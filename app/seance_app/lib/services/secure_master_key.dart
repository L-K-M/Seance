import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:seance_core/seance_core.dart';

/// The OS keystore could not be read or written — on Linux that is usually a
/// locked login keyring (auto-login leaves it locked) or a desktop without a
/// Secret Service daemon (gnome-keyring/KWallet) at all. [message] is
/// user-facing.
class KeystoreException implements Exception {
  final String message;
  const KeystoreException(this.message);
  @override
  String toString() => message;
}

/// The vault has no key this session because the OS keystore is unavailable,
/// so secrets can neither be read nor stored until it comes back.
class VaultLockedException implements Exception {
  final String message;
  const VaultLockedException([
    this.message = 'Saved secrets are unavailable: the OS keyring is locked '
        'or missing. Unlock the login keyring (or install gnome-keyring), '
        'then retry.',
  ]);
  @override
  String toString() => message;
}

/// Whether the OS keystore is reachable right now. Tracked on every access so
/// the app can say "secrets unavailable" and offer a retry instead of dying
/// at bootstrap (the original `KeyringLocked` hard-fail).
enum KeystoreStatus { unknown, available, unavailable }

/// Obtains the 32-byte vault master key using the layered model from the
/// proposal:
///   1. a random key stored in the OS keystore (macOS/iOS Keychain, Windows
///      Credential Manager, Android Keystore, Linux Secret Service), or
///   2. a passphrase-derived key (Argon2id) as the fallback for headless Linux
///      or a lost keystore entry — which is also the sync E2E key.
class MasterKeyManager {
  final FlutterSecureStorage _storage;
  static const _keyName = 'seance.vault.masterKey.v1';

  /// Last observed keystore health. The bootstrap toast keys off this.
  KeystoreStatus keystoreStatus = KeystoreStatus.unknown;

  /// One-line description of the most recent keystore failure
  /// (e.g. `KeyringLocked`) for display in the retry toast.
  String? lastKeystoreError;

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

  void _markAvailable() {
    keystoreStatus = KeystoreStatus.available;
    lastKeystoreError = null;
  }

  void _markUnavailable(Object e) {
    keystoreStatus = KeystoreStatus.unavailable;
    lastKeystoreError = _describe(e);
  }

  /// A compact description of a keystore failure. flutter_secure_storage on
  /// Linux reports libsecret errors as PlatformException(code: message:), so
  /// for the common case ("KeyringLocked"/"KeyringLocked") the code alone is
  /// the whole story.
  static String _describe(Object e) {
    if (e is PlatformException) {
      final msg = e.message;
      return msg != null && msg != e.code ? '${e.code} — $msg' : e.code;
    }
    return e.toString();
  }

  /// Load the device master key from the OS keystore, creating one on first
  /// run. Returns null when the keystore is unavailable right now —
  /// [keystoreStatus]/[lastKeystoreError] say why. Deliberately does NOT
  /// fabricate an ephemeral key: anything encrypted with a key that dies with
  /// the process would be silently orphaned on the next launch, which is a
  /// far worse failure than "secrets are temporarily unavailable".
  Future<List<int>?> probeKeystore() async {
    try {
      final existing = await _storage.read(key: _keyName);
      if (existing != null) {
        _markAvailable();
        return base64.decode(existing);
      }
      final key = secureRandomBytes(32);
      await _storage.write(key: _keyName, value: base64.encode(key));
      _markAvailable();
      return key;
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
  }

  /// Whether a master key is stored. Tolerant like [getApiKey]: a keystore
  /// that throws reads as "no key", not as a crash.
  Future<bool> hasKeystoreKey() async {
    try {
      final v = await _storage.read(key: _keyName);
      _markAvailable();
      return v != null;
    } catch (e) {
      _markUnavailable(e);
      return false;
    }
  }

  /// Replace the stored master key (used when sync enrolment switches the
  /// vault to the passphrase-derived key that is shared across devices).
  Future<void> setKeystoreKey(List<int> key) =>
      _write(_keyName, base64.encode(key), what: 'the vault master key');

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
  /// synced. Throws [KeystoreException] when the keystore is unavailable —
  /// a caller saving user input must be able to say the save failed.
  Future<void> putApiKey(String name, String value) =>
      _write('seance.apikey.$name', value, what: 'the $name key');

  Future<void> _write(String key, String value, {required String what}) async {
    try {
      await _storage.write(key: key, value: value);
      _markAvailable();
    } catch (e) {
      _markUnavailable(e);
      throw KeystoreException(
        'Could not save $what to the OS keyring (${_describe(e)}). Unlock '
        'the login keyring or install gnome-keyring, then try again.',
      );
    }
  }

  /// Reads never crash the app on a locked/unavailable keystore; they behave
  /// as "not set" (and update [keystoreStatus] for the UI's retry affordance).
  Future<String?> getApiKey(String name) async {
    try {
      final v = await _storage.read(key: 'seance.apikey.$name');
      _markAvailable();
      return v;
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
  }
}
