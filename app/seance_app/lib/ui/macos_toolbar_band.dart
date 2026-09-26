// Ported from Poltergeist app/poltergeist_app/lib/ui/shell/macos_toolbar_band.dart;
// see docs/POLTERGEIST.md. Divergence: without a MacosToolbarBandScope
// there is no band (Poltergeist counts it as shown), because Séance's
// Settings window and its tests have a standard titlebar and no scope.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The height of the titlebar band the empty unified NSToolbar claims on
/// macOS (`MacosTitlebar.install`). The macOS `SeanceChrome.headerHeight`
/// matches it, so the traffic lights sit centred on the header.
const double macosToolbarBandHeight = 52;

/// Publishes whether the band is showing to the widgets that lay out
/// around it. It is gone in full screen, where the runner hides the
/// toolbar (`MacosToolbarBandChannel`): nothing then claims the top 52 pt
/// and no traffic lights sit in the window.
///
/// Only the main window's app has one, and only when the titlebar was
/// installed: without a scope there is no band and no integrated titlebar.
class MacosToolbarBandScope extends InheritedNotifier<ValueListenable<bool>> {
  const MacosToolbarBandScope({
    super.key,
    required ValueListenable<bool> band,
    required super.child,
  }) : super(notifier: band);

  /// Whether this window draws its header under the unified toolbar: on
  /// macOS, with the titlebar installed, in full screen too (where the
  /// band itself is hidden but the header stays at the top).
  static bool unifiedToolbarOf(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.macOS &&
      context.dependOnInheritedWidgetOfExactType<MacosToolbarBandScope>() !=
          null;

  /// Whether the band is showing; rebuilds [context] when that changes.
  static bool visibleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MacosToolbarBandScope>()
          ?.notifier
          ?.value ??
      false;
}

/// What the main window's `MaterialApp.builder` wraps the navigator in:
/// with a [band] (the titlebar is installed), its scope and a reservation
/// above every route; without one, [child] alone.
Widget withMacosToolbarBand(
  ValueListenable<bool>? band, {
  required Widget child,
}) {
  if (band == null) return child;
  return MacosToolbarBandScope(
    band: band,
    child: ReserveMacosToolbarBand(child: child),
  );
}

/// Reserves the macOS toolbar band for everything the root navigator
/// shows: pushed routes, dialogs, sheets, popup menus, and the root
/// overlay's top toasts.
///
/// The band takes every mouse-down for window drag and double-click zoom,
/// except where a `MacosToolbarPassthrough` view hands the click back to
/// Flutter, and only the header and the rail's resize handle register
/// those. Adding the band to `MediaQuery` padding moves every other
/// surface's interactive chrome below it the way a status bar inset would:
/// an `AppBar` grows by the padding and paints its background up into the
/// band, and `showDialog`'s safe area, popup-menu layout, and the toast
/// column's `SafeArea` all keep clear of it. The empty band above them
/// then drags and zooms the window natively, as a titlebar should.
///
/// The wide layout takes the band back with [ClaimMacosToolbarBand]: its
/// header is the one surface meant to draw under it. The narrow layout
/// keeps the reservation, so its app bars sit below the band. Other
/// platforms have no band, so both widgets are no-ops there, and so are
/// they on macOS while [MacosToolbarBandScope] reports the band gone.
class ReserveMacosToolbarBand extends StatelessWidget {
  const ReserveMacosToolbarBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _shiftTop(context, _bandHeight(context), child);
  }
}

/// Takes the band [ReserveMacosToolbarBand] added back out for the wide
/// layout, which draws its header under the band and wraps the header's
/// controls in `MacosToolbarPassthrough`. Without this the layout's safe
/// areas would push its content down a band, and every scroll view in it
/// would pad its top by 52 pt.
///
/// While an opaque route covers the shell, the offstage header's
/// passthrough views stay registered with the window. Clicks on those
/// rects reach Flutter over the covering route's empty band padding, where
/// nothing is interactive, so the only cost is that the window cannot be
/// dragged from those few spots until the route pops.
class ClaimMacosToolbarBand extends StatelessWidget {
  const ClaimMacosToolbarBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _shiftTop(context, -_bandHeight(context), child);
  }
}

/// Zero off macOS and in full screen. The [MediaQuery] from [_shiftTop]
/// stays in the tree either way: dropping it when the band goes would
/// re-parent everything below it and lose its state.
double _bandHeight(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.macOS &&
        MacosToolbarBandScope.visibleOf(context)
    ? macosToolbarBandHeight
    : 0;

Widget _shiftTop(BuildContext context, double delta, Widget child) {
  final data = MediaQuery.of(context);
  double shifted(double top) => (top + delta).clamp(0, double.infinity);
  return MediaQuery(
    data: data.copyWith(
      padding: data.padding.copyWith(top: shifted(data.padding.top)),
      viewPadding: data.viewPadding.copyWith(
        top: shifted(data.viewPadding.top),
      ),
    ),
    child: child,
  );
}
