import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_core/seance_core.dart';

/// The atomic write stages through `<path>.tmp`; a directory there fails every
/// write from now on, at the same point a full disk would, and needs no
/// permission the test process might already hold.
Future<void> blockWrites(File file) =>
    Directory('${file.path}.tmp').create().then((_) {});

Future<void> allowWrites(File file) =>
    Directory('${file.path}.tmp').delete(recursive: true);

Secret secret(String id) =>
    Secret(id: id, kind: SecretKind.password, value: 'value-$id');

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-vault-');
    file = File('${directory.path}/vault.json');
  });

  tearDown(() => directory.delete(recursive: true));

  test('a re-key that cannot be written leaves every credential readable',
      () async {
    final oldKey = secureRandomBytes(32);
    final newKey = secureRandomBytes(32);
    final secrets = [secret('a'), secret('b'), secret('c')];
    final store = FileVaultStore(file);
    await SecretVault(store, oldKey).putSecrets(secrets);

    await blockWrites(file);
    await expectLater(
      SecretVault(store, newKey).putSecrets(secrets),
      throwsA(isA<FileSystemException>()),
    );
    await allowWrites(file);

    // The old key is the one still installed in the keystore, so it is the one
    // the vault has to stay readable with. A per-credential loop would have
    // left the entries written before the failure sealed under a key nothing
    // holds yet, and a restart could not open them again.
    final reopened = SecretVault(FileVaultStore(file), oldKey);
    for (final expected in secrets) {
      expect((await reopened.getSecret(expected.id))!.value, expected.value);
    }
  });

  test('a failed write is not committed by the next successful one', () async {
    final key = secureRandomBytes(32);
    final store = FileVaultStore(file);
    await SecretVault(store, key).putSecret(secret('kept'));

    await blockWrites(file);
    await expectLater(
      SecretVault(store, key).putSecret(secret('refused')),
      throwsA(isA<FileSystemException>()),
    );
    await allowWrites(file);

    // The caller was told "refused" was not stored. The cache is written whole
    // on every mutation, so leaving it there would have let this unrelated
    // write persist it on that caller's behalf.
    await SecretVault(store, key).putSecret(secret('later'));

    final reopened = SecretVault(FileVaultStore(file), key);
    expect(await reopened.getSecret('refused'), isNull);
    expect((await reopened.getSecret('kept'))!.value, 'value-kept');
    expect((await reopened.getSecret('later'))!.value, 'value-later');
  });

  test('a failed delete leaves the entry in place', () async {
    final key = secureRandomBytes(32);
    final store = FileVaultStore(file);
    await SecretVault(store, key).putSecret(secret('kept'));

    await blockWrites(file);
    await expectLater(
      store.deleteSecret('kept'),
      throwsA(isA<FileSystemException>()),
    );
    await allowWrites(file);

    await SecretVault(store, key).putSecret(secret('later'));

    final reopened = SecretVault(FileVaultStore(file), key);
    expect((await reopened.getSecret('kept'))!.value, 'value-kept');
  });
}
