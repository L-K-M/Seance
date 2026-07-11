import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?

  /// Whether a terminal (rather than a text field) currently has focus. Pushed
  /// from Dart so the Edit menu can route Copy/Paste/Select All to the active
  /// terminal, and otherwise fall back to the native behaviour (text fields).
  private var terminalFocused = false

  override func awakeFromNib() {
    // Séance is single-window; disabling automatic window tabbing stops AppKit
    // from injecting a View menu full of tab commands ("Show Tab Bar", etc.).
    NSWindow.allowsAutomaticWindowTabbing = false

    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Default desktop window size.
    self.setContentSize(NSSize(width: 1800, height: 1600))
    self.center()

    // Channel used by our menu items to trigger Dart actions.
    menuChannel = FlutterMethodChannel(
      name: "seance/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    // Dart → native: track whether a terminal is focused (see `terminalFocused`).
    menuChannel?.setMethodCallHandler { [weak self] call, result in
      if call.method == "setTerminalFocused" {
        self?.terminalFocused = (call.arguments as? Bool) ?? false
        result(nil)
      } else {
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
        panel.allowedFileTypes = ["app"]
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

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The main menu is loaded from the storyboard; augment it once it's set.
    DispatchQueue.main.async { [weak self] in
      self?.installMenuItems()
    }

    super.awakeFromNib()
  }

  /// Keep the storyboard's standard menus (Edit, Window, Help, …) and add our
  /// own: rewire the app menu's Preferences item to open Settings, add Terminal
  /// items for New Tab (⌘T) and Generate Command… (⌘K), and route Edit ▸
  /// Copy/Paste/Select All through us so they can reach the terminal — all fire
  /// back into Dart.
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

    retargetEditMenu(mainMenu)
  }

  /// Retarget the standard Edit menu's Copy / Paste / Select All to our own
  /// actions (keeping their ⌘C/⌘V/⌘A key equivalents from the storyboard). When
  /// a terminal is focused we forward to Dart; otherwise we re-dispatch the
  /// original selector so a focused text field copies/pastes natively as before.
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

  @objc private func editCopy(_ sender: Any?) {
    if terminalFocused {
      menuChannel?.invokeMethod("editCopy", arguments: nil)
    } else {
      _ = NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: sender)
    }
  }

  @objc private func editPaste(_ sender: Any?) {
    if terminalFocused {
      menuChannel?.invokeMethod("editPaste", arguments: nil)
    } else {
      _ = NSApp.sendAction(NSSelectorFromString("paste:"), to: nil, from: sender)
    }
  }

  @objc private func editSelectAll(_ sender: Any?) {
    if terminalFocused {
      menuChannel?.invokeMethod("editSelectAll", arguments: nil)
    } else {
      _ = NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: sender)
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
}
