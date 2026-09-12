import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryVaultStore store;
  late List<int> key;
  late SecretVault vault;

  setUp(() {
    store = InMemoryVaultStore();
    key = secureRandomBytes(32);
    vault = SecretVault(store, key);
  });

  const original = Secret(
    id: 'secret',
    kind: SecretKind.privateKey,
    value: 'PEM',
    keyPassphrase: 'phrase',
  );

  test('credential versions survive reopening and unchanged saves', () async {
    await vault.putLocalSecret(original, updatedAt: 10);
    vault = SecretVault(store, key);
    await vault.putLocalSecret(original, updatedAt: 20);

    expect((await vault.getSecret('secret'))!.updatedAt, 10);
  });

  for (final changed in [
    original.copyWith(value: 'other PEM'),
    original.copyWith(kind: SecretKind.password),
    original.copyWith(keyPassphrase: 'other phrase'),
    const Secret(id: 'secret', kind: SecretKind.privateKey, value: 'PEM'),
  ]) {
    test('changing credential material advances a timestamp behind its peer '
        '(${changed.kind}, passphrase=${changed.keyPassphrase != null})',
        () async {
      await vault.putSecret(original.copyWith(updatedAt: 100));
      await vault.putLocalSecret(changed, updatedAt: 10);

      final saved = (await vault.getSecret('secret'))!;
      expect(saved.toJson(), changed.copyWith(updatedAt: 101).toJson());
    });
  }

  test('legacy unchanged material stays unversioned until a real edit', () async {
    await vault.putSecret(original);
    await vault.putLocalSecret(original, updatedAt: 30);
    expect((await vault.getSecret('secret'))!.updatedAt, 0);

    await vault.putLocalSecret(original.copyWith(value: 'new'), updatedAt: 40);
    expect((await vault.getSecret('secret'))!.updatedAt, 40);
  });

  test('reencrypting a credential preserves its version', () async {
    await vault.putLocalSecret(original, updatedAt: 10);
    final secret = (await vault.getSecret('secret'))!;
    final rekeyed = SecretVault(store, secureRandomBytes(32));
    await rekeyed.putSecret(secret);

    expect((await rekeyed.getSecret('secret'))!.toJson(), secret.toJson());
  });

  group('readableSecret', () {
    // At the vault rather than only through a sync round: all three answers
    // matter to the caller, and a change here should fail pointing at the
    // vault instead of surfacing as a puzzling coordinator failure.
    test('absent reads as null', () async {
      expect(await vault.readableSecret('missing'), isNull);
    });

    test('an entry that will not open reads as null', () async {
      await SecretVault(store, secureRandomBytes(32))
          .putSecret(original.copyWith(value: 'sealed under another key'));

      await expectLater(vault.getSecret('secret'), throwsA(isA<Exception>()));
      expect(await vault.readableSecret('secret'), isNull);
    });

    test('a healthy entry reads through unchanged', () async {
      await vault.putLocalSecret(original, updatedAt: 10);

      final read = await vault.readableSecret('secret');
      expect(read!.toJson(), (await vault.getSecret('secret'))!.toJson());
    });
  });
}
