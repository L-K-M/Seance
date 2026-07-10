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
      validate(confirmation: '  \t'),
      'Confirm the vault passphrase before registering.',
    );
    expect(
      validate(confirmation: 'different'),
      'Vault passphrases do not match.',
    );
    expect(
      validate(confirmation: '$passphrase '),
      'Vault passphrases do not match.',
      reason: 'nonblank confirmation must still match exactly',
    );
  });

  test('rejects server URLs containing embedded credentials', () {
    expect(
      validate(baseUrl: 'https://alice:secret@sync.example.com'),
      'Server URL must not include embedded credentials.',
    );
    expect(
      validate(baseUrl: 'http://alice@localhost:8787'),
      'Server URL must not include embedded credentials.',
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

  test('HTTP remains accepted for development and self-hosted servers', () {
    expect(validate(baseUrl: 'http://localhost:8787'), isNull);
    expect(validate(baseUrl: 'http://sync.example.com'), isNull);
  });
}
