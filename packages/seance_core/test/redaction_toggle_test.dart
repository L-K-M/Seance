import 'package:seance_core/src/llm/redaction.dart';
import 'package:test/test.dart';

void main() {
  group('SecretRedactor.enabled', () {
    const secret = 'export KEY=sk-ant-abcdefghij0123456789XYZ';

    test('redacts by default (enabled)', () {
      final r = SecretRedactor();
      expect(r.redact(secret), isNot(contains('sk-ant-')));
      expect(r.wouldRedact(secret), isTrue);
    });

    test('is a pass-through when disabled', () {
      final r = SecretRedactor(enabled: false);
      expect(r.redact(secret), secret);
      expect(r.wouldRedact(secret), isFalse);
    });
  });
}
