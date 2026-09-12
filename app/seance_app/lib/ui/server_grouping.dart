/// Sectioning for the server list.
///
/// Kept free of Flutter, like [server_filter.dart], so the rules that decide
/// what the list looks like can be unit-tested without pumping a widget.
///
/// The shape of the feature is that grouping costs nothing until it is used:
/// with no server filed anywhere, [groupServers] returns one anonymous section
/// and the pane renders exactly the flat list it always did — no headers, no
/// indentation, nothing to collapse.
library;

import 'package:seance_core/seance_core.dart';

/// The key of the section holding servers with no group.
///
/// Empty is safe as a sentinel because a real group key never is:
/// [normalizeServerGroup] turns a blank or whitespace-only name into null,
/// which is what puts a server in this section in the first place.
const String kUngroupedKey = '';

/// The header shown over the servers that aren't in any group. Only ever
/// rendered when at least one *other* group exists — see [groupServers].
const String kUngroupedLabel = 'Ungrouped';

/// The key of the pinned shortlist.
///
/// A leading space cannot collide with a real group key: [normalizeServerGroup]
/// trims, so no group — not even one the user literally names "Pinned" — can
/// produce this. That is what lets the pinned section be folded away through
/// the same `collapsedServerGroups` set as every other section.
const String kPinnedKey = ' pinned';

/// The header over the pinned shortlist, which is always the first section.
const String kPinnedLabel = 'Pinned';

/// The header over everything that is *not* pinned, when nothing is grouped.
///
/// With real groups in play the leftovers keep [kUngroupedLabel] instead:
/// there, "ungrouped" is what they actually are. Here it would claim a feature
/// the user has not used.
const String kUnpinnedLabel = 'Other servers';

/// One section of the server list.
class ServerGroupSection {
  /// The group's name as the user spelled it, or null for a section that is
  /// not a user-named group: the pinned shortlist, or the remainder.
  final String? name;

  /// Members, in the order they arrived (the store sorts by label).
  final List<ServerConfig> servers;

  /// The identity this section is collapsed and re-found by, stable across a
  /// re-sort and across a member being renamed.
  final String key;

  /// The text of this section's header, or null for the one anonymous section
  /// a flat list with nothing pinned collapses to — which draws no header at
  /// all, and so can never be collapsed into nothing.
  ///
  /// Resolved here rather than at the row, because only [groupServers] knows
  /// whether the remainder is "Ungrouped" (beside real groups) or
  /// "Other servers" (beside nothing but pins).
  final String? header;

  const ServerGroupSection({
    required this.name,
    required this.servers,
    required this.key,
    required this.header,
  });
}

/// [servers] split into sections: the pinned shortlist first, then one section
/// per group sorted by name, with the ungrouped remainder last.
///
/// Returns a single unnamed section when nothing is pinned and no server
/// carries a group, so the common case renders as a plain list rather than as
/// one section that happens to hold everything.
///
/// Grouping is case-insensitive ([serverGroupKey]); the spelling shown is the
/// one on the first member in [servers] order, so a group does not rename
/// itself when a member is edited elsewhere in the list.
///
/// A pinned server leaves its group for the shortlist rather than appearing
/// twice: "pinned to the top" and "still filed under Production" cannot both
/// be true of one row, and a duplicate row is the kind of thing a user fixes
/// by unpinning. Its group's count drops accordingly, which is honest about
/// what folding that group away now hides.
List<ServerGroupSection> groupServers(
  List<ServerConfig> servers, {
  Set<String> pinnedIds = const {},
}) {
  // Order within the shortlist is the list's own (the store sorts by label),
  // not the order things were pinned in — a shortlist that reshuffles itself
  // as you pin is harder to aim at than one that stays alphabetical.
  final pinned = [
    for (final server in servers)
      if (pinnedIds.contains(server.id)) server,
  ];
  if (pinned.isEmpty) return _groupSections(servers, anonymous: true);

  final rest = [
    for (final server in servers)
      if (!pinnedIds.contains(server.id)) server,
  ];
  return [
    ServerGroupSection(
      name: null,
      servers: pinned,
      key: kPinnedKey,
      header: kPinnedLabel,
    ),
    ..._groupSections(rest, anonymous: false),
  ];
}

/// The group sections of [servers].
///
/// [anonymous] is true only when this is the whole list: a list with no groups
/// then renders headerless. With a pinned section above it the remainder needs
/// a header of its own, or the rows after the shortlist would read as still
/// being part of it.
List<ServerGroupSection> _groupSections(
  List<ServerConfig> servers, {
  required bool anonymous,
}) {
  final byKey = <String, List<ServerConfig>>{};
  final names = <String, String>{};
  final ungrouped = <ServerConfig>[];

  for (final server in servers) {
    final group = normalizeServerGroup(server.group);
    if (group == null) {
      ungrouped.add(server);
      continue;
    }
    final key = serverGroupKey(group);
    byKey.putIfAbsent(key, () => []).add(server);
    names.putIfAbsent(key, () => group);
  }

  if (byKey.isEmpty) {
    // Everything is pinned: no remainder to head. Only reachable when a
    // pinned section already exists, so the list is never left with nothing.
    if (servers.isEmpty && !anonymous) return const [];
    return [
      ServerGroupSection(
        name: null,
        servers: servers,
        key: kUngroupedKey,
        header: anonymous ? null : kUnpinnedLabel,
      ),
    ];
  }

  final keys = byKey.keys.toList()..sort();
  return [
    for (final key in keys)
      ServerGroupSection(
        name: names[key],
        servers: byKey[key]!,
        key: serverGroupKey(names[key]!),
        header: names[key],
      ),
    if (ungrouped.isNotEmpty)
      ServerGroupSection(
        name: null,
        servers: ungrouped,
        key: kUngroupedKey,
        header: kUngroupedLabel,
      ),
  ];
}

/// One rendered line of the server list: either a group header or a server.
sealed class ServerListRow {
  const ServerListRow();
}

/// A collapsible section header. Not emitted for a list with no groups.
final class ServerGroupHeaderRow extends ServerListRow {
  /// The name to show — [kUngroupedLabel] for the ungrouped section.
  final String name;
  final String key;

  /// Members in the section, shown beside the name so a collapsed group still
  /// says how much it is hiding.
  final int count;
  final bool collapsed;

  const ServerGroupHeaderRow({
    required this.name,
    required this.key,
    required this.count,
    required this.collapsed,
  });
}

final class ServerRow extends ServerListRow {
  final ServerConfig server;
  const ServerRow(this.server);
}

/// Flatten [sections] into the rows to render, dropping the members of any
/// section whose key is in [collapsedKeys].
///
/// A section that is collapsed still emits its header — that is the only way
/// back. A section with no header emits none, and so can never be collapsed
/// into nothing.
List<ServerListRow> serverListRows({
  required List<ServerGroupSection> sections,
  required Set<String> collapsedKeys,
}) {
  final rows = <ServerListRow>[];
  for (final section in sections) {
    final header = section.header;
    var collapsed = false;
    if (header != null) {
      collapsed = collapsedKeys.contains(section.key);
      rows.add(ServerGroupHeaderRow(
        name: header,
        key: section.key,
        count: section.servers.length,
        collapsed: collapsed,
      ));
    }
    if (collapsed) continue;
    for (final server in section.servers) {
      rows.add(ServerRow(server));
    }
  }
  return rows;
}

/// The distinct group names in [servers], sorted, for offering existing groups
/// in the editor instead of making the user retype (and misspell) one.
List<String> existingServerGroups(List<ServerConfig> servers) {
  final names = <String, String>{};
  for (final server in servers) {
    final group = normalizeServerGroup(server.group);
    if (group != null) names.putIfAbsent(serverGroupKey(group), () => group);
  }
  final keys = names.keys.toList()..sort();
  return [for (final key in keys) names[key]!];
}
