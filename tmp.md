# SSH sibling apps: review before implementation

Review date: 2026-09-26. Poltergeist base: `913ca3da32b168fd0f8b480032e495666d5cc9f2`.
Séance base: `dd7e105` (both fetched before review).

This snapshot records the review before source or regression-test changes.
`ANALYSIS.md` is the maintained backlog after implementation. Findings are
source-confirmed unless explicitly marked as a hypothesis, runtime observation,
or proposal. Line numbers refer to these bases and will drift after fixes.
We did not inspect or interact with other contributors' open PRs.

## Assessment

The apps already have substantial functionality and defensive engineering:
separate SSH transport and UI responsibilities, changed-key handling, managed
remote edits, cancellation paths, tests, transfer journals, and shared theme
vocabulary. Poltergeist has previewable sync, queue controls, two-pane tabs,
Quick Look, native drag-out and multiple workspace windows. Séance has session
tabs, a terminal fork, SFTP editing, an assistant, themes, SSH-agent support and
jump hosts. These are present features, not suggestions to implement again.

The highest-value work is making existing safety promises hold through failures
and concurrent actions. The next priorities are recoverable enrollment/storage,
bounded network/parser work, and accessible interactions. Further visual work
should refine the current design rather than replace it wholesale.

## Root review: account backup, shared storage and distribution

### PG-REV-001: An old push acknowledgement can erase a newer edit (P1)

Evidence: `packages/poltergeist_core/lib/src/bookmarks/bookmark_coordinator.dart`
lines 777-804 snapshots dirty records, awaits the network, then acknowledges by
ID. `src/sync/persistent_record_store.dart:223-228` stamps whatever currently
occupies that ID and clears its dirty flag. Local bookmark/server edits are
allowed during backup; the UI's `_syncing` guard only serializes backup rounds
and account changes. Rejected pushes can similarly restore a displaced old
winner over a newer edit.

Reproduction: pause a push of revision A, edit the same bookmark to revision B,
then complete A's response. B becomes clean even though the server never saw
it. A future backup may never upload B. This is silent backup divergence, not
merely an unnecessary extra request.

Fix: settle accepted and rejected responses only against the exact sent record
in the store's existing mutation queue. Preserve a replacement's dirtiness and
displaced bookkeeping. An ID/timestamp comparison alone is insufficient when
two edits share a clock tick. Never hold the UI edit path behind network I/O.

Acceptance: blocked accepted/rejected push plus same-ID edit and deletion,
including equal timestamps/different sealed bytes; reload from disk; subsequent
backup reaches the new state. Normal acknowledgements and losing-LWW restoration
must retain their existing behavior. Séance's public sync contract has the same
by-ID weakness; any upstream extension must be coordinated with its consumers.

### PG-REV-002: Large backup dirty sets exceed server request limits (P1)

Evidence: `BookmarkCoordinator.runRound:777-787` pushes the entire dirty set in
one request. Current Séance's `SyncEngine._pushOnce` uses `batchForPush` and
advertised `PushLimits`; Poltergeist pins Séance v0.9.1 (`035b0d88`) and has its
own coordinator. Repeatedly retrying the same oversized request cannot converge.

Fix: audit and update the shared package pin, then consume the shared batcher
and limits in Poltergeist. Preserve partial progress, exact-revision settlement,
and a clear oversized-single-record error. Do not copy shared transport code.

Acceptance: more than the default record-count limit, byte-limit splits,
nondefault advertised limits, legacy server fallback, interruption after an
accepted batch, and one oversized record. Run against the real server fixture.

### BOTH-REV-003: I/O failure is mistaken for corruption in sensitive stores (P1)

Evidence: Poltergeist `app/poltergeist_app/lib/services/file_stores.dart:110-131`
and Séance's corresponding main vault/host-key loaders put file reads inside
the corruption catch. A temporary read/permission failure can quarantine valid
data and expose an empty store. The re-key sidecar already demonstrates the
safer separation: read bytes outside the parse/schema catch.

Fix: propagate retriable I/O failures without moving the file or completing
initialization as empty. Parse bytes separately so invalid UTF-8 remains a
content error. Preserve unique recovery copies and surface recovery actions.

Acceptance: injected read failure leaves bytes and pins untouched; a second
read succeeds; malformed UTF-8/JSON still quarantines under unique names;
concurrent first-load callers see the same failure. Port behavioral changes to
both apps and update the copy ledger.

### PG-REV-004: Failed persistence can leave an uncommitted in-memory cursor (P1)

Evidence: `PersistentLocalRecordStore._mutate:278-288` edits live maps/cursors
before awaiting `_write`; the healed tail permits later reads after failure.
If a cursor write fails, subsequent reads can report progress absent from disk.
If a tombstone/domain operation partially fails, subsequent sync may observe a
state the failed action did not promise to commit.

Fix: stage a complete next state, persist it, then publish it, or restore a
snapshot on write failure. Define behavior for failures after rename/fsync,
where disk may already hold the new state; do not claim a transaction across
independent domain and record files. Longer term, put the domain and outbox in
one transactional store.

Acceptance: failure injection for local/remote record, displaced winner,
acknowledgement and cursor writes; in-memory and reopened views agree with the
documented failure contract. Tests must include an immediately following call.

### BOTH-REV-005: Account enrollment needs a transaction beyond vault re-key (P1)

The vault now has a staged two-generation re-key journal. Do not reimplement
that completed feature. URL, bearer token, account metadata, vault-key swap and
sync-ledger reset still require a recoverable enrollment boundary. Séance
`AppServices` persists new connection facts before re-key completion, so a
failure can leave a new account selected with old encryption state.

Fix: journal an explicit enrollment attempt and activation state; verify the
account and decryptability before publishing a usable configuration. Recovery
must either resume the attempt or preserve the old usable account. Preserve
local-only and orphaned credentials, not just those referenced by current rows.

Acceptance: failure/restart at every write boundary; old and new account keys;
locked keystore; no implicit empty-vault recovery or upload under the wrong key.

### BOTH-REV-006: Account transport and encrypted-envelope boundaries (P0 design work)

Séance `RecordCodec` seals kind/data, while ID, time, device and deletion are
outside authentication; tombstones carry empty blobs. Both apps consume this
protocol. Poltergeist quarantines conflicting synced pins, but that does not
authenticate all routing/deletion metadata. E2E ciphertext alone does not
justify a breach-tolerant account claim.

Use the existing SOL-011 envelope-migration task: versioned authenticated
identity/revision/deletion, typed tombstones, compatibility fixtures and explicit
rollback policy. Keep server sequence outside the client-authenticated payload.
Do not introduce an incompatible local crypto fork as a quick fix.

Separately, enrollment accepts HTTP URLs. Establish an explicit loopback/secure
tunnel exception and remote-HTTP warning or refusal policy, with clear setup
copy. Encryption does not protect bearer tokens or authentication verifiers in
cleartext transport. Test IPv4/IPv6 loopback, redirects and reverse-proxy paths.

### BOTH-REV-007: Packaging has reproducibility and release-verification gaps (P2)

Poltergeist already stages releases privately, verifies versions/licenses,
emits checksums, then publishes a complete release. Preserve those controls.
`scripts/package-linux.sh:460-479` downloads and executes appimagetool without
checking a known digest and caches by basename; another URL with that basename
can reuse an unrelated cached executable. Séance shares the pattern.

Fix: pin a digest per supported host architecture and include source identity
in the cache key. Verify before executing cached or downloaded tooling; define
the explicit local-tool override separately. Validate mismatched cache and
interrupted downloads. Signing/distribution changes remain product choices,
not reasons to silently replace the documented personal-app release policy.

## Cross-platform and performance priorities

- **PG-REV-008, P1: macOS extra-window accessibility.** D39 explicitly disables
  semantics in secondary workspace windows because the embedder assigns them
  to the primary bridge. Treat this as a real supported-feature limitation:
  add a view-aware native bridge or a clear accessible single-window path.
  Verify VoiceOver independently in two windows and after closing/reopening
  the implicit view. Private macOS/Windows embedding APIs need SDK-upgrade
  compatibility tests; compile success does not establish native usability.
- **PG-REV-009, P2: bridge performance budgets need remeasurement.** D8 now
  keeps the queue/local hashing/local I/O in the UI isolate and remote-to-remote
  bytes cross twice. Run the existing M0/D12 workloads against the shipped
  bridge: large listings, concurrent transfers, hashing, cancel, bounded memory,
  frame/typing latency. Move work only when measured budgets fail. The original
  spike does not prove the amended architecture's performance.
- **PG-REV-010, P1 feature: Android foreground transfers and storage grants.**
  D35 declares Android supported but background freezing stops transfers and
  local browsing is app-private. Build foreground execution/cancellation and
  durable SAF grants as separate slices, then Share/receive/DocumentsProvider.
  Test OS kill/restart, grant revocation, unavailable providers and battery
  policy on devices. Keep iOS explicitly unsupported until its own lifecycle
  and provider behavior is verified.
- **BOTH-REV-011, P2: common theme interoperability contract.** Both apps now
  implement editable device palettes and presets. Test copy/paste both ways,
  unknown terminal fields, corrupt individual values, custom surface contrast,
  large fonts and status shapes. Do not request another generic theming system.
- **BOTH-REV-012, P2: authoritative port ledger.** Shared package fixes belong
  upstream; copied UI/storage files need behavioral parity checks and dated
  divergence entries. The two atomic-file helpers have already diverged in
  serialization and fallback behavior. Test cross-repo security contracts
  rather than keeping only a historical copy timestamp.

## Visual inspection and useful product experiments

Current sidebar fixtures were rendered from the checked-out source in light
and dark desktop/compact/phone layouts. Arial/Courier were supplied through the
fixtures' font aliases on this Mac; these are fixture renders, not production
native screenshots or proof of platform interaction. The semantic icon hues,
quiet surfaces, visible endpoints and connected/blocked shape cues already
form a coherent family. Preserve that identity.

- **BOTH-IDEA-001: trust fingerprint sigils.** Deterministic small randomart
  beside the full key fingerprint in trust dialogs and connection details.
  Same key yields the same mark in both apps; changed keys visibly differ.
  Never replace fingerprints or explicit trust decisions with decorative art.
- **PG-IDEA-002: a transfer receipt.** A compact completion summary showing
  where files went, skipped/failed counts, verification mode and retained
  backups, with Reveal and Retry failed. Build on the existing queue/history
  rather than adding a second activity model. Test partial completion and
  background-window attribution; respect disabled-history privacy.
- **PG-IDEA-003: explain this sync row.** An inspectable reason showing source
  and destination metadata, chosen rule and why it creates/replaces/skips.
  Expose the 2-second tolerance and thorough-hash option without burying them
  in settings. Test reasons from the exact immutable plan, including overrides.
- **PG-IDEA-004: ghost landing preview.** While dragging, show a restrained
  destination breadcrumb and Copy/Move/count badge tied to the actual command
  plan. Update on modifiers and spring-loaded folder navigation. No simulated
  progress, extra transfer, animation delay or stale endpoint label.
- **SEA-IDEA-005: last words.** Keep final terminal output visible with the
  disconnect reason and Reconnect/Copy/Save. A dropped connection should leave
  the evidence the user needs. Reconnect is explicit and never replays commands.
- **SEA-IDEA-006: reading anchor.** Show an unread-output count and Jump to live
  while the user reads older output; preserve selection and absolute anchors
  through scrollback trimming and alternate-screen transitions.
- **BOTH-IDEA-007: connection flight recorder.** Opt-in bounded phase timings
  distinguish DNS, TCP, key exchange, auth, listing/PTY and rendering stalls.
  Export a previewed redacted diagnostic bundle without keys, raw commands or
  credentials. It should answer why an operation is slow, not collect telemetry.
- **BOTH-IDEA-008: production wards.** Existing explicit server colors/tags
  gain a small textual production identity in destructive-action dialogs and
  reviewed assistant commands. Do not imply arbitrary PTY input is intercepted.
- **SEA-IDEA-009: command palette.** Reuse Poltergeist's registry principles
  for session/search/snippet/settings commands, showing shortcuts and a clear
  target. Restore focus to the terminal and never execute shell text implicitly.
- **BOTH-IDEA-010: quiet visual polish.** Preserve compact desktop density,
  increase touch affordances only on touch surfaces, keep status words visible
  before truncated endpoints, and preview custom palettes on realistic
  connected/error/selected rows. Avoid extra ornament in the terminal or
  transferring-file rows. Verify high text scale and reduced motion first.

## Validation record before implementation

- Host: macOS; installed Flutter 3.47.3 / Dart 3.13.3. CI pins Flutter 3.47.2.
- Both app analyzers and the reviewed pure-Dart package analyzers were clean.
- Séance packages: 778 tests passed. App: 1079 passed, 2 skipped, 2 failed.
  Both failures were desktop rail capture fixtures failing to locate
  `prod-worker` after a hover; capture with actual fonts is checked separately.
- Poltergeist packages: 1780 passed, 26 skipped, 2 failed. The failures were
  access-time assertions in `local_file_system_test.dart` on this host.
- Poltergeist app baseline was still running when this section was first
  written; its final count is recorded in the consolidated backlog. Failures
  include the platform temp alias `/var` being refused by no-symlink checks.
- Native Windows/Linux/mobile interaction, power-loss durability, real-device
  accessibility and sustained performance are not established by these tests.
- No code changes preceded this review. Implementation starts only after the
  specialist reviews below have been incorporated.
# Poltergeist engine audit, 2026-09-26

Reviewed current `origin/main` at `913ca3da` in `/private/tmp/poltergeist-review-20260926`. This is a read-only source review of the local VFS, transfer queue, sync scanner/differ/executor/journal, and related tests. No application code or tests were written. Findings below are confirmed code-path defects or explicitly labelled investigation work; none is claimed to have been reproduced at runtime yet. The root reviewer is running existing package tests. All paths below are repository-relative.

The foundations are unusually defensive: bounded streaming, exclusive upload temps, pre/post upload conflict checks, queued-task persistence, per-file outcomes, no-follow leaf checks, explicit source/destination error attribution, TOFU integration, delete rails, and journal-backed undo are present. The gaps mostly occur between these individually careful components. Existing safeguards are noted so later work does not remove them.

## PGE-01, P1: Preserve sync backup recovery metadata before attempting the replacement

Evidence: `packages/poltergeist_sync/lib/src/executor.dart:894-908` moves an update's existing destination to trash, then keeps its location/hash/size only in local variables. The replacement transfer starts at line 924. Any later exception is caught by `_runItem` at lines 774-787 and replaced with an empty `_ItemOutcome`; lines 807-809 therefore write no trash mapping. `journal.dart:518-536` builds Restore Trashed Files exclusively from recorded mappings. In contrast, type-replacement pre-deletes immediately append a separate `SyncJournalTrashLine` (`executor.dart:1146-1164`).

Impact: a routine disconnect, cancellation, full destination disk, or failed upload after backup leaves the prior destination absent and its backup invisible to the normal Restore action. A retry then sees the expected destination missing and conflicts. The bytes may still exist under a sequence-prefixed trash name, so this is recovery loss and disappearance from the working path, not a claim that every such failure destroys all copies.

Reproduce: prepare an update with default `backups: trash`; make the destination upload throw after the trash rename; inspect the absent origin, extant backup and journal with no mapping; run `restoreTrashedFiles` and observe no restoration. Repeat with cancellation and with an exception after upload before the item result is journaled.

Change: record a durable standalone trash mapping immediately after backup succeeds and before replacement begins. Avoid recording the same backup twice on success. Preserve restore's post-state checks: completed updates may replace only the version this run wrote; failed updates may restore only into an absent original, never over unrelated later work. Evaluate the narrower crash window between trash rename and mapping separately rather than claiming full write-ahead recovery.

Acceptance: failing regression first, then failed/cancelled update restores the exact old bytes after reopening its journal; successful update has one restore mapping and restores once; recreated origin remains untouched; existing type-replacement restore tests stay green.

**Best first implementation candidate:** tightly scoped, deterministic fault injection, high data-recovery value.

## PGE-02, P1: Reject same-size source changes after sync preview

Evidence: `_verifySource` in `executor.dart:1078-1096` checks only regular-file kind and size. It ignores the preview's `mtimeSecs` and `sha256`. `_verifyDestination` at lines 1020-1044 applies cross-endpoint mtime tolerance and accepted clock shifts to a same-endpoint before/after safety check. `diff.dart:497-505,541-547` computes hashes for comparison but stores the original, unhashed snapshots in the plan, so the executor cannot enforce the content-hash preview either. Existing retry coverage changes the source to a different size (`test/executor_test.dart:1280-1305`), missing the same-size case.

Impact: while the preview is open, edit `first` to `later`; execution quietly copies content that was never reviewed. A same-size destination edit inside the default two-second window can also be overwritten or deleted. Content-hash mode does not close this execution-time gap, despite being the escape hatch for size/mtime ambiguity.

Change: separate endpoint-to-endpoint comparison rules from same-endpoint preconditions. Verify known source mtimes at the endpoint's recorded precision; preserve and enforce preview hashes when captured. Decide explicitly how unreliable/missing mtimes behave and avoid pretending that unchanged size proves unchanged content. Reverify the source snapshot before any destructive backup/removal, and retain the existing in-stream change detection.

Acceptance: same-length changed source becomes `conflicted` without modifying destination, both initially and in Retry Failed; a one-second changed destination is protected; accepted clock shifts do not mask same-side edits; content-hash mode rejects same-size/mtime-preserving changes; unchanged files and clock-unreliable workflows remain usable. Update the safety contract in the plan if changing its currently documented tolerant destination precondition.

**Strong second candidate:** source-mtime validation is a focused initial PR; preserving hashes and tightening destination rules may be a separate, explicitly designed follow-up.

## PGE-03, P1: Flush cross-filesystem sync trash copies before deleting their original

Evidence: `_trashEntry` handles local `LocalCrossDeviceRenameException` by `_transfer` to the trash target and immediate `fs.delete(entry)` (`executor.dart:1361-1382`). There is no file or parent-directory durability barrier. `LocalFileSystem.upload` drains/closes a sink and renames a sibling temp (`local_file_system.dart:648-713`), but does not fsync the final file/directory. The ordinary transfer move path already has precisely this barrier at `transfer_queue.dart:2919-2922`, backed by `flushLocalDestination` at lines 215-230 and D26.

Impact: a user configuring trash on another volume can permanently remove the only durable original while its backup is still only in volatile cache. A crash or power loss can lose both. The existing EXDEV trash test verifies bytes during the running process, not durability ordering.

Change: share or inject the established local durability operation into sync's copy-then-delete path; flush landed file data, then its parent directory, then delete source. If flush fails, retain original and report failure; cleanup must not erase the only known-good copy. Scope remote durability guarantees separately because the VFS currently exposes no remote fsync operation.

Acceptance: operation-log test proves upload -> file fsync -> directory fsync -> delete; injected flush failure never deletes source; normal rename path does not pay a redundant copy barrier; EXDEV integration fixture preserves bytes.

## PGE-04, P1: Revalidate the sync roots and both sides' ancestor chains

Evidence: `_executeItem` calls `_checkParentChain` only for the destination (`executor.dart:831-835`). `_checkParentChain` initializes `current` to the root but starts statting only after appending a child component (`1107-1118`); the root itself is never checked, and a top-level file checks no parent at all. `_verifySource` stats only the leaf (`1083`). `LocalFileSystem.download` refuses a symlink leaf but opens the path through normal ancestor resolution (`local_file_system.dart:547-569`).

Impact: after preview, replacing the destination root with a symlink permits writes/deletes outside the scanned tree. Replacing a source subdirectory with a link can upload an unrelated same-size file from outside the selected source tree. This is a deterministic before-execution swap, not merely a nanosecond TOCTOU argument. Existing descendant destination checks mitigate some cases but miss roots and every source ancestor.

Change: validate the captured canonical root itself and all relevant ancestors on both source and destination, fail as changed-since-preview on a link or non-directory, and apply equivalent checks to restore. Longer term, handle-relative local file operations would close races after validation; do not claim a path-stat fix eliminates all concurrent filesystem races.

Acceptance: swap destination root to link before executing a top-level deletion/copy; swap source `sub` to link before a nested upload; both conflict and leave the outside sentinel untouched. Keep tests for legitimate roots initially opened through a symlink but captured as canonical paths.

## PGE-05, P2: Retain each endpoint's actual filename in a sync plan

Evidence: matching uses NFC/case-folded keys (`compare.dart:31-36` and `diff.dart`), and `_matchedItem` receives distinct `leftPath` and `rightPath`, but every returned `SyncItem` retains only `leftPath` (`diff.dart:541-544`). Execution constructs both source and destination paths using the single `relativePath` (`executor.dart:824-825`). `SyncItem` has no per-side path fields (`plan.dart:366-405`).

Impact: names such as NFC `café.txt` and NFD `cafe\u0301.txt` match in preview but a case-sensitive endpoint is subsequently addressed with the other endpoint's spelling. Updates conflict as missing or read the wrong source. A case-insensitive left side paired with a case-sensitive right side has the same issue for `Readme`/`README`. Directory descendants and type-replacement subtree keys compound it.

Change: model left/right byte-preserving relative paths separately from the logical match/display key, carry them through journal/restore and any manual direction override. Preserve compatibility in saved journal decoding. Do not globally normalize actual I/O paths.

Acceptance: differ-to-executor integration test using two case-sensitive fake filesystems with NFC/NFD names, both directions; mixed case-sensitive/insensitive endpoints; nested directories; restore returns to the actual original spelling and does not create a duplicate.

## PGE-06, P2: Make cross-device trash backups restorable

Evidence: forward trash handles EXDEV with copy-then-delete (`executor.dart:1361-1382`). Undo only calls `fs.rename(entry.trashLocation, origin)` and reports failure (`journal.dart:679-683`). For an update, `_clearOwnPostState` has already removed the run-created origin before that rename. An out-of-root trash path on another local volume is an explicitly supported configuration.

Impact: Restore cannot undo backups deliberately placed on another filesystem. For an update, the current destination can be removed before the predictable reverse EXDEV failure, leaving the live path absent even though its prior version remains in trash.

Change: add reverse copy fallback with exclusive temp, content validation and local durability, arranging replacement so a failed restore does not remove the working current version. Reuse the same safeguards as the forward copy and preserve no-overwrite checks for later user edits.

Acceptance: force EXDEV in both directions; restore deleted file and overwritten file successfully; injected copy/flush failure preserves both the current origin and backup; unrelated post-run origin changes are never overwritten.

## PGE-07, P2: Cancellation must release a sync scan or hash promptly

Evidence: `ScanCancellation` is a boolean only (`scan.dart:35-42`); the scanner awaits a listing signal without racing cancellation (`scan.dart:192-201`). A hung or slow last READDIR prevents Cancel from completing. Hash mode calls `streamedSha256` twice sequentially per pair (`diff.dart:85-92`); this helper takes no cancellation (`compare.dart:142-148`) even though the core digest seam supports transfer cancellation. Cancellation is checked only before the next file.

Impact: Cancel can feel broken during a large remote hash or a server that stalls a listing. SHA mode also spends serial network latency and bandwidth across each file and endpoint.

Change: bridge ScanCancellation to a completion signal and RemoteTransferCancellation, race/dismiss pending listing operations without leaking owned leases, and thread cancellation into digest reads. Consider bounded parallel hashing after prompt cancellation works. The currently pinned listDirectory contract's lack of cancellation is already STATUS item 12; preserve the distinction between UI cancellation and actually closing protocol work.

Acceptance: cancel a never-completing fake listing and a gated digest, settle promptly, perform no later scans/hashes, release leases, ignore late responses safely. Measure a many-file hash scan before choosing parallelism.

## PGE-08, P2: Move synchronous Linux copy syscalls away from the UI isolate

Evidence: D8's bridge addendum says local queue work runs on the UI isolate. Local copies call the Linux FFI `copy_file_range` synchronously for a 16 MiB chunk (`local_copy_pump.dart:195-207`) and yield only after it returns (`231-234`). Six simultaneous queue tasks can each perform this work. The comment's sub-second cancellation assumption is not a guarantee on slow USB, network mounts or congested storage.

Impact: an individual kernel copy can block animation/input/cancellation for the syscall's full duration; async Dart syntax does not make FFI nonblocking. This is a verified architectural risk, with latency magnitude unmeasured on affected hardware.

Change: put local pumps on a worker isolate or move the queue executor engine-side per D8's existing escalation. Keep bounded progress messages, cancellable chunk boundaries, and durable move semantics. Measure slow-volume behavior before claiming performance gains.

Acceptance: deliberately delayed fake/native pump plus UI timer/frame probe proves no UI stall; cancellation latency bounded between worker chunks; large-file throughput no worse than the agreed budget. Re-run D8's real bridge budgets, which the decision log already leaves open.

## Focused backlog to consolidate with existing STATUS/ANALYSIS

- **Expose Verify after transfer.** D7 promises an opt-in, but ordinary `_runFile` invokes `_pipe` without `computeHash` (`transfer_queue.dart:2814-2830`), whose default is false, local fast copies have no verification option, and task/settings models provide no bulk verification knob. Add a clearly explained per-task/default option, compare actual landed content rather than merely calculating an outgoing digest, journal verification failures, and never delete a move source until verification succeeds. Test corruption via a destination fake and both local/remote paths.
- **Ship trash retention and purge UI.** Existing STATUS item 27 (`docs/STATUS.md:9664`) is still material: trash and journals otherwise accumulate indefinitely. Add an age/size notice with previewable confirmed purge, running-run exclusion and origin-aware retention; never silently expire recovery data.
- **Warn before backups land under web docroots.** Existing STATUS item 28 (`docs/STATUS.md:9678`) records that in-root backup files may remain HTTP-retrievable. Add pair-editor and plan warnings with one-click out-of-root selection; don't infer that 0700 prevents access by a web server running as the same account. Test common docroot shapes and custom/out-of-root paths.
- **Make interrupted sync recovery a real workflow.** Existing STATUS item 29 (`docs/STATUS.md:9688`) acknowledges absent startup temp sweeping and no resume API. Add explicit interrupted-run history, bounded conservative cleanup, and journal post-state reconciliation; a committed-but-unjournaled file must not be overwritten blindly. Include kill-at-each-commit-boundary tests.
- **Novel but practical: Recovery drawer.** A single pane lists interrupted syncs, unavailable backup mappings, leftover upload temps, dirty editor checkouts and trash usage, with safe actions and exact original paths. Use existing journals; avoid silently moving or deleting anything. This turns the application's strongest safety mechanisms into discoverable user value.

## Lower-confidence follow-ups, not confirmed defects

- Queue `_postCommit` deletes the source after metadata/fsync work without rechecking the post-download source (`transfer_queue.dart:2901-2924`). A source changed during that interval could be unlinked. Add a deterministic mutation seam test before deciding which snapshot/hash should authorize delete, and review the same issue in sync trash copy fallback.
- `_normalizeRoots` only checks a new root against already-kept roots (`transfer_queue.dart:5062-5100`), so child-before-parent input is not actually deduplicated. UI usually supplies siblings; inspect all enqueue callers and add order-independent normalization if arbitrary OS drop payloads can contain both.
- Drag self-containment is a lexical app-layer guard (`pane_drop.dart:190-235`) and explicitly leaves case-insensitive APFS knowledge open. The core queue has self-move equality checks but no general canonical ancestor rejection. Investigate folder-copy destinations reached through aliases/symlinks before claiming recursive growth is reachable from current UI.

## Scope and validation limits

No other models' PRs were inspected or touched. No code has been changed. macOS/Windows/Linux live SFTP, native storage failure, power-loss, and UI responsiveness experiments were not performed in this audit. The report distinguishes source-established missing guards from hardware-dependent impact and deferred-feature contracts. The strongest immediate patches are PGE-01 and the focused source-mtime part of PGE-02; PGE-03 is also compact and important, while per-side path identity and full crash recovery deserve dedicated design/test work.
# Séance security, stability and core review

Read-only review of `dd7e105` in `/private/tmp/seance-review-20260926`, 2026-09-26. This report was written before implementation. No code or tests were changed for this review. Evidence below is static source inspection, not a claim of a live exploit or device reproduction. The root reviewer independently ran the baseline package analyzer and all 778 package tests successfully.

The core has useful safeguards already: explicit TOFU approval, constant-time verifier comparison, Argon2 resource ceilings and an app strength floor, domain-separated authentication/encryption keys, XChaCha20-Poly1305 payload sealing, bounded server request/blob/push sizes, transactional record pushes and consistent SQLite pulls, generation-guarded assistant replies, independent secret timestamps, durable config/snippet deletion intents, and a recoverable vault re-key journal. The remaining risks cluster at the boundaries between those mechanisms.

## Recommended bounded implementation slices

1. **P1: redact quoted JSON and complete quoted assignment values.** Strongest small privacy fix. Start with `packages/seance_core/lib/src/llm/redaction.dart:38-42`, add failing redactor and chat request tests, preserve current assignment/token/PEM behavior and the explicit disable switch. Details SEA26-SEC-01 below.
2. **P1: make SQLite account deletion atomic.** Wrap the existing four deletes in the existing `_transaction(_TransactionMode.write, ...)`, add trigger-injected failures at every delete and cross-connection contention tests, confirm successful deletion removes all rows and invalidates the token. The broader account lifecycle and plaintext-token work remains separate. Details SEA26-SEC-06 below. A narrowly scoped deletion PR must not claim to solve concurrent login/create-token races or revocation.

An alternative second slice is separating JSON I/O failures from corrupt content; that touches more client stores but addresses a direct data-safety risk.

## Findings

### SEA26-SEC-01: quoted secret fields bypass default redaction (P1, confirmed)

**Evidence:** `packages/seance_core/lib/src/llm/redaction.dart:38-42` allows a quote before the value but none after a key, so `{"password":"correct-horse-battery"}` and `{"token":"opaque-token-material"}` do not match. Its value stops at whitespace even inside quotes, so `password="two secret words"` is not safely covered as a whole. `chat_controller.dart:143-157` uses this redactor for both terminal context and typed messages; the same reusable filter also guards command capture.

**Reproduction:** feed JSON password/token/API-key fields to `SecretRedactor.redact`, then a `ChatController.send` with those values as terminal context and inspect the fake provider messages. The quoted-key cases leave the full value intact. Use synthetic strings only.

**Fix scope:** recognize existing secret-key vocabulary when quoted in JSON/YAML-style assignments; consume complete quoted values including spaces and escaped quotes; preserve the surrounding key/structure where practical. Keep the filter explicitly best-effort and avoid claiming regex guarantees against every credential format.

**Acceptance:** quoted/unquoted keys, mixed case, nested JSON, escaped quotes/backslashes, Unicode, spaces, several adjacent fields, short secrets, malformed/truncated quoted input, existing shell assignments, PEM/provider-key cases and benign prose. Integration assertion: provider payload contains no synthetic sensitive value when redaction is enabled, and explicit disable still passes through. Bound matching work on large adversarial text.

### SEA26-SEC-02: encrypted sync payloads do not authenticate their routing/version/deletion envelope (P0, confirmed; consolidates SOL-011/012)

**Evidence:** `packages/seance_protocol/lib/src/records/record_codec.dart:26-39,43-60` seals only `{kind,data}` and accepts `deleted` or an empty blob without decrypting. `record.dart:155-163` defaults a missing blob to empty and truncates numeric fields. A server can replay a valid older ciphertext under a newer outer timestamp, or forge config/snippet deletions. Payload-ID checks in `sync_coordinator.dart:615-629,633-648,657-669` now block several transplant cases and must be preserved; they do not authenticate envelope freshness/deletion. Config/snippet deletes are honored at `:543-568,598-603`; secret/host-key tombstones are intentionally refused.

**Fix scope:** version the wire envelope; AEAD-authenticate client-controlled identity, kind, revision, time, device, key epoch, schema/purpose and deletion intent, excluding server cursor. Typed encrypted tombstones, migration fixtures, compatibility readers, explicit old-client policy. Coordinate with Poltergeist. Add opaque HMAC-derived wire IDs in this migration: current `hostkey:<host>:<port>` reveals hostnames despite documentation claiming the server cannot identify record kinds.

**Acceptance:** field-by-field tamper, payload transplant, old-ciphertext replay with winning metadata, fabricated empty blob/tombstone, cross-purpose swaps, legacy reader/writer interactions, rollback and interrupted migration. Distinguish authenticity from freshness: binding fields alone does not prevent replay without a trusted monotonic client history.

### SEA26-SEC-03: sync silently replaces established SSH trust (P0, confirmed; AST-008/SOL-023 still live)

**Evidence:** `packages/seance_core/lib/src/sync/sync_coordinator.dart:632-650` validates locator and exclusion but unconditionally calls `hostKeyStore.put(pin)`. `TofuVerifier.check` trusts a matching stored fingerprint (`hostkey/tofu.dart:43-58`). A newer pin from another device changes local trust without the changed-host-key dialog; unauthenticated outer versions increase the replay risk above.

**Reproduction:** seed local endpoint fingerprint A; apply a valid encrypted newer fingerprint B for that endpoint; subsequent check of B is trusted without review.

**Fix scope:** preserve established local pins, persist a conflict record with both fingerprints and origins, surface explicit resolution, and issue a newer durable revision when resolved. Do not silently skip conflicting records while reporting successful convergence. Normalize endpoint identity consistently, with a migration for existing aliases.

**Acceptance:** same/new/conflicting pins, device restart, user resolution, repeat sync, equivalent DNS spellings, IPv4/IPv6, both sibling clients. Pending conflict must remain visible until resolved.

### SEA26-SEC-04: approval of a stale TOFU dialog can overwrite a newer decision (P1, confirmed)

**Evidence:** `packages/seance_core/lib/src/ssh/ssh_session.dart:127-133` checks, awaits a dialog, then pins without verifying the current stored key. `hostkey/tofu.dart:61-62` is an unconditional put. Two first-use or changed-key dialogs for one endpoint can approve different keys in opposite order. Delayed approval can also persist trust after connection timeout because the prompt itself is not cancelled.

**Fix scope:** endpoint-scoped trust transaction/CAS comparing the key that was actually presented in the dialog; shared coordination with sync trust decisions. Return a stale-decision result and redisplay current evidence, never auto-approve a replacement.

**Acceptance:** two completions in both orders, unchanged same-key approval, concurrent sync update, cancellation/timeout while dialog is visible. Only the current explicit decision persists.

### SEA26-SEC-05: permanent plaintext bearer tokens make database leaks active account compromise (P0/P1, confirmed; SOL-048)

**Evidence:** `packages/seance_sync_server/lib/src/sqlite_storage.dart:44-49,113-124` stores and looks up raw bearer tokens; no expiry or revoke endpoints exist. `server.dart:217-220` permits total account deletion with that bearer alone. E2E encryption protects plaintext confidentiality, not destructive API access or server-side impersonation.

**Fix scope:** hash tokens at rest, migrate/rotate existing sessions, expiration, bounded sessions per account, revoke current/all/device sessions, recent verification for destructive account deletion. Correct the breach-tolerant claims until this and authenticated envelopes are complete.

**Acceptance:** raw DB/backups contain no live usable token; expired/revoked tokens fail; migration does not strand clients silently; deletion requires fresh intent/auth; race tests do not resurrect accounts.

### SEA26-SEC-06: partial account deletion leaves inconsistent, potentially accessible state (P1, confirmed; SOL-051 slice)

**Evidence:** `packages/seance_sync_server/lib/src/sqlite_storage.dart:105-109` executes four independent deletes. Failure after deleting `accounts` can leave `tokens`, `records` and/or `seqs`. `usernameForToken` at `:121-124` looks only at tokens, so a leftover token can still authorize API access despite absent account. `_transaction` at `:163-186` already provides rollback and busy handling for record operations and is reusable.

**Reproduction:** install SQLite `BEFORE DELETE` trigger on `tokens` or `records` that raises abort, call `deleteAccount`, verify account disappeared while other state remains. This is a deterministic failure injection, not a speculative concurrency concern.

**Fix scope:** atomic deletion of all account state using the existing write transaction. Separately make token lookup require a live account and token creation fail if it was deleted; registration should atomically create-or-conflict account/sequence/initial token. The server's await boundaries mean transactionally deleting alone cannot solve a login that fetched an account before deletion and creates a new token afterward.

**Acceptance:** trigger failures at every delete retain the original entire account; success removes all four stores and old tokens fail; contention returns the existing structured 503 with no partial mutation; subsequent successful retry works. Add dedicated delayed-storage login/delete tests for the broader lifecycle slice.

### SEA26-SEC-07: missing master key is treated as a new installation (P0, confirmed; SOL-031)

**Evidence:** `app/seance_app/lib/services/secure_master_key.dart:94-104` creates a replacement whenever the keystore returns null. `app_services.dart:166-171` probes before loading the existing vault. The journal protects re-key interruptions, but a genuinely lost key produces a new key that cannot open existing ordinary vault entries.

**Fix scope:** decide empty-install versus encrypted-data-present before key creation; represent key lost/locked/available separately. Retain ciphertext and recovery journal and require restore/unlock action. Validate decoded key length before marking it available.

**Acceptance:** existing vault + missing key never writes a new key or clears data; genuinely empty first run does; keystore inaccessible vs missing vs malformed is distinguishable; signed Apple and Android restore fixtures. Recovery UI must preserve the only remaining encrypted copy.

### SEA26-SEC-08: enrollment is not one recoverable account/key transition (P0, confirmed; residual SOL-030)

**Evidence:** `app_services.dart:450-454,504-508` commits new URL/username and token before `_rekeyVault`. A refused re-key leaves the app pointing at the new account while still holding the old local vault key. A later automatic sync can publish local records under the wrong account encryption key. The local vault re-key itself is now staged and recoverable at `:312-338`; do not describe the old per-secret overwrite bug as current.

**Fix scope:** journal enrollment/account identity, token, old/new key and local vault generations as one recoverable workflow; block sync while transition is unresolved. Establish encrypted key-confirmation metadata for empty accounts: current login checks one existing nondeleted payload (`:491-502`) and cannot verify the encryption passphrase when no such payload exists.

**Acceptance:** inject failure at account creation, settings write, token write, journal stage, keystore write and vault promotion; restart each time; the app operates fully against the old account/key or new account/key and never a mixed pair. Wrong encryption passphrase on an empty account should not seed a second incompatible key population.

### SEA26-SEC-09: I/O errors are quarantined as corruption and replaced by empty stores (P1, confirmed; SOL-034 residual)

**Evidence:** `app/seance_app/lib/services/file_stores.dart:24-35` config, `:84-94` snippets, `:308-314` vault, `:543-552` host keys catch both `readAsString` errors and parsing errors. `atomic_file.dart:81-87` removes a previous `.corrupt` backup, renames the current file, swallows failures. Transient I/O or permission failures therefore become apparently empty durable state and may erase the useful prior quarantine copy. `app_settings.dart:517-530` has the same classification issue.

**Fix scope:** separate filesystem reads from decoding/schema validation; propagate actionable transient storage failures and permit retry; quarantine only validated malformed content using unique retained recovery files. Preserve all unaffected valid records or fail closed where partial data would weaken trust. In-memory caches must not commit writes/deletes before persistence succeeds.

**Acceptance:** fail-injected file read/stat/rename/write, permission denial and disk-full cases never silently become empty, never quarantine good state, and retry works; malformed content still has a recovery path; failed save keeps memory and disk consistent. Check vault, trust, config, snippets, tombstones and settings uniformly.

### SEA26-SEC-10: Windows atomic replacement still deletes the only destination on any rename failure (P1, confirmed; SOL-034 residual)

**Evidence:** `atomic_file.dart:66-74` catches every Windows `FileSystemException`, removes destination, then retries. An unrelated first rename failure is sufficient to enter a destructive fallback; second failure leaves the destination absent. Process-local path serialization now exists (`:33-52`) but does not protect multiple processes or filesystem aliases.

**Fix scope:** use a Windows atomic replace implementation behind the persistence service or retain recoverable backup/journal through all replacement steps; narrow error classification; add an app-support process lock before caches load. Preserve the current process-local queue.

**Acceptance:** Windows fixture with access-denied/sharing violation/second rename failure keeps original or recoverable new state; concurrent processes cannot overwrite stale caches; crash at each stage is recoverable. Compilation on Windows alone is insufficient.

### SEA26-SEC-11: sync mirror is rebuilt and acknowledgements do not identify the sent revision (P1, confirmed architecture; SOL-001/005/006/010/037/059 residual)

**Evidence:** `app_services.dart:554-564` constructs a new `InMemoryLocalRecordStore` each run; `sync_coordinator.dart:150-181` re-encrypts all published values and attributes them to the current device. `sync_engine.dart:119-123` marks IDs synced from server response, while `local_record_store.dart:56-59` clears whichever current value has that ID. Unknown/duplicate/omitted acknowledgement IDs are not checked. `SyncOutcome` reports only counts after max rounds.

**Mitigations:** app saves/deletes/manual/timer sync now serialize through `_mutate` (`app_state.dart:1524-1566`), so the old claim that manual sync interleaves with local edits is stale at this app entry point. Core embedding clients still lack exact revision protection. Config/snippet deletes now persist intents and secrets have independent timestamps.

**Fix scope:** durable account-scoped operation ledger/cursor with exact sent-operation acknowledgements; authenticate revisions in the envelope migration; preserve origin until a local edit; observable pending/conflict outcome; one batched apply transaction. Fetch network data outside the app mutation queue, recheck/merge under the queue.

**Acceptance:** blocked push then new local edit stays dirty, missing/duplicate/foreign acknowledgement fails safely, unchanged second run pushes nothing, restart preserves cursor/tombstones, account switch isolates ledger. Slow sync must not stall unrelated saves for its full sequence of requests. The current request timeout prevents an infinite dead-network hang but slow successful batches can keep the queue occupied much longer.

### SEA26-SEC-12: normal SSH shell acquisition has no deadline/cancellation (P1, confirmed residual)

**Evidence:** `packages/seance_core/lib/src/ssh/ssh_session.dart:1008-1013` now bounds handshake/authentication at five minutes, but `:1205-1207` awaits `client.shell` with no timeout. A server that authenticates then never answers channel/PTY/shell requests leaves the connection attempt indefinitely pending. SFTP opening and remote-command execution have separate deadlines and cleanup; those are not proof that terminal shell acquisition is bounded.

**Fix scope:** phase-specific cancellable lifecycle owning socket, jump parents, authenticated client, channel and engine; sensible network deadline for shell acquisition separate from user-interactive authentication time. Dispose late-acquired channels after cancellation.

**Acceptance:** authenticated fake peer stalls each channel/PTY/shell phase; timeout/cancel closes ownership tree and cannot commit a late session; immediate remote close still drains final output and marks disconnected; retries work. Keep current remote-output drain/cleanup tests.

### SEA26-SEC-13: assistant conversation remains shared and unbounded (P1/P2, confirmed residual)

**Evidence:** `app_state.dart:477` holds one `ChatSession` for all SSH sessions; `chat_controller.dart:105,156-157,173,240` grows history without byte/token budget. Every turn resends that history. `chat_sidebar.dart:66-85` correctly captures the originating terminal and rejects stale/disconnected targets now; `chat_controller.dart:154-166` correctly keeps terminal snapshots out of persistent history; reset generation guards at `:310-320` exist. Retained user messages, assistant replies and tool-result content still cross host context.

**Fix scope:** session-scoped conversations with deliberate global mode, bounded history by tokens/bytes, visible current target, independent Stop/Retry and streaming. Keep context opt-in choice across drawer rebuilds: `_includeContext = true` is widget state (`chat_sidebar.dart:23`), so dismissing a narrow-layout drawer resets a user's unchecked choice to true.

**Acceptance:** two hosts cannot inherit each other's conversation unexpectedly; 1,000 turns remain bounded and deterministic; drawer close/reopen preserves context privacy setting; reset/dispose stops side effects and no late reply targets another session. Do not regress the existing originating-session guard.

### SEA26-SEC-14: native tool semantics and outbound receipts are incomplete (P1/P2, confirmed; SOL-042/044/045)

**Evidence:** `chat_controller.dart:213-240` serializes tool results as an ordinary user message and does not retain native call IDs; `openai_provider.dart:40-44` serializes only role/content. `ChatResult.sent` captures current input/query strings but omits full history, model response text and search results; the sidebar does not present it. Search snippets/title/URL are now bounded in `chat_controller.dart:245-307`, but no final redaction pass covers tool-result strings or prior assistant content.

**Fix scope:** typed provider-neutral assistant tool calls/results, correct native request serialization, untrusted search-result boundaries, final outbound redaction and an exact serialized-payload receipt. Display target/provider/endpoint, redaction summary and search destinations before/after send. Inspect `paste_to_prompt` as an explicit staged suggestion: the current API promises no automatic execution but immediately injects into any active remote program, which need not be a shell prompt.

**Acceptance:** second-request wire fixtures for both providers, missing/invalid tool IDs/arguments, injected search instructions, matched payload/receipt equality, recognizable secrets in search results and model echoes, non-shell terminal modes. Preserve the strict no-CR/LF/control sanitization and bounded tool loop; a regex danger classifier is advisory, not a security boundary.

### SEA26-SEC-15: network resources and payload sizes remain unevenly bounded (P2, confirmed risk; SOL-058 residual)

**Evidence:** `openai_provider.dart:18-26,95-106,143-148` creates a client without a close method; `.timeout` wraps full requests but does not cancel underlying work, and streaming only times out header acquisition. `search.dart:29-35,43-48,66-73,79-87` has the same ownership/full-body pattern. Five LLM/search implementations use this shape. `HttpSyncClient` does close owned clients (`http_sync_client.dart:34-40`) and all app sync actions use finally-close (`app_services.dart:584-594`), but pulls still buffer/decode full bodies.

**Fix scope:** ownership-aware close on interfaces and app lifecycle, cancellation on replacement/reset/dispose, streamed byte caps plus connect/total/idle deadlines. Preserve caller ownership of injected clients. Z.AI already has stricter body limits; reuse concepts without weakening them.

**Acceptance:** stalled headers/body/SSE, oversized/malformed response, repeated model/settings changes, reset while blocked, error bodies with secrets; sockets close and no late PTY effects. Memory stays bounded before parsing, not just after search-result clipping.

### SEA26-SEC-16: server quotas, parsing and operational lifecycle remain unfinished (P1/P2, confirmed; SOL-049/050/051/052/053/054/055)

**Evidence:** `server.dart:79-116` registration has no source-IP/account creation throttle; `:148-149` login limits username only. `rate_limiter.dart:19,62-65` has no live-bucket cap, so active unique-name spray grows memory despite expired pruning. `server.dart:120-126` casts the prelogin username outside validation, yielding 500 for a numeric username. `sqlite_storage.dart:262-271` materializes all records; no total account quota or pull pagination. Register accepts arbitrary decoded verifier length and unvalidated salt encoding (`server.dart:101-114`). Liveness checks only return `ok` (`:36`).

**Fix scope:** independent bounded source/account limits with trusted-proxy policy, account/token/record/byte quotas, strict wire parsing (integral/range-limited revisions, 16-byte salt and 32-byte verifier policy), stable pagination, versioned schema, transactionally created accounts, readiness, graceful signal drain and sanitized request/error telemetry. Use online WAL-aware backup/restore procedures.

**Acceptance:** source spray, deliberate victim-username lockout, simultaneous quota edges, malformed prelogin 4xx, oversized account bounded memory, record mutation between pages, DB failure readiness false, SIGTERM under load and restore with live WAL. Existing transactional record push/pull and 8 MiB request/1 MiB blob limits are real mitigations.

## Verified stale backlog clauses to replace, not repeat

These are exact claims from existing `ANALYSIS.md` that should be retired or narrowed when consolidating. Preserve source history in an archive and keep residual tasks under their stable IDs.

| Existing claim | Current evidence and replacement |
|---|---|
| SOL-001 group: “Hard deletes emit no tombstone” | App deletes now use `FileTombstoneStore`; `app_state.dart:929-984,1461-1490`, `sync_coordinator.dart:69-75,184+`. Keep authenticated typed tombstones, opt-out semantics, durable full ledger and exact revisions. |
| Same group: “secrets borrow server timestamps” | `sync_coordinator.dart:158-181` publishes each credential at `secret.updatedAt`; `SecretVault.putLocalSecret` advances independent version. Retain legacy-client compatibility warning. |
| Same group: “Manual sync bypasses the automatic run guard” | `_runSyncAndRefresh` joins the common `_mutate` queue (`app_state.dart:1524-1566`). Replace with slow fetch blocking the mutation queue and core-level exact revision gaps. |
| SOL-030: “overwrites secrets one by one, migrates only currently referenced secrets, and changes memory before keystore persistence” | Whole-vault staged journal including orphans and late adoption now implemented: `file_stores.dart:472-529`, `app_services.dart:312-338`; extensive `vault_rekey_test.dart` exists. Keep enrollment/account transaction and genuinely lost-key recovery tasks. |
| SOL-034: “Writers share <file>.tmp; parallel writes can replace each other's data” | `atomic_file.dart:33-52` now queues same-path writes within the process. Retain cross-process lock, read/classification/cache failure handling, Windows fallback and symlink-alias boundaries. |
| SOL-038: “ChatController.send stores terminal context in history despite its turn-only comment” | Fixed at `chat_controller.dart:154-166`: only redacted user text persists and context attaches to the current provider calls. Keep shared cross-session conversation and unbounded history. |
| SOL-038: “reset can race late results” | Generation checks after provider/search and before tools plus `ChatSession.isCurrentTurn` now guard replies/staging. Retain transport cancellation and resource lifetime work; do not reimplement result guards. |
| SOL-020 connection deadlines as blanket missing | Authentication now bounded at five minutes; keep shell-opening deadline/cancellation specifically (`ssh_session.dart:1205-1207`). |
| SOL-021: “add a compatible typed challenge carrying prompt text ... identity” | `KeyboardInteractiveChallenge` now includes `server`, prompts, name, instruction (`ssh_session.dart:93-109`); retain echo policy, explicit cancellation and platform focus/autofill verification. |
| SOL-028 agent/jump hosts missing | SSH agent protocol adapters, Unix/Windows transport, saved jump-host resolver and chained connection ownership exist (`ssh_agent.dart`, `ssh_session.dart:690-815`). Retain port-forward UI and unverified live platform integration; inspect import parity separately. |
| AST-008/SOL-023 silently replaced host pins | **Still current**, do not move to completion merely because payload locator checks were added. `sync_coordinator.dart:650` is unconditional. |
| SOL-031 missing keystore key | **Still current**, independent of the completed re-key journal. |
| SOL-048 plaintext tokens | **Still current**. |

## Product ideas grounded in the risks

- **Connection passport:** a compact per-host sheet with local pin, observed fingerprint, approval date/device, jump route and unresolved sync trust changes. Copyable redacted diagnostics make SSH failures easier to act on without exposing raw trace material.
- **Whisper switch:** one visible session-local control disabling outgoing terminal context and command-history capture, persisting across drawer/layout changes. Show what it suppresses; do not pretend regex can recognize arbitrary no-echo passwords.
- **Outbound receipt:** a collapsible assistant turn card listing the actual endpoint/model, terminal block selection, searches sent and exact redacted payload. Allow one-click reuse of a saved narrow context choice.
- **Sync health, not just a spinner:** show “all devices caught up,” queued operations, trust conflicts, skipped undecodable records and recovery actions. Retain local edits and durable backup/export until authenticated sync semantics are complete.
- **Connection phase timeline:** DNS/TCP, each jump, trust approval, authentication and shell acquisition with cancel/retry and bounded diagnostics. Do not show a permanent undifferentiated connecting state when a shell channel is stalled.

## Validation limits

This review did not operate live SSH/SFTP hosts, inspect other models' PRs, test signed mobile keystores, validate Windows named-pipe behavior on Windows, run a physical Android/iOS device, measure frame times or collect native interface screenshots. Compile/test coverage cannot replace those checks. The suggested fixes require failing regression tests before implementation; this report records static confidence and specific reproducible seams so the next agent can perform that work.
# Sibling UI, accessibility and product audit

Read-only assessment on 2026-09-26. Poltergeist baseline: `913ca3da32b168fd0f8b480032e495666d5cc9f2`; Séance baseline: `dd7e1059597c613e727c2c64f116332f945384e1`. Paths below are repository-relative and identify the app explicitly. No source or test files changed. I inspected code, existing test coverage, product decisions, status, and four committed rendered screenshots. I did not launch either native app, test native assistive technology, or render new captures. Findings marked static need the prescribed regression/reproduction before being represented as runtime-verified.

## Strongest bounded implementation candidates

### UI-01 · P1 · Poltergeist delete dialog can pop another route and leaves counting work uncancelled

Evidence: `app/poltergeist_app/lib/ui/shell/delete_confirm_dialog.dart:85-108` and `:257-265`. `_run` awaits `prepare`, checks only `mounted`, and pops the current navigator when the result is null. `_cancel` and the confirmation callback also pop without an idempotence/current-route guard. The state has no dispose cancellation. Flutter keeps the dialog state mounted through its reverse animation. A second activation or a cancelled prepare resolving null during that animation can therefore pop the route underneath; a callback from a covered dialog can answer a newer route. System Back dismisses the route without calling `_cancel`, so its counting walk continues.

Reproduction: put the dialog above a pushed sentinel page; activate Cancel twice before the exit animation completes, or cancel then complete `prepare` with null; verify the sentinel remains. Cover the dialog with another route and invoke a saved old callback; the new route must remain. Pop via Back while preparation is blocked and observe the cancellation token. Static control-flow finding, not yet exercised in a new test.

Scope: centralize idempotent current-route completion, cancel preparation on disposal/back, ignore late prepare results after dismissal. Preserve explicit trash/permanent disposition and Cancel as the destructive default. Existing sibling precedent is Séance `ui/host_key_dialog.dart:21-28` and `ui/keyboard_interactive_dialog.dart:63-69`.

Gate: failure-first widget regressions for repeated Cancel/Confirm, null preparation during dismissal, obscured route, system Back, teardown, and existing delete wording/disposition/command tests. This is the best bounded safety fix from this audit.

### UI-02 · P2 · Séance pane resizing excludes keyboard and assistive-technology users

Evidence: `app/seance_app/lib/ui/adaptive_shell.dart:392-419`. `_ResizeHandle` is a `MouseRegion`/`GestureDetector` with no focus target, key handling, semantic label/value or increase/decrease actions. Width persistence now exists (`:48-56`, `:364-384`), so the old backlog claim that pane widths do not persist is obsolete.

Reproduction: tab through a wide layout or inspect semantics; neither divider is an adjustable control. A keyboard-only user cannot reclaim terminal space from either sidebar.

Scope: focusable labelled dividers, visible focused state, left/right arrows in predictable steps, assistive increase/decrease, current clamped width and bounds. Reuse Poltergeist's established interaction contract (`ui/shell/shell_splitter.dart:15-168`), adapted to Séance's existing allocator and persistence boundary, rather than importing the entire shell. Consider Home/reset only if discoverable and tested. Preserve drag/clamp behavior and terminal minimum width. Handle RTL geometrically, not by assuming the list is always on the left.

Gate: keyboard/semantics tests at minimum and maximum widths, both splitters, clamp after window shrink, one persistence callback per action, existing drag tests, visible focus and native VoiceOver/NVDA follow-up. This is the best bounded accessibility fix.

## Other confirmed gaps and targeted follow-ups

### UI-03 · P2 · Séance's mobile terminal controls are below comfortable touch targets

Evidence: `app/seance_app/lib/ui/terminal_keyboard_bar.dart:34-45` fixes the deck to 46 dp and gives the scrolling keys 6 dp vertical padding each side, leaving a 34 dp hit height; `:176-190` uses 40 dp minimum width. Session strip is 38 dp high (`ui/terminal_pane.dart:355`, `:447`, `:462`, `:635`), including New tab/Generate command and close controls. This is measured from constraints, not a physical-device usability study.

Scope: on touch platforms retain compact-looking keycaps inside 48 dp hit regions; allow scaled labels to grow the deck. Keep terminal keyboard focus, one-shot Ctrl, DECCKM-sensitive arrows and horizontal access to all keys. Touch-specific session-strip sizing should be a separate small change from key deck sizing.

Gate: Flutter tap-target guideline test, TalkBack labels/toggle state, 320/360 dp widths at 1×/2× text with keyboard open, `terminal_keyboard_bar_test.dart`, cursor-mode tests, no accidental double sends. Leave desktop density intact.

### UI-04 · P2 · Both toast stacks are unbounded, unannounced and expire even when their action is hard to reach

Evidence in both `app/<app>_app/lib/ui/top_toast.dart`: `:85-113` appends every notice; `:125-146` builds all cards in a non-scrolling unconstrained Column; `:170-174` unconditionally starts an expiry timer; the render subtree has no live-region semantics, and custom backgrounds force white text (Séance `:199-204`, Poltergeist `:198-206`). A burst can cover the workspace or exceed viewport height. A screen-reader user may never discover a failure/retry/undo notice before it disappears. Custom backgrounds can produce unreadable text if they are light.

Scope: a shared bounded notice policy, with a small visible limit and retained overflow/history where available; live-region announcements with duplicate coalescing; pause/action persistence while focused or under accessible-navigation mode; composited contrast-aware foreground. Keep notices at the top so they do not cover the shell prompt. Persist safety/recovery incidents in an appropriate panel rather than relying on a toast.

Gate: burst of 20 notices in a 320×568 viewport at 2× text, no overflow, action invoked once, announcement semantics, accessible-navigation expiry policy, focus retention and reduced motion. Update both copies and the port ledger. Existing top-toast tests do not substitute for native announcement validation.

### UI-05 · P1 accessibility/platform backlog · Extra Poltergeist macOS windows deliberately emit no semantics

Evidence: `app/poltergeist_app/lib/ui/workspace_windows_root.dart:91-107` wraps secondary macOS views in `_SemanticsSilentView`; the code explains the embedder otherwise overwrites the main window's accessibility tree. `docs/STATUS.md:9749` records this and related D39 gaps. This is an acknowledged shipping limitation, not a newly introduced regression.

Impact: a secondary workspace can be visible and keyboard-operable yet have no accessible tree for VoiceOver or other accessibility clients. Do not describe multi-window support as assistive-technology complete.

Scope: first establish a minimal multi-view semantics reproducer with the pinned Flutter embedder. Route updates by view in a focused upstream/native patch or supported engine update, then remove the suppression only after verifying both windows. Until then, expose an honest accessible alternative that brings content into the main window. Preserve the workaround rather than blindly deleting it.

Gate: two macOS windows with distinct controls; VoiceOver independently enumerates and activates each, closing/hiding one does not corrupt the other tree. Native test required. Track separately: secondary-window drop-in/out, Quick Look, toolbar, taskbar progress, geometry and unique titles, all already listed under D39.

### UI-06 · P2 · Poltergeist phone transfer destination is encoded as A/B instead of the target folder

Evidence: `app/poltergeist_app/lib/ui/compact/compact_selection_bar.dart:52-61`, `:76-77`, `:116-143`; buttons read Copy to B / Move to B while only pane A is visible. `compact_pane_switcher.dart:14-18` exposes the alternate pane as one toggle. The model is coherent, but users must remember the hidden pane's host and folder before committing a potentially destructive operation. This is a product-safety opportunity, not proof of an incorrect transfer.

Scope: a compact destination summary above the action bar, e.g. `To production.example · /srv/site`, derived from the same immutable target snapshot used by the command. Let tapping it inspect/change the destination; show a clear unavailable reason. Consider an explicit review for moves to another host, without nagging for every ordinary copy. Long targets need middle ellipsis, full semantics and a reveal affordance.

Gate: pane B changed while selection is active, remote reconnect, target tab closed, both local and remote endpoints, RTL/2× text, and target attribution under queued work. The actual queued target must match the summary shown at activation.

### UI-07 · P1 cross-platform product gap · Android file utility and reliable background transfers remain incomplete

Evidence: Poltergeist `docs/STATUS.md:9736-9748` explicitly records local storage limited to the app's own directory, no share-to-upload intent, no selection Share, no transfer foreground service, and no DocumentsProvider, while Android is a supported release target. `compact_selection_bar.dart:60-62` acknowledges Share is absent. A build succeeding on Android does not establish a useful daily transfer app if users cannot select their documents or a backgrounded transfer stops.

Scope, separate PRs: (1) SAF/document-provider imports/exports with persisted permissions and no assumption that content URIs are stable POSIX paths; (2) selection Share with completed bytes/explicit download and temporary-file lifetime; (3) foreground transfer ownership/progress/cancellation and resumable recovery semantics; (4) share-to-Poltergeist explicit destination flow. A DocumentsProvider is a later larger capability. Avoid requesting broad all-files access when SAF fulfills the workflow.

Gate: real device with downloads, removable and cloud-provider documents, revoked grants, process kill/background freeze, low storage, cancellation, duplicate names and restart recovery. Device/OEM evidence required, not just compiled APKs. Séance already has foreground-session support; validate and reuse appropriate lifecycle lessons, not its terminal policy unchanged.

### UI-08 · P2 validation task · Scaled text must drive chrome height, not just row height

Evidence: Poltergeist compact listing explicitly scales row extent, but `compact_breadcrumbs.dart:143-155` fixes each visual crumb to 32 dp and its row to 48; `compact_pane_switcher.dart:39-48` fixes letter discs to 28. Séance `ui/sidebar_panel.dart:165-180` fixes icon-plus-label tabs to 52 dp, and session tabs to 38 dp. Long/translated text is ellipsized but a fixed height can still clip scaled glyphs. No new render was performed, so this is a reproduction target rather than a verified overflow report.

Scope: current golden/semantics matrix at 320/700/960/1440 widths, 1×/1.5×/2× text, a wide installed font, keyboard-open compact layouts, long host/path and RTL. Increase affected chrome heights from measured text metrics or use scale-appropriate icon-only controls with full labels. Do not globally clamp user text scale.

Gate: no clipped warning/action text or unreachable controls, stable pane/list selection, baseline screenshots reviewed in both shipped themes and high-contrast theme. Include narrow errors and host-key/auth prompts, which already have some scrollability fixes.

### UI-09 · P2 privacy hardening · Remote text editors do not request IME learning suppression

Evidence: Séance `app/seance_app/lib/ui/built_in_text_editor.dart:1283-1296` and Poltergeist `app/poltergeist_app/lib/ui/built_in_text_editor.dart:676-689` turn autocorrect/suggestions off but omit `enableIMEPersonalizedLearning: false`. Both apps' auth fields already set the flag. Remote configuration text can include secrets even outside password fields.

Scope: disable personalized learning on editor and editor-search fields; inspect other credential/command fields for the same omission. This is an OS/IME hint, not a guarantee against a malicious installed keyboard, and should not be documented as secure-input isolation.

Gate: widget properties plus actual Android keyboard configuration in a real-device check; typing, IME composition, undo, search and selection remain functional. Keep smart quotes/dashes disabled.

### UI-10 · P2 performance investigation · Measure large editor typing and search before more editor features

Evidence: both built-in editors recompute UTF-8 byte count and scan line breaks after every changed text; Poltergeist `ui/built_in_text_editor.dart:178-194`. Syntax has a 200k-character cutoff (`ui/editor_syntax.dart:23`), while document input allows approximately 4 MiB. Highlighting being disabled does not bound TextField layout, search or status recomputation. This is a code hotspot hypothesis, not measured jank.

Scope: benchmark 4 MiB ASCII, mixed Unicode, many short lines and a few giant lines; typing, paste, find-next, caret motion and save with syntax enabled/disabled. Separate status computation from typing frames, update line/byte summaries incrementally only if measurements justify it; consider worker-backed indexing or a stricter friendly size fallback before replacing the editor.

Gate: input latency and frame percentiles on a modest Android device and laptop, peak memory, correct byte/BOM/line-ending counts, no lost edits or stale save state. Preserve atomic save/conflict checking.

## Visual assessment and aesthetic improvements

Inspected committed captures: Poltergeist `tasks/d34-colour/captures/after-window-light-compact.png` and `after-window-dark-comfortable.png`; Séance `docs/captures/d34-colour/after-panel-files-light.png` and `after-panel-git-dark.png`. They are real stored raster evidence, not fresh captures of this exact baseline. I did not inspect other models' PRs.

The sibling direction is coherent: quiet neutral surfaces, a shared vocabulary of colored functional glyphs, strong file-list selection, readable dark/light hierarchy, and a recognizable sidebar structure. Themes already ship with ten presets, editable palette, type/corner controls and contrast tests. Recommend refinement over another wholesale recoloring. The captures show considerable metadata/toolbar density and broad desktop empty space, which should be addressed through context and adaptive utility, not decoration.

### UI-11 · P2 aesthetic workflow · Destination-and-selection inspector

For Poltergeist, make the empty/summary inspector useful: show the selected total, destination identity, transfer rule and concise next action; selected-file view can place path/size/modified information before less-used owner/group fields. Keep unknown values explicit. First slice is summary UI over existing selection and queue state, with no filesystem scanning triggered merely by painting the inspector.

Gate: all metadata remains available, no new remote calls on selection churn, one focused next action, screenshot review for single/multiple/no selection and narrow inspector. Avoid always-on huge illustrations or tutorial copy in a working file manager.

### UI-12 · P2 aesthetic workflow · A calmer medium-width Séance layout

Existing breakpoint at `ui/adaptive_shell.dart:18-29` is 960 logical pixels: both side panes disappear together below that. Add an intermediate terminal+server-rail mode with utilities in a drawer, and explicit collapse affordances. Persist chosen collapse intent and keep it distinct from automatic layout constraints. The assistant remains intentionally always available.

Gate: resize across 700/960/1440 without session loss, duplicate SSH work, editor buffer loss, focus stealing or keyboard disappearance; list and utilities reachable by keyboard; app Back preserves live sessions. Persisted pane widths and narrow Back are already implemented and must not be re-added as new work.

### UI-13 · P2 aesthetic safety · Accessible theme editing with recoverable live preview

The new theme editor updates immediately and correctly supplies preset defaults. Next useful slice: contrast diagnostics for custom text/status/selection against actual resolved surfaces, with a conspicuous keyboard-accessible reset/undo that stays legible in the editor even after an unreadable custom palette. Do not prohibit users' deliberate low-contrast palettes; show the resolved contrast and offer an automatic correction. Preserve share compatibility and deliberate device-local scope.

Gate: black-on-black, white-on-white, translucent selections, all presets, customized font, both settings engines and rollback after failed persistence. Warn only for actual contrast conflicts, not arbitrary color taste.

## Delightful, concrete optional ideas

These preserve file-first Poltergeist and terminal-first Séance. They can be implemented independently after correctness work.

- **Transfer receipt (Poltergeist, P2).** A compact completion card stating exact source → destination, verified/unchecked status, counts, conflicts/skips and elapsed time, with Reveal destination and Copy summary. Derive it from actual terminal queue state; cancelled/partial work must never receive a celebratory success. Optional subtle checkmark motion obeys reduced motion. Acceptance: partial, skipped, retried and remote-to-remote runs produce honest receipts, with no secret paths included in external notifications by default.
- **Breadcrumb return trail (both, P2).** A short, device-local recent-folder trail scoped to endpoint, exposing a fast return to a folder without reopening a modal picker. Poltergeist already has recents/history and workspaces: surface those, do not create another history store. Séance's trail never injects a `cd` unless the user explicitly asks to change the shell; file navigation can stay independent. Acceptance: chroot/path identity and disconnected endpoint are explicit, no unsolicited commands, keyboard discovery.
- **Change postcard (Poltergeist, P2).** Before a sync, show a tiny truthful summary such as `23 uploads · 2 downloads · 1 delete` and a small map of affected top-level folders, linked to the existing detailed plan. Expose uncertainty/conflicts plainly. First slice renders the existing immutable plan; no duplicate scanner. Acceptance: exact counts, exclusions and overrides stay in sync, delete confirmation remains, enormous plans render with bounded widgets.
- **Connection fingerprint seal (both, P3).** A deterministic small geometric mark from the full host-key fingerprint, alongside the real fingerprint in trust review and optional server identity. Use it as a memory aid only; a changed key changes both text and seal and stays blocked under the current trust policy. Acceptance: stable cross-platform generation, collision/visual ambiguity limitations explained, explicit server colors retained, accessibility has the real fingerprint.
- **Sensible quiet mode (both, P2).** One existing-setting-derived motion policy for transitions, progress pulses and future flourishes. Current compact transitions and toast SlideTransitions use fixed animation durations without a direct reduced-motion branch. Keep real progress visible, make state changes immediate when the OS requests reduced motion, and never animate terminal text. Acceptance: disableAnimations produces no spatial slide/tween while focus/navigation and cancellation still complete.
- **End-of-session postcard (Séance, P2).** Keep the last output and precise disconnect reason visible, with duration and a deliberate Reconnect action. Reuse existing session metadata and retained terminal buffers; never imply the remote process can be restored. Acceptance: authentication failure, clean shell exit, dropped transport and reconnect keep distinct messages, copy works, editor recovery stays reachable. This consolidates the existing “Last words” idea rather than adding a duplicate backlog entry.

## Backlog consolidation notes

Séance's current `ANALYSIS.md` retains stale active claims. Before publishing a consolidated future-work document, remove completed clauses, preserving real residuals:

- Pane widths now persist; narrow Back has a PopScope and closes drawers first; window defaults are now 1280×800. Do not keep instructions to implement those basics. Three-stage layout, collapse controls, utility-tab persistence, native predictive-back verification and keyboard splitters remain useful.
- Status is now one composed dot with distinct styles and words (`ui/server_status_dot.dart:40-75`), and broad themes ship. Retain native semantics/color-vision validation; do not recreate dual-dot consolidation or another theme picker.
- ssh-agent and recursive saved-host ProxyJump now exist in Séance (`docs/STATUS.md:74-98`). Real agent/Windows/mobile capability coverage and any outstanding forwards remain; “implement agent and jump hosts” is stale. Poltergeist still uses an older pinned Séance version and explicitly warns that agent is unsupported, so its adoption is a separate dependency/upstream parity task.
- Existing SelectedTabView tests cover hidden focus, preserved per-page state and primary scroll ownership. Do not assert those are missing based on older TabBarView behavior.
- Poltergeist's compact accessibility gestures, 56 dp/scaled rows, folder Back, command sheets, settings window, queue and previewable sync already exist. Do not propose them from scratch. Android storage/background/export and D39 secondary-window capabilities are the true documented gaps.
- Keep rendered/native evidence boundaries explicit: committed captures and static source support this review; new native, assistive-technology and real-device verification remain unperformed.

## Fresh fixture-capture addendum

After the initial review, the coordinating agent rendered existing capture fixtures against these source baselines. I visually inspected `/private/tmp/seance-review-captures/home-phone-comfortable-dark.png`, `/private/tmp/seance-review-captures/rail-narrow-compact-light.png`, `/private/tmp/poltergeist-review-captures/sidebar-comfortable-narrow.png`, and `/private/tmp/poltergeist-review-captures/sidebar-compact-dark.png`. These are source-current widget fixtures rather than a running native application. System Arial/Courier were aliased to the fixtures' expected Deja font names because the expected fonts were unavailable; typographic metrics and text fitting are therefore not release-golden proof.

Observed: the current narrow sidebars retain group structure and connected-state badges; the comfortable phone list exposes endpoint/status details and overflow actions, while compact mode intentionally omits them. Long labels elide without obvious row overlap in these samples. The documented single composed status indicator is visibly present, so older requests to consolidate two independent dots should be retired. Narrow comfortable Poltergeist rows leave very little visible endpoint detail; a reliable full-identity tooltip/semantics/reveal affordance is more useful than another icon. These four fixtures do not exercise the terminal deck, editor, toasts, scaled breadcrumbs, secondary-window semantics or actual mobile insets, so they neither confirm nor refute the separate findings above.
