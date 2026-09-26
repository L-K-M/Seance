# Séance: engineering and product backlog

Consolidated 2026-09-26 from review baseline `dd7e105`, preserving main's later
theme-default update at `5c02fe0`. This is the unfinished work list, with bounded
next steps and acceptance gates. The complete new
review is [tmp.md](tmp.md); the unchanged previous backlog and completion ledger
are [archived](docs/reviews/analysis-2026-09-05.md). Earlier review sources remain
[astra.md](astra.md) and the [July archive](docs/reviews/analysis-2026-07-25.md).
SOL/SEA/AST identifiers remain stable; SEA26 and UI identifiers refer to tmp.md.
No information was discarded: completed or corrected historical claims belong
in the archive, while current residuals remain here. Poltergeist has a sibling
ANALYSIS.md for transfer/sync/backup/UI integration work.

The unchanged archive retains links written for the repository root. Use these
current targets when following its original relative links: [astra.md](astra.md),
[July archive](docs/reviews/analysis-2026-07-25.md), [PROPOSAL.md](PROPOSAL.md),
[status](docs/STATUS.md) and [SFTP reference](docs/SFTP.md).

## Implemented in open PRs from this review

| Finding | PR | Scope awaiting owner review |
|---|---|---|
| SEA26-SEC-01 | [#132](https://github.com/L-K-M/Seance/pull/132) | Mask complete quoted JSON/YAML values and static shell assignment words, including escaped/truncated inputs, adjacent fields, common `secret_key` spellings and AWS secret-access-key fields; actual provider-body coverage. General redaction remains best-effort. |
| SEA26-SEC-06 / SOL-051 slice | [#133](https://github.com/L-K-M/Seance/pull/133) | Atomic SQLite account deletion with rollback under injected failures. Login/deletion races and token lifecycle remain separate. |
| UI-02 / SOL-061 slice | [#134](https://github.com/L-K-M/Seance/pull/134) | Focusable, labelled pane dividers with arrow and assistive adjustment, visible focus, clamped values and RTL geometry. Native assistive-technology QA remains. |

These PRs are intentionally open for the owner to review and merge. Do not
reimplement their slices. Keyboard-accessible dividers and the final validation
and review status are tracked in the final ledger below. Remove implemented
scope after merge, retaining the stated residuals.

## Assessment and verification

Trust reconciliation, account activation/recovery and the unauthenticated sync
envelope remain the largest risks. Local vault re-key staging, durable server/
snippet deletion intents, independent secret timestamps, serialized app sync,
agent/jump transport and editable themes now exist. Preserve those safeguards.
Do not call account sync production-ready until the P0 migration/recovery gates
pass. P0 means a trust boundary or major loss risk; P1 means correctness/privacy/
reliability; P2 means substantial usability/performance; P3 is optional.

Baseline source and light/dark sidebar fixtures were inspected. Twenty capture
tests produce 30 PNGs and pass using local Arial/Courier through the fixtures'
font aliases; these are widget renders, not release-font or native-device QA.
The composed status badges and quiet colored glyph vocabulary are coherent.
Native assistive technology, signed keystores, physical mobile IME/Back,
sustained frame timing, Windows agent behavior and power-loss recovery remain
unverified here.

Baseline on macOS, Flutter 3.47.3/Dart 3.13.3 (CI pins Flutter 3.47.2): package
analysis and all 778 package tests passed; app analysis clean, app tests 1079
passed, two skipped, two desktop capture fixtures failed without real fonts.
Both capture failures disappeared in the 20-test real-font capture run. This is
not a claim that the complete app suite was rerun successfully. Prior version
counts, historical CI and detailed completion records remain in the archive.

Supplemental visual QA on main `5c02fe0`: a temporary copy of the capture fixture
used `SeanceTheme.build(ThemePresets.initial, brightness, platform: platform)`
instead of `SeanceTheme.light`/`dark`, which still select Séance/Automatic.
Four representative capture tests passed and produced nine Terminal-palette
PNGs. Comfortable/compact 200 dp rails, a 280 dp rail, a 390 dp phone and the
menu showed no obvious new layout/contrast blocker; status colors remained
distinct and explicit host colors survived. Endpoint elision remains. Twelve
existing Terminal/default/preset-contrast assertions passed sequentially after
a concurrent native-assets codesign race. The temporary harness was removed;
this is supplemental render evidence, not new stock-fixture coverage.
The phone FAB overlaps part of the lowest visible group in both palettes;
existing bottom clearance allows scrolling it clear. Verify that clearance with
long lists and scaled text before treating this as an inaccessible-control bug.

Pull current main first; one focused branch/PR per slice; a bug needs a failing
regression before the fix. Honor the owner's merge instructions. Preserve
public protocol/core compatibility with Poltergeist and service boundaries.
Recommended order: authenticated records and durable ledger; explicit trust
reconciliation; recoverable account activation/lost-key handling; bounded server
lifecycle; measured terminal work; ergonomic workflows. Independent UI fixes may
proceed alongside the protocol work. Migrations need compatibility/rollback
fixtures, not an ad hoc rewrite of existing vaults.

## P0: trust, sync and credentials

### Authenticate routing and conflict metadata — SOL-011

**Evidence:** `packages/seance_protocol/lib/src/records/{record,record_codec}.dart` and
`crypto/vault.dart` authenticate `{kind,data}`, not ID, timestamp, device or
deleted flag. Empty tombstone blobs have no authentication. A breached server can
forge deletions or replay old ciphertext with winning metadata. Current consumer
checks reject mismatched config, pin, snippet and secret payload IDs, so a
cross-ID transplant is not assumed to succeed through those consumers; preserve
those checks while binding identity cryptographically at the codec boundary.

**Next:** specify a versioned canonical envelope binding purpose, schema, key
epoch, kind, identity, client revision/time, device and deletion inside AEAD.
Encrypt typed tombstones; exclude server-owned sequence from authentication.
Ship compatibility readers and migration fixtures before changing writers.

**Gate:** field-by-field tamper, transplant, replay and forged-tombstone tests;
old/new client interoperability, interrupted migration and rollback. Opaque IDs
(SOL-012) should use the same migration, not a second destructive rewrite.

### Durable ledger, typed deletes and exact acknowledgements — SOL-001, SOL-005, SOL-006, SOL-010, SOL-037, SOL-059

**Current evidence:** `AppServices.runSync` still builds an in-memory mirror per
run; the coordinator re-encrypts unchanged records and reattributes authorship.
Core acknowledgements identify only IDs. The app now serializes saves, deletes,
manual and automatic sync through `_mutate`; server/snippet deletion intents and
independent secret timestamps are implemented. Do not repeat their old fixes.

**Next, separate slices:** persistent account-scoped origin/cursor/dirty-operation
ledger; exact sent-revision acknowledgement; authenticated typed deletes and
credential opt-out; one batched domain apply transaction. Fetch outside the app
mutation queue and recheck/merge under it, so slow successful network batches do
not block every local edit. Reconcile live sessions whose config was remotely
deleted as explicit orphans. Include a visible pending/conflict outcome after
round exhaustion and validate missing/duplicate/foreign acknowledgement IDs.

**Gate:** both devices restart after deletion without resurrection; unchanged
resync pushes nothing; blocked push plus edit remains dirty; blocked apply cannot
overwrite a domain edit; account switch isolates state; credential opt-out
converges. Coordinate with Poltergeist's exact-record settlement extension rather
than altering the shared interface without consumers/tests.

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

**Evidence:** `ui/server_editor.dart` now persists referenced-key passphrases and
preserves a stored PEM when changing to a referenced key. Both modes still share
one credential slot: a reference's new passphrase can become paired with the
retained PEM, so switching back may leave it undecryptable (STATUS follow-up 17).
Changing only an existing stored key's passphrase while leaving its PEM field
blank is still ignored. Retaining `secretRef` across modes preserves recovery
options, but keep/replace/remove is not explicit. The old empty-key overwrite
was fixed in #7; that is not the remaining bug.

**Next:** model keep/replace/remove explicitly for password, stored key, referenced
key and agent. Validate each mode, save config/secret changes as one unit, and
remove obsolete local/synced credentials only after successful replacement.
Prompt for referenced-key passphrases without requiring storage.

**Gate:** every auth-mode transition, passphrase-only edits, unrelated config edits,
failed secret writes and cancelled dialogs preserve the intended credential.

### Recoverable vault re-key — SOL-030

**Implemented foundation:** the complete vault, including orphaned secrets, has
a staged two-generation journal and keystore-directed settlement. Preserve
`FileVaultStore.stageRekey/settleRekey` and `vault_rekey_test.dart`.

**Remaining P0 task (SEA26-SEC-08):** `AppServices` writes new URL/account/token
before re-key completes. Journal the entire account activation and block sync
while unresolved; a restart must choose the old account/key or the new pair,
never mixed state. Add explicit encryption-key confirmation for empty accounts,
where existing payload trial-decryption cannot establish the passphrase.

**Gate:** failure/restart at registration, settings, token, journal, key write and
vault promotion; orphaned credentials preserved; no upload under the wrong key;
wrong passphrase on an empty account cannot seed incompatible record populations.
Do not substitute “set up sync first” for recovery.

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
keys over encrypted data. Preserve the current sandbox and keystore migration behavior.

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

**Start:** `services/{atomic_file,file_stores,app_settings}.dart`. Same-path writes
now queue within a process. Main loaders still catch read/permission failures as
corruption and expose empty caches; quarantine overwrites the prior `.corrupt`
copy. The Windows fallback deletes the destination after any rename error.
Multiple processes and symlink aliases are not coordinated.

**Next:** separate byte reads from decode/schema catches, propagate retryable I/O,
retain unique recovery copies, and publish cache state only after persistence.
Use Windows atomic replacement or a recoverable backup protocol; acquire a
process lock before cache load. Prefer transactional client storage for cross-file
invariants. Keep the existing write queue and settings device-ID salvage.

**Gate:** injected read/stat/rename/write failure, permissions, disk full, same-path
and cross-process races, crash at each replacement stage, malformed UTF-8/JSON and
partial-valid documents. Good state is never quarantined for a temporary failure;
original or recoverable replacement survives. Port applicable fixes to Poltergeist.

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

**Current:** pre-socket key parsing, stale result checks, idempotent engine
disposal, final-output drain and five-minute authentication deadline exist.
`ssh_session.dart:1205-1207` still awaits `client.shell` without a deadline.
Authenticated servers can stall channel/PTY/shell opening indefinitely.

**Next:** phase/total cancellation owning sockets, jump parents, clients, channels
and engine, with a shell-opening deadline separate from interactive user auth.
Dispose late-acquired channels; show precise phase/reason and Cancel/Retry/Copy log.
Verify deleted/replaced tabs cannot retain inaccessible connection work.

**Gate:** stalled channel/PTY/shell, cancel while trust/auth dialogs are open,
immediate remote close, retry, stream errors and disposal. No leaked ownership,
late session commit or unhandled completion error.

### Typed keyboard-interactive challenges — SOL-021 / AST-002 residual

**Current:** challenges already carry server identity, prompts, name and
instruction. Answers default private, reveal individually, request keyboard
privacy and scroll above the IME.

**Next:** preserve per-prompt echo policy and represent cancellation distinctly
from a valid empty challenge; maintain callback compatibility. Verify Next/Done
traversal and intentional password/OTP autofill without guessing from remote text.

**Gate:** echo/no-echo, multiple rounds, count/order, cancellation, small screens,
native composition/reveal/selection/focus and hardware/software keyboards. A
server echo flag is not proof an answer is non-sensitive.

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

**Implemented:** Unix/Windows SSH agent adapters, saved-host jump resolution and
chained transport ownership. Poltergeist's older pin still needs audited adoption.

**Next:** validate real agents including password-manager integrations and Windows
named pipes; complete alias/import parity, explicit capability errors and
forwarding UI for local/remote/dynamic tunnels. Add known_hosts import/export,
fingerprint aids and per-device key generation/public-key deployment separately.

**Gate:** real SSH authentication matrix, agent cancellation/unavailability,
every-hop TOFU, jump failure cleanup, explicit forwarding bind addresses and
lifecycle. Verify strict-KEX/Terrapin behavior and dependency advisories against
primary evidence; preserve working SFTP cancellation conformance on upgrades.

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

**Current:** `third_party/xterm/lib/src/core/escape/parser.dart` now caps pending
unfinished sequences at 64 KiB. It still rolls short incomplete sequences back,
so adversarial chunking can repeat work up to that cap. Do not describe the old
unbounded queue as current or duplicate a fix based only on an old PR reference.

**Next:** benchmark chunked incomplete OSC/DCS/CSI, implement resumable parsing if
needed, and verify abandon recovery cannot reinterpret controls hidden inside
payloads. Extend output/input/selection/scrollback capabilities of the terminal
seam before swapping backends; the app still reaches into xterm internals.

**Gate:** arbitrary chunks, malformed/unterminated sequences, parser fuzzing,
recovery, bounded time/memory; vim/htop/readline/alternate screen/Unicode/mouse/
resize conformance. A future backend must pass the same gate.

### Bound completed control-sequence work — AST-015

**P1. Evidence:** `third_party/xterm/lib/src/terminal.dart` loops over an unchecked
CSI REP count in `repeatPreviousCharacter`. The 12-byte input `X\x1b[10000000b`
performs ten million
cell writes. A bounded Linux parser-only JIT probe took 364 ms (one million:
40 ms; 80×24 terminal, 10,000 retained rows). These are single samples, not frame-time
measurements. Larger values were not executed. The implemented unfinished-sequence cap
does not cover this path.

**Next:** specify supported numeric/count/size limits and recovery for excessive
work across REP, resize, erase and insert operations. Use equivalent bounded bulk
updates where possible; preserve ordinary wrap/cursor semantics rather than adding
an undocumented arbitrary clamp. Audit numeric overflow as well as huge counts.

**Gate:** short complete adversarial sequences, count boundaries, chunked input,
normal REP/wrap conformance, continued output and bounded scheduling latency.
Keep this distinct from the incomplete-OSC queue fix; both are required before
claiming malformed output cannot wedge the terminal.

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
features, not promises of TCP reconnect. Local-shell and process-restoration policies remain separate.

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

**Current:** one `ChatSession` is shared across hosts and history is unbounded.
Terminal snapshots are now turn-only, originating-session guards prevent stale
staging, and reset uses generation checks. Preserve those fixes. The narrow
drawer's local `_includeContext=true` resets an unchecked choice on reopen.

**Next:** histories scoped per SSH session with an explicit global mode and
byte/token budget; durable session-local context privacy choice; visible target;
streaming Stop/Retry and selectable Markdown/code staging. Cancel actual provider
work as well as rejecting late results. Audit command-generator/model-discovery/
enrollment lifetimes independently instead of assuming chat guards cover them.

**Gate:** switch hosts mid-turn, close/reopen drawer, 1000-turn bounded history,
reset/dispose while blocked, provider failure and malformed links. No unexpected
cross-host history/context sharing or late PTY effects.

### Native tools and exact outbound receipts — SOL-042, SOL-044, SOL-045

**Evidence:** native tool-call IDs are discarded; results become ordinary user
strings. `ChatResult.sent` omits retained history and search snippets and the UI
ignores it. Search results are untrusted external content too.

**Next:** provider-neutral typed calls/results preserving IDs; emit Anthropic
`tool_use/tool_result` and OpenAI assistant `tool_calls` / tool-role messages.
Keep the existing bounded tool loop. Capture the complete serialized provider
payload after redaction, including history and searches. Show expandable context
receipts: target, provider/endpoint/model, command blocks, redactions, queries/
results, token estimate and exact outbound text. Redact final outbound history/tool-result/model-echo content, not only user input.
Add user-defined/structured redaction patterns; label the filter best-effort, not guaranteed secrecy.
Known grammar residuals include YAML tagged values and block scalars, shell
command substitutions and backticks, source-language comparisons/Go `:=`, and
YAML plain scalars containing shell-like quote prefixes after `:`. Examples
include `password == "example words"`, `password := "example words"` and
`password: $'example words'`: the current filter can leave their quoted text
visible, sometimes after masking only an operator/prefix. Add format-aware
parsing and serialized provider-request regressions for those forms; never execute expressions while
redacting. Keep a conservative fallback for terminal text that is not valid
structured input. Static shell words and adjacent recognized fields are covered
by the open #132 slice and should not be implemented again.

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

### Quotas, snapshots and abuse controls — SOL-049, SOL-050; SOL-002/SOL-007 residual

**Evidence:** request/batch/blob caps and expired limiter pruning already exist.
Accounts can still accumulate unbounded blobs/tokens; full pulls materialize the
account. Active unique-key spray grows limiter memory; username-only limits enable
lockout and do not protect prelogin/registration.

**Next:** account/token/record/blob/total-byte quotas; validate configured limits.
Paginate against a defined snapshot/revision contract, not a moving watermark.
Independent `seq <= W` queries across requests are not one historical snapshot:
test records updated/deleted between pages and preserve eventual delta delivery.
Separate bounded source-IP and account rate buckets, trusted-proxy policy,
prelogin/register limits and `Retry-After`; shared/persistent state if supporting
replicas. Reject malformed
prelogin username types as structured 4xx, not internal 500.

**Gate:** concurrent quota edges, large historical accounts, ID spray, targeted
lockout, proxy spoofing, restarts and exhausted pages; bounded memory/disk and
clear actionable status codes.

### Account transactions, schema and backups — SOL-051, SOL-054

**Start:** SQLite registration/deletion and `_migrate`.

**Next:** atomic create-or-conflict including initial sequence/token; live-account
token joins and delayed-login/delete races. Transactional deletion is implemented
in open PR #133 above; do not duplicate that slice. Version schema with transactional
`PRAGMA user_version` migrations and foreign keys/checks/cascades. Define bounded
asynchronous contention retries, backoff and `Retry-After`; do not add seconds of
synchronous `busy_timeout` that block the shared isolate. #71 already fails
transaction contention atomically with `503 storage_busy`; empty pushes stay
read-only. Document synchronous/durability settings and WAL-aware online backup /
restore. Never copy only the main DB file while ignoring active WAL state.

**Gate:** concurrent registration/delete/login, orphans, migration interruption,
cross-process kill/lock recovery, disk full, corruption and restore during writes.
Two-connection contention and trigger rollback tests do not prove power-loss or
cross-process crash durability.

### Readiness, drain and observability — SOL-052, SOL-053, SOL-055

**Correction:** #48 replaced Compose's old `--help` check with real HTTP health;
do not implement that obsolete fix again. `/healthz` remains liveness only.

**Next:** bounded SQLite-aware `/readyz`; actual-container CI smoke test for
register/login/push/pull/persistence/restart. Stop accepting on SIGTERM, drain with
a deadline, finish/rollback transactions, close/checkpoint SQLite and handle
repeated signals. Log request ID/route/status/duration/size and sanitized server
errors; add auth/throttle/push/DB latency counters. #71 adds sanitized cleanup
failure codes and fail-closed 503s, not general observability. Preserve causal stack
traces when wrapping errors and add structured diagnostics for ordinary failures.
No authorization, verifier, blob, request-body or raw command logging.

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

The shared Linux packager executes downloaded appimagetool without a pinned
digest and caches by basename. Verify host-architecture digests and source-aware
cache keys before executing either downloaded or cached tooling; test mismatch,
URL collision and interrupted downloads. Keep explicit local-tool overrides.

Android's committed sideload key gives upgrade continuity, not private publisher
authenticity. Exclude keystore-dependent data from incompatible backup restore;
verify upgrade data retention. If distributing publicly, use protected signing.
Add iOS LAN disclosure and narrowly tested transport policy; explain that phone
`localhost` is the phone. Review cleartext sync/provider URL policy and publish
reverse-proxy examples. Correct stale scratch/static-image and every-request
version claims.

**Gate:** tag mismatch/prerelease tests, actual packaged install/upgrade, failed
rollout recovery, checksums, LAN endpoints and signed mobile relaunch.

### Review-service latency and configuration drift — P2

**Evidence:** both `.github/workflows/zai-code-review.yml` files set
`MAX_CHUNK_CHARS: 25000`, while the adjacent comment warns that this size exhausted
the reasoning/output budget and says the action default should be used. The
initial #132 assessment needed two output-limit retries before returning useful
feedback. Séance permits a 170-minute attempt; Poltergeist permits two such
attempts. These are configured ceilings, not evidence that every run times out.

**Next:** verify the pinned action's actual defaults and chunk/retry behavior;
measure representative small and large patches with proposed chunk sizes.
Reconcile comments with the chosen settings and choose an explicit wall-clock/
retry budget from coverage, latency and failure data. Coordinate with the
current-PR scope fix in Poltergeist's ANALYSIS.md; inherited changes must not
inflate the workload. Do not change the reviewer workflow during an active
assessment merely to manufacture approval.

**Gate:** record complete coverage, elapsed time, retries and output-limit
failures; timeout and partial-review notices remain distinguishable from clean
reviews; superseded heads are cancelled and no stale result approves a new head.

## Adaptive layout, aesthetics and convenience

### Three-stage layout and navigation — SOL-039, SOL-060, SOL-062, SOL-065; SEA-015, SEA-018

**Current:** the 960 px breakpoint still drops both side panes together. Pane
widths now persist, narrow Back has a PopScope and closes drawers first, and
window defaults are laptop-sized (1280x800). Retain these implemented behaviors.

**Next:** wide list/terminal/utility -> medium list/terminal plus utility drawer
-> phone routes. Add explicit collapse intent distinct from automatic constraints,
persist utility-tab/selection where useful, constrain dialogs/drawers to actual
space, and verify geometry after monitor changes. Keyboard splitter work from
this review is listed in the PR ledger, not a new implementation task.

**Gate:** 320/700/960/1440 px, 1x/2x text, IME, RTL, monitor removal, native Android
predictive Back/iOS swipe and breakpoint changes. No lost session/editor state,
unexpected exit or focus theft.

### Accessible controls and terminal preferences — SOL-061, SOL-064; SEA-019, SEA-020, SEA-021, SEA-039

**Current:** device themes, persisted terminal font/palette/zoom, mobile cursor
modes, grapheme-safe middle labels and a composed shaped status badge exist.
Remaining work is interaction/semantics validation and missing preferences.
Main now starts new devices and Reset in Terminal; partial themes and host
themes without extensions retain the Séance/Automatic fallback. Preserve this
distinction and saved choices. The baseline captures predate this default change;
the supplemental Terminal renders and their limits are recorded above.

**Next:** touch-specific 48 dp key/tab/close targets without bloating desktop;
key deck currently offers about 34 dp height. Bounded live safety notices,
accessible expiry/action policy, keyboard resize verification, useful terminal
screen-reader fallback, persistent recovery notices. Add cursor/blink/scrollback/
bell/ligature/OSC52/remote-title policies as distinct features.

**Gate:** tap-target and semantics tests, native assistive technology, color-vision
simulation, large text and selection during output. Remote titles cannot impersonate
trusted chrome; honor reduced motion. Do not replace the existing status palette
or create another theme picker.

### Visual hierarchy and identity — SOL-063; visual-direction backlog

**Next:** use the baseline sidebar fixtures as a starting point, then capture
complete native light/dark desktop/mobile screens with the current Terminal
default and other presets. Preserve each chosen palette's identity; reduce
duplicated utility headings, unlabelled icon
clusters and inert empty space. Use short context-sensitive empty-state actions,
consistent spacing/radii/density and a quiet host-identity edge. Terminal palettes
remain user-controlled. Add recoverable theme preview, resolved contrast diagnostics and a legible
keyboard reset for extreme palettes. Preserve explicit server colors and verify
theme JSON interchange with Poltergeist. Normalize visible platform names within signing/bundle
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

**Next:** extend Files widget tests with picker/opener fakes; keyboard/accessibility pass;
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

### Bounded notices and editor privacy — UI-04, UI-08, UI-09, UI-10

Both top-toast implementations append an unbounded non-scrolling stack and
start fixed expiry timers without live-region semantics. Add a shared visible
limit, duplicate coalescing, overflow/history and accessible action expiry policy.
Choose text color against the resolved background; do not force white on custom
light fills. Safety/recovery incidents need persistent discoverability.

Gate: 20 notices at 320x568 and 2x text, no overflow, one-shot actions, native
announcements, focused action survival and reduced motion. Keep notices above
the shell prompt. Test fixed-height utility/session tabs and keyboard-open layouts
without clamping the user's text scale globally.

The remote editor disables suggestions but omits IME personalized-learning
suppression. Add the hint to editor/search fields in both siblings, preserving
composition, undo and smart-quote settings; verify on Android. This is not a
guarantee against a malicious keyboard. Benchmark large editor files and giant
lines: byte/line recounts and TextField layout remain after syntax cutoff.
Optimize only measured hot paths, with BOM/line-ending fidelity and save safety.

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
| Files breadcrumb return trail | Surface existing endpoint-scoped folder history, distinct from host favorites. Test chroot/disconnected identity, keyboard access and exact return paths; never issue an implicit shell `cd`. |
| Quiet motion | One shared reduced-motion policy for routes, drawers and notices. With `disableAnimations`, remove spatial slides/tweens while progress, focus, navigation and cancellation still complete correctly. |

Later, separate proposals: terminal splits, tmux/Mosh persistence, provider-native
search, sync OIDC and libghostty. Historical proposals and their ownership links
remain in the archive; verify the current implementation before planning more work.

## Completed scope retained in the archive

The complete earlier PR ledger, benchmark counts, review history and residual
mapping remain in [the prior analysis](docs/reviews/analysis-2026-09-05.md).
Completed changes are not instructions to implement again: KDF ceilings, auth
field privacy, footer layout, default status contrast, client release tests,
HTTP cleanup, recognizable-secret capture filtering, transactional record
push/pull, unknown-kind preservation, SFTP/editor features, terminal selection,
current vault re-key journal, deletion intents, independent secret timestamps,
app mutation queue, agent/jump transport, device themes and narrow Back handling.
Residuals above remain independent of these foundations.

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

## Implementation handoff

All code PRs remain open for owner review and merging, on separate branches
from the reviewed main. The check/review snapshot recorded at publication does
not certify later commits or native behavior.

| PR | Final reviewed head | Remote checks and review |
|---|---|---|
| #132 | `8bfd0eb` | Eight build/test checks passed, including all five client builds, package/app tests and Docker; both final full-review checks passed. Six assessments completed; the final two were full reviews of this same revision with no agreed important finding in the implemented forms. One superseded hybrid refresh was cancelled and is excluded. |
| #133 | `659e034` | All nine checks passed, including five client builds, package/app tests, Docker and review. Two completed distinct-revision assessments, no agreed important findings. |
| #134 | `1322090` | All nine checks passed, including five client builds, package/app tests, Docker and review. Two completed full assessments on distinct revisions, no agreed important findings. |

| PR | Branch | Local evidence |
|---|---|---|
| #132 | `codex/redact-quoted-secrets` | Seven initial failures reproduced quoted-value leaks. Later fail-first regressions cover punctuation boundaries, custom-filter ordering, `secret_key` and AWS secret-access-key labels, adjacent assignments and complete static shell words; 551 core tests and analysis pass on `8bfd0eb`. Unit tests and actual OpenAI/Anthropic request bodies reproduced the AWS, overlap and shell-word leaks before repair. Redaction still cannot promise arbitrary secret detection. |
| #133 | `codex/atomic-account-deletion` | Four failures reproduced partial deletion. All 72 server tests and analysis pass, including API-level 500/rollback, contention and full unaffected-account assertions. Cross-process crash and power-loss tests remain separate. |
| #134 | `codex/accessible-pane-resizing` | Six accessibility/RTL regressions failed before repair, followed by rapid opposite-arrow and modified-arrow regressions. All 34 focused resize/narrow-Back tests and full Flutter analysis pass on `1322090`. Native assistive technology remains unverified. |

Review decisions to retain: #133's optional unknown-account store no-op test
was deferred; deleted-token retry already returns 401 at the HTTP boundary and
contention tests verify no partial commit. A repeated suggestion for an explicit
autocommit assertion after HTTP 500 was also deferred: the tested subsequent
successful DELETE must begin a fresh transaction and would fail if one remained
open. Two completed assessments on distinct revisions found no agreed important
issues. This does not close the separately listed delayed-login/account-deletion
race.

#134's first assessment prompted the modifier-arrow guard so Alt/Ctrl/Meta
shortcuts pass through a focused divider. Optional settings-write coalescing
needs measurement first: writes are atomic and serialized, width bounds limit
repeats, and `setPaneWidths` does not notify the whole app. English semantics
match the current untranslated UI; localization is a separate app-wide task.
Speculative layout-invariant and disabled-adjustment-value polish was deferred.
The second full assessment at `1322090` found only optional polish, completing
two distinct-revision assessments without agreed important findings. Repeated
bound-announcement/write-coalescing suggestions, Shift-arrow behavior and SDK
drift notes were deferred; the existing semantics APIs had already compiled on
the CI-pinned SDK, and latest-head CI is recorded separately.

#132's first completed assessment succeeded after two output-limit retries; it
did not time out. Its verified `SECRET_KEY` bypass prompted a narrow fix and
reset the clean-review count. A purported blocker referred to a deliberately
synthetic test fixture and was rejected with test evidence. Short unquoted
values remain masked deliberately: benign short configuration values can be
false positives, but reinstating the old length floor would expose short
passwords. The filter remains best-effort rather than a guarantee of secrecy.
The second assessment exposed standard `AWS_SECRET_ACCESS_KEY` fields. A
unit test and both provider-body tests confirmed the leak before its fix; this
also reset the clean-review count. The claimed `client_secret_key` bypass was
refuted and its already-working masking is now explicitly tested. A queued
same-head reassessment was cancelled before the genuine AWS fix and does not
count as a completed assessment.

The third assessment at `1822c40` had no important findings. Its subsequent full
reassessment exposed an overlapping-label bypass: an earlier unquoted value
could consume the next label and leave its secret visible. This reset the clean
count again. Local independent checks also found static shell-word fragments;
`8bfd0eb` repairs both, including the equality-at-quote boundary, newline and
three-field chains, ANSI-C/localized quotes, concatenated fragments and escaped
spaces. The reviewer's proposed `<=` cursor guard was too broad; a verified
quoted-value regression requires `<` instead. Ambiguous single-quote backslash
handling remains conservative to avoid leaking valid Python-style strings.
YAML tags/block scalars and dynamic shell expressions remain explicit grammar
residuals above. The repeated synthetic-fixture blocker and claimed absence of
tests were rejected using the fixture content and actual provider tests.

The fifth completed assessment, a full review at `8bfd0eb`, found no agreed
important defect in the implemented forms. Its comparison/Go-operator and
colon-prefixed plain-scalar suggestions are acknowledged as concrete grammar
gaps above, rather than denied or treated as universal redaction approval.
An ad hoc operator exclusion is unsafe: `password==secret` can itself be a
valid shell assignment whose value begins with `=`. These expansions need
format context and their own tests. The superseded hybrid refresh had included
inherited main changes; it was cancelled and replaced with a full-current-PR
assessment, not counted as a completed round. The shared reviewer-scope task
is recorded in Poltergeist's ANALYSIS.md.

The sixth assessment completed successfully at `8bfd0eb` after three output-limit
failures and smaller-chunk retries; it did not time out. Its proposed
`RangeError` is prevented by the existing guard: an emitted value starts at or
after `match.end`, and that end cannot precede `copiedThrough`. Its generic
`env`/`FOO` examples are not recognized secret labels. The escaped-space claim
overlooks the later `=` branch's `_shellWordEnd` result; the whitespace claim
overlooks the assignment regex's trailing whitespace consumption. Built-in
masking and scanner/provider tests are present. These claims and the repeated
synthetic-fixture warning were rejected with source/test evidence; seven direct
probes of cited inputs and equivalent recognized labels passed. The stated
YAML/dynamic-shell gaps remain tracked work, not a secrecy guarantee.

Optional mock-client teardown, request-count diagnostics, label-list linking,
phase-order documentation, assertion wording and tighter benchmark timing were
deferred. Reinstating a value-length floor or guessing that ordinary-looking
words are public would expose valid short/word-based secrets. The final two
full assessments establish the requested feedback steady state on one revision;
they are not two distinct-revision rounds under the repository's default metric.
The PR remains open for owner review and merging.
