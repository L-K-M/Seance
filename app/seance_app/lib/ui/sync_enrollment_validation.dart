enum SyncEnrollmentMode { register, login }

/// Returns a user-facing error when sync enrollment must not contact the
/// server, or null when the request is ready to run.
String? validateSyncEnrollment({
  required SyncEnrollmentMode mode,
  required String baseUrl,
  required String username,
  required String passphrase,
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
  if (passphrase.trim().isEmpty) return 'Enter a vault passphrase.';
  if (mode == SyncEnrollmentMode.register) {
    if (confirmationPassphrase.trim().isEmpty) {
      return 'Confirm the vault passphrase before registering.';
    }
    if (confirmationPassphrase != passphrase) {
      return 'Vault passphrases do not match.';
    }
  }
  return null;
}
