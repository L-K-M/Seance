// The band channel is ported from Poltergeist
// app/poltergeist_app/lib/services/macos_toolbar_band_channel.dart; see
// docs/POLTERGEIST.md. Divergence: the channel is `seance/window`, and the
// installer lives here rather than in a window-lifecycle service.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

/// The `seance/window` method channel's name. The Swift side lives in
/// `MainFlutterWindow.swift`.
const windowChannelName = 'seance/window';

/// Makes the main window's titlebar part of the app, the way Poltergeist's
/// is: content under a transparent titlebar, the title hidden, and an empty
/// unified toolbar that makes the band 52 pt tall so the traffic lights sit
/// centred on the header drawn beneath it. Empty band space keeps AppKit's
/// window drag and double-click zoom; the header's controls take clicks
/// through `MacosToolbarPassthrough` views.
///
/// The runner starts from a standard titlebar
/// (`MainFlutterWindowManipulator.start`), so this must run before the
/// window is first shown: `main` calls [install] ahead of
/// `WindowStateService.restoreAndTrack`, while the window is still hidden.
/// Never pass a `titleBarStyle` to window_manager as well: its
/// `setTitleBarStyle` rewrites the same three window properties.
abstract final class MacosTitlebar {
  /// Installs the titlebar and returns the band's state, or null when the
  /// install failed and the window keeps its standard titlebar, in which
  /// case nothing in the app reserves a band. Only call it on macOS.
  static Future<MacosToolbarBandChannel?> install({
    MacosTitlebarAdapter? adapter,
    MethodChannel? channel,
  }) async {
    adapter ??= _WindowUtilsTitlebar();
    try {
      await adapter.install();
    } catch (error) {
      debugPrint('Integrated titlebar install failed: $error');
      // A half-applied titlebar (content under a transparent bar, but no
      // toolbar to make the band) would put the traffic lights over the
      // rail with nothing reserved for them. Back to the standard one.
      try {
        await adapter.reset();
      } catch (_) {}
      return null;
    }
    final band = MacosToolbarBandChannel(channel: channel);
    await band.start();
    return band;
  }
}

/// The native calls behind [MacosTitlebar.install], a seam for tests.
abstract interface class MacosTitlebarAdapter {
  /// Makes the titlebar transparent over full-size content and adds the
  /// empty unified toolbar.
  Future<void> install();

  /// Puts the standard titlebar back.
  Future<void> reset();
}

final class _WindowUtilsTitlebar implements MacosTitlebarAdapter {
  /// Every other WindowManipulator call waits for `initialize` to have
  /// completed, so after a failed one [reset] would wait forever.
  bool _initialized = false;

  @override
  Future<void> install() async {
    await WindowManipulator.initialize();
    _initialized = true;
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.hideTitle();
    await WindowManipulator.addToolbar();
    await WindowManipulator.setToolbarStyle(
      toolbarStyle: NSWindowToolbarStyle.unified,
    );
  }

  @override
  Future<void> reset() async {
    if (!_initialized) return;
    await WindowManipulator.removeToolbar();
    await WindowManipulator.showTitle();
    await WindowManipulator.makeTitlebarOpaque();
    await WindowManipulator.disableFullSizeContentView();
  }
}

/// Whether macOS currently shows the unified toolbar band that the header
/// draws under, as the runner reports it.
///
/// The band exists only while the window is windowed. In full screen
/// AppKit would keep the toolbar permanently visible in an opaque strip
/// above the content, covering the header, so the runner hides the toolbar
/// for the duration and the titlebar only slides in with the menu bar. The
/// runner reports each switch as the transition *begins* (AppKit's
/// will-enter and will-exit edges), so the layout changes with the toolbar
/// instead of snapping after the animation.
///
/// The value starts true, the windowed layout, and stays true when no
/// runner answers the channel.
final class MacosToolbarBandChannel extends ValueNotifier<bool> {
  MacosToolbarBandChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(windowChannelName),
      super(true) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;

  /// Asks the runner for the band's state, which a window restored
  /// straight into full screen changed before the handler was set.
  ///
  /// Never throws: [MacosTitlebar.install] awaits this in `main` before
  /// the hidden-at-launch window is shown, and the band is only a layout
  /// hint, so any failure leaves the windowed layout instead.
  Future<void> start() async {
    try {
      final visible = await _channel.invokeMethod<bool>('isToolbarBandVisible');
      if (visible != null) value = visible;
    } on MissingPluginException {
      // No runner side: the windowed layout stands.
    } catch (error) {
      // A runner error, or a reply that is not a bool (a cast error).
      debugPrint('Toolbar band state unavailable: $error');
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'toolbarBandChanged') {
      throw MissingPluginException();
    }
    final visible = call.arguments;
    if (visible is! bool) {
      throw PlatformException(
        code: 'BAD_ARGS',
        message: 'toolbarBandChanged needs a bool argument',
      );
    }
    value = visible;
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
