import 'package:seance_protocol/seance_protocol.dart';

/// One `Host` block parsed from an OpenSSH `config` file.
class ImportedHost {
  final String alias;
  final String? hostName;
  final int? port;
  final String? user;
  final String? identityFile;
  final String? proxyJump;

  const ImportedHost({
    required this.alias,
    this.hostName,
    this.port,
    this.user,
    this.identityFile,
    this.proxyJump,
  });

  /// Effective hostname to connect to (falls back to the alias, as ssh does).
  String get effectiveHost => hostName ?? alias;

  /// Build a Séance [ServerConfig] from this entry. An `IdentityFile` becomes a
  /// "reference, don't store" private-key config; otherwise we default to
  /// ssh-agent, the lowest-risk mode.
  ServerConfig toServerConfig({required String id, required int now}) {
    final hasKey = identityFile != null && identityFile!.trim().isNotEmpty;
    return ServerConfig(
      id: id,
      label: alias,
      host: effectiveHost,
      port: port ?? 22,
      username: user ?? '',
      authMethod: hasKey ? AuthMethod.privateKey : AuthMethod.agent,
      identityFilePath: hasKey ? identityFile : null,
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// A read-only importer for `~/.ssh/config`. Parses the common directives
/// (`Host`, `HostName`, `Port`, `User`, `IdentityFile`, `ProxyJump`) and skips
/// everything else. Wildcard-only host patterns (e.g. `Host *`) are dropped,
/// since they describe defaults rather than a connectable server.
class SshConfigImporter {
  /// Parse the text of an ssh config file into importable hosts.
  static List<ImportedHost> parse(String text) {
    final blocks = <_Block>[];
    _Block? current;

    for (var raw in text.split('\n')) {
      final line = _stripComment(raw).trim();
      if (line.isEmpty) continue;

      final (key, value) = _splitKeyValue(line);
      if (key == null) continue;
      final lower = key.toLowerCase();

      if (lower == 'host') {
        // A Host line may list several patterns; keep them all for filtering.
        current = _Block(patterns: _tokenize(value));
        blocks.add(current);
      } else if (lower == 'match') {
        // Match blocks are conditional; ignore their directives for import.
        current = null;
      } else if (current != null) {
        current.directives[lower] = value;
      }
    }

    final hosts = <ImportedHost>[];
    for (final block in blocks) {
      final alias = block.patterns.firstWhere(
        (p) => !_isWildcard(p),
        orElse: () => '',
      );
      if (alias.isEmpty) continue; // wildcard-only block: defaults, not a host
      final d = block.directives;
      hosts.add(ImportedHost(
        alias: alias,
        hostName: d['hostname'],
        port: d['port'] != null ? int.tryParse(d['port']!) : null,
        user: d['user'],
        identityFile: _expandTilde(d['identityfile']),
        proxyJump: d['proxyjump'],
      ));
    }
    return hosts;
  }

  static String _stripComment(String line) {
    final idx = line.indexOf('#');
    return idx >= 0 ? line.substring(0, idx) : line;
  }

  /// Split `Key value` or `Key=value`, tolerating the leading whitespace and
  /// optional `=` that ssh_config allows.
  static (String?, String) _splitKeyValue(String line) {
    final eq = line.indexOf('=');
    final sp = line.indexOf(RegExp(r'\s'));
    int cut;
    if (eq >= 0 && (sp < 0 || eq < sp)) {
      cut = eq;
    } else if (sp >= 0) {
      cut = sp;
    } else {
      return (null, '');
    }
    final key = line.substring(0, cut).trim();
    final value = line.substring(cut + 1).trim().replaceAll('"', '');
    if (key.isEmpty) return (null, '');
    return (key, value);
  }

  static List<String> _tokenize(String value) =>
      value.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

  static bool _isWildcard(String pattern) =>
      pattern.contains('*') || pattern.contains('?') || pattern.startsWith('!');

  static String? _expandTilde(String? path) {
    if (path == null) return null;
    // Leave ~ in place; the app resolves it against the real home directory,
    // which this pure package must not assume.
    return path;
  }
}

class _Block {
  final List<String> patterns;
  final Map<String, String> directives = {};
  _Block({required this.patterns});
}
