import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/secure_master_key.dart';

/// A keystore whose answers the test chooses. Overrides only the two methods
/// [MasterKeyManager] uses, so the real code path runs.
class FakeKeystore extends FlutterSecureStorage {
  FakeKeystore({this.readReturns, this.readThrows});

  /// What `read` hands back — null models both "nothing stored" and a platform
  /// that reports a refused read as absence rather than as an error.
  final String? readReturns;

  /// Set to model a platform that throws instead.
  final Object? readThrows;

  final Map<String, String?> written = {};

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
    final thrown = readThrows;
    if (thrown != null) throw thrown;
    return readReturns;
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
    written[key] = value;
  }
}

void main() {
  group('the vault master key', () {
    test('is minted once on a genuine first run', () async {
      final keystore = FakeKeystore();
      final key = await MasterKeyManager(
        keystore,
      ).loadOrCreateFromKeystore(hasExistingVault: false);

      expect(key, hasLength(32));
      expect(keystore.written, hasLength(1));
      expect(base64.decode(keystore.written.values.single!), key);
    });

    test('is read back when the keystore has it', () async {
      final stored = List<int>.generate(32, (i) => i);
      final keystore = FakeKeystore(readReturns: base64.encode(stored));

      expect(
        await MasterKeyManager(keystore).loadOrCreateFromKeystore(
          hasExistingVault: true,
        ),
        stored,
      );
      expect(keystore.written, isEmpty, reason: 'nothing to write');
    });

    test('is never replaced when a vault already exists', () async {
      // The whole point: a keystore that reports nothing while an encrypted
      // vault sits on disk is a keystore that would not hand the key over —
      // minting a new one would make that vault permanently unreadable.
      final keystore = FakeKeystore();

      await expectLater(
        MasterKeyManager(keystore).loadOrCreateFromKeystore(
          hasExistingVault: true,
        ),
        throwsA(isA<MasterKeyUnavailableException>()),
      );
      expect(
        keystore.written,
        isEmpty,
        reason: 'a refused read must not overwrite the key it could not read',
      );
    });

    test('says what happened, and what to do about it', () async {
      final message = const MasterKeyUnavailableException().toString();
      expect(message, contains('vault'));
      expect(message, contains('Always Allow'));
    });

    test('a keystore that throws is left to propagate', () async {
      // A platform that reports refusal as an error needs no guard: the throw
      // already stops startup before anything can be overwritten.
      final keystore = FakeKeystore(readThrows: StateError('keychain denied'));

      await expectLater(
        MasterKeyManager(keystore).loadOrCreateFromKeystore(),
        throwsStateError,
      );
      expect(keystore.written, isEmpty);
    });
  });
}
