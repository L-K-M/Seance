# Séance: engineering and product backlog

Consolidated: 2026-09-04. Review base: `2f99f4e` (`origin/main`).

This is the **unfinished-work list**. Each entry gives a starting point, a bounded
next step, and verification criteria. Completed work belongs in the ledger, not
in implementation instructions.

Sources: [review-first snapshot](astra.md),
[unaltered July analysis](docs/reviews/analysis-2026-07-25.md),
[proposal](PROPOSAL.md), [status](docs/STATUS.md), and current source/tests.
SOL/SEA/AST identifiers remain stable; grouped identifiers denote consolidated
findings, not independent duplicate tasks. The archive preserves original wording,
line references, PR history and ideas; its relative paths refer to the repo root.

## Assessment and evidence

The largest risks are sync correctness, trust reconciliation and credential
recovery. Encryption primitives do not make the current sync envelope or account
lifecycle breach-safe. Do not call sync production-ready until the P0 gates pass.

Terminal selection has substantial fork coverage; it is not an unimplemented
feature. However, scrollback search, complete keyboard navigation and mobile
interaction validation remain missing. Parser hangs must be distinguished from
raster/layout stutter before changing renderers.

The committed screenshot is historical: it predates tabs, server groups, Files
and the editor. Visual recommendations combine that screenshot with source
inspection, **not current native-device testing**. No frame-time measurements
were collected. Signed Apple keystore behavior, physical mobile keyboards/Back,
real SSH/SFTP latency, monitor geometry, battery use and Docker runtime still need
validation.

### Verification

Baseline at the review base: 263 package tests, 309 app tests, 137 terminal-fork
tests passed; two existing macOS-only goldens skipped on Linux. Package and app
analysis were clean. Continuation used Flutter 3.47.2 / Dart 3.13.2. SQLite tests
needed an environment-only `libsqlite3.so` symlink to the installed `.so.0`.

```bash
dart pub get
dart analyze packages/seance_protocol packages/seance_core packages/seance_sync_server
dart test packages/seance_protocol packages/seance_core packages/seance_sync_server
(cd app/seance_app && flutter pub get && flutter analyze && flutter test)
(cd third_party/xterm && flutter pub get && flutter test)
```

Final integrated verification is recorded after the implementation PRs merge.
Platform compilation is not equivalent to real-device validation.

### Priority and execution

- **P0:** security boundary, data loss or permanent divergence.
- **P1:** common workflow, privacy or reliability failure.
- **P2:** performance risk, accessibility or substantial polish.
- **P3:** optional product work or lower-risk maintenance.

Pull first. For a bug, reproduce with a failing test before fixing it. One bounded
change per branch/PR; review and merge before marking it complete. Keep public
protocol/core compatibility with Poltergeist. UI → service → core abstraction →
transport/storage; never bypass a layer to make a patch smaller.

Recommended sequence:

```text
versioned/authenticated records -> durable ledger + exact revisions -> deletes
                               -> durable host-key conflict resolution
storage transactions -> snapshot pagination -> quotas + honest convergence
recoverable vault migration -> credential transactions -> recovery onboarding
terminal benchmarks -> bounded parser/output work -> ergonomic shell actions
```

The migration entries below are plans, not permission to rewrite existing vaults
or change wire semantics without fixtures, compatibility policy and rollback.
Independent ergonomic work can proceed alongside them.

## P0: trust, sync and credentials

### Authenticate routing and conflict metadata — SOL-011

**Evidence:** `seance_protocol/lib/src/records/{record,record_codec}.dart` and
`crypto/vault.dart` authenticate `{kind,data}`, not ID, timestamp, device or
deleted flag. Empty tombstone blobs have no authentication. A breached server can
transplant ciphertext, forge deletions or replay old keys with winning metadata.

**Next:** specify a versioned canonical envelope binding purpose, schema, key
epoch, kind, identity, client revision/time, device and deletion inside AEAD.
Encrypt typed tombstones; exclude server-owned sequence from authentication.
Ship compatibility readers and migration fixtures before changing writers.

**Gate:** field-by-field tamper, transplant, replay and forged-tombstone tests;
old/new client interoperability, interrupted migration and rollback. Opaque IDs
(SOL-012) should use the same migration, not a second destructive rewrite.

### Durable ledger, typed deletes and exact acknowledgements — SOL-001, SOL-005, SOL-006, SOL-010, SOL-037, SOL-059

**Evidence:** `AppState.deleteServer/deleteSnippet`, `AppServices.runSync`,
`SyncCoordinator.collectLocal/applyToStores`, `LocalRecordStore.markSynced`,
`SyncEngine`. Hard deletes emit no tombstone; every run rebuilds an in-memory
mirror from sequence zero. Deleted items return ([#54](https://github.com/L-K-M/Seance/issues/54)).
Unchanged records are re-encrypted and attributed to this device. An old push
acknowledgement can clear a newer edit; secrets borrow server timestamps.
Manual sync bypasses the automatic run guard. Applying records rewrites whole
JSON collections repeatedly.

**Next, in separate slices:**

1. Persist record origin, cursor, dirty operations and independent revisions at
   initialization. Use one account-scoped queue for manual/automatic sync.
2. Acknowledge the exact sent operation/revision; leave newer edits dirty. Merge
   pulls against current domain state, not an earlier collection.
3. Record authenticated typed tombstones before domain deletion. Add delete APIs
   for every synced kind; tombstone opted-out credentials, including global
   opt-out, rather than merely stopping future uploads.
4. Give each secret its own identity/revision regardless of shared references.
5. Batch domain application into one transaction/write; preserve origin metadata
   until content changes. Reconcile remotely changed/deleted configs with live
   sessions as explicit orphans, not hidden live connections.

**Gate:** A deletes → both restart → alternating sync never resurrects any kind;
unchanged resync sends nothing; blocked push plus local edit retains the edit;
blocked apply plus domain edit cannot overwrite it; startup/manual/timer sync
serialize; crash/offline recovery and credential opt-out converge.

### Atomic server writes and pull snapshots — SOL-002, SOL-007

**Evidence:** `seance_sync_server/lib/src/{server,storage,sqlite_storage}.dart`
separates LWW comparison, sequence allocation, upsert, and pull/watermark reads.
Concurrent requests can overwrite a winner or expose inconsistent snapshots.
Batches can partially commit before returning an error.

**Next:** move compare/resolve/sequence/upsert into a storage batch transaction
(`BEGIN IMMEDIATE` for SQLite); serialize the memory backend equivalently.
Define atomic-batch versus explicit durable partial-result semantics. Add a
storage pull operation capturing watermark W and records `since < seq <= W`
in one snapshot; paginate against W, not a moving latest sequence.

**Gate:** barrier-controlled real HTTP/SQLite tests force a stale loser to write
after a winner; concurrent watermark capture, crashes mid-batch, lock contention
and separate processes cannot violate ordering/durability. PR #17's observed
client cursor remains necessary; it did not make the server transactional.

### Never silently re-trust synced host keys — AST-008 / SOL-023

**Evidence:** `SyncCoordinator.applyToStores` unconditionally overwrites pins,
bypassing local changed-key review ([#56](https://github.com/L-K-M/Seance/issues/56)).
`TofuVerifier` also lacks endpoint-level serialization/CAS for competing dialogs.

**Next:** route pin reconciliation through a trust service. Preserve established
local trust; durably quarantine conflicts with both fingerprints and explicit
resolution. Resolution creates a new revision so the same conflict cannot recur
forever. Canonicalize DNS case/trailing dot, IDNA, IP literals and ports before
lookup; validate imported key algorithm/encoding. Serialize first approval and
compare-and-set repins against the pin the dialog actually displayed.

**Gate:** matching/new/conflicting pins across two devices; concurrent first
connections; stale repin dialogs; restart and user resolution; equivalent endpoint
spellings. Do not replace silent overwrite with a silent skip that reports success.
Coordinate the public policy with Poltergeist and authenticated records.

### Transactional credential editing — SOL-029

**Evidence:** `ui/server_editor.dart` retains `secretRef` across auth changes.
Referenced-key passphrases are displayed but not persisted by `_save`; changing
only an existing stored key's passphrase is ignored. The old empty-key overwrite
was fixed in #7; that is not the remaining bug.

**Next:** model keep/replace/remove explicitly for password, stored key, referenced
key and agent. Validate each mode, save config/secret changes as one unit, and
remove obsolete local/synced credentials only after successful replacement.
Prompt for referenced-key passphrases without requiring storage.

**Gate:** every auth-mode transition, passphrase-only edits, unrelated config edits,
failed secret writes and cancelled dialogs preserve the intended credential.

### Recoverable vault re-key — SOL-030

**Evidence:** `AppServices._rekeyVault` overwrites secrets one by one, migrates only
currently referenced secrets, and changes memory before keystore persistence.
Failure can leave mixed-key ciphertext or lose unreferenced credentials.

**Next:** add `VaultStore.listIds`; stage and verify a complete new vault plus
recovery journal. Atomically switch data/key only after all records succeed;
retain rollback material until reopening works. Show/export recovery material
before the destructive phase. Enrollment must not partially persist account
settings/token on failure.

**Gate:** inject failure at every phase, including keystore write and restart;
all credentials reopen under either the old or new key, never a mixed vault.
Do not tell users to “set up sync first” as a substitute for recovery.

### Missing keystore key is not first run — SOL-031

**Evidence:** `services/secure_master_key.dart:probeKeystore` creates a key after
a null read without checking existing `vault.json` ciphertext. Locked-keystore
errors already degrade safely; a genuinely missing key is a different state.

**Next:** distinguish first run, locked keystore and lost key in the service.
If ciphertext exists, open recovery/unlock UI and leave it untouched. Verify iOS
entitlements under signed debug/profile/release; do not add macOS restricted
keychain groups that break ad-hoc builds.

**Gate:** signed Apple relaunch/update, code-signing/container migration, keystore
loss, Android backup restore and empty first run. Never synthesize replacement
keys over encrypted data. Coordinate with existing sandbox-migration PR #45.

### Hash, expire and revoke bearer tokens — SOL-048

**Evidence:** SQLite `tokens` contains permanent plaintext bearer tokens;
`DELETE /v1/account` accepts one without recent authentication. A DB/backup leak
therefore grants live API access, despite the breach-tolerant description.

**Next:** store token hashes, creation/expiry/last-use/device metadata and bounded
per-account sessions. Add logout, device listing, revoke-current/revoke-all, and
recent verifier authentication for deletion. Rotate old tokens during migration;
correct the documented database-leak model.

**Gate:** raw DB tokens cannot authenticate, expired/revoked tokens fail, concurrent
revoke/login/delete cannot revive an account, and migration does not retain live
plaintext token rows or backups without an explicit retention warning.

## P1/P2: protocol, recovery and storage

### Strict wire parsing and deterministic revisions — SOL-008, SOL-009, SOL-012, SOL-013

**Start:** protocol `records/`, `sync/dtos.dart`, core `sync_engine.dart`.
Missing fields currently default into acceptance; numeric truncation and weak
range checks remain outside the now-strict KDF parser. Exact LWW ties are not a
deterministic total order, and clients can supply server-owned sequence values.
Unknown-kind preservation in #58 is done; do not reintroduce kind guessing.

**Next:** require typed fields, lengths, nonnegative ranges and canonical envelope
combinations. Define version policy and typed parse errors; preserve/quarantine
unknown future data with visible skipped outcomes. Use an authenticated operation
ID/counter/HLC for total ordering; sequence is only a server delta cursor. Require
one acknowledgement per submitted ID, reject duplicates/unknown IDs, and report
pending/incomplete convergence after exhausted rounds. Derive opaque wire IDs
with a domain-separated keyed HMAC; current IDs expose kind and hostnames.

**Gate:** parser fuzz/property tests, commutative/associative/idempotent LWW,
exact ties, same-millisecond edits, clock rollback, missing acknowledgements,
unknown kinds across old/new clients, and migration interoperability.

### Remaining KDF and crypto assurance — SOL-014, SOL-016, SOL-017, SOL-018

**Done:** AST-001 bounds KDF resources, requires integer JSON and a 32-byte output,
and validates direct derivation; defaults remain unchanged. The app strength floor
is separate from resource validity. Unsupported old factors must be rejected,
never clamped or hand-edited into a different key.

**Next:** validate salt/verifier encoding and exact lengths at both boundaries.
Add independent Argon2id, HKDF-domain, verifier-hash and XChaCha compatibility
vectors, including production factors outside the fast suite. Profile KDF latency
on a midrange phone; the 64 MiB/10-iteration/4-lane ceilings are safety limits,
not a latency guarantee. Define Unicode normalization only in a versioned format
with migration fixtures. Defensively copy key/blob storage, verify decrypted
secret identity, and minimize root-key retention.

**Gate:** malicious prelogin fails before allocation; independent vectors match;
NFC/NFD policy is documented and tested without breaking existing accounts;
external crypto/protocol review before sync GA. Unsupported factors alone cannot
prove whether the endpoint is malicious or an account is legacy.

### Serialize persistence or adopt transactional client storage — SOL-034

**Start:** `services/{atomic_file,file_stores,app_settings}.dart`.
Writers share `<file>.tmp`; parallel writes can replace each other's data. The
rename fallback deletes the old destination even for unrelated I/O failures.
Broad catches conflate malformed JSON with permissions/transient I/O. Multiple
Linux processes can write the same stores.

**Next:** prefer the planned transactional SQLite store. If retaining JSON, use a
write queue, process lock, unique temporary files, flush/fsync where supported,
atomic replacement and recoverable backups. Keep corruption quarantine distinct
from I/O errors. Preserve the settings `deviceId` salvage path.

**Gate:** concurrent writers, process contention, disk full, permission denial,
crash at each rename phase, backup restore and partial-valid JSON. A failed cleanup
must not discard readable safe state or erase the only original file.

### Missing credentials and recovery onboarding — SOL-035; workflow backlog

**Start:** `AppServices.resolveCredentials`, server editor, settings and master-key
services. A synced local-only `secretRef` currently becomes an empty password/key
on a new device and produces misleading network/auth errors.

**Next:** show “Credential required on this device” before connecting; offer
unlock, prompt, key selection or agent, never an invented empty credential.
Implement encrypted offline export/import with canonical recovery codes and
verified restore before promoting sync. Offer recovery enrollment when the first
secret is saved; optional biometric/passcode app lock belongs at the same boundary.

**Gate:** two devices with/without credential opt-in, locked/missing keys, export
round-trip/tamper rejection, cancelled recovery and interrupted import. Explain
local SFTP plaintext retention separately from encrypted vault guarantees.

## SSH and terminal correctness

### Complete connection ownership and deadlines — SOL-020, SOL-032, SOL-033

**Start:** `seance_core/lib/src/ssh/ssh_session.dart`, `AppState._connect`.
Pre-network key parsing, stale completion checks, idempotent engine disposal,
remote output drain and teardown were implemented. Audit remaining handshake/auth/
shell deadlines and immediate-closure callback races instead of rebuilding those
fixes. Rejecting a stale result is not cancellation of the in-flight connection.

**Next:** one phase/total-deadline cancellation lifecycle owning socket/client/
channels. Expose replayable completion and disconnect reason; Cancel/retry/copy
log actions in the UI. Complete failed/pending-engine ownership and verify a
server deleted mid-connect cannot retain inaccessible work.

**Gate:** delayed fakes for every phase, immediate remote close, cancellation
while TOFU/auth is open, replaced tabs, stream errors and app disposal. No leaked
client/engine, late state commit or unhandled completion error.

### Typed keyboard-interactive challenges — SOL-021 / AST-002 residual

**Start:** `SshSessionManager._keyboardInteractiveHandler` and
`ui/keyboard_interactive_dialog.dart`. Answers now default private, support
per-answer reveal, disable keyboard learning/suggestions and scroll above the IME.

**Next:** add a compatible typed challenge carrying prompt text, echo policy and
identity, plus explicit cancellation distinct from an empty valid challenge.
Preserve existing callback consumers. Add verified Next/Done traversal between
fields without landing on reveal buttons, and deliberate password/OTP autofill
policy rather than guessing from remote prompt text.

**Gate:** echo/no-echo, multiple challenge rounds, answer count/order, cancellation,
active composition, small screens and hardware/software keyboard traversal.
Never infer that a server-provided echo flag proves an answer is non-sensitive.

### SSH config parity and import — SOL-022; SEA-007, SEA-027

**Start:** `ssh_config_import.dart`, `AppState.importSshConfig`, import dialog.
Repeated paste imports generate fresh UUIDs; wildcard defaults, multiple aliases,
first-value semantics, Include and quoting are incomplete. ProxyJump is discarded.

**Next:** file Browse plus paste, preview with unsupported-directive warnings and
host/port/user dedupe. Evaluate all concrete aliases against matching defaults,
first value wins; tokenize quotes/comments and handle multiple identities.
Consider `ssh -G` on desktop behind an evaluator interface. Mark unresolved auth
as setup-required rather than silently guessing an empty user or password.

**Gate:** repeated imports are idempotent; wildcard/multi-alias/repeated blocks,
quotes/comments/Include loops, unsupported ProxyJump and sandbox file grants.
No imported directive executes local commands during preview.

### Agent, jump hosts and forwards — SOL-028

**Next:** transport-neutral agent signing for Unix sockets and Windows OpenSSH
named pipes, including 1Password/Bitwarden. Implement ProxyJump execution and alias
mapping; add local/remote/dynamic forwarding UI. Add known_hosts import/export,
fingerprint randomart and per-device key generation/public-key deployment.

**Gate:** real sshd version/password/key/passphrase/keyboard-interactive matrix;
agent cancellation and unavailable agent; jump-chain TOFU at every hop; forwarding
lifecycle and explicit bind addresses. Verify strict-KEX/Terrapin behavior of the
pinned dartssh2 version and establish dependency/CVE monitoring. Do not unpin a
working SFTP cancellation version without the same conformance tests.

### Honest reachability probes — SOL-024

**Evidence:** `TcpBannerProber` reads one chunk but never checks `SSH-`; a completed
connection, including banner timeout, reports online. Socket exceptions conflate
refusal, DNS and routing errors. Bounded concurrency, connected-host skipping and
disposal guards are already implemented (#36 and follow-ups).

**Next:** bounded identification-line parsing, distinguishing refusal from unknown
network/DNS/filter states, with per-host opt-out. Preserve background pause,
staggering and active-session bypass.

**Gate:** real loopback services returning SSH, HTTP, silence, split banners,
pre-banner lines and malformed/oversized data; disposal/background transitions
must neither publish late state nor restart timers.

### Runaway parser and backend conformance — AST-009 / SOL-027

**Evidence:** current parser rolls incomplete OSC input back and re-parses it on
every write: quadratic work. Existing [PR #49](https://github.com/L-K-M/Seance/pull/49)
contains a reproduction and timings. Finish/review it; do not open a duplicate.

**Next:** bounded resumable parsing; recovery must not reinterpret controls hidden
inside an abandoned payload. Add output/input/selection/scrollback capabilities to
the terminal seam before swapping backends. Current app code still reaches into
xterm controllers, buffers and staged input; an interface name alone is not a
renderer-independent implementation.

**Gate:** arbitrary chunk boundaries, unterminated OSC/DCS/CSI, fuzz/property tests,
large payload recovery and bounded memory/time. Real sshd conformance: vim, htop,
readline, alternate screens, Unicode widths, mouse reports and resize/reflow.
Adopt libghostty only after a stable suitable API and the same conformance gate.

### Bounded, Unicode-safe pending-input hints — AST-010 / SEA-006

**Evidence:** `XtermTerminalEngine._trackPending` appends per rune without a bound,
ignores cursor/history edits and removes a UTF-16 code unit on backspace. Large
pastes can be quadratic; non-BMP text can become malformed. `_snippetTitle` and
`_shortError` still use grapheme-unsafe `substring` truncation.

**Next:** bound and buffer hint assembly, delete graphemes, invalidate hints after
unknown editing/history operations. Reuse grapheme-safe truncation for labels and
errors. Treat pending text as a hint, never authoritative shell state or safe LLM
context; do not guess a remote cursor position from screen columns.

**Gate:** emoji/combining/ZWJ edits, large pastes, cursor/history/control keys and
no-echo input; no malformed UTF-16, unbounded growth or automatic cloud prefill.

### Search and native-feeling shell interaction — SEA-023, SEA-025, SEA-028; SOL-047

**Search slice (P1):** add Cmd-F / Ctrl-Shift-F scrollback find, next/previous,
case toggle, wrapped-line matching and stable hit anchors during output/trim.
Keep highlights separate from selection; scan incrementally with bounded work.
Escape restores terminal focus; never steal readline Ctrl-F. Fork theme slots
and a commented search test do not constitute an implementation.

**Navigation slice (P1):** cycle/select tabs 1–9, close, focus host filter, clear
terminal and shortcut help. Preserve plain Ctrl-C interrupt, Ctrl-A home and
remote mouse reporting. Put the managed-edit close guard behind the operation
first (SEA-009), not in one button handler. Clear native terminal focus on dispose
without an old view clearing a newer focused view (SEA-008); test native Edit menus.

**Command slice:** build OSC 133 command blocks and Copy last command/output,
Save snippet, reviewed Rerun and Explain. Use one backend-independent local Draft
Dock for AI/snippets/history: exact target/source, editable text and danger
findings, final control/newline validation, explicit handling of a nonempty prompt.
Do not silently concatenate or submit. Clipboard multiline paste needs its own
preview policy preserving bracketed paste and editor workflows.

**Mobile gate:** test touch handles, copy toolbar, magnification, edge drag,
selection under output, external keyboards, iPad shortcuts and CJK/dead-key IME on
devices. Preserve the implemented multi-click/shift/drag/trim/Option behavior.

### Disconnect recovery — SEA-026; “Last words”

**Evidence:** final scrollback survives in the model but disconnected UI replaces
it with a placeholder. Reconnect is manual; persisted edit placeholders are not
session restoration.

**Next:** show final scrollback plus reason, duration, cwd, copy/save/reconnect.
Opt-in reconnect with bounded backoff/cancel after network changes; opt-in tab
restoration with a target preview. Persistent tmux/Mosh sessions are separate
features, not promises of TCP reconnect. Existing local-shell PR #44 is separate.

**Gate:** network flaps/background/resume, auth expiry, remote normal/error exit,
manual cancellation and stale attempts. Never replay a command/login script
silently during recovery.

## Performance: measure before changing architecture

### Reproducible latency harness — SOL-026, SOL-057, SOL-059; SEA-012; AST-012

Risks, not measured frame regressions:

- Packet-by-packet synchronous parsing and rapid PTY resize compete with input.
- All servers' sessions remain mounted in an `IndexedStack`; hidden views retain
  render/paragraph caches and participate in layout/resize.
- Broad `AppState` notifications rebuild unrelated chrome. The old trace-line
  rebuild storm was fixed in #35; do not claim it is still present.
- KDF, crypto, whole-collection JSON writes, recursive SFTP scans and editor work
  share the UI isolate. Preserve existing syntax memoization/highlight caps.
- SFTP and keystrokes share a transport; transfer throughput is not typing latency.

**Next:** record p50/p95 frame and keystroke latency, parser throughput and peak
RSS on a laptop and midrange phone: captured ASCII/color/Unicode, `yes`, large
files, full scrollback, unterminated controls, resize spam, selection during output,
1/10/50 tabs, tab switches and concurrent upload/cancel. Separate parser, layout,
raster, transport and GC time. Target 60 Hz (16.7 ms frames), not an unmeasured claim.

Then introduce independently measured changes: bounded output queues/backpressure,
coalesced/duplicate-suppressed PTY resize, active-server plus LRU rendered views
without discarding session state, focused listenables/selectors, batched domain
writes and off-isolate work. Preserve interactive interrupt and quick tab switches.
Initial PTY remains 80×24 until widget layout; negotiate the measured grid earlier
if the harness shows visible redraw. Remote resize must never recurse into itself.

An optional **connection flight recorder** (AST-012) can expose DNS/TCP/handshake/
auth/shell versus parse/layout timings. Keep retention bounded, export previewable
and redacted; no keys, commands or raw traces by default.

### Network cancellation and response bounds — SOL-058 / AST-006 residual

Owned sync clients now close after sync/enrollment, including failures; injected
transports remain caller-owned. This is not general cancellation.

**Next:** ownership-aware close for LLM/search providers; cancellable requests,
connect/total/stream-idle deadlines and streamed response/body limits. Ensure
reset, dialog dismissal, app disposal and timeout stop or discard work instead
of only completing a `Future.timeout` wrapper.

**Gate:** stalled headers/body/SSE, oversized responses, disposal during requests,
late replies and retry; no resource accumulation or stale UI/PTY side effects.

## Assistant privacy and usability

### Session-local, bounded, cancellable conversation — SOL-038, SOL-041; SEA-017

**Evidence:** drawer chat survives closure but is still shared across sessions.
`ChatController.send` stores terminal context in history despite its “turn only”
comment. Replies use non-streaming `SelectableText`; reset can race late results.

**Next:** histories per SSH session with byte/token budgets, ephemeral terminal
context separate from persistent messages, deterministic truncation/summarization.
Stream replies with Stop/Retry; safe Markdown with code Copy/Stage, selectable
text and preserved scroll position. Add generation tokens across chat, command
generator, model discovery and enrollment UI. Cancel/dismiss must prevent later
insertion; use `mounted` and `finally` for route/busy state.

**Gate:** switching hosts mid-turn, closing/reopening utility pane, reset/dispose
while blocked, long histories, provider errors and malformed Markdown/links.
No old context silently resent and no result staged into another session.

### Native tools and exact outbound receipts — SOL-042, SOL-044, SOL-045

**Evidence:** native tool-call IDs are discarded; results become ordinary user
strings. `ChatResult.sent` omits retained history and search snippets and the UI
ignores it. Search results are untrusted external content too.

**Next:** provider-neutral typed calls/results preserving IDs; emit Anthropic
`tool_use/tool_result` and OpenAI assistant `tool_calls` / tool-role messages.
Keep the existing bounded tool loop. Capture the complete serialized provider
payload after redaction, including history and searches. Show expandable context
receipts: target, provider/endpoint/model, command blocks, redactions, queries/
results, token estimate and exact outbound text. Add user-defined/structured
redaction patterns; label the filter best-effort, not guaranteed secrecy.

**Gate:** second-request wire-format fixtures for both providers, search-injection
fixtures, payload-to-receipt equality and credential URL/cookie/kubeconfig examples.
Add provider connectivity/latency diagnostics. Expose Brave settings or remove the
half-wired option; native provider web search remains an optional separate path.

### Shell-aware command capture — SOL-046 / AST-007 residual; SEA-034

Recognizable secrets are now filtered before capture, legacy loading and save,
independently of assistant settings. Legacy cleanup is attempted on load; failed
writes, unparseable files and historical backups cannot be promised scrubbed.

**Next:** capture only proven OSC 133 command boundaries; arbitrary no-echo passwords
are not recognizable by regex. Add a visible local privacy/“whisper” mode excluding
capture and outgoing context, plus clear-history/storage controls. Never infer
no-echo from ordinary SSH channel bytes alone. Bound command lengths/counts,
loaded data and dismissal storage without silently breaking “never suggest again.”

**Gate:** password/OTP prompts, shell/readline editing, nested shells and alternate
screens; settings-independent protection; safe commands still rank. Explicitly
warn that prior backups/plaintext history may persist.

## Server operations and release reliability

### Quotas, snapshots and abuse controls — SOL-049, SOL-050

**Evidence:** request/batch/blob caps and expired limiter pruning already exist.
Accounts can still accumulate unbounded blobs/tokens; full pulls materialize the
account. Active unique-key spray grows limiter memory; username-only limits enable
lockout and do not protect prelogin/registration.

**Next:** account/token/record/blob/total-byte quotas; validate configured limits.
Paginate against atomic snapshot watermarks. Separate bounded source-IP and
account rate buckets, trusted-proxy policy, prelogin/register limits and
`Retry-After`; shared/persistent state if supporting replicas. Reject malformed
prelogin username types as structured 4xx, not internal 500.

**Gate:** concurrent quota edges, large historical accounts, ID spray, targeted
lockout, proxy spoofing, restarts and exhausted pages; bounded memory/disk and
clear actionable status codes.

### Account transactions, schema and backups — SOL-051, SOL-054

**Start:** SQLite registration/deletion and `_migrate`.

**Next:** atomic create-or-conflict including initial sequence/token; transactional
account deletion; live-account token joins. Version schema with transactional
`PRAGMA user_version` migrations, foreign keys/checks/cascades and bounded busy
timeout. Document synchronous/durability settings and WAL-aware online backup /
restore. Never copy only the main DB file while ignoring active WAL state.

**Gate:** concurrent registration/delete/login, orphans, migration interruption,
lock contention, disk full, corruption and restore during writes.

### Readiness, drain and observability — SOL-052, SOL-053, SOL-055

**Correction:** #48 replaced Compose's old `--help` check with real HTTP health;
do not implement that obsolete fix again. `/healthz` remains liveness only.

**Next:** bounded SQLite-aware `/readyz`; actual-container CI smoke test for
register/login/push/pull/persistence/restart. Stop accepting on SIGTERM, drain with
a deadline, finish/rollback transactions, close/checkpoint SQLite and handle
repeated signals. Log request ID/route/status/duration/size and sanitized server
errors; add auth/throttle/push/DB latency counters. No authorization, verifier,
blob, request-body or raw command logging.

**Gate:** live process with broken DB is not ready; SIGTERM during reads/writes,
restart recovery, safe structured errors and container health failure detection.

### Release/update hardening — SOL-040, SOL-056

Client publishing now requires app analysis/tests and the terminal fork suite;
that gate does not replace the remaining release checks.

**Next:** SemVer tag/pubspec consistency; stable-only Docker `latest`; immutable
action/base-image pins, checksums and multi-architecture images where supported.
Back up before schema updates, wait for readiness and roll back failed deploys.
Make Docker Hub/Gradle dependency pulls resilient to 429/timeouts through supported
caches, authenticated pulls and bounded retries; distinguish infrastructure
failures from code failures. Pin an SDK/golden-update policy, not arbitrary golden
regeneration to turn CI green.

Android's committed sideload key gives upgrade continuity, not private publisher
authenticity. Exclude keystore-dependent data from incompatible backup restore;
verify upgrade data retention. If distributing publicly, use protected signing.
Add iOS LAN disclosure and narrowly tested transport policy; explain that phone
`localhost` is the phone. Review cleartext sync/provider URL policy and publish
reverse-proxy examples. Correct stale scratch/static-image and every-request
version claims.

**Gate:** tag mismatch/prerelease tests, actual packaged install/upgrade, failed
rollout recovery, checksums, LAN endpoints and signed mobile relaunch.

## Adaptive layout, aesthetics and convenience

### Three-stage layout and navigation — SOL-039, SOL-060, SOL-062, SOL-065; SEA-015, SEA-018

**Evidence:** the 960 px breakpoint drops both side panes at once. Narrow mode is
an `AnimatedSwitcher`, not navigation history; system Back can leave the app.
The utility drawer is fixed at 380 px. Pane sizes, utility tab and active host do
not persist. The 1800×1600 window default exceeds common laptop work areas.

**Next:** wide list/terminal/utility → medium list/terminal plus utility drawer →
phone routes. Support drawer-first Back, Android predictive Back and iOS swipe;
preserve sessions while resizing across modes. Add explicit pane collapse,
keyboard/focus resizing and persisted ratios/selection. Constrain drawers and long
credential dialogs to available width/keyboard space. Existing window-state
[PR #47](https://github.com/L-K-M/Seance/pull/47) owns geometry: review/rebase it,
clamp restored placement to current monitors and use laptop-safe defaults.

**Gate:** 320/700/960/1440 px, 1×/2× text, IME open, RTL, monitor removal and
breakpoint transitions. No inaccessible actions, lost sessions or unexpected exit.
AST-003 fixed long session-footer targets; do not re-add that task.

### Accessible controls and terminal preferences — SOL-061, SOL-064; SEA-019, SEA-020, SEA-021, SEA-039

**Done:** persisted font size/family/palette/zoom, app mono stack, mobile cursor-mode
keys, Unicode-safe middle labels and light-mode status contrast. Remaining status
work is semantics/non-color cues, not another palette replacement.

**Next:** touch-specific 44–48 dp tab-close/key/swatch targets without bloating
desktop density; keyboard-adjustable separators, live safety notices and useful
terminal screen-reader fallback. Distinguish connected/error/unknown beyond hue.
Consider one composed connection/reachability indicator rather than two confusing
dots. Make settings-recovery/device-ID reset notice persistent until acknowledged.
Add cursor shape/blink, scrollback length, bell behavior, ligature, OSC 52 and
remote-title policies. Keep system/reduced-motion preferences respected.

**Gate:** semantics and keyboard tests plus native assistive-technology testing;
color-vision simulation, text scale, all tab states and selection/copy during
streaming output. Remote titles must never impersonate trusted local UI.

### Visual hierarchy and identity — SOL-063; visual-direction backlog

**Next:** recapture current light/dark desktop/mobile screens first. Keep the quiet
violet/near-black identity; reduce duplicated utility headings, unlabelled icon
clusters and inert empty space. Use short context-sensitive empty-state actions,
consistent spacing/radii/density and a quiet host-identity edge. Terminal palettes
remain user-controlled. Normalize visible platform names within signing/bundle
constraints, check desktop/AppStream integration and simplify the small-size icon
into a terminal/sigil; keep photographic artwork for onboarding/marketing.

**Gate:** current-screen golden matrix at the layout sizes above, keyboard and
screen-reader discovery, launcher-size icon checks and native desktop metadata.
Linux `.deb`, AppImage, desktop/icon packaging already exist; audit completeness
instead of starting another packaging format. No ornamental terminal animation.

### Fast daily workflows

- **P1: Planchette palette.** Fuzzy hosts/snippets/settings/reconnect/sync/assistant
  actions, keyboard-first with shortcut help. Test filtering, focus return and
  final target confirmation; use service commands, not raw UI-to-network calls.
- **P1: Quick connect.** One-off host/user/port without forced persistence, reusing
  editor/auth/TOFU validation. Add favorites/recents and duplicate detection;
  server search and synced groups/colors/icons already exist.
- **P1: Device/account management.** Sync logout, revoke/list devices, account
  deletion, passphrase rotation and conflict/deletion audit, after token/ledger/
  recovery foundations. UI must not imply a local delete also revoked a remote
  credential until the tombstone is acknowledged.
- **P2: Safe context enrichment.** Populate OS/distro/shell/cwd/exit status through
  explicit shell integration; show unknown rather than guessed facts. Prefer
  command blocks over a blind last-N-lines context window.

### Files and mobile persistence follow-up

SFTP, recursive transfers, durable local edits, conflict-checked upload-back,
POSIX metadata, chmod/symlinks, sorting/filtering/bookmarks, Android export and the
syntax/find/save-and-upload editor are implemented. Remaining scope is in
[docs/SFTP.md](docs/SFTP.md), not “add an SFTP browser.”

**Next:** Files widget tests with picker/opener fakes; keyboard/accessibility pass;
copy/move operations, drop onto folder rows and persisted sort/filter preferences.
Validate OpenSSH, BBEdit/macOS, Android SAF/provider grants and iOS editing on real
devices. Add resumable/queued background transfers, optional independently owned
transfer connections, server-side hash support where available, and promised-file
drag-out as separate features. Expose retained plaintext edits/storage/discard;
centralize destructive-close guards before adding shortcuts or swipe-close.

**Gate:** never erase unsaved edits implicitly. Preserve cancellation ownership
from dartssh2 3.0.2/#59 and new VFS metadata/hash controls (#61/#62). Test concurrent
save/upload, reconnect/restart, chroots, symlinks and providers without stable paths.
Hash-before-rename still has a remote-write race; do not describe it as a lock.

Android foreground keep-alive (#51) is implemented, not device-validated. Measure
battery/OEM behavior, notification permission and Android 15 six-hour `dataSync`
timeout. Revisit Play `specialUse` policy if distributing there. Floating/overlay
keyboards may still cover the final terminal row despite resize fixes. iOS opener
copy/share is not proof of in-place upload-back support.

## Optional product ideas

Each is local/explicit by default, reduced-motion aware, and subordinate to shell
predictability. These consolidate earlier ideas without removing their useful
variants.

| Idea / identifier | First useful slice and acceptance criterion |
|---|---|
| Fingerprint spirit sigils / SEA-033 host hues | Deterministic fingerprint randomart + optional automatic host hue on rows/tabs/TOFU. Same key gives the same identity across devices; changed key visibly changes it. Never substitute art for fingerprint verification or overwrite explicit production labels. |
| Safe Draft Dock / SOL-047 | Local editable target-labelled command staging with source/danger cues; only an explicit action sends to PTY, never Enter. Test nonempty prompts and stale sessions. |
| Planchette | One fast action palette with a restrained selection motif; no theatrical delay or focus ambiguity. |
| Production wards | Synced production/staging/lab tags with symbol and color; extra confirmation for reviewed destructive/sudo actions on production. No promise of intercepting every shell command. |
| OSC 133 command cards / SEA-028 | Completed-command Copy/Explain/Snippet/Reviewed Rerun/Compare/Include-in-chat, using real command boundaries, not guessed keystrokes. |
| Last words | Preserve final output, duration, cwd and disconnect reason with copy/save/reconnect; never hide diagnostic scrollback behind a blank placeholder. |
| Completion notices / SEA-031 | For background completed commands, optional tab badge/OS notice with exit and duration. Prove correct session attribution; hide sensitive command text by default. |
| Ghost tabs / SEA-032 | Short-lived Undo close restoring host/label and offering reviewed cwd staging. A new SSH session is not restoration of remote process state; never bypass managed-edit deletion guards. |
| Whisper mode / SEA-034 | Visible capture/context privacy toggle; auto-arm only from a trustworthy supported signal. Ordinary channel bytes cannot prove no-echo. |
| Séance transcript / SEA-035 | Previewable redacted Markdown export of command/output blocks, timestamps, host and duration to file/clipboard/snippet; warn redaction is best-effort. |
| Presence pulse / SEA-036 | Optional real keepalive RTT tooltip/sparkline or quiet pulse; do not invent a measurement or animate terminal text. Respect reduced motion. |
| Custom/two-hand mobile decks / SEA-037 | Per-host saved keys, modifiers left/navigation right, punctuation drawer, repeat/haptics and clipboard actions. Maintain application cursor modes and accessible targets. |
| Context ledger / SOL-044 | Expandable exact outbound receipt for every assistant request, including history/search and redaction; no hidden resend. |
| Idle divination / SEA-038 | Explicit per-host opt-in to cheap uptime/disk/reboot facts, outside PTY and through a core service. No autonomous assistant execution or undisclosed periodic commands. |
| Reading anchor / AST-011 | Unread output counter + Jump to live while scrolled/selected. Stable absolute anchors, bounded counts after trims, no selection theft or unsolicited snap-to-bottom; test alternate screens. |
| Connection flight recorder / AST-012 | Bounded opt-in local phase timings separating network/auth/parser/layout; redacted export preview, no commands/keys/raw traces by default. |
| Portable workspace recipe / AST-013 | Save hosts/tab labels/pane layout/intended cwd, preview targets then explicitly reconnect. Stage quoted cd only at a verified empty prompt; never silently replay commands/login scripts. |
| Quiet connection rehearsal / AST-014 | Optional cancellable DNS/port/key-readability check before saving, explaining the next trust/auth step. No password guessing, background remote commands or silent pinning. |

Later, separate proposals: terminal splits, tmux/Mosh persistence, provider-native
search, sync OIDC and libghostty. Keep the existing local-shell/sandbox/window/
parser PRs (#44/#45/#47/#49) visible so future agents do not duplicate them.

## Completion ledger

Implementation PRs #64–70 are awaiting final CI/review. Do not mark residuals
complete merely because a smaller patch landed.

| Entry | Implementation PR | Proven scope / residual |
|---|---|---|
| AST-001 / SOL-014 part | [#64](https://github.com/L-K-M/Seance/pull/64) | KDF ceilings, strict integer typing and direct-call validation. Salt/verifier shape, device profiling and independent vectors remain. |
| AST-002 / SOL-021 part | [#65](https://github.com/L-K-M/Seance/pull/65) | Masked/revealable, scrollable auth fields with IME privacy hints. Typed echo, cancellation model and Next/Done remain. |
| AST-003 | [#66](https://github.com/L-K-M/Seance/pull/66) | Long footer labels and scaled text fit; full identity stays accessible. |
| AST-004 / SEA-019 | [#68](https://github.com/L-K-M/Seance/pull/68) | Light/dark indicator contrast tests against real surfaces/overlays. Non-color cues remain. |
| AST-005 | [#69](https://github.com/L-K-M/Seance/pull/69) | Fork tests in CI; app/fork gate before client publishing. Other release hardening remains. |
| AST-006 / SOL-058 part | [#70](https://github.com/L-K-M/Seance/pull/70) | Owned sync HTTP cleanup; borrowed-client ownership preserved. Cancellation/LLM/search lifetimes remain. |
| AST-007 / SOL-046 part | [#67](https://github.com/L-K-M/Seance/pull/67) | Recognizable-secret filtering and legacy cleanup. Unmarked passwords, failed disk scrubs, backups and retention limits remain. |

Earlier completed work, removed from active instructions:

- #1–31: command newline/control guard improvements, source-session paste binding,
  modern token redaction, loopback Compose publish, generic server errors, atomic
  JSON/quarantine, credential/port defaults, request timeouts, danger rules,
  redaction toggle, body/batch/blob caps, Android signing continuity, observed
  pull cursors, pre-socket key parsing, limiter pruning, packet-safe UTF-8,
  canonical recovery codes, bounded tool loops, mobile DECCKM, grapheme-safe
  middle labels, enrollment validation, pane constraints, selection overhaul,
  per-server tabs, update notice, macOS key picker/bookmarks/audit, review workflow.
  The full per-PR residual mapping remains in the July archive.
- #32–38 are **merged**, not open: appearance (SEA-013), metadata labels/footer
  (SEA-014), server filter (SEA-024), trace/recentText/teardown fixes
  (SEA-001, SEA-005, SEA-011), bounded active-host-aware probes (SEA-003, SEA-004), surviving
  drawer chat/constraint-aware bubbles (SEA-010, SEA-016), settings salvage (SEA-002).
- #40/#41: command-aware and manually named tabs. #42: Option composition and
  word/line drag selection. #43: synced server groups/colors/icons.
- #46: syntax/find editor and top notices. #48: actual HTTP deployment health and
  containerized reverse-proxy support. #50: explicit per-server login script.
  #51: Android foreground-session anchor. #58: unknown-kind/malformed-record
  preservation. #59–62: SFTP cancellation, authenticated-client ownership and
  metadata/hash additions. #57 established the Unlicense.
- SOL-036's macOS key-file access is implemented; validate native behavior rather
  than recreating it. SOL-032/SOL-033's completed lifecycle portions are distinguished
  from remaining cancellation/deadline work above.
- SEA-022 was superseded by completion notices (SEA-031); SEA-029 merely confirmed
  power-user gaps. SEA-030 is documentation drift: update `docs/STATUS.md` and
  `AGENTS.md` counts/development-branch text. Redaction toggle and split UTF-8 are
  fixed; the old ledger's “SOL-010 residual” referred to the toggle, **not** to the
  still-open independent-secret-revisions issue.

## Invariants and release gates

Preserve shared protocol code; domain-separated Argon2id/HKDF and XChaCha AEAD;
strict changed-host-key blocking; explicit review-before-run; default redaction;
terminal scrollback/search content as untrusted; no assistant execution/file
capabilities; stable terminal identities, selection and top notices that do not
cover the shell prompt. The always-available assistant is deliberate, not a toggle
bug. JSON and pure-Dart crypto are intentional swappable v1 choices.

Before sync/credential handling is called production-ready, require:

- Restart-level two-device typed deletion and forced acknowledgement/apply races.
- Authenticated-envelope tamper/replay/transplant and version migration fixtures.
- Real HTTP-over-SQLite concurrent snapshot/upsert and crash tests.
- Independent crypto vectors, device KDF profiling and external protocol review.
- Real sshd auth/changed-key/resize/output/strict-KEX matrix.
- Signed Apple keystore relaunch/migration and Android upgrade/backup tests.
- Adaptive golden/semantics tests plus native keyboard/clipboard/IME validation.
- Running-container readiness/persistence/backup/restart/SIGTERM smoke tests.
