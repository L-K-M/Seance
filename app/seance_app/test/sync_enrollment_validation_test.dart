import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/sync_enrollment_validation.dart';

void main() {
  const validUrl = 'https://sync.example.com';
  const username = 'alice';
  const password = 'server account password';
  const encryptionPassphrase = 'correct horse battery staple';

  String? validate({
    SyncEnrollmentMode mode = SyncEnrollmentMode.register,
    String baseUrl = validUrl,
    String user = username,
    String accountPassword = password,
    String vaultPassphrase = encryptionPassphrase,
    String confirmation = encryptionPassphrase,
  }) => validateSyncEnrollment(
    mode: mode,
    baseUrl: baseUrl,
    username: user,
    password: accountPassword,
    encryptionPassphrase: vaultPassphrase,
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

  test('rejects blank username, password, and encryption passphrase', () {
    expect(validate(user: '  '), 'Enter a username.');
    expect(validate(accountPassword: '\t'), 'Enter the sync account password.');
    expect(
      validate(vaultPassphrase: '\t'),
      'Enter the vault encryption passphrase.',
    );
  });

  test('registration rejects blank or mismatched confirmation', () {
    expect(
      validate(confirmation: ''),
      'Confirm the vault encryption passphrase before registering.',
    );
    expect(
      validate(confirmation: '  \t'),
      'Confirm the vault encryption passphrase before registering.',
    );
    expect(
      validate(confirmation: 'different'),
      'Vault encryption passphrases do not match.',
    );
    expect(
      validate(confirmation: '$encryptionPassphrase '),
      'Vault encryption passphrases do not match.',
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
