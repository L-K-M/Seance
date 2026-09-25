/// Sectioning for the server list.
///
/// Kept free of Flutter, like [server_filter.dart], so the rules that decide
/// what the list looks like can be unit-tested without pumping a widget.
///
/// The shape is the sibling rail's (Poltergeist's plan, 10 §5): a PINNED
/// section when anything is pinned, then SERVERS — its ungrouped servers
/// first, then one nested disclosure row per group, sorted by name.
/// Ungrouped servers lead so an expanded group's members, indented under it,
/// are never followed by rows that only look like more of that group.
library;

import 'package:seance_core/seance_core.dart';

/// The key of the pinned shortlist.
///
/// A leading space cannot collide with a real group key: [normalizeServerGroup]
/// trims, so no group — not even one the user literally names "Pinned" — can
/// produce this. That is what lets the pinned section be folded away through
/// the same `collapsedServerGroups` set as every other section.
const String kPinnedKey = ' pinned';

/// The key of the SERVERS section itself, collision-free for the same reason
/// as [kPinnedKey].
const String kServersKey = ' servers';

/// The section headers' titles (drawn in caps; announced as spelled).
const String kPinnedLabel = 'Pinned';
const String kServersLabel = 'Servers';

/// One named group under SERVERS.
class ServerGroupSection {
  /// The group's name as the user spelled it.
  final String name;

  /// Members, in the order they arrived (the store sorts by label).
  final List<ServerConfig> servers;

  /// The identity this group is collapsed and re-found by, stable across a
  /// re-sort and across a member being renamed.
  final String key;

  const ServerGroupSection({
    required this.name,
    required this.servers,
    required this.key,
  });
}

/// The rail's sections for one list of servers.
class ServerSidebarSections {
  /// The pinned shortlist, in the list's own order.
  final List<ServerConfig> pinned;

  /// SERVERS' members that are in no group.
  final List<ServerConfig> ungrouped;

  /// SERVERS' named groups, sorted by key.
  final List<ServerGroupSection> groups;

  const ServerSidebarSections({
    required this.pinned,
    required this.ungrouped,
    required this.groups,
  });

  /// Everything under SERVERS: what its header counts while collapsed.
  int get unpinnedCount =>
      ungrouped.length +
      groups.fold<int>(0, (sum, group) => sum + group.servers.length);
}

/// [servers] split into the rail's sections.
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
ServerSidebarSections groupServers(
  List<ServerConfig> servers, {
  Set<String> pinnedIds = const {},
}) {
  // Order within the shortlist is the list's own (the store sorts by label),
  // not the order things were pinned in — a shortlist that reshuffles itself
  // as you pin is harder to aim at than one that stays alphabetical.
  final pinned = <ServerConfig>[];
  final ungrouped = <ServerConfig>[];
  final byKey = <String, List<ServerConfig>>{};
  final names = <String, String>{};

  for (final server in servers) {
    if (pinnedIds.contains(server.id)) {
      pinned.add(server);
      continue;
    }
    final group = normalizeServerGroup(server.group);
    if (group == null) {
      ungrouped.add(server);
      continue;
    }
    final key = serverGroupKey(group);
    byKey.putIfAbsent(key, () => []).add(server);
    names.putIfAbsent(key, () => group);
  }

  final keys = byKey.keys.toList()..sort();
  return ServerSidebarSections(
    pinned: pinned,
    ungrouped: ungrouped,
    groups: [
      for (final key in keys)
        ServerGroupSection(name: names[key]!, servers: byKey[key]!, key: key),
    ],
  );
}

/// One rendered line of the server list.
sealed class ServerListRow {
  const ServerListRow();
}

/// A top-level section header: PINNED or SERVERS.
final class ServerSectionRow extends ServerListRow {
  final String title;
  final String key;

  /// Members in the section, shown while it is collapsed so a folded section
  /// still says how much it is hiding.
  final int count;
  final bool collapsed;

  const ServerSectionRow({
    required this.title,
    required this.key,
    required this.count,
    required this.collapsed,
  });
}

/// A group's nested disclosure row under SERVERS.
final class ServerGroupHeaderRow extends ServerListRow {
  final String name;
  final String key;
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

  /// 1 under a group's disclosure row, 0 elsewhere.
  final int depth;

  const ServerRow(this.server, {this.depth = 0});
}

/// Flatten [sections] into the rows to render, dropping the members of any
/// section or group whose key is in [collapsedKeys].
///
/// A collapsed section or group still emits its header — that is the only
/// way back. A section with no members emits nothing, header included: a
/// PINNED with nothing pinned, or a SERVERS emptied by pinning everything,
/// would be a caption over nothing.
///
/// Except a section named in [keptSections] ([kPinnedKey], [kServersKey]):
/// when [sections] is a filtered list that left it empty, its header stays
/// anyway, counting 0 as every header counts what it draws. That is for a
/// filter that hid a live server there (see [sectionsHoldingLive]), whose
/// header is then the one place its dot can show.
List<ServerListRow> serverListRows({
  required ServerSidebarSections sections,
  required Set<String> collapsedKeys,
  Set<String> keptSections = const {},
}) {
  final rows = <ServerListRow>[];
  if (sections.pinned.isNotEmpty || keptSections.contains(kPinnedKey)) {
    final collapsed = collapsedKeys.contains(kPinnedKey);
    rows.add(
      ServerSectionRow(
        title: kPinnedLabel,
        key: kPinnedKey,
        count: sections.pinned.length,
        collapsed: collapsed,
      ),
    );
    if (!collapsed) rows.addAll(sections.pinned.map(ServerRow.new));
  }

  final unpinned = sections.unpinnedCount;
  if (unpinned == 0 && !keptSections.contains(kServersKey)) return rows;
  final collapsed = collapsedKeys.contains(kServersKey);
  rows.add(
    ServerSectionRow(
      title: kServersLabel,
      key: kServersKey,
      count: unpinned,
      collapsed: collapsed,
    ),
  );
  if (collapsed) return rows;

  rows.addAll(sections.ungrouped.map(ServerRow.new));
  for (final group in sections.groups) {
    final folded = collapsedKeys.contains(group.key);
    rows.add(
      ServerGroupHeaderRow(
        name: group.name,
        key: group.key,
        count: group.servers.length,
        collapsed: folded,
      ),
    );
    if (folded) continue;
    for (final server in group.servers) {
      rows.add(ServerRow(server, depth: 1));
    }
  }
  return rows;
}

/// The sections of [whole] holding a server [isLive] accepts, by key: the
/// ones whose header a filter must not drop along with their rows.
///
/// Poltergeist's rule: a filter that hides every row drops the section,
/// unless a live server is among the hidden, and then its header stays to
/// say so. Only whole sections need it. A group the filter empties goes,
/// and its members fall to SERVERS' header, which this keeps.
Set<String> sectionsHoldingLive(
  ServerSidebarSections whole,
  bool Function(ServerConfig server) isLive,
) => {
  if (whole.pinned.any(isLive)) kPinnedKey,
  if (whole.ungrouped.any(isLive) ||
      whole.groups.any((group) => group.servers.any(isLive)))
    kServersKey,
};

/// The servers of [sections] that each header in [rows] keeps out of view,
/// by the header's key, so a folded group or a filter never hides a live
/// connection without a trace.
///
/// [sections] is the whole list, [rows] what is drawn: a collapsed
/// section's or group's members are hidden, and so are the ones a filter
/// left out when [rows] were built from a filtered list. Each server goes
/// under the innermost header still on screen that holds it (its group's
/// row, else its section's), so a folded group's server marks that group
/// and not SERVERS as well. One whose every header is gone goes nowhere,
/// which only a server that is not live can meet when [rows] kept the
/// sections [sectionsHoldingLive] names.
Map<String, List<ServerConfig>> hiddenByHeader({
  required ServerSidebarSections sections,
  required List<ServerListRow> rows,
}) {
  final shown = <String>{};
  final headers = <String>{};
  for (final row in rows) {
    switch (row) {
      case ServerRow(:final server):
        shown.add(server.id);
      case ServerSectionRow(:final key):
        headers.add(key);
      case ServerGroupHeaderRow(:final key):
        headers.add(key);
    }
  }

  final hidden = <String, List<ServerConfig>>{};
  void hide(ServerConfig server, List<String> keys) {
    if (shown.contains(server.id)) return;
    for (final key in keys) {
      if (!headers.contains(key)) continue;
      (hidden[key] ??= []).add(server);
      return;
    }
  }

  for (final server in sections.pinned) {
    hide(server, const [kPinnedKey]);
  }
  for (final server in sections.ungrouped) {
    hide(server, const [kServersKey]);
  }
  for (final group in sections.groups) {
    for (final server in group.servers) {
      hide(server, [group.key, kServersKey]);
    }
  }
  return hidden;
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
