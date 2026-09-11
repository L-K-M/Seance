import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:seance_app/services/app_services.dart' show LockedSecretVault;
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_core/seance_core.dart';

/// A keystore in the exact state the Ubuntu bug report hit: every access
/// throws the libsecret "KeyringLocked" PlatformException.
class _LockedKeystore extends FlutterSecureStorage {
  _LockedKeystore();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');

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
  }) =>
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
}

/// In-memory keystore that can be "locked" on demand, to test the recovery
/// transition (keyring gets unlocked while the app runs).
class _ToggleableKeystore extends FlutterSecureStorage {
  _ToggleableKeystore();
  final Map<String, String> _map = {};
  bool locked = false;

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
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
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
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

void main() {
  group('MasterKeyManager on a locked keystore (the Ubuntu KeyringLocked bug)',
      () {
    test('probeKeystore returns null and marks the keystore unavailable',
        () async {
      final keys = MasterKeyManager(_LockedKeystore());
      final key = await keys.probeKeystore();
      expect(key, isNull);
      expect(keys.keystoreStatus, KeystoreStatus.unavailable);
      expect(keys.lastKeystoreError, contains('KeyringLocked'));
    });

    test('reads degrade to "not set" instead of throwing', () async {
      final keys = MasterKeyManager(_LockedKeystore());
      expect(await keys.getApiKey('anthropic'), isNull);
      expect(await keys.hasKeystoreKey(), isFalse);
      expect(keys.keystoreStatus, KeystoreStatus.unavailable);
    });

    test('writes throw a clear KeystoreException', () async {
      final keys = MasterKeyManager(_LockedKeystore());
      await expectLater(
        () => keys.putApiKey('anthropic', 'sk-test'),
        throwsA(
          isA<KeystoreException>()
              .having((e) => e.message, 'message', contains('keyring')),
        ),
      );
      expect(keys.keystoreStatus, KeystoreStatus.unavailable);
    });

    test('a keystore that comes back is picked up on re-probe', () async {
      final storage = _ToggleableKeystore()..locked = true;
      final keys = MasterKeyManager(storage);

      expect(await keys.probeKeystore(), isNull);
      expect(keys.keystoreStatus, KeystoreStatus.unavailable);

      storage.locked = false;
      final key = await keys.probeKeystore();
      expect(key, isNotNull);
      expect(key, hasLength(32));
      expect(keys.keystoreStatus, KeystoreStatus.available);
      expect(keys.lastKeystoreError, isNull);

      // The created key persists: a second probe returns the same one.
      expect(await keys.probeKeystore(), equals(key));
    });

    test('probeKeystore never fabricates an ephemeral key while locked',
        () async {
      // Regression guard for the tempting wrong fix: if probeKeystore had
      // returned a fresh random key under a locked keystore, anything saved
      // this session would decrypt to garbage (or appear corrupt) forever
      // after — "unavailable" is the only honest answer.
      final keys = MasterKeyManager(_LockedKeystore());
      expect(await keys.probeKeystore(), isNull);
      expect(await keys.probeKeystore(), isNull);
    });
  });

  group('LockedSecretVault', () {
    test('reads and writes throw VaultLockedException; deletes work', () async {
      final vault = LockedSecretVault(InMemoryVaultStore());
      await expectLater(
        () => vault.getSecret('any'),
        throwsA(isA<VaultLockedException>()),
      );
      await expectLater(
        () => vault.putSecret(
          Secret(id: 's1', kind: SecretKind.password, value: 'x'),
        ),
        throwsA(isA<VaultLockedException>()),
      );
      // Deleting needs no key and must not throw.
      await vault.deleteSecret('any');
    });

    test('the locked message tells the user what to do', () {
      expect(
        const VaultLockedException().toString(),
        allOf(contains('keyring'), contains('gnome-keyring')),
      );
    });
  });
}
