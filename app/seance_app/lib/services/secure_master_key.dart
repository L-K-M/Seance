import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:seance_core/seance_core.dart';

/// Obtains the 32-byte vault master key using the layered model from the
/// proposal:
///   1. a random key stored in the OS keystore (macOS/iOS Keychain, Windows
///      Credential Manager, Android Keystore, Linux Secret Service), or
///   2. a passphrase-derived key (Argon2id) as the fallback for headless Linux
///      or a lost keystore entry — which is also the sync E2E key.
class MasterKeyManager {
  final FlutterSecureStorage _storage;
  static const _keyName = 'seance.vault.masterKey.v1';

  MasterKeyManager([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<bool> hasKeystoreKey() async =>
      (await _storage.read(key: _keyName)) != null;

  /// Load the device master key from the OS keystore, creating one on first run.
  Future<List<int>> loadOrCreateFromKeystore() async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null) return base64.decode(existing);
    final key = secureRandomBytes(32);
    await _storage.write(key: _keyName, value: base64.encode(key));
    return key;
  }

  /// Replace the stored master key (used when sync enrolment switches the vault
  /// to the passphrase-derived key that is shared across devices).
  Future<void> setKeystoreKey(List<int> key) =>
      _storage.write(key: _keyName, value: base64.encode(key));

  /// Derive the vault key from a master passphrase (fallback / sync enrolment).
  /// The returned [VaultKeys.vaultKey] unlocks the local vault; the
  /// [VaultKeys.authVerifier] authenticates to the sync server.
  Future<VaultKeys> deriveFromPassphrase(
    String passphrase,
    List<int> salt, {
    Argon2Params params = const Argon2Params(),
  }) =>
      VaultCrypto.deriveKeys(
          passphrase: passphrase, salt: salt, params: params);

  /// Store an API key (LLM provider) in the OS keystore under [name]. Never
  /// synced.
  Future<void> putApiKey(String name, String value) =>
      _storage.write(key: 'seance.apikey.$name', value: value);

  Future<String?> getApiKey(String name) =>
      _storage.read(key: 'seance.apikey.$name');
}
