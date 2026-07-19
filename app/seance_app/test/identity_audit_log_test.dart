import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/identity_audit_log.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('seance-audit-');
    file = File('${dir.path}/identity_reads.jsonl');
  });

  tearDown(() => dir.delete(recursive: true));

  IdentityReadEvent event(int n, {bool ok = true, String? error}) =>
      IdentityReadEvent(
        at: '2026-07-19T08:00:${n.toString().padLeft(2, '0')}.000Z',
        serverId: 'srv-$n',
        serverLabel: 'server $n',
        path: '/Users/ada/.ssh/id_$n',
        viaBookmark: n.isEven,
        ok: ok,
        error: error,
      );

  test('records and reads back events in order, with all fields', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await log.record(event(2, ok: false, error: 'EPERM'));

    final entries = await log.readAll();
    expect(entries, hasLength(2));
    expect(entries[0].serverId, 'srv-1');
    expect(entries[0].viaBookmark, isFalse);
    expect(entries[0].ok, isTrue);
    expect(entries[0].error, isNull);
    expect(entries[1].serverId, 'srv-2');
    expect(entries[1].path, '/Users/ada/.ssh/id_2');
    expect(entries[1].viaBookmark, isTrue);
    expect(entries[1].ok, isFalse);
    expect(entries[1].error, 'EPERM');
  });

  test('an absent file reads as empty', () async {
    expect(await IdentityAuditLog(file).readAll(), isEmpty);
  });

  test('rotation keeps only the newest maxEntries', () async {
    final log = IdentityAuditLog(file, maxEntries: 5);
    for (var n = 0; n < 11; n++) {
      await log.record(event(n));
    }
    // 11 lines crossed 2 * 5, so the file was trimmed to the newest 5.
    final entries = await log.readAll();
    expect(entries, hasLength(5));
    expect(entries.first.serverId, 'srv-6');
    expect(entries.last.serverId, 'srv-10');
  });

  test('malformed lines are skipped, not fatal', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await file.writeAsString('not json\n{"at": 7}\n',
        mode: FileMode.append, flush: true);
    await log.record(event(2));

    final entries = await log.readAll();
    expect(entries.map((e) => e.serverId), ['srv-1', 'srv-2']);
  });

  test('concurrent records are serialized without interleaving', () async {
    final log = IdentityAuditLog(file);
    await Future.wait([for (var n = 0; n < 20; n++) log.record(event(n))]);
    expect(await log.readAll(), hasLength(20));
  });
}
