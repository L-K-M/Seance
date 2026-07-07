import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:sqlite3/open.dart';

/// On Linux, distro runtime packages ship `libsqlite3.so.0` but not the
/// unversioned `libsqlite3.so` symlink (that lives in the -dev package). Point
/// the loader at the versioned name so a slim Docker image works without extra
/// symlink gymnastics.
void _configureSqliteLoader() {
  if (!Platform.isLinux) return;
  open.overrideFor(OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open('libsqlite3.so.0');
    } catch (_) {
      return DynamicLibrary.open('libsqlite3.so');
    }
  });
}

Future<void> main(List<String> argv) async {
  _configureSqliteLoader();
  final parser = ArgParser()
    ..addOption('bind', help: 'Address to bind', defaultsTo: null)
    ..addOption('port', abbr: 'p', help: 'Port to listen on')
    ..addOption('db',
        help: 'SQLite database path (omit for in-memory / ephemeral)')
    ..addFlag('open-registration',
        help: 'Allow new accounts via /v1/register', defaultsTo: null)
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args['help'] as bool) {
    stdout.writeln('Séance sync server\n\n${parser.usage}');
    return;
  }

  // Environment first, CLI flags override.
  var settings = ServerSettings.fromEnvironment(Platform.environment);
  settings = settings.copyWith(
    bindAddress: args['bind'] as String?,
    port: args['port'] != null ? int.tryParse(args['port'] as String) : null,
    dbPath: args['db'] as String?,
    openRegistration: args['open-registration'] as bool?,
  );

  final Storage storage = (settings.dbPath == null || settings.dbPath!.isEmpty)
      ? InMemoryStorage()
      : SqliteStorage.open(settings.dbPath!);

  final server = SyncServer(storage: storage, settings: settings);
  final running = await server.start();

  stdout.writeln('Séance sync server listening on '
      'http://${running.host}:${running.port}');
  stdout.writeln('  open registration: ${settings.openRegistration}');
  stdout.writeln('  storage: ${settings.dbPath ?? 'in-memory (ephemeral)'}');
  stdout.writeln('Run behind a TLS-terminating reverse proxy in production.');

  // Shut down cleanly on SIGINT/SIGTERM.
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      stdout.writeln('\nShutting down…');
      await running.close();
      exit(0);
    });
  }
}
