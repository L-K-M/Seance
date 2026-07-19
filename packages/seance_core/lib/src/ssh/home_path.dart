/// A sandboxed macOS process gets `$HOME` pointed at its app container
/// (`/Users/<name>/Library/Containers/<bundle-id>/Data`) instead of the real
/// home directory. Matching that suffix lets us recover the real home without
/// platform channels or FFI.
final _macSandboxContainerHome =
    RegExp(r'^(.+)/Library/Containers/[^/]+/Data/?$');

/// Expand a leading `~` in [path] to the user's home directory.
///
/// Only `~` alone and `~/...` are expanded; `~otheruser/...` and paths without
/// a leading tilde are returned unchanged, as is the input when no home
/// directory can be determined. The home comes from [environment] (`HOME`,
/// falling back to Windows' `USERPROFILE`).
///
/// With [isMacOS] set, a `$HOME` that points inside an app-sandbox container
/// is first stripped back to the real home: identity paths like
/// `~/.ssh/id_ed25519` mean the *user's* `.ssh`, never the app container's,
/// which contains no keys and would yield a confusing "file not found".
String expandHomePath(
  String path, {
  required Map<String, String> environment,
  bool isMacOS = false,
}) {
  if (path != '~' && !path.startsWith('~/')) return path;
  var home = environment['HOME'] ?? environment['USERPROFILE'];
  if (home == null || home.isEmpty) return path;
  if (isMacOS) {
    home = _macSandboxContainerHome.firstMatch(home)?.group(1) ?? home;
  }
  if (home.length > 1 && home.endsWith('/')) {
    home = home.substring(0, home.length - 1);
  }
  return path == '~' ? home : '$home/${path.substring(2)}';
}
