import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'atomic_file.dart';

/// The desktop main-window geometry carried across launches. [bounds] is the
/// last user-arranged *normal* frame (never a maximized or full-screen one) —
/// the position doubles as the monitor choice, so restoring it puts the window
/// back on the display it was closed on. The flags say how the window was
/// presented on top of that frame.
///
/// Units: the desktop's global logical pixels on macOS and Linux, but
/// *physical* pixels on Windows. window_manager converts between physical and
/// logical with one ratio — the monitor the window currently occupies — while
/// screen_retriever scales each display by its own ratio, so on a mixed-DPI
/// Windows setup the two "logical" spaces disagree and neither is stable
/// across a relaunch. Physical pixels are the one space every Windows API
/// maps into exactly; the file is device-local, so the unit never has to
/// travel.
class WindowStateSnapshot {
  final Rect? bounds;
  final bool isMaximized;
  final bool isFullScreen;

  const WindowStateSnapshot({
    this.bounds,
    this.isMaximized = false,
    this.isFullScreen = false,
  });

  Map<String, dynamic> toJson() => {
    if (bounds != null) 'x': bounds!.left,
    if (bounds != null) 'y': bounds!.top,
    if (bounds != null) 'width': bounds!.width,
    if (bounds != null) 'height': bounds!.height,
    'isMaximized': isMaximized,
    'isFullScreen': isFullScreen,
  };

  /// Tolerant parse: anything malformed reads as "nothing saved". Window
  /// geometry is cheap to lose, so there is no quarantine ceremony here — the
  /// next save simply overwrites a bad file.
  static WindowStateSnapshot? fromJson(Object? json) {
    if (json is! Map) return null;
    double? dim(Object? value) {
      if (value is! num) return null;
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }

    final x = dim(json['x']);
    final y = dim(json['y']);
    final width = dim(json['width']);
    final height = dim(json['height']);
    Rect? bounds;
    if (x != null &&
        y != null &&
        width != null &&
        height != null &&
        width > 0 &&
        height > 0) {
      bounds = Rect.fromLTWH(x, y, width, height);
    }
    return WindowStateSnapshot(
      bounds: bounds,
      isMaximized: json['isMaximized'] == true,
      isFullScreen: json['isFullScreen'] == true,
    );
  }
}

/// Loads and saves the window state as `window_state.json`. Kept out of
/// settings.json on purpose: geometry changes with every move/resize, and the
/// settings file — which carries the device's sync identity — should not be
/// rewritten that often (and it isn't loaded until after the first frame,
/// which is too late to place the window without a flash).
class WindowStateStore {
  final File file;
  Future<void> _saveTail = Future<void>.value();

  WindowStateStore(this.file);

  Future<WindowStateSnapshot?> load() async {
    try {
      if (!await file.exists()) return null;
      return WindowStateSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(WindowStateSnapshot snapshot) {
    final contents = jsonEncode(snapshot.toJson());
    final result = Completer<void>();
    _saveTail = _saveTail.then((_) async {
      try {
        await writeStringAtomically(file, contents);
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

/// Decide whether a saved frame can be restored onto the currently connected
/// displays (their visible areas, in the same coordinate space as the frame).
/// Returns the frame to restore, or null to fall back to the platform's
/// default placement — when the monitor the window lived on is gone, or the
/// saved values are degenerate. "Restorable" means enough of the frame lands
/// on some display to grab the title bar and drag the window back by hand —
/// which is specifically the frame's *top* strip: a frame hanging down from
/// above every screen shows plenty of window but nothing to drag.
Rect? resolveWindowBounds(Rect? saved, Iterable<Rect> displayAreas) {
  if (saved == null) return null;
  const minimumWindowSize = 100.0;
  if (!saved.left.isFinite ||
      !saved.top.isFinite ||
      !saved.width.isFinite ||
      !saved.height.isFinite) {
    return null;
  }
  if (saved.width < minimumWindowSize || saved.height < minimumWindowSize) {
    return null;
  }
  for (final area in displayAreas) {
    final overlap = saved.intersect(area);
    if (overlap.width < 100 || overlap.height < 50) continue;
    // The title bar sits at the frame's top edge, so that edge must be on
    // this display (1px of tolerance for rounding), or the visible chunk is
    // un-draggable.
    if (saved.top < area.top - 1) continue;
    return saved;
  }
  return null;
}

/// Restores the persisted window state at launch and keeps it current while
/// the app runs. Desktop only — a no-op on mobile.
///
/// Wiring contract (macOS): `MainFlutterWindow` hides the window at launch
/// (`hiddenWindowAtLaunch()` in its `order` override) so the saved frame can
/// be applied off-screen. [restoreAndTrack] is what makes the window visible
/// again — it always reaches `show()` on macOS, even when restoring fails —
/// so it must run in `main()` before `runApp`.
class WindowStateService with WindowListener {
  WindowStateService._(this._store, this._current);

  /// Keeps the listener alive for the process lifetime; also the reentry
  /// guard, since the window can only be restored once per launch.
  static WindowStateService? _instance;

  final WindowStateStore _store;
  WindowStateSnapshot _current;
  Timer? _debounce;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  static Future<void> restoreAndTrack() async {
    if (!_isDesktop || _instance != null) return;
    try {
      await windowManager.ensureInitialized();
      final dir = await getApplicationSupportDirectory();
      final store = WindowStateStore(File('${dir.path}/window_state.json'));
      final saved = await store.load();
      final service = WindowStateService._(
        store,
        saved ?? const WindowStateSnapshot(),
      );
      _instance = service;
      await service._applyAtLaunch(saved);
      windowManager.addListener(service);
    } catch (error) {
      debugPrint('Window state restore failed: $error');
      if (Platform.isMacOS) {
        // The macOS runner keeps the window hidden until we show it; a restore
        // failure must not leave the app invisible.
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      }
    }
  }

  Future<void> _applyAtLaunch(WindowStateSnapshot? saved) async {
    final bounds = resolveWindowBounds(saved?.bounds, await _displayAreas());
    final maximized = saved?.isMaximized ?? false;
    final fullScreen = saved?.isFullScreen ?? false;
    if (Platform.isMacOS) {
      // The window is hidden (see MainFlutterWindow.order), so the saved frame
      // applies without a flash of the storyboard default. Full-screen needs a
      // visible window — toggleFullScreen does nothing to a hidden one — so it
      // is entered after show().
      await windowManager.waitUntilReadyToShow(null, () async {
        if (bounds != null) await windowManager.setBounds(bounds);
        if (maximized && !fullScreen) await windowManager.maximize();
        await windowManager.show();
        await windowManager.focus();
        if (fullScreen) await windowManager.setFullScreen(true);
      });
    } else if (Platform.isWindows) {
      if (bounds != null) {
        // Stored values are physical pixels. setBounds sends logical values
        // together with the very ratio it converted them by, and the plugin
        // multiplies them straight back — so dividing by whatever
        // getDevicePixelRatio() returns *right now* lands exact physical
        // coordinates, whichever monitor's ratio that happens to be. No
        // waiting for metrics to settle.
        Rect asLogical(Rect physical) {
          final ratio = windowManager.getDevicePixelRatio();
          return Rect.fromLTWH(
            physical.left / ratio,
            physical.top / ratio,
            physical.width / ratio,
            physical.height / ratio,
          );
        }

        // Two passes: crossing onto a different-DPI monitor makes the runner
        // apply the OS's suggested frame (WM_DPICHANGED — handled
        // synchronously inside the first call), which rescales the window.
        // Re-asserting the full frame afterwards sticks exactly and — the
        // monitor and DPI no longer changing — provokes no further
        // adjustment.
        await windowManager.setBounds(
          null,
          position: asLogical(bounds).topLeft,
        );
        await windowManager.setBounds(asLogical(bounds));
      }
      // The runner shows the window on the first Flutter frame with
      // SW_SHOWNORMAL, which cancels any earlier maximize (and maximizing a
      // hidden window would show it early). The plugin reports that Show as a
      // 'show' event (WM_SHOWWINDOW), so the flags apply then — see
      // [onWindowEvent] — with a timer as a backstop in case the event is
      // never delivered.
      if (maximized || fullScreen) {
        _pendingWindowsFlags = (maximized: maximized, fullScreen: fullScreen);
        Timer(const Duration(seconds: 3), () {
          unawaited(_applyPendingWindowsFlags());
        });
      }
    } else {
      // Linux: the runner shows the window on the first frame, and GTK applies
      // move/resize/maximize/fullscreen requests made while hidden when the
      // window maps. (On Wayland the compositor ignores positioning — size,
      // maximize and full-screen still restore.)
      if (bounds != null) await windowManager.setBounds(bounds);
      if (fullScreen) {
        await windowManager.setFullScreen(true);
      } else if (maximized) {
        await windowManager.maximize();
      }
    }
    // A rejected saved frame (its monitor is disconnected) is deliberately
    // retained, not dropped: every restore re-checks it against the connected
    // displays, so it can never place the window off-screen — but if that
    // monitor comes back, the window goes home. The first normal-frame
    // capture replaces it anyway.
    _current = WindowStateSnapshot(
      bounds: bounds ?? saved?.bounds,
      isMaximized: maximized,
      isFullScreen: fullScreen,
    );
  }

  /// The visible working area of every connected display, in the same
  /// coordinate space as the stored bounds ([resolveWindowBounds] needs both
  /// sides to agree).
  Future<List<Rect>> _displayAreas() async {
    final displays = await ScreenRetriever.instance.getAllDisplays();
    return [for (final display in displays) _displayArea(display)];
  }

  Rect _displayArea(Display display) {
    final area =
        (display.visiblePosition ?? Offset.zero) &
        (display.visibleSize ?? display.size);
    if (!Platform.isWindows) return area;
    // screen_retriever divides each monitor's rect by that monitor's own
    // scale factor, so mixed-DPI monitors don't share one logical space.
    // Multiply it back out into the physical coordinates the stored bounds
    // use (see WindowStateSnapshot).
    final scale = (display.scaleFactor ?? 1).toDouble();
    return Rect.fromLTWH(
      area.left * scale,
      area.top * scale,
      area.width * scale,
      area.height * scale,
    );
  }

  /// A frame from window_manager, converted into the stored coordinate space
  /// (physical pixels on Windows — getBounds divides the physical frame by
  /// the current monitor's ratio, so multiplying it back is exact).
  Rect _storedSpaceFrom(Rect windowBounds) {
    if (!Platform.isWindows) return windowBounds;
    final ratio = windowManager.getDevicePixelRatio();
    return Rect.fromLTWH(
      windowBounds.left * ratio,
      windowBounds.top * ratio,
      windowBounds.width * ratio,
      windowBounds.height * ratio,
    );
  }

  /// Windows-only: maximize/full-screen waiting for the runner to show the
  /// window (see the Windows branch of [_applyAtLaunch]).
  ({bool maximized, bool fullScreen})? _pendingWindowsFlags;

  Future<void> _applyPendingWindowsFlags() async {
    final pending = _pendingWindowsFlags;
    if (pending == null) return;
    _pendingWindowsFlags = null;
    try {
      if (pending.fullScreen) {
        await windowManager.setFullScreen(true);
      } else if (pending.maximized) {
        await windowManager.maximize();
      }
    } catch (error) {
      debugPrint('Deferred window state restore failed: $error');
    }
  }

  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'show') unawaited(_applyPendingWindowsFlags());
  }

  // Geometry events arrive continuously during a drag; the debounce means one
  // write per interaction, not one per pixel. The *ed variants fire only on
  // some platforms, so both are wired.
  @override
  void onWindowResize() => _scheduleCapture();
  @override
  void onWindowResized() => _scheduleCapture();
  @override
  void onWindowMove() => _scheduleCapture();
  @override
  void onWindowMoved() => _scheduleCapture();
  @override
  void onWindowMaximize() => _scheduleCapture();
  @override
  void onWindowUnmaximize() => _scheduleCapture();
  @override
  void onWindowEnterFullScreen() => _scheduleCapture();
  @override
  void onWindowLeaveFullScreen() => _scheduleCapture();
  @override
  void onWindowRestore() => _scheduleCapture();

  @override
  void onWindowClose() {
    // Last chance to persist a change still inside the debounce window. Best
    // effort — if the process dies before the write lands, the previous save
    // still holds.
    _debounce?.cancel();
    unawaited(_captureAndSave());
  }

  void _scheduleCapture() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_captureAndSave()),
    );
  }

  Future<void> _captureAndSave() async {
    try {
      // A minimized window reports junk geometry; whatever was saved before
      // minimizing is still the truth.
      if (await windowManager.isMinimized()) return;
      final isFullScreen = await windowManager.isFullScreen();
      final isMaximized = await windowManager.isMaximized();
      var bounds = _current.bounds;
      // Only a normal frame is worth remembering — maximized/full-screen
      // bounds are derived from the display, and restoring them as the
      // "normal" frame would make un-maximizing a no-op.
      if (!isFullScreen && !isMaximized) {
        bounds = _storedSpaceFrom(await windowManager.getBounds());
      }
      _current = WindowStateSnapshot(
        bounds: bounds,
        isMaximized: isMaximized,
        isFullScreen: isFullScreen,
      );
      await _store.save(_current);
    } catch (error) {
      debugPrint('Window state save failed: $error');
    }
  }
}
