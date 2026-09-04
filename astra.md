# Séance review

Reviewed: 2026-09-04 · base: `2f99f4e` (`origin/main`).

This is the review-first record. No application code was changed before it was
written. Existing SOL/SEA identifiers refer to `ANALYSIS.md`; repeated findings
below refine those entries rather than create competing work items.

## Scope and evidence

Read the protocol/crypto, sync client/coordinator/server/storage, SSH lifecycle,
Flutter state/services, terminal engine/view/rendering/selection, credential
editor, assistant, SFTP/edit pipeline, platform configuration, CI, proposal,
status, and prior analysis. Inspected the committed macOS screenshot; it predates
the current tabs, groups, Files pane, and editor. Visual conclusions below are
source/screenshot inspection, not a claim of current native-device validation.

Baseline: Flutter 3.47.1 / Dart 3.13.1 on Linux.

| Check | Result |
|---|---|
| Pure-Dart analysis | Clean |
| Protocol/core/server tests | 263 passed |
| App analysis | Clean |
| App tests | 309 passed |
| Vendored xterm tests | 137 passed, 2 macOS-only goldens skipped |

SQLite initially failed to load `libsqlite3.so`; a temporary library-path symlink
to the available `.so.0` fixed all three failures. This was environment setup,
not a product regression. Flutter added generated analyzer exclusions during
bootstrap; they are not part of this review.

Not exercised: signed Apple builds, real Android/iOS keyboards and Back gestures,
live SSH/SFTP latency, physical monitor geometry, battery use, or Docker runtime.
No frame-time measurements were collected; performance risks are labeled as such.

The original checkout has uncommitted clickable-URL work. It is untouched. Open
PRs #44 (local shell), #45 (macOS sandbox migration), #47 (window geometry), and
#49 (runaway escape parser) are existing work, not candidates for duplicate PRs.

## Findings and implementation queue

P0 = security/data loss; P1 = common workflow/privacy failure; P2 = robustness,
performance, accessibility or polish; P3 = optional improvement.

The seven bounded changes below can be implemented independently without a wire
migration or access to a personal server. Each gets a separate branch/PR. Bug
fixes require a failing regression test before implementation. Broader issues
remain explicit backlog items, not implied fixes from these small changes.

### AST-001 · P0 · Bound KDF resource use (SOL-014)

**Evidence:** `packages/seance_protocol/lib/src/crypto/vault.dart` accepts up to
4 GiB, unlimited iterations/parallelism/output length, and truncates JSON numbers.
`AppServices.loginSync` checks a minimum, not a resource ceiling. The endpoint is
untrusted before authentication; a malicious prelogin response can exhaust a
phone. Direct `deriveKeys` also bypasses JSON validation.

**Implement:** one shared validation policy before parsing/deriving. Require exact
integers; cap memory at 64 MiB, iterations at 10, parallelism at 4, and output at
32 bytes. Enforce Argon2's minimum memory per lane. Keep production lower bounds
and test-only fast parameters distinct; reject, never clamp, incompatible values.
Rejecting formerly accepted extreme accounts must be documented, not silently
re-derive a different key. These are safety limits, not measured latency targets.

**Tests:** fractional/missing/wrong-type inputs; every limit edge; fast/default
round-trips; direct unsafe derivation rejected before allocation; hostile HTTP
prelogin rejected. Still needed separately: salt/verifier shape validation,
production-device KDF profiling, independent vectors and versioned normalization.

### AST-002 · P1 · Hide authentication answers (SOL-021, SOL-065)

**Evidence:** `_keyboardInteractiveHandler` discards SSH's echo bit and
`ui/keyboard_interactive_dialog.dart` renders ordinary predictive TextFields in
an unscrollable Column. Passwords and OTPs are visible, and long multi-prompt
challenges cannot fit above a phone keyboard.

**Implement now:** obscure all challenge responses conservatively, disable
suggestions/autocorrect, and make dialog content scrollable. Preserve response
order, cancellation and controller lifetime. No shared callback API break.

**Tests:** hidden fields/input policy, ordered submission, cancel with active
composition, many prompts at small height with keyboard insets.

**Residual:** carry typed echo metadata through the public SSH API in a compatible
follow-up so explicitly echoing username prompts need not be obscured. Include
challenge identity and explicit cancellation rather than relying on empty answers.

### AST-003 · P2 · Keep long session targets inside the footer

**Evidence:** `SessionStatusBar` in `ui/terminal_pane.dart` gives
`username@host:port` an unconstrained Text before its Expanded cwd. A long FQDN or
IPv6 address exhausts phone-width space. Its fixed 24-pixel height also clips
large text. The target is the user's final cue about where keystrokes go.

**Implement:** constrain/truncate the target with a full-label tooltip/semantics;
keep cwd available; let footer height grow with text scaling. Preserve connection
identity from the session snapshot, not a renamed config's new hostname.

**Tests:** 240/320-pixel widths, long host and user, cwd present/absent, 2× text,
full target accessible, no RenderFlex overflow.

### AST-004 · P2 · Make status dots legible in light mode (SEA-019)

**Evidence:** `theme.dart:StatusColors` ignores its context and always returns
dark-theme colors. The green's contrast against white is about 2.54:1; actual
light containers can be worse.

**Implement:** brightness-specific status colors, preserving the dark palette.
Choose light colors against real surface/container/selected-row backgrounds.

**Tests:** all three states exceed WCAG's 3:1 non-text contrast threshold on the
surfaces they occupy in both built-in themes. Color alone is still insufficient:
terminal status semantics and non-color cues remain under SOL-064.

### AST-005 · P1 · Gate CI/releases on the terminal fork

**Evidence:** `.github/workflows/ci.yml` runs app tests but not
`third_party/xterm/test`; selection, IME, reflow and mouse-report regressions are
there. Release currently gates only on Dart tests, assuming main's app CI passed.
Tags/manual dispatch can violate that assumption.

**Implement:** run the vendored suite in CI; add app analysis/tests and fork tests
to a Flutter release gate required by client publishing. Keep upstream platform
skips explicit; do not regenerate goldens merely to make a red build green.

**Verification:** execute the exact new commands locally; inspect release job
`needs`; confirm the new CI step runs. The fork currently passes on this SDK.
A pinned SDK/golden update policy remains release-engineering work.

### AST-006 · P2 · Own sync HTTP client lifetime (SOL-058)

**Evidence:** `HttpSyncClient` owns an `http.Client` without close; enrollment and
every periodic `AppServices.runSync` allocate one. Timeouts complete the wrapper
future without cancelling network work. A long-lived app accumulates abandoned
connections/resources until runtime cleanup.

**Implement:** an ownership-aware, idempotent close operation; close internally
created clients in `finally` around sync, login and registration. Borrowed clients
remain caller-owned. Keep protocol DTOs unchanged.

**Tests:** owned/borrowed clients, repeated close, failure cleanup, and preserved
requests. Residual: explicit cancellation, streamed-body limits, and equivalent
LLM/search provider ownership; closing sync clients is not a universal timeout fix.

### AST-007 · P1 · Filter recognizable secrets before command persistence (SOL-046)

**Evidence:** `_recordCommand` stores raw text; `_recomputeSuggestions` redacts
only when selecting suggestions. `CommandStats.toJson` therefore persists
`export API_TOKEN=...` even though it never appears in the suggestions UI.

**Implement:** reject known-secret patterns at the stats boundary, regardless of
assistant redaction settings; filter legacy loaded counts/dismissals too. Keep
safe command counts, ordering and limits. Do not claim regexes detect passwords.

**Tests:** known token/assignment/private-key patterns never reach serialized
counts or dismissals; safe commands still rank; legacy secret entries disappear
from the in-memory/next-saved representation.

**Residual:** no-echo passwords with no recognizable pattern still cannot be
identified. Gate precise command capture on OSC 133 and add a local privacy mode;
provide a clear-history action and explain that historical disk backups remain.

## Security, sync and durability: remaining blockers

### AST-008 · P0 · Host-key sync must not silently re-trust (#56)

`SyncCoordinator.applyToStores` unconditionally replaces a local pin. A newer
conflicting synced key bypasses the otherwise strict changed-key dialog.

Use the TOFU service to compare fingerprints per canonical endpoint. Preserve
local trust; quarantine conflicts durably and surface both fingerprints. A user
resolution must create a new revision or the conflict repeats forever. Test two
devices with competing pins, matching pins, new endpoints, restart and resolution.
Coordinate with SOL-023 (canonical identity/CAS), SOL-011 (authenticated envelope)
and the shared Poltergeist API; do not implement a silent skip that reports success.

### Sync foundation (existing SOL-001/002/005/006/007/008/009/011/012/013/037)

Confirmed on current code:

- Domain deletes emit no tombstones; fresh in-memory mirrors pull from zero.
  Deleted servers/snippets return (#54). Build a durable ledger, typed
authenticated tombstones, local revisions and restart-level convergence tests.
- Remote records are recollected with this device's ID and re-encrypted; an
  unchanged client can republish another device's record. Preserve origin until
  a real edit, persist the cursor, and batch domain writes.
- `markSynced(id, seq)` can clear an edit made during push. Acknowledge the exact
  sent revision. Merge pulled data against current domain state, not old snapshots.
- Server compare/sequence/upsert and pull/watermark are separate async operations.
  Move each transaction into Storage; add barrier-controlled real-HTTP/SQLite
  interleaving tests, including a stale loser writing after the winner.
- Metadata driving LWW and deletion is unauthenticated. Empty blobs decode as
  tombstones. Bind identity, timestamp/revision, device, schema, kind and deletion
  inside AEAD; do not authenticate server-assigned sequence. Version/migrate first.
- Wire IDs expose hostnames/categories. Introduce keyed opaque IDs during the same
  migration, with old records retained until conversion succeeds.
- Exact LWW ties, client-assigned seq and partial/duplicate acknowledgements need
  strict rules. Exhausted rounds must report pending/incomplete state, not success.
- Manual sync bypasses `_autoSync`'s running guard. Route every entry through one
  serialized coordinator with queued edits; add a delayed-fake overlap test.
- #58 now preserves unknown kinds and skips malformed applies; it does not solve
  envelope authentication, persistent quarantine or honest user-visible outcomes.

Suggested dependency order:

```text
strict/versioned envelope -> durable ledger + revisions -> typed deletes
                         -> host-key conflict queue
storage transactions -> snapshot pagination -> quotas and convergence reporting
```

### Credentials and local storage (SOL-029/030/031/034/035)

- `_rekeyVault` mutates the existing vault secret-by-secret, then changes key and
  keystore; interruption leaves mixed keys. Stage a complete vault and recovery
  journal, including unreferenced secrets, before swapping the key and data.
- `probeKeystore` creates a key after a null read without checking existing vault
  ciphertext. Distinguish first run, locked keystore and lost key; never replace
  key material over an existing vault. Test relaunch/update/key-loss on signed apps.
- `server_editor.dart` retains `secretRef` across auth changes. The referenced-key
  passphrase field is displayed but `_save` never persists it; updating only the
  passphrase of an existing stored key is also ignored. Model keep/replace/remove
  explicitly, then test all auth transitions and passphrase-only saves atomically.
- Missing local-only credentials become empty strings on newly synced devices.
  Show “credential required on this device” before connecting; offer unlock/prompt.
- Atomic JSON writers share `<file>.tmp`; parallel writes can rename each other's
  data. The catch-all rename fallback deletes the original even for unrelated I/O
  failures. Queue writes, use unique temps, keep recoverable backups, distinguish
  corruption from I/O, and prove cross-process/crash behavior or adopt SQLite.
- Local SFTP checkouts intentionally contain plaintext. Explain retention and
  provide a visible discard/storage action; never erase unsaved edits implicitly.

### Server/operations (SOL-048–056)

Permanent plaintext bearer tokens make database/backup theft live API access,
including account deletion. Hash tokens, expire/revoke/list devices and require
recent authentication for destructive account actions; migrate existing rows.
Add account quotas/paginated pulls, bounded account+source abuse controls,
transactional registration/deletion, schema versions/foreign keys, safe structured
logs, graceful drain and WAL-aware backup/restore. `/healthz` is liveness, not
SQLite readiness. Revalidate Compose's now-real HTTP healthcheck rather than
repeating the old `--help` finding. Test actual container restart/SIGTERM and
malformed protocol fields (e.g. non-string prelogin username currently becomes 500).

## Terminal correctness and responsiveness

### AST-009 · P1 · Finish, do not duplicate, parser PR #49

The current stateless parser rolls an incomplete OSC back and re-parses it on
every write. This is a concrete quadratic hang, not “Flutter draws slowly.” #49
contains reproduction and measured timings. Rebase/review it; ensure its recovery
policy cannot expose terminal controls hidden in an abandoned payload. Long-term:
a bounded resumable state machine with chunk-boundary/property/fuzz tests.

### Performance risks to measure (SOL-026/057/059, SEA-012)

- Synchronous packet-by-packet parsing and per-change layout compete with input.
  Add bounded feeding/backpressure and coalesced PTY resize only after measuring.
- Every server's terminal remains mounted in an IndexedStack, with per-view caches
  and hidden layouts/resizes. Compare 1/10/50 tabs; use an LRU of rendered views
  without discarding terminal state/selection. Preserve instant active-tab switches.
- Broad AppState notifications still rebuild unrelated chrome; trace-storm logging
  was already isolated in #35. Split listenables based on measured rebuild counts.
- Production KDF, encryption, whole-collection JSON writes, recursive SFTP scans,
  and syntax/search work run on the UI isolate. The editor already memoizes tokens
  and caps highlighting: preserve those protections, profile worst-size files.
- Transfers share SSH transport with keystrokes; measure typing latency during
  large uploads and cancellation. A separate transfer connection needs explicit
  authentication/ownership, not a UI call directly into sockets.

Acceptance harness: repeatable captured output plus live sshd; ASCII/color/Unicode,
unterminated OSC, `yes`, resize spam, full scrollback, selection during output,
10–50 tabs, and concurrent SFTP. Record p50/p95 frame and keystroke latency, peak
RSS and parser throughput on laptop and midrange phone. Aim for 60 Hz rendering
(16.7 ms frame budget) and responsive interrupt; do not assert those are current
measurements. Keep CPU, parser, layout and raster costs separate.

### Shell interaction gaps

Existing click/double/triple/shift/drag selection, trim anchoring, edge autoscroll,
application cursor modes, split UTF-8 and macOS Option composition are implemented.
Do not re-add them. Preserve Ctrl-C interrupt, Ctrl-A readline home, raw alternate
screen mouse reporting and explicit copy shortcuts.

- **SEA-023:** real scrollback find, next/previous, case toggle, wrapped matches,
  incremental bounded scan, hit highlights separate from selection, stable anchors
  during output/trim, Escape restoring focus. Ctrl+Shift+F / Cmd-F; never steal
  plain shell Ctrl-F. The old commented search test is not an implementation.
- **SEA-025/009:** tab cycle/1–9, close, focus host filter, quick palette. Put the
  local-edit destruction guard behind the close operation before adding shortcuts.
- **SOL-047:** one safe local Draft Dock for assistant/snippets/history. Show exact
  target and danger, reject controls/newlines at the final boundary; never append
  blindly to a nonempty prompt. Clipboard multiline paste needs a separate preview
  policy, preserving bracketed paste and editor use, not blanket newline stripping.
- **AST-010:** `_trackPending` appends per rune, has no length bound, ignores cursor
  edits/history, and removes one UTF-16 code unit on backspace. Non-BMP characters
  can become malformed; large pastes can be quadratic. Treat this as an unreliable
  local hint, bound it, remove graphemes, and never use it as authoritative shell
  state or send unknown no-echo input to command generation.
- **SEA-008:** clear native terminal focus on teardown without an old view clearing
  a newer focused view. Validate with native Edit menus, not only widget tests.
- Touch selection needs native-feeling handles/copy toolbar, magnification and
  edge dragging; validate IME composition, autocorrect, external keyboards and
  iPad shortcuts on devices. Cursor movement should send shell/app-aware keys;
  don't move a remote caret by guessing columns from a click.
- Preserve readable final scrollback on disconnect (the model remains but the UI
  replaces it with a placeholder), with copy/save/reconnect and a real reason.
- Agent auth, ProxyJump, forwards, known_hosts tools, strict-KEX matrix, recovery
  exports, reconnect/backoff and persistent-session options remain open. Local
  shell is already PR #44; splits/Mosh/libghostty need their own conformance plan.

## Interface, aesthetics and product backlog

### Adaptive and accessible layout (SOL-039/060/062/064/065; SEA-015/018/020)

The 960-pixel cliff drops both side panes. Use three stages: list+terminal+utility,
list+terminal with a utility drawer, then phone navigation. Persist ratios, last
host and utility tab; add collapse controls and keyboard-adjustable separators.
Narrow mode is an AnimatedSwitcher, not navigation: system Back can exit instead
of returning to hosts. Implement route-aware back handling and drawer-first Back;
test predictive Back, iOS swipe and resizing across the breakpoint.

The fixed 380-pixel drawer, 38-pixel tab strip, 28-pixel close control, 34-pixel
appearance choices and compact mobile keys need constrained-width/large-text
coverage and 44–48 dp touch targets. Avoid making the whole desktop UI phone-sized.
Expose connected/error/unknown semantically; don't animate the terminal or encode
warnings only in color. Honor reduced motion. Window sizing belongs to PR #47.

### Visual direction

Keep the calm violet/near-black identity; fix legibility and hierarchy before
adding ornament. The historical screenshot has duplicated Assistant headings,
vast empty utility space and tiny unlabelled header icons. Current Files/groups
change that layout, so recapture before visual redesign.

Use one clear utility header, context-sensitive empty states with short actions,
consistent density/spacing/radii, a quiet host identity edge and fewer competing
status dots. Keep terminal colors user-controlled. Prefer a simplified sigil at
small icon sizes; photographic art can stay in onboarding. Add screenshot/golden
and semantics coverage for light/dark, 320/700/960/1440 widths and 1×/2× text.

### Assistant (SOL-038/041/042/044/045; SEA-017)

Replies are plain SelectableText and non-streaming. Add safe Markdown with code
copy/stage, streaming and Stop/Retry; preserve user scroll position. Store chat
per session, not just one surviving drawer model. Bound history and keep terminal
context turn-local: current history retains every old context despite its comment.
Native Anthropic/OpenAI tool-result IDs/types must survive the provider seam;
textual “Tool results” is not protocol-equivalent. Reset/dismiss must invalidate
in-flight writes. Show exact redacted outbound payload, target host, provider and
search activity; don't present regex redaction as guaranteed secrecy.

### Files, onboarding and convenience

SFTP, recursive transfers, durable edits, syntax/find and save-and-upload are
already implemented. Remaining work is live platform validation, keyboard file
navigation, resume/background transfer, promised-file drag-out and copy/move—not
“add SFTP.” See `docs/SFTP.md` for conflict/rename race limitations.

Add file-based SSH import with preview and dedupe (current repeated paste import
creates fresh UUIDs), first-value OpenSSH semantics and unsupported-directive
warnings; quick connect; favorites/recents; provider connectivity checks; a
keyboard-first action palette and discoverable shortcut help. Server search,
groups/colors/icons and tab rename already exist. Make credential recovery/export
an onboarding action before encouraging sync adoption.

## New optional ideas

These complement, not replace, ANALYSIS.md's Draft Dock, Planchette, fingerprint
sigils, production wards, OSC command actions, ghost tabs, completion notices,
transcripts, mobile key decks and context receipts.

### AST-011 · P3 · Reading anchor / “new output below”

When scrolled up or selecting, show a small unread-line counter and Jump to live.
Never steal the selection or snap to bottom. Anchor counts to absolute buffer
indices, clear on explicit jump, cap after trims; test continuous output and
alternate-screen changes. This makes an existing scroll-preservation feature
visible and explains why new output isn't on screen.

### AST-012 · P3 · Connection flight recorder

An opt-in local diagnostic card separates DNS/TCP/handshake/auth/shell timing from
parser/layout stalls. Export redacted timings, version and capability metadata,
not keys, commands or raw traces by default. Useful for “it stutters” reports;
bound retention and make export previewable.

### AST-013 · P3 · Portable workspace recipe

Save hosts, tab labels, pane layout and intended directories as a named recipe.
Preview all targets; reconnect explicitly; stage quoted `cd` only at a verified
empty prompt. Never replay previous commands or login scripts without showing the
behavior. A “morning maintenance” workspace is useful without hidden automation.

### AST-014 · P3 · Quiet connection rehearsal

Before saving a host, optionally test DNS/port/key availability and explain the
next trust/auth step. No password guessing, no background remote commands, no
silent pinning. Reuse SSH/probe services; allow cancellation and copyable sanitized
diagnostics. This reduces trial-and-error configuration on mobile.

## Consolidation rules

After review/merge, fold unfinished entries into `ANALYSIS.md` with these IDs and
acceptance criteria. Remove completed action blocks from the active backlog;
retain concise evidence in its resolved ledger. Mark #32–38 merged; remove stale
“add search/groups/SFTP/UTF-8 fix” instructions where implementation already exists.
Do not retire residuals (no-echo capture, typed echo, salt validation, LLM client
lifetime) merely because a smaller fix landed. Preserve prior product ideas,
security dependencies, test gates and historical PR links.
