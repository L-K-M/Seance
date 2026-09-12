import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// An OS keystore that keeps what it is given, and can be locked the way an
/// auto-login Linux session leaves the login keyring.
class _Keystore extends FlutterSecureStorage {
  _Keystore();
  final Map<String, String> _map = {};
  bool locked = false;

  /// Runs just before a write is accepted, so a test can look at the vault
  /// directory at the exact instant the keystore is about to change.
  Future<void> Function()? onWrite;

  /// The keystore that keeps the value and then reports failure anyway.
  bool throwAfterWrite = false;

  void _check() {
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _check();
    return _map[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _check();
    await onWrite?.call();
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
    if (throwAfterWrite) {
      throw PlatformException(code: 'Unknown', message: 'stored, then failed');
    }
  }
}

Secret secret(String id) =>
    Secret(id: id, kind: SecretKind.password, value: 'value-$id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File vaultFile;
  late File journalFile;
  late List<int> oldKey;
  late List<int> newKey;
  late _Keystore keystore;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-rekey-');
    keystore = _Keystore();
    vaultFile = File('${directory.path}/vault.json');
    journalFile = File('${vaultFile.path}.rekey');
    oldKey = secureRandomBytes(32);
    newKey = secureRandomBytes(32);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  /// The state a process leaves behind when it dies inside the re-key: both
  /// generations staged, and whatever the keystore had got to by then.
  Future<void> crashMidRekey({required List<int> installed}) async {
    final store = FileVaultStore(vaultFile);
    await SecretVault(store, oldKey).putSecrets([secret('a'), secret('b')]);
    await store.stageRekey(currentKey: oldKey, newKey: newKey);
    await MasterKeyManager(keystore).setKeystoreKey(installed);
  }

  group('FileVaultStore re-key journal', () {
    test('a crash before the keystore write leaves the old key working',
        () async {
      await crashMidRekey(installed: oldKey);

      // A fresh store is the next launch: it finds the journal and settles it
      // against the key the keystore actually kept.
      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(oldKey), VaultRekeyOutcome.adopted);
      final vault = SecretVault(reopened, oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect((await vault.getSecret('b'))!.value, 'value-b');
      expect(await journalFile.exists(), isFalse);
    });

    test('a crash after the keystore write leaves the new key working',
        () async {
      await crashMidRekey(installed: newKey);

      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(newKey), VaultRekeyOutcome.adopted);
      final vault = SecretVault(reopened, newKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect((await vault.getSecret('b'))!.value, 'value-b');
      expect(await journalFile.exists(), isFalse);

      // The generation actually committed to the vault file is the new one, so
      // the next launch needs no journal to read it.
      final next = SecretVault(FileVaultStore(vaultFile), newKey);
      expect((await next.getSecret('a'))!.value, 'value-a');
    });

    test('a key matching neither generation drops the journal, not the vault',
        () async {
      await crashMidRekey(installed: oldKey);

      // Neither staged generation can be opened, so neither is recoverable.
      // What matters is that the store does not stay wedged behind a journal
      // nothing can clear.
      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(secureRandomBytes(32)),
          VaultRekeyOutcome.discarded);
      expect(await journalFile.exists(), isFalse);
      expect(await File('${journalFile.path}.corrupt').exists(), isTrue);

      // The stored vault is untouched: staging never wrote it.
      expect(
          (await SecretVault(reopened, oldKey).getSecret('a'))!.value,
          'value-a');
      // And ordinary mutations are allowed again.
      await SecretVault(reopened, oldKey).putSecret(secret('c'));
      expect((await SecretVault(reopened, oldKey).getSecret('c'))!.value,
          'value-c');
    });

    test('a stray or damaged journal never blocks a vault read', () async {
      await SecretVault(FileVaultStore(vaultFile), oldKey)
          .putSecret(secret('a'));
      // The trap this guards: a journal no code path created and none could
      // clear, failing every read from here on.
      await journalFile.writeAsString('not json at all');

      final vault = SecretVault(FileVaultStore(vaultFile), oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);
      expect(await File('${journalFile.path}.corrupt').exists(), isTrue);
    });

    test('an entry the current key cannot open survives the re-key', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('live'));
      // An orphan left sealed under a key nobody holds any more. Re-keying
      // must not fail on it, and must not delete it either.
      await SecretVault(store, secureRandomBytes(32)).putSecret(secret('lost'));

      await store.stageRekey(currentKey: oldKey, newKey: newKey);
      expect(await store.settleRekey(newKey), VaultRekeyOutcome.adopted);

      final vault = SecretVault(store, newKey);
      expect((await vault.getSecret('live'))!.value, 'value-live');
      expect(await store.getSecretBlob('lost'), isNotNull);
    });

    test('credentials are not mutable while a re-key is staged', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      // A write now would persist the stored generation, which settling may
      // then replace with the staged one, silently undoing it.
      await expectLater(
        () => SecretVault(store, oldKey).putSecret(secret('b')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        () => store.stageRekey(currentKey: oldKey, newKey: newKey),
        throwsA(isA<StateError>()),
      );
    });

    test('the journal stores no plaintext', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      final staged = await journalFile.readAsString();
      expect(staged, isNot(contains('value-a')));
      expect(staged, isNot(contains(base64.encode(newKey))));
    });
  });

  group('AppServices settles a re-key the last run left staged', () {
    late AppServices services;

    tearDown(() async => services.probe.dispose());

    test('startup recovers a crash before the keystore write', () async {
      await crashMidRekey(installed: oldKey);

      services = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore));

      expect((await services.vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);
    });

    test('startup recovers a crash after the keystore write', () async {
      await crashMidRekey(installed: newKey);

      services = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore));

      expect((await services.vault.getSecret('a'))!.value, 'value-a');
      expect(services.vaultKey, equals(newKey));
      expect(await journalFile.exists(), isFalse);
    });

    test('a locked keyring keeps the journal for the next unlock', () async {
      await crashMidRekey(installed: newKey);
      keystore.locked = true;

      services = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore));

      // Nothing can be settled without the key, so the vault stays locked and
      // the journal survives to be settled later.
      expect(services.vaultKey, isNull);
      expect(await services.unlockVaultFromKeystore(), isFalse);
      expect(await journalFile.exists(), isTrue);

      keystore.locked = false;
      expect(await services.unlockVaultFromKeystore(), isTrue);
      expect((await services.vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);
    });
  });

  group('AppServices re-keys the vault through the journal', () {
    late AppServices services;

    tearDown(() async => services.probe.dispose());

    /// A vault holding one credential, opened by the key the keystore holds.
    Future<void> enrolled() async {
      await MasterKeyManager(keystore).setKeystoreKey(oldKey);
      await SecretVault(FileVaultStore(vaultFile), oldKey)
          .putSecret(secret('a'));
      services = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore));
    }

    test('both generations are staged before the keystore is changed',
        () async {
      await enrolled();
      // The whole point of the journal is that it is durable *first*. Read the
      // sidecar at the moment the keystore write begins: staged after it, this
      // finds nothing and the crash window is still open.
      String? stagedAtWrite;
      keystore.onWrite = () async {
        if (await journalFile.exists()) {
          stagedAtWrite = await journalFile.readAsString();
        }
      };

      await services.rekeyVaultForTesting(newKey);

      expect(stagedAtWrite, isNotNull);
      expect(stagedAtWrite, contains('"version":1'));
      expect((await services.vault.getSecret('a'))!.value, 'value-a');
      expect(services.vaultKey, equals(newKey));
      expect(await journalFile.exists(), isFalse);
    });

    test('a keyring that refuses the new key leaves the old one working',
        () async {
      await enrolled();
      keystore.locked = true;

      await expectLater(() => services.rekeyVaultForTesting(newKey),
          throwsA(isA<KeystoreException>()));

      // Staging never wrote the vault file, so there is nothing to roll back:
      // the old generation is still the stored one and still the installed key.
      expect(services.vaultKey, equals(oldKey));
      expect((await services.vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);

      keystore.locked = false;
      expect(
          (await SecretVault(FileVaultStore(vaultFile), oldKey)
                  .getSecret('a'))!
              .value,
          'value-a');
    });

    test('a keyring that stores the key and then throws settles on it',
        () async {
      await enrolled();
      keystore.throwAfterWrite = true;

      await expectLater(() => services.rekeyVaultForTesting(newKey),
          throwsA(isA<KeystoreException>()));

      // The keystore kept the new key, so the new generation is the one that
      // has to win, and reading the keystore back is what tells them apart.
      expect(services.vaultKey, equals(newKey));
      expect((await services.vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);

      keystore.throwAfterWrite = false;
      expect(
          (await SecretVault(FileVaultStore(vaultFile), newKey)
                  .getSecret('a'))!
              .value,
          'value-a');
    });
  });
}
