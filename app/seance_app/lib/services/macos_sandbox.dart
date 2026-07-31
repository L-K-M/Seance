import 'dart:io';

/// Whether this process is running inside macOS's App Sandbox.
///
/// `APP_SANDBOX_CONTAINER_ID` is set in the environment of every sandboxed
/// macOS process, and there is no public API that answers this from the
/// inside — so treat it as a strong hint rather than a guarantee, and never
/// let a wrong answer be destructive.
///
/// Séance ships **unsandboxed** on macOS (see `macos/Runner/*.entitlements`),
/// so this is normally false. It stays in the code because the answer decides
/// two things that must not guess: whether a local shell would be confined,
/// and whether an install still has data behind a container that needs
/// migrating out.
bool macOsSandboxed({Map<String, String>? environment, bool? isMacOS}) {
  if (!(isMacOS ?? Platform.isMacOS)) return false;
  final container =
      (environment ?? Platform.environment)['APP_SANDBOX_CONTAINER_ID'] ?? '';
  return container.isNotEmpty;
}
