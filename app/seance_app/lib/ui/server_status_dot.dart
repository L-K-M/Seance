/// The one status dot a server row composes into its mark.
///
/// The sibling contract (Poltergeist's plan, 10 §5 and §10) gives both apps
/// the same dot for the same truth, so a server that shows in Séance's rail
/// and in Poltergeist's SERVERS reads identically in each:
///
/// - connected: solid green
/// - connecting: solid amber
/// - failed: solid red
/// - blocked (the host key no longer matches the pinned one): a red dot
///   crossed by a bar, the kit's no-entry sign, as Poltergeist draws it
/// - reachable (the probe answered, nothing is connected): a hollow green
///   ring
/// - unknown, or idle with no probe answer: no dot
///
/// Séance's probe also reports hosts it could not reach, which the contract
/// leaves open. They draw a hollow red ring: hollow because it is the same
/// weaker, observed kind of fact as "reachable", red because a solid red dot
/// already means a session failed.
library;

import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'sidebar/sidebar_kit.dart';

enum ServerDot {
  none,
  connected,
  connecting,
  failed,
  blocked,
  reachable,
  unreachable;

  /// What the dot says, folded into the row's tooltip and spoken label
  /// (the row's visuals are excluded from semantics). Null for no dot.
  String? get description => switch (this) {
    ServerDot.none => null,
    ServerDot.connected => 'Connected',
    ServerDot.connecting => 'Connecting',
    ServerDot.failed => 'Connection failed',
    ServerDot.blocked => 'Connection blocked',
    ServerDot.reachable => 'Host reachable',
    ServerDot.unreachable => 'Host unreachable',
  };

  /// What to do about the state, where the state alone does not say it:
  /// folded into the tooltip and label after [description].
  String? get detail => switch (this) {
    ServerDot.blocked =>
      'The host key changed. Review it at the next connection attempt.',
    _ => null,
  };

  /// Live session truth is solid; a probe's observation is a ring; a
  /// refusal the user has to act on is the no-entry sign.
  SidebarDotStyle get style => switch (this) {
    ServerDot.reachable || ServerDot.unreachable => SidebarDotStyle.ring,
    ServerDot.blocked => SidebarDotStyle.blocked,
    _ => SidebarDotStyle.solid,
  };

  /// The colour to paint, or null for no dot.
  Color? color(BuildContext context) => switch (this) {
    ServerDot.none => null,
    ServerDot.connected || ServerDot.reachable => StatusColors.online(context),
    ServerDot.connecting => StatusColors.connecting(context),
    ServerDot.failed ||
    ServerDot.blocked ||
    ServerDot.unreachable => StatusColors.offline(context),
  };
}

/// The dot for a server whose terminal sessions aggregate to [session]
/// (null when it has none) and whose last probe said [probe]; a failed
/// session that [hostKeyBlocked] reads as blocked rather than failed.
///
/// A live session outranks the probe: a connected server is connected even
/// if the last probe timed out. A session that ended cleanly is idle, and
/// the probe speaks again.
ServerDot serverDotFor({
  required TerminalStatus? session,
  required ProbeStatus probe,
  bool hostKeyBlocked = false,
}) {
  switch (session) {
    case TerminalStatus.connected:
      return ServerDot.connected;
    case TerminalStatus.connecting:
      return ServerDot.connecting;
    case TerminalStatus.error:
      return hostKeyBlocked ? ServerDot.blocked : ServerDot.failed;
    case TerminalStatus.disconnected || null:
      return switch (probe) {
        ProbeStatus.online => ServerDot.reachable,
        ProbeStatus.offline => ServerDot.unreachable,
        ProbeStatus.unknown => ServerDot.none,
      };
  }
}

/// Aggregate a server's terminal tabs into the one state its row shows: any
/// connecting wins, else any connected, else any error, else disconnected.
/// Null when the server has no terminal tab at all.
TerminalStatus? aggregateSessionStatus(Iterable<TerminalSession> tabs) {
  if (tabs.isEmpty) return null;
  if (tabs.any((t) => t.status == TerminalStatus.connecting)) {
    return TerminalStatus.connecting;
  }
  if (tabs.any((t) => t.status == TerminalStatus.connected)) {
    return TerminalStatus.connected;
  }
  if (tabs.any((t) => t.status == TerminalStatus.error)) {
    return TerminalStatus.error;
  }
  return TerminalStatus.disconnected;
}
