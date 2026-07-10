# SFTP file browser

Living design and implementation record for Séance's session-scoped SFTP file
browser. Update the progress section as work lands so this document remains the
starting point for future sessions.

_Last updated: 2026-07-10_

## Goal

Put a small remote file browser beside each terminal session. It should make the
common terminal-adjacent tasks easy without becoming a general file manager:

- browse the directory currently shown by the shell when reliable shell
  metadata is available;
- upload a local file into that directory, including desktop drag-and-drop;
- download a remote file or open a temporary local copy in another app;
- safely send an edited local copy back to the server;
- work with touch navigation and Android's document-provider model as well as
  desktop filesystems.

The browser is directly user-operated. It is not exposed to the assistant as a
tool and remote file contents are never added to LLM context automatically.

## Product and UX

### Desktop

Files is a tab in the existing right utility pane beside Assistant and
Snippets. It follows the active terminal tab and shows the server and session
identity prominently.

The compact layout contains:

- a breadcrumb/path control with Up, Home, and Refresh actions;
- a **Follow terminal** toggle;
- a list with name, and size/date columns when width permits;
- Upload, New folder, Rename, Download/Open, and Delete actions;
- a small transfer queue with progress and cancellation;
- a drop target where local files upload to the displayed directory.

Dragging remote files out to Finder or Explorer is not part of the first
version. Native promised-file drag APIs make that substantially different from
accepting local drops.

### Android and other narrow layouts

Files is a full-screen view opened from the terminal app bar, not a narrow
drawer. The terminal remains alive behind it and normal Back navigation returns
to the session.

Android uses the system document picker for uploads and the app cache plus an
Android content URI for opening downloaded files. Download/export should use a
system save or share flow when the user wants to retain a copy. No feature may
assume that a picked file has a stable absolute path: Android document providers
can provide bytes only.

Touch targets, menus, progress controls, and confirmation dialogs must remain
usable without hover, right-click, or desktop drag-and-drop.

## Working-directory synchronization

SFTP cannot query the current directory of an already-running interactive
shell. `realpath(".")` only gives the SFTP subsystem's initial directory.
Prompt parsing and watching for typed `cd` commands are not reliable.

Séance therefore consumes standard OSC 7 terminal metadata:

```text
ESC ] 7 ; file://hostname/path ESC \
```

The cwd is stored per terminal session. When **Follow terminal** is enabled and
a valid absolute path arrives, the browser navigates to it. The browser falls
back to SFTP's canonical home/current directory when OSC 7 is unavailable. A
path that is outside an SFTP chroot is reported without breaking the shell.

Shells do not all emit OSC 7 by default. Future shell-integration documentation
can provide opt-in prompt hooks for bash, zsh, and fish. Séance must not silently
inject or execute shell setup code.

The reverse action, **Open terminal here**, should insert a shell-escaped `cd`
command without a newline so the user reviews and submits it. It is disabled
when the terminal already has pending input. Future OSC 133 prompt markers can
make prompt readiness and command boundaries authoritative.

## Architecture

`SshSession` owns the authenticated transport and shell channel. It lazily opens
an SFTP subsystem as another channel on the same `dartssh2` `SSHClient`, so
there is no second host-key prompt, password prompt, or TCP connection.

`seance_core` exposes a transport-neutral `RemoteFileSystem` interface and
models for entries, metadata, transfer progress, and typed failures. The
Flutter app never imports `dartssh2` or passes its types through UI state.

The first connection policy is deliberately simple:

- one remote browser per terminal session;
- SFTP opens only when Files is first used;
- disconnecting or reconnecting the terminal closes SFTP and cancels transfers;
- tabs for the same server do not share a transport or browser location.

A future dedicated transfer connection may keep long transfers alive when a
shell exits, but that requires an explicit lifecycle and reauthentication UX.

## Transfer and edit safety

Uploads write a sibling temporary remote file and rename it into place after a
complete transfer. Existing targets require an explicit overwrite decision.
Where the server supports it, the original mode is preserved.

Opening a remote file locally is a managed checkout:

1. Download to a private cache directory with a sanitized local filename.
2. Record the remote path, size, modification time, type, and mode.
3. Open it with the platform default app or a selected desktop editor.
4. Keep the checkout visible in a **Local edits** section.
5. Offer **Upload changes**; do not silently overwrite the remote file.
6. Re-stat before and after transfer and warn if the remote snapshot changed.
7. Upload through a temporary remote file and rename only after completion.
8. Remove plaintext cache files on discard or confirmed tab/server deletion.

Remote files are untrusted. Opening one is always an explicit action. Large or
binary files are streamed as bytes and never decoded merely to transfer them.

## Initial scope

- [x] Core remote-filesystem abstraction over a lazy SFTP channel.
- [x] Directory listing, canonical paths, metadata, and symlink-aware entries.
- [x] Session-specific browser path, refresh, Up, and Home.
- [x] Optional follow-shell behavior using OSC 7.
- [x] Responsive Files utility tab on desktop and full-screen Files view on
      narrow/mobile layouts.
- [x] Upload through a system picker and desktop drag-and-drop.
- [x] Streamed download to app cache and open with a local application.
- [x] New folder, rename, and delete with confirmation.
- [x] Collision preflight and temporary-file-plus-rename uploads.
- [x] Transfer progress, cancellation, timeouts, and clear disconnect errors.
- [x] Core path tests plus Flutter controller and OSC 7 tests.
- [ ] Files browser widget tests with picker/opener platform fakes.
- [ ] Manual validation against an OpenSSH SFTP server on desktop and Android.

## Future enhancements

- Configurable default editor and an explicit **Open with BBEdit** action.
- Prompt-on-save or opt-in automatic upload for managed local edits.
- Persist the managed-edit index so Android process death while an editor is in
  front cannot orphan a checkout.
- Content hashing and local file watching, including atomic-save detection.
- Strong remote conflict checks using server-side hashes when supported.
- Recursive directory upload/download with aggregate progress.
- Resumable and queued background transfers.
- A dedicated transfer connection that survives shell exit/reconnect.
- Remote-to-desktop promised-file drag-out.
- Drop directly onto a folder row instead of only the displayed directory.
- Multi-selection, sorting, filtering, hidden-file preferences, and bookmarks.
- chmod/chown, symlink creation, and richer POSIX metadata editing.
- Clipboard copy/paste for remote paths and file operations.
- Shell-integration setup guidance for OSC 7 and OSC 133.
- **Open terminal here** once prompt readiness can be determined safely.
- Android export/share actions and persisted document-provider destinations.
- iOS document-provider and external-editor validation.
- Accessibility and keyboard-navigation passes for full file-manager operation.

## Risks and constraints

- Shell and SFTP share one SSH transport. Session teardown must be idempotent,
  and transport loss must complete pending SFTP work rather than leave futures
  hanging.
- Some servers disable SFTP or expose a different chroot from the shell.
- OSC control sequences are remote input. Validate paths and display the actual
  SFTP result rather than trusting metadata blindly.
- SFTP v3 has limited conflict and timestamp precision. Size/mtime checks reduce
  risk but are not a transactional lock. A concurrent write in the narrow gap
  between the final stat and rename can still win or be replaced.
- `dartssh2` uses OpenSSH atomic replacement when the server advertises it.
  Explicit overwrite may fail on SFTP v3 servers without that extension.
- Large transfers may compete with terminal latency on one transport and need
  real-device testing.
- Mobile apps can be suspended while an external editor is open. Save-back must
  tolerate reconnection and revalidate the remote file.
- Managed local copies survive session disconnect/reconnect, but their index is
  currently in memory. Android process death can leave an untracked cache file.
- Android grants external editors read/write access to the managed checkout.
  The current iOS opener generally previews or shares a copy, so iOS upload-back
  is not considered validated.

## Progress

### 2026-07-10

- Design captured and SFTP moved out of the deliberately deferred backlog.
- Added `RemoteFileSystem` and a `dartssh2` SFTP adapter in `seance_core`, with
  neutral entry/error models, POSIX path helpers, streamed transfers,
  cancellation, operation timeouts, short-read detection, collision preflights,
  temporary uploads, mode preservation, and conflict snapshots.
- `SshSession` now lazily opens one SFTP channel on the existing authenticated
  transport. Session teardown closes SFTP and drains final shell output first.
- Added per-session browser/controller state, transfer history, local edit
  checkouts, upload-back conflict prompts, and checkout retention across normal
  disconnect/reconnect.
- Added standard OSC 7 cwd extraction with URI validation and percent-decoding.
- Added a lazy Files utility tab for wide layouts and a full-screen route from
  the terminal app bar for Android/narrow layouts.
- Added navigation, responsive file rows, path entry, follow mode, upload,
  desktop drop, open locally, upload changes, mkdir, rename, empty-directory
  delete, progress, cancellation, and confirmations.
- Android picker uploads use `file_picker` read streams/cached files and do not
  require an absolute document-provider path. Downloaded files use app-private
  cache paths and `open_file` content URIs.
- Sandboxed macOS drops acquire and release the plugin's security-scoped
  bookmark. Linux checkouts are created in app cache and chmod'd to 0700/0600.
- Symlink entries are shown but deliberately cannot be opened/uploaded back yet,
  avoiding replacement of a link with a regular file.

## Verification log

- `dart analyze packages/seance_protocol packages/seance_core
  packages/seance_sync_server` — clean.
- `dart test packages/seance_protocol packages/seance_core` — 131 tests pass.
- `flutter analyze` — clean.
- `flutter test` — 82 tests pass.
- Full three-package Dart run reaches 160 passing tests, but the three existing
  SQLite storage tests cannot load `libsqlite3.so` in this container (only
  runtime `libsqlite3.so.0` is installed).
- Android compile not run: this environment has no Android SDK / `ANDROID_HOME`.
- Linux compile not run: this environment has no CMake toolchain.
- Live OpenSSH/SFTP and real-device Android validation remain open.
