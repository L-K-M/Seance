# Seance Engineering And Product Analysis

Last consolidated: 2026-07-25

Review base: `origin/main` at `10edf74`

The durable backlog for Séance. It consolidates two full review passes:

- **2026-07-09** — protocol, cryptography, SSH/core, sync client and server,
  Flutter application, platform configuration, tests, release tooling,
  performance, accessibility, visual design, and product experience. Its
  findings are numbered `SOL-nnn`.
- **2026-07-25** — a second, independent pass over the whole repository after
  PRs #1–#31 landed, focused on bugs, performance, interface and layout,
  missing features, and product ideas. Its findings are numbered `SEA-nnn`.

Both temporary review documents (`sol.md`, `claude.md`) were deliberately kept
out of `main`; everything in them lives here. Completed work is recorded in the
pull-request ledger and in [Resolved And Retired](#resolved-and-retired) rather
than deleted, so no context is lost.

## Baseline Verification

```bash
dart analyze packages/seance_protocol packages/seance_core packages/seance_sync_server
dart test    packages/seance_protocol packages/seance_core packages/seance_sync_server

cd app/seance_app
flutter analyze
flutter test
```

Results at the 2026-07-25 pass (Dart 3.12.2, Flutter 3.44.8):

| Check | 2026-07-09 | 2026-07-25 |
|---|---|---|
| Pure-Dart analysis | clean | clean |
| Pure-Dart tests | 106 passed | **187 passed** |
| Flutter analysis | clean | clean |
| Flutter tests | 20 passed | **136 passed** |

`libsqlite3` no longer needs a manual symlink on this container.

The project has strong foundations: clear packages and interfaces, shared wire
models, strict TOFU behavior, sensible cryptographic primitives, an explicit
review-before-run assistant invariant, and meaningful regression tests for
terminal resize and trace storms. The highest risks remain in synchronization
semantics and durable credential ownership rather than the primitive choices.
The second pass found no new defects in the protocol or the server; the weakest
area is now terminal presentation and navigation ergonomics.

## Priority Legend

| Priority | Meaning |
|---|---|
| P0 | Data loss, command execution, security-model break, or permanent divergence |
| P1 | Major functionality, privacy, reliability, or common-workflow failure |
| P2 | Performance, robustness, accessibility, or significant polish issue |
| P3 | Low-risk hardening, cleanup, documentation, or future-facing improvement |

## Pull Request Ledger

### Merged (#1–#31)

Every pull request from the first review pass has landed. Residual work found
while reviewing each one is kept here, because the corresponding `SOL-` entries
below describe *only* what remains.

| PR | Merged change | Residual finding |
|---|---|---|
| [#1](https://github.com/L-K-M/Seance/pull/1) | Reject CR/LF in generated commands and snippets | Central safe staging still needed — SOL-047 |
| [#2](https://github.com/L-K-M/Seance/pull/2) | Bind chat paste tools to the originating session | Chat state was global rather than per-session; hoisted to `AppState` in #37, still not per-session |
| [#3](https://github.com/L-K-M/Seance/pull/3) | Redact common modern token formats | Redaction remains best-effort; inspector absent — SOL-045 |
| [#4](https://github.com/L-K-M/Seance/pull/4) | Bind Compose HTTP port to loopback | App transport policy and reverse-proxy examples remain |
| [#5](https://github.com/L-K-M/Seance/pull/5) | Return generic server errors | Server-side structured logging remains absent — SOL-055 |
| [#6](https://github.com/L-K-M/Seance/pull/6) | Atomic JSON writes and corruption recovery | All writers share one `.tmp` path; transient I/O treated as corruption — SOL-034. `SettingsStore` was missed entirely; fixed in #38 |
| [#7](https://github.com/L-K-M/Seance/pull/7) | Credential edit guard, port validation, supported default auth | Auth transitions can retain a wrong old secret — SOL-029 |
| [#8](https://github.com/L-K-M/Seance/pull/8) | HTTP/LLM/search timeouts | `Future.timeout` does not cancel the request — SOL-058 |
| [#9](https://github.com/L-K-M/Seance/pull/9) | Expanded danger-linter patterns | Quoted paths, long options, redirection still evade rules |
| [#10](https://github.com/L-K-M/Seance/pull/10) | Honor redaction toggle and lint chat commands | Outbound inspector remains absent — SOL-044 |
| [#11](https://github.com/L-K-M/Seance/pull/11) | Body, batch, and blob limits | No account quotas or pull pagination — SOL-049 |
| [#12](https://github.com/L-K-M/Seance/pull/12) | Reconnect controller binding; scrollback-wide select-all | Superseded by #27's session-keyed views |
| [#13](https://github.com/L-K-M/Seance/pull/13) | Reject KDF downgrades | Unbounded memory/iterations still allow client DoS — SOL-014 |
| [#14](https://github.com/L-K-M/Seance/pull/14) | Pause probes in the background | Probes still ran against connected hosts, unbounded — fixed in #36 |
| [#15](https://github.com/L-K-M/Seance/pull/15) | Snippet filtering; dialog controller lifecycle | The server list had no equivalent filter — fixed in #34 |
| [#16](https://github.com/L-K-M/Seance/pull/16) | Stably signed Android APK | Provides continuity, not publisher authenticity |
| [#17](https://github.com/L-K-M/Seance/pull/17) | Sync cursor advances only through observed pulls | Atomic server pull snapshots and local CAS remain — SOL-002, SOL-005 |
| [#18](https://github.com/L-K-M/Seance/pull/18) | Parse private keys before opening a socket | Handshake/auth deadlines remain — SOL-020 |
| [#19](https://github.com/L-K-M/Seance/pull/19) | Prune expired login-limiter buckets | Source-IP policy and spray defence remain — SOL-050 |
| [#20](https://github.com/L-K-M/Seance/pull/20) | Preserve UTF-8 across SSH packets | Output batching/backpressure remains — SOL-026 |
| [#21](https://github.com/L-K-M/Seance/pull/21) | Canonical 32-byte recovery codes | Recovery-key enrollment UI remains |
| [#22](https://github.com/L-K-M/Seance/pull/22) | Bounded chat tool loops | Provider-native tool-result messages remain — SOL-042 |
| [#23](https://github.com/L-K-M/Seance/pull/23) | DECCKM cursor keys on mobile | Custom key decks and larger touch targets remain — SEA-020 |
| [#24](https://github.com/L-K-M/Seance/pull/24) | Grapheme-safe label truncation | The helper was not reused elsewhere — SEA-006 |
| [#25](https://github.com/L-K-M/Seance/pull/25) | Validate sync enrollment | Transactional re-key/recovery remains — SOL-030 |
| [#26](https://github.com/L-K-M/Seance/pull/26) | Reserve a usable terminal width; clamp pane drags | Persistence, collapse, and the single 960 px cliff remain — SOL-060, SEA-015, SEA-018 |
| [#27](https://github.com/L-K-M/Seance/pull/27) | Terminal selection overhaul (vendored xterm fork) | No scrollback search — SEA-023 |
| [#28](https://github.com/L-K-M/Seance/pull/28) | Per-server connection tabs | Tabs were unnamed and unreachable by keyboard — #33, SEA-025 |
| [#29](https://github.com/L-K-M/Seance/pull/29) | Notify when a newer release exists | — |
| [#30](https://github.com/L-K-M/Seance/pull/30) | Identity files in the macOS sandbox; Browse…; read audit log | Resolves SOL-036 |
| [#31](https://github.com/L-K-M/Seance/pull/31) | Harden the PR-review workflow | — |

### Open, from the 2026-07-25 pass

Each is on its own branch, with mostly disjoint files so they can land in any
order. Every one is `analyze`-clean with tests.

| PR | Change | Addresses | Verification |
|---|---|---|---|
| [#32](https://github.com/L-K-M/Seance/pull/32) | Configurable terminal appearance: size, family, palette, zoom shortcuts | SEA-013, SOL-061 (part) | 145 Flutter tests (+9) |
| [#33](https://github.com/L-K-M/Seance/pull/33) | Session tab names from OSC 7/0/2, plus a host/cwd/exit status bar | SEA-014 | 149 Flutter tests (+13) |
| [#34](https://github.com/L-K-M/Seance/pull/34) | Server list filter, Enter-to-open, Escape-to-clear | SEA-024 | 141 Flutter tests (+5) |
| [#35](https://github.com/L-K-M/Seance/pull/35) | Connection-log rebuild storm; bounded `recentText`; teardown hygiene | SEA-001, SEA-005, SEA-011, SOL-057 (part) | 142 Flutter tests (+6) |
| [#36](https://github.com/L-K-M/Seance/pull/36) | Skip probing connected hosts; bound probe concurrency | SEA-003, SEA-004 | 193 Dart tests (+6) |
| [#37](https://github.com/L-K-M/Seance/pull/37) | Chat survives the drawer closing; pane-proportional bubbles | SEA-010, SEA-016, SOL-065 (part) | 143 Flutter tests (+7) |
| [#38](https://github.com/L-K-M/Seance/pull/38) | Quarantine a corrupt settings file; salvage `deviceId` | SEA-002 | 145 Flutter tests (+9) |

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
- **Make CI's container and Gradle pulls survivable.** Observed repeatedly on
  2026-07-25: with several PRs open at once, `Sync server Docker image` fails
  at `FROM debian:stable-slim` with `i/o timeout` to `registry-1.docker.io`,
  and `Client build (android)` fails with HTTP 429 from
  `repo.maven.apache.org` — both before any repository code is compiled, so
  every red is a false negative that has to be diagnosed by hand. Options:
  authenticate the Docker Hub pull (an authenticated token lifts the
  anonymous rate limit), pull base images through a registry mirror or the
  GitHub-hosted cache, and add a retry with backoff around the Gradle
  dependency resolution.

## Performance And Responsiveness Backlog

### SOL-057: Split the monolithic `AppState` notifier

Priority: P2

Probe sweeps, sync status, suggestions, and sessions rebuild broad shell/server/
terminal/sidebar widgets through one notifier.

PR #35 removed the worst symptom — a full-tree rebuild per SSH trace line
during every handshake — by giving the connection log its own notifier. The
split itself remains.

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

PR #32 applies a deliberate terminal style, adopts the mono fallback stack
(which was dead code), adds persisted font size/family, ships spectral
light/dark palettes with a follow-the-app mode, and binds zoom shortcuts with
clamped limits.

Remaining actions:

- Cursor shape and blink controls.
- Scrollback length and bell behavior controls.
- Ligature and OSC 52 / title policy controls.

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

PR #37 sizes chat bubbles from the pane's own constraints. The drawer is still
a fixed 380 px on narrow phones, and several long credential dialogs still need
scroll/keyboard constraints.

Remaining actions:

- Size the drawer from available constraints.
- Make every credential/long-content dialog scrollable and keyboard-safe.

## 2026-07-25 Pass: Open Findings

Findings from the second review pass that are **not** covered by PRs #32–#38.
Items resolved by those PRs are recorded in
[Resolved And Retired](#resolved-and-retired).

### Correctness

#### SEA-006: Grapheme-unsafe truncation outside the helper that fixes it

Priority: P3

`AppState._snippetTitle` (`substring(0, 39)`) and `AppState._shortError`
(`substring(0, 200)`) can split a surrogate pair and produce a lone surrogate —
the exact class of bug `MiddleEllipsisText` and PR #24 exist to prevent.

Action: route both through the grapheme-aware helper.

#### SEA-007: Repeated ssh_config import silently duplicates hosts

Priority: P2

`AppState.importSshConfig` assigns a fresh `uuidV4()` per parsed host and stores
it unconditionally. Importing the same file twice yields two copies of every
host, with no dedupe by host/port/user and no preview.

Action: import with a preview and a dedupe pass; see also SEA-027.

#### SEA-008: macOS terminal-focus flag is never cleared on dispose

Priority: P3

`_SessionViewState` reports focus to the native Edit menu over the
`seance/menu` channel but never sends `false` from `dispose()`. If the last
terminal is torn down while focused, the native menu keeps believing a terminal
is focused. Degrades to "⌘C does nothing", not a crash.

Action: send `false` on dispose.

#### SEA-009: The destructive-close guard lives in one call site, not in the operation

Priority: P1 — **settle before adding tab shortcuts**

`AppState.closeTab` calls `_disposeSession(deleteLocalCopies: true)`, which
permanently deletes unsaved managed SFTP edits. The only confirmation is the
dialog in `TerminalPane._closeTab`. Any new call site — a ⌘W binding, a menu
item, a mobile swipe — silently deletes user data.

Action: move the guard behind the state operation, or split the destructive
variant into a distinctly named method, *before* SEA-025 lands.

#### SEA-012: Every session of every server stays fully mounted

Priority: P2

`TerminalPane._body` builds an `IndexedStack` over all sessions across all
servers. The instant-switch rationale is sound, but the cost scales with total
open tabs, not with tabs of the visible server: each mounted `TerminalView`
holds a render object and paragraph cache, participates in every layout pass,
and forwards a PTY resize to its remote host on every window resize.

Action: mount the active server's tabs eagerly plus an LRU of others.

### Interface and layout

#### SEA-015: The layout collapses to the phone UI below 960 px

Priority: P2 (refines SOL-060)

`AdaptiveShell.breakpoint` is 200 + 480 + 260 + 2×10 = **960**. A half-screen
window on a 13" laptop (~720 px) or an iPad in split view therefore loses the
server list *and* the tiled utility panel at once.

Action: two-stage response — drop the utility pane to a drawer first (keeping
list + terminal tiled to ~700 px), then collapse fully.

#### SEA-017: Assistant replies are unformatted plain text

Priority: P1 (same item as the P1 in "Daily workflow")

`SelectableText(m.text)`. Model answers arrive with fenced code, lists, and
inline code, and render as a wall of proportional text with no per-block copy
affordance.

#### SEA-018: Pane widths, active host, and utility tab are not remembered

Priority: P2 (refines SOL-060)

`_AdaptivePaneLayoutState` initialises to constants on every launch; so does
the sidebar's selected tab and the last active server.

#### SEA-019: Status colors are hardcoded and theme-blind

Priority: P2 (refines SOL-064)

`StatusColors.online/offline/unknown` take a `BuildContext` and ignore it,
returning fixed GitHub-dark hexes. Measured against pure white — the most
favourable light surface there is — the green is **2.54:1**, below WCAG's 3:1
for non-text indicators; the grey sits on the line at 3.08:1 and the red
clears it at 3.35:1. The app's light surface is a tinted near-white, so all
three land slightly lower again. The signature is already right; only the
implementation needs to consult the theme brightness.

The green is the one that matters most: "connected" is the state a user reads
at a glance, and it is the least legible of the three.

#### SEA-020: Tab-strip touch targets are below the platform minimum

Priority: P2 (refines SOL-064)

The tab close button is a 15 px icon in a 28 px box inside a 38 px strip, shown
on touch platforms too. Material and HIG both want ≥44–48 px.

#### SEA-021: Two similar dots per server row read as one broken indicator

Priority: P3

A filled 12 px connection dot on the left and a 10 px outlined reachability dot
on the right, both grey when idle. The distinction is deliberate and documented
but reads as a rendering bug. A single composed indicator — filled for the
session, ring for reachability — would say the same thing in one glyph.

#### SEA-039: A one-shot toast is a thin channel for a sync-identity reset

Priority: P3

PR #38 tells the user once, with a ten-second toast, that their settings
file was unreadable and reset — and the flag is consumed on the launch that
finds it, because the salvage is persisted in the same step. A user looking
elsewhere for ten seconds never learns that their `deviceId` may have changed.

Action: keep the notice until acknowledged — a dismissible banner, or a marker
in Settings ▸ Sync — rather than a transient toast.

### Missing features

#### SEA-023: No scrollback search

Priority: P1 — **the most conspicuous missing terminal feature**

The vendored fork already carries `searchHitBackground`,
`searchHitForeground` and `searchHitBackgroundCurrent` in `TerminalTheme`, so
the render path has a slot for hit highlighting — but there is no search
controller, no UI, and no buffer-scanning path.

Action: implement in the fork (viewport control + hit highlighting) behind a
⌘F / Ctrl+Shift+F panel. Non-trivial; worth doing properly.

#### SEA-025: Almost no keyboard shortcuts

Priority: P1

`AppMenus` binds exactly two: new tab and settings. Missing, roughly in order:
close tab (⌘W / Ctrl+Shift+W — **after SEA-009**), select tab 1–9, cycle tabs
(Ctrl+Tab, ⌘⇧[ / ⌘⇧]), focus the server filter, clear terminal.

Constraint that makes this subtle: the terminal handles most `Ctrl` chords
itself and returns `handled`, so app-level bindings must use ⌘ on Apple and
`Ctrl+Shift` elsewhere — the convention `_handleKeyEvent` already establishes.

#### SEA-026: No auto-reconnect and no session restore

Priority: P2

A dropped connection leaves a manual Reconnect button. For a mobile client that
changes network constantly, opt-in reconnect-with-backoff and a "reopen my tabs
at launch" option are the difference between usable and irritating. The
mechanism exists: `_restoreManagedEditSessions` already recreates placeholder
tabs, but only for durable file edits.

#### SEA-027: SSH config import is paste-only

Priority: P2

The tooltip says "Import ~/.ssh/config" but the dialog only accepts pasted text
— on desktop, where the file is readable and the app already has a native
file-picker plus security-scoped bookmark path for identity files.

Action: add Browse…, reusing the existing bookmark plumbing. Pair with SEA-007.

#### SEA-028: No "copy last command output"

Priority: P2

With OSC 133 marks already parsed, `Copy last output` / `Copy last command` /
`Rerun` are a short step away and are the actions people actually reach for.
The minimum viable slice of SOL's command-block treatment.

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

### Séance-specific ideas from the 2026-07-25 pass

These are additive to the list above, not replacements.

#### SEA-031: "The spirit answered" — completion notices

When an OSC 133 `D` arrives for a session that is not on screen, pulse that tab
and optionally post an OS notification with the command, its exit code, and how
long it took. Everything needed is already parsed. A long `apt upgrade` on a
background tab is the canonical case, and the framing writes itself.

#### SEA-032: Ghost tabs — undo close

A closed tab leaves a translucent chip in the strip for ~10 s. Clicking it
reopens a session on the same host and, where shell integration is present,
`cd`s back to the last known working directory. Also defuses SEA-009 for the
common "wrong tab" mistake.

#### SEA-033: Host hues

Hash the host key fingerprint — already the canonical identity — into a hue used
for the tab underline, the status-bar edge, and the server-row accent. Unlike
production wards, which need the user to tag things, this is automatic and
zero-config, and makes "which box am I on" a peripheral-vision question. Same
input as the spirit sigils, a second representation.

#### SEA-034: Whisper mode

A one-key toggle — auto-armed when the shell reports a no-echo prompt — that
suspends command capture *and* excludes the next lines from assistant context,
with a quiet visual indicator. This retires the caveat that command suggestions
cannot tell a command from a password by making it an explicit, visible mode
instead of an opt-out.

#### SEA-035: Séance transcript

Export a session as Markdown — commands, outputs, timestamps, host, duration —
with redaction applied, into a snippet, a file, or the clipboard. The
scrollback, the OSC 133 marks, and the redactor all exist; this is assembly.

#### SEA-036: Latency as a pulse, not a number

dartssh2 already sends a keepalive every ten seconds and gets a reply.
Surfacing the round trip as a slow, low-contrast pulse on the connection dot
(with the millisecond figure on hover) answers "is the link alive or is the box
wedged?" without another readout. Must respect reduced motion.

#### SEA-037: Two-hand mobile key deck

The key row is one scrolling strip. On a phone held in two hands the reachable
zones are the lower corners: modifiers left, navigation right, punctuation in a
pull-up drawer. Pairs with the per-host decks above.

#### SEA-038: Idle divination

When a session is idle and reachable, occasionally sample cheap facts the
assistant would otherwise have to ask for (uptime, disk pressure, pending
reboots) — only with explicit per-server opt-in, and shown as a passive reading
on the server row rather than injected into the terminal. Fills the empty
`HostContext` without the assistant guessing.

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

## Resolved And Retired

Kept rather than deleted, so a future reader can tell "done" from "never
considered". Each row names the evidence.

| Item | Resolution |
|---|---|
| SOL-036 — sandbox-compatible private-key selection on macOS | **Done** in #30: `~` expansion against the real home (`expandHomePath`), a read-only `~/.ssh` entitlement exception, Browse… minting security-scoped bookmarks (`identity_bookmarks.dart`), an actionable error instead of a raw `PathNotFoundException`, and a device-local read audit trail. |
| SOL-010 residual — "honor the redaction toggle" (still listed as open in `docs/STATUS.md`) | **Done** in #10: `chat_sidebar.dart` and `command_generator.dart` both construct `SecretRedactor(enabled: settings.redactionEnabled)`. `docs/STATUS.md` is stale here — SEA-030. |
| SOL-032 — cancel stale connection attempts and dispose every engine | **Done**: `AppState._connect` closes a session whose tab was replaced mid-connect (`identical(sessionById(tab.id), tab)`), and `XtermTerminalEngine.dispose` is idempotent. The remaining fire-and-forget teardown in `AppState.dispose` is fixed in #35. |
| SOL-033 — reconcile remote shell closure | **Done**: `SshSession._remoteClosed` drains stdout/stderr with a deadline before teardown, and `onClosed` flips the tab to disconnected, releasing the SFTP controller and retaining local copies. |
| SEA-001, SEA-005, SEA-011 | #35 |
| SEA-002 | #38 |
| SEA-003, SEA-004 | #36 |
| SEA-010, SEA-016 | #37 |
| SEA-013 | #32 (size, family, palette, zoom; cursor/bell/scrollback controls remain under SOL-061) |
| SEA-014 | #33 |
| SEA-024 | #34 |
| SEA-022 | Superseded by SEA-031, which is the feature rather than the gap. |
| SEA-029 | Not a finding — a confirmation that the previous pass's power-user gaps (ssh-agent, port forwarding, ProxyJump execution, splits, Mosh, provider-native search, streaming replies, OSC 133 context) are all still open. |
| SEA-030 | Documentation drift; fold into the next `docs/STATUS.md` update: the redaction item is done, the tab strip now shows at one tab, and `AGENTS.md` §8 names a long-dead development branch. |

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
