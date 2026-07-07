import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:seance_protocol/src/crypto/random.dart';
import 'package:seance_protocol/src/crypto/recovery_key.dart';
import 'package:seance_protocol/src/crypto/vault.dart';
import 'package:test/test.dart';

void main() {
  group('VaultCrypto key derivation', () {
    test('derives independent vault and auth keys, deterministically', () async {
      final salt = secureRandomBytes(16);
      final a = await VaultCrypto.deriveKeys(
          passphrase: 'correct horse battery staple',
          salt: salt,
          params: const Argon2Params.fast());
      final b = await VaultCrypto.deriveKeys(
          passphrase: 'correct horse battery staple',
          salt: salt,
          params: const Argon2Params.fast());

      // Deterministic: same passphrase + salt + params => same keys.
      expect(a.vaultKey, equals(b.vaultKey));
      expect(a.authVerifier, equals(b.authVerifier));

      // Domain separation: vault key and auth verifier must differ.
      expect(a.vaultKey, isNot(equals(a.authVerifier)));
      expect(a.vaultKey.length, 32);
      expect(a.authVerifier.length, 32);
    });

    test('different passphrase yields different keys', () async {
      final salt = secureRandomBytes(16);
      final a = await VaultCrypto.deriveKeys(
          passphrase: 'passphrase one',
          salt: salt,
          params: const Argon2Params.fast());
      final b = await VaultCrypto.deriveKeys(
          passphrase: 'passphrase two',
          salt: salt,
          params: const Argon2Params.fast());
      expect(a.vaultKey, isNot(equals(b.vaultKey)));
    });
  });

  group('VaultCrypto seal/open', () {
    test('round-trips a JSON payload', () async {
      final key = secureRandomBytes(32);
      final payload = {
        'kind': 'serverConfig',
        'data': {'host': 'example.com', 'port': 22, 'user': 'root'},
      };
      final blob = await VaultCrypto.sealJson(key, payload);
      final opened = await VaultCrypto.openJson(key, blob);
      expect(opened, equals(payload));
    });

    test('blob layout is nonce(24) || ciphertext || mac(16)', () async {
      final key = secureRandomBytes(32);
      final blob = await VaultCrypto.seal(key, utf8.encode('hello'));
      // 24 (nonce) + 5 (plaintext len, stream cipher) + 16 (mac) = 45
      expect(blob.length, 24 + 5 + 16);
    });

    test('wrong key fails to open', () async {
      final key = secureRandomBytes(32);
      final wrong = secureRandomBytes(32);
      final blob = await VaultCrypto.seal(key, utf8.encode('secret'));
      expect(
        () => VaultCrypto.open(wrong, blob),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('tampered ciphertext fails to open', () async {
      final key = secureRandomBytes(32);
      final blob = await VaultCrypto.seal(key, utf8.encode('secret'));
      blob[30] ^= 0xff; // flip a ciphertext byte
      expect(
        () => VaultCrypto.open(key, blob),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('auth verifier hashing', () {
    test('is stable and salt-dependent', () {
      final verifier = secureRandomBytes(32);
      final salt1 = secureRandomBytes(16);
      final salt2 = secureRandomBytes(16);
      final h1a = VaultCrypto.hashAuthVerifier(verifier, salt1);
      final h1b = VaultCrypto.hashAuthVerifier(verifier, salt1);
      final h2 = VaultCrypto.hashAuthVerifier(verifier, salt2);
      expect(h1a, equals(h1b));
      expect(h1a, isNot(equals(h2)));
    });
  });

  group('RecoveryKey', () {
    test('round-trips 32 random bytes', () {
      for (var i = 0; i < 20; i++) {
        final key = secureRandomBytes(32);
        final code = RecoveryKey.encode(key);
        expect(RecoveryKey.decode(code), equals(key));
      }
    });

    test('is grouped, dash-separated, and case/space tolerant', () {
      final key = secureRandomBytes(32);
      final code = RecoveryKey.encode(key);
      expect(code, contains('-'));
      final messy = code.toLowerCase().replaceAll('-', ' ');
      expect(RecoveryKey.decode(messy), equals(key));
    });

    test('detects a single-character corruption', () {
      final key = secureRandomBytes(32);
      final code = RecoveryKey.encode(key);
      final chars = code.replaceAll('-', '').split('');
      // Corrupt the first symbol to a different valid symbol.
      chars[0] = chars[0] == '7' ? '8' : '7';
      expect(
        () => RecoveryKey.decode(chars.join()),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
