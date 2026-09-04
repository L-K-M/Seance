import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Argon2 resource policy', () {
    for (final entry in <String, List<Object?>>{
      'memory': [null, '19456', 19456.0, 19456.5, 0, 65537],
      'iterations': [null, '2', 2.0, 2.5, 0, 11],
      'parallelism': [null, '1', 1.0, 1.5, 0, 5],
      'hashLength': [null, '32', 32.0, 32.5, 16, 33],
    }.entries) {
      for (final value in entry.value) {
        test('rejects ${entry.key}=$value (${value.runtimeType})', () {
          final json = const Argon2Params().toJson()..[entry.key] = value;
          expect(() => Argon2Params.fromJson(json), throwsFormatException);
        });
      }
      test('requires ${entry.key}', () {
        final json = const Argon2Params().toJson()..remove(entry.key);
        expect(() => Argon2Params.fromJson(json), throwsFormatException);
      });
    }

    test('accepts default, fast and maximum supported work factors', () {
      for (final params in [
        const Argon2Params(),
        const Argon2Params.fast(),
        const Argon2Params(memory: 65536, iterations: 10, parallelism: 4),
      ]) {
        expect(
          Argon2Params.fromJson(params.toJson()).toJson(),
          params.toJson(),
        );
      }
    });

    test('requires at least eight memory blocks per lane', () {
      expect(
        () => Argon2Params.fromJson(
          const Argon2Params(memory: 31, parallelism: 4).toJson(),
        ),
        throwsFormatException,
      );
      expect(
        Argon2Params.fromJson(
          const Argon2Params(memory: 32, parallelism: 4).toJson(),
        ).memory,
        32,
      );
    });

    test('direct derivation cannot bypass the output-length policy', () async {
      // Small valid work factors keep the unfixed regression safe to execute.
      await expectLater(
        VaultCrypto.deriveKeys(
          passphrase: 'test',
          salt: List<int>.filled(16, 0),
          params: const Argon2Params(
            memory: 256,
            iterations: 1,
            hashLength: 16,
          ),
        ),
        throwsFormatException,
      );
    });
  });
}
