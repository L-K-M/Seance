# Séance: engineering and product backlog

Consolidated 2026-09-26. Code base: `origin/main` at `f5570dd` (PRs #132 to
#142 merged; #145 and #146 in review). Review base for new findings: `dd7e105`.
This file is the single forward-looking backlog. It merges two backlogs written
the same day: the sibling reviewer's ANALYSIS.md (built on [tmp.md](tmp.md))
and the backlog from the 2026-09-26 deep review. Nothing from either was
dropped: duplicates were merged into one entry carrying both sets of IDs,
evidence and gates. Completed work is listed only in the compact
[completion ledger](#completion-ledger); older detailed records stay in
[the 2026-09-05 archive](docs/reviews/analysis-2026-09-05.md) and
[the July archive](docs/reviews/analysis-2026-07-25.md).

## Sources and identifiers

| Source | What it is |
|---|---|
| [tmp.md](tmp.md) | Sibling review of both apps, 2026-09-26, bases Séance `dd7e105` / Poltergeist `913ca3d` (review before implementation). Its PRs #132 to #134 have merged. |
| [docs/reviews/deep-review-2026-09-26.md](docs/reviews/deep-review-2026-09-26.md) | Deep review, 2026-09-26, base `dd7e105`: slices S1 to S5, X and L. |
| [docs/reviews/analysis-2026-09-05.md](docs/reviews/analysis-2026-09-05.md) | Previous backlog and completion ledger (archive, unchanged). |
| [docs/reviews/analysis-2026-07-25.md](docs/reviews/analysis-2026-07-25.md) | July backlog (archive). |
| [astra.md](astra.md) | Earlier review; source of AST identifiers. |

| Prefix | Source | Notes |
|---|---|---|
| SOL, SEA, AST | Earlier reviews ([astra.md](astra.md), archives) | Stable IDs; keep them. |
| SEA26-SEC, UI, BOTH-REV | Sibling review [tmp.md](tmp.md) | Mapped onto the entries below. The sibling's UI identifiers collide with this file's UI area IDs, so they are always written "UI-nn (sibling review)"; a bare UI-nn is an entry here. Sibling UI-01, UI-05, UI-06, UI-07 and UI-11 are Poltergeist-only and live in its ANALYSIS.md. |
| S1 to S5, X, L | [Deep review](docs/reviews/deep-review-2026-09-26.md) (S1 protocol/server/sync, S2 core, S3 app services, S4 UI, S5 backlog audit, X cross-app, L live-app run) | S5 statuses were applied to every old entry. |
| STATUS n | `docs/STATUS.md` "Open items" numbering | Several code comments cite wrong numbers (see DOC-01). |

Poltergeist has a sibling ANALYSIS.md. Items that need a Séance change for
Poltergeist's sake are here ([Cross-app](#cross-app-with-poltergeist));
purely Poltergeist work is not.

## How to use this file

1. Pull current main. Cut one focused branch per entry slice from
   `origin/main`; one PR per slice. Honour the owner's merge instructions.
2. Pick from the [recommended sequence](#recommended-sequence), or any entry
   whose Status is `Open`. Skip entries marked `In review: #N` or
   `In progress` unless coordinating with that work.
3. Re-anchor evidence before editing. Line numbers are from `dd7e105` unless
   marked `@9322f6e` or `@f5570dd`. `app_state.dart` moved by about +30 lines
   between `dd7e105` and `9322f6e`. #140 (merged after `9322f6e`) changed
   `sync_engine.dart` and `sync_coordinator.dart`, so re-anchor line numbers in
   those two files; `app_state.dart` gained 10 lines near `:1580`.
   Entries S2-04 to S2-22 came from a review slice that was cut short: they
   have only a one-line finding, so re-trace the evidence first and record what
   you find in the PR.
4. A bug fix starts with the Gate's regression test failing, then the fix.
5. Preserve public protocol/core compatibility with Poltergeist and the service
   boundaries in AGENTS.md. Migrations need compatibility and rollback
   fixtures, never an ad hoc rewrite of existing vaults.
6. When an entry ships, delete it here and add one line to the completion
   ledger with the PR link. Put residuals back as entries.

**Priorities.** P0: a trust boundary or major loss risk. P1: correctness,
privacy or reliability. P2: substantial usability or performance. P3: optional
polish or hardening.

**Status values.** Open; Partial (some slices done, listed); In review: #N (PR
open, keep the entry until merged); In progress (branch exists, no PR yet).

**Verification commands** (AGENTS.md §3; never run bare `dart test` at the root):

```bash
export PATH=/opt/dart-sdk/bin:/opt/flutter/bin:$PATH
dart pub get
dart analyze packages/seance_protocol packages/seance_core packages/seance_sync_server
dart test    packages/seance_protocol packages/seance_core packages/seance_sync_server
(cd app/seance_app && flutter pub get && flutter analyze && flutter test)
(cd third_party/xterm && flutter test)          # vendored fork, not analyze-gated
dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart -o /tmp/seance-sync
docker build -f packages/seance_sync_server/Dockerfile -t seance-sync .
scripts/test-macos-accessibility.sh             # macOS, after flutter build macos
```

Recorded baselines at `dd7e105` (neither is a claim about later commits):

- Linux container, Flutter 3.47.2 / Dart 3.13.2 (deep review): package
  analysis clean, 778 package tests pass; app analysis clean, 1,083 app tests
  pass.
- macOS, Flutter 3.47.3 / Dart 3.13.3, while CI pins Flutter 3.47.2 (sibling
  review): package analysis and all 778 package tests pass; app analysis clean,
  1,079 app tests pass, two skipped, two desktop capture fixtures fail without
  real fonts. Both capture failures disappeared in a separate 20-test real-font
  capture run; the complete app suite was not rerun after that.

Not verified anywhere: real macOS/Windows/iOS/Android devices, signed Apple
keychains and keystores, physical mobile IME and Back, Docker at runtime,
native assistive technology, sustained frame timing, Windows agent behaviour,
power-loss recovery. Prior version counts and historical CI stay in the
archive.

## Assessment

The code is careful and heavily tested; remaining defects sit at subsystem
seams and in failure and recovery paths. Rare I/O, keystore or protocol errors
can still become permanent loss, and adversarial input (a hostile server,
terminal output, odd file names) reaches code that assumed friendly input. Do
not call account sync production-ready until the gates in
[Invariants and release gates](#invariants-and-release-gates) pass. Both
reviews agree that trust reconciliation, account activation and recovery, and
the unauthenticated sync envelope are the largest risks.

**Visual QA record (sibling review).** Baseline source and light/dark sidebar
fixtures were inspected at `dd7e105`: twenty capture tests produce 30 PNGs and
pass using local Arial/Courier through the fixtures' font aliases. These are
widget renders, not release-font or native-device QA. The composed status
badges and the quiet coloured glyph vocabulary are coherent. Supplemental QA
on main `5c02fe0`: a temporary copy of the capture fixture used
`SeanceTheme.build(ThemePresets.initial, brightness, platform: platform)`
instead of `SeanceTheme.light`/`dark` (which still select Séance/Automatic).
Four representative capture tests passed and produced nine Terminal-palette
PNGs. Comfortable and compact 200 dp rails, a 280 dp rail, a 390 dp phone and
the menu showed no obvious new layout or contrast blocker; status colours stayed
distinct and explicit host colours survived. Endpoint elision remains. Twelve
existing Terminal/default/preset-contrast assertions passed sequentially after
a concurrent native-assets codesign race. The temporary harness was removed;
this is supplemental render evidence, not new stock-fixture coverage. The
phone FAB note is under UI-10.

Implemented foundations to preserve (do not reimplement): the vault re-key
journal (`FileVaultStore.stageRekey/settleRekey`), server/snippet deletion
tombstones (#84), independent secret timestamps, the `AppState._mutate` queue,
agent and ProxyJump transport (#131), editable themes (#128), KDF resource
ceilings, the 64 KiB unfinished-sequence cap (#49), window-state persistence
(#47), transactional record push/pull (#71), unknown-kind preservation (#58),
and everything in the completion ledger.

## Recommended sequence

Strategic order (sibling review): authenticated records and a durable ledger;
explicit trust reconciliation; recoverable account activation and lost-key
handling; bounded server lifecycle; measured terminal work; ergonomic
workflows. The tactical sequence below front-loads small data-loss and trust
fixes inside that order.

1. **Data-loss and trust quick wins (S effort):** APP-01 quit guard; CRED-04
   first PR (Android backup, no-mint); CRED-02 enrolment ordering; CRED-03
   key-check canary; APP-02 exception-safe tab close; AI-01 generator cancel
   (S4-13); SYNC-09 monotonic snippet stamps; SYNC-02 stamp-boost rejection
   (after Poltergeist's `keepLocalPin` fix).
2. **Land what is in flight:** TERM-05 search (#146), TERM-06 navigation
   (#145). SYNC-04's main fix merged in #140; its residuals remain.
3. **Sync foundations (M to L):** SYNC-03 slice 1 with SYNC-05 cursor recovery;
   exact acknowledgements; TRUST-01 host-key reconciliation; SYNC-01
   authenticated envelope and sealed tombstones; SYNC-06 token hashing; CRED-04
   recovery UI; CRED-05 credential-required state.
4. **Server operations:** SRV-02 lifecycle residuals, SRV-03 health on storage
   failure and drain, SRV-01 quotas and limiter.
5. **Terminal correctness and performance:** TERM-02 REP bound, PERF-02 style
   equality, TERM-03 reflow, TERM-04 pending input, SSH-01/SSH-02 deadlines and
   liveness; then the PERF-01 harness before any architectural change.
6. **Release hardening:** REL-01 workflow and toolchain pins, REL-02
   appimagetool, SSH-06 macOS sandbox decision before tagging the agent default
   (XAPP-02).
7. **Daily workflow and UI:** UI-02 tab overflow, UI-07 TOFU dialog and
   monospace, UI-06 accent contrast, UI-01 three-stage layout, WF-01 Planchette,
   WF-02 quick connect, TERM-08 disconnect recovery.

Independent UI fixes may run in parallel with protocol work.

## In review

Open PRs implementing entries below. Do not reimplement their slices; keep the
entry until the PR merges, then move it to the ledger with residuals kept as
entries. The sibling reviewer's PRs (#132, #133, #134) have all merged and are
in the [completion ledger](#completion-ledger); their review records are in
[Appendix: review records for #132 to #134](#appendix-review-records-for-132-to-134).

| PR | Entry | Scope |
|---|---|---|
| [#145](https://github.com/L-K-M/Seance/pull/145) | TERM-06 (SEA-025 navigation slice) | Tab shortcuts: close, select 1 to 9, next/previous and related navigation. SEA-008, SEA-009 and S4-16 stay open. |
| [#146](https://github.com/L-K-M/Seance/pull/146) | TERM-05 (SEA-023 search slice) | Terminal scrollback search. |

#140 (SYNC-04, S1-04) was listed as in review when this merge started; `git log`
shows it merged at `f5570dd`, so it is in the ledger.

---

## P0 and P1: trust, sync and credentials

### SYNC-01: Authenticate routing and conflict metadata; seal tombstones
**IDs:** SOL-011, SOL-012 (opaque IDs), SEA26-SEC-02, BOTH-REV-006, STATUS 16 ·
**Priority:** P0 · **Status:** Open

**Problem.** `packages/seance_protocol/lib/src/records/record_codec.dart:26-31`
seals only `{kind,data}`; `:44` treats `deleted` or an empty blob as a
tombstone with no authentication. `id`, `updatedAt`, `deviceId` and `deleted`
are plaintext envelope fields (`record.dart:81-110`). A breached server can
forge deletions (configs and snippets on every device) or replay old
ciphertext with winning metadata (SYNC-02 has the reproduced pin rollback).
Peers keep orphaned vault entries and unretracted pins because
`secret:`/`hostkey:` tombstones are deliberately never honoured
(`sync_coordinator.dart:519-606`). Wire IDs expose kind and hostnames
(`hostkey:host:port`, `models/host_key.dart:67`). Mitigations to keep:
apply-side payload-id equals envelope-id checks for config, host key, snippet
and secret (verified at `f5570dd`: `sync_coordinator.dart:621, 638, 661, 865`;
the deep-review draft listed only the first three). A cross-ID transplant is
therefore not assumed to succeed through those consumers; preserve the checks
while binding identity cryptographically at the codec boundary.

**Next.** Specify a versioned envelope v2 whose AEAD associated data binds
purpose, schema, key epoch, kind, id, client revision/time, device and deleted
flag. Encrypt typed tombstones; exclude the server-owned `seq`. Ship
compatibility readers and migration fixtures before changing writers: readers
accept v1 and v2; writers stay v1 until fixtures and interop tests exist. Derive
opaque wire IDs with a domain-separated keyed HMAC in the same migration, not a
second rewrite. This unblocks honouring `secret:`/`hostkey:`/assistant
tombstones.

**Gate.** Field-by-field tamper, transplant, replay and forged-tombstone tests;
old/new client interoperability (including Poltergeist's pin); interrupted
migration and rollback fixtures; external protocol review before GA.

### SYNC-02: Reject envelope stamps newer than the sealed payload (interim)
**IDs:** S1-02 (mitigation for SOL-011/AST-008) · **Priority:** P1 ·
**Status:** Open, ordered after a Poltergeist change

**Problem.** `sync_coordinator.dart:609-650` (config, host key) and `:653-671`
(snippet) never compare the payload's own stamp with the envelope's, although
secrets do (`:875-883`, `secret.updatedAt != dec.updatedAt`). Reproduced: a pin
published at `pinnedAt=10` (key OLD) and re-pinned at 20 (NEW); the server
re-serves the OLD blob with `updatedAt: 1<<50`; the device silently returns to
OLD, so a MITM holding the old key gets no warning. The same move reverts a
config's host/port or resurrects old snippet text.

**Next.** First, Poltergeist's `keepLocalPin`
(`poltergeist_core/lib/src/bookmarks/bookmark_coordinator.dart:475-499`) must
write a payload whose `pinnedAt` equals the envelope stamp. Then in
`applyToStores` skip (with a diagnostic) when envelope stamp > payload stamp
for serverConfig (`updatedAt`), hostKey (`pinnedAt`), snippet (`updatedAt`) and
assistantSettings (`updatedAt`). Reject only boosts. Every Séance writer
(`collectLocal`, `_revive`) already emits equal stamps.

**Gate.** In `sync_coordinator_test.dart`: the replay probe keeps NEW and lists
the id as skipped; same shape for config and snippet; an honest newer pin
applies. State the residuals in the PR: replay with the original stamp still
loses LWW (harmless); forged tombstones remain until SYNC-01.

### SYNC-03: Durable ledger, typed deletes and exact acknowledgements
**IDs:** SOL-001, SOL-005, SOL-006, SOL-010, SOL-037, SOL-059, SEA26-SEC-11,
STATUS 14, S1-10, #54 residual · **Priority:** P1 · **Status:** Partial

**Done (do not repeat):** server-config and snippet delete tombstones
(`FileTombstoneStore`, #84), republished each round and pruned on
confirmation; credentials versioned by `Secret.updatedAt` (`6f3d7f3`, #98,
#91); saves, deletes and all sync rounds serialized on `AppState._mutate`
(#73); push batching to advertised limits (#90, #92).

**Problem.** `app_services.dart:560` (@9322f6e) builds
`InMemoryLocalRecordStore()` per round, so every run pulls from seq 0 and
nothing persists origin, cursor or dirty operations. `markSynced(id, seq)`
ignores revision (`sync_engine.dart:122`), masked only because the queue blocks
edits during a round (assistant settings are edited outside it).
`collectLocal` re-encrypts every record with this device's `deviceId`
(`sync_coordinator.dart:150-157, 176-182, 222-228, 283-290`), re-attributing
unchanged peer records. No tombstone path exists for hostKey, secret,
assistantSettings or bookmark; the global credential opt-out does not
tombstone. Whole-collection JSON rewrite per `putServer`. No orphan
reconciliation for live sessions of remotely deleted configs. The queue is held
across network I/O (STATUS 14, `app_state.dart:1528-1545` at `dd7e105`).
S1-10 quantifies the cost: 100 servers with image marks make a ~34 MB pull per
run (every 5 min plus after edits); `http_sync_client.dart:157-163` applies a
30 s timeout to the whole body, so below about 9 Mbit/s sync always fails.

**Next (separate slices).**
1. Persistent, account-scoped `LocalRecordStore` (cursor, dirty set, origin
   `deviceId`/`updatedAt`, local revision counter); stop re-attributing
   unchanged records. Poltergeist's `PersistentLocalRecordStore` is a working
   reference that could be upstreamed together with SYNC-05.
2. Interim for S1-10: per-chunk idle timeout instead of whole-response.
3. Acknowledge only the exact sent revision; validate missing, duplicate and
   foreign ack IDs; report a pending/incomplete outcome after round exhaustion.
4. After SYNC-01: authenticated typed deletes (sealed tombstones for hostKey,
   secret and assistant settings); credential opt-out converges.
5. One batched domain apply transaction (one write per store). Fetch outside
   `_mutate`, then recheck and merge under it (STATUS 14), so slow successful
   network batches do not block every local edit.
6. Reconcile live sessions whose config was remotely deleted as explicit
   orphans.

**Gate.** Both devices restart after deletion without resurrection; unchanged
resync pushes nothing; blocked push plus edit remains dirty; blocked apply
cannot overwrite a domain edit; account switch isolates state; credential
opt-out converges; a 34 MB pull on a throttled link completes. Coordinate with
Poltergeist's exact-record settlement (its PG-REV-001) rather than changing the
shared interface without consumers and tests.

### SYNC-04: Refused-record residuals after #140
**IDs:** S1-04 residuals · **Priority:** P2 · **Status:** Open (main fix
merged in [#140](https://github.com/L-K-M/Seance/pull/140))

**Done (#140, verified at `f5570dd`):** a single-record 413 no longer aborts
the run. The engine sets the record aside, finishes, and throws
`SyncRecordsRefused` (an `ApiError` with the same `payload_too_large` code);
the coordinator applies what was pulled and prunes confirmed tombstones before
rethrowing with each record's kind and name; `AppState` refreshes its lists on
that failure; the sync status names the record (CHANGELOG). The record stays
dirty and is retried once it fits. Regression tests: `sync_test.dart`,
`sync_coordinator_test.dart`, `sync_refused_record_test.dart`.

**Problem (residuals).** No save-time size guard: a snippet larger than the
advertised `maxBlobBytes` can still be saved and is then refused every run. A
refused batch of several records (a server enforcing tighter limits than it
advertises) still ends the run where it happens; the batcher does not split it.
A refused record is re-sent once per engine run, so every sync re-uploads it.
Review notes on #140 also deferred: "Everything else synced." reads as success
for a run that exhausts `maxRounds` (pre-existing; SYNC-03 slice 3), and
broader two-pass coverage.

**Next.** A save-time snippet (and config image mark) size check derived from
the advertised `maxBlobBytes`; split a refused multi-record batch and retry the
halves; skip re-sending a refused record until its content changes. The
"account doctor" idea helps users find the offending record.

**Gate.** Saving an oversize snippet is refused with a clear message; a
multi-record 413 splits and applies the rest; an unchanged refused record is
not re-uploaded on the next run.

### SYNC-05: Signal and recover from server cursor regression
**IDs:** S1-03 (with the "rollback tripwire" idea) · **Priority:** P1 (latent
for Séance until SYNC-03 slice 1; live for Poltergeist today) · **Status:** Open

**Problem.** `sqlite_storage.dart` `deleteAccount` drops the `seqs` row, so a
re-created account restarts at seq 1; `_sync` (`server.dart:231` @9322f6e)
answers `since > latestSeq` with an empty list; `setHighWaterSeq` is monotone
(`local_record_store.dart:66-69`); `sync_engine.dart:63-93` never checks
`latestSeq < since`. Reproduced: after delete and re-register, a client at
cursor 5 never receives the three new records. A restored DB backup does the
same to every account. Poltergeist's `SyncCursorRejectedException` fallback is
dead code because nothing throws it.

**Next.** Server: `since > snapshot.latestSeq` returns `409 cursor_ahead`
(Séance's current client never sends that). Core: move
`SyncCursorRejectedException` into `seance_core` (keep a Poltergeist export);
`HttpSyncClient.pull` throws it on `cursor_ahead`; `SyncEngine._pullOnce`
resets the cursor and re-pulls from 0 on that exception or when
`resp.latestSeq < since` (old servers). Add
`LocalRecordStore.resetHighWaterSeq()`. Follow-up with SRV-02 schema
versioning: a random per-account epoch in `PullResponse`, rotated by restore
procedures.

**Gate.** Server 409 test; engine test (cursor 5 against latestSeq 3 re-pulls
and delivers); integration over real HTTP and SQLite with
delete/re-register/push.

### TRUST-01: Never silently re-trust synced host keys; serialize TOFU
**IDs:** AST-008, SOL-023, SEA26-SEC-03, SEA26-SEC-04, S2-14, issue #56 ·
**Priority:** P0 · **Status:** Open

**Problem.** `sync_coordinator.dart:650` (@9322f6e) still calls
`hostKeyStore.put(pin)` unconditionally (only id/locator equality and the
excluded-locator skip were added). `TofuVerifier.check/pin`
(`packages/seance_core/lib/src/hostkey/tofu.dart:44-67`) has no serialization
or compare-and-set, so a stale dialog can overwrite a newer decision.
`hostKeyLocator` is `'$host:$port'` without canonicalization
(`models/host_key.dart:112`). ProxyJump (#131) verifies each hop against its
own `host:port`, so pins for one name reached through different jump routes
collide (S2-14, table row only: re-trace). #56 is still open and is the
pin-trust gate for Poltergeist shared accounts.

**Next.** Route pulled pins through a `HostKeyReconciler` in core: the same
fingerprint keeps; no local pin adopts; a different fingerprint writes a
durable conflict record (both fingerprints), keeps the local pin and surfaces
it in the UI; resolution writes a new revision so the conflict cannot recur.
Canonicalize the locator (lowercase, strip trailing dot, IDNA, IP literals
including bracketed IPv6, port) before lookup, with a migration of existing
pins; decide whether route identity belongs
in the locator for S2-14. Add `pin(expected:)` CAS against the pin the dialog
showed, and serialize first approval per endpoint. Validate imported key
algorithm and encoding.

**Gate.** Matching/new/conflicting pins across two devices; concurrent first
connections; stale repin dialog; restart and user resolution; equivalent
endpoint spellings; jump-routed collision. Never replace silent overwrite with
a silent skip that reports success. Coordinate the public policy with
Poltergeist and with authenticated records (SYNC-01).

### CRED-01: Transactional credential editing
**IDs:** SOL-029, STATUS 17, 18, 19, 21 · **Priority:** P1 · **Status:** Partial

**Done:** referenced-key passphrase persisted with the stored PEM (#74); form
values snapshotted before the vault await; agent auth needs no secret (#131).
The old empty-key overwrite was fixed in #7.

**Problem** (`app/seance_app/lib/ui/server_editor.dart`, at `dd7e105`):
- a passphrase-only edit of a stored pasted key is ignored (`:85` returns null
  when the PEM box is blank);
- a method switch keeps a wrong-kind `secretRef` (`:52-60`, STATUS 18);
- one passphrase slot serves the pasted PEM and the referenced file
  (`:104-110`, STATUS 19), so switching back can leave the PEM undecryptable;
- a referenced key's passphrase cannot be cleared (STATUS 17; STATUS documents
  dartssh2 3.0.2 erroring on some key types and silently accepting PKCS#1);
- re-pasting a key with a blank passphrase box drops the stored passphrase
  (STATUS 21);
- obsolete credentials are not removed transactionally.
Retaining `secretRef` across modes preserves recovery options, but
keep/replace/remove is never explicit to the user.
STATUS argues 17/18/19/21 are one editor redesign; treat them as one entry.

**Next.** Show what is stored (a "passphrase stored" chip with Clear, a
kind-mismatch notice) and model keep/replace/clear per field for password,
stored key, referenced key and agent. Give the referenced-key passphrase its
own slot. Validate each mode. Save config and secret changes as one unit; delete obsolete
local/synced credentials only after a successful replacement. Prompt for
referenced-key passphrases without requiring storage. Mirror the rule in
`resolveCredentials`/`plannedCredential`.

**Gate.** Extend `planned_credential_test.dart`: every auth-mode transition,
passphrase-only edits, clear, re-paste with a blank box, unrelated config
edits, failed secret writes and cancelled dialogs preserve the intended
credential.

### CRED-02: Make sync enrolment one recoverable transition
**IDs:** SOL-030 residual, SEA26-SEC-08, BOTH-REV-005, S3-02, STATUS 4 ·
**Priority:** P0 · **Status:** Open (the re-key journal core is done: #95,
#98, #99, #100)

**Implemented foundation to preserve:** the complete vault, including orphaned
secrets, has a staged two-generation journal and keystore-directed settlement
(`FileVaultStore.stageRekey/settleRekey`, `vault_rekey_test.dart`).

**Problem.** `app_services.dart:450-454` (register) and `:504-508` (login)
(@9322f6e) save `syncBaseUrl`/username and the token before `_rekeyVault`. If
the re-key throws (`KeystoreException`, `VaultLockedException`, a pending
journal, a full disk), the UI shows "Failed" but sync is configured. The next
auto-sync (`_scheduleAutoSync` gates only on `isSyncConfigured`) seals every
record with the device-local key and pushes it; any device running `loginSync`
then fails if the first live record is one of those, including this device on
retry. The account stays poisoned until records are deleted server-side. A
round that captured `SecretVault(oldKey)` can also write old-key blobs into the
new generation after `settleRekey`, because enrolment does not run under
`_mutate`. Separately, entries the current key cannot open are carried
byte-for-byte forever with no UI (STATUS 4).

**Next.**
1. Reorder: derive keys, register/login (and verify), `_rekeyVault`, then the
   token, then settings. A failed re-key persists nothing.
2. Defence in depth: `AppSettings.syncKeyCheck` = base64
   HMAC-SHA256(vaultKey, `seance/v1/sync-key-check`), written after enrolment;
   `runSync` refuses before any request on mismatch. Migration: set it after a
   round where a pulled sealed record decrypted; refuse to push if records were
   pulled and none decrypted.
3. Route enrolment through a new `AppState.enrollSync` under `_mutate`.
4. Journal the whole account activation so a restart picks the old pair or the
   new pair, never a mix. No recovery material is shown before the destructive
   phase: coordinate with CRED-05.
5. STATUS 4: a UI to list and discard unreadable or orphaned vault entries.

**Gate.** Extend `sync_client_lifetime_test.dart` with
`_SelectiveKeystore(refuseMasterKey: true)`: after a failed register/login,
`isSyncConfigured` is false and the token null; `runSync` makes zero requests;
after swapping the stored master key `runSync` throws a key-mismatch error
before any push. Failure and restart at registration, settings, token, journal,
key write and vault promotion; orphaned credentials preserved; no upload under
the wrong key. Do not substitute "set up sync first" for recovery.

### CRED-03: Detect a wrong encryption passphrase on an empty account
**IDs:** S1-05, SEA26-SEC-08 (explicit key confirmation for empty accounts) · **Priority:** P1 · **Status:** Open

**Problem.** `loginSync` (`app_services.dart:488-503`) verifies the passphrase
by decrypting only the first live record; with zero records the key is
adopted. `registerSync` publishes nothing checkable. Two devices can then write
under different keys; shared IDs flip-flop and the devices diverge for good; a
third device with the correct passphrase can be refused when the first record
is a wrong-key one.

**Next.** A key-check canary without an enum change: `registerSync` pushes
`keycheck:v1` sealed as `{kind:'keyCheck', data:{}}` (it decodes as
`RecordKind.unknown` in every build, so all apply paths skip it and Poltergeist
switches do not break). `loginSync` checks it first and fails closed;
otherwise it checks every live record, reports a mixed-key account distinctly,
and pushes the canary if the account has none. The `KeyCheck` helper belongs
in `seance_core`.

**Gate.** App-service tests with the fake server: an empty account plus a wrong
passphrase on the second device is refused, so a wrong passphrase on an empty
account cannot seed incompatible record populations; the correct passphrase with a
canary is accepted; a mixed account reports "mixed", not "wrong passphrase".

### CRED-04: A missing keystore key is not a first run
**IDs:** SOL-031, SEA26-SEC-07, S3-04, X-10 (Séance half) · **Priority:** P0 ·
**Status:** Open

**Problem.** Locked-keystore errors already degrade safely; a genuinely
missing key is a different state that the code treats as a first run.
`secure_master_key.dart:94-109` `probeKeystore` mints a key after a null read
without checking existing `vault.json` ciphertext; `app_services.dart:166` (@9322f6e) calls it at bootstrap before
looking at `vault.json`. A non-minting `readKeystoreKey` exists (`:130`).
Concrete triggers (S3-04, LIKELY):
- Android: `AndroidManifest.xml` has no `allowBackup`, so Auto Backup restores
  `vault.json` and the plugin prefs without the Keystore key.
  `flutter_secure_storage` 10's `AndroidOptions.resetOnError` defaults to true:
  it wipes, returns null, and a new key is minted. Auto Backup also uploads
  `sftp-checkouts/`, `command_stats.json` and `identity_reads.jsonl`, and a
  cloned `settings.json` gives two devices one `deviceId` (this breaks the
  own-retraction logic at `sync_coordinator.dart:564,585`).
- Windows: `flutter_secure_storage_windows` 4.1.0 deletes its DPAPI store when
  decryption fails, returns `{}` on any read error and writes non-atomically,
  so a transient read error plus the mint replaces the whole store (the sync
  token and API keys are lost too).
- Concurrency: `unlockVaultFromKeystore` (`app_services.dart:242-265`) is not
  single-flight; two callers can mint two keys.

**Next (first PR).** Manifest `android:allowBackup="false"`,
`android:fullBackupContent="false"` and `android:dataExtractionRules`
excluding everything (API 31+); `AndroidOptions(resetOnError: false)`;
`probeKeystore(mayCreate:)` with `mayCreate: !(await vaultStore.hasEntries())`
(add `FileVaultStore.hasEntries`); a distinct "vault key missing" locked state;
single-flight unlock. **Then** the recovery/unlock UI (leave ciphertext
untouched), a README note ("reinstall and sign in to sync to move phones"),
and verification of iOS entitlements under signed builds. Do not add macOS
restricted keychain groups that break ad-hoc builds (AGENTS.md §3). Exclude
keystore-dependent data from incompatible backup restore and verify upgrade
data retention.

**Gate.** `MasterKeyManager` over a fake storage: a null read with
`mayCreate: false` writes nothing; `AppServices.initialize` with a non-empty
`vault.json` and an empty keystore starts locked with keystore and vault
untouched; two concurrent unlocks make one write and return the same key; a
Dart test parses the manifest for `allowBackup="false"`. Manual: signed Apple
relaunch/update, code-signing and container migration, keystore loss,
Android backup restore, empty first run. Never synthesize replacement keys over
encrypted data. Preserve the current keystore migration behaviour (and the
sandbox, unless SSH-06 decides to drop it).

### CRED-05: Missing credentials, recovery material and onboarding
**IDs:** SOL-035, workflow backlog · **Priority:** P1 · **Status:** Open

**Problem.** `app_services.dart:689` (@9322f6e) still falls back to
`SshCredentials.password(secret?.value ?? '')`, and `:723` to
`secret?.value ?? ''` for keys, so a synced local-only `secretRef` becomes an
empty credential on a new device with misleading auth errors. `RecoveryKey`
(`seance_protocol/lib/src/crypto/recovery_key.dart`) is unused by the app. No
app lock. Mitigation since: keyless servers default to agent (#131), which has
its own problems (SSH-06).

**Next.** Throw a typed `CredentialMissing` from `resolveCredentials` when
`secretRef` is set and the vault has no entry; the UI shows "Credential
required on this device" with unlock, prompt, key selection or agent. Then
encrypted offline export/import using `RecoveryKey` with canonical recovery
codes and verified restore, before promoting sync;
offer recovery enrolment when the first secret is saved; an optional biometric
or passcode app lock at the same boundary.

**Gate.** Two devices with and without credential opt-in; locked and missing
keys; export round-trip and tamper rejection; cancelled recovery; interrupted
import. Explain local SFTP plaintext retention separately from vault
guarantees.

### SYNC-06: Hash, expire and revoke bearer tokens
**IDs:** SOL-048, SEA26-SEC-05 · **Priority:** P0 · **Status:** Open

**Problem.** SQLite `tokens(token, username)` stores permanent plaintext bearer
tokens (`sqlite_storage.dart:45`); `DELETE /v1/account` (`server.dart:87`
@9322f6e) needs only the bearer; there are no logout, list or revoke routes. A
DB or backup leak grants live API access, contradicting the breach-tolerant
description.

**Next.** Store SHA-256(token) plus created/expires/last-used/device label and
bounded per-account sessions; `POST /v1/logout`, `GET /v1/devices`,
revoke-current and revoke-all; recent verifier re-auth for account deletion.
The migration rotates existing rows; correct the documented DB-leak model.

**Gate.** Raw DB tokens cannot authenticate; expired or revoked tokens fail;
concurrent revoke/login/delete cannot revive an account; the migration keeps no
live plaintext rows or backups without a retention warning.

### SYNC-07: Assistant-settings sync trust boundary
**IDs:** #76 follow-up (S5 new gap), #139 follow-up · **Priority:** P1 ·
**Status:** Open

**Problem.** Since #76 an opted-in peer can silently repoint the provider or
endpoint, so terminal context can go to a new endpoint without notice; STATUS
names "surfacing an adopted change of provider or endpoint" as a follow-up.
Rotated keys leave stale keystore entries (removals never travel); "stop
sharing the keys" needs a sealed tombstone (SYNC-01). From #139:
`includeTerminalContext` is device-local; decide whether to sync it next to
the redaction setting.

**Next.** On apply, when provider, base URL or model changes, hold the change
pending and show a one-time confirmation ("Assistant endpoint changed on
<device>"); until confirmed, keep the previous endpoint or disable sending.
Garbage-collect replaced keystore entries locally.

**Gate.** A pulled endpoint change sends no request to the new endpoint before
confirmation; a declined change is not re-prompted every round.

### SYNC-08: Exclude-from-sync residuals
**IDs:** #72 follow-ups (S5 new gap) · **Priority:** P2 · **Status:** Open

**Problem.** No "has ever synced" bit, so re-linking can retract unprompted
(`server_editor.dart:24-30`); a peer's later exclusion deletes a config this
device re-included (`sync_coordinator.dart:555-563`); pins pushed before
exclusion are withheld, never retracted (`:203-220`; needs SYNC-01).

**Next.** Persist a per-server `everSynced` flag; treat a peer exclusion as a
retraction only when it is newer than this device's re-inclusion revision.

**Gate.** Coordinator tests for re-link, peer exclusion after local
re-inclusion, and pin withholding.

### SYNC-09: Monotonic snippet (and re-pin) stamps
**IDs:** S1-08 · **Priority:** P2 · **Status:** Open

**Problem.** `ui/snippets_pane.dart:377-387` stamps edits with raw `now`;
`AppState.saveSnippet` (`app_state.dart:1465` @9322f6e) does not clamp. After
adopting a snippet from a peer whose clock runs ahead, a local edit loses LWW
and `putSnippet(remote)` (`sync_coordinator.dart:671`) silently reverts it.
Contrast `nextUpdatedAt` (`server_editor.dart:158-159`), `putLocalSecret` and
`_deletionStamp`. Re-pin at `ssh_session.dart:125`
(`pinnedAt: DateTime.now()`) has the same shape: fail-safe but confusing, as
the old pin returns and blocks.

**Next.** Clamp centrally in `saveSnippet`:
`updatedAt = max(snippet.updatedAt, existing.updatedAt + 1)`; consider the
same for re-pin.

**Gate.** Saving an edit to a snippet whose stored `updatedAt` is
`now + 60000` stores a larger stamp.

### SYNC-10: Idle sync reports own echoes and spends two rounds
**IDs:** S1-12 · **Priority:** P3 · **Status:** Open

**Problem.** `sync_engine.dart:78,87` counts `applied++` when the remote copy
of this device's own record wins the seq tie; idle runs report "pulled 5" in
Settings (`settings_screen.dart:1352`) and always take two rounds (reproduced).

**Next.** In `_pullOnce`, when `updatedAt` and `deviceId` match, still
`putRemote` (clear dirty, adopt seq) but do not count it as applied; update the
loop's break-condition test. Pairs with the "echo-free cursor advance" idea.

**Gate.** Probe: idle runs 1 and 2 report `pulled=0 rounds=1`.

---

## P1 and P2: protocol, crypto and local storage

### PROTO-01: Strict wire parsing and deterministic revisions
**IDs:** SOL-008, SOL-009, SOL-013, S1-13 · **Priority:** P1 · **Status:** Open

**Problem.** Missing fields default into acceptance, and numeric truncation
and weak range checks remain outside the now-strict KDF parser.
`record.dart:155-163` is lenient (`(as num).toInt()` truncation,
`deleted ?? false`, `blob ?? ''`); DTOs default a missing `protocolVersion` to
current (`sync/dtos.dart:34-35, 83-84`). The LWW tie falls back to a
client-supplied `seq` (`records/lww.dart:23-26`) and the server resolves with
`incoming.seq` (`storage.dart:136-137`, `sqlite_storage.dart:138-139`), so
exact LWW ties are not a deterministic total order and clients can supply
server-owned sequence values.
Reproduced: a forged `seq: 1<<40` tie push wins (S1-13; not part of #136). The
engine does not check one ack per id (`sync_engine.dart:119-129`);
`SyncOutcome` has no pending state. The only new strictness is
`PushLimits.tryFromJson`. Unknown-kind preservation (#58) is done; do not
reintroduce kind guessing.

**Next.** Quick win: `_push` rebuilds each incoming record with `seq: null`
before storage (one-line test). Then strict `EncryptedRecord.fromJson` (typed
errors, int-only, required fields, length bounds, nonnegative ranges and
canonical envelope combinations), a version policy with typed parse errors,
preserved or quarantined unknown future data with visible skipped outcomes, and
an authenticated operation ID/counter/HLC for total order (with SYNC-01);
`seq` is only a server delta cursor. One acknowledgement per submitted ID,
rejecting duplicates and unknown IDs, is SYNC-03 slice 3. Opaque wire IDs
(SOL-012) ride the SYNC-01 migration.

**Gate.** Parser fuzz/property tests; LWW commutative, associative and
idempotent; exact ties, same-millisecond edits, clock rollback; missing
acknowledgements; unknown kinds across old and new clients; migration
interoperability.

### PROTO-02: Remaining KDF, identity and crypto assurance
**IDs:** SOL-014, SOL-016, SOL-017, SOL-018, S1-11 (client half), S2-20, #136
username follow-ups · **Priority:** P1 · **Status:** Partial

**Done:** AST-001 bounds KDF resources, requires integer JSON and a 32-byte
output, and validates direct derivation; defaults are unchanged. The app
strength floor is separate from resource validity. #136 added server-side salt
(16 B) and verifier (32 B) shape checks and username validation including
invisible characters.

**Problem.** The client still runs `base64.decode(pre.argonSalt)` with no
length check (`app_services.dart:474-480`), so a malicious server can hand
every user one fixed or empty salt and amortize a dictionary attack. Only a
recovery-code KAT exists (`seance_protocol/test/crypto_test.dart:108`); there
are no Argon2id, HKDF-domain, verifier-hash or XChaCha20-Poly1305 vectors. No
NFC/NFD policy for passphrases; case-variant usernames (`Alice`/`alice`) remain
distinct accounts and need a versioned normalization policy.
`SecretVault.getSecret(id)` does not check the decrypted secret's id (S2-20,
table row only: re-trace).

**Next.** The client refuses a prelogin salt that is not exactly 16 bytes. Add
independent vectors including production factors. Define Unicode and case
policy only in a versioned format with migration fixtures (registration-time
case fold; existing accounts are not renamed). Verify decrypted secret
identity, defensively copy key/blob storage, minimize root-key retention.
Profile the KDF on a midrange phone (the 64 MiB/10-iteration/4-lane ceilings
are safety limits, not a latency promise). Unsupported old factors are
rejected, never clamped or hand-edited into a different key.

**Gate.** A malicious prelogin fails before allocation; vectors match; NFC/NFD
is documented and tested without breaking existing accounts; external crypto
and protocol review before sync GA. Unsupported factors alone cannot prove
whether the endpoint is malicious or an account is legacy.

### STORE-01: Persistence failure paths and transactional client storage
**IDs:** SOL-034, SEA26-SEC-09, SEA26-SEC-10, BOTH-REV-003, S3-08, S3-13 ·
**Priority:** P1 · **Status:** Partial

**Done (#91, #100):** per-path in-process write queue
(`services/atomic_file.dart:31-52`); a POSIX rename failure keeps the
destination; owner-only option; the journal read separates I/O from damage.

**Problem.**
- The Windows fallback (`atomic_file.dart:66-75`) deletes the destination and
  then renames. If the destination is held with `FILE_SHARE_DELETE`
  (antivirus, indexer), only `*.tmp` survives and nothing reads `.tmp`. Next
  launch: an empty vault (empty-password connects), default settings with a
  new `deviceId` and no recovery notice, a missing managed index. The next
  write truncates the `.tmp`.
- `quarantineCorruptFile` (`:81-89`) deletes an existing `.corrupt` first.
- Loaders quarantine on any exception, including read I/O
  (`file_stores.dart:22-38, 297-315`; `app_settings.dart:513-547`). A vault
  reset shows no notice. `SettingsStore.load` salvages defaults when the read
  (not the parse) fails and then overwrites the original.
- The fixed `<file>.tmp` name is unsafe across processes; no directory fsync.
  Multiple processes and symlink aliases of one path are not coordinated
  (STORE-02 covers the process lock, acquired before cache load).
- S3-13: four JSON stores set `_loaded` after awaits (a first-load race that
  `FileVaultStore` already fixed at `:277-295`), and `putServer`,
  `deleteServer`, `putSnippet`, `add` and `put` mutate `_cache` before
  `_flush` with no restore, so a failed save is later committed or pushed.

**Next.** Windows: retry the rename with backoff (about 5 tries, 20 to
200 ms), then `file -> file.bak`, `tmp -> file`, delete `.bak`; never delete
the only copy. `recoverInterruptedWrite(File)` restores from `.bak`/`.tmp` in
each `_load`. Timestamped quarantine names; keep the newest 5. Read outside the
`try`; quarantine only decode/shape errors; let `FileSystemException` propagate
so the store retries later. An `AppServices.vaultWasRecovered` notice. A shared
`_JsonMapStore<T>` with memoized `_loading` and snapshot/restore on a failed
flush. Unique temp names. Prefer transactional client storage for cross-file
invariants later. Keep the write queue and the settings device-ID salvage.

**Gate.** `atomic_file_test.dart` with `IOOverrides`: rename throws once then
succeeds (no destination deleted); a missing file plus `.tmp` recovers; two
corrupt events keep both copies; a read `FileSystemException` does not
quarantine; a failed write leaves `getServer` returning the old value. Injected
read/stat/rename/write failures, permissions, same-path and cross-process
races, crash at each replacement stage, disk full, malformed UTF-8/JSON and
partial-valid documents. Good state is never quarantined for a temporary
failure; the original or a recoverable replacement survives. Port the fixes to
Poltergeist (its atomic-file helper has already diverged, BOTH-REV-012).

### STORE-02: Single-instance guard on Linux and Windows
**IDs:** S3-09, X-09, SOL-034 (multi-process) · **Priority:** P1 ·
**Status:** Open

**Problem.** `linux/runner/my_application.cc:131` uses
`G_APPLICATION_NON_UNIQUE`; the Windows runner has no mutex. Every store
caches and writes whole snapshots, so two instances drop each other's changes
(servers, known hosts, tombstones, managed index, `vault.json`). A re-key in
one instance while the other holds the old key can leave an unopenable vault.

**Next.** Linux: `G_APPLICATION_DEFAULT_FLAGS` so a relaunch activates the
first instance. Windows: a named mutex plus `FindWindow`/`SetForegroundWindow`.
Dart backstop early in `main()` (before `restoreAndTrack`): an exclusive
`RandomAccessFile.lock` on `<appSupport>/.instance.lock`, showing "already
running" otherwise; the settings-window engine returns before this code.

**Gate.** Unit test of `InstanceLock.acquire(dir)` where a second acquire in a
spawned process fails (fcntl locks are per process). Manual relaunch on Linux
and Windows focuses the existing window.

---

## Server operations

### SRV-01: Quotas, snapshots, pagination and abuse controls
**IDs:** SOL-049, SOL-050, SOL-002/SOL-007 residual, S1-10 (server half), #136
follow-ups, SEA26-SEC-16 · **Priority:** P1 · **Status:** Partial

**Done:** request/batch/blob caps, validated configured limits, advertised blob
cap (#90, #92); #136 small auth-route body cap, `BytesBuilder` reads, username
validation before the limiter, typed 400 for a non-string prelogin username.

**Problem.** No account, token, record, blob or total-byte quotas, so accounts
can accumulate unbounded blobs and tokens. A full
snapshot per pull (`server.dart:231-232` @9322f6e; `sqlite_storage.dart:153-161`
materializes every blob, about 4x the account size per concurrent pull).
Limiter keys are size-capped, but distinct keys per window are still
unbounded; username-only limits enable lockout and do not protect prelogin or
registration. A chunked body over the cap is reset instead of answered 413.
Unknown users get `404 no_account` from prelogin (account enumeration; see the
"non-enumerating prelogin" idea). The sibling review's "reject malformed
prelogin username types as structured 4xx" residual is done (verified at
`f5570dd`, `server.dart:171` returns 400).

**Next.** Per-account record/byte quota with clear status codes; bounded
source-IP and account buckets, a trusted-proxy policy, prelogin/register
limits, `Retry-After`; shared or persistent limiter state if replicas are
supported; answer oversized chunked bodies with 413. Paginate against a defined
snapshot/revision contract, not a moving watermark (independent `seq <= W`
queries across requests are not one historical snapshot): test records
updated or deleted between pages and preserve eventual delta delivery.

**Gate.** Concurrent quota edges, large historical accounts, ID spray, targeted
lockout, proxy spoofing, restarts, exhausted pages; bounded memory and disk;
clear, actionable status codes.

### SRV-02: Account lifecycle transactions, schema and backups
**IDs:** SOL-051, SOL-054, S1-07 · **Priority:** P1 · **Status:** Partial

**Done:** atomic SQLite account deletion with rollback (#133); #71 contention
fails atomically with `503 storage_busy`; empty pushes stay read-only.

**Problem.** `pushRecords` never checks that the account exists; `_nextSeq`'s
upsert re-creates the `seqs` row; `createAccount` uses
`INSERT OR IGNORE INTO seqs` (`sqlite_storage.dart:100` @9322f6e), keeping a
stale value, and is not one transaction with its token; `usernameForToken`
(`:126`) does not join `accounts`. Reproduced (S1-07): a push racing deletion
(the token is resolved, then `_push` awaits the body) writes an orphan that a
same-name re-registration inherits with the old seq, which can make CRED-03's
check reject the correct passphrase. `_migrate` is `CREATE IF NOT EXISTS` only:
no `user_version`, foreign keys or checks. No documented WAL-aware backup and
restore.

**Next.** Inside the push write transaction run `SELECT 1 FROM accounts`; if
absent throw `AccountGoneException`, mapped to 401. Join accounts in
`usernameForToken`. Run `createAccount` in one transaction that clears leftover
`records/seqs/tokens` rows and creates the token. Mirror all of it in
`InMemoryStorage`. Then transactional `PRAGMA user_version` migrations with
foreign keys and cascades, bounded asynchronous contention retry (no long
synchronous `busy_timeout` that blocks the shared isolate; define retries,
backoff and `Retry-After`), documented synchronous/durability settings, and
documented WAL-safe online backup and restore (never copy only the main DB
file while ignoring active WAL state). Atomic create-or-conflict covers the
initial sequence and token; also cover delayed-login/delete races.

**Gate.** `storage_batch_test.dart` on both backends: token resolved, account
deleted, push throws 401; re-registration starts empty at seq 0; a deleted
account's token is 401. Concurrent registration/delete/login, orphans,
migration interruption, cross-process kill and lock recovery, disk full,
corruption, restore during writes. Two-connection contention and trigger
rollback tests do not prove power-loss or cross-process crash durability.

### SRV-03: Readiness, graceful drain and observability
**IDs:** SOL-052, SOL-053, SOL-055, S1-09 · **Priority:** P1 · **Status:** Open

**Problem.** `/healthz` (`server.dart:67` @9322f6e) never consults storage.
After one uncertain rollback `_failure` is set for good
(`sqlite_storage.dart:213`) and every request is 503 "restart required", yet
Compose's healthcheck stays green and `restart: unless-stopped` never fires
(S1-09). SIGTERM runs `close()` then `exit(0)` with no drain or DB close
(`bin/seance_sync_server.dart:62-67`). No request logging or counters; #71
added sanitized cleanup failure codes and fail-closed 503s, which is not
general observability. #48 already replaced the old `--help` healthcheck with
real HTTP health; do not redo it. `/healthz` is liveness only.

**Next.** Smallest first: `Storage.isAvailable`, and `/healthz` returns 503
when false (or schedule `exit(70)` so the restart policy reopens the DB). Then
a bounded SQLite-aware `/readyz` and an actual-container CI smoke test for
register/login/push/pull/persistence/restart; stop accepting on SIGTERM, drain with a
deadline, finish or roll back, checkpoint and close SQLite, handle repeated
signals. Request ID/route/status/duration/size logs, sanitized errors with
causal stack traces preserved when wrapping errors, structured diagnostics for
ordinary failures, auth/throttle/push/DB latency counters. Never log
authorization, verifiers, blobs, request bodies or raw commands.

**Gate.** A forced `_failure` makes `/healthz` 503; a live process with a broken
DB is not ready; SIGTERM during reads and writes; restart recovery; safe
structured errors; a container health failure is detected.

### SRV-04: Compose settings overridable without editing tracked files
**IDs:** S1-14 · **Priority:** P3 · **Status:** Open

**Problem.** `packages/seance_sync_server/docker-compose.yml:27` hard-codes
`SEANCE_OPEN_REGISTRATION: "false"` (and the limiter and cap variables); `.env`
only feeds `${}` interpolation, so enrolling requires a local diff that
collides with `./update.sh`'s `git pull --ff-only`.

**Next.** `"${SEANCE_OPEN_REGISTRATION:-false}"` and the same pattern for the
other variables; document them in `.env.example`.

**Gate.** `docker compose config` with an `.env` override shows the value.

---

## SSH, SFTP and terminal correctness

### SSH-01: Connection ownership, deadlines and cancellation
**IDs:** SOL-020, SOL-032, SOL-033, SEA26-SEC-12, S2-07 · **Priority:** P1 ·
**Status:** Open

**Problem.** Pre-socket key parsing, stale-result checks, idempotent engine
disposal, final-output drain, a 5-minute auth deadline and #131's per-hop
cleanup exist. But `ssh_session.dart:1205-1207` awaits `client.shell` without
a deadline; channel open and exec have no deadline, and dartssh2 never fails a
pending channel request on transport close (S2-07, table row only: re-trace).
The stale result is closed after the fact (`app_state.dart:1251-1255` at
`dd7e105`); there is no cancel API; the connecting view is a bare spinner
(`ui/terminal_pane.dart:1073-1075`); Test connection documents "no cancel
seam" (`server_editor.dart:261-262`).

**Next.** A `ConnectAttempt` handle (a cancel token closing socket, jump
parents, client, channels and engine per phase) in `openAuthenticatedClient`;
a shell/PTY deadline separate from interactive auth; fail pending channel
requests when the transport closes; dispose late-acquired channels; Cancel,
Retry and Copy log on the connecting view with precise phase and reason.

**Gate.** Stalled channel/PTY/shell/exec; cancel while TOFU or k-i dialogs are
open; immediate remote close; retry; stream errors; disposal; deleted or
replaced tabs retain no connection work; no leaked ownership, late session
commit or unhandled completion error.

### SSH-02: Keepalive cannot detect a dead peer
**IDs:** S2-08 · **Priority:** P2 · **Status:** Open (table row only: re-trace)

**Problem.** One unanswered keepalive ping stops keepalives for good, so a dead
peer is never detected. Core keepalive controls came in #77.

**Next.** Re-trace the keepalive code under `seance_core/lib/src/ssh/`. Count
consecutive unanswered pings, keep sending on the interval, and close the
session with a clear "connection lost" reason after N misses (OpenSSH
`ServerAliveCountMax` semantics).

**Gate.** A fake transport that stops answering: the session reports lost
after N intervals; an answering transport keeps pinging.

### SSH-03: Cancellation wrapper leaks a listener per chunk
**IDs:** S2-06 · **Priority:** P2 · **Status:** Open (table row only: re-trace)

**Problem.** `_cancelWhenRequested` adds a listener per 16 KiB chunk to a
never-completing future: about 500 MB per million chunks in JIT (benchmarked).
The code is shared by Poltergeist's bulk transfers.

**Next.** Register one listener per transfer, or remove the subscription on
completion.

**Gate.** A 100k-chunk transfer keeps the listener count constant (counting
fake) and memory flat in a benchmark; cancellation still works mid-transfer.

### SSH-04: Keyboard-interactive echo, cancel and keyboard flow
**IDs:** SOL-021, AST-002 residual, S4-21 · **Priority:** P2 · **Status:** Partial

**Done (#131):** typed `KeyboardInteractiveChallenge {server, prompts, name,
instruction}`; trusted endpoint separated from server text; private answers,
per-field reveal, keyboard privacy, IME scrolling.

**Problem.** The echo flag is dropped (`ssh_session.dart:661` maps only
`promptText`); cancel is still "empty list"
(`ui/keyboard_interactive_dialog.dart:5`); Enter neither submits nor advances,
and the reveal button is in the Tab order (`:106-127`).

**Next.** `List<bool> echo` and an explicit `KeyboardInteractiveCancelled`
result (keep callback compatibility); `textInputAction: last ? done : next`;
`onSubmitted` advancing or submitting; the reveal button with `skipTraversal`.
Verify Next/Done traversal and intentional password/OTP autofill without
guessing from remote text.

**Gate.** Enter submits a single prompt; with two prompts the first Enter moves
focus; cancel is distinct from an empty valid challenge; echo and no-echo;
multiple rounds; prompt count and order; small screens; native composition,
reveal, selection and focus; hardware and software keyboards. A server echo
flag is not proof an answer is non-sensitive.

### SSH-05: ssh_config import parity
**IDs:** SOL-022, SEA-007, SEA-027, S2-10, S4-26, ProxyJump import (S5 gap),
`importSshConfig` outside `_mutate` · **Priority:** P2 · **Status:** Open

**Problem.** Paste-only dialog without preview or dedupe
(`ui/server_list_pane.dart:788-823`); a fresh UUID per import; the last value
wins (`ssh_config_import.dart:69`; OpenSSH is first-wins); wildcard defaults are
dropped (`:74-79`); naive quote and comment stripping (`:94-97, 112`); no
Include; `ProxyJump` is parsed (`:87`) but not mapped to `jumpHostId`; an empty
username is kept. S2-10 (table row only): `Key = value` imports `= host` as the
hostname, and `%h` is not expanded. S4-26: the dialog's `TextEditingController`
is never disposed. `importSshConfig` (`app_state.dart:1155` @9322f6e) writes
the store outside `_mutate` (harmless today, but it breaks the queue's
invariant). Keyless hosts import as agent (#131; see SSH-06).

**Next.** A tokenizer with quotes, comments and `=` separators; first value
wins; evaluate every concrete alias of a block against matching `Host *`
defaults; handle multiple identities; Include with a loop guard;
`%h` expansion; ProxyJump mapped to a saved host; unresolved auth marked
setup-required. An `_ImportSshConfigDialog` StatefulWidget owning its
controller, with file Browse and "Read ~/.ssh/config" on desktop, a preview
with unsupported-directive warnings and host/port/user dedupe; run under
`_mutate`. Consider `ssh -G` behind an evaluator interface on desktop.

**Gate.** Idempotent repeated imports; wildcard, multi-alias and repeated
blocks; quotes; `Key = value`; Include loops; ProxyJump mapping; sandbox file
grants. No directive executes local commands during preview.

### SSH-06: Agent default, agent reachability and the macOS sandbox
**IDs:** X-06, L-02, S2-16, X-04 (Séance side) · **Priority:** P1 (macOS) ·
**Status:** Open

**Problem.** New servers default to ssh-agent (`server_editor.dart:287`) and
keyless imported hosts become agent (`ssh_config_import.dart:35`), even with no
agent (live run, L-02); mobile has no agent at all. Séance's macOS build is
App-Sandboxed (`macos/Runner/Release.entitlements`; the only exception is
read-only `~/.ssh`), and the sandbox very likely blocks connecting to
`$SSH_AUTH_SOCK` (launchd's `/private/tmp/com.apple.launchd.*/Listeners`,
1Password and Secretive group containers) (X-06, LIKELY: verify on a Mac).
There is no key selection, so agents holding many keys hit `MaxAuthTries`
(S2-16, table row only). The macOS sandbox migration PR #45 never landed. Once
tagged, the agent default also breaks Poltergeist on its v0.9.1 pin (X-04; see
XAPP-02).

**Next.** Verify on macOS. Decide: drop App Sandbox for the direct-distribution
build (Poltergeist ships unsandboxed; the sandbox already costs the `~/.ssh`
exception, bookmarks and the `$HOME` rewrite) or add and test exceptions. Map
EPERM to "The macOS sandbox blocks the ssh-agent socket". Default to agent only
when one is reachable (`SSH_AUTH_SOCK` set and the socket exists, or the
Windows pipe exists); otherwise Password; never on mobile. Add per-server
identity selection (like `IdentitiesOnly`) for agents.

**Gate.** The editor default under each condition (fake reachability probe); a
signed macOS build connects through the launchd agent and 1Password; a many-key
agent connects with the chosen key.

### SSH-07: Agents, jump hosts, forwards and key management
**IDs:** SOL-028, S2-22, X-14 (Séance), ProxyJump editor gap (S5) ·
**Priority:** P2 · **Status:** Partial

**Done (#131):** Unix and Windows agent clients (`ssh/ssh_agent.dart`);
saved-host jump chains with per-hop TOFU, auth, keepalive and cleanup.

**Problem.** No editor UI for `jumpHostId` (`server_editor.dart:919-920` "not
exposed yet"; the route is preserved on save). No port forwarding. No
known_hosts import/export (`HostKey.fromPublicKey` is unused), no key
generation or public-key deployment. The Windows agent was never exercised at
runtime, and real agents including password-manager integrations were not
validated. Poltergeist's older pin still needs an audited adoption (XAPP-02).
dartssh2 3.0.2 defaults include dh-group1-sha1, hmac-md5,
ssh-rsa/SHA-1 and CBC, with no strict-KEX (Terrapin) support (S2-22, table row
only: re-trace against the pinned source). Dependabot covers github-actions and
gradle only (not pub), and its gradle entry points at `/`, where no Gradle files
exist (X-14).

**Next.** A "Connect via" saved-host picker (cycle-checked) and alias/import
parity (SSH-05); explicit capability errors; then known_hosts import/export and
fingerprint aids; then forwarding UI for local, remote and dynamic tunnels with
explicit bind addresses; per-device key generation and public-key deployment
as a separate slice. Validate real agents, including password-manager
integrations and Windows named pipes. Restrict default
algorithms to modern sets with an explicit per-host legacy opt-in; track
strict-KEX upstream. Dependabot: add `pub` for the workspace and the app;
point gradle at `/app/seance_app/android`.

**Gate.** A real sshd matrix (agent cancellation and unavailability, every-hop
TOFU, jump failure cleanup, explicit forwarding bind addresses and lifecycle,
legacy-algorithm refusal). Verify strict-KEX/Terrapin behaviour and dependency
advisories against primary evidence. Preserve SFTP cancellation conformance (dartssh2 3.0.2, #59) on upgrades.

### SSH-08: Honest reachability probes
**IDs:** SOL-024, S2-18, "polite probing" idea · **Priority:** P2 ·
**Status:** Open

**Problem.** `TcpBannerProber`
(`seance_core/lib/src/probe/probe_service.dart:22-56` @9322f6e) documents that
"a banner starting with `SSH-` confirms online" but never checks it: any
completed connect is online (including a banner timeout), and every
`SocketException` (refusal, DNS, routing) is offline. Servers with a
`jumpHostId` are probed directly (`updateServers`, `:182`), leaking a direct
connection attempt and showing a wrong status (S2-18). Done: bounded
concurrency, connected-host skipping, disposal guards (#36), sweep
serialization (`4a50782`).

**Next.** Read up to 255 bytes for an `SSH-` line; ECONNREFUSED is offline,
DNS/unreachable/timeout is unknown; jump-routed servers report unknown (or are
probed through the route later); per-host opt-out. Preserve background pause,
staggering and the active-session bypass. Optional: per-host
exponential backoff for offline hosts with "last checked" in the tooltip.

**Gate.** Loopback services returning SSH, HTTP, silence, split banners,
pre-banner lines and malformed or oversized data; a jump-routed host is never
dialed; disposal and background transitions neither publish late state nor
restart timers.

### SSH-09: Remote git probe hardening and porcelain parsing
**IDs:** S2-05, S2-04, #137 follow-up · **Priority:** P2 · **Status:** Open

**Done (#137):** dialect-neutral `quoteShellWord` for the git probe and the
staged `cd` (fish-safe); control-character guard on OSC 7 directories.

**Problem.**
- The probe is still parsed by the login shell (`remote_git.dart:214`
  @9322f6e); fish before 4 cannot parse `{ }` groups and csh differs.
- S2-05 (table row only): the background probe honours the repository's
  `core.fsmonitor` (a repo-configured command runs) and takes optional index
  locks.
- S2-04 (table row only, VERIFIED with git 2.43): porcelain v2 `-z` headers
  are NUL-terminated, so branch, upstream, ahead/behind and stash are dropped
  on every git >= 2.17; the test fixtures use LF-terminated headers.

**Next.** `client.execute('sh -s')` with the script written to stdin; pass
`-c core.fsmonitor= -c core.untrackedCache=false` and `GIT_OPTIONAL_LOCKS=0`;
split `-z` header records on NUL; replace fixtures with captured real output.

**Gate.** A fixture from real `git status --porcelain=v2 -z --branch
--show-stash` yields branch, upstream, ahead/behind and stash; a repo with a
hostile `core.fsmonitor` does not run it (side-effect file absent); the probe
works with fish 3 and csh as the login shell (skip when absent).

### SSH-10: Upload replace residuals
**IDs:** S2-09, #138 follow-ups · **Priority:** P2 · **Status:** Partial

**Done (#138):** replace refused over symlinks, FIFOs, devices and folders (up
front); permission bits masked (`& 0xFFF`); staging owner-only when the final
mode withholds read or write.

**Problem.** The temp file is readable before `fsetstat` lands (dartssh2's open
takes no attrs); uid/gid are not preserved on replace; a kept setuid/setgid bit
moves to the uploader's identity; a symlink planted between the second
preflight and the rename is not detected (SFTP has no compare-and-rename).
Poltergeist re-pin note: #138 adds one `fsetstat` per upload for non-0666
modes, and Poltergeist's fakes may need `setStat`.

**Next.** Open the temp file with restrictive attrs where the server honours
them, otherwise create and chmod before writing any bytes; drop setuid/setgid
when the owner would differ (like `cp -p`); attempt `fchown` to the original
uid/gid and report when refused; document the remaining TOCTOU honestly
(hash-before-rename is not a lock).

**Gate.** Upload CAS tests: no data written before the mode is set; setuid
dropped on owner change; ownership preserved when permitted.

### SSH-11: SFTP robustness and throughput
**IDs:** S2-15, S2-19, S2-21 · **Priority:** P2 (S2-15), P3 (others) ·
**Status:** Open (table rows only: re-trace)

**Problem.** Upload throughput is capped at one local chunk per round trip
(S2-15). SFTP listings do not validate server-supplied names containing `/`,
`..` or NUL (S2-19). A dead SFTP subsystem is cached for the session's life and
`openRemoteFileSystem` throws synchronously (S2-21).

**Next.** Pipeline uploads with a bounded number of outstanding writes
(measure first against a real sshd with latency); reject or escape invalid
names at the listing boundary; drop the cached subsystem on channel close and
return a failed Future instead of throwing.

**Gate.** A throughput benchmark at 50 ms RTT before and after; a listing with
hostile names never yields a path outside the directory; reopening after
subsystem death works.

### SSH-12: Host-key algorithm preference ignores the pinned type
**IDs:** S2-17 · **Priority:** P3 · **Status:** Open (table row only: re-trace)

**Problem.** The negotiated host-key algorithm does not prefer the pinned
key's type, so a server offering several key types can present a different
one and raise a false "HOST KEY CHANGED".

**Next.** When a pin exists, put its algorithm first in the host-key
preference list; the changed-key dialog names a type change (UI-07).

**Gate.** A server with ed25519 and ecdsa keys and an ecdsa pin: no
changed-key prompt.

### TERM-01: Runaway parser and backend conformance
**IDs:** AST-009, SOL-027 · **Priority:** P1 · **Status:** Partial

**Done (#49):** a 64 KiB cap on pending unfinished sequences
(`third_party/xterm/lib/src/core/escape/parser.dart:14, 55-77`). Do not
describe the old unbounded queue as current, or duplicate a fix based only on
an old PR reference.

**Problem.** Below the cap every write rolls back and re-parses the pending run
(`:70-72`), so cost is quadratic up to 64 KiB; an abandoned payload resumes as
text and control bytes inside it are interpreted (`:73-75`); no fuzz or
property tests; the app reaches past the seam (`ui/app_menus.dart:100`
`engine.terminal.paste`, `terminal_pane.dart:1097`).

**Next.** Benchmark chunked incomplete OSC/DCS/CSI; make parsing resumable
(keep parser state across writes) if the benchmark warrants it; decide and
test the recovery policy for abandoned payloads so recovery cannot reinterpret
controls hidden inside them; add chunk-boundary property tests; extend the
`TerminalEngine` seam for output, input, paste, selection and scrollback
before any backend swap (libghostty must pass the same gate).

**Gate.** Arbitrary chunking, malformed and unterminated sequences, fuzzing,
recovery, bounded time and memory; vim, htop, readline, alternate screen, Unicode, mouse
and resize conformance.

### TERM-02: Bound completed control-sequence work
**IDs:** AST-015 · **Priority:** P1 · **Status:** Open

**Problem.** `third_party/xterm/lib/src/terminal.dart:502`
`repeatPreviousCharacter` loops over an unchecked count: the 12-byte input
`X\x1b[10000000b` performs ten million cell writes (a bounded Linux
parser-only JIT probe took 364 ms; one million: 40 ms; 80x24 terminal, 10,000
retained rows). These are single samples, not frame-time measurements; larger
values were not executed. `6f3d7f3` only normalized zero to one. IL, DL, ICH, DCH, ECH, SU, SD and resize have the same shape. The #49 cap
does not cover this path.

**Next.** Specify supported numeric, count and size limits and recovery for
excessive work. Clamp REP to the remaining cells in the scroll region (or an
equivalent bounded bulk fill);
bound insert/delete/erase/scroll counts by screen size; audit numeric overflow;
preserve wrap and cursor semantics rather than an undocumented clamp; record
the patch in `PATCHES.md`.

**Gate.** Short complete adversarial sequences with a time bound, count
boundaries, chunked input, normal REP/wrap conformance, continued output and
bounded scheduling latency. Keep this distinct from the incomplete-sequence
fix (TERM-01); both are required before claiming malformed output cannot wedge
the terminal.

### TERM-03: Fork reflow pushes a half-filled screen into scrollback
**IDs:** S4-05 · **Priority:** P2 · **Status:** Open

**Problem.** `third_party/xterm/lib/src/core/buffer/buffer.dart:531-571`
(`resize`): seven lines at 80x24 resized to 44 columns give `scrollBack=5`
with 35 blank rows visible; with a long line below the prompt, narrowing
leaves the cursor one row below its prompt because `_cursorY` is not adjusted
for reflowed lines (both reproduced). It shows when dragging dividers, snapping
windows or rotating phones, and breaks `fzf --height` and zsh menus.

**Next.** Record the cursor line before reflow (an anchor or wrapped-row
count); after reflow, drop trailing blank rows below the cursor down to the new
height before anything becomes scrollback; set
`_cursorY = newCursorAbs - scrollBack`; keep the maxLines trim patch.

**Gate.** The two probes as expectations (`scrollBack == 0` with the first row
intact; the cursor row reads `prompt$`); a narrow-then-widen round trip; an
alternate-buffer no-op.

### TERM-04: Bounded, Unicode-safe pending-input hints
**IDs:** AST-010, SEA-006 · **Priority:** P2 · **Status:** Open

**Problem.** `services/xterm_engine.dart:278` `_trackPending` appends per rune
without a bound, ignores cursor and history edits, and removes one UTF-16 code
unit on backspace (quadratic on large pastes; malformed non-BMP text).
`_snippetTitle` (`app_state.dart:1924` @9322f6e) and `_shortError` (`:1856`)
truncate with `substring`.

**Next.** Cap at about 4 KiB, then mark unknown; delete by grapheme
(`characters`); invalidate on arrow and history keys; reuse the grapheme-safe
middle-ellipsis truncation for labels and errors. Pending text stays a hint,
never authoritative shell state or safe LLM context; do not guess a remote
cursor position from screen columns.

**Gate.** Emoji, combining and ZWJ edits; large pastes; cursor, history and
control keys; no-echo input; no malformed UTF-16, unbounded growth or
automatic cloud prefill.

### TERM-05: Terminal scrollback search
**IDs:** SEA-023 (search slice), S4-20, "search with scrollbar ticks" idea ·
**Priority:** P1 · **Status:** In review: [#146](https://github.com/L-K-M/Seance/pull/146)

**Problem.** No find in `_handleKeyEvent` (`terminal_pane.dart:1130-1208`); the
fork has only `TerminalController.highlight()` and theme slots. Fork theme
slots and a commented-out search test do not constitute an implementation. S4-20:
`_paintSelection` (`third_party/xterm/lib/src/ui/render.dart:729-747`) walks
every selected line per frame via a `sync*` generator from `begin.y`, and
search highlights hit the same loop.

**Scope.** Cmd-F / Ctrl-Shift-F, next/previous, case toggle, wrapped-line
matches, stable anchors during output and trim, highlights separate from
selection, an incremental bounded scan (about 500 lines per frame), Escape
restores terminal focus, readline Ctrl-F is never stolen. Add
`BufferRange.segmentsWithin(firstLine, lastLine)` for viewport-culled selection
and highlight painting if the branch does not.

**Gate.** Hits across wrapped lines; anchors survive trim; a counting
`BufferRange` shows at most one segment per visible line per paint. Follow-up
idea: hit ticks in an overview strip.

### TERM-06: Tab navigation and native-feeling shortcuts
**IDs:** SEA-025 (navigation slice), SEA-008, SEA-009, S4-14, S4-16 ·
**Priority:** P1 · **Status:** In review: [#145](https://github.com/L-K-M/Seance/pull/145) for
the shortcut slice; SEA-008, SEA-009 and S4-16 Open

**Done earlier:** focus the server filter (Opt-Cmd-F / Ctrl-Alt-F), new tab,
Settings shortcut (#123).

**Problem.** No close (Cmd-W / Ctrl-Shift-W), select 1-9, next/previous, clear
scrollback or shortcut help; the macOS `MainMenu.xib` has no Close item.
SEA-009: the managed-edit close guard lives in the UI handler
(`terminal_pane.dart:114-164`) while `AppState.closeTab` deletes local copies
unguarded; move it behind a `closeTab(..., confirm:)` service contract before
adding the shortcut (see APP-02). SEA-008/S4-14: `_SessionView.dispose`
(`terminal_pane.dart:1050-1058`) removes the focus listener before disposing,
so `setTerminalFocused(false)` is never sent and macOS Cmd-C/V/A stay routed to
a terminal that no longer exists. S4-16: `app_menus.dart:235-247` binds plain
Ctrl+T globally (stealing the macOS Emacs transpose in text fields), and
Ctrl+Shift+T does nothing outside the terminal.

**Next.** The guard contract first; then the shortcuts (preserve Ctrl-C
interrupt, Ctrl-A home, remote mouse reporting). S4-14: a static
`_reportedOwner`; report false on blur or dispose only if still the owner, so
an old view cannot clear a newer one. S4-16: Cmd-T on Apple platforms,
Ctrl+Shift+T elsewhere; drop plain Ctrl+T.

**Gate.** Mocked `seance/menu` channel: closing the focused last tab sends
`setTerminalFocused(false)`; disposing A after focusing B sends nothing.
Ctrl+T in a macOS TextField does not open a tab; Ctrl+Shift+T from the server
list does on Linux. The close shortcut goes through the guard. Test native Edit
menus.

### TERM-07: Command blocks, Draft Dock and safe injection
**IDs:** SEA-028, SOL-047, S2-03, multiline paste policy · **Priority:** P1 ·
**Status:** Open

**Problem.** `paste_to_prompt` and the command generator inject raw keystrokes
into whatever runs in the foreground (`chat_controller.dart:80-83, 227-234`;
`paste_sanitizer.dart:79-105`; sinks in `chat_sidebar.dart:77-85` and
`command_generator.dart:105` @9322f6e). "Paste but never run" holds only at a
shell prompt: in vim normal mode `ggdGZZ` wipes and saves a file without Enter
(S2-03; that entry was cut short, so re-trace the app sinks). Several
`paste_to_prompt` calls per turn are all staged. Clipboard paste is unguarded
(`app_menus.dart:96-102`).

**Next.** Gate injection on OSC 133 prompt state (`atPrompt`): outside a proven
empty prompt, stage into a local Draft Dock instead of the PTY. The Dock (one
backend-independent surface for AI, snippets and history) shows the exact
target and source, editable text, danger findings, final control/newline
validation and explicit handling of a nonempty prompt; it never silently
concatenates or submits. Then OSC 133 command blocks with Copy command/output,
Save snippet, reviewed Rerun and Explain. Multiline clipboard paste gets its
own preview policy that preserves bracketed paste and editor workflows.

**Gate.** Injection while an alternate-screen program runs goes to the Dock;
nonempty prompt; stale session; bracketed paste unchanged in vim and nano.

### TERM-08: Disconnect recovery ("Last words")
**IDs:** SEA-026 · **Priority:** P2 · **Status:** Open

**Problem.** Disconnected sessions render `_Disconnected`
(`terminal_pane.dart:1081` @9322f6e) instead of the retained scrollback;
reconnect is manual; the connection-failed view has no "Edit server" action.
Persisted edit placeholders are not session restoration.

**Next.** Render the retained `TerminalView` read-only with a reason, duration
and cwd banner plus Copy, Save, Reconnect and Edit server. Then opt-in
reconnect with bounded backoff and cancel after network changes, and opt-in
tab restoration with a target preview. tmux/Mosh persistence is a separate
feature, not a promise of TCP reconnect. Local-shell and process-restoration
policies remain separate.

**Gate.** Network flaps, background/resume, auth expiry, normal and error exit,
manual cancel, stale attempts; never replay a command or login script silently.

### TERM-09: Terminal display preferences and link affordance
**IDs:** S4-15, S4-24, SOL-064 (preferences), OSC 8 residual · **Priority:** P2
(S4-15), P3 (others) · **Status:** Open

**Problem.** The terminal passes no `textScaler`
(`terminal_pane.dart:1096-1114`), so the grid follows the OS text scale (about
22 columns on a 360 dp phone at 2x, while Settings still says 13 pt). The fork
shows a hand cursor over any link
(`third_party/xterm/lib/src/terminal_view.dart:356-363, 391`) although opening
needs Cmd/Ctrl or touch (`:423-429`). OSC 8 links (#103) have no keyboard
discovery or mobile gesture. There are no cursor shape/blink, scrollback length
(fixed `maxLines` 10000), bell, ligature, OSC 52 or remote-title settings.

**Next.** `textScaler: TextScaler.noScaling`; seed `terminalFontSize` from the
OS scale on first run (clamped), or add "Scale terminal with system text"
(default off); show the effective size. Click cursor and underline only while
the modifier is held, with a "Cmd-click to open" tooltip. Add cursor and
scrollback settings first; bell, ligature, OSC 52 and remote-title policies are
distinct features (titles must not impersonate trusted chrome).

**Gate.** `RenderTerminal.cellSize` at text scale 2 equals the 1.0 size; hover
without the modifier shows the text cursor.

### TERM-10: Mobile terminal interaction gate
**IDs:** SEA-023/025/028 mobile gate, STATUS 10 · **Priority:** P2 ·
**Status:** Open (validation)

Test on devices: touch handles, the copy toolbar, magnification, edge drag,
selection under output, external keyboards, iPad shortcuts, CJK and dead-key
IME, and floating or overlay keyboards covering the last row. Preserve the
implemented multi-click, shift, drag, trim and Option behaviour.

---

## Performance

### PERF-01: Reproducible latency harness, then measured changes
**IDs:** SOL-026, SOL-057, SOL-059, SEA-012, AST-012 · **Priority:** P2 ·
**Status:** Open

Risks, not measured regressions: packet-by-packet synchronous parsing and
rapid PTY resize compete with input; all servers' sessions stay mounted in an
`IndexedStack` (`terminal_pane.dart:287` @9322f6e), where hidden views retain
render and paragraph caches and take part in layout and resize; broad `AppState`
notifications rebuild chrome (the MaterialApp now rebuilds only on
`appearance`, #128; the old trace-line storm was fixed in #35); KDF, crypto,
whole-collection JSON writes, recursive SFTP scans and editor work share the UI
isolate (preserve the existing syntax memoization and highlight caps); SFTP and
keystrokes share one transport, and transfer throughput is not typing latency.
Only
`test/connect_perf_test.dart` exists.

**Next.** Record p50/p95 frame and keystroke latency, parser throughput and
peak RSS on a laptop and a midrange phone: captured ASCII/colour/Unicode,
`yes`, large files, full scrollback, unterminated controls, resize spam,
selection during output, 1/10/50 tabs, tab switches, concurrent upload and
cancel. Separate parser, layout, raster, transport and GC time; target 60 Hz
(16.7 ms frames), not an unmeasured claim. Then, one at a time and each
measured: bounded output queues and backpressure, coalesced and
duplicate-suppressed PTY resize, active-server plus LRU rendered views without discarding
session state, focused listenables, batched domain writes, off-isolate work,
glyph-run painting (idea). The initial PTY stays 80x24 until widget layout
(STATUS 8); negotiate the measured grid earlier only if the harness shows
visible redraw. Remote resize must never recurse into itself. The optional
connection flight recorder (AST-012, see Ideas) can expose
DNS/TCP/handshake/auth/shell versus parse/layout timings; keep its retention
bounded and its export previewable and redacted, with no keys, commands or raw
traces by default.

**Gate.** Harness numbers recorded in the PR for each change; no regression in
interactive interrupt latency or quick tab switches.

### PERF-02: Value-equal terminal styles (glyph cache flush)
**IDs:** S4-01 · **Priority:** P2 · **Status:** Open

**Problem.** Every `AppState` notification rebuilds every `_SessionView`;
`TerminalAppearance.resolve` returns a new `TerminalStyle` (and
`TerminalTheme`); the fork compares by identity
(`third_party/xterm/lib/src/ui/terminal_text_style.dart:26`,
`terminal_theme.dart`, `render.dart:97-112`), so each terminal re-measures,
clears its paragraph cache and relays out on every tab switch, 45 s probe sweep
and sync round (verified with a scratch test).

**Next.** `==`/`hashCode` on `TerminalStyle` (with `listEquals`) and on
`TerminalTheme` (all colours plus search slots), noted in `PATCHES.md`; memoize
`TerminalAppearance` in `_SessionViewState` keyed on font family, size,
palette, the theme's terminal block and brightness.

**Gate.** Fork: re-pumping an equal new style leaves `debugNeedsLayout ==
false`. App: the style is `==` across `focusTab`.

### PERF-03: Built-in editor gutter relayout per keystroke
**IDs:** S4-06, UI-10 (sibling review) · **Priority:** P2 · **Status:** Open

**Problem.** `built_in_text_editor.dart:472-503` `_ensureGutterLayout` keys its
cache on text identity, so each keystroke lays out a second `TextPainter` over
the whole span (up to 200k chars) and calls `getOffsetForCaret` per line: about
260 to 335 ms per keystroke for a 150 KB file in debug JIT. Byte/line recounts
and TextField layout remain after the syntax cutoff.

**Next.** A monospace fast path: if `maxLineChars * advanceWidth <=
textWidth`, tops are `i * lineHeight`; otherwise use the field's
`RenderEditable` for visible lines, or debounce precise layout to idle.
Benchmark giant lines too. Preserve BOM and line-ending fidelity and save
safety.

**Gate.** A `@visibleForTesting` counter: 20 keystrokes in a no-wrap 150 KB file
do 0 precise layouts; wrapped documents keep correct tops; the existing gutter
tests pass.

### PERF-04: Throttle transfer progress notifications
**IDs:** S3-17 · **Priority:** P3 · **Status:** Open

**Problem.** `remote_files_controller.dart:1084-1092` notifies per SFTP chunk
(`remote_file_system.dart:424-426, 549`); a 1 GB transfer rebuilds the Files
pane tens of thousands of times.

**Next.** Throttle to about 10 Hz with a `Stopwatch`; always notify on
completion or failure.

**Gate.** 1000 progress callbacks inside 10 ms produce at most 2
notifications.

### PERF-05: Network cancellation and response bounds
**IDs:** SOL-058, AST-006 residual, SEA26-SEC-15, STATUS 22 · **Priority:** P2 ·
**Status:** Open

**Problem.** Owned sync clients close after sync and enrolment, including on
failure; injected transports remain caller-owned. That is not general
cancellation. LLM and search
providers use `Future.timeout` wrappers and never close
(`llm/anthropic_provider.dart:101, 111, 138`; `openai_provider.dart:101, 113,
143`; `search.dart:34`); Z.AI (#75) is a fifth such client. No streamed body
limits or stream-idle deadlines.

**Next.** Ownership-aware `close()` on all providers, closing replaced
instances in `AppServices`; cancellable requests with connect, total and idle
deadlines and streamed body limits; reset, dialog dismissal, disposal and
timeout stop work instead of only completing a wrapper.

**Gate.** Stalled headers, body and SSE; oversized responses; disposal
mid-request; late replies; retry; no resource accumulation or stale UI/PTY
effects.

---

## Assistant

### AI-01: Session-local, bounded, cancellable conversation
**IDs:** SOL-038, SOL-041, SEA-017, SEA26-SEC-13, S4-13 · **Priority:** P1 ·
**Status:** Partial

**Done:** turn-only terminal context, originating-session guards against
stale staging, reset/dispose generation checks, paste target bound per send
(#91); a persisted "Include terminal output" opt-out (#139). Verified at
`f5570dd`: the narrow drawer's local `_includeContext = true` reset that the
sibling review reported is gone, and the chat sidebar and the command
generator both read and write the one persisted
`AppState.includeTerminalContext` (`chat_sidebar.dart:68, 188`;
`command_generator.dart:75, 187`).

**Problem.** One global `ChatSession` (`app_state.dart:477` @9322f6e);
unbounded history; non-streaming `chat()` with `SelectableText`; no Markdown,
Stop or Retry. S4-13 (still present @9322f6e): `command_generator.dart:105`
injects the reply after the await with no `mounted` or cancel check, and Esc or
the barrier still dismiss while busy, so a dismissed dialog types a command
into whatever the user is typing next (Enter then runs a spliced command);
`setState` at `:91, 110, 112` is unguarded.

**Next.** First S4-13: a `_closed` flag set in `dispose`; return before
`injectInput` when closed or unmounted; guard `setState`; optionally an
explicit Esc cancel via PopScope. Then key `ChatSession` by session id with an
explicit global mode, a byte/token budget with deterministic truncation,
`streamChat` with Stop and Retry, selectable Markdown/code staging, a visible
target,
a durable session-local context privacy choice, and real provider
cancellation (not only rejecting late results). Audit generator,
model-discovery and enrolment lifetimes independently instead of assuming the
chat guards cover them. (The deep-review draft suggested defaulting the
generator's context checkbox to the persisted preference; #139 already does
that.)

**Gate.** A fake provider behind a `Completer`: Esc, complete, the engine
received no input and no FlutterError. Switch hosts mid-turn; close and reopen
the drawer; 1000-turn bounded history; reset or dispose while blocked; provider
failure; malformed links. No unexpected cross-host history or context sharing
and no late PTY effects.

### AI-02: Native tools, exact outbound receipts and redaction grammar
**IDs:** SOL-042, SOL-044, SOL-045, SEA26-SEC-14, S2-11 · **Priority:** P1 ·
**Status:** Open (the quoted/static-word redaction slice landed in #132)

**Problem.** Native tool-call IDs are discarded; results become user strings
(`chat_controller.dart:240`). `ChatResult.sent` omits history and search
snippets and is never rendered. Brave is read from `settings.braveApiKeyRef`
(`app_services.dart:902` @9322f6e) with no settings UI. Search results are
untrusted content. Redaction grammar residuals: YAML tagged values and block
scalars; shell command substitutions and backticks; source-language
comparisons and Go `:=`; YAML plain scalars with shell-like quote prefixes
after `:`. For `password == "example words"`, `password := "example words"` and
`password: $'example words'` the current filter can leave the quoted text
visible, sometimes after masking only an operator or prefix. Static shell words
and adjacent recognized fields are covered by #132 and must not be implemented
again.
S2-11 (table row, written before #132 merged; re-check which still leak): URL
credentials, `-pPASS`, HTTP Basic auth and partial PEM blocks (JSON keys and
`*_SECRET_KEY` are probably covered by #132). An ad hoc operator exclusion is
unsafe: `password==secret` can be a valid shell assignment.

**Next.** Provider-neutral typed calls and results preserving IDs (Anthropic
`tool_use`/`tool_result`; OpenAI `tool_calls` and tool-role messages); keep the
bounded tool loop. Capture the complete serialized provider payload after
redaction, including history and searches, and show expandable receipts
(target, provider/endpoint/model, command blocks, redactions, queries and
results, token estimate, exact outbound text). Redact final outbound history,
tool results and model echoes, not only user input. Format-aware parsing for
the residual grammars, with serialized provider-request regressions, never
executing expressions while redacting; a conservative fallback for terminal
text that is not valid structured input; user-defined
patterns; label the filter best-effort. Add Brave to Settings or remove it. Add
provider connectivity and latency diagnostics. Native provider web search stays
a separate path.

**Gate.** Second-request wire fixtures for both providers; search-injection
fixtures; payload-to-receipt equality; credential URL, cookie, kubeconfig,
Basic auth and PEM examples through actual provider bodies.

### AI-03: Untrusted-context delimiters are static and spoofable
**IDs:** S2-12 · **Priority:** P2 · **Status:** Open (table row only: re-trace)

**Problem.** Terminal and search context is wrapped in fixed markers
(`<<<CONTEXT` / `CONTEXT>>>`, e.g. `command_generator.dart` near `:80`
@9322f6e) that terminal output can close and follow with instructions.

**Next.** Per-request random nonce delimiters, escaping any occurrence in the
content, plus a system instruction naming the nonce; prefer provider-native
structured content blocks where available.

**Gate.** Context containing the closing marker cannot end the block (unit test
on the built prompt).

### AI-04: Danger-linter bypasses
**IDs:** S2-13 · **Priority:** P2 · **Status:** Open (table row only: re-trace)

**Problem.** The independent danger linter misses `bash <(curl ...)`,
`sh -c "$(curl ...)"`, `| sudo -E bash`, quoted targets, `/dev/xvda` and
similar forms (verified by running the linter).

**Next.** Add rules with a table of positive and negative cases; normalize
quoting before matching. The review-before-run gate stays the real safety.

**Gate.** Table tests for each bypass and for safe look-alikes.

### AI-05: Shell-aware command capture and CommandStats learning
**IDs:** SOL-046, AST-007 residual, SEA-034, S3-10, STATUS 9 ·
**Priority:** P2 · **Status:** Open

**Problem.** `onCommand` fires on every Enter regardless of OSC 133 phase
(`xterm_engine.dart:315`; `atPrompt` gates only `activeCommand`). No whisper
mode or clear-history control; command length is unbounded (the count is
capped at 400, `command_stats.dart:38`). S3-10 (reproduced): once 400 commands
have count >= 2, a new command enters with count 1 and is evicted in the same
call, so learning freezes; `List.sort` is unstable, so ties drop arbitrarily.
Minor: the `Timer(..., services.saveCommandStats)` callback drops its Future
(an unhandled error on failure), and up to 3 s of stats are lost on quit
(`app_state.dart:1841-1847` at `dd7e105`). Done: recognizable secrets are
filtered before capture, legacy loading and save, independently of assistant
settings. Legacy cleanup is attempted on load; failed writes, unparseable files
and historical backups cannot be promised scrubbed, and arbitrary no-echo
passwords are not recognizable by regex.

**Next.** Record commands only at proven OSC 133 boundaries (`atPrompt`); bound
command lengths and counts, loaded data and dismissal storage without silently
breaking "never suggest again"; a recency-ordered
map evicting the lowest count, oldest first, never the command just recorded,
with optional decay on trim; await and log the save; "Clear command history"
and a visible whisper toggle excluding capture and outgoing context. Never
infer no-echo from channel bytes.

**Gate.** The S3-10 repro passes; password/OTP prompts, readline editing,
nested shells, alternate screens; settings-independent protection; safe
commands still rank. Explicitly warn that prior backups and plaintext history
may persist.

### AI-06: Safe context enrichment and search error typing
**IDs:** workflow backlog "Safe context enrichment", STATUS 15 ·
**Priority:** P2 (enrichment), P3 (STATUS 15) · **Status:** Open

**Problem.** OSC 7 cwd, OSC 133 D exit code and OSC 1337 shell kind exist
(`xterm_engine.dart:166-260`), but chat sends only `recentText(maxLines: 200)`
(`chat_sidebar.dart:69` @9322f6e). Search failures have no domain exception
type (STATUS 15).

**Next.** A labelled context header with cwd, shell and last exit ("unknown"
when not reported); prefer command blocks (TERM-07) over a blind last-N-lines
window. Add a typed search failure when a retry UI exists.

**Gate.** Header content with and without shell integration.

---

## App lifecycle and persistence

### APP-01: Quit guard for dirty editors and live sessions
**IDs:** S3-07, S4-08, "Close the circle?" idea, "draft ectoplasm" idea ·
**Priority:** P1 · **Status:** Open

**Problem.** `main.dart` registers no `AppLifecycleListener(onExitRequested:)`
(STATUS: "Séance registers no exit observer today"). Cmd-Q, or closing the
main window on Linux/Windows, drops unsaved built-in-editor buffers
(`EditorTab.dirty`; saves happen only on Cmd-S) and live sessions; closing a
tab does ask (`terminal_pane.dart:115-164`). The settings window already
forwards exit requests (`RemoteSettingsBackend.requestAppExit`); Poltergeist's
`app_session_lifecycle.dart`/`QuitGuard` is the template.

**Next.** A listener owned by `_BootstrapState` once `_state` exists. With no
dirty editors and no connected sessions return `exit`; otherwise show a dialog
on the root navigator ("Quit Séance? 2 files have unsaved changes; 3 sessions
are connected.") with Cancel and Quit, reusing `confirmDiscard` semantics.
Later: per-row actions and an "idle sessions only" preference; mobile draft
autosave on `paused` to an owner-only `.draft` sidecar (Android swipe-away has
no exit hook).

**Gate.** `test/quit_guard_test.dart`: a dirty `EditorTab` plus
`handleRequestAppExit()` (inside `runAsync`) shows the dialog and Cancel
returns `cancel`; a clean state returns `exit` with no dialog; one connected
session is named.

### APP-02: Exception-safe tab teardown and a service-level close guard
**IDs:** S3-06, SEA-009, "centralize destructive-close guards" ·
**Priority:** P1 · **Status:** Open

**Problem.** `_disposeSession` (`app_state.dart:1412` @9322f6e) awaits local
copy deletion before `log.freeze()`, `session.close()`, `engine.dispose()` and
`tab.dispose()`; `closeTab` (`:2149`) has already removed the tab and notifies
only after the await. A sharing violation (Windows), a disk-full index flush or
an unsafe-path throw leaks the SSH session for the process lifetime, leaves the
keep-alive count stale (the Android foreground service stays up) and skips the
active-tab fallback; `deleteServer` aborts the same way. The close guard lives
in the UI (TERM-06); editor tabs and the git sidebar raise the stakes.

**Next.** Local copy deletion inside try/catch collecting failures; disposal
in an always-run `finally`; the fallback, notify and keep-alive refresh in
`finally`; return a report ("N local copies could not be deleted and were
kept") shown as a notice. Move the guard into `closeTab(..., confirm:)`.

**Gate.** `app_state_mutation_test.dart`: a placeholder tab whose checkout
parent is a symlink (delete throws; skip on Windows); `closeTab` completes,
`tabs` is empty, the engine is disposed, listeners are notified.

### APP-03: Lifecycle mapping treats `inactive` as background
**IDs:** S3-05 · **Priority:** P2 · **Status:** Open

**Problem.** `main.dart:105-109` calls `setForeground(lifecycle == resumed)`.
On desktop `inactive` means "not focused but visible" (on Android it also
covers the notification shade and split screen). Every refocus runs an
immediate probe sweep of every server (`probe_service.dart:223-228, 241-243`)
and re-hashes all managed checkouts twice on the UI isolate
(`remote_files_controller.dart:1300-1312`, plus per-tab
`reconcileLocalCopies`); open editors re-stat. Switching windows every 10 s
multiplies sshd preauth log noise about 4.5x, and status dots go stale on a
visible second monitor.

**Next.** Ignore `inactive`; `hidden`/`paused`/`detached` pause; `resumed`
resumes; idempotent `setForeground` (`app_state.dart:1997` @9322f6e); one
`reconcileAll` per resume fanned out to tabs and controllers (skip where
directory watchers run); optionally `ProbeService.resume()` sweeps immediately
only if the last sweep is older than the interval.

**Gate.** Bootstrap widget test: `inactive` leaves `probe.isPaused == false`;
`hidden` pauses; `resumed` resumes once; a counting fake store sees one
`reconcileAll` per resume.

### APP-04: Managed checkout recovery residuals
**IDs:** S3-12, S3-11, S3-08 (index part), #141 follow-ups, "expose retained
plaintext edits", "recovered edits drawer" idea · **Priority:** P2 ·
**Status:** Partial

**Done (#141):** checkouts preserved across index loss or quarantine (sweep
inhibited); startup survives unreadable checkouts. Earlier: per-file "Discard
local copy"; the editor keeps 0600 and refuses symlinks. Still owed from the
Files backlog: expose retained plaintext edits, their storage and discard.

**Problem.** Preserved checkouts are not visible anywhere. Checkouts whose
server is gone are skipped at restore (`app_state.dart:2204-2205` at
`dd7e105`), keeping hidden plaintext and edits forever. A newer-version index
is still quarantined instead of opened read-only. A Windows `*.tmp` index left
by the delete-then-rename fallback is never read back (STORE-01). S3-11:
renaming onto a path with a retained local copy overwrites
`localCopies[target]`, and `ManagedRemoteFileStore.update` (`:148-162`) lacks
`put`'s duplicate check, so the old edits become invisible, leak on close and
block future checkouts of that path.

**Next.** A "Recovered edits" list (Settings > Files) of all checkouts not
attached to a live session, with sizes, Open, Reveal, Export, Upload to and
Discard, plus bulk discard; minimal slice: `AppState.orphanedManagedFiles`
feeding a one-time notice. Open a newer index read-only and disable
managed-edit writes with a clear error. `renameEntry` refuses when a local copy
holds the target ("upload or discard the local copy of b.txt first"); `update`
gets the duplicate check.

**Gate.** A seeded orphan for server `gone` is listed after `load()`; index v2
untouched and read-only; the rename is refused with remote and index unchanged.

### APP-05: Vault lock reason and platform-correct messages
**IDs:** S3-14 · **Priority:** P2 · **Status:** Open

**Problem.** A settle failure sets `vaultKey = null` but `keystoreStatus` stays
`available` (`app_services.dart:199-214`), so no notice appears
(`main.dart:153-155`), and every connect then advises installing gnome-keyring
(`secure_master_key.dart:22-25`), on every platform.

**Next.** An `AppServices.vaultLockReason` enum (`keystoreUnavailable`,
`rekeyPending`, `keyMissing` for CRED-04); a notice on any reason; reason- and
platform-specific `VaultLockedException` messages.

**Gate.** `keystore_resilience_test.dart` with an unreadable journal via
`IOOverrides`: locked with reason `rekeyPending` and a matching message.

### APP-06: Sync round bookkeeping drops queued auto-syncs
**IDs:** S3-16, TOFU-pin auto-sync (S3 minor) · **Priority:** P3 ·
**Status:** Open

**Problem.** `syncNow` sets and clears `syncing` but ignores `_syncQueued`, so
an edit made during a manual sync waits up to 5 minutes (or until next launch
on mobile); `syncNow` during an auto round clears `syncing` early
(`app_state.dart:1836-1847` @9322f6e). Pins written by `hostKeyStore.put` in
core never call `_scheduleAutoSync`.

**Next.** A `_roundsInFlight` counter; one `_runRound({surfaceErrors})` for both
entry points that re-runs once when anyone queued; schedule an auto-sync after
a new pin.

**Gate.** A fake client with a blocking pull: start `syncNow`, save a server,
advance 2 s; after completion a second push happens.

### APP-07: Settings window lifecycle and known limits
**IDs:** S3-15, #126 known limits · **Priority:** P3 · **Status:** Open

**Problem.** Closing the settings window before its `hello` leaves the host
believing it is visible (`services/settings_window.dart:188-201, 252-258`;
SPECULATIVE), so the next open sends `selectTab` to a stale page. Known
limits: Cmd-T/Cmd-K act on the main window while Settings is key; window size
and position are not remembered; closing discards unsaved field input,
including API keys; the macOS and Windows runners compile but were never run
(`docs/STATUS.md:309-317`).

**Next.** Track `_runnerShowing` (true on open, false on closed); `hello` sets
visibility from it and returns `{'hidden': true}`; persist geometry; warn on
close with unsaved fields.

**Gate.** `settings_window_test.dart`: `closed` before `hello`, then `open()`
receives `show`.

### APP-08: App data location and file permissions
**IDs:** S3-18 · **Priority:** P3 · **Status:** Open

**Problem.** `app_services.dart:157` uses `getApplicationSupportDirectory()`,
which is Roaming AppData on Windows, so plaintext `sftp-checkouts/`,
`command_stats.json` and `identity_reads.jsonl` roam with domain profiles. On
Linux, `servers.json` and `managed_remote_files.json` are written with the
umask mode. `remote_files_controller.dart:1319-1327` shells out to `chmod`.

**Next.** Caches and checkouts under `getApplicationCacheDirectory()` (Local
AppData) with a migration shim; `chmod 700` the app-support directory on Linux
or write all stores owner-only; use the `posix` package's `chmod`.

**Gate.** A migration test moves existing checkouts; created files are 0600 on
Linux.

### APP-09: Files pane follow-ups and device validation
**IDs:** Files backlog (docs/SFTP.md), STATUS 2, 11, 12, 13, UI-09 (sibling
review), Android keep-alive (#51) · **Priority:** P2 · **Status:** Open

Implemented, not to be re-added: SFTP, recursive transfers, durable local
edits, conflict-checked upload-back, POSIX metadata, chmod and symlinks,
sorting/filtering/bookmarks, Android export and the syntax/find/save-and-upload
editor. Remaining scope is in [docs/SFTP.md](docs/SFTP.md), not "add an SFTP
browser". Centralize destructive-close guards (APP-02) before adding shortcuts
or swipe-close.

- Widget tests for `files_pane` with picker and opener fakes (none today).
- Keyboard and accessibility pass: arrow, Enter and Delete in the list
  (`docs/SFTP.md:196`).
- Copy/move, drop onto folder rows, persisted sort/filter per server (the
  smallest slice) (`docs/SFTP.md:185-194`).
- Resumable/queued background transfers, an optional dedicated transfer
  connection (feasible via `openAuthenticatedClient`), server-side hash where
  available, promised-file drag-out: separate proposals
  (`docs/SFTP.md:181-184`).
- IME personalized-learning suppression on editor and search fields in both
  siblings (UI-09, sibling review): the remote editor sets
  `enableSuggestions: false` but not `enableIMEPersonalizedLearning: false`
  (verified at `f5570dd`, `built_in_text_editor.dart:1112, 1294`; only the k-i
  dialog sets it). Preserve composition, undo and smart-quote settings; verify
  on Android; not a guarantee against a malicious keyboard.
- Real-device validation: OpenSSH, BBEdit/macOS, Android SAF/provider grants,
  iOS editing (iOS opener copy/share is not proof of upload-back), the macOS
  native Edit menu (STATUS 11), and the app end-to-end (STATUS 2).
- Android foreground keep-alive (#51) is implemented, not device-validated:
  measure battery and OEM behaviour, notification permission, the Android 15
  six-hour `dataSync` timeout; revisit Play `specialUse` if distributing there.

**Gate.** Never erase unsaved edits implicitly. Preserve cancellation ownership
from dartssh2 3.0.2/#59 and the VFS metadata and hash controls (#61, #62).
Concurrent save/upload, reconnect/restart, chroots, symlinks, providers without
stable paths.
Hash-before-rename still has a remote-write race; do not call it a lock.

---

## UI, UX, accessibility and theming

### UI-01: Three-stage adaptive layout and navigation
**IDs:** SOL-039, SOL-060, SOL-062, SOL-065, SEA-015, SEA-018, UI-12 (sibling
review), L-04, S4-K layout · **Priority:** P2 · **Status:** Partial

**Done:** window geometry persisted and clamped (#47); pane widths persisted;
1280x800 defaults; Android Back drawer-first with predictive back (#123); Files
Back climbs folders; iOS edge swipe on Files; scrollable host-key and k-i
dialogs; the Settings window (#126); keyboard and assistive pane dividers
(#134).

**Problem.** Still two-stage at the computed 960 px breakpoint
(`ui/adaptive_shell.dart:27-31`): a 959 px desktop window gets the phone home
with a FAB, and live sessions are hidden unless `_viewingTerminal` was set.
Narrow mode is a state flag, not routes (no iOS swipe-back from the terminal).
At 1000 to 1024 px the utility pane (about 280 px) plus the rail leaves the
terminal about 480 px, under 80 columns, and the utility tab label truncates to
"Snipp..." (L-04, observed live). The utility drawer is a fixed
`Drawer(width: 380)` (`terminal_pane.dart:77-78` @9322f6e). The utility tab and
active host are not persisted. No explicit pane collapse. On Android 12L and
older, Back on the server list still finishes the activity and ends sessions
(`docs/STATUS.md:547-549`).

**Next.** Wide: list, terminal, utility. Medium: list and terminal plus a
utility drawer. Phone: routes. A persisted collapse toggle for the utility
pane, auto-collapsing below about 1100 px, distinct from automatic
constraints. Clamp drawers and dialogs to 90% of the actual width. Persist the
utility tab, selection and active server where useful. Verify geometry after
monitor changes. Handle Android 12L Back (move the task to the back instead of
finishing). Keyboard splitters are done (#134); do not reimplement them.

**Gate.** 320/700/960/1440 px, 1x/2x text, IME, RTL, monitor removal, Android
predictive Back and iOS swipe, breakpoint changes; no lost session or editor
state, duplicate SSH work, keyboard disappearance, unexpected exit or focus
theft; list and utilities reachable by keyboard.

### UI-02: Tab strip overflow and active-tab visibility
**IDs:** S4-02, "tab switcher" idea · **Priority:** P2 · **Status:** Open

**Problem.** `terminal_pane.dart:367-441`: a horizontal `SingleChildScrollView`
with no controller or ensure-visible. With 12 tabs at 1024 px the active one is
off-screen with no hint; a mouse wheel cannot scroll it (Flutter maps a
vertical wheel to horizontal only with Shift) and mouse drag is not a desktop
drag device, so overflowed tabs are effectively unreachable.

**Next.** A `ScrollController` and a per-chip `GlobalKey`;
`Scrollable.ensureVisible` post-frame on `activeTabId` change; a
`Listener(onPointerSignal:)` mapping `dy` to the offset; a trailing overflow
`MenuAnchor` listing all tabs (status dot, label, dirty mark) when
`maxScrollExtent > 0`. It can later become the Ctrl-Tab switcher.

**Gate.** `terminal_tab_strip_test.dart`: the active chip lies inside the strip
rect; `PointerScrollEvent(dy: 120)` moves the offset; the overflow button
appears only when overflowing and selects the tab.

### UI-03: Chrome that grows with text scale
**IDs:** S4-03, UI-08 (sibling review) · **Priority:** P2 · **Status:** Open

**Problem.** Fixed heights: tab strip 38 px (`terminal_pane.dart:355, 635`
@9322f6e), utility tabs 52 px (`sidebar_panel.dart:168, 191`). At text scale 2
the tab labels spill over terminal rows and the panel logs `RenderFlex
overflowed by 1.00 pixels` four times.

**Next.** `minHeight` constraints sized from the text scaler, or
`MediaQuery.withClampedTextScaling(maxScaleFactor: 1.6)` on chrome rows (as
native tab bars do); the same for `_PanelTabLabel`. Do not clamp the user's
scale globally. Test fixed-height utility and session tabs with the keyboard
open too.

**Gate.** Pump `TerminalTabStrip` and `SidebarPanel` at `TextScaler.linear(2.0)`:
no FlutterError; chip height at least the label paragraph height.

### UI-04: Accessible controls, touch targets and reduced motion
**IDs:** SOL-061, SOL-064, SEA-019, SEA-020, SEA-021, SEA-039, UI-03 (sibling
review, touch), S4-17, "quiet motion" idea · **Priority:** P2 · **Status:** Partial

**Done:** a one-value status dot with shape and spoken description; state text
leads the second line; a hidden live header announcement; row verbs via
Shift+F10/Menu; a High-contrast preset and contrast tests (#128); the
installed-font picker (#89); keyboard dividers (#134).

**Problem.** Tab close is 28 px (`terminal_pane.dart:670-679`); the key bar's
`minWidth` is 40 (`terminal_keyboard_bar.dart:187`, about 34 dp tall); strip
buttons are 40x38 on phones; compact mobile rows are 40 dp (#129): all under 44
to 48 dp. S4-17: tab chips (`terminal_pane.dart:581-666`) expose no selected
state, and the status dot (`:965-987`) has no label. No reduced-motion handling
anywhere (`disableAnimations` unused). The settings-recovery notice is a 10 s
toast (`main.dart:193-206`). The terminal screen-reader fallback is minimal.
Pane divider keyboard resizing (#134) still needs native assistive-technology
verification. Device themes, persisted terminal font/palette/zoom, mobile
cursor modes, grapheme-safe middle labels and the composed status badge exist;
what remains is interaction and semantics validation plus missing preferences
(TERM-09).

**Next.** Touch-only 48 dp targets without bloating desktop. Chips in
`Semantics(selected:, button:, label: '<label>, <status>[, unsaved]')` with the
dot and close icon excluded and a "Close tab" custom action. One shared
reduced-motion policy honouring `MediaQuery.disableAnimationsOf` for routes,
drawers and notices: remove spatial slides and tweens while progress, focus,
navigation and cancellation still complete. Bounded live safety notices and an
accessible expiry/action policy (UI-05); a persistent banner for settings and
vault recovery; a useful terminal screen-reader fallback. Localization is a
separate app-wide task (#134's semantics are English, matching the
untranslated UI).

**Gate.** Tap-target and semantics tests (`getSemantics` shows selected and
"connected"); native assistive technology; colour-vision simulation; large
text; selection during output; with `disableAnimations`, progress, focus,
navigation and cancellation still complete. Remote titles cannot impersonate
trusted chrome. Do not replace the existing status palette or create another
theme picker.

### UI-05: Bounded, accessible top notices
**IDs:** UI-04 (sibling review), S4-18, L-03 · **Priority:** P2 · **Status:** Open

**Problem.** Both toast implementations append an unbounded non-scrolling
stack, start fixed expiry timers that are not paused on hover or focus
(`ui/top_toast.dart:173`), and have no live region (`:208-265`), so
screen-reader users never hear "keyring locked... Retry" and mouse users lose
the action while reading it. Text colour is forced white on custom light fills.
In the live run an error notice sat over the Add server dialog's title (L-03).

**Next.** A shared visible limit, duplicate coalescing, overflow and history;
`Semantics(liveRegion: true)` plus `SemanticsService.announce`; pause on
`MouseRegion.onEnter` and focus; text colour from the resolved background;
offset below an open dialog's title, or show dialog-scoped errors inline.
Safety and recovery incidents stay discoverable after expiry.

**Gate.** 20 notices at 320x568 and 2x text without overflow; the live-region
flag is set and native announcements work; hovering past the duration keeps the
notice; a focused action survives; one-shot actions; reduced motion; notices
stay above and never cover the shell prompt.

### UI-06: Accent contrast and recoverable theme editing
**IDs:** S4-09, UI-13 (sibling review), BOTH-REV-011, S4-25, theme known
limits (#128), Terminal default (#135) ·
**Priority:** P2 · **Status:** Open

**Problem.** `theme.dart:172-176` uses a custom accent verbatim as `primary`;
only `onPrimary` is made legible (`:209`). Measured: `#3949AB` is 1.89:1 on the
dark surface and `#FFD600` 1.41:1 on white, while `primary` colours TextButton
labels, the selected Settings tab, focus borders and links. No contrast
feedback in `appearance_settings.dart:243-245`. S4-25: git change letters use
`scheme.primary`/`tertiary` (`git_pane.dart:699-706`) instead of the FamilyHue
vocabulary (AGENTS.md §7). Known limits: editor syntax colours and badge fills
follow brightness, not the palette; the bootstrap spinner uses the default
theme; the kit corner change is Séance-only; the tab was never driven in a
built app (`docs/STATUS.md:220-233`). Since #135 new devices and Reset start
in Terminal, while partial themes and host themes without extensions keep the
Séance/Automatic fallback; preserve that distinction and saved choices. The
baseline captures predate the default change.

**Next.** Keep the raw accent for fills; derive `primary` per brightness by
stepping tone until 4.5:1 against the surface (falling back to the table
primary); show "Low contrast, adjusted". A recoverable live preview, resolved
contrast diagnostics and a legible keyboard reset for extreme palettes. Git
letters via `FamilyPalette.of(context).glyph` (green, amber, red, blue). Do not
prohibit deliberate low-contrast palettes: show the resolved contrast, offer an
automatic correction, and warn only for actual contrast conflicts. Preserve
share compatibility and device-local scope. Verify theme JSON interchange with
Poltergeist (BOTH-REV-011: copy/paste both ways, unknown terminal fields,
corrupt individual values, custom surface contrast, large fonts, status
shapes); do not request another generic theming system.

**Gate.** `theme_build_test.dart`: `#FFD600`, `#3949AB` and `#6B5BD3` reach 4.5:1
at both brightnesses; the default preset stays byte-identical; the existing
preset tests pass. Black-on-black, white-on-white, translucent selections,
all presets, a customized font, both settings engines and rollback after failed
persistence.

### UI-07: Host-key dialog: fingerprints before Trust, legible monospace
**IDs:** S4-12, S4-11 · **Priority:** P2 · **Status:** Open

**Problem.** `ui/host_key_dialog.dart:23-80`: at 360x640 and text 1.5 neither
fingerprint is visible while the red filled "Trust the new key" is enabled;
Cancel is a small TextButton; a key-type change is not called out. S4-11: 20
widgets use a bare `fontFamily: 'monospace'` (including the fingerprint at
`host_key_dialog.dart:101`, PEM fields, the connection log, status bar, git,
snippets, chat, files, import and key bar), which does not resolve on macOS and
iOS, so I/l/1 and O/0 blur exactly where the user compares characters.

**Next.** Fingerprints above the explanation on the changed path; "Key type
changed: A -> B"; Trust enabled only after scrolling to the end (immediately if
nothing scrolls); a tonal Cancel with initial focus (Enter and Esc cancel).
`SeanceTheme.mono(...)` using `monoFallback`, replacing all 20 sites.

**Gate.** At 360x640 and ts 1.5, Trust's `onPressed` is null until dragged to
the end; Esc returns false. A test scanning `lib/` for
`fontFamily: 'monospace'` finds none; the fingerprint style's fallback contains
Menlo and Consolas.

### UI-08: Server editor and Add-server ergonomics
**IDs:** S4-22, L-01, STATUS 20 · **Priority:** P3 · **Status:** Open

**Problem.** No `autofocus` in `ui/server_editor.dart`; Save/Test and the test
result sit at the end of the scroll view (no Save visible at 1024x700); the
phone editor is a roughly 280 px inset dialog. The label is required even when
host, user and password are filled (L-01, live). Test connection validates the
whole form, so the label validator blocks a pre-save test (STATUS 20).

**Next.** Autofocus Label (new) or Host; pin the actions and result row outside
the scroll view; `Dialog.fullscreen` below 600 px; default a blank label to the
host (hint "Defaults to the host"); Test validates only connection fields.

**Gate.** Label focused on open; Save hit-testable at 1024x700 without
scrolling; saving with a blank label stores the host; Test runs with a blank
label.

### UI-09: Narrow-width and chrome polish
**IDs:** S4-10, S4-19, S4-23, L-05, L-06, L-07 · **Priority:** P3 ·
**Status:** Open

- S4-10: the Assistant provider dropdown overflows by 28 px at 360 px
  (`settings_screen.dart:273-297`): add `isExpanded` and ellipsis.
- S4-19: the update banner breaks per character at the 200 px rail
  (`server_list_pane.dart:877-928`): stack text over actions below about
  260 px. Utility tab labels truncate at the 260 px pane minimum: glyph-only
  with a tooltip when the label does not fit. Phone title "S..." at 320 px and
  1.5x: move Import to an overflow menu.
- S4-23: built-in terminal backgrounds (`terminal_appearance.dart:36-41`) no
  longer match the slate chrome; the 10 px resize handles paint bands with no
  hover feedback (`adaptive_shell.dart:404-418`): retune to sibling neutrals,
  paint handles transparent with a `primary` divider on hover/drag, fix the
  stale comment, keep ANSI contrast at least 4.5:1.
- L-05: the utility pane repeats its tab name as a heading: drop it and move
  "+" into the tab or filter row.
- L-06: the bottom-bar density switch is two tiny similar glyphs: one
  segmented toggle with tooltips, or move it to the View menu and Settings.
- L-07: with servers and no selection, the main area offers nothing clickable:
  show recent servers and a quick-connect field (WF-02).
- L-08 (no defect): OSC titles, the status ring and the footer endpoint worked
  in the live run; keep them in the capture matrix.

**Gate.** A 200/260/320/360 capture matrix with no overflow errors and banner
text at most 2 lines; contrast tests for retuned palettes.

### UI-10: Visual hierarchy, identity and captures
**IDs:** SOL-063, visual-direction backlog, `ServerAvatar` decision, phone FAB
clearance note · **Priority:** P3 · **Status:** Partial

**Done:** sidebar redesign (#123-#125), glyph colour vocabulary (#127), themes
(#128), marks, colours and colour line; Linux/Windows titles "Séance".

**Problem.** `screenshot.png` predates the sidebar and themes. No full-app
golden matrix (320/700/960/1440, 1x/2x). The small-size icon is photographic.
The unused `ServerAvatar` awaits a keep/remove decision
(`docs/STATUS.md:523-525`). The phone FAB overlaps the lowest visible group;
bottom clearance allows scrolling it clear, so verify with long lists and
scaled text before calling it an inaccessible-control bug.

**Next.** Starting from the baseline sidebar fixtures, recapture complete
native light/dark desktop and phone screens with the Terminal default and other
presets, preserving each chosen palette's identity; reduce duplicated utility
headings, unlabelled icon clusters and inert space; short context-sensitive
empty-state actions; consistent spacing, radii and density and a quiet
host-identity edge. Terminal palettes stay user-controlled and explicit server
colours are preserved. Normalize visible platform names within signing and
bundle constraints (REL-04) and check desktop/AppStream integration (REL-03).
A terminal/sigil small icon (keep the photographic artwork for onboarding and
marketing). Decide on `ServerAvatar`. No ornamental terminal animation.

**Gate.** A current-screen golden matrix at the UI-01 sizes; keyboard and
screen-reader discovery; launcher-size icon checks; native desktop metadata.
Linux `.deb`, AppImage and desktop/icon packaging exist: audit their
completeness instead of starting another packaging format.

### WF-01: Planchette action palette
**IDs:** workflow backlog, Planchette idea · **Priority:** P1 · **Status:** Open

**Problem.** No action palette exists; only the Cmd-K command generator.

**Next.** A fuzzy palette over service commands: hosts, snippets, settings,
reconnect, sync, assistant; keyboard-first with shortcut help; a restrained
selection motif and no theatrical delay.

**Gate.** Filtering, focus return and final target confirmation; it uses
service commands, never raw UI-to-network calls.

### WF-02: Quick connect, recents and duplicate detection
**IDs:** workflow backlog, L-07, "quick connect in the filter" idea ·
**Priority:** P1 · **Status:** Partial (pinned shortlist #96, Duplicate #73,
Test connection #74)

One-off host/user/port without forced persistence, reusing editor, auth and
TOFU validation. Server search and synced groups, colours and icons already
exist.

**Next.** Typing `user@host[:port]` in the server filter shows an italic
"Connect to ..." row (the kit supports unsaved italic rows,
`sidebar_kit.dart:1265`); Enter opens an unsaved session through the same
editor validation, auth and TOFU path, with "Save..." in its row menu. Add an
MRU list and duplicate detection; the empty main area shows recents (L-07).

**Gate.** An unsaved session never persists a config; TOFU and auth are
identical to saved hosts; a duplicate warning on save.

### WF-03: Device and account management
**IDs:** workflow backlog, pinned-servers sync record (STATUS) · **Priority:** P1
· **Status:** Open (after SYNC-06, SYNC-03, CRED-05)

**Next.** Sign out of sync, list and revoke devices, delete the account
(`HttpSyncClient.deleteAccount` at `http_sync_client.dart:148` is unused),
passphrase rotation, a conflict/deletion audit. The UI must not imply a local
delete revoked a remote credential until the tombstone is acknowledged.
Optional opt-in synced pinned-servers record (`docs/STATUS.md:842-846`).

**Gate.** A revoked device cannot sync; deleting the account signs out all
devices.

---

## Release, packaging and platform

### REL-01: Harden the release workflow and pin toolchains
**IDs:** SOL-040, SOL-056, X-07, X-11, X-23, X-24, X-26 (Séance side),
BOTH-REV-007 · **Priority:** P1 · **Status:** Partial (Dependabot for
actions/gradle, action bumps #109-#113; releases require app tests and the fork
suite)

**Problem.** `.github/workflows/release.yml`: workflow-level `contents: write,
packages: write` inherited by every job; mutable action tags
(`softprops/action-gh-release@v2`, `docker/*`, `subosito/flutter-action@v2`,
`dart-lang/setup-dart@v1`); releases public immediately per matrix leg; no
tag-vs-pubspec check on dispatch (the comment at lines 20-24 only asks for
one); no refuse-overwrite; no SHA256SUMS; Docker `type=raw,value=latest` on
every tag including prereleases (`:315`). CI and release use unpinned `stable`
Flutter/Dart while the app pubspec says `flutter: ">=3.24.0"` (X-11);
Poltergeist pins 3.47.2 and relies on Séance's macOS accessibility gate "on the
same Flutter line" (X-26). The Dockerfile uses floating `dart:stable` and
`debian:stable-slim` without `--enforce-lockfile` (X-23). No
`persist-credentials: false`; no secret scan (fixtures contain PEM headers and
need a scoped allowlist); Dart tests are Ubuntu-only despite Windows named-pipe
and Unix-socket agent code; the review workflow makes a single attempt (X-24).
No multi-arch images.

**Next.** Port Poltergeist's release structure: resolve the checkout ref,
refuse to overwrite, a shell loop checking that all four pubspecs equal
`${tag#v}`, draft legs with `fail_on_unmatched_files`, and a sums job that
verifies a bijection and then publishes. SHA-pin third-party actions; job-level
permissions (read for test/native/flutter); `persist-credentials: false`;
`latest` only when the tag contains no `-`; `FLUTTER_VERSION: '3.47.2'` in CI
and release, the app floor `>=3.47.2`, AGENTS §1 pinned, bumped together with
Poltergeist. Pin base images by version and digest sharing one Debian codename;
`dart pub get --enforce-lockfile`. Add a secret scan, multi-OS `dart test` and
one bounded review retry. Make Docker Hub and Gradle pulls resilient (caches,
authenticated pulls, bounded retries) and distinguish infrastructure failures
from code failures. Back up before schema updates, wait for readiness and roll
back failed deploys (`update.sh`). Pin an SDK/golden-update policy; never
regenerate goldens just to turn CI green. Correct stale scratch/static-image
and every-request version claims (DOC-01).

**Gate.** A dispatch with a mismatched tag fails; a prerelease does not move
`latest`; a re-run refuses to overwrite; SHA256SUMS verify; packaged install
and upgrade; failed rollout recovery.

### REL-02: Verify downloaded Linux packaging tools
**IDs:** X-08, SOL-040 appimagetool note · **Priority:** P1 · **Status:** Open

**Problem.** `scripts/package-linux.sh:380-401` downloads appimagetool 1.9.1,
runs `chmod 755` and executes it without a checksum, caching by basename.
Without `--runtime-file` (`:436-445`) appimagetool embeds a runtime fetched
from the mutable `type2-runtime` "continuous" release, and the job holds
`contents: write`.

**Next.** Pin `APPIMAGETOOL_SHA256_x86_64`/`_aarch64` and verify with
`sha256sum -c` before `chmod`, for downloaded and cached copies; pin a
`type2-runtime` asset with its SHA-256 and pass `--runtime-file`; source-aware
cache keys; keep explicit local-tool overrides. Make the same change in
Poltergeist.

**Gate.** A hash mismatch, a URL collision and an interrupted download fail the
build.

### REL-03: Linux package metadata port-backs
**IDs:** X-12, X-13, SOL-063 AppStream · **Priority:** P3 · **Status:** Open

**Problem.** The `.deb` libstdc++6 floor compares a GLIBCXX ABI tag with
package versions (`package-linux.sh:204-219`), so it never rejects.
`seance.desktop` (`:324`) does not match the GApplication id
`com.lkm.seance_app`, so Wayland docks may show a generic icon or a second
entry. `copyright` says "as published in the source repository" (`:330`).
`scripts/build.sh:264` ignores `package_linux` failure (exit 0 after "packages:
FAILED"). The GTK view background `#000000` flashes black on resize
(`linux/runner/my_application.cc:48`). No AppStream metainfo
(`package-linux.sh:441`).

**Next.** Copy Poltergeist's GLIBCXX-to-GCC mapping and tests;
`$APPLICATION_ID.desktop`; embed the license text; `package_linux || FAILED=1`;
a transparent GTK background (main and settings views); add metainfo.

**Gate.** `dpkg-deb -I` shows a real libstdc++ floor; `desktop-file-validate`
and `appstreamcli validate` pass; build.sh exits non-zero on packaging failure.

### REL-04: Mobile and Apple platform metadata
**IDs:** X-18, X-19, X-22, SOL-040/056 (iOS LAN disclosure, cleartext policy,
Android signing) · **Priority:** P2 (X-22 and LAN policy), P3 (others) ·
**Status:** Open

**Problem.** The APK `versionCode` is always 1 (pubspecs have no `+build`;
Flutter defaults to 1), so updaters such as Obtainium cannot order releases
(X-18). The iOS home-screen name is "Seance App" (`ios/Runner/Info.plist:9-10`;
`CFBundleName` `seance_app` at `:17-18`) (X-19). No
`NSLocalNetworkUsageDescription` in the iOS or macOS plists: iOS and macOS 15+
prompt with generic text, and a denial yields an unexplained EHOSTUNREACH
(X-22). The iOS `Info.plist` has no ATS keys; the cleartext sync/provider URL
policy is unreviewed; users need to know that phone `localhost` is the phone.
The committed Android sideload key gives upgrade continuity, not publisher
authenticity.

**Next.** `release.sh`'s post-bump writes
`X.Y.Z+<major*1e6+minor*1e3+patch>` into the app pubspec, with a CI verify step.
`CFBundleDisplayName` "Séance" (only bundle file names must stay ASCII). A
local-network usage string in all Apple plists and an EHOSTUNREACH hint on
Apple platforms. A narrow, tested transport policy and reverse-proxy examples.
Protected signing if distributing publicly.

**Gate.** `aapt dump badging` shows the derived versionCode; plist keys present
(parse test); a signed mobile relaunch keeps data.

### REL-05: Review-service latency and configuration drift
**IDs:** earlier P2 entry, X-24 (retry) · **Priority:** P2 · **Status:** Open

**Problem.** Both siblings' `.github/workflows/zai-code-review.yml` set
`MAX_CHUNK_CHARS: 25000` (Séance: `:82`, verified at `f5570dd`) while the
adjacent comment says that size exhausted the reasoning/output budget and that
the action default should be used. #132's first assessment needed two
output-limit retries before returning useful feedback, and its sixth completed
only after three output-limit failures and smaller-chunk retries. Séance permits one 170-minute attempt; Poltergeist two,
with a retry and a backstop. These are ceilings, not evidence that every run
times out.

**Next.** Verify the pinned action's defaults; measure small and large patches
with candidate chunk sizes; reconcile the comments; choose an explicit
wall-clock and retry budget from coverage, latency and failure data;
coordinate with Poltergeist's current-PR scope fix so inherited main changes do
not inflate the workload. Do not change the workflow during an active
assessment to manufacture approval.

**Gate.** Coverage, elapsed time, retries and output-limit failures recorded;
timeout and partial-review notices distinguishable from clean reviews;
superseded heads cancelled and no stale result approves a new head.

### REL-06: Small Séance code port-backs
**IDs:** X-16 · **Priority:** P3 · **Status:** Open

**Problem.** `lib/services/badge_image.dart:251` catches only `Exception` in
the encode phase; `toImage`/`toByteData` can fail with an `Error`, which
crashes the import instead of showing "couldn't encode". Poltergeist fixed
this (`catch (_)`, `cee70be`).

**Next.** Port the catch; ask Poltergeist to update its PORTS "verbatim" entry.

**Gate.** A fake encoder throwing an `Error` returns the failure result.

---

## Documentation drift

### DOC-01: Agent-facing docs that mislead
**IDs:** SEA-030, X-20, X-21, S5 stale items, astra outdated statements ·
**Priority:** P2 (X-20), P3 (rest) · **Status:** Open

Fix each; generate counts in CI or drop them.
- `docs/POLTERGEIST.md:348-350` and its closing bullet say Poltergeist reads
  `serverConfig` read-only and writes only `bookmark:`/`hostkey:` records.
  Since 2026-09-24 it writes `serverConfig` and opted-in `secret:` records.
  Rewrite the section, state the `secret:` publication rules, and add a
  field-preservation invariant (XAPP-01). Its table still lists PR-S4 (agent +
  ProxyJump) as an ask; #131 delivered it.
- AGENTS.md `:114` and `:317` test counts (746/700/245) are stale (baseline
  above: 778 package tests, 1,083 app tests); STATUS points readers at them.
- `CHANGELOG.md` has only "Unreleased" although v0.9.2 shipped; items merged
  before the bump sit under Unreleased.
- `docs/STATUS.md`: items 3 (redaction toggle) and 5 (UTF-8 across packets) are
  implemented (`chat_sidebar.dart`; `xterm_engine.dart:146-148` chunked
  decoder): delete them. The #54 housekeeping text is half stale: servers and
  snippets write tombstones since #84; "every pull is full" is still true. The
  "Should do next" numbering starts at 2.
- Code comments cite wrong STATUS numbers: `server_editor.dart:60, 109` say 17
  (actual 18/19), `app_services.dart:635` says 16 (actual 17). Renumber or fix.
- `packages/seance_sync_server/README.md:95` says every request carries a
  `protocolVersion`; GET `/v1/sync`, prelogin and DELETE do not.
- `PROPOSAL.md:86, 190` describe a scratch image; the Dockerfile uses
  `debian:stable-slim`.
- `astra.md`: "Window sizing belongs to PR #47" and "#49 ... rebase/review it"
  are outdated (both merged); "Local shell is already PR #44" is unverifiable
  (no code in main).
- The archive's relative links were written for the repository root; current
  targets: [astra.md](astra.md), [July archive](docs/reviews/analysis-2026-07-25.md),
  [PROPOSAL.md](PROPOSAL.md), [status](docs/STATUS.md), [SFTP](docs/SFTP.md).

**Gate.** A reviewer reading only AGENTS, STATUS and POLTERGEIST reaches
correct conclusions about X-02/X-03 and current counts.

---

## Cross-app with Poltergeist

### XAPP-01: Preserve unknown `ServerConfig`, `Snippet` and `Bookmark` keys
**IDs:** X-03, "protocol hygiene" idea · **Priority:** P1 · **Status:** Open

**Problem.** `seance_protocol/lib/src/models/server_config.dart:327-400`:
`toJson` writes and `fromJson` reads only known fields; unknown enum names
degrade to null. Poltergeist round-trips Séance's catalog through a lagging
pin, so any field Séance adds is stripped fleet-wide when Poltergeist (or an
older Séance) edits a label, and the stripped record wins LWW. Poltergeist's
editor already dropped `jumpHostId` this way (X-02, being fixed on its side).

**Next.** A private `Map<String, Object?> _unknown` captured in `fromJson` and
merged back in `toJson`, carried by `copyWith`; keep the raw values of
known-but-rejected enum names. The same for `Bookmark` and `Snippet`. Add
"every model round-trips unknown keys" to POLTERGEIST.md's never-touch list,
with a golden test per model that both repos run. Poltergeist re-pins
afterwards.

**Gate.** Decode JSON with extra keys, `copyWith(label:)`, `toJson`: the extras
survive byte-identical; an unknown icon name round-trips.

### XAPP-02: Tag and re-pin coordination for #131 (agent default, API break)
**IDs:** X-04, X-25, X-05 (Séance side), PR-S4 · **Priority:** P1 (blocks the
next tag) · **Status:** Open

**Problem.** Once tagged, Séance's agent default makes every new or keyless
imported server fail in Poltergeist on v0.9.1 (`AgentAuthUnsupportedError`).
The re-pin is breaking: `KeyboardInteractiveResponder` now takes a
`KeyboardInteractiveChallenge`; `AgentAuthUnsupportedError` was removed;
`openAuthenticatedClient` gained `resolveJumpHost`, `forward` and
`loadAgentIdentities`; `seance_core` added `ffi: ^2.1.0` (license gate).
Without a resolver, `jumpHostId` configs now fail honestly
(`ssh_session.dart:855-861`), while the old pin dials the destination directly
(X-05). The wire format and record kinds are unchanged since `035b0d8`.

**Next (Séance side).** Do not tag the agent default until Poltergeist has a
fallback or is ready to re-pin in the same window; resolve SSH-06 first.
Record the API changes in CHANGELOG. Consider the downstream canary job (idea).

**Gate.** Poltergeist builds and connects to an agent server on the new tag.

### XAPP-03: Shared sync contracts to coordinate
**IDs:** S1-02 ordering, S1-03 exception move, PG-REV-001, #56, upstream
`PersistentLocalRecordStore` · **Priority:** P1 · **Status:** Open

- SYNC-02 must wait for Poltergeist's `keepLocalPin` stamp fix.
- SYNC-05 moves `SyncCursorRejectedException` into `seance_core`; Poltergeist
  switches its import, and its dead catch path starts working unchanged.
- Exact-record settlement (Poltergeist PG-REV-001) and SYNC-03 slice 3 should
  share one extension of the sync contract, with consumers and tests.
- TRUST-01 (#56) is the pin-trust gate for shared accounts.
- Upstreaming Poltergeist's persistent record store into `seance_core` would
  serve SYNC-03 slice 1.

### XAPP-04: Shared files, packaging and platform parity
**IDs:** X-08, X-09, X-10, X-11, X-26, BOTH-REV-011, BOTH-REV-012, shared-file
guard idea ·
**Priority:** P2 · **Status:** Open

The Séance halves are tracked in REL-02, STORE-02, CRED-04 and REL-01. Keep
`family_hues.dart`, `sidebar_kit.dart`, `selected_tab_view.dart`, the theme
palette/presets/contrast files and the settings-window runners in step (a
manifest plus a CI hash check is an idea below). Pin both siblings to the same
Flutter version so Poltergeist's reliance on Séance's macOS accessibility gate
holds. BOTH-REV-012: keep an authoritative port ledger. Shared package fixes
belong upstream; copied UI and storage files need behavioural parity checks and
dated divergence entries (the two atomic-file helpers have already diverged in
serialization and fallback behaviour); test cross-repo security contracts
rather than keeping only a historical copy timestamp. BOTH-REV-011 (theme
interchange) is in UI-06. Poltergeist-only items from the X slice (X-01, X-02, X-05 on its side,
X-15, X-17) live in its ANALYSIS.md.

---

## Ideas

Each is local and explicit by default, reduced-motion aware and subordinate to
shell predictability. Ideas with a backlog entry point there. These
consolidate earlier ideas without removing their useful variants.

| Idea / IDs | First useful slice and acceptance |
|---|---|
| Fingerprint spirit sigils / SEA-033, randomart and SSHFP | Deterministic randomart and an optional host hue on rows, tabs and TOFU; the same key gives the same identity across devices and a changed key visibly changes it; optional SSHFP check. Never replaces fingerprint verification or overrides explicit labels. |
| Safe Draft Dock / SOL-047 | See TERM-07. Local, editable, target-labelled staging with source and danger cues; only an explicit action sends to the PTY, never Enter. Test nonempty prompts and stale sessions. |
| Planchette | See WF-01. One fast action palette with a restrained selection motif; no theatrical delay or focus ambiguity. |
| Production wards and tint | A synced production/staging/lab tag with symbol and colour; a 3 to 4% server-hue wash on prod terminals; extra confirmation for reviewed destructive/sudo actions and multi-line pastes. No promise of intercepting every command. |
| OSC 133 command cards / SEA-028 | See TERM-07: Copy, Explain, Snippet, reviewed Rerun, Compare, Include in chat, from real boundaries. |
| Last words | See TERM-08. Preserve final output, duration, cwd and disconnect reason with copy/save/reconnect; never hide diagnostic scrollback behind a blank placeholder. |
| Completion notices / SEA-031 | For background completed commands, an optional tab badge or OS notice with exit and duration; correct session attribution; command text hidden by default. |
| Ghost tabs / SEA-032 | A short-lived Undo close restoring host and label with reviewed cwd staging; not remote process restoration; never bypasses managed-edit guards (after APP-02). |
| Whisper mode / SEA-034 | See AI-05. Auto-arm only from a trustworthy signal. |
| Séance transcript / SEA-035 | A previewable redacted Markdown export of command/output blocks, timestamps, host and duration to file, clipboard or snippet; warn that redaction is best-effort. |
| Presence pulse / SEA-036 | A real keepalive RTT tooltip, sparkline or quiet pulse (expose RTT from core first); no invented measurement; never animate terminal text; reduced motion. |
| Custom/two-hand mobile decks / SEA-037 | Per-host saved keys, modifiers left and navigation right, punctuation drawer, repeat/haptics, clipboard actions; keep application cursor modes and 48 dp targets. |
| Context ledger / SOL-044 | See AI-02. An expandable exact outbound receipt for every assistant request, including history, search and redaction; no hidden resend. |
| Idle divination / SEA-038 | Per-host opt-in cheap uptime/disk/reboot facts over `SshSession.runCommand`, outside the PTY; no autonomous assistant execution or undisclosed periodic commands. |
| Reading anchor / "Jump to live" pill / AST-011 | An unread-output counter ("37 new lines") and Jump to live while scrolled up or selecting, using `RenderTerminal.stickToBottom`; stable absolute anchors and bounded counts after trims; no selection theft or unsolicited snap-to-bottom; test alternate screens. |
| Connection flight recorder / AST-012 | Bounded opt-in phase timings (DNS/TCP/handshake/auth/shell vs parse/layout) in `SshConnectionLog`; a redacted export preview; no commands, keys or raw traces by default. |
| Portable workspace recipe / AST-013 | Save hosts, tab labels, pane layout and intended cwd; preview targets, then explicitly reconnect; stage a quoted cd only at a verified empty prompt; never silently replay commands or login scripts. |
| Quiet connection rehearsal / AST-014 | Test connection exists (#74); add an optional, cancellable staged DNS/port/key-readability check before saving that explains the next trust/auth step, with real cancellation (SSH-01) and field-only validation (UI-08). No password guessing, background remote commands or silent pinning. |
| Files breadcrumb return trail | Surface the existing endpoint-scoped folder history, distinct from host favourites; test chroot and disconnected identity, keyboard access and exact return paths; never an implicit shell `cd`. |
| Quiet motion | See UI-04's reduced-motion policy (routes, drawers, notices; no spatial slides or tweens under `disableAnimations`). |
| Search with scrollbar ticks | See TERM-05. |
| Tab switcher ("séance table") | The overflow menu (UI-02) reused as a Ctrl-Tab popup with live dot, cwd, running command and type-to-filter. |
| Tab drag-reorder, move to new window | Reorder within a server's strip first, persisted in tab order. |
| "Close the circle?" quit ritual | See APP-01. |
| Draft ectoplasm | See APP-01 (mobile draft autosave). |
| Recovered edits drawer | See APP-04. |
| Account sigil | Four words from a 256-word list derived from `syncKeyCheck` (CRED-02) in Settings > Sync, so two devices can be compared at a glance. |
| Polite probing | See SSH-08. |
| Linux terminal conventions | Opt-in copy on select and middle-click paste of the last in-app selection (Flutter lacks PRIMARY). |
| Glyph-run painting | Benchmark `paintLine` at 200x60, then batch same-style cell runs into one paragraph behind a flag, with golden comparisons (PERF-01). |
| "Who changed this?" sync receipts | A sealed `device:<id>` name record; an "edited on MacBook, 3 min ago" tooltip; feeds WF-03's device list. |
| Echo-free cursor advance | When the accepted seqs are exactly `previousLatest+1..latestSeq`, advance the cursor without re-downloading own pushes (after SYNC-03 slice 1); test the non-contiguous case. |
| Rollback tripwire | Remember the highest `latestSeq` and a rolling hash of pulled tuples; warn "server state went backwards" (first slice: SYNC-05's check, logged). |
| Non-enumerating prelogin | A deterministic fake salt `HMAC(serverSecret, username)` and default params for unknown users; test that known and unknown users are indistinguishable by status and shape. |
| Account doctor endpoint | `GET /v1/account/stats` (records, bytes, largest record, tombstones) plus a Settings line; helps SYNC-04 and S1-10 victims. |
| Second-launch hand-off | After STORE-02, a second process asks the first to focus via a loopback port recorded in the lock file. |
| Handoff URLs (both apps) | `poltergeist://open?server=<id>&path=` from Séance's cwd and `seance://connect?server=<id>&cd=`; register on macOS and Linux for one verb; an `sftp://` clipboard fallback. |
| Drag from Poltergeist onto a Séance terminal | Accept `text/uri-list` `sftp://` drops and paste the shell-quoted path when host and user match the session. |
| One theme for the family | "Use Séance's theme" in Poltergeist; later an opt-in synced `appearance` record (device-local by default). |
| Downstream canary | A Séance CI job building Poltergeist core against the PR's `seance_core` (analyze-only, non-blocking first); would have caught X-25. |
| Shared-file guard | A manifest of byte-identical files with normalization rules and a CI hash check against the sibling's recorded revision. |
| Session tray (both apps) | A local socket announcing `{serverConfigId, state}`: Séance shows Poltergeist's transfer count, Poltergeist shows an open-shell dot. No secrets shared. |
| Poltergeist-side ideas using Séance code | Port Séance's Android `KeepAliveService` to Poltergeist transfers; server-side operations over `runCommand` (reflink copy, `sha256sum`, git chip). Tracked in Poltergeist's ANALYSIS.md. |

Later, separate proposals: terminal splits, tmux/Mosh persistence, a local
shell (PR #44 never landed), provider-native web search (STATUS 7), sync OIDC,
libghostty (proposal M10). Historical proposals and their ownership links
remain in the archive; verify current code before planning them.

---

## Completion ledger

One line per completed backlog item; details are in the PRs and the archive.
Residuals live in the entries named.

| PR | Item(s) | Residuals now tracked in |
|---|---|---|
| [#132](https://github.com/L-K-M/Seance/pull/132) (sibling reviewer, head `8bfd0eb`) | SEA26-SEC-01: redaction masks complete quoted JSON/YAML values and static shell assignment words, including escaped and truncated inputs, adjacent fields, common `secret_key` spellings and AWS secret-access-key fields; actual provider-body coverage. General redaction remains best-effort. | AI-02 (YAML tags/block scalars, dynamic shell, `==`/`:=`, colon-prefixed scalars, S2-11 forms) |
| [#133](https://github.com/L-K-M/Seance/pull/133) (sibling reviewer, head `659e034`) | SEA26-SEC-06 / SOL-051 slice: atomic SQLite account deletion with rollback under injected failures | SRV-02 (login/deletion and push/delete races, token join, createAccount leftovers), SYNC-06 (token lifecycle) |
| [#134](https://github.com/L-K-M/Seance/pull/134) (sibling reviewer, head `1322090`) | UI-02 (sibling review) / SOL-061 slice: focusable, labelled pane dividers with arrow and assistive adjustment, visible focus, clamped values, RTL geometry; modified arrows pass through | UI-01, UI-04 (native AT QA, localization) |
| [#135](https://github.com/L-K-M/Seance/pull/135) | New devices and Reset start in the Terminal theme (`10b49f8`, `06204c8`); partial and extension-less host themes keep the Séance fallback | UI-06, UI-10 (captures predate the change) |
| [#136](https://github.com/L-K-M/Seance/pull/136) | S1-01 auth-route body cap and `BytesBuilder`; S1-06 username validation including invisible characters, before the limiter; S1-15 typed 400; S1-11 server-side salt/verifier shape | SRV-01 (limiter key count, per-IP buckets, chunked 413), PROTO-02 (client salt check, case/Unicode policy), PROTO-01 (S1-13 seq) |
| [#137](https://github.com/L-K-M/Seance/pull/137) | S2-01 fish-safe `quoteShellWord` for the git probe and staged cd; OSC 7 control-character guard | SSH-09 (`sh -s`, fsmonitor, porcelain `-z`) |
| [#138](https://github.com/L-K-M/Seance/pull/138) | S2-02 refuse replace over symlink/FIFO/device/folder; permission-bit mask; part of S2-09 (owner-only staging when the final mode withholds read or write) | SSH-10 |
| [#139](https://github.com/L-K-M/Seance/pull/139) | S4-04 persisted "Include terminal output" opt-out, shared by the chat drawer and the command generator (also closes the sibling review's drawer `_includeContext` reset) | SYNC-07 (sync it?) |
| [#140](https://github.com/L-K-M/Seance/pull/140) | S1-04: a record the server refuses as too large no longer stops pulled records from being applied; the sync status names it | SYNC-04 (size guard, multi-record split, re-send per run) |
| [#141](https://github.com/L-K-M/Seance/pull/141) | S3-01 managed checkouts preserved across index loss; S3-03 startup survives unreadable checkouts | APP-04, STORE-01 |
| [#142](https://github.com/L-K-M/Seance/pull/142) | S4-07 new tab uses the current saved config | None |

Earlier landed work that closed or reshaped backlog items (verified by the S5
audit at `dd7e105`; details in the archive and STATUS):

| PR(s) | Item |
|---|---|
| #64 to #71 | Earlier consolidation ledger: KDF ceilings (AST-001), auth field privacy, footer layout, status contrast, client release tests, HTTP cleanup, capture filtering, transactional push/pull (#71) |
| #47, #49 | Window-state persistence; 64 KiB unfinished-sequence cap (part of AST-009) |
| #58, #59, #61, #62 | Unknown-kind preservation; SFTP cancellation (dartssh2 3.0.2); VFS metadata and hash controls |
| #72, #73, #74 | Exclude from sync; duplicate server and the `_mutate` queue; Test connection and referenced-key passphrase |
| #84 | Server and snippet delete tombstones (#54 for those kinds) |
| #90, #92 | Push batching to server limits; advertised blob cap |
| #91 | Current-state bugfixes including the per-path write queue, turn-only chat context, snippet id checks |
| #95, #98, #99, #100, `6f3d7f3` | Serialized vault ops, credential versioning, healing an unreadable credential, crash-safe re-key journal |
| #103 | OSC 8 hyperlinks (keyboard discovery and mobile gestures remain: TERM-09) |
| #123 to #131 | Sidebar kit, Android Back, densities, Settings window, family colours, themes, mobile rows, agent and ProxyJump (#131) |
| Various (sibling review's completed-scope list) | KDF ceilings, auth field privacy, footer layout, default status contrast, client release tests, HTTP cleanup, recognizable-secret capture filtering, transactional record push/pull, unknown-kind preservation, SFTP/editor features, terminal selection, current vault re-key journal, deletion intents, independent secret timestamps, app mutation queue, agent/jump transport, device themes, narrow Back handling. Completed changes are not instructions to implement again; residuals above stay independent of them. |
| #80, #81 | SOL-036 macOS key-file access: audit log hardening (native validation only) |

---

## Invariants and release gates

Preserve: shared protocol code; domain-separated Argon2id/HKDF and XChaCha
AEAD; strict changed-host-key blocking; explicit review-before-run; default-on
redaction (best-effort, never a secrecy guarantee); terminal scrollback and
search content treated as untrusted; no assistant execution or file tools;
stable terminal identities and selection; top notices that never cover the
shell prompt; every model round-trips unknown keys (once XAPP-01 lands). The
always-available assistant is deliberate, not a missing toggle. JSON stores and
pure-Dart crypto are intentional, swappable v1 choices.

Before sync and credential handling are called production-ready:

| Gate | Status at `9322f6e` | Entries |
|---|---|---|
| Restart-level two-device typed deletion and forced ack/apply races | Partial: server/snippet deletion convergence tests exist; ack/apply races untested (masked by the queue); hostKey/secret deletes refused | SYNC-01, SYNC-03 |
| Authenticated-envelope tamper/replay/transplant and migration fixtures | Open | SYNC-01, SYNC-02 |
| Real HTTP-over-SQLite concurrent snapshot/upsert and crash tests | Partial: #71 concurrency tests; no cross-process kill or crash tests | SRV-02 |
| Independent crypto vectors, device KDF profiling, external protocol review | Open | PROTO-02 |
| Real sshd auth/changed-key/resize/output/strict-KEX matrix | Partial: a real Unix-socket agent test; one manual local sshd check; no CI matrix | SSH-01, SSH-07, TRUST-01 |
| Signed Apple keystore relaunch and migration; Android upgrade and backup | Open | CRED-04, REL-04 |
| Adaptive golden/semantics tests plus native keyboard/clipboard/IME | Partial: server-list captures, narrow Back tests, Xvfb drives; no devices | UI-01, UI-04, TERM-10 |
| Running-container readiness/persistence/backup/restart/SIGTERM smoke tests | Open: CI builds the image only | SRV-03, REL-01 |
| Cursor regression recovery and enrolment key check | Open | SYNC-05, CRED-02, CRED-03 |

The gate status column is as of `9322f6e`; #140 (merged since) touched only
the refused-record path and changes none of these rows.

---

## Appendix: review records for #132 to #134

Carried over from the sibling reviewer's ANALYSIS.md so that no review decision
is lost. All three PRs have merged since (`8bf33b8`, `3ee800f`, `c185049`); at
publication they were open on separate branches from the reviewed main. The
check/review snapshot below does not certify later commits or native behaviour.
Deferred suggestions recorded here are not backlog entries unless an entry
above names them.

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
The PR has since merged (see the completion ledger).
