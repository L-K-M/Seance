# Seance Project Analysis

Review date: 2026-07-09  
Reviewer: OpenCode  
Base branch: `main` at `a24d2ce`  
Note: this file did not exist in the working tree when requested, so it was created.

## Scope And Method

I reviewed the Flutter app, pure-Dart core/protocol packages, sync server,
Docker/deploy files, tests, README, proposal, status document, and agent notes.
The focus was correctness, safety, performance/stutter risk, UI quality,
missing features, and product delight.

Verification performed:

- `dart analyze packages/seance_protocol packages/seance_core packages/seance_sync_server` passed.
- `dart test packages/seance_protocol packages/seance_core packages/seance_sync_server` initially failed because the container has `libsqlite3.so.0.8.6` but not the unversioned `libsqlite3.so` name that Dart's `sqlite3` package opens.
- After adding a temporary symlink outside the repo and setting `LD_LIBRARY_PATH`, all pure-Dart tests passed.
- Flutter was not on `PATH` at review start, so the SDK was bootstrapped outside the repo.
- `flutter analyze` in `app/seance_app` passed.
- `flutter test` in `app/seance_app` passed.

High-level read:

- The project is already unusually well structured for a young personal app: clean package split, explicit seams, meaningful tests, documented constraints, and a coherent safety posture around TOFU, command review, and redaction.
- The biggest correctness risks are in sync semantics. The lower-level sync engine has tombstone tests, but the app/coordinator path does not appear to preserve enough durable sync metadata to correctly emit domain-object deletions or avoid re-publishing unchanged pulled records.
- The biggest immediate safety issues are command/snippet insertion paths that can stage raw newlines and chat tool output that can target the wrong active session.
- The biggest deployment risk is the sync server's operational hardening: plaintext stored bearer tokens, unbounded request sizes, default plain-HTTP compose exposure, weak healthcheck, and generic input validation gaps.
- The biggest UX gap is that the UI claims or implies support for some workflows that are incomplete or platform-fragile: ssh-agent defaults, typed private-key paths on sandboxed macOS, narrow layout thresholds, and ignored redaction settings.

## Highest-Impact Findings

### A-001: Generated commands can auto-execute if a provider returns CR/LF

Severity: P0 safety  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/command_generator.dart:82`, `app/seance_app/lib/services/xterm_engine.dart:105`

The command generator inserts `suggestion.command` directly into the terminal.
If the model returns `\n` or `\r`, xterm forwards it to SSH as Enter. That
breaks the product invariant that generated commands are reviewed and never
auto-run.

Recommendation: route generated command text through `PasteSanitizer.sanitize`,
reject multi-line output with a visible error, and add a widget/unit test proving
newlines do not reach `injectInput`.

### A-002: Snippets can also execute multi-line bodies despite the UI promise

Severity: P0 safety  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/snippets_pane.dart:9`, `app/seance_app/lib/ui/snippets_pane.dart:97`, `app/seance_app/lib/ui/snippets_pane.dart:293`

The snippets pane says snippets are inserted for review and never run, but the
editor allows multi-line bodies and insertion writes the body directly. A saved
snippet containing a newline can execute one or more commands immediately.

Recommendation: prevent CR/LF insertion by default. If multi-line snippets are
desired later, they need an explicit confirmation and a different affordance,
because terminal paste semantics are execution semantics.

### A-003: App-level deletes likely do not sync and can resurrect records

Severity: P0 data correctness  
Confidence: High  
Implementation confidence: Medium  
References: `app/seance_app/lib/app_state.dart:186`, `app/seance_app/lib/app_state.dart:311`, `app/seance_app/lib/services/app_services.dart:157`, `packages/seance_core/lib/src/sync/sync_coordinator.dart:43`

The lower-level `SyncEngine` has tombstone support, but the app/coordinator path
collects only currently-existing domain objects. Local server/snippet deletes do
not appear to create durable tombstones. The app also creates a fresh
`InMemoryLocalRecordStore` for each sync, so it has no durable mirror of known
record IDs or dirty/delete state. A remote copy can therefore reappear on a
later pull.

Recommendation: add persistent sync metadata/mirror storage for domain records,
emit tombstones on local delete, and add app-level sync tests for deleting a
server and a snippet across two app stores.

### A-004: Sync record envelope metadata is not authenticated

Severity: P0 security/protocol  
Confidence: High  
Implementation confidence: Medium; protocol-breaking  
References: `packages/seance_protocol/lib/src/records/record_codec.dart:21`, `packages/seance_protocol/lib/src/crypto/vault.dart:123`

The encrypted payload contains `{kind, data}`, but the server-visible envelope
fields `id`, `updatedAt`, `deviceId`, and `deleted` are not bound to the AEAD.
A malicious or compromised server cannot read plaintext, but it can alter
conflict metadata, flip deletion state, replay a blob under another ID, or force
LWW outcomes.

Recommendation: bind canonical envelope metadata as AEAD associated data or
duplicate it inside ciphertext and verify on decrypt. Tombstones need
authenticated kind and ID too.

### A-005: Sync IDs leak kind and hostnames despite the privacy model

Severity: P0 privacy/protocol  
Confidence: High  
Implementation confidence: Medium; migration needed  
References: `packages/seance_core/lib/src/sync/sync_coordinator.dart:57`, `packages/seance_core/lib/src/sync/sync_coordinator.dart:68`, `packages/seance_core/lib/src/sync/sync_coordinator.dart:79`

The docs say record kind is inside ciphertext, but generated IDs include values
such as `secret:...`, `hostkey:<host:port>`, and `snippet:...`. The server can
learn record kind and hostnames/ports.

Recommendation: use opaque IDs. For records that need deterministic joins, use
a keyed deterministic ID such as `HMAC(recordIdKey, kind || naturalKey)`.

### A-006: Sync re-encrypts and republishes unchanged records

Severity: P0 data correctness/performance  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_core/lib/src/sync/sync_coordinator.dart:43`, `packages/seance_protocol/lib/src/records/record_codec.dart:25`, `packages/seance_protocol/lib/src/records/lww.dart:18`

Every sync collection turns all current domain objects into local records with a
fresh nonce and the current device ID. Records pulled from device A and unchanged
on device B can be republished as device B's writes. This creates extra traffic,
false conflicts, and tie-break outcomes based on device ID rather than user
intent.

Recommendation: persist dirty state and origin metadata. Only push local edits,
preserve server seq/origin for unchanged pulled records, and add regression
tests for "pull unchanged record then sync again".

### A-007: Rejected pushes can strand stale local data

Severity: P1 data correctness  
Confidence: High  
Implementation confidence: Medium; wire change likely  
References: `packages/seance_core/lib/src/sync/sync_engine.dart:81`, `packages/seance_sync_server/lib/src/server.dart:170`

When the server rejects a losing push, the result only includes `{id, seq,
accepted:false}`. The client marks the local loser as synced and advances the
high-water mark. If the winner's seq is already at or below the new high-water,
the client can miss the winning record.

Recommendation: include the winning record in rejected push results, or force a
targeted fetch/reconcile for rejected IDs before advancing the high-water mark.

### A-008: Secret sync has no independent version timestamp

Severity: P1 data correctness/security  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_protocol/lib/src/models/secret.dart:11`, `packages/seance_core/lib/src/sync/sync_coordinator.dart:53`

`Secret` has no `updatedAt`. Secret sync records use the owning server's
timestamp. A password/key change can fail to sync if the server config timestamp
does not change, and shared secrets can inherit whichever server timestamp wins.

Recommendation: add secret metadata/versioning and sync each secret once with
its own timestamp.

### A-009: Chat tool paste can land in the wrong SSH session

Severity: P0 safety  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/chat_sidebar.dart:56`, `app/seance_app/lib/ui/chat_sidebar.dart:79`

Chat sends terminal context from the active session at send time, but the paste
tool callback uses `state.activeSession` later when the model responds. If the
user switches tabs while the provider is thinking, a suggested command can be
staged into a different host.

Recommendation: capture the intended `TerminalSession` at send time and stage
tool output only into that session if it is still present and connected.

### A-010: Server tokens are stored plaintext

Severity: P0 server security  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_sync_server/lib/src/sqlite_storage.dart:35`, `packages/seance_sync_server/lib/src/sqlite_storage.dart:103`, `packages/seance_sync_server/lib/src/server.dart:187`

Bearer tokens are persistent and stored plaintext in SQLite. A DB read leak
becomes API access: pull blobs, push destructive records, or delete the account.
This weakens the "breach-tolerant blob store" story.

Recommendation: store token hashes only, add creation/expiry/revocation fields,
support logout/revoke-all, and require re-authentication or a fresh login for
destructive account deletion.

### A-011: Concurrent server pushes can violate LWW

Severity: P0 sync correctness  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/server.dart:159`, `packages/seance_sync_server/lib/src/sqlite_storage.dart:125`

Conflict check and upsert are separate operations. Two concurrent requests can
both read the same existing record, then the older write can overwrite a newer
write after the newer write was accepted.

Recommendation: move conflict resolution into a storage-level transaction/CAS,
or add a per-account/per-record mutex around check-and-upsert. Add a concurrent
push regression test.

### A-012: Server request and record sizes are unbounded

Severity: P0 availability  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/server.dart:200`, `packages/seance_sync_server/lib/src/server.dart:159`, `packages/seance_sync_server/lib/src/sqlite_storage.dart:145`

The server reads request bodies without a size cap, accepts unbounded batches
and record blobs, and returns unpaged pulls. A malicious or buggy client can
consume memory, CPU, and disk.

Recommendation: enforce max body bytes, records per push, record ID/device/blob
lengths, and paginated pull limits.

### A-013: Compose exposes plain HTTP on all host interfaces by default

Severity: P0 deployment safety  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/docker-compose.yml:14`, `packages/seance_sync_server/README.md:23`

The sync protocol depends heavily on transport confidentiality for bearer tokens
and verifier login. The compose file publishes `8787:8787` by default, making it
easy to expose plain HTTP to a LAN or the internet by accident.

Recommendation: default to `127.0.0.1:8787:8787` or remove host ports and show a
reverse-proxy deployment. The app should also warn or block non-loopback HTTP
sync URLs.

## App And UI Findings

### B-001: ssh-agent is the default even though it is unsupported

Severity: P1 UX/functionality  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/server_editor.dart:54`, `packages/seance_core/lib/src/ssh/ssh_session.dart:212`

New servers default to `AuthMethod.agent`, and config import can create agent
configs, but connection throws `UnsupportedError` before network activity.

Recommendation: until real agent support exists, default new servers to a
supported auth path or label agent as unavailable in the UI with a clear help
message. Real ssh-agent support remains a major power-user feature.

### B-002: Redaction setting is persisted but ignored

Severity: P1 UX/trust  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/settings_screen.dart:186`, `packages/seance_core/lib/src/llm/chat_controller.dart:96`, `app/seance_app/lib/ui/command_generator.dart:72`

`AppSettings.redactionEnabled` is saved, but chat and command generation always
redact. The safe default is good, but a toggle that does nothing damages trust.

Recommendation: wire the setting through to a no-op redactor when disabled, or
remove/disable the toggle until the product is ready to honor it. Prefer wiring
it with a warning because the setting already exists.

### B-003: macOS sandboxed builds likely cannot read typed identity-file paths

Severity: P1 platform functionality  
Confidence: High  
Implementation confidence: Medium  
References: `app/seance_app/lib/ui/server_editor.dart:184`, `app/seance_app/lib/services/app_services.dart:183`, `app/seance_app/macos/Runner/Release.entitlements:10`

The editor asks users to type paths such as `~/.ssh/id_ed25519`, but sandboxed
macOS file access normally requires user-selected files and security-scoped
bookmarks. Typed paths are likely to fail in release builds.

Recommendation: add a platform file picker and persist security-scoped access
on macOS. Also add a picker for importing `~/.ssh/config`.

### B-004: Wide layout activates too early and can squeeze the terminal

Severity: P1 layout/usability  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/adaptive_shell.dart:17`, `app/seance_app/lib/ui/adaptive_shell.dart:28`, `app/seance_app/lib/ui/adaptive_shell.dart:54`

The wide breakpoint is 720 px, but fixed server/sidebar pane widths consume
most of that. At tablet/small-window widths, the terminal can become a narrow
sliver or overflow after resizing.

Recommendation: raise the breakpoint, clamp pane widths to available
constraints, and collapse the assistant/sidebar before starving the terminal.

### B-005: ssh_config import loses important OpenSSH semantics

Severity: P1 adoption/functionality  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_core/lib/src/ssh_config/ssh_config_import.dart:43`, `packages/seance_core/lib/src/ssh_config/ssh_config_import.dart:87`, `app/seance_app/lib/app_state.dart:201`

Wildcard defaults such as `Host * User ... IdentityFile ...` are ignored, and
`ProxyJump` is parsed but not mapped into `ServerConfig`. Re-importing creates
new UUIDs without duplicate handling.

Recommendation: apply OpenSSH-style defaults for imports, preserve unsupported
fields as warnings, and deduplicate by alias/host/user/port.

### B-006: Connection races can create ghost sessions or stale UI state

Severity: P1 correctness/UX  
Confidence: Medium-high  
Implementation confidence: Medium  
References: `app/seance_app/lib/app_state.dart:231`, `app/seance_app/lib/app_state.dart:245`, `app/seance_app/lib/app_state.dart:270`

`connect` creates a terminal tab but does not install it until after an await.
Overlapping connects can both proceed. Late completions do not verify that the
tab is still the current tab for that config before assigning session/error.

Recommendation: install a connecting placeholder before any await and guard
late completions with identity checks.

### B-007: Remote shell close can still look connected

Severity: P1 UX/correctness  
Confidence: Medium  
Implementation confidence: High  
References: `packages/seance_core/lib/src/ssh/ssh_session.dart:127`, `app/seance_app/lib/app_state.dart:259`

Core calls `onClosed` when the shell completes, but the app handler only clears
`connecting`. It may leave `tab.session` non-null and UI status ambiguous.

Recommendation: mark the tab closed/disconnected, close or dispose the session,
and show a reconnect affordance.

### B-008: Narrow-mode system back likely exits instead of returning to the list

Severity: P1 mobile UX  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/adaptive_shell.dart:23`, `app/seance_app/lib/ui/adaptive_shell.dart:77`

Narrow navigation is local `_viewingTerminal` state rather than a route or
`PopScope`. The app bar back button works, but Android/iOS system back gestures
may exit the app instead of returning to the server list.

Recommendation: add `PopScope` to flip `_viewingTerminal` back to false.

### B-009: Platform names and default sizes need polish

Severity: P1 visual/platform polish  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/linux/runner/my_application.cc:48`, `app/seance_app/windows/runner/main.cpp:27`, `app/seance_app/ios/Runner/Info.plist:9`

Linux/Windows/iOS still show names like `seance_app` or `Seance App` in some
platform files. Desktop default window size is 1800x1600, which is oversized for
many laptops.

Recommendation: set consistent user-visible names and choose a more laptop-safe
default size with remembered window geometry later.

### B-010: Failed connection engines and app services can leak

Severity: P2 resource/performance  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/app_state.dart:232`, `app/seance_app/lib/app_state.dart:270`, `app/seance_app/lib/main.dart:59`, `app/seance_app/lib/app_state.dart:491`

`XtermTerminalEngine` instances created for failed connections are not disposed
on the error path. `AppState.dispose()` exists, but bootstrap does not call it.

Recommendation: dispose engines on failed connect/retry and call `AppState` /
service cleanup from `_BootstrapState.dispose()`.

### B-011: Async UI paths can call setState after dispose

Severity: P2 robustness  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/chat_sidebar.dart:77`, `app/seance_app/lib/ui/settings_screen.dart:311`, `app/seance_app/lib/ui/command_generator.dart:70`

Several long async UI actions set state after awaits without checking
`mounted`. This can show up as noisy exceptions when dialogs/routes close while
requests are in flight.

Recommendation: add `if (!mounted) return` before post-await `setState`, route
changes, or snackbars.

### B-012: Probe/status updates rebuild too much UI

Severity: P2 performance/stutter  
Confidence: Medium-high  
Implementation confidence: Medium  
References: `app/seance_app/lib/app_state.dart:136`, `app/seance_app/lib/ui/adaptive_shell.dart:37`, `app/seance_app/lib/ui/terminal_pane.dart:46`

Probe updates call global `notifyListeners`, and broad widgets listen to the
same `AppState`. With many hosts, periodic probes can rebuild terminal/sidebar
subtrees unnecessarily.

Recommendation: split notifiers/selectors for server-list status, active
session, sync status, and terminal pane state. Keep terminal widgets out of
probe-driven rebuild paths.

### B-013: Probing is unbounded and not app-lifecycle paused

Severity: P2 performance/network noise  
Confidence: Medium  
Implementation confidence: Medium  
References: `packages/seance_core/lib/src/probe/probe_service.dart:85`, `app/seance_app/lib/app_state.dart:136`

`probeAll` probes all servers concurrently, and the app starts probes without
pausing when hidden. Large server lists can create connection bursts and wakeups.

Recommendation: add a concurrency limit, jitter, and app lifecycle pause/resume.

### B-014: Terminal UTF-8 decoding can corrupt split multibyte sequences

Severity: P2 terminal correctness  
Confidence: High  
Implementation confidence: Medium  
References: `app/seance_app/lib/services/xterm_engine.dart:122`

Each SSH chunk is decoded independently with lenient UTF-8. If a multibyte
character is split across packets, it can become replacement characters.

Recommendation: use a streaming UTF-8 decoder or a byte-native terminal feed
path.

### B-015: Dialogs and fixed drawers can overflow on small screens

Severity: P2 mobile/layout  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/keyboard_interactive_dialog.dart:16`, `app/seance_app/lib/ui/command_generator.dart:123`, `app/seance_app/lib/ui/terminal_pane.dart:55`

Keyboard-interactive fields are plain text and not scroll-wrapped, the command
generator dialog is not clearly constrained for small screens, and the fixed
380 px drawer can exceed narrow phones.

Recommendation: make dialogs scrollable/constrained, obscure sensitive prompts
when appropriate, and size drawers from available width.

### B-016: Form validation is thin

Severity: P2 UX/data quality  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/ui/server_editor.dart:109`, `app/seance_app/lib/ui/snippets_pane.dart:257`, `app/seance_app/lib/ui/settings_screen.dart:342`

Ports accept out-of-range values, blank credentials can be saved, empty snippets
silently close, and settings save failures have little user feedback.

Recommendation: add validators and keep the user in context on errors.

### B-017: Local command suggestions can store secret-like input before filtering

Severity: P2 privacy  
Confidence: Medium-high  
Implementation confidence: High  
References: `app/seance_app/lib/app_state.dart:401`, `app/seance_app/lib/app_state.dart:421`

Command capture records first and filters suggestions later. If the capture
heuristic sees password-like text, secret-like strings can persist locally even
if never displayed.

Recommendation: skip storage when `SecretRedactor.wouldRedact` is true.

### B-018: File-backed stores are non-atomic and fragile on corruption

Severity: P2 data durability  
Confidence: Medium  
Implementation confidence: Medium  
References: `app/seance_app/lib/services/file_stores.dart:29`, `app/seance_app/lib/services/file_stores.dart:84`, `app/seance_app/lib/services/file_stores.dart:137`

JSON stores rewrite whole files directly and load paths lack corruption
recovery. A crash during write can corrupt startup data.

Recommendation: write temp files, flush, rename atomically, keep a `.bak`, and
surface recovery UI or logs for corrupt JSON.

### B-019: Some configured backend capabilities lack UI

Severity: P2 UX/completeness  
Confidence: High  
Implementation confidence: High  
References: `app/seance_app/lib/services/app_settings.dart:17`, `app/seance_app/lib/services/app_services.dart:230`, `app/seance_app/lib/ui/settings_screen.dart:177`

Brave Search exists in settings/services, but Settings only exposes SearXNG.
There is also no obvious provider test action, clear API key button, or sync
logout/account-management flow.

Recommendation: expose configured capabilities or remove dead settings until
they are usable.

## Core, Protocol, SSH, And LLM Findings

### C-001: Static auth verifier is password-equivalent over intercepted transport

Severity: P1 security  
Confidence: High  
Implementation confidence: High for warning/enforcement; Medium for protocol proof  
References: `packages/seance_protocol/lib/src/sync/dtos.dart:63`, `packages/seance_core/lib/src/sync/http_sync_client.dart:70`

Login sends the raw base64 auth verifier. If used over plain HTTP or intercepted
TLS, an attacker can log in and mutate encrypted sync state.

Recommendation: immediately warn/block non-loopback HTTP sync URLs. Longer
term, use nonce-based proof or PAKE-style login rather than sending a static
verifier.

### C-002: Chat terminal context persists beyond one turn

Severity: P1 safety/cost  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/llm/chat_controller.dart:94`, `packages/seance_core/lib/src/llm/chat_controller.dart:104`, `packages/seance_core/lib/src/llm/chat_controller.dart:189`

The code comment says terminal context is one-turn-only, but the message that
contains terminal context is appended to `_history`. Stale untrusted scrollback
can influence future turns and token usage can grow without bound.

Recommendation: build transient request messages with context, but persist only
the user's actual redacted message. Add a history cap or summarization.

### C-003: `paste_to_prompt` bypasses danger-linter feedback

Severity: P1 safety  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/llm/chat_controller.dart:158`, `packages/seance_core/lib/src/llm/danger_linter.dart:16`

Chat tool output is sanitized to one line, but destructive command patterns are
not scanned before staging. The core safety design says command suggestions get
independent danger linting.

Recommendation: run `DangerLinter.scan` before staging and surface findings in
the UI near the inserted prompt/toast.

### C-004: "What was sent" audit omits tool results

Severity: P1 transparency/privacy  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/llm/chat_controller.dart:52`, `packages/seance_core/lib/src/llm/chat_controller.dart:147`

Tool results are appended to history and sent back to the provider, but they are
not included in `ChatResult.sent`. Search snippets and staged-command text can
leave the machine without appearing in a future inspector.

Recommendation: redact and add `SentContext('tool results', ...)`, and label web
search results as untrusted context.

### C-005: Remote-controlled KDF and record sizes need bounds

Severity: P1 availability/security  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_protocol/lib/src/crypto/vault.dart:40`, `packages/seance_protocol/lib/src/sync/dtos.dart:55`, `packages/seance_protocol/lib/src/records/record.dart:83`

`Argon2Params.fromJson` accepts arbitrary memory/iteration values, and record
JSON accepts arbitrary blob sizes. A malicious server can cause CPU/memory DoS
during prelogin or pull.

Recommendation: enforce sane min/max KDF params, salt/verifier lengths, record
field sizes, and blob sizes with clear `FormatException`s.

### C-006: Private-key parse failure can leak an opened socket

Severity: P2 resource correctness  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/ssh/ssh_session.dart:226`, `packages/seance_core/lib/src/ssh/ssh_session.dart:241`

The TCP socket opens before private-key parsing. If parsing fails, the error path
throws without closing the socket.

Recommendation: close/destroy the socket before throwing on key parse failures.

### C-007: SSH connection log freeze is app-dependent

Severity: P2 performance  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/ssh/ssh_session.dart:75`, `packages/seance_core/lib/src/ssh/ssh_session.dart:287`

Core exposes `freeze()` to avoid per-packet trace storms, but `connect()` does
not freeze the log itself. The app does it externally, so core's own contract is
fragile.

Recommendation: freeze the log after the shell opens in core.

### C-008: Silent enum fallbacks hide corrupt or future data

Severity: P2 data correctness  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_protocol/lib/src/records/record.dart:9`, `packages/seance_protocol/lib/src/models/server_config.dart:5`, `packages/seance_protocol/lib/src/models/secret.dart:4`

Unknown record/auth/secret kinds silently become `serverConfig`, `password`, or
`password`. This can misroute corrupt/future-version records and weaken auth
semantics.

Recommendation: throw `FormatException` or add explicit unknown handling.

### C-009: Core provider command-generation path does not enforce redaction

Severity: P2 safety invariant  
Confidence: Medium-high  
Implementation confidence: Medium  
References: `packages/seance_core/lib/src/llm/openai_provider.dart:126`, `packages/seance_core/lib/src/llm/anthropic_provider.dart:121`

The app appears to redact before calling `generateCommand`, but provider methods
send prompt/context directly if reused elsewhere.

Recommendation: add a higher-level command-generation controller/decorator that
always applies redaction and linting before provider calls.

### C-010: HTTP, LLM, and search clients lack timeouts/dispose APIs

Severity: P2 reliability/performance  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/sync/http_sync_client.dart:13`, `packages/seance_core/lib/src/llm/openai_provider.dart:17`, `packages/seance_core/lib/src/llm/anthropic_provider.dart:15`, `packages/seance_core/lib/src/llm/search.dart:26`

Network calls can hang indefinitely, and internally-created `http.Client`s are
not closed.

Recommendation: add configurable timeouts and `close()`/`dispose()` methods.

### C-011: ProbeService has a dispose race and banner ambiguity

Severity: P2 reliability/correctness  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/probe/probe_service.dart:22`, `packages/seance_core/lib/src/probe/probe_service.dart:86`, `packages/seance_core/lib/src/probe/probe_service.dart:116`

`probeAll()` probes all servers concurrently. Disposing during an awaited probe
can still try to add to a closed stream. The prober's docs imply SSH banner
validation, but any successful TCP connection is treated as online.

Recommendation: limit concurrency, re-check closed state after awaits, and
either validate `SSH-` banners or rename the status to "TCP reachable".

### C-012: Paste sanitizer mishandles bare carriage returns

Severity: P2 safety edge case  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/terminal/paste_sanitizer.dart:32`

`sanitize()` rejects both CR and LF, but `sanitizeFirstLine()` splits only on
`\r?\n`, not bare `\r`. A bare carriage return should be treated as a line
break.

Recommendation: split on `\r\n|\r|\n` and add a unit test.

### C-013: LWW can be poisoned by future client clocks

Severity: P2 sync robustness  
Confidence: Medium-high  
Implementation confidence: Medium  
References: `packages/seance_protocol/lib/src/records/lww.dart:18`

Any device with a badly future-skewed clock can create records that win for a
long time.

Recommendation: clamp extreme future timestamps, surface clock-skew warnings,
or move to monotonic per-device logical clocks.

### C-014: Redactor misses common token formats

Severity: P3 privacy  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/llm/redaction.dart:14`

Current patterns miss common high-value formats such as OpenAI `sk-proj-...`,
GitHub `github_pat_...`, and AWS secret access keys.

Recommendation: add focused patterns and tests. Keep false positives acceptable
because redaction is a safety feature.

### C-015: RecoveryKey accepts non-canonical encodings and arbitrary lengths

Severity: P3 crypto hygiene  
Confidence: Medium  
Implementation confidence: High if keys are always 32 bytes  
References: `packages/seance_protocol/lib/src/crypto/recovery_key.dart:34`, `packages/seance_protocol/lib/src/crypto/recovery_key.dart:92`

The checksum is over decoded bytes, not canonical Base32 text, and decoded
length is not explicitly checked.

Recommendation: require 32 decoded bytes and canonical re-encoding.

### C-016: Headless terminal UTF-8 comments do not match implementation

Severity: P3 test fidelity  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_core/lib/src/terminal/terminal_engine.dart:47`

`receivedText` claims lossy UTF-8 but uses `String.fromCharCodes`; `type()` uses
`codeUnits`. Non-ASCII tests/input will be wrong.

Recommendation: use `utf8.decode(..., allowMalformed: true)` and `utf8.encode`.

## Sync Server And Operations Findings

### D-001: Compose healthcheck does not check the server

Severity: P1 operations  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/docker-compose.yml:25`

The healthcheck runs `seance-sync --help`, which can succeed while the HTTP
server, port, or database is broken.

Recommendation: use a real HTTP healthcheck against `/healthz` or `/readyz`.
This may require adding a tiny built-in check mode or a minimal HTTP client in
the image.

### D-002: Malformed base64/verifier input can become 500s, and 500s leak detail

Severity: P1 API robustness/security  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/server.dart:81`, `packages/seance_sync_server/lib/src/server.dart:128`, `packages/seance_sync_server/lib/src/server.dart:215`

Base64 decoding happens outside validation/catch paths in multiple places, and
the error handler returns `e.toString()` to clients.

Recommendation: validate and return 400 for malformed input; return generic 500
bodies and log details server-side.

### D-003: Rate limiter is in-memory, unbounded, username-only, and narrow

Severity: P1 abuse resistance  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_sync_server/lib/src/server.dart:120`, `packages/seance_sync_server/lib/src/rate_limiter.dart:9`

Username-only rate limits let one attacker lock out a username and grow memory
with sprayed names. Registration and prelogin are not rate-limited.

Recommendation: key by username plus trusted client IP, cap/evict buckets, add
`Retry-After`, and rate-limit registration/prelogin with clear reverse-proxy IP
trust rules.

### D-004: Input validation is too loose

Severity: P1 robustness/security  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_protocol/lib/src/sync/dtos.dart:31`, `packages/seance_protocol/lib/src/sync/dtos.dart:81`, `packages/seance_protocol/lib/src/records/record.dart:83`

Usernames, KDF params, verifier length, record IDs, device IDs, and blobs are
accepted with little bounding.

Recommendation: enforce non-empty usernames, length and charset limits, 32-byte
verifier, expected salt lengths, sane Argon2 bounds, record field limits, and
tombstone/blob consistency.

### D-005: Registration is non-atomic

Severity: P1 correctness  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/server.dart:78`, `packages/seance_sync_server/lib/src/sqlite_storage.dart:79`

Registration does check-then-create. Duplicate races can surface as 500s or
partial account state if multi-statement operations fail between steps.

Recommendation: create account, initial seq, and token in a transaction; catch
unique constraint and return 409.

### D-006: Dockerfile may initialize `/data` with wrong ownership on some builders

Severity: P1 operations  
Confidence: Medium-high  
Implementation confidence: High  
References: `packages/seance_sync_server/Dockerfile:36`

`VOLUME /data` appears before `chown`. Some builder/runtime combinations can
initialize named volumes root-owned, preventing the non-root process from
creating SQLite files.

Recommendation: create and chown `/data` before declaring the volume, or use an
entrypoint/init strategy.

### D-007: Shutdown is forceful and SQLite is not explicitly closed

Severity: P1 operations/data durability  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/bin/seance_sync_server.dart:62`, `packages/seance_sync_server/lib/src/server.dart:56`, `packages/seance_sync_server/lib/src/sqlite_storage.dart:182`

Signal handling force-closes the HTTP server and does not call storage close.

Recommendation: graceful HTTP close with timeout, close storage, then exit.

### D-008: `/healthz` is liveness only, not readiness

Severity: P2 operations  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/server.dart:33`

`/healthz` only proves the process can answer. It does not prove storage is
usable.

Recommendation: add `/readyz` with a lightweight DB check and point deployment
healthchecks at readiness.

### D-009: SQLite schema lacks foreign keys/cascade and transactions

Severity: P2 data integrity  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_sync_server/lib/src/sqlite_storage.dart:25`, `packages/seance_sync_server/lib/src/sqlite_storage.dart:95`

Schema and operations rely on manual deletes and mostly non-transactional
multi-step changes.

Recommendation: enable `PRAGMA foreign_keys=ON`, use `ON DELETE CASCADE`, add
`busy_timeout`, and wrap create/delete/batch push in transactions.

### D-010: No request/audit logging

Severity: P2 operations  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/server.dart:47`, `packages/seance_sync_server/lib/src/server.dart:211`

There is no structured request logging. Errors are returned but not logged in a
useful server-side way.

Recommendation: log method/path/status/duration, auth failures/rate limits, and
push/pull counts. Never log bearer tokens or blobs.

### D-011: Backup/restore guidance is missing

Severity: P2 operations  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/lib/src/sqlite_storage.dart:24`, `update.sh:39`

SQLite WAL mode is enabled, but docs/scripts do not explain safe backup and
restore.

Recommendation: document `sqlite3 .backup`, volume backup including WAL, restore
steps, and a pre-update backup suggestion.

### D-012: Docker CI builds but does not run a smoke test

Severity: P2 release confidence  
Confidence: High  
Implementation confidence: High  
References: `.github/workflows/ci.yml:68`

CI builds the image but does not run it. This would miss loader, permission,
healthcheck, and entrypoint regressions.

Recommendation: run the image, wait for health, hit `/healthz`, and ideally
perform register/login against a temp volume.

### D-013: Release image reference may rely on mixed-case repository normalization

Severity: P3 release hygiene  
Confidence: Medium  
Implementation confidence: High  
References: `.github/workflows/release.yml:109`, `README.md:108`

Docker image names must be lowercase. The README documents lowercase GHCR, while
release workflow may derive from mixed-case `${{ github.repository }}`.

Recommendation: hardcode or normalize `ghcr.io/l-k-m/seance`.

### D-014: Compose lacks container hardening and resource limits

Severity: P3 operations/security  
Confidence: High  
Implementation confidence: Medium  
References: `packages/seance_sync_server/docker-compose.yml:8`

The container already runs non-root, which is good, but lacks `cap_drop`,
`no-new-privileges`, resource limits, and optionally read-only root filesystem.

Recommendation: add hardening after testing SQLite and Dart runtime behavior
with writable `/data` and any required temp dirs.

### D-015: Server docs drift from implementation

Severity: P3 docs  
Confidence: High  
Implementation confidence: High  
References: `packages/seance_sync_server/pubspec.yaml:3`, `packages/seance_sync_server/Dockerfile:25`, `packages/seance_sync_server/README.md:58`, `packages/seance_protocol/lib/src/records/lww.dart:23`

Examples: docs mention a scratch image but Dockerfile uses Debian; docs say
every request has `protocolVersion`, but some endpoints do not; docs describe
LWW as `(updatedAt, deviceId)` while code also uses `seq` for exact ties.

Recommendation: update docs or adjust implementation intentionally.

## Missing Features And Product Gaps

### SSH and terminal power-user features

- Real ssh-agent support across Unix/macOS/Windows, including 1Password and
  Bitwarden agents.
- `known_hosts` import/export and fingerprint copy/share affordances.
- First-run `~/.ssh/config` import wizard with diff/duplicate handling.
- ProxyJump execution, not just parsing/import warnings.
- Port forwarding UI for local/remote/dynamic forwards.
- SFTP browser or at least quick upload/download into the active host.
- One-click deploy public key to server, like `ssh-copy-id`, especially useful
  for per-device keys and mobile.
- Terminal appearance settings: font size, font family, theme, cursor shape,
  scrollback size, bell behavior, and ligature toggle.
- OSC 133 shell integration for precise current command, last command block,
  cwd, exit status, and command suggestions that do not rely on keystroke
  reconstruction.
- Mosh support for flaky mobile networks.

### Sync and account features

- Sync logout, revoke current token, revoke all devices, and list active
  devices/sessions.
- Recovery/re-key UX that clearly explains when secrets are re-encrypted and
  what remains local-only.
- Conflict/deletion audit screen: "what changed on this device vs remote".
- Encrypted export/import without a server, useful for Syncthing/git/USB users.
- Registration modes beyond open/closed: first-account-only and invite token.
- Admin CLI for backup, restore, token revocation, and account deletion.

### Assistant features

- Streaming sidebar chat. Providers already expose streaming; the UI uses
  non-streaming calls, which feels slower.
- "What was sent" inspector using `SentContext`, including terminal context and
  tool results.
- Provider-native web search for Anthropic/OpenAI-compatible backends where
  available, in addition to client-side SearXNG/Brave.
- Model/provider test button with latency and error details.
- Command review card before insertion: command, explanation, danger findings,
  copy, save as snippet, insert.
- Conversation history cap and per-session chat transcripts, optionally synced
  only if explicitly enabled.
- Better local/offline story: Ollama discovery, local model recommendations, and
  a privacy badge when no cloud provider is configured.

### Navigation and daily-use UX

- Command palette for quick connect, settings, snippets, sync now, and command
  generation.
- Server search, tags/groups, favorites, recently used, and per-server color or
  small avatar.
- Quick connect for one-off hosts without saving.
- Duplicate detection on import and manual add.
- Remember per-server working layout: last pane size, assistant tab, and terminal
  font scale.
- Richer connection diagnostics with actionable next steps and copyable logs.
- Per-platform shortcuts shown in UI, not only implied.

## Visual And Delight Ideas

The app already has a memorable name. Lean into it without making the UI silly:

- "Seance table" empty state: a quiet circular table/terminal motif with a
  single primary action: "Summon a server".
- "Spellbook" snippets: snippets grouped as reusable incantations, with
  placeholders presented as fill-in runes/cards rather than plain forms.
- Host identity charms: small deterministic sigils generated from host key
  fingerprints, useful for spotting unexpected host-key changes visually.
- Connection mood lighting: subtle border/glow colors for connecting, online,
  offline, and host-key-danger states.
- A "Planchette" command palette: fast fuzzy launcher for hosts, snippets, and
  assistant actions.
- Delightful but useful session recap: when a session closes, show duration,
  exit status if known, last cwd/command if shell integration exists, and buttons
  for reconnect/copy log/save snippet.
- "Ghost text" generated command preview in the prompt line before insertion,
  requiring one explicit accept.
- Optional ambient terminal themes named after paranormal concepts, while keeping
  a professional default theme.

## Performance And Stutter Watchlist

- Avoid global `notifyListeners` for probe/sync/log changes that rebuild terminal
  views.
- Add network timeouts everywhere: sync, LLM, model discovery, and search.
- Limit concurrent probes and large sync batches.
- Avoid re-encrypting every record each sync; dirty tracking will improve both
  performance and correctness.
- Add terminal throughput smoke tests: large output, resize spam, Unicode split
  packets, and rapid session switching.
- Consider a worker isolate only if SQLite sync-server operations become a real
  bottleneck; size limits and pagination are the first pragmatic step.

## Suggested Implementation Queue

These are the entries I would implement first because they are high-confidence,
small-to-medium changes, and can be separated into low-conflict PRs.

1. Safety gate terminal insertion: sanitize/reject CR/LF for generated commands
   and snippets. Add tests.
2. Fix chat target capture so `paste_to_prompt` cannot stage into the wrong host.
3. Fix `PasteSanitizer.sanitizeFirstLine` bare-CR handling and add redactor
   patterns for common tokens.
4. Add app lifecycle/dispose/mounted fixes for leaks and common async UI races.
5. Improve narrow/wide layout thresholds, mobile back behavior, and fixed drawer
   sizing.
6. Wire or remove the redaction toggle. Prefer wiring it, with safe default on.
7. Make ssh-agent unavailable state explicit until real agent support lands.
8. Harden sync server request parsing: generic 500 body, malformed base64 400,
   basic input bounds, and request body limits.
9. Change compose default exposure to loopback and document reverse proxy usage.
10. Add server transaction/mutex protection for concurrent LWW writes.
11. Add HTTP/LLM/search timeouts and client close APIs.
12. Add sync coordinator/app deletion metadata. This is important but larger;
    isolate it in its own branch with focused tests.

Protocol-breaking items should be planned before implementation:

- Authenticated envelope metadata.
- Opaque deterministic record IDs.
- Push rejection payload changes.
- Secret version schema.
- Token hash migration and expiry/revocation model.

## Existing Strengths Worth Preserving

- The `TerminalEngine`, store, sync, and provider seams are the right shape;
  extend them rather than bypassing them.
- TOFU behavior is strict and tested. Keep changed-host-key handling visually and
  procedurally distinct from ordinary errors.
- Review-before-run is the central assistant invariant. Any new assistant tool
  should preserve it.
- Redaction-on-by-default is the right default. If a disable toggle is honored,
  it should be explicit and reversible.
- The sync server being a dumb blob store is a good design; harden the metadata
  and operational edges without turning it into a plaintext app server.
- The app already has several strong UX touches: default snippets, command
  suggestions, connection logs, mobile key row, top prompt-safe notices, and a
  clear product theme.
