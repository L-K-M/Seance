# SFTP file browser

Living design and implementation record for Séance's session-scoped SFTP file
browser. Update the progress section as work lands so this document remains the
starting point for future sessions.

_Last updated: 2026-07-11_

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
back to a conservative OSC 0/2 title parser when OSC 7 is unavailable. This
covers the default Ubuntu/Debian Bash title form (`user@host: ~/path` or an
absolute path), resolving `~` against SFTP's canonical home. If neither source
is available, Files stays at the SFTP home/current directory. A path outside an
SFTP chroot is reported without breaking the shell.

Shells do not all emit OSC 7 or a cwd title. Optional prompt hooks for bash,
zsh, and fish are documented in [SHELL_INTEGRATION.md](SHELL_INTEGRATION.md).
Séance never silently injects or executes shell setup code.

The reverse action, **Open terminal here**, uses OSC 133 prompt markers and an
explicit shell identity. It inserts a shell-specific quoted `cd` without a
newline so the user reviews and submits it. Any input since the last prompt,
including cursor/history keys, disables the action. **Copy remote path** is
always available as a local user action.

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

1. Download to a private application-support directory with a sanitized local
   filename.
2. Record the remote path, size, modification time, type, and mode.
3. Open UTF-8 text up to 4 MB in Séance's built-in editor, or use the platform
   default app or a configured desktop editor.
4. Keep the checkout visible in a **Local edits** section.
5. Offer **Upload changes**; do not silently overwrite the remote file.
6. Re-stat and stream-hash before commit; warn if the remote snapshot changed.
7. Upload through a temporary remote file and rename only after completion.
8. Remove plaintext support files on discard or confirmed tab/server deletion.

The managed-edit index is persisted atomically. Checkouts are SHA-256 hashed,
watched by parent directory to catch atomic saves, reconciled on app resume,
and restored into their original logical session after process death. A local
save only prompts or marks the checkout dirty; it never uploads silently.

Remote files are untrusted. Opening one is always an explicit action. Large or
binary files are streamed as bytes and never decoded merely to transfer them.
The built-in editor rejects malformed UTF-8 and NUL-containing content,
preserves UTF-8 BOM and CRLF conventions, and saves atomically to the managed
checkout. Mobile defaults to this editor because mobile open/share APIs do not
reliably edit app-private checkouts in place.

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

- [x] Built-in mobile/desktop text editor plus a configurable registry of
  extension-filtered desktop editors.
- [x] Prompt-on-save for managed local edits without silent upload.
- [x] Persist the managed-edit index across process death.
- [x] Local SHA-256 hashing and parent-directory watching for atomic saves.
- Strong remote conflict checks using server-side hashes when supported.
- [x] Recursive desktop directory upload/download with aggregate progress.
- Resumable and queued background transfers.
- A dedicated transfer connection that survives shell exit/reconnect.
- Remote-to-desktop promised-file drag-out.
- Drop directly onto a folder row instead of only the displayed directory.
- [x] Multi-selection, sorting, filtering, hidden-file visibility, and
  per-server bookmarks.
- [x] chmod, symlink inspection/creation, and richer POSIX metadata display.
- [x] Clipboard copy for remote paths.
- [x] Shell-integration setup guidance for OSC 133 prompt readiness.
- [x] Reviewed **Open terminal here** staging with no implicit execution.
- [x] Android export/share actions and a persisted SAF destination grant.
- Persist sort/filter view preferences across launches (hidden-file visibility
  and bookmarks already persist per server).
- Clipboard-backed remote file copy/move operations.
- iOS document-provider and external-editor validation.
- Accessibility and keyboard-navigation passes for full file-manager operation.

## Risks and constraints

- Shell and SFTP share one SSH transport. Session teardown must be idempotent,
  and transport loss must complete pending SFTP work rather than leave futures
  hanging.
- Some servers disable SFTP or expose a different chroot from the shell.
- OSC control sequences are remote input. Validate paths and display the actual
  SFTP result rather than trusting metadata blindly.
- SFTP v3 has limited timestamp precision. Managed upload-back therefore
  re-reads and SHA-256 hashes the remote target in addition to metadata checks.
  This is still not a transactional lock: a concurrent write in the narrow gap
  between the final hash and rename can still win or be replaced.
- `dartssh2` uses OpenSSH atomic replacement when the server advertises it.
  Explicit overwrite may fail on SFTP v3 servers without that extension.
- Large transfers may compete with terminal latency on one transport and need
  real-device testing.
- Mobile apps can be suspended while an external editor is open. Save-back must
  tolerate reconnection and revalidate the remote file.
- Managed edit metadata and plaintext checkouts persist locally so interrupted
  editor workflows can recover. Users must explicitly discard them when done.
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
- Added an OSC 0/2 title fallback for the cwd titles emitted by default Ubuntu
  and Debian Bash configurations when OSC 7 is absent.
- Added a lazy Files utility tab for wide layouts and a full-screen route from
  the terminal app bar for Android/narrow layouts.
- Added navigation, responsive file rows, path entry, follow mode, upload,
  desktop drop, open locally, upload changes, mkdir, rename, empty-directory
  delete, progress, cancellation, and confirmations.
- Android picker uploads use `file_picker` read streams/cached files and do not
  require an absolute document-provider path. Downloaded files use app-private
  cache paths and `open_file` content URIs.
- Sandboxed macOS drops acquire and release the plugin's security-scoped
  bookmark. Linux checkouts are created in application support and chmod'd to
  0700/0600.
- Symlink entries are shown but deliberately cannot be opened/uploaded back yet,
  avoiding replacement of a link with a regular file.
- Added durable managed-edit recovery, local hashing/watching, dirty prompts,
  configurable editors, and explicit BBEdit launching on macOS.
- Added sorting, filtering, hidden-file visibility, bookmarks, multi-selection,
  recursive desktop transfers, metadata/mode editing, and symlink creation.
- Added copy-path and guarded Open terminal here actions plus opt-in OSC 133
  integration guidance.
- Added streamed Save As, native sharing, and Android SAF export destinations.
- Added a built-in conflict-aware UTF-8 text editor and configurable external
  editor registry. The built-in editor is the mobile default.

## Verification log

- `dart analyze packages/seance_protocol packages/seance_core
  packages/seance_sync_server` — clean.
- `dart test packages/seance_protocol packages/seance_core
  packages/seance_sync_server` — 181 tests pass.
- `flutter analyze` — clean.
- `flutter test` — 125 tests pass.
- Android compile not run: this environment has no Android SDK / `ANDROID_HOME`.
- Linux compile not run: this environment has no CMake toolchain.
- Live OpenSSH/SFTP and real-device Android validation remain open.
