import 'dart:io';

import 'package:posix/posix.dart' as posix;

const _ownerReadWriteMode = 0x180; // POSIX 0600: owner read + write only.
const _permissionBitsMask = 0x1ff; // POSIX 0777: rwx for owner, group, other.

/// Applies owner-only mode bits to files that carry path-bearing or
/// otherwise private data (the identity audit log names private-key
/// paths). Windows and mobile rely on their per-user/application
/// storage ACLs instead.
void restrictFileToOwner(File file) {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  posix.chmodWithMode(file.path, _ownerReadWriteMode);
}

/// Sets [file]'s permission bits to those of [mode] (a `stat` mode: only the
/// read, write and execute bits for owner, group and others are applied).
/// This is how an atomic replacement carries over the mode of the file it
/// replaces. A no-op on the same platforms as [restrictFileToOwner].
void applyPermissionBits(File file, int mode) {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  posix.chmodWithMode(file.path, mode & _permissionBitsMask);
}
