import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:seance_core/seance_core.dart';

/// Thrown when the OS keystore reports no master key but an encrypted vault is
/// already on disk.
///
/// The two situations are indistinguishable from the keystore alone — a first
/// run and a keystore that will not hand the key over both read as "nothing
/// there" — and the difference is total: minting a fresh key in the second
/// case makes every stored password and private key permanently
/// undecryptable. So the vault itself is the tiebreaker, and this refuses to
/// start rather than guess.
///
/// On macOS the realistic cause is the login-keychain prompt being dismissed
/// or denied. Séance is ad-hoc signed, so its keychain ACL is bound to an
/// exact code hash and every rebuild you install asks again.
class MasterKeyUnavailableException implements Exception {
  const MasterKeyUnavailableException();

  @override
  String toString() =>
      'The vault master key could not be read from the system keystore, but '
      'an encrypted vault already exists. Séance stopped rather than create a '
      'new key, which would make your saved passwords and private keys '
      'unreadable. On macOS this is usually a keychain prompt that was '
      'dismissed or denied — relaunch and choose "Always Allow".';
}

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
      : _storage = storage ??
            const FlutterSecureStorage(
              // macOS: use the legacy login keychain, not the iOS-style
              // data-protection keychain. The latter requires a
              // keychain-access-groups entitlement — a *restricted*
              // entitlement that macOS only honors for team-signed builds, so
              // an ad-hoc "sign to run locally" app either throws -34018 at
              // the first read (entitlement absent) or refuses to launch at
              // all (entitlement present but unvalidated).
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  Future<bool> hasKeystoreKey() async =>
      (await _storage.read(key: _keyName)) != null;

  /// Load the device master key from the OS keystore, creating one on first
  /// run.
  ///
  /// [hasExistingVault] is what makes "first run" distinguishable from "the
  /// keystore said no": pass true when an encrypted vault is already on disk,
  /// and a missing key becomes a [MasterKeyUnavailableException] instead of a
  /// brand-new key that would strand it. Depending on the platform a refused
  /// read may throw instead of returning null — this guard holds either way,
  /// which is why it does not try to tell those apart.
  Future<List<int>> loadOrCreateFromKeystore({
    bool hasExistingVault = false,
  }) async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null) return base64.decode(existing);
    if (hasExistingVault) throw const MasterKeyUnavailableException();
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
