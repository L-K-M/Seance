# Seance Engineering And Product Analysis

Last consolidated: 2026-07-09

Review base: `origin/main` at `a673d70`

This is the durable backlog produced by a full review of the protocol,
cryptography, SSH/core package, sync client, sync server, Flutter application,
platform configuration, tests, release/deployment tooling, performance,
accessibility, visual design, and product experience.

The temporary review document `sol.md` was intentionally not added to `main`.
Its completed items are recorded in the PR ledger below, and every incomplete or
partially complete item is retained here with enough context to resume work.

## Baseline Verification

The reviewed `main` baseline was verified with:

```bash
dart analyze packages/seance_protocol packages/seance_core packages/seance_sync_server
LD_LIBRARY_PATH=/tmp/seance-sol-lib \
  dart test packages/seance_protocol packages/seance_core packages/seance_sync_server

cd app/seance_app
flutter analyze
flutter test
```

Results at review time:

- Pure-Dart analysis: clean.
- Pure-Dart tests: 106 passed. The local container exposes only
  `libsqlite3.so.0`, so a temporary external `libsqlite3.so` symlink was needed.
- Flutter analysis: clean.
- Flutter tests: 20 passed.

The project has strong foundations: clear packages and interfaces, shared wire
models, strict TOFU behavior, sensible cryptographic primitives, an explicit
review-before-run assistant invariant, and meaningful regression tests for
terminal resize and trace storms. The highest risks are in synchronization
semantics and durable credential ownership rather than the primitive choices.

## Priority Legend

| Priority | Meaning |
|---|---|
| P0 | Data loss, command execution, security-model break, or permanent divergence |
| P1 | Major functionality, privacy, reliability, or common-workflow failure |
| P2 | Performance, robustness, accessibility, or significant polish issue |
| P3 | Low-risk hardening, cleanup, documentation, or future-facing improvement |

## Pull Request Ledger

### Merged Before This Review Pass

| PR | Change | Residual work |
|---|---|---|
| [#1](https://github.com/L-K-M/Seance/pull/1) | Reject CR/LF in generated commands and snippets | Central safe staging is still needed; see SOL-047 |
| [#2](https://github.com/L-K-M/Seance/pull/2) | Bind chat paste tools to the originating session | Chat state is still global rather than per-session |
| [#3](https://github.com/L-K-M/Seance/pull/3) | Redact common modern token formats | Redaction remains best-effort; inspector still absent |
| [#4](https://github.com/L-K-M/Seance/pull/4) | Bind Compose HTTP port to loopback | App transport policy and reverse-proxy examples remain |
| [#5](https://github.com/L-K-M/Seance/pull/5) | Return generic server errors | Server-side structured logging remains absent |

### Reviewed PRs Merged After Analysis

PRs #6 through #14 were merged after the review and analysis commit. Their
changes are now part of `main`; the notes below are residual risks or follow-up
work found during review, not a request to revert the merged improvements.

| PR | Merged change | Residual review finding |
|---|---|---|
| [#6](https://github.com/L-K-M/Seance/pull/6) | Atomic JSON writes and corruption recovery | All writers share one `.tmp` path; concurrent fallback can delete a valid destination; transient I/O is treated as corruption |
| [#7](https://github.com/L-K-M/Seance/pull/7) | Credential edit guard, port validation, supported default auth | Blank-key wipe is fixed, but auth transitions can retain a wrong old secret; editor paths lack direct tests |
| [#8](https://github.com/L-K-M/Seance/pull/8) | HTTP/LLM/search timeouts | `Future.timeout` does not cancel the request; owned clients still lack disposal; stream idle/body limits remain |
| [#9](https://github.com/L-K-M/Seance/pull/9) | Expanded danger-linter patterns | Quoted paths, long options, redirection, and option-order forms still evade rules |
| [#10](https://github.com/L-K-M/Seance/pull/10) | Honor redaction toggle and lint chat commands | Outbound inspector remains absent; broader redaction limitations remain under SOL-045 |
| [#11](https://github.com/L-K-M/Seance/pull/11) | Body, batch, and blob limits | No account quotas or pull pagination; configured limits still need strict startup validation |
| [#12](https://github.com/L-K-M/Seance/pull/12) | Reconnect controller binding and scrollback-wide select-all | Reconnect production path and helper are not directly covered |
| [#13](https://github.com/L-K-M/Seance/pull/13) | Reject KDF downgrades | 4 GiB memory ceiling and unbounded iterations/parallelism/hash length still allow client DoS |
| [#14](https://github.com/L-K-M/Seance/pull/14) | Pause probes in the background | Bootstrap/background ordering and Flutter lifecycle wiring need broader tests |
| [#15](https://github.com/L-K-M/Seance/pull/15) | Snippet filtering and dialog controller lifecycle | Review regressions were fixed before merge: controllers now belong to route State and an active filter remains editable below the normal visibility threshold |

### Existing PRs Still Open

| PR | Intended change | Review assessment before merge |
|---|---|---|
| [#16](https://github.com/L-K-M/Seance/pull/16) | Publish a stably signed Android APK | The upgrade-signature blocker is fixed with a deliberately public, stable sideloading key; remove the temporary PR-only signing workflow before merge and document that this provides continuity, not publisher authenticity |

### Open PRs Created From This Analysis

Each change is on its own branch to minimize conflict and was independently
reviewed after implementation.

| PR | Change | Verification | Remaining scope |
|---|---|---|---|
| [#17](https://github.com/L-K-M/Seance/pull/17) | Advance sync cursor only through observed pulls; do not use push watermarks; keep rejected writes dirty until the winner is pulled | Core full suite + analysis | Atomic server pull snapshots and local CAS remain |
| [#18](https://github.com/L-K-M/Seance/pull/18) | Parse private keys before opening an SSH socket | Core full suite + analysis | Handshake/auth deadlines and general ownership cleanup remain |
| [#19](https://github.com/L-K-M/Seance/pull/19) | Prune expired login-limiter buckets periodically | Server full suite + analysis | Source-IP policy, active-window spray, and distributed limiting remain |
| [#20](https://github.com/L-K-M/Seance/pull/20) | Preserve UTF-8 decoder state across SSH packets; fix headless UTF-8 | Core and Flutter full suites + analysis | Output batching/backpressure remains |
| [#21](https://github.com/L-K-M/Seance/pull/21) | Enforce canonical 32-byte recovery codes and a fixed vector | Protocol full suite + analysis | Recovery-key semantics/enrollment UI remain |
| [#22](https://github.com/L-K-M/Seance/pull/22) | Complete bounded chat tool loops with a final tools-disabled turn | Core full suite + analysis | Provider-native tool-result messages remain |
| [#23](https://github.com/L-K-M/Seance/pull/23) | Respect DECCKM for mobile cursor keys and add control semantics | Flutter full suite + analysis | Custom key decks and larger touch targets remain |
| [#24](https://github.com/L-K-M/Seance/pull/24) | Truncate labels by grapheme and expose full semantic labels | Flutter full suite + analysis | Broader status/terminal accessibility remains |
| [#25](https://github.com/L-K-M/Seance/pull/25) | Validate sync enrollment, confirm registration passphrase, and perform an initial sync | Flutter full suite + analysis | Transactional re-key/recovery remains |
| [#26](https://github.com/L-K-M/Seance/pull/26) | Reserve a usable terminal width and clamp pane drags | Flutter full suite + analysis | Pane persistence/collapse and mobile navigation remain |

## Immediate P0 Work

### SOL-001: Persist typed tombstones so deletions do not return

Priority: P0

References: `app/seance_app/lib/app_state.dart:186-198,311-316`,
`app/seance_app/lib/services/app_services.dart:150-168`,
`packages/seance_core/lib/src/sync/sync_coordinator.dart:43-87`,
`packages/seance_protocol/lib/src/records/record_codec.dart:17-43`

The app hard-deletes server/snippet domain objects. Every sync creates an empty
local mirror, and `collectLocal()` sees only objects that still exist, so no
tombstone is emitted. The old remote record is pulled from sequence zero and
recreates the deleted item.

Tombstones also use an empty blob and decrypt as `RecordKind.serverConfig`, so a
snippet, host-key, or secret tombstone cannot be routed correctly. Host keys
have no deletion API. Revoking credential sync does not remove the previous
remote encrypted secret.

Action:

- Create one durable sync ledger for records, dirty state, cursor, origin, and tombstones.
- Record a tombstone before deleting a domain object.
- Carry authenticated kind and identity in every tombstone.
- Add deletion APIs for every synchronized record kind.
- Tombstone credentials when per-item or global secret sync is revoked.
- Test delete on A, restart both clients, sync A/B repeatedly, and prove no resurrection.

### SOL-002: Make pull records and watermark one atomic snapshot

Priority: P0

References: `packages/seance_sync_server/lib/src/server.dart:176-180`,
`packages/seance_sync_server/lib/src/storage.dart`

PR #17 stops trusting an unseen `latestSeq` client-side, but the server still
reads `recordsSince()` and `latestSeq()` separately. A concurrent write between
those calls produces an inconsistent response and extra retries. Pagination
will require a real snapshot cursor anyway.

Action:

- Add one storage operation returning `{records, watermark}` from a consistent snapshot.
- In SQLite, read watermark W and return only `since < seq <= W` in one transaction.
- Paginate against W so concurrent writes belong to the next snapshot.
- Add barrier-controlled concurrent tests around watermark capture.

### SOL-005: Make local sync acknowledgement compare-and-set

Priority: P0

References: `packages/seance_core/lib/src/sync/local_record_store.dart:19-20,56-60`,
`packages/seance_core/lib/src/sync/sync_engine.dart`

`markSynced(id, seq)` does not identify which local revision was sent. If an edit
lands while a push is in flight, the old acknowledgement can clear the new
dirty value. Applying a stale pull after `collectLocal()` can similarly overwrite
a domain edit.

Action:

- Acknowledge the exact sent operation ID/revision/content hash.
- Leave a newer local revision dirty.
- Merge remote snapshots against current domain state rather than an earlier collection.
- Serialize account sync runs through one mutex/queue.
- Test local edit while push is blocked and remote apply while domain edit is blocked.

### SOL-006: Replace full transient synchronization with a durable mirror

Priority: P0

References: `app/seance_app/lib/services/app_services.dart:157-168`,
`packages/seance_core/lib/src/sync/sync_coordinator.dart:43-87`

Every five-minute run starts at sequence zero, re-encrypts every item under a
new nonce, stamps every item with the current device, marks all items dirty,
pulls the full account, and rewrites domain files. An unchanged device-A record
can be republished as a device-B write.

Action:

- Create a persistent `LocalRecordStore` at application initialization.
- Preserve remote device/sequence metadata until domain content actually changes.
- Batch domain application in one transaction/write.
- Return `converged` and pending counts in `SyncOutcome`.
- Add restart, unchanged-resync, offline-edit, and interrupted-sync tests.

### SOL-007: Make server LWW compare, sequence allocation, and upsert atomic

Priority: P0

References: `packages/seance_sync_server/lib/src/server.dart:195-205`,
`packages/seance_sync_server/lib/src/sqlite_storage.dart:118-168`

Two concurrent requests can compare against the same old record and then write
in arrival order, allowing the LWW loser to overwrite the winner. Sequence
allocation and record storage are separate autocommit operations. Batch pushes
can partially commit before returning an error.

Action:

- Move compare/resolve/sequence/upsert into a storage-level batch operation.
- Use `BEGIN IMMEDIATE` and allocate/update in one SQLite transaction.
- Serialize the in-memory implementation equivalently.
- Decide and document whether a batch is atomic or returns durable per-record partial results.
- Add concurrent same-ID, crash, and multi-process tests.

### SOL-011: Authenticate the complete client-authored record envelope

Priority: P0

References: `packages/seance_protocol/lib/src/records/record.dart`,
`packages/seance_protocol/lib/src/records/record_codec.dart`,
`packages/seance_protocol/lib/src/crypto/vault.dart`

The ciphertext authenticates `{kind, data}` only. `id`, `updatedAt`, `deviceId`,
and `deleted` control routing/LWW but are mutable. Tombstones have no tag. A
breached server or stolen token can forge a far-future deletion, replay stale
host-key ciphertext with winning metadata, or transplant blobs between IDs.

Action:

- Bind canonical client-authored metadata with AEAD associated data or verify a duplicate inside ciphertext.
- Include purpose domain, payload schema, key epoch, kind, identity, and deletion flag.
- Encrypt authenticated tombstone payloads rather than accepting empty blobs.
- Do not bind server-assigned sequence.
- Add field-by-field tamper, replay, transplant, and tombstone-forgery tests.
- Define and implement a versioned migration before changing shipped records.

### SOL-014: Bound all Argon2 parameters before key derivation

Priority: P0

References: `packages/seance_protocol/lib/src/crypto/vault.dart`,
`app/seance_app/lib/services/app_services.dart:129-148`, merged PR #13

The prelogin endpoint controls client KDF parameters. PR #13 adds a minimum but
allows a 4 GiB memory value and lacks safe ceilings for iterations, parallelism,
and output length. A malicious endpoint can kill a desktop or phone before
credentials are checked.

Action:

- Fix output length at 32.
- Set conservative mobile-safe maximum memory, iteration, and parallelism values.
- Validate exact salt/verifier lengths client-side and server-side.
- Reject fractional and out-of-range JSON before invoking Argon2.
- Add an end-to-end malicious-prelogin test that proves no expensive call starts.

### SOL-029: Make credential edits explicit and transactional

Priority: P0

References: `app/seance_app/lib/ui/server_editor.dart`, merged PR #7

Current main can overwrite a stored private key with empty text when unrelated
fields are edited. PR #7 guards that path, but auth transitions can still retain
an old `secretRef`; a password can be interpreted as a key or an obsolete secret
can remain stored/synced after the user thinks it was removed.

Action:

- Model credential changes as explicit keep, replace, or remove.
- Validate required fields per auth mode before persistence.
- Save config and secret changes as one transaction/unit of work.
- Delete obsolete local and synchronized secret records only after successful replacement.
- Test every transition among password, stored key, referenced key, and agent.

### SOL-030: Make vault re-key transactional and recoverable

Priority: P0

References: `app/seance_app/lib/services/app_services.dart:89-148`, PR #25

PR #25 prevents blank/typo registration and performs an initial sync. The
underlying re-key still overwrites secrets one at a time, changes in-memory key
state before keystore persistence, and migrates only secrets referenced by
current configs. Failure can leave a mixed-key vault.

Action:

- Add `VaultStore.listIds` and enumerate every encrypted secret.
- Re-encrypt into a separate temporary vault and verify every record.
- Atomically swap vault/key only after complete success.
- Keep rollback material until the new key and vault reopen successfully.
- Show/export a recovery artifact before destructive re-key.
- Test interruption at every phase.

### SOL-031: Never silently replace a missing secure-storage key

Priority: P0

References: `app/seance_app/lib/services/secure_master_key.dart`, iOS project settings

The iOS secure-storage configuration needs real entitlement/relaunch testing.
More generally, a null key read can create a new key while `vault.json` still
contains ciphertext, permanently orphaning credentials.

Action:

- Add and verify iOS debug/profile/release entitlements required by the plugin.
- If encrypted data exists, treat a missing key as recovery-required, not first run.
- Present an unlock/recovery screen and keep the old vault untouched.
- Add signed iOS/macOS relaunch, update, migration, and keystore-loss tests.

### SOL-048: Hash, expire, and revoke bearer tokens

Priority: P0

References: `packages/seance_sync_server/lib/src/sqlite_storage.dart:35-39,103-115`,
`packages/seance_sync_server/lib/src/server.dart:216-220`

Tokens are permanent plaintext rows. A leaked database/backup becomes live API
access that can fetch blobs, upload malicious metadata, or delete an account.
Repeated logins create unlimited rows. Current documentation incorrectly says a
database leak cannot allow login.

Action:

- Store SHA-256 token hashes only.
- Add creation, expiry, last-use, device ID/name, and per-account token limits.
- Add logout, current-device revoke, revoke-all, and device/session listing.
- Require recent verifier authentication for account deletion.
- Rotate existing tokens during migration.
- Correct the breach-model documentation.

## Protocol And Sync Backlog

### SOL-008: Define a deterministic total order for writes

Priority: P1

References: `packages/seance_protocol/lib/src/records/lww.dart`

Exact timestamp/device/sequence ties are non-commutative, and an already
sequenced old value can beat a same-millisecond new local value. Client-supplied
sequence is accepted even though sequence is server-owned.

Action:

- Use an authenticated operation ID, monotonic per-device counter, or hybrid logical clock.
- Keep server sequence exclusively as a delta cursor.
- Reject non-null client sequences.
- Add commutative, associative, idempotent, exact-tie, and clock-rollback tests.

### SOL-009: Report incomplete convergence honestly

Priority: P1

References: `packages/seance_core/lib/src/sync/sync_engine.dart`

Missing, duplicate, or unknown push-result IDs are accepted. Dirty records can
remain after `maxRounds`, but the UI reports success.

Action:

- Require exactly one acknowledgement for every sent ID.
- Reject unknown/duplicate results and invalid sequence movement.
- Return convergence/pending state or throw when rounds are exhausted.

### SOL-010: Give secrets independent revisions

Priority: P1

References: `packages/seance_protocol/lib/src/models/secret.dart`,
`packages/seance_core/lib/src/sync/sync_coordinator.dart:53-63`

Secret records borrow the owning server's `updatedAt`. Credential-only changes
can order incorrectly, and shared secrets depend on whichever server timestamp
was used.

Action:

- Give each secret an independent immutable identity and update revision.
- Emit one record per secret regardless of reference count.

### SOL-012: Hide record kind and hostnames in wire IDs

Priority: P1

References: `packages/seance_core/lib/src/sync/sync_coordinator.dart:53-84`

IDs such as `secret:`, `snippet:`, and `hostkey:<hostname>:<port>` disclose
record category and endpoint metadata despite the opacity claim.

Action:

- Derive stable opaque IDs with a domain-separated keyed HMAC over kind and canonical identity.
- Plan a protocol migration and preserve old records until converted.

### SOL-013: Make protocol parsing strict and typed

Priority: P1

References: protocol record and DTO `fromJson` factories

Missing `accepted` defaults true, missing blobs become empty tombstones, missing
versions default current, arbitrary `num` values are truncated, negative values
are accepted, and unknown enums silently become password/server-config behavior.

Action:

- Require every wire field and exact integer types.
- Enforce nonnegative ranges, length limits, and canonical envelope combinations.
- Require protocol version consistently or rely solely on `/v1` and update docs.
- Throw typed `ProtocolFormatException`s.
- Quarantine unknown future kinds instead of misrouting them.
- Fuzz/property-test every parser with missing, wrong-type, huge, and fractional values.

### SOL-016: Add fixed cryptographic compatibility vectors

Priority: P1

References: `packages/seance_protocol/test/crypto_test.dart`

PR #21 adds a fixed recovery-code vector, but Argon2id, HKDF, verifier hash, and
XChaCha compatibility are still only self-tested with matching code paths.

Action:

- Add independent fixed vectors for Argon2id, HKDF domains, verifier hashing, and XChaCha open.
- Run at least one production-parameter KDF compatibility test separately from fast tests.
- Complete the proposal's external crypto/protocol review before sync GA.

### SOL-017: Define passphrase Unicode normalization

Priority: P2

Visually identical NFC/NFD text currently derives different keys across input
methods. Define NFC in a versioned KDF format, test it across platforms, and
document migration before stable release.

### SOL-018: Stop exposing mutable key/ciphertext storage

Priority: P3

Defensively copy key/blob inputs, expose read-only views or copies, verify a
decrypted secret's ID matches the requested ID, and minimize retention of the
root key.

## SSH, TOFU, Probe, And Terminal Backlog

### SOL-020: Own the complete SSH connection lifecycle

Priority: P1

References: `packages/seance_core/lib/src/ssh/ssh_session.dart`

PR #18 prevents the local key parse socket leak. Remaining problems include no
deadline for handshake/auth/shell creation, `SSHClient` construction outside a
complete ownership guard, callback registration races, and shell completion
that does not set `_closed` or tear down subscriptions/client.

Action:

- Add phase and total connection deadlines with cancellation.
- Transfer socket/client ownership through one `try/finally` lifecycle.
- Expose a replayable closed future/state and disconnect reason.
- Make shell completion, stream failure, user close, and timeout share idempotent teardown.

### SOL-021: Preserve keyboard-interactive echo metadata

Priority: P1

References: `ssh_session.dart:404-412`, `keyboard_interactive_dialog.dart`

Passwords and OTPs are displayed in plain text because the SSH prompt echo flag
is discarded.

Action:

- Pass an app-facing prompt model with text and echo flag.
- Obscure no-echo fields, validate answer count, and support explicit cancellation.
- Make long instruction/multi-prompt dialogs scrollable.
- Add core mapping and widget privacy tests.

### SOL-022: Evaluate SSH config like OpenSSH

Priority: P1

References: `packages/seance_core/lib/src/ssh_config/ssh_config_import.dart`

Wildcard defaults are dropped, only one alias from multi-host blocks is kept,
later values overwrite OpenSSH first-value semantics, quotes/comments are
misparsed, repeated blocks/Include/multiple identities are unsupported,
ProxyJump is discarded, and missing user can become empty.

Action:

- Implement two-pass first-value evaluation over all matching blocks.
- Import every concrete alias and apply wildcard/default directives.
- Tokenize quotes/comments correctly and expose unsupported directives in a preview.
- Consider `ssh -G` as the desktop evaluator where available.
- Represent imported credentials as setup-required rather than guessing silently.

### SOL-023: Make TOFU endpoint identity canonical and repins atomic

Priority: P1

References: `packages/seance_core/lib/src/hostkey/tofu.dart`, HostKey model

Concurrent first connections can approve different keys and race. A stale
changed-key dialog can overwrite a newer pin. Equivalent DNS/IP spellings create
separate pins and can turn a changed key into apparent first use.

Action:

- Canonicalize DNS case/trailing dot, IDNA, IP literals, and ports.
- Serialize verification per endpoint and compare-and-set repins.
- Validate known-hosts fields and encoded key algorithm.

### SOL-024: Verify SSH banners and bound probes

Priority: P2

References: `packages/seance_core/lib/src/probe/probe_service.dart`

The prober reports any successful TCP connect as online, starts every host at
once, conflates refusal/DNS/route failures, and can race disposal after an await.
PR #14 addresses background pause only.

Action:

- Parse SSH identification lines and require `SSH-`.
- Distinguish refusal from timeout/DNS/network uncertainty.
- Bound concurrency or stagger hosts individually.
- Track disposed state after every await.
- Skip connected sessions and add per-host probe opt-out.

### SOL-026: Batch terminal output and coalesce resize

Priority: P2

PR #20 fixes split UTF-8. Output is still fed packet-by-packet with no bounded
queue, and every drag/window frame can send a remote PTY resize.

Action:

- Batch feed work per event-loop/frame with a bounded queue/backpressure policy.
- Coalesce duplicate/rapid resize events.
- Benchmark `yes`, large files, Unicode, resize spam, and session switching against latency budgets.

### SOL-027: Complete the terminal backend seam

Priority: P2

The app reaches into `XtermTerminalEngine` for terminal widget, selection,
controller, scrollback, pending input, and injection. A libghostty swap would
still touch broad UI code.

Action:

- Add focused renderer/controller/input/scrollback capabilities.
- Keep safe staged-command insertion backend-independent.
- Build the proposal's headless conformance rig before swapping engines.

### SOL-028: Complete common SSH power-user workflows

Priority: P1

- Implement Unix socket and Windows named-pipe ssh-agent signing.
- Support 1Password/Bitwarden/OpenSSH agents.
- Execute ProxyJump and map imported aliases to jump hosts.
- Prompt for referenced-key passphrases without requiring storage.
- Verify strict-KEX/Terrapin behavior and establish an SSH CVE watch.
- Add a real sshd version/auth/cipher matrix in CI.

## Flutter Application And Platform Backlog

### SOL-032: Cancel stale connection attempts and dispose every engine

Priority: P1

References: `app/seance_app/lib/app_state.dart:230-283,478-500`

Reconnect does not cancel the old attempt. Deleting a server while connect is
pending can produce an inaccessible live session. Failed attempts have no
`SshSession`, so their engines are not disposed. Teardown closes only live
sessions and is not awaited.

Action:

- Give each attempt an identity/generation and cancellation state.
- Commit completion only while it remains current; close stale results immediately.
- Dispose engines on failure, replacement, disconnect, close, and app teardown.
- Disable duplicate reconnect while connecting and expose Cancel.
- Add delayed-fake lifecycle tests.

### SOL-033: Reconcile remote shell closure completely

Priority: P1

Core calls `onClosed` but does not tear down or set closed state. The app keeps a
non-null session and clears only `connecting`.

Action:

- Route remote completion through idempotent core teardown.
- Clear/replace app session state and keep an explicit disconnect reason.
- Preserve final scrollback for reconnect diagnostics.

### SOL-034: Replace fragile JSON persistence or fully serialize it

Priority: P1

Merged PR #6 improves the current truncate-in-place behavior but introduces a
shared-temp race and broad error recovery. Linux also permits multiple app
processes writing the same files.

Action:

- Prefer the planned transactional SQLite client store.
- If JSON remains, use an in-process queue, process lock, unique temp names, flush/fsync, atomic rename, and backup.
- Distinguish malformed JSON from permission/transient I/O failures.
- Add concurrent writer, crash, backup recovery, and multi-process tests.

### SOL-035: Represent missing local credentials explicitly

Priority: P1

Synced configs retain `secretRef` even if credentials are local-only. On a new
device a null lookup becomes an empty password/key and causes misleading auth
failure.

Action:

- Add a `credential required on this device` state.
- Prompt before network connection and never synthesize empty credentials.

### SOL-036: Use sandbox-compatible private-key selection on macOS

Priority: P1

Typed `~/.ssh/id_ed25519` paths do not grant a sandboxed app read access.

Action:

- Use a file picker and persist a security-scoped bookmark, or import the key into the vault.
- Add a picker/import preview for SSH config.

### SOL-037: Serialize every sync entry point

Priority: P1

`syncNow()` can overlap startup, periodic, or debounced `_autoSync()` calls while
all mutate the same stores and status.

Action:

- Use one async mutex/queue for manual and automatic sync.
- Coalesce queued edits without losing an explicit manual request.

### SOL-038: Cancel or discard stale asynchronous UI work

Priority: P2

Settings model discovery, sync buttons, command generation, and chat can call
`setState` or mutate a terminal after route/dialog disposal. Dismissing command
generation does not cancel insertion. Resetting chat during a request can let an
old result repopulate the new conversation.

Action:

- Add generation tokens and cancellable/drop-stale requests.
- Prevent dismissal while uncancelled work can alter the PTY, or make cancellation explicit.
- Check `mounted` after every await and use `try/finally` for busy flags.
- Disable/reset chat safely while a turn is in flight.

### SOL-039: Give narrow mode real navigation history

Priority: P1

Narrow mode swaps widgets with a boolean. Android Back can exit instead of
returning to servers; iOS lacks swipe-back and restoration.

Action:

- Use a nested Navigator/router, or at minimum a `PopScope` with correct route semantics.

### SOL-040: Finish mobile security, networking, and signing

Priority: P1

Android backup can restore encrypted preferences without the keystore key. iOS
lacks local-network disclosure for LAN endpoints. Mobile `localhost` means the
phone. PR #16 now uses a committed stable sideloading key, which fixes upgrade
continuity but deliberately does not establish private publisher authenticity.

Action:

- Exclude/scopely configure Android backup for secure-storage data.
- Add iOS local-network usage text and tested transport exceptions only where needed.
- Provide mobile endpoint guidance/discovery.
- Decide whether debug-grade public signing is sufficient; use a protected private release key if publisher authenticity matters.
- Test upgrade installation and local-data retention across released APKs.
- Gate app artifacts on Flutter analysis/tests.

## Assistant, Privacy, And Safety Backlog

### SOL-041: Bound chat history and keep terminal context turn-local

Priority: P1

Terminal context is embedded in a user message and retained in `_history`, so
old untrusted output is resent every turn. Cost, latency, memory, and injection
exposure grow until provider context limits fail.

Action:

- Keep ephemeral terminal context outside persistent conversation history.
- Maintain separate histories per SSH session.
- Apply deterministic token/byte budgets with summarization or truncation.
- Show what old context will be resent.

### SOL-042: Use native structured tool-result protocols

Priority: P1

PR #22 fixes iteration limits and current text-role alternation. Tool-call IDs
are still discarded and results are ordinary user strings. Strict Anthropic and
OpenAI implementations expect their own structured tool messages.

Action:

- Model assistant tool calls and tool results in the provider abstraction.
- Emit Anthropic `tool_use`/`tool_result` blocks.
- Emit OpenAI assistant `tool_calls` and `role: tool` messages with IDs.
- Mark search content as untrusted.
- Add second-request wire-format tests for both providers.

### SOL-044: Build a complete outbound context receipt

Priority: P1

`ChatResult.sent` omits old history and search result snippets, and the Flutter
UI ignores it. The privacy promise is therefore not inspectable.

Action:

- Capture the exact complete provider payload after redaction for each request.
- Render an expandable receipt with host, selected output, redactions, queries/results, model, endpoint, and token estimate.

### SOL-045: Treat secret redaction as best-effort

Priority: P2

Patterns cannot reliably detect arbitrary passwords, cookies, kubeconfigs,
credential URLs, or every vendor token.

Action:

- Add user-defined patterns and structured credential patterns.
- Label redaction honestly as best-effort.
- Use local-provider badges and the exact outbound inspector as the backstop.

### SOL-046: Stop storing arbitrary no-echo input as command history

Priority: P1

The opt-in command tracker reconstructs all outgoing keystrokes and cannot know
whether the remote disabled echo. Passwords can be written to
`command_stats.json`; filtering happens only when presenting suggestions. The
same pending input can prefill cloud command generation.

Action:

- Prefer OSC 133 command boundaries before enabling capture.
- At minimum, filter before persistence rather than after.
- Never send unknown no-echo pending input to an LLM.

### SOL-047: Centralize safe command staging

Priority: P1

Merged PRs #1/#2/#10 improve individual paths, but generator,
snippets, and chat still separately append text to current PTY input and surface
danger differently.

Action:

- Add one backend-independent `stageCommandForReview` API.
- Reject line/control/format hazards and lint danger at the final boundary.
- Verify session identity/connectivity and handle a non-empty current prompt explicitly.
- Prefer a local editable Safe Draft Dock before sending text to the PTY.

## Sync Server And Operations Backlog

### SOL-049: Add account quotas and paginated pulls

Priority: P1

PR #11 limits a request/batch/blob, but a token can still fill disk and
`since=0` materializes the full account response.

Action:

- Add account/token/record/blob/total-byte quotas.
- Validate all configured limits at startup.
- Paginate pulls against a fixed snapshot watermark.
- Return 413 and quota-specific structured 4xx errors.

### SOL-050: Complete abuse-resistant rate limiting

Priority: P1

PR #19 removes indefinite stale-bucket retention without scanning on every
request. Active unique-key spray can still grow state within one window.
Username-only limits also permit targeted lockout, reset on restart, and do not
cover prelogin/registration.

Action:

- Add separate source-IP and account buckets.
- Bound active state with a policy that does not turn capacity into global lockout.
- Add prelogin and registration limits and `Retry-After`.
- Define trusted-proxy client-IP handling.
- Use shared/persistent limits if multiple replicas are supported.

### SOL-051: Make account lifecycle transactional

Priority: P1

Registration check/create and account deletion span independent statements and
can race or leave orphan state.

Action:

- Make create return created/conflict atomically.
- Wrap account, initial sequence, and token creation in one transaction.
- Enable foreign keys with cascading deletion.
- Join token lookup to a live active account.

### SOL-052: Add real readiness checks

Priority: P1

Compose runs `seance-sync --help`, which says nothing about the running HTTP
process or database. `/healthz` is liveness only.

Action:

- Probe the actual HTTP server from the container healthcheck.
- Add `/readyz` with a bounded SQLite read/write or integrity check.
- Add a built-in healthcheck CLI if no HTTP client belongs in the image.
- Run the built image in CI and smoke register/login/push/pull/restart.

### SOL-053: Drain requests and close SQLite on shutdown

Priority: P1

Current shutdown force-closes connections and exits without storage disposal.

Action:

- Stop accepting, drain with deadline, finish/rollback transactions, close/checkpoint SQLite, then exit.
- Handle repeated signals safely and test SIGTERM during reads/writes.

### SOL-054: Add schema migrations, constraints, and backup policy

Priority: P1

Action:

- Use transactional `PRAGMA user_version` migrations.
- Enable foreign keys, checks, cascade deletion, and a bounded busy timeout.
- Document synchronous/durability settings.
- Document/test online backup and restore while WAL is active.
- Test lock contention, disk full, corruption, migration, and abrupt termination.

### SOL-055: Add safe structured observability

Priority: P1

PR #5 hides internal errors from clients, but errors are now also invisible to
operators.

Action:

- Log request ID, route, status, duration, response size, and sanitized exception/stack.
- Never log authorization, verifiers, blobs, or request bodies.
- Add counters for auth failure, throttle, push accept/reject, DB latency, and response size.

### SOL-056: Harden releases and deployment updates

Priority: P1

Action:

- Validate SemVer tags against every pubspec before publishing.
- Emit Docker `latest` only for stable releases.
- Pin actions and container bases by immutable versions/digests.
- Publish checksums and multi-architecture images if ARM is supported.
- Back up before schema updates, wait for readiness, and roll back failed deploys.
- Correct docs that claim scratch/static image, every-request versioning, and ciphertext-only DB leakage.

## Performance And Responsiveness Backlog

### SOL-057: Split the monolithic `AppState` notifier

Priority: P2

Probe sweeps, sync status, suggestions, and sessions rebuild broad shell/server/
terminal/sidebar widgets through one notifier.

Action:

- Split server status, sessions, sync, settings, and suggestions into focused listenables/selectors.
- Keep terminal widget identity out of probe-driven rebuild paths.
- Profile with large host lists before and after.

### SOL-058: Cancel and dispose network clients

Priority: P2

PR #8 adds caller timeouts, but timeout does not cancel underlying I/O. Owned
`http.Client`s have no lifecycle contract, and periodic sync creates new clients
that rely on GC.

Action:

- Add ownership-aware `close()` APIs and close short-lived clients in `finally`.
- Use cancellable requests/clients and response/body limits.
- Add connect, total, and stream-idle deadlines.

### SOL-059: Batch domain-store application

Priority: P2

Applying pulled records rewrites whole JSON collections per record. Combined
with current full pulls, this causes unnecessary disk churn and UI-isolate work.

Action:

- Apply a pull in one transaction or one atomic collection write.
- Move production KDF and large serialization off the UI isolate only after profiling.

## Visual, Layout, And Accessibility Backlog

### SOL-060: Finish adaptive pane behavior after PR #26

Priority: P2

PR #26 reserves a 480 px terminal, clamps side panes, and uses a viable 960 px
three-pane breakpoint.

Remaining actions:

- Add explicit list/utility collapse controls.
- Persist pane ratios rather than absolute widths.
- Add keyboard/focus resizing and screen-reader semantics to handles.
- Add large-text golden tests and test dynamic platform window constraints.

### SOL-061: Add terminal appearance and accessibility settings

Priority: P1

`SeanceTheme.monoFallback` is unused. Terminal style stays on xterm defaults and
offers no font size/family, light/dark palette, cursor, scrollback, ligature, or
bell controls.

Action:

- Apply a deliberate terminal style and the mono fallback stack.
- Add zoom shortcuts and accessible font-size limits.
- Add professional spectral light/dark palettes, cursor, bell, and scrollback controls.

### SOL-062: Use laptop-safe and remembered window geometry

Priority: P2

The 1800x1600 desktop default exceeds common work areas.

Action:

- Start near 1180x760, clamp to monitor work area, set a useful minimum, and restore geometry.

### SOL-063: Normalize product naming and desktop metadata

Priority: P2

Some iOS/Linux/Windows strings still show `seance_app` or `Seance App`; Linux
lacks normal desktop/AppStream icon integration. The photographic source icon
is memorable at full size but muddy at launcher scale.

Action:

- Normalize visible names under platform constraints.
- Add `.desktop`, AppStream, and Linux icon assets.
- Derive a simplified terminal/planchette/sigil small-size icon.

### SOL-064: Complete accessibility after PRs #23 and #24

Priority: P1

PR #23 labels mobile terminal controls and PR #24 makes label truncation
grapheme-safe with full semantics. Remaining issues include color-only status,
unfocusable resize handles, small key targets, non-live safety notices, and an
unlabeled terminal surface.

Action:

- Add non-color status text/icons and semantic state labels.
- Make resize handles focusable and keyboard adjustable.
- Raise touch targets toward 48 dp while preserving compact horizontal scrolling.
- Mark safety notices as live regions.
- Give the terminal a useful screen-reader description/fallback.
- Respect reduced-motion for future animations.

### SOL-065: Make chat and dialogs constraint-aware

Priority: P2

Chat bubbles cap at 300 px in a wide panel; the drawer is a fixed 380 px on
narrow phones; several long credential dialogs need scroll/keyboard constraints.

Action:

- Size bubbles/drawers from available constraints.
- Make every credential/long-content dialog scrollable and keyboard-safe.

## User Experience And Missing Features

### Daily workflow

- P1: Add a fuzzy command palette for hosts, snippets, settings, reconnect, sync, and assistant actions.
- P1: Add server search, favorites, recently used, tags/groups, and duplicate detection.
- P1: Add quick connect for one-off hosts without saving.
- P1: Add first-run SSH config file import with preview, warnings, and deduplication.
- P1: Add cancel/retry/copy actions for connections and assistant requests.
- P1: Render assistant Markdown with safe code-block copy/stage affordances.
- P1: Stream assistant output and expose Stop/Retry.
- P1: Surface the exact outbound context receipt.
- P1: Add sync logout, device list/revoke, account deletion, passphrase rotation, and conflict/deletion audit.
- P1: Ship encrypted export/import without a server and complete recovery enrollment.
- P1: Add optional biometric/passcode app lock on mobile.
- P2: Remember last active host, utility tab, pane ratios, and per-host terminal scale.
- P2: Reconcile remotely edited/deleted configs with live sessions; represent deleted active sessions as explicit orphans.
- P2: Add terminal find, local paste preview, scrollback controls, bell settings, and OSC 52/title policies.
- P2: Add a provider test action with latency and actionable diagnostics.
- P2: Expose Brave Search settings or remove the half-wired configuration.
- P2: Populate `HostContext` with OS, distro, shell, cwd, and exit status.

### Power-user and later features

- Real ssh-agent support across Unix/macOS/Windows.
- ProxyJump execution and editing.
- Local, remote, and dynamic port-forwarding UI.
- Known-hosts import/export and visual randomart.
- Per-device key generation and one-click public-key deployment.
- Focused upload/download or an SFTP browser.
- OSC 133 command blocks for context, history, cwd, exit status, and suggestions.
- Persistent/reconnecting mobile sessions and Mosh.
- Provider-native web search in addition to SearXNG/Brave.
- Optional splits/tabs after single-session ergonomics are stable.
- A real libghostty backend only after stable API/release and conformance coverage.

## Delightful Product Ideas

These ideas should remain useful, optional, professional, and reduced-motion
aware. The theme should reinforce identity and trust rather than obscure an SSH
client's behavior.

### Fingerprint spirit sigils

Render deterministic randomart/identicons from host-key fingerprints on server
tiles and TOFU/re-pin screens. A key change visibly changes the host's identity,
making the theme a real security aid.

### Safe Draft Dock

Stage AI commands, snippets, and history in a local editable strip above the
terminal. Show target host, environment, source, and danger findings. Only an
explicit action sends the text to PTY input. This solves prompt concatenation
and centralizes review-before-run.

### The Planchette

Use one keyboard-first fuzzy palette for hosts, snippets, settings, and actions.
A restrained planchette motif can indicate selection without compromising speed.

### Production wards

Allow production/staging/lab tags with color and symbol cues. Offer extra
confirmation when a critical command, `sudo`, or destructive action is staged
against production.

### OSC 133 command-block actions

Give completed commands Explain, Save as snippet, Copy, Rerun, Compare output,
and Include in chat actions. This also fixes precise context and command stats.

### Last words

On disconnect, preserve the final command/output block and show duration, last
cwd, exit/disconnect reason, reconnect, copy, and save actions.

### Presence and heartbeat

Use a restrained online breathing indicator, unknown-state flicker, connection
materialization, and latency sparkline from keepalives. Never animate the
terminal surface and respect reduced motion.

### Custom mobile key deck

Allow per-host key layouts, haptics, long-press repeat, application-mode-aware
keys, clipboard/history actions, and saved decks.

### Context ledger

Attach a compact privacy receipt to each assistant response: host, command
blocks, redactions, searches/results, provider/model, token estimate, and exact
outbound payload.

### Visual identity

Use calm near-black/navy terminal surfaces, parchment-warm highlights, muted
violet, and one vivid status accent. Keep photographic ghost art for onboarding
or marketing and use a simpler terminal/sigil mark at launcher and toolbar size.

## Test And Release Gates

Before sync or credential handling is described as production-ready:

- Add restart-level two-device deletion tests for every record kind.
- Add forced interleaving for pull watermark, push rejection, and local edit acknowledgement.
- Add authenticated-envelope tamper/replay/transplant tests.
- Add real HTTP-over-SQLite concurrency tests rather than only in-memory HTTP integration.
- Add fixed independent crypto vectors and external review.
- Add real sshd password/key/keyboard-interactive/changed-key/resize/output/strict-KEX matrix tests.
- Add signed iOS/macOS keystore relaunch and stable Android upgrade tests.
- Add adaptive golden/semantics tests at phone, tablet, laptop, and large text sizes.
- Run the Docker image in CI with persistence, readiness, register/login/push/pull, restart, and SIGTERM.

## Strengths To Preserve

- Shared protocol code prevents ordinary client/server schema drift.
- XChaCha20-Poly1305, Argon2id, and HKDF domain separation are sensible choices.
- Strict TOFU and visually distinct changed-key handling are correct defaults.
- Review-before-run and default secret redaction are load-bearing product invariants.
- Terminal, store, sync, and provider interfaces are valuable seams even where they need expansion.
- Stable server-list keys, connection logs, mobile keys, top notices, snippets,
  and automatic sync status are thoughtful daily-use touches.
- The name and premise are distinctive enough to support a memorable interface
  without sacrificing predictable professional behavior.
