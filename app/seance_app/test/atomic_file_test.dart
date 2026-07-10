import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/atomic_file.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('seance_atomic_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('writeStringAtomically', () {
    test('creates the parent directory and round-trips content', () async {
      final file = File('${dir.path}/nested/deep/data.json');
      await writeStringAtomically(file, '{"hello":"world"}');
      expect(await file.readAsString(), '{"hello":"world"}');
    });

    test('replaces existing content and leaves no temp file behind', () async {
      final file = File('${dir.path}/data.json');
      await writeStringAtomically(file, 'first');
      await writeStringAtomically(file, 'second');
      expect(await file.readAsString(), 'second');
      expect(await File('${file.path}.tmp').exists(), isFalse);
    });
  });

  group('quarantineCorruptFile', () {
    test('moves the bad file aside to *.corrupt', () async {
      final file = File('${dir.path}/data.json');
      await file.writeAsString('not json');
      await quarantineCorruptFile(file);
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.corrupt').exists(), isTrue);
    });
  });

  group('FileConfigStore resilience', () {
    test('a corrupt servers file does not throw and starts empty', () async {
      final file = File('${dir.path}/servers.json');
      await file.writeAsString('}{ this is not valid json');
      final store = FileConfigStore(file);
      // Must not throw (previously this crashed app startup).
      expect(await store.listServers(), isEmpty);
      // The bad file was quarantined so it can't wedge the next launch either.
      expect(await File('${file.path}.corrupt').exists(), isTrue);
    });

    test('a valid round-trip still works after the atomic-write change',
        () async {
      final file = File('${dir.path}/servers.json');
      final store = FileConfigStore(file);
      final now = DateTime.now().millisecondsSinceEpoch;
      await store.putServer(ServerConfig(
        id: 'a',
        label: 'box',
        host: 'example.com',
        username: 'me',
        authMethod: AuthMethod.password,
        createdAt: now,
        updatedAt: now,
      ));
      final reloaded = FileConfigStore(file);
      final servers = await reloaded.listServers();
      expect(servers, hasLength(1));
      expect(servers.single.host, 'example.com');
    });
  });
}
