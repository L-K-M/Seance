# Status & next steps

Living snapshot of where Séance is, what's proven, and what to pick up next.
Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-09-05 — a server can be excluded from sync and kept on
one device._

## Done (implemented + verified)

| Area | State |
|---|---|
| `seance_protocol` | Complete. Models (incl. strict Bookmark, Snippet with `{{placeholder}}` parsing/fill, and `ServerConfig`'s optional `group`/`color`/`icon`/`loginScript` — named accents and icons rather than raw values, so they render per theme and an unknown name decodes to "none"), E2E crypto, forward-compatible records (serverConfig/hostKey/secret/snippet/bookmark/unknown), LWW, sync DTOs. |
| `seance_core` | Complete. SSH+TOFU, ssh_config import, prober, sync engine + fail-soft coordinator, LLM providers + chat tools, danger linter, redaction, paste sanitizer, stores; per-server login script typed into the shell once it opens. |
| `seance_sync_server` | Complete. 7 endpoints, in-memory + SQLite storage, rate limiting, Dockerfile + compose. |
| `seance_app` | Complete; `flutter analyze` clean, widget tests pass. Server list is the top-level list; each server can hold several sessions shown as a per-server tab strip (a strip appears only at 2+ tabs, so a single session looks title-bar-less as before), with ⌘T/Ctrl+Shift+T + a "New tab" affordance, status dot: green/grey/red + connecting spinner; resizable tiled panes); right-hand utility panel with Assistant + Snippets + **Files** tabs. Files is session-scoped SFTP over the existing SSH transport: responsive navigation, OSC 7 follow mode, picker/desktop-drop upload, local open + conflict-checked upload-back, mkdir/rename/delete, progress/cancel; narrow/Android gets a full-screen route. See [`docs/SFTP.md`](SFTP.md) for implementation state and remaining real-device work. Snippets are synced command templates with `{{placeholder}}` fill-in dialogs; assistant chat when configured, ⌘/Ctrl+↵ sends; inline command generator (⌘K / Ctrl+Shift+K, prefilled from the current shell line, Enter generates+inserts+closes) turns NL into a reviewed command; the native macOS menu is kept intact (Edit/Window/…) with Settings wired to ⌘, and a Terminal ▸ Generate Command… (⌘K) item; Settings is still an in-app route; settings suggest models from the endpoint with manual fallback; failed connections show a summary + expandable connection log. **Automatic sync** runs at startup, after any server/snippet add/edit/delete (debounced), and every 5 min, with a live header/settings status; the "Sync now" button remains. **Credential sync** is opt-in (global toggle × per-server "allow this credential to sync"; E2E-encrypted). A server row's menu also **duplicates** it: fresh id and timestamps, a "… copy" / "… copy 2" label that continues rather than stutters, everything else carried over, and the credential copied into a vault entry of its own (never shared — a copy that shared one would be rewritten by an edit to either server, and the sync layer keys a credential record by the credential rather than by the server holding it, so two owners would push two versions of one record). Deleting a server now drops its vault entry only when no other server still names it — the check the `secret:` tombstone path already made, extended to the local delete, since a shared entry is reachable through sync and through the editor whatever duplication does — and shares one queue with duplication — as do saving a server and applying a sync round, since both write the config store and the vault; re-entry is detected by zone identity against the action that is running, so a callback registered inside a mutation (a listener's microtask, the auto-sync debounce a save schedules) can queue one of its own once that mutation is over — so two deletes of servers sharing an entry cannot each read the list before the other's removal lands and both leave it behind, and a credential rewritten in place under an unchanged ref cannot happen while a duplicate is reading it. A duplicate also re-reads its source before saving, since the guard is cheaper than the invariant it stands in for: planning is a read, so nothing is created until it passes, and `SourceServerChanged` can say so. A server can also be **excluded from sync** outright (per-server switch in the editor, confirmed when there is something to retract; `cloud_off` mark on its row): its config is never pushed, and a copy pushed before the switch went on is retracted with a tombstone — so it also leaves the other devices, which the switch's subtitle says. A retraction the copy on the sync server outranks (another device's clock running ahead of this one's, or an edit made while this one was offline) is re-dated one millisecond past the record that beat it and pushed again in the same run: re-minting the same losing date every five minutes would leave the switch on here and the config on every other device forever, which is the multi-device case the switch exists for. Turning the switch back off is the mirror: the retraction it revokes may have been re-dated past this device's own clock, so an honest re-inclusion stamp would still lose — the live record is re-dated past its own tombstone instead, and the device stops applying a retraction it has withdrawn rather than deleting the server it just brought back. Its credential is retracted with it, off the sync server — unless a still-synced server shares that vault entry, in which case it is neither withdrawn nor frozen, since a secret record is keyed by the credential rather than by the server holding it. What a `secret:` tombstone does *not* do is delete anything from a vault: it is staged and pushed, never honoured on apply. A tombstone carries no sealed payload — `RecordCodec.decrypt` reads the envelope's flag without opening anything — so a delete is the one signal a sync server can assert entirely on its own, and honouring these would hand it a way to empty the vault (tombstone the configs, then the credentials no config still names). The cost is that the other devices keep an orphaned vault entry no config names, invisible in a UI that lists servers; the fix is sealing tombstones, not trusting this one — and until then a config tombstone is honoured on the same say-so, as it always has been, so a hostile sync server can still delete every synced server's *settings* on every device (never a credential or a pin); sealing closes that too. A pinned host key is withheld for the same reason (it is keyed by `host:port`, and deleting it elsewhere would drop that device back to trust-on-first-use), though new pins for an address only excluded servers use are no longer pushed. The **built-in text editor** opens at the top with the app's monospace stack, has an in-file find bar (⌘F/Ctrl+F; Enter/F3/⌘G cycle, match-case toggle, all matches highlighted) and basic syntax highlighting (shell, python, js/ts, dart, json, yaml, ini/conf, dockerfile, sql, c-family, xml, markdown — detected by name/extension/shebang); for a server file ⌘S/Ctrl+S saves **and uploads immediately** (⇧⌘S keeps it local; conflicts still prompt). Transient notices app-wide use **top toasts**, never bottom SnackBars, so they can't cover the shell prompt at the bottom of the terminal. On **touch platforms** the terminal shows an on-screen key row (Esc/Tab/Ctrl [sticky]/^C/arrows/Home/End/PgUp/PgDn/`\|` `/` `-` `~` + hide-keyboard) and reflows above the soft keyboard. **Command suggestions** (opt-in, local only) surface frequently-run commands in the Snippets tab to save as snippets. **Server groups, colours and icons** are per-server and synced: the list files servers into collapsible sections (alphabetical, ungrouped last; no headers at all until something is grouped, and a live filter overrides collapsed sections so it can never hide a match), each row carries a badge of the server's icon on its accent with the connection dot in the corner, and the accent also rules the terminal's tab strip. Folded sections are device-local (settings), the grouping itself syncs. On **Android**, backgrounding no longer kills the sessions: a `dataSync` foreground service anchors the process while any session is connecting/connected (ongoing notification with the live count, opt-out in Settings ▸ General; `BackgroundKeepAlive` drives it through the `seance/keepalive` channel — on other platforms it is a no-op). Default desktop window 1800×1600. Platform folders committed. |
| Linux packaging | `scripts/package-linux.sh` turns a built Flutter Linux bundle into `seance_<version>-1_<arch>.deb` and `seance-linux-x64.AppImage`. The .deb's `Depends` is derived from the bundle's actual ELF headers (readelf NEEDED → a soname→package table incl. Ubuntu 24.04 `t64` renames as dpkg alternatives, glibc/libstdc++ floors from symbol versions; a documented optional-soname list covers lazily-loaded native assets like package:jni's `libjvm.so`), the AppImage is built with a pinned appimagetool. Wired into `scripts/build.sh` (Linux `app` target), `ci.yml` (builds + uploads the packages every run), and `release.yml` (x64 assets). **x64 only**: Flutter publishes no linux-arm64 host artifacts (`releases_linux.json` is x64-only), so no arm runner can `flutter build linux` — revisit when that changes. The glibc floor tracks the CI toolchain (currently
2.38, from building on ubuntu-24.04) — dpkg enforces it via `Depends`, and
AppImage users on older distros get a clear loader error instead. Deliberately
no .rpm/Flatpak — the AppImage covers non-Debian distros; it uses the system GTK3 (present on any desktop install) rather than bundling it. |
| CI | `.github/workflows/ci.yml`: dart analyze+test, flutter analyze+test, docker build, and a client build matrix (android/linux x64/macos/ios/windows on native runners — the same matrix `release.yml` publishes; the Linux entry also runs the packaging and uploads the artifacts). |

## Test inventory (what proves what)

- `packages/seance_protocol/test/crypto_test.dart` — KDF determinism + domain separation,
  seal/open round-trip, wrong-key & tamper rejection, auth-verifier hashing,
  recovery-code round-trip + corruption detection.
- `packages/seance_protocol/test/records_test.dart` — model JSON, record codec opacity,
  unknown-kind logging/refusal, LWW tie-breaking, DTO round-trips.
- `packages/seance_protocol/test/bookmark_test.dart` — every bookmark kind round-trips;
  strict unions, kind fields, ids, dates, and immutable rules.
- `packages/seance_core/test/pure_logic_test.dart` — ssh_config import, TOFU verdicts,
  danger linter, paste sanitizer, secret redaction.
- `packages/seance_core/test/llm_test.dart` — Anthropic/OpenAI request build + response
  parse, command JSON extraction, SSE parse, chat tool loop (paste + search),
  redaction of outbound context.
- `packages/seance_core/test/sync_test.dart` — engine: push, two-device convergence,
  concurrent-edit LWW, tombstones.
- `packages/seance_core/test/sync_coordinator_test.dart` — domain⇄record
  mapping, unknown-kind preservation, fail-soft apply, tombstone dispatch, and
  that a server's group, colour and icon travel between devices with
  regrouping converging like a rename (a group is a name its members carry,
  not a record that can dangle). Plus exclude-from-sync, one bullet per
  invariant:
  - an excluded server is retracted rather than pushed, credential included,
    and the retraction is dated at the exclusion so repeat rounds are no-ops;
  - the credential is retracted under the same id the push used, asserted
    against a real vault, and the tombstone that leaves carries no payload;
  - a `secret:` tombstone is staged and pushed but never honoured against a
    vault — unsealed, so the date on it is the sync server's to choose, which
    is why the refusal is unconditional rather than last-write-wins;
  - a host key is withheld only when no synced server shares the address;
  - a credential a still-synced server shares is neither withdrawn nor frozen;
  - an excluded server survives both its own retraction and another device's
    stale copy, config *and* credential;
  - excluding on one device removes it from the other, even when the copy on
    the sync server outranks the retraction — and re-including supersedes the
    retraction, even one already re-dated past this device's clock;
  - a server nobody excluded is never re-tombstoned, checked against
    `rescheduleOutranked` directly, since reaching it through `applyToStores`
    proves the caller's filter and never the guard;
  - one refused write does not sink the whole re-dating pass;
  - changing the flag without a strictly later `updatedAt` throws in every
    build — a real throw, not an assert, since asserts are stripped from the
    release build users run. The editor builds
    its record through the constructor with a monotonic `updatedAt`, so that
    throw guards `copyWith` callers rather than anything a user can reach.
- `packages/seance_core/test/stores_probe_ssh_test.dart` — SecretVault, ConfigStore,
  ProbeService orchestration, `SshSessionManager.verifyHostKey` (TOFU), headless
  engine.
- `packages/seance_sync_server/test/server_test.dart` — all endpoints, auth, rate limit,
  protocol-version + open-registration gating, per-account isolation.
- `packages/seance_sync_server/test/sqlite_storage_test.dart` — real SQLite round-trips +
  durability across reopen.
- `packages/seance_sync_server/test/integration_test.dart` — real client vs live server,
  two devices converge over HTTP; bad-login rejection.
- `app/seance_app/test/host_key_dialog_test.dart` — TOFU dialog first-use +
  hard changed-key block.
- `app/seance_app/test/bootstrap_test.dart` — startup phases stay in one
  MaterialApp; pushed routes resolve `AppScope`.
- `app/seance_app/test/keystore_resilience_test.dart` — a locked/missing OS
  keyring (Ubuntu auto-login, no gnome-keyring) must not kill startup:
  probes return null, reads degrade to "not set", writes fail with a clear
  message, the locked vault throws instead of mis-decrypting, and recovery
  works when the keystore comes back.
- `packages/seance_core/test/ssh_diagnostics_test.dart` — connection-log capture and the
  readable `SshConnectException` summary; agent-auth rejected pre-network; the
  login-script keystroke shape (one Enter, edges trimmed, interior newlines
  and non-ASCII kept).
- `packages/seance_core/test/http_sync_client_test.dart` — sync base-URL normalization
  (trailing slash / whitespace tolerated).
- `packages/seance_core/test/remote_file_system_test.dart` — remote POSIX paths, sticky
  cancellation, POSIX metadata, chmod, readlink, and symlink creation.
- `app/seance_app/test/remote_files_controller_test.dart` — SFTP browser home,
  sorting/filtering/selection/bookmarks, OSC-directory follow, aggregate
  recursive transfers, durable managed copies, concurrent checkout, and
  save-during-upload guards.
- `app/seance_app/test/managed_remote_file_store_test.dart` — durable index,
  SHA-256 reconciliation, corruption quarantine, and traversal-safe cleanup.
- `app/seance_app/test/file_export_service_test.dart` — streamed staging and
  Android SAF method-channel contract.
- `app/seance_app/test/background_keep_alive_test.dart` — the anchor state
  machine: activates on the first live session, coalesces repeats into count
  updates, deactivates on the last, and honors the enable/disable setting
  (including re-anchoring live sessions on re-enable); the settings field
  round-trips in `app_settings_test.dart`.
- `app/seance_app/test/server_grouping_test.dart` — sectioning: no groups means
  no headers, case-folded keys with the first spelling kept, ungrouped last,
  collapse/expand, and a stale collapsed key doing nothing.
- `app/seance_app/test/server_appearance_test.dart` — every colour × icon
  renders, the same accent resolves differently per brightness, and the status
  dot keeps its tooltip inside the badge.
- `app/seance_app/test/editor_syntax_test.dart` — language detection
  (extension/basename/shebang), tokenizer per family (comments, strings with
  escapes, numbers, keywords, meta), non-overlap invariant, search matching
  and caps, and search-over-syntax span layering that reassembles the text.
- `app/seance_app/test/built_in_text_editor_test.dart` — atomic save
  round-trips, BOM/CRLF preservation, external-change refusal, and the editor
  screen: Ctrl-S save-and-upload (immediate, no dialog; reconcile fallback on
  failure), local-only save without an upload target, open-at-top, monospace
  stack, and the find bar (counts, wrap, case toggle, highlight ranges).
- `app/seance_app/test/server_exclude_from_sync_test.dart` — the row's
  exclusion mark appears only for an excluded server, and describes itself as
  a label rather than a tooltip (a `ListTile` merge keeps one tooltip and
  every label, so a tooltip there would be silently dropped); plus when
  excluding asks for confirmation (only when another device could lose the
  server).

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
13. **Android background keep-alive is CI-verified only.** The foreground-
    service anchor (`KeepAliveService`, driven by
    `services/background_keep_alive.dart` through the `seance/keepalive`
    channel) is unit-tested (`background_keep_alive_test.dart`) and compiled
    by the CI matrix, but has not run on real
    hardware: battery impact, OEM task killers ignoring the FGS, the
    POST_NOTIFICATIONS ask, and the Android 15 six-hour `dataSync` timeout
    path are all unexercised on a device. If store distribution ever happens,
    revisit whether Play accepts `dataSync` for an indefinite session anchor
    or whether `specialUse` (with its justification form) is the safer fit.
14. **Split the sync round's fetch from its apply.** `AppState._mutate`
    serializes store mutations, and a sync round joins the queue because it
    writes the config store and the vault. That holds the queue across
    network I/O. It is bounded — `HttpSyncClient` times every request out at
    30 s, a timeout ends the round rather than retrying, and `_mutate`
    releases in a `finally` — so a dead network costs one timeout, not a
    wedged app. A slow-but-alive one costs more, because `SyncEngine.sync`
    runs up to five rounds and `SyncCoordinator.run` up to two passes. The
    fix is a `SyncCoordinator` that fetches outside the queue and applies
    inside it, which preserves the invariant (no store write interleaves with
    a delete's reference count or a duplicate's plan) while a slow fetch stops
    stalling saves and deletes.

15. **Seal tombstones.** A tombstone carries no sealed payload, so its date
    is the sync server's to choose: a config tombstone is honoured on that
    say-so today (a hostile server can delete every synced server's *settings*
    on every device), and `secret:` / `hostkey:` tombstones are refused for
    the same reason, at the cost of an orphaned vault entry and an
    unretracted pin on the other devices. An authenticator over id, kind and
    date keyed like the payload closes all three at once.

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
- **Poltergeist**, the sibling two-pane SFTP app, consumes `seance_protocol`
  and `seance_core` as pinned dependencies, with a short queue of small
  upstream asks (forward-compatible record kinds being the important one) —
  see [docs/POLTERGEIST.md](POLTERGEIST.md). Two remaining gaps it documents
  are live Séance bugs tracked on their own, not just as Poltergeist asks:
  - deletes never writing tombstones, so deleted servers resurrect on
    the next pull — and every pull is effectively full, since the app
    rebuilds its record store per round
    ([#54](https://github.com/L-K-M/Seance/issues/54));
  - pulled hostkey pins silently overwriting a conflicting local pin
    ([#56](https://github.com/L-K-M/Seance/issues/56)).
- Release/build/deploy tooling is in place and aligned with the sibling repos:
  `scripts/release.sh` (pubspec-lockstep bump + `v*` tag →
  `.github/workflows/release.yml` publishes the server binaries, the GHCR image,
  and all app clients: Android APK, Linux `.deb` + AppImage + bundle (x64),
  macOS/Windows desktop bundles,
  unsigned iOS IPA),
  `scripts/build.sh` (all local targets, staged into `dist/`), `./update.sh`
  (compose redeploy; gates on the published `/healthz` answering and honors
  per-deployment overrides in `packages/seance_sync_server/.env`, e.g.
  `SEANCE_PUBLISH_ADDR` for containerized reverse proxies).
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
