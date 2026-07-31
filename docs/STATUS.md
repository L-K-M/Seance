# Status & next steps

Living snapshot of where Séance is, what's proven, and what to pick up next.
Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-07-31 — server groups, colours and icons; optional local
shell; macOS ships unsandboxed._

## Done (implemented + verified)

| Area | State |
|---|---|
| `seance_protocol` | Complete. Models (incl. Snippet with `{{placeholder}}` parsing/fill, and `ServerConfig`'s optional `group`/`color`/`icon` — named accents and icons rather than raw values, so they render per theme and an unknown name decodes to "none"), E2E crypto, records (serverConfig/hostKey/secret/snippet), LWW, sync DTOs. |
| `seance_core` | Complete. SSH+TOFU, ssh_config import, prober, sync engine + coordinator, LLM providers + chat tools, danger linter, redaction, paste sanitizer, stores. A session's bytes now travel over a named `SessionTransport` — `SshSession` or `LocalShellSession` (a local pty behind the `LocalPty` seam). |
| `seance_sync_server` | Complete. 7 endpoints, in-memory + SQLite storage, rate limiting, Dockerfile + compose. |
| `seance_app` | Complete; `flutter analyze` clean, widget tests pass. Server list is the top-level list; each server can hold several sessions shown as a per-server tab strip (a strip appears only at 2+ tabs, so a single session looks title-bar-less as before), with ⌘T/Ctrl+Shift+T + a "New tab" affordance, status dot: green/grey/red + connecting spinner; resizable tiled panes); right-hand utility panel with Assistant + Snippets + **Files** tabs. Files is session-scoped SFTP over the existing SSH transport: responsive navigation, OSC 7 follow mode, picker/desktop-drop upload, local open + conflict-checked upload-back, mkdir/rename/delete, progress/cancel; narrow/Android gets a full-screen route. See [`docs/SFTP.md`](SFTP.md) for implementation state and remaining real-device work. Snippets are synced command templates with `{{placeholder}}` fill-in dialogs; assistant chat when configured, ⌘/Ctrl+↵ sends; inline command generator (⌘K / Ctrl+Shift+K, prefilled from the current shell line, Enter generates+inserts+closes) turns NL into a reviewed command; the native macOS menu is kept intact (Edit/Window/…) with Settings wired to ⌘, and a Terminal ▸ Generate Command… (⌘K) item; Settings is still an in-app route; settings suggest models from the endpoint with manual fallback; failed connections show a summary + expandable connection log. **Automatic sync** runs at startup, after any server/snippet add/edit/delete (debounced), and every 5 min, with a live header/settings status; the "Sync now" button remains. **Credential sync** is opt-in (global toggle × per-server "allow this credential to sync"; E2E-encrypted). On **touch platforms** the terminal shows an on-screen key row (Esc/Tab/Ctrl [sticky]/^C/arrows/Home/End/PgUp/PgDn/`|` `/` `-` `~` + hide-keyboard) and reflows above the soft keyboard. **Command suggestions** (opt-in, local only) surface frequently-run commands in the Snippets tab to save as snippets. **Local shell** (opt-in, off by default, Settings ▸ General) pins a "Local shell" row above the servers that opens a real pty on this machine, with the same tabs, naming, status dot and assistant/snippets as any session — Linux and macOS only (see the platform matrix below); Files is hidden for it, and nothing about it is stored or synced. **Server groups, colours and icons** are per-server and synced: the list files servers into collapsible sections (alphabetical, ungrouped last; no headers at all until something is grouped, and a live filter overrides collapsed sections so it can never hide a match), each row carries a badge of the server's icon on its accent with the connection dot in the corner, and the accent also rules the terminal's tab strip. Folded sections are device-local (settings), the grouping itself syncs. Default desktop window 1800×1600. Platform folders committed. |
| CI | `.github/workflows/ci.yml`: dart analyze+test, flutter analyze+test, docker build, and a client build matrix (android/linux/macos/ios/windows on native runners — the same matrix `release.yml` publishes). |

## Local shell — platform matrix

| Platform | Offered | Why |
|---|---|---|
| Linux | yes | Verified end to end against a real pty: echo, `stty size` before/after resize, `^C`, exit status, teardown. |
| macOS | yes, unverified on a Mac | The App Sandbox is **off** (`macos/Runner/*.entitlements`), so the shell reaches the real `$HOME` and keeps job control. With it on the child inherits it: container-only `$HOME`, unreadable files, `can't set tty pgrp`. The warning path is kept and still fires if the entitlement is ever put back. Existing installs are migrated out of the old container on first launch (`SandboxMigration`) — see the section below. |
| Windows | no | `flutter_pty` 0.4.2 builds a malformed command line there (see AGENTS.md §5). Vendoring the package fixes it in ~6 lines; until then the setting says so rather than shipping a broken shell. |
| Android | no | Only toybox's `/system/bin/sh` inside the app's own sandbox, with no way to install tools. |
| iOS/iPadOS | never | iOS apps may not spawn child processes at all. |

## macOS: no App Sandbox

The local shell is why, and the trade is deliberate rather than incidental.

- **What it buys.** A child process inherits its parent's sandbox, so a
  sandboxed Séance can only offer a shell confined to its own container — no
  real `$HOME`, no files outside it, and no job control (`^C` reaches the
  shell instead of the command). Apple's own guidance for this case is to
  ["enable SSH on their machine if they want to run locally"](https://developer.apple.com/forums/thread/685544).
  Séance is ad-hoc signed and distributed outside the App Store, so nothing
  requires the sandbox.
- **What it costs, permanently.** A compromise of Séance — or of any package
  it depends on — now reaches everything the user can reach, and the SSH keys
  and vault this app holds are precisely the target. Reverting is one line in
  both entitlements files.
- **What existing installs see.** `SandboxMigration` copies the whole support
  tree out of `~/Library/Containers/<bundle id>/…` on the first unsandboxed
  launch, before any store is opened. It copies rather than moves, and lands
  the copy with a single directory rename so the result is all-or-nothing —
  a half-filled directory would read as "already in use" next launch and
  strand the remainder for good. A failure **stops startup** with an
  explanation rather than starting empty, because everything after that point
  writes and any one write would make the retry impossible. Success is
  silent.
- **The one thing that is not transparent.** The login-keychain ACL is bound
  to the code signature, so every user gets one *"Séance wants to use your
  confidential information"* prompt. That is not new — ad-hoc signing means an
  exact code hash, so it already happens on every rebuild. What is new is that
  dismissing it can no longer destroy the vault:
  `loadOrCreateFromKeystore(hasExistingVault:)` refuses to mint a replacement
  key when an encrypted vault is already on disk.

None of the macOS half is verified — no Mac ran any of it. See AGENTS.md §4
for the manual checklist to run before releasing an unsandboxed build.

## Test inventory (what proves what)

- `seance_protocol/test/crypto_test.dart` — KDF determinism + domain separation,
  seal/open round-trip, wrong-key & tamper rejection, auth-verifier hashing,
  recovery-code round-trip + corruption detection.
- `seance_protocol/test/records_test.dart` — model JSON, record codec opacity,
  LWW tie-breaking, DTO round-trips.
- `seance_core/test/pure_logic_test.dart` — ssh_config import, TOFU verdicts,
  danger linter, paste sanitizer, secret redaction.
- `seance_core/test/llm_test.dart` — Anthropic/OpenAI request build + response
  parse, command JSON extraction, SSE parse, chat tool loop (paste + search),
  redaction of outbound context.
- `seance_core/test/sync_test.dart` — engine: push, two-device convergence,
  concurrent-edit LWW, tombstones.
- `seance_core/test/sync_coordinator_test.dart` — domain⇄record mapping converges
  across two devices; edit propagation.
- `seance_core/test/local_shell_test.dart` — shell/argument/environment
  resolution per platform (incl. the whole-environment rule and the dropped
  `LINES`/`COLUMNS`), the support matrix, and `LocalShellSession` against a
  fake pty: bytes both ways, resize, exit → `onClosed` once, late `onClosed`,
  idempotent close, spawn failure.
- `seance_app/test/sandbox_migration_test.dart` — the container copy against
  real temp directories: every store plus the nested checkout tree, the
  container left intact, a live install never overwritten by a stale
  container, a stray `.DS_Store` neither blocking the migration nor being
  destroyed by it, a leftover staging directory not mistaken for data, and —
  the one that matters — a copy that dies partway leaving the destination
  completely untouched.
- `seance_app/test/master_key_test.dart` — a master key is minted on a genuine
  first run, read back when present, and **never** replaced when a vault
  already exists.
- `seance_app/test/local_shell_test.dart` — the availability double gate,
  macOS sandbox detection, a session with no server (never renders `@:0`),
  local tabs grouping/fallback, the pinned row, and the setting's round-trip.
- `seance_core/test/stores_probe_ssh_test.dart` — SecretVault, ConfigStore,
  ProbeService orchestration, `SshSessionManager.verifyHostKey` (TOFU), headless
  engine.
- `seance_sync_server/test/server_test.dart` — all endpoints, auth, rate limit,
  protocol-version + open-registration gating, per-account isolation.
- `seance_sync_server/test/sqlite_storage_test.dart` — real SQLite round-trips +
  durability across reopen.
- `seance_sync_server/test/integration_test.dart` — real client vs live server,
  two devices converge over HTTP; bad-login rejection.
- `app/seance_app/test/host_key_dialog_test.dart` — TOFU dialog first-use +
  hard changed-key block.
- `app/seance_app/test/bootstrap_test.dart` — startup phases stay in one
  MaterialApp; pushed routes resolve `AppScope`.
- `seance_core/test/ssh_diagnostics_test.dart` — connection-log capture and the
  readable `SshConnectException` summary; agent-auth rejected pre-network.
- `seance_core/test/http_sync_client_test.dart` — sync base-URL normalization
  (trailing slash / whitespace tolerated).
- `seance_core/test/remote_file_system_test.dart` — remote POSIX paths, sticky
  cancellation, POSIX metadata, chmod, readlink, and symlink creation.
- `app/seance_app/test/remote_files_controller_test.dart` — SFTP browser home,
  sorting/filtering/selection/bookmarks, OSC-directory follow, aggregate
  recursive transfers, durable managed copies, concurrent checkout, and
  save-during-upload guards.
- `app/seance_app/test/managed_remote_file_store_test.dart` — durable index,
  SHA-256 reconciliation, corruption quarantine, and traversal-safe cleanup.
- `app/seance_app/test/file_export_service_test.dart` — streamed staging and
  Android SAF method-channel contract.
- `app/seance_app/test/server_grouping_test.dart` — sectioning: no groups means
  no headers, case-folded keys with the first spelling kept, ungrouped last,
  collapse/expand, and a stale collapsed key doing nothing.
- `app/seance_app/test/server_appearance_test.dart` — every colour × icon
  renders, the same accent resolves differently per brightness, and the status
  dot keeps its tooltip inside the badge.
- `packages/seance_core/test/sync_coordinator_test.dart` — a server's group,
  colour and icon travel between devices, and regrouping converges like a
  rename (a group is a name its members carry, not a record that can dangle).

## Open items (roughly prioritized)

### Should do next
1. **ssh-agent auth.** `AuthMethod.agent` currently throws `UnsupportedError`
   (dartssh2 has no local-agent path). Options: implement an agent client
   (`$SSH_AUTH_SOCK` / `\\.\pipe\openssh-ssh-agent`) that signs via a custom
   `SSHKeyPair`, or resolve keys from the agent at the app layer and pass them as
   `privateKey` credentials. This is the power-user gap.
2. **Run the app for real.** Build for Linux/macOS (platform folders are now
   committed), drive a live SSH session, confirm resize + TOFU + assistant
   end-to-end. First real runs exist on macOS and Android; a full end-to-end
   pass is still open.
3. **Honor the redaction toggle.** `AppSettings.redactionEnabled` is persisted
   but `ChatController` always redacts (safe default). Wire the setting through
   (e.g. a pass-through redactor when disabled).

### Known limitations to revisit
4. **Sync re-key UX.** Enrolling in sync re-keys the vault to the
   encryption-passphrase-derived key and re-encrypts only secrets referenced by
   *current* configs. Document/enforce "set up sync before storing lots of
   secrets", or generalize re-encryption (needs a `VaultStore.listIds`).
5. **UTF-8 across packets.** `XtermTerminalEngine.feed` uses lenient UTF-8
   decode; a multibyte sequence split across SSH packets can mangle a glyph.
   A byte-accumulating decoder (or the libghostty engine) fixes it.
6. **LLM context = last-N-lines + selection only.** OSC 133 "last command block"
   extraction isn't implemented. Streaming (`streamChat`) exists in the providers
   but the sidebar uses non-streaming `chat()`; switch for nicer UX.
7. **Provider-native web search** (Anthropic/OpenAI server-side tool) is unused;
   only client-side SearXNG/Brave. Add the native path for cloud providers.
8. **Terminal PTY initial size** is 80×24 for the moment between connect and the
   first widget layout, then the xterm `autoResize` fits the grid to the pane and
   forwards it to the remote PTY. (This resize path used to recurse infinitely —
   `terminal.onResize` → `session.resize` → `engine.resize` → `terminal.resize`
   → … — which left the grid stuck at 80 cols; `XtermTerminalEngine.resize` now
   only records the size. Regression: `test/terminal_resize_test.dart`.)
9. **Command suggestions are keystroke-based.** Capture reconstructs the
   command line from outbound keystrokes, so it can't tell a shell command from
   text typed at a no-echo prompt (a password). That's why the feature is
   opt-in and the stats stay local — only a snippet the user explicitly saves
   syncs. A precise version needs OSC 133 command-block marks (see item 6).
10. **Mobile keyboard reflow** relies on `resizeToAvoidBottomInset` +
    `adjustResize`; the on-screen key row reserves space above the keyboard, and
    with the resize loop fixed the terminal now re-fits its rows/cols as the
    keyboard and key row change the available space. A soft keyboard with a
    floating/overlay mode may still cover the last row — revisit if it recurs.

11. **Terminal selection & copy/paste.** Selection semantics live in the
    vendored xterm fork (`third_party/xterm`, every divergence documented
    in its PATCHES.md): single/double/triple click (word / soft-wrap-aware
    line), shift-click extension, drag selection anchored to content with
    edge autoscroll, selections and the scrolled-up viewport surviving
    scrollback trims, and mouse-report hygiene for remote apps. Right-click
    gives Copy / Paste / Select all. Ctrl+Shift+C/V/A elsewhere; ⌘C/⌘V/⌘A
    on macOS/iPadOS (macOS additionally retargets the native Edit menu via
    `MainFlutterWindow.swift`: routes to the focused terminal, falls back
    to text fields; focus pushed over the `seance/menu` channel, the
    session's `TerminalController` exposed on `TerminalSession`). **Needs a
    macOS build to verify the native-menu path** (no Swift toolchain in the
    Linux dev container).
12. **SFTP browser follow-up.** The delayed edit, file-manager, shell, and
    Android export groups are implemented. Live OpenSSH, BBEdit/macOS, Android
    SAF/provider, and iOS editor validation remain, along with Files widget
    platform fakes, resumable/background transfers, and promised-file drag-out.
    Full design/progress: [`docs/SFTP.md`](SFTP.md).

### Deliberately deferred (per proposal)
Port-forwarding UI, ProxyJump execution (import only), Mosh,
terminal **splits** (multiple panes visible at once), OIDC on the sync server,
libghostty terminal backend (swap behind `TerminalEngine` when it tags a stable
release).

> **Un-deferred:** *per-server connection tabs* — several sessions to one
> server, shown as a tab strip one level below the server list (not top-level
> tabs; adjacent tabs are always the same server). The v1 proposal folded this
> into the deferred "tabs-within-tabs/splits" line; it is now built. Splits
> (showing more than one pane at once) stay deferred.

## Housekeeping
- ~~The GitHub repository is still named `Ghossht`~~ — renamed; the remote is
  `L-K-M/Seance` now.
- Release/build/deploy tooling is in place and aligned with the sibling repos:
  `scripts/release.sh` (pubspec-lockstep bump + `v*` tag →
  `.github/workflows/release.yml` publishes the server binaries, the GHCR image,
  and all five app clients: Android APK, Linux/macOS/Windows desktop bundles,
  unsigned iOS IPA),
  `scripts/build.sh` (all local targets, staged into `dist/`), `./update.sh`
  (compose redeploy).
- Flutter platform folders are now committed, carrying the `Séance` app name,
  launcher icons from `media-sources/seance-icon.png`, and the macOS
  entitlements. The -34018 keystore startup failure is fixed by using the
  legacy login keychain (`usesDataProtectionKeychain: false`) — not by a
  keychain entitlement, which would stop ad-hoc-signed builds from launching.
  The sync server serves the icon as `/favicon.ico` plus a tiny landing page
  at `/`.
- SQLite storage in the server needs `libsqlite3` at runtime; the Docker image
  installs `libsqlite3-0` and `bin/` sets a loader override for `.so.0`.
- Identity files referenced by path (`~/.ssh/…`) resolve against the *real*
  home on macOS: the sandbox points `$HOME` at the app container, so `~`
  expansion strips the container suffix (`expandHomePath` in seance_core), and
  the entitlements carry a read-only temporary exception for `~/.ssh` so the
  connect-time read is permitted. Unreadable key files now fail with an
  actionable message instead of a raw `PathNotFoundException`. Keys outside
  `~/.ssh` work via the server editor's Browse… button: a native panel (shows
  dot-directories) mints a security-scoped bookmark (`seance/secure_bookmarks`
  channel + `files.bookmarks.app-scope` entitlement), stored device-locally in
  settings — never synced; other devices fall back to the path. Every
  identity-file read (path or bookmark, success or failure) is appended to a
  device-local audit trail, `identity_reads.jsonl` in the app-support dir.
