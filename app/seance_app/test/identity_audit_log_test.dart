import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:posix/posix.dart' as posix;
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

  test(
      'a fresh audit log is created owner-only on desktop POSIX', () async {
    // A traversable app directory must not yield a traversable log: the
    // file carries private-key paths.
    posix.chmod(dir.path, _permissiveDirectoryPermissions);
    await IdentityAuditLog(file).record(event(1));
    expect(
        (await file.stat()).mode & _permissionBits, _ownerOnlyFileMode);
  },
      skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);

  test('recording repairs a permissive existing log', () async {
    await file.create();
    posix.chmod(file.path, _permissiveFilePermissions);
    await IdentityAuditLog(file).record(event(1));
    expect(
        (await file.stat()).mode & _permissionBits, _ownerOnlyFileMode);
  },
      skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);

  test('reading repairs a permissive existing log', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    posix.chmod(file.path, _permissiveFilePermissions);

    final entries = await log.readAll();

    expect(entries.map((e) => e.serverId), ['srv-1']);
    expect(
        (await file.stat()).mode & _permissionBits, _ownerOnlyFileMode);
  },
      skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);

  // Linux procfs provides read-side fixtures no fake can: files owned by
  // this process that chmod cannot touch (EPERM) without any host change.
  // Both are this process's non-sensitive metadata — I/O counters and
  // kernel/scheduler status — never environ or memory. Rootless and
  // mountless; they run in the Ubuntu CI flutter job and skip elsewhere
  // because no other desktop platform has /proc.
  test('an already-private chmod-incapable file reads without repair',
      () async {
    final file = File(_procSelfIoPath);
    final modeBefore = (await file.stat()).mode;
    // Fixture prerequisites, asserted loudly: readable and owner-only.
    expect(modeBefore & _groupOtherBits, 0);
    expect(await file.readAsString(), isNotEmpty);

    final entries = await IdentityAuditLog(file).readAll();

    // The counters are not JSON records; the point is that no repair
    // chmod fires (it would fail EPERM here), so a private trail on a
    // chmod-incapable mount stays readable and its mode untouched.
    expect(entries, isEmpty);
    expect((await file.stat()).mode, modeBefore);
  },
      skip: !Platform.isLinux || !File(_procSelfIoPath).existsSync()
          ? 'needs Linux procfs'
          : false);

  test('a permissive chmod-incapable file fails the read closed', () async {
    final file = File(_procSelfStatusPath);
    final modeBefore = (await file.stat()).mode;
    // Fixture prerequisites, asserted loudly: readable with group/other
    // bits set, so the read-side repair must fire.
    expect(modeBefore & _groupOtherBits, isNot(0));
    expect(await file.readAsString(), isNotEmpty);

    // The repair chmod fails EPERM on procfs; failing the read beats
    // returning a world-readable trail. Pinning EPERM — not just the
    // exception type — proves the throw is the repair chmod itself, and
    // the throw (not empty entries; the status text is not JSON) proves
    // the rejection ran.
    final read = IdentityAuditLog(file).readAll();
    await expectLater(
        read,
        throwsA(isA<posix.PosixException>()
            .having((e) => e.code, 'errno', equals(posix.EPERM))));
    expect((await file.stat()).mode, modeBefore);
  },
      skip: !Platform.isLinux || !File(_procSelfStatusPath).existsSync()
          ? 'needs Linux procfs'
          : false);

  test('audit storage stays owner-only on desktop POSIX', () async {
    await file.create();
    posix.chmod(dir.path, _permissiveDirectoryPermissions);
    posix.chmod(file.path, _permissiveFilePermissions);

    // Three writes force the atomic-rotation path at maxEntries 1.
    final log = IdentityAuditLog(file, maxEntries: 1);
    for (var n = 0; n < 3; n++) {
      await log.record(event(n));
    }

    // Privacy belongs to the file, even under a traversable app directory.
    expect((await dir.stat()).mode & _permissionBits,
        _permissiveDirectoryMode);
    expect(
        (await file.stat()).mode & _permissionBits, _ownerOnlyFileMode);
  },
      skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);

  test('malformed lines are skipped, not fatal', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await file.writeAsString('not json\n{"at": 7}\n',
        mode: FileMode.append, flush: true);
    await log.record(event(2));

    final entries = await log.readAll();
    expect(entries.map((e) => e.serverId), ['srv-1', 'srv-2']);
  });

  // A hand edit can leave valid JSON whose field types no longer match —
  // that must skip like any other malformed line, not poison the trail.
  test('wrong-typed fields are skipped, not fatal', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await file.writeAsString(
        '{"at":"2026-07-19T08:00:03.000Z","serverId":"srv-3",'
        '"path":"/Users/ada/.ssh/id_3","ok":"yes"}\n',
        mode: FileMode.append,
        flush: true);
    await log.record(event(2));

    final entries = await log.readAll();
    expect(entries.map((e) => e.serverId), ['srv-1', 'srv-2']);
  });

  test('absent optional fields fall back to their defaults', () async {
    await file.writeAsString(
        '{"at":"2026-07-19T08:00:03.000Z","serverId":"srv-3",'
        '"path":"/Users/ada/.ssh/id_3"}\n',
        flush: true);

    final entries = await IdentityAuditLog(file).readAll();

    expect(entries, hasLength(1));
    expect(entries.single.serverLabel, '');
    expect(entries.single.viaBookmark, isFalse);
    expect(entries.single.ok, isFalse);
    expect(entries.single.error, isNull);
  });

  test('concurrent records are serialized without interleaving', () async {
    final log = IdentityAuditLog(file);
    await Future.wait([for (var n = 0; n < 20; n++) log.record(event(n))]);
    expect(await log.readAll(), hasLength(20));
  });
}

const _permissionBits = 0x1ff;
const _ownerOnlyFileMode = 0x180;
const _permissiveDirectoryMode = 0x1ed;
const _permissiveDirectoryPermissions = '755';
const _permissiveFilePermissions = '644';
const _groupOtherBits = 0x3f; // 0o077: group + other rwx bits.

// This process's own non-sensitive procfs metadata. /proc/self/io is
// owner-only (0400); /proc/self/status is world-readable (0444). procfs
// denies chmod on both with EPERM, so together they pin both read-side
// privacy branches without root, mounts, or touching the host.
const _procSelfIoPath = '/proc/self/io';
const _procSelfStatusPath = '/proc/self/status';
