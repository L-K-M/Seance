import Cocoa
import FlutterMacOS

/// The Settings window: a second NSWindow on a second Flutter engine, whose
/// Dart side runs the Settings screen instead of the app (see
/// lib/services/settings_window.dart).
///
/// Dart opens it, or brings it forward, with "open" on the app engine's
/// `seance/settings_window` channel, and hears "closed" there when the user
/// closes it. Every message either engine sends on `seance/settings_link` is
/// forwarded to the other engine, and its reply back: the two engines share
/// nothing else, so this is how the window reaches the app's state.
///
/// Closing it hides it: the window and its engine are created once and kept
/// until the app's window closes, as on the other desktops, where tearing a
/// second engine down is not safe (lib/services/settings_window.dart). It
/// also reopens at once; the Dart side drops its screen while hidden.
final class SettingsWindowHost: NSObject, NSWindowDelegate {
  private static let controlChannel = "seance/settings_window"
  private static let linkChannel = "seance/settings_link"

  /// What the settings engine's Dart entrypoint looks for to run the
  /// Settings screen instead of the app (`settingsWindowArgument` in Dart).
  private static let windowArgument = "--seance-settings-window"

  private static let defaultSize = NSSize(width: 760, height: 640)
  private static let minimumSize = NSSize(width: 520, height: 420)

  private weak var mainWindow: NSWindow?
  private let mainMessenger: FlutterBinaryMessenger
  private let control: FlutterMethodChannel

  private var window: NSWindow?

  init(mainWindow: NSWindow, messenger: FlutterBinaryMessenger) {
    self.mainWindow = mainWindow
    mainMessenger = messenger
    control = FlutterMethodChannel(
      name: Self.controlChannel, binaryMessenger: messenger)
    super.init()
    control.setMethodCallHandler { [weak self] call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.open()
      result(nil)
    }
    messenger.setMessageHandlerOnChannel(Self.linkChannel) {
      [weak self] message, reply in
      // No window, no answer: the sender reads an empty reply as "no
      // handler", the same as a window that was never opened.
      guard let controller = self?.window?.contentViewController
        as? FlutterViewController
      else {
        reply(nil)
        return
      }
      controller.engine.binaryMessenger.send(
        onChannel: Self.linkChannel, message: message, binaryReply: reply)
    }
  }

  /// Closes the window for good, if there is one. The app's window calls
  /// this as it closes, so the app still quits with its last window —
  /// a window only hidden would keep it running.
  func close() {
    window?.close()
  }

  private func open() {
    if let window = window {
      // Shows it again if it was closed, and brings it forward either way.
      window.makeKeyAndOrderFront(nil)
      return
    }

    let project = FlutterDartProject()
    project.dartEntrypointArguments = [Self.windowArgument]
    // The same subclass as the app's window, for the same reason: this screen
    // is text fields, and closing the window is exactly the controller
    // teardown the accessibility guard exists for
    // (docs/macos-accessibility-crash.md).
    let controller = SeanceFlutterViewController(project: project)
    // No plugins: everything the Settings screen does runs in the app's
    // engine, reached over the link. Set before the engine can run Dart,
    // whose first act is to say hello over it.
    controller.engine.binaryMessenger.setMessageHandlerOnChannel(
      Self.linkChannel
    ) { [weak self] message, reply in
      guard let main = self?.mainMessenger else {
        reply(nil)
        return
      }
      main.send(onChannel: Self.linkChannel, message: message, binaryReply: reply)
    }

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "Settings"
    window.contentViewController = controller
    window.setContentSize(Self.defaultSize)
    window.contentMinSize = Self.minimumSize
    // Owned by `self.window`; released on close, which shuts its engine down.
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    if let main = mainWindow {
      let frame = main.frame
      window.setFrameOrigin(NSPoint(
        x: frame.midX - window.frame.width / 2,
        y: frame.midY - window.frame.height / 2))
    } else {
      window.center()
    }
    self.window = window
    window.makeKeyAndOrderFront(nil)
  }

  /// The close button, ⌘W and File ▸ Close: hide rather than close.
  /// Programmatic `close()` does not ask, which is how `close()` above ends
  /// it for good.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    control.invokeMethod("closed", arguments: nil)
    return false
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing === window
    else { return }
    closing.delegate = nil
    window = nil
    // Released after AppKit has finished closing it rather than from inside
    // its own close: that drops the last reference to the controller, whose
    // dealloc invalidates the text fields and whose engine then shuts down.
    DispatchQueue.main.async {
      closing.contentViewController = nil
    }
  }
}
