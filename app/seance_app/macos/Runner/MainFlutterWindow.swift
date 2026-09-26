import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import macos_window_utils
import window_manager

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?
  private var bookmarksChannel: FlutterMethodChannel?
  private var windowChannel: FlutterMethodChannel?

  /// In full screen, or entering it: set on AppKit's will-enter and
  /// will-exit edges, so the toolbar and the Flutter layout switch as a
  /// transition starts rather than after its animation.
  private var inFullScreen = false

  /// The Dart side installs the unified toolbar after launch
  /// (macos_titlebar.dart), possibly after a restored window already
  /// entered full screen, so every toolbar the window receives takes the
  /// current visibility.
  override var toolbar: NSToolbar? {
    didSet { toolbar?.isVisible = !inFullScreen }
  }

  /// Settings in a window of its own (SettingsWindow.swift).
  private var settingsWindow: SettingsWindowHost?

  /// URLs currently inside a startAccessingSecurityScopedResource grant,
  /// keyed by an opaque per-grant token (NOT by path: two overlapping grants
  /// on the same file must each balance their own start with a stop).
  private var activeScopedUrls: [String: URL] = [:]
  private var nextGrantToken = 0

  /// Whether a terminal (rather than a text field) currently has focus. Pushed
  /// from Dart so the Edit menu can route Copy/Paste/Select All to the active
  /// terminal, and otherwise fall back to the native behaviour (text fields).
  private var terminalFocused = false

  /// View ▸ "Use Compact Sidebar Rows" / "Use Comfortable Sidebar Rows": one
  /// item whose title Dart owns and sets to the density it would switch to,
  /// so the copy lives in one place. Hidden (with its separator) until Dart
  /// has named it; Dart may name it before the menu is built, hence the
  /// title kept on its own.
  private var densityItem: NSMenuItem?
  private var densitySeparator: NSMenuItem?
  private var densityTitle: String?

  override func awakeFromNib() {
    // Séance's windows never tab (the app's, and Settings' with its own
    // `tabbingMode`); disabling automatic window tabbing stops AppKit from
    // injecting a View menu full of tab commands ("Show Tab Bar", etc.).
    NSWindow.allowsAutomaticWindowTabbing = false

    // The integrated titlebar (macos_titlebar.dart): macos_window_utils
    // hosts the Flutter view in its own controller, whose click
    // passthrough lets the header's buttons take clicks inside the
    // titlebar band. The Flutter controller inside it is still the
    // accessibility guard (SeanceFlutterViewController.m).
    let windowUtilsController = MacOSWindowUtilsViewController(
      flutterViewController: SeanceFlutterViewController())
    let flutterViewController = windowUtilsController.flutterViewController
    self.contentViewController = windowUtilsController
    // Default desktop window size, matching the Linux and Windows runners
    // (the window-state service restores the user's own frame after the
    // first launch); 1800x1600 overflowed most laptop screens.
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.center()
    // Starts from a standard titlebar; Dart makes it transparent and adds
    // the unified toolbar before the window is first shown.
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    // Channel used by our menu items to trigger Dart actions.
    menuChannel = FlutterMethodChannel(
      name: "seance/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    // Dart → native: track whether a terminal is focused (see
    // `terminalFocused`), and title the View menu's density item.
    menuChannel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setTerminalFocused":
        self?.terminalFocused = (call.arguments as? Bool) ?? false
        result(nil)
      case "setServerListDensityTitle":
        self?.densityTitle = call.arguments as? String
        self?.applyDensityTitle()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    filesChannel = FlutterMethodChannel(
      name: "seance/files",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    filesChannel?.setMethodCallHandler { call, result in
      if call.method == "pickApplication" {
        let panel = NSOpenPanel()
        panel.title = "Choose an editor application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        // .applicationBundle (com.apple.application-bundle) is the exact
        // equivalent of the legacy `allowedFileTypes = ["app"]` filter, which
        // macOS 12 deprecated. Unconditional: allowedContentTypes needs
        // macOS 11, and this project's MACOSX_DEPLOYMENT_TARGET is 12.0
        // (Runner.xcodeproj, every configuration — see AGENTS.md §3), so an
        // availability check here is always true and its dead `else` branch
        // would still be compiled, putting the deprecation warning back.
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          guard let bundle = Bundle(url: url),
                let bundleIdentifier = bundle.bundleIdentifier else {
            result(FlutterError(
              code: "INVALID_APPLICATION",
              message: "The selected item is not an application bundle.",
              details: nil))
            return
          }
          let info = bundle.infoDictionary
          let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
          result([
            "displayName": displayName,
            "bundleIdentifier": bundleIdentifier,
          ])
        }
        return
      }
      guard call.method == "openWithApplication",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            let bundleIdentifier = arguments["bundleIdentifier"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let application = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier) else {
        result(FlutterError(
          code: "APPLICATION_NOT_FOUND",
          message: "The configured editor application is not installed.",
          details: nil))
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        [URL(fileURLWithPath: path)],
        withApplicationAt: application,
        configuration: configuration) { _, error in
          if let error = error {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "OPEN_FAILED",
                message: error.localizedDescription,
                details: nil))
            }
          } else {
            DispatchQueue.main.async { result(nil) }
          }
        }
    }

    // Identity files ("reference, don't store" SSH keys): a native open panel
    // that can show dot-directories like ~/.ssh, plus security-scoped
    // bookmarks so a key picked outside ~/.ssh stays readable at connect time
    // across relaunches (the sandbox forgets plain picker grants on quit).
    bookmarksChannel = FlutterMethodChannel(
      name: "seance/secure_bookmarks",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    bookmarksChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handleBookmarkCall(call, result: result)
    }

    settingsWindow = SettingsWindowHost(
      mainWindow: self,
      messenger: flutterViewController.engine.binaryMessenger)

    // Full screen: AppKit keeps a window's toolbar permanently visible in
    // full screen, in an opaque strip of its own above the content. The
    // empty unified toolbar that gives the windowed titlebar its 52 pt
    // band would cover the header drawn beneath it, so it hides for the
    // duration and the titlebar only slides in with the menu bar.
    // `seance/window` tells the Dart side the band is gone, so it stops
    // reserving it above pushed routes. Notifications rather than delegate
    // methods, because window_manager owns the window's delegate.
    windowChannel = FlutterMethodChannel(
      name: "seance/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "isToolbarBandVisible" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(!self.inFullScreen)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(hideToolbarBandForFullScreen(_:)),
      name: NSWindow.willEnterFullScreenNotification,
      object: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(showToolbarBandLeavingFullScreen(_:)),
      name: NSWindow.willExitFullScreenNotification,
      object: self)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The main menu is loaded from the storyboard; augment it once it's set.
    DispatchQueue.main.async { [weak self] in
      self?.installMenuItems()
    }

    super.awakeFromNib()
  }

  /// The Settings window closes with this one, so closing the app's window
  /// still leaves no window open and quits the app
  /// (AppDelegate.applicationShouldTerminateAfterLastWindowClosed).
  override func close() {
    settingsWindow?.close()
    super.close()
  }

  @objc private func hideToolbarBandForFullScreen(_ notification: Notification) {
    setInFullScreen(true)
  }

  @objc private func showToolbarBandLeavingFullScreen(_ notification: Notification) {
    setInFullScreen(false)
  }

  private func setInFullScreen(_ value: Bool) {
    guard value != inFullScreen else { return }
    inFullScreen = value
    toolbar?.isVisible = !value
    windowChannel?.invokeMethod("toolbarBandChanged", arguments: !value)
  }

  /// Keep the window invisible while Dart puts it back where it was closed:
  /// WindowStateService.restoreAndTrack() (main.dart, before runApp) applies
  /// the previous session's frame and then shows the window — always, even
  /// when restoring fails — so the storyboard's default-size window never
  /// flashes. Do not remove this without removing that contract too.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }

  /// Keep the storyboard's standard menus (Edit, Window, Help, …) and add our
  /// own: rewire the app menu's Preferences item to open Settings, add Terminal
  /// items for New Tab (⌘T) and Generate Command… (⌘K), put the server list's
  /// density switch at the top of View, and route Edit ▸ Copy/Paste/Select All
  /// through us so they can reach the terminal — all fire back into Dart.
  private func installMenuItems() {
    guard let mainMenu = NSApp.mainMenu else { return }

    if let appMenu = mainMenu.items.first?.submenu,
       let settings = appMenu.items.first(where: {
         $0.title.hasPrefix("Preferences") || $0.title.hasPrefix("Settings")
       }) {
      settings.title = "Settings…"
      settings.target = self
      settings.action = #selector(didSelectSettings)
      settings.keyEquivalent = ","
      settings.keyEquivalentModifierMask = [.command]
    }

    let terminalSubmenu = NSMenu(title: "Terminal")
    let newTab = NSMenuItem(
      title: "New Tab",
      action: #selector(didSelectNewTab),
      keyEquivalent: "t")
    newTab.target = self
    terminalSubmenu.addItem(newTab)
    terminalSubmenu.addItem(.separator())

    let generate = NSMenuItem(
      title: "Generate Command…",
      action: #selector(didSelectGenerateCommand),
      keyEquivalent: "k")
    generate.target = self
    terminalSubmenu.addItem(generate)

    let terminalItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
    terminalItem.submenu = terminalSubmenu
    let windowIndex = mainMenu.indexOfItem(withTitle: "Window")
    if windowIndex >= 0 {
      mainMenu.insertItem(terminalItem, at: windowIndex)
    } else {
      mainMenu.addItem(terminalItem)
    }

    if let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu {
      let density = NSMenuItem(
        title: "",
        action: #selector(didSelectToggleDensity),
        keyEquivalent: "")
      density.target = self
      let separator = NSMenuItem.separator()
      viewMenu.insertItem(density, at: 0)
      viewMenu.insertItem(separator, at: 1)
      densityItem = density
      densitySeparator = separator
      applyDensityTitle()
    }

    retargetEditMenu(mainMenu)
  }

  /// Title the density item with the latest name from Dart, or keep it (and
  /// its separator) hidden while there is none.
  private func applyDensityTitle() {
    let title = densityTitle ?? ""
    densityItem?.title = title
    densityItem?.isHidden = title.isEmpty
    densitySeparator?.isHidden = title.isEmpty
  }

  /// Retarget the standard Edit menu's Copy / Paste / Select All to our own
  /// actions (keeping their ⌘C/⌘V/⌘A key equivalents from the storyboard). When
  /// a terminal is focused we forward to Dart; otherwise we re-dispatch the
  /// original selector so a focused text field copies/pastes natively as before.
  ///
  /// "A terminal is focused" is this window's focus: with the Settings window
  /// key, its text fields get the native actions even though a terminal
  /// behind it still holds focus in this window.
  private func retargetEditMenu(_ mainMenu: NSMenu) {
    let copySel = NSSelectorFromString("copy:")
    let pasteSel = NSSelectorFromString("paste:")
    let selectAllSel = NSSelectorFromString("selectAll:")
    for topItem in mainMenu.items {
      guard let submenu = topItem.submenu else { continue }
      for item in submenu.items {
        if item.action == copySel {
          item.target = self
          item.action = #selector(editCopy(_:))
        } else if item.action == pasteSel {
          item.target = self
          item.action = #selector(editPaste(_:))
        } else if item.action == selectAllSel {
          item.target = self
          item.action = #selector(editSelectAll(_:))
        }
      }
    }
  }

  private var routesEditToTerminal: Bool { terminalFocused && isKeyWindow }

  @objc private func editCopy(_ sender: Any?) {
    if routesEditToTerminal {
      menuChannel?.invokeMethod("editCopy", arguments: nil)
    } else {
      _ = NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: sender)
    }
  }

  @objc private func editPaste(_ sender: Any?) {
    if routesEditToTerminal {
      menuChannel?.invokeMethod("editPaste", arguments: nil)
    } else {
      _ = NSApp.sendAction(NSSelectorFromString("paste:"), to: nil, from: sender)
    }
  }

  @objc private func editSelectAll(_ sender: Any?) {
    if routesEditToTerminal {
      menuChannel?.invokeMethod("editSelectAll", arguments: nil)
    } else {
      _ = NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: sender)
    }
  }

  /// The user's real home directory. The sandbox's $HOME is the app
  /// container, so the open panel would otherwise start in the wrong place.
  private func realHomeDirectory() -> URL? {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
      return nil
    }
    return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
  }

  private func handleBookmarkCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    switch call.method {
    case "pickIdentityFile":
      let panel = NSOpenPanel()
      panel.title = "Choose an SSH identity file"
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.resolvesAliases = true
      // Identity files live in dot-directories; without this the panel shows
      // an apparently empty home.
      panel.showsHiddenFiles = true
      if let home = realHomeDirectory() {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        panel.directoryURL =
          FileManager.default.fileExists(atPath: ssh.path) ? ssh : home
      }
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        // Mint the bookmark while the picker's grant is live. Read-only: the
        // app only ever reads identity files, so the standing grant must not
        // be able to modify them. If minting fails the path alone still
        // helps: ~/.ssh works via the entitlement, and the picker grant
        // covers this process for anything else.
        let bookmark = try? url.bookmarkData(
          options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        var payload: [String: Any] = ["path": url.path]
        if let bookmark = bookmark {
          payload["bookmark"] = bookmark.base64EncodedString()
        }
        result(payload)
      }
    case "resolveBookmark":
      guard let arguments = call.arguments as? [String: Any],
            let encoded = arguments["bookmark"] as? String,
            let data = Data(base64Encoded: encoded) else {
        result(FlutterError(
          code: "BAD_BOOKMARK", message: "Malformed bookmark data.",
          details: nil))
        return
      }
      var isStale = false
      guard let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale) else {
        result(FlutterError(
          code: "RESOLVE_FAILED",
          message: "The saved file grant could not be resolved.",
          details: nil))
        return
      }
      guard url.startAccessingSecurityScopedResource() else {
        result(FlutterError(
          code: "ACCESS_DENIED",
          message: "The saved file grant was not honored.",
          details: nil))
        return
      }
      nextGrantToken += 1
      let token = String(nextGrantToken)
      activeScopedUrls[token] = url
      var payload: [String: Any] = ["path": url.path, "token": token]
      // A stale bookmark still resolves once; re-mint it now, while access is
      // live, so the caller can persist a fresh grant.
      if isStale,
         let refreshed = try? url.bookmarkData(
           options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
           includingResourceValuesForKeys: nil,
           relativeTo: nil) {
        payload["refreshedBookmark"] = refreshed.base64EncodedString()
      }
      result(payload)
    case "stopAccess":
      if let arguments = call.arguments as? [String: Any],
         let token = arguments["token"] as? String,
         let url = activeScopedUrls.removeValue(forKey: token) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @objc private func didSelectSettings() {
    menuChannel?.invokeMethod("openSettings", arguments: nil)
  }

  @objc private func didSelectNewTab() {
    menuChannel?.invokeMethod("newTab", arguments: nil)
  }

  @objc private func didSelectGenerateCommand() {
    menuChannel?.invokeMethod("generateCommand", arguments: nil)
  }

  @objc private func didSelectToggleDensity() {
    menuChannel?.invokeMethod("toggleServerListDensity", arguments: nil)
  }
}
