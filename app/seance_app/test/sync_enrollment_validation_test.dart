import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/sync_enrollment_validation.dart';

void main() {
  const validUrl = 'https://sync.example.com';
  const username = 'alice';
  const passphrase = 'correct horse battery staple';

  String? validate({
    SyncEnrollmentMode mode = SyncEnrollmentMode.register,
    String baseUrl = validUrl,
    String user = username,
    String pass = passphrase,
    String confirmation = passphrase,
  }) => validateSyncEnrollment(
    mode: mode,
    baseUrl: baseUrl,
    username: user,
    passphrase: pass,
    confirmationPassphrase: confirmation,
  );

  test('rejects blank and non-HTTP(S) server URLs', () {
    expect(validate(baseUrl: '   '), 'Enter a valid HTTP or HTTPS server URL.');
    expect(
      validate(baseUrl: 'ssh://sync.example.com'),
      'Enter a valid HTTP or HTTPS server URL.',
    );
    expect(
      validate(baseUrl: 'https:///missing-host'),
      'Enter a valid HTTP or HTTPS server URL.',
    );
  });

  test('rejects blank username and passphrase', () {
    expect(validate(user: '  '), 'Enter a username.');
    expect(validate(pass: '\t'), 'Enter a vault passphrase.');
  });

  test('registration rejects blank or mismatched confirmation', () {
    expect(
      validate(confirmation: ''),
      'Confirm the vault passphrase before registering.',
    );
    expect(
      validate(confirmation: 'different'),
      'Vault passphrases do not match.',
    );
  });

  test('valid registration passes the service-call gate', () {
    expect(validate(), isNull);
  });

  test('valid login passes without passphrase confirmation', () {
    expect(
      validate(mode: SyncEnrollmentMode.login, confirmation: 'does not match'),
      isNull,
    );
  });

  test('HTTP localhost is accepted for self-hosted development', () {
    expect(validate(baseUrl: 'http://localhost:8787'), isNull);
  });
}
