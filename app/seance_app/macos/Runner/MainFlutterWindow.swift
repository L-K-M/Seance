import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?

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

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The main menu is loaded from the storyboard; augment it once it's set.
    DispatchQueue.main.async { [weak self] in
      self?.installMenuItems()
    }

    super.awakeFromNib()
  }

  /// Keep the storyboard's standard menus (Edit, Window, Help, …) and add our
  /// own: rewire the app menu's Preferences item to open Settings, and add a
  /// Terminal ▸ Generate Command… item (⌘K) — both fire back into Dart.
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
  }

  @objc private func didSelectSettings() {
    menuChannel?.invokeMethod("openSettings", arguments: nil)
  }

  @objc private func didSelectGenerateCommand() {
    menuChannel?.invokeMethod("generateCommand", arguments: nil)
  }
}
