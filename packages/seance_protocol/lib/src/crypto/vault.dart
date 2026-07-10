import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as classic;

/// Argon2id work factors. Defaults are the OWASP minimum for interactive use;
/// `memory` is counted in 1 KiB blocks, so 19456 == 19 MiB.
///
/// The parameters are stored per account (alongside the salt) so they can be
/// raised over time without breaking existing vaults: a device derives keys
/// with whatever parameters the account was created with.
class Argon2Params {
  final int memory;
  final int iterations;
  final int parallelism;
  final int hashLength;

  const Argon2Params({
    this.memory = 19456,
    this.iterations = 2,
    this.parallelism = 1,
    this.hashLength = 32,
  });

  /// Deliberately weak parameters for fast unit tests. Never use in production.
  const Argon2Params.fast()
      : memory = 256,
        iterations = 1,
        parallelism = 1,
        hashLength = 32;

  /// The minimum work factors a client will accept when deriving its vault key
  /// from a passphrase — the v1 defaults. Parameters may be *raised* over time
  /// (a newer device honors whatever the account was created with), but a
  /// client must never derive its end-to-end key with anything *weaker*, or a
  /// malicious/compromised server could force a KDF downgrade at prelogin and
  /// then cheaply brute-force the passphrase against the ciphertext it holds.
  static const Argon2Params minimum = Argon2Params();

  /// Whether these parameters are at least as strong as [floor].
  bool meetsMinimum(Argon2Params floor) =>
      memory >= floor.memory &&
      iterations >= floor.iterations &&
      hashLength >= floor.hashLength;

  Map<String, dynamic> toJson() => {
        'memory': memory,
        'iterations': iterations,
        'parallelism': parallelism,
        'hashLength': hashLength,
      };

  factory Argon2Params.fromJson(Map<String, dynamic> json) {
    final params = Argon2Params(
      memory: (json['memory'] as num).toInt(),
      iterations: (json['iterations'] as num).toInt(),
      parallelism: (json['parallelism'] as num).toInt(),
      hashLength: (json['hashLength'] as num).toInt(),
    );
    // Reject nonsensical values (a non-positive or absurd count would crash the
    // Argon2id constructor or, at 0, silently weaken the KDF). 4 GiB (in KiB)
    // is a generous memory ceiling that still blocks an OOM-inducing value.
    if (params.memory < 1 ||
        params.memory > 4 * 1024 * 1024 ||
        params.iterations < 1 ||
        params.parallelism < 1 ||
        params.hashLength < 16) {
      throw const FormatException('Argon2 parameters out of range');
    }
    return params;
  }
}

/// The three keys derived from a user's passphrase.
///
/// * [vaultKey] never leaves the device — it encrypts every record payload.
/// * [authVerifier] is safe to hand to the server; because it comes from an
///   independent HKDF salt, learning it reveals nothing about [vaultKey].
/// * [masterKey] is the Argon2id root the other two are derived from; kept so
///   additional subkeys can be derived later (e.g. per-record wrapping keys).
class VaultKeys {
  final Uint8List masterKey;
  final Uint8List vaultKey;
  final Uint8List authVerifier;

  VaultKeys({
    required this.masterKey,
    required this.vaultKey,
    required this.authVerifier,
  });
}

/// HKDF salts used purely as domain separators. `cryptography` 2.9's `Hkdf`
/// exposes the salt but not the RFC 5869 `info` field, so distinct salts —
/// which yield independent output key material — are how we separate domains.
const String _kVaultKeyDomain = 'seance/v1/vault-encryption-key';
const String _kAuthVerifierDomain = 'seance/v1/auth-verifier';

const int _kXNonceLength = 24; // XChaCha20 nonce
const int _kMacLength = 16; // Poly1305 tag

final Xchacha20 _cipher = Xchacha20.poly1305Aead();

/// End-to-end vault cryptography. All record payloads are sealed under
/// XChaCha20-Poly1305 with a random 24-byte nonce; the sealed blob is a plain
/// `nonce || ciphertext || mac` concatenation so it is self-describing on the
/// wire and the server stores it as an opaque byte string.
class VaultCrypto {
  /// Derive the vault and auth keys from a passphrase and the account's salt.
  /// This is the only expensive call (Argon2id); everything else is cheap.
  static Future<VaultKeys> deriveKeys({
    required String passphrase,
    required List<int> salt,
    Argon2Params params = const Argon2Params(),
  }) async {
    final argon = Argon2id(
      parallelism: params.parallelism,
      memory: params.memory,
      iterations: params.iterations,
      hashLength: params.hashLength,
    );
    final master = Uint8List.fromList(
      await (await argon.deriveKey(
        secretKey: SecretKey(utf8.encode(passphrase)),
        nonce: salt,
      ))
          .extractBytes(),
    );

    final vaultKey = await _hkdf(master, _kVaultKeyDomain);
    final authVerifier = await _hkdf(master, _kAuthVerifierDomain);
    return VaultKeys(
      masterKey: master,
      vaultKey: vaultKey,
      authVerifier: authVerifier,
    );
  }

  static Future<Uint8List> _hkdf(List<int> key, String domain) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(key),
      nonce: utf8.encode(domain),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Seal [plaintext] under [key], returning `nonce || ciphertext || mac`.
  static Future<Uint8List> seal(List<int> key, List<int> plaintext) async {
    final box = await _cipher.encrypt(plaintext, secretKey: SecretKey(key));
    return box.concatenation();
  }

  /// Open a `nonce || ciphertext || mac` blob. Throws [SecretBoxAuthenticationError]
  /// if the key is wrong or the blob was tampered with.
  static Future<Uint8List> open(List<int> key, Uint8List blob) async {
    final box = SecretBox.fromConcatenation(
      blob,
      nonceLength: _kXNonceLength,
      macLength: _kMacLength,
    );
    final clear = await _cipher.decrypt(box, secretKey: SecretKey(key));
    return Uint8List.fromList(clear);
  }

  /// Convenience: seal a JSON-encodable map.
  static Future<Uint8List> sealJson(
          List<int> key, Map<String, dynamic> value) =>
      seal(key, utf8.encode(jsonEncode(value)));

  /// Convenience: open a blob back into a JSON map.
  static Future<Map<String, dynamic>> openJson(
      List<int> key, Uint8List blob) async {
    final clear = await open(key, blob);
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  /// How the server stores the auth verifier: a salted SHA-256 of it.
  ///
  /// A slow hash (Argon2id) is unnecessary here because the verifier is already
  /// a 256-bit HKDF output, not a low-entropy password — precomputation is
  /// infeasible against a per-account salt. Online guessing is stopped by the
  /// server's rate limiter, and an attacker must still run Argon2id themselves
  /// to turn a passphrase guess into a candidate verifier.
  static String hashAuthVerifier(List<int> verifier, List<int> salt) {
    final digest = classic.sha256.convert([...salt, ...verifier]);
    return base64.encode(digest.bytes);
  }
}
