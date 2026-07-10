enum SyncEnrollmentMode { register, login }

/// Returns a user-facing error when sync enrollment must not contact the
/// server, or null when the request is ready to run.
String? validateSyncEnrollment({
  required SyncEnrollmentMode mode,
  required String baseUrl,
  required String username,
  required String password,
  required String encryptionPassphrase,
  String confirmationPassphrase = '',
}) {
  final uri = Uri.tryParse(baseUrl.trim());
  final scheme = uri?.scheme.toLowerCase();
  // HTTP remains valid for localhost, development, and existing self-hosted
  // deployments; stricter transport policy is a separate migration.
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty) {
    return 'Enter a valid HTTP or HTTPS server URL.';
  }
  if (uri.userInfo.isNotEmpty) {
    return 'Server URL must not include embedded credentials.';
  }
  if (username.trim().isEmpty) return 'Enter a username.';
  if (password.trim().isEmpty) return 'Enter the sync account password.';
  if (encryptionPassphrase.trim().isEmpty) {
    return 'Enter the vault encryption passphrase.';
  }
  if (mode == SyncEnrollmentMode.register) {
    if (confirmationPassphrase.trim().isEmpty) {
      return 'Confirm the vault encryption passphrase before registering.';
    }
    if (confirmationPassphrase != encryptionPassphrase) {
      return 'Vault encryption passphrases do not match.';
    }
  }
  return null;
}
