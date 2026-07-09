# Séance — Code & Product Review

_A thorough, code-grounded review of the whole project: correctness, data
integrity, end-to-end-encryption soundness, security, performance, UX,
visual/layout, missing features, and some deliberately playful ideas that fit
the "séance" theme._

> **On this file's name.** The request was to write the review into `claude.md`.
> The repo already ships a load-bearing `CLAUDE.md` (agent instructions that
> point at `AGENTS.md`/`STATUS.md`), and a lowercase `claude.md` beside it would
> collide on the case-insensitive macOS/Windows filesystems this project is
> built on. So the review lives in **`ANALYSIS.md`** — the file the backlog was
> always going to be consolidated into. `CLAUDE.md` was left untouched. The first
> commit of this file is the full brain-dump; it is later pruned to the
> un-implemented backlog as items ship.

Reviewed at `main` = `bd0e52a`. Findings cite `file:line` as they stand there;
line numbers are anchors, not exact. Produced by reading every source file plus
a fan-out multi-agent pass with adversarial verification; the mechanism of every
🔴 item below was traced by hand in the code.

## Legend

| Tag | Meaning |
|---|---|
| 🔴 | Correctness / security / data-loss, or a clearly broken user-facing path |
| 🟠 | Real friction, perf, or a latent bug in a less-common path |
| 🟡 | Polish, cleanup, nice-to-have |
| **→ PR** | Small & confident enough to ship now as its own PR |
| **→ backlog** | Worth doing, but larger / riskier / opinion-dependent |

A short **"what's already good"** appendix is at the end — a lot here is careful,
well-tested work, and several "obvious" bugs were already found and fixed.

---

## 1. Correctness & data-integrity bugs

### 1.1 🔴 Deleting a server (or snippet) doesn't sync — and it comes back **→ backlog (top priority)**
`app/seance_app/lib/app_state.dart:186,311`,
`packages/seance_core/lib/src/sync/sync_coordinator.dart:44`,
`packages/seance_protocol/lib/src/records/record.dart:31`

The record model has tombstones (`DecryptedRecord.tombstone`, `deleted: true`)
and the engine + `applyToStores` honor them — the "a delete propagates as a
tombstone" test even passes. But the **app never creates a tombstone.**
`deleteServer`/`deleteSnippet` hard-delete from the local JSON store, and
`SyncCoordinator.collectLocal` only emits records for what's *still* in the
store. So on the next sync:

1. the deleted item isn't collected → no tombstone is pushed → the server keeps
   its live copy;
2. `_pullOnce` pulls that live copy back down → `applyToStores` **re-creates the
   item locally.**

Net effect: **a deleted server reappears after the next sync, and deletions
never propagate to other devices.** For a sync feature this is a serious
correctness bug (and it silently accumulates zombie hosts).

**Fix (needs care + multi-device testing, hence backlog not a rushed PR):**
persist tombstones — a small `deletions.json` mapping `id → {kind, deletedAt}` —
write one on every local delete, have `collectLocal` emit a `deleted: true`
record for each, and prune a tombstone once the server has accepted it (and it's
older than any device could still be offline). `applyToStores` already does the
right thing on the receiving side.

### 1.2 🔴 Editing a stored private-key server wipes the key **→ PR**
`app/seance_app/lib/ui/server_editor.dart:242`

The password branch is guarded by `_password.text.isNotEmpty` (line 238); the
stored-private-key branch is **not**:

```dart
} else if (_auth == AuthMethod.privateKey && !_referenceKeyFile) {
  secretRef ??= uuidV4();
  secret = Secret(id: secretRef, kind: SecretKind.privateKey,
      value: _keyPem.text, ...);   // _keyPem is blank on edit
}
```

On edit the PEM field starts empty (secrets are never read back into the form),
so opening an existing stored-key server, changing *anything*, and pressing Save
writes `Secret(value: "")` — silently destroying the stored key. **Fix:** guard
with `_keyPem.text.isNotEmpty`, keeping the existing secret when blank.

### 1.3 🔴 Local stores use non-atomic writes → a crash mid-save corrupts them **→ PR**
`app/seance_app/lib/services/file_stores.dart:29,84,137,184`,
`services/app_settings.dart:115`, `services/command_stats.dart:95`

Every JSON file (`servers`, `snippets`, `vault`, `known_hosts`, `settings`,
`command_stats`) is written with a single `writeAsString`, which truncates then
writes. A crash/power-loss mid-write leaves a truncated/corrupt file — including
`vault.json` (secrets). Worse, the four `file_stores` loaders have **no
try/catch**, so a corrupt `servers.json` throws inside `AppServices.initialize`
and the whole app fails to start. **Fix:** write to a temp file + `rename`
(atomic on POSIX); make loaders defensive (move a bad file to `*.corrupt` and
start empty rather than crashing).

### 1.4 🔴 "Add server → connect" and "import ssh config → connect" dead-end on unsupported ssh-agent **→ PR**
`packages/seance_protocol/lib/src/models/server_config.dart:42`,
`app/seance_app/lib/ui/server_editor.dart:54`,
`packages/seance_core/lib/src/ssh_config/ssh_config_import.dart:35`,
`packages/seance_core/lib/src/ssh/ssh_session.dart:212`

`AuthMethod.agent` is the default for new configs, the default in the editor's
dropdown, and the importer's fallback for any host without `IdentityFile`. But
agent auth throws `UnsupportedError` at connect. So the most common first-run
flows fail for every host that took the default, and the dropdown offers a method
that can never work. **Fix:** default to a working method, have the importer
default keyless hosts to password, and mark ssh-agent "not supported yet" (or
hide it) until it's implemented.

### 1.5 🟠 macOS Edit ▸ Copy / Select All silently stop working after a reconnect **→ PR**
`app/seance_app/lib/ui/terminal_pane.dart:170`

`initState` binds `widget.tab.controller = _terminalController` once. Reconnect
builds a **new** `TerminalSession` but reuses the server id, so the
`_SessionView` (keyed by `ValueKey(serverId)`) keeps its `State` and `initState`
doesn't re-run — the new tab's `controller` stays `null`, so `terminalCopy` /
`terminalSelectAll` / the macOS Edit menu silently no-op. **Fix:** rebind in
`didUpdateWidget` when the tab instance changes.

### 1.6 🟠 "Select all" omits the scrollback it advertises **→ PR**
`app/seance_app/lib/ui/app_menus.dart:62` — anchors from `buffer.height -
viewHeight` (top of the *visible* screen), so scrollback above the fold isn't
selected. Anchor from row `0`.

### 1.7 🟠 Assistant chat can drop a final tool call / return an empty reply / break Anthropic role ordering **→ backlog**
`packages/seance_core/lib/src/llm/chat_controller.dart:129-171`

At `iterations >= maxToolIterations` on a turn that still has `toolCalls`, it
returns `turn.text` (often empty) **without dispatching** them — a command the
model wanted to stage on the last iteration is lost. And a pure tool-call turn
adds nothing to `_history` (text guard at :134), producing two consecutive
`user` messages, which the Anthropic Messages API can reject ("roles must
alternate"). **Fix:** dispatch before the cap-return; insert a synthetic
assistant turn (or real `tool_use`/`tool_result` blocks).

### 1.8 🟠 Chat-staged commands bypass the danger linter **→ PR**
`chat_controller.dart:158`, `ui/chat_sidebar.dart:278`

The linter's contract is "runs on every command the assistant proposes"
(`danger_linter.dart:17`); the command generator honors it, but the chat's
`paste_to_prompt` path stages a command with no lint and the bubble shows only
"placed in prompt: …" — no warning even for a `critical` command smuggled in via
injected scrollback. **Fix:** lint staged commands and show the severity.

---

## 2. End-to-end encryption & sync integrity

The crypto primitives are done well (see the appendix). These are *protocol/trust
model* gaps around them.

### 2.1 🔴 Client trusts server-supplied Argon2 params at prelogin — KDF downgrade **→ PR**
`app/seance_app/lib/services/app_services.dart:135`,
`packages/seance_protocol/lib/src/crypto/vault.dart:40`

`loginSync` derives the vault key using `pre.argonParams` — parameters the
**server** returns at `/v1/prelogin`. A malicious or breached server can return
`Argon2Params.fast()`-grade values (memory 256, 1 iteration); the client then
derives its E2E key with a trivially brute-forceable KDF, and the server (which
holds the ciphertext) can crack the passphrase cheaply — defeating the whole
"breach-tolerant" promise. `Argon2Params.fromJson` also does no range validation
(0 / negative accepted). **Fix:** enforce a client-side minimum (e.g. ≥19 MiB /
≥2 iters) and reject/clamp anything weaker; validate ranges in `fromJson`.

### 2.2 🔴 The record envelope isn't authenticated — a breached server can delete/rollback/swap **→ backlog**
`packages/seance_protocol/lib/src/records/record.dart:46`

Only `blob` is sealed. `id`, `updatedAt`, `deviceId`, and **`deleted`** live in
the plaintext envelope, and the client trusts them for LWW and deletion. So a
malicious server can flip `deleted → true` (destroy your data), roll back
`updatedAt`/`seq` (serve stale versions), or move a blob under a different `id` —
all without decrypting anything. Confidentiality holds; **integrity and
availability don't**, which undercuts the stated threat model. **Fix:** bind the
envelope fields into the AEAD as associated data (or add a MAC/signature over
them keyed from the vault key) and reject records that don't verify.

### 2.3 🟠 Vault re-key is non-atomic **→ backlog**
`app/seance_app/lib/services/app_services.dart:92`

`_rekeyVault` re-encrypts current-config secrets under the new key, swaps
`vault`/`vaultKey`, then writes the keystore key. An interruption partway leaves
some secrets under the old key and the keystore under the new one → undecryptable
secrets. (Also only re-encrypts secrets referenced by *current* configs — STATUS
"#4".) **Fix:** stage the re-encrypted blobs, then flip atomically; consider
keeping both keys until verified.

### 2.4 🟠 No passphrase fallback when the OS keystore is unavailable **→ backlog**
`app/seance_app/lib/services/secure_master_key.dart`

The class docs promise "a passphrase-derived key as the fallback for headless
Linux or a lost keystore entry", but `MasterKeyManager` only ever reads/writes
the keystore; there's no passphrase-unlock path if `flutter_secure_storage`
throws (headless Linux without Secret Service). Bootstrap would just fail. **Fix:**
wire the documented passphrase fallback.

### 2.5 🟡 Rejected-push reconciliation can lag a round **→ backlog**
`packages/seance_core/lib/src/sync/sync_engine.dart:85` — a rejected push
`markSynced`s the local (losing) blob and relies on the *next* pull to bring the
winner; within a single `sync()` the loser can briefly persist. Converges over
rounds; noting for completeness.

---

## 3. Sync server security & robustness

### 3.1 🔴 No request-body size limit — unauthenticated memory-exhaustion DoS **→ PR**
`packages/seance_sync_server/lib/src/server.dart:241,196`, `config.dart`

`_readJson` reads the whole body to a string with no cap; `_push` loops an
unbounded record list with unbounded blobs. One large request can OOM a
self-hosted server. **Fix:** a configurable max-body middleware + per-record blob
cap + max-records-per-push.

### 3.2 🟠 No per-account storage quota / record caps **→ backlog**
`server.dart:183`, `storage.dart` — an authenticated device can grow the DB and
event-loop work without bound. **Fix:** per-account record count / total size
quota.

### 3.3 🟠 Rate limiter is login-only, username-keyed, and leaks memory **→ backlog**
`packages/seance_sync_server/lib/src/rate_limiter.dart`, `server.dart:147,119`

Only `/v1/login` is limited, keyed by username (rotate usernames to bypass);
`register`/`push`/`sync` are unthrottled; `_hits` never evicts emptied buckets
(memory growth); and `/v1/prelogin` distinguishes 404 vs 200, enabling username
enumeration. **Fix:** add an IP key, prune buckets, throttle register, uniform
prelogin.

### 3.4 🟠 Bearer tokens never expire, are never pruned, can't be revoked **→ backlog**
`packages/seance_sync_server/lib/src/storage.dart`, `sqlite_storage.dart:103` —
every login/register inserts a token row kept forever. **Fix:** token TTL +
periodic prune + a logout/revoke path.

### 3.5 🟡 Login timing note **→ backlog**
`server.dart:150` — the "always compute against some stored hash to keep timing
uniform" comment is contradicted by the `account == null` path skipping the hash;
prelogin already reveals account existence, so this is minor, but the comment is
misleading. Compute a dummy hash for the missing-account case (or drop the
comment).

---

## 4. Client security & privacy

### 4.1 🔴 The "Redact secrets before sending" toggle does nothing **→ PR**
`app/seance_app/lib/ui/settings_screen.dart:188`,
`packages/seance_core/lib/src/llm/chat_controller.dart:117`,
`ui/command_generator.dart:86`

`redactionEnabled` is shown, persisted, and reloaded, but redaction is applied
**unconditionally**. The default (always redact) is safe, so it's not a leak —
but it's a control that lies, and an untested path. **Fix:** thread the flag
through (pass-through redactor when off) + a test. (STATUS "#3".)

### 4.2 🟠 The command generator can send secrets typed at a no-echo prompt to the LLM **→ backlog**
`app/seance_app/lib/services/xterm_engine.dart:77`, `ui/command_generator.dart:47`

`pendingInput` is reconstructed from every outbound keystroke, so a password
typed at a `sudo`/SSH prompt lands in `pendingInput`; the generator prefills its
box with it and sends it to the model (redaction is best-effort and won't catch a
bare password). **Fix:** don't reconstruct/prefill from keystrokes sent while the
remote is in no-echo mode (or drop keystroke-based capture in favor of OSC 133).

### 4.3 🟠 Keyboard-interactive prompts (2FA / passwords) shown in cleartext **→ backlog**
`app/seance_app/lib/ui/keyboard_interactive_dialog.dart:29`,
`packages/seance_core/lib/src/ssh/ssh_session.dart:409` — plain `TextField`, and
dartssh2's per-prompt `echo` flag is discarded by the responder wrapper. **Fix:**
thread `echo` through and obscure no-echo prompts.

### 4.4 🟠 No HTTP timeouts on sync / LLM / search calls **→ PR**
`packages/seance_core/lib/src/sync/http_sync_client.dart`,
`llm/anthropic_provider.dart`, `llm/openai_provider.dart`, `llm/search.dart`

Every network call uses `http` with no `.timeout(...)`. A hung sync request
leaves `AppState.syncing == true` forever (spinner stuck, auto-sync wedged since
it early-returns while syncing); a hung LLM call leaves the chat spinner forever
with no cancel. **Fix:** wrap requests in sensible timeouts and surface a clean
error.

### 4.5 🟡 Danger-linter coverage gaps **→ PR**
`packages/seance_core/lib/src/llm/danger_linter.dart:26`

The `rm` rule only fires for paths exactly `/`, `~`, `*`, or `$HOME` + separator,
so `rm -rf /etc`, `rm -rf /var/lib`, `rm -rf /usr` are **not** flagged. Also
missing: `shred`, `wipefs`, `find … -delete`, `truncate -s0`, `git clean -fdx`,
`chmod … 777` with flags after the mode, `> /etc/...` clobbers. It never blocks,
so broadening is low-risk. **Fix:** match any absolute system path in the `rm`
rule and add the rules above (+ tests).

---

## 5. Performance & responsiveness

### 5.1 🟠 One monolithic `ChangeNotifier` rebuilds the whole shell on every tick **→ backlog**
`app/seance_app/lib/app_state.dart`, `ui/adaptive_shell.dart:37`,
`ui/terminal_pane.dart:46`, `ui/sidebar_panel.dart:17`, `ui/server_list_pane.dart:48`

`AppState` is a single notifier; each top-level pane wraps a big subtree in
`ListenableBuilder(listenable: state)`. So *any* `notifyListeners()` — the probe
every ~45 s, the sync spinner toggling per round and per debounced edit,
suggestion recomputes — rebuilds the server list, the terminal-pane wrapper, and
the whole sidebar (chat + snippets). The team already froze the connection log
post-connect for exactly this reason (`app_state.dart:255`). The `TerminalView`
glyphs are driven by xterm's own listenable so they don't repaint, but the churn
is real and grows with server count. **Fix:** split into focused notifiers or use
`Selector`/`ValueListenable` so a probe update only repaints the dots.

### 5.2 🟠 The reachability probe never pauses when backgrounded **→ PR**
`packages/seance_core/lib/src/probe/probe_service.dart:100`

`pause()`/`resume()` exist and the class comment claims probing "pauses when the
app is not visible" — but nothing calls them (no `WidgetsBindingObserver`). So
the app opens TCP connections to every server every ~45 s while backgrounded,
draining battery/data on mobile and filling remote `sshd`/auth logs (fail2ban
risk). **Fix:** a lifecycle observer that pauses the probe (and defers auto-sync)
on `paused`/`inactive`.

### 5.3 🟠 Every sync round re-downloads and re-uploads the whole dataset **→ backlog**
`app/seance_app/lib/services/app_services.dart:163`, `sync_coordinator.dart`

`runSync` uses a fresh `InMemoryLocalRecordStore`, so `highWaterSeq` is always 0
(pull `since=0` every time), `collectLocal` marks everything dirty (push all every
time), and `applyToStores` rewrites every domain file each round. Fine for dozens
of records; O(all) every 5 min otherwise. **Fix:** persist the local record store
(the documented SQLite swap) with a real high-water mark + dirty tracking. (Also
the natural home for tombstones, §1.1.)

### 5.4 🟡 Terminal engines leak on failed/errored reconnects & at teardown **→ backlog**
`app/seance_app/lib/app_state.dart:241`, `services/xterm_engine.dart:154` — if the
prior attempt errored (`session == null`), its `XtermTerminalEngine` (a broadcast
`StreamController` + a `ValueNotifier`) is never disposed; `AppState.dispose`
also never disposes engines. **Fix:** dispose the outgoing engine in `_connect` /
`disconnect` / `closeSession` / `dispose`.

### 5.5 🟡 Placeholder dialog leaks its text controllers **→ PR**
`app/seance_app/lib/ui/snippets_pane.dart:358` — created per placeholder, never
disposed (the KI dialog does dispose). Fix in-place.

---

## 6. UX & workflow friction

- 🟠 **No confirm-passphrase on sync registration** — `settings_screen.dart:259`.
  The passphrase *is* the E2E key; a typo at Register derives from the typo and a
  second device with the intended passphrase can't log in, with no obvious cause.
  Add a confirm field + a "can't be reset" note. **→ PR**
- 🟠 **Assistant replies render as raw text, not Markdown** —
  `chat_sidebar.dart:261` (`SelectableText`); code fences/bold/lists show as
  literals, no per-code-block copy. **→ backlog** (adds a dep)
- 🟠 **Chat is non-streaming with no cancel/copy/retry** — the sidebar uses
  `chat()`; `streamChat()` exists but is unused. No partial tokens, stop button,
  per-message copy, or retry. **→ backlog** (STATUS "#6")
- 🟠 **The "what was sent" audit trail is computed but never shown** —
  `ChatResult.sent` (`chat_controller.dart:61`) is populated and ignored;
  surfacing it makes the privacy story tangible. **→ backlog**
- 🟡 **No snippet search/filter** — flat alphabetical list. **→ PR** (pairs with §5.5)
- 🟡 **Port field accepts any integer** — `server_editor.dart:113` (0/neg/>65535).
  Validate `1..65535`. **→ PR** (bundle with §1.2/§1.4)
- 🟡 **No duplicate detection when adding/editing a server** — two identical
  `user@host:port` entries are allowed silently. **→ backlog**
- 🟡 **Mobile arrows/Home/End ignore application-cursor mode (DECCKM)** —
  `terminal_keyboard_bar.dart:22` always sends `ESC [ A`; in vim/less (which set
  DECCKM) arrows should send `ESC O A`, so they misbehave. **→ backlog**
- 🟡 **No un-enroll / delete-account / rotate-passphrase in the UI** —
  `deleteAccount` exists client+server but has no button. **→ backlog**
- 🟡 **Bootstrap failure is a dead end** — `main.dart:136` shows static text, no
  retry/copy. **→ backlog** (more useful once §1.3 lands)
- 🟡 **Pane widths reset every launch** — `adaptive_shell.dart:28`. Persist them.
  **→ backlog**
- 🟡 **Always lands on the empty "Select a server" pane** — remembering the
  last-active server (and offering reconnect) on launch would be a nicer open.
  **→ backlog**

---

## 7. Visual & layout

- 🟠 **Wide layout can starve the terminal to 0 px / RenderFlex-overflow** —
  `adaptive_shell.dart:50`. `_listWidth` (≤480) + `_assistantWidth` (≤680) + the
  two handles ≈ 1180 px; at window widths below that the `Expanded` terminal gets
  0/negative width and overflows. **Fix:** clamp the pane widths against the live
  `constraints.maxWidth`. **→ backlog** (could be a small PR)
- 🟠 **Terminal has no configurable font/size and ignores the app theme** —
  `theme.dart:24` defines `monoFallback` (JetBrains Mono → …) that's **never
  applied**; `TerminalView` uses xterm's defaults (always dark, even in light
  mode) and other mono text uses the literal `'monospace'`. No font or size
  control at all — a near-universal SSH-client expectation (and an accessibility
  issue). **Fix:** a `TerminalStyle` from the fallback stack that follows the
  theme, plus a font-size stepper (⌘±). **→ backlog**
- 🟡 **Chat bubbles hard-capped at 300 px** — `chat_sidebar.dart:251`; wide
  sidebars waste space. **→ backlog**
- 🟡 **Status-dot colors are fixed GitHub-dark hex, ignore theme/contrast** —
  `theme.dart:35` (`StatusColors` ignore `BuildContext`). **→ backlog**
- 🟡 **`MiddleEllipsisText` can split surrogate pairs / grapheme clusters** —
  truncating by code unit mangles emoji/combining marks in long labels. **→ backlog**
- 🟡 **Mobile key-row buttons expose no semantics labels** to screen readers
  (`terminal_keyboard_bar.dart`). **→ backlog**
- 🟡 **Dead `connecting` switch arm** — `server_list_pane.dart:276` (already
  handled by the early return at :261). Trivial cleanup. **→ backlog**

---

## 8. Missing features (power-user gaps)

- 🟠 **Recovery-code enrollment is built but unshipped** —
  `packages/seance_protocol/lib/src/crypto/recovery_key.dart` is a complete,
  tested Crockford-Base32 + checksum recovery code, but nothing shows it after
  register or accepts it to enroll a second device (sync is passphrase-only).
  Wiring it in is a big, low-risk UX win. **→ backlog**
- 🟠 **No grouping / tags / folders / search across servers** — flat alphabetical
  list. Power users with many hosts want groups, pinning, recent, and a filter.
  **→ backlog**
- 🟠 **`HostContext` is never populated** — `provider.dart:19` defines OS / distro
  / shell / cwd / exit-code, but only `.unknown` is ever passed to
  `generateCommand`. Gathering `uname`/`$SHELL`/`pwd` at connect would materially
  improve generated commands. **→ backlog**
- 🟠 **ProxyJump imported then dropped** — `jumpHostId` round-trips through JSON
  but is never set by the editor or honored at connect; the importer parses
  `ProxyJump` then discards it. **→ backlog**
- 🟠 **`Host *` defaults aren't applied on import** — `ssh_config_import.dart`
  drops wildcard-only blocks entirely, so global `User`/`IdentityFile` defaults
  never propagate; imported hosts arrive with empty user/no key. **→ backlog**
- 🟡 **No known_hosts import/export**, **no provider-native web search** (only
  client-side SearXNG/Brave; STATUS "#7"), **no session restore / last-connected /
  duration**, and **`maxTokens` fixed at 1024** (`anthropic_provider.dart:21`) so
  long replies truncate. **→ backlog**
- SFTP, port-forwarding UI, and Mosh remain intentionally deferred (proposal).

---

## 9. Dead / half-wired scaffolding

Reads as "done" but isn't reachable — finish it or mark it a stub:

| Thing | State |
|---|---|
| `streamChat` (both providers) | Implemented + on the interface; only the test mock calls it. |
| `HostContext` | Defined; only `.unknown` is ever used. |
| `RecoveryKey` | Fully implemented + tested; never called by the app. |
| `jumpHostId` (ProxyJump) | Round-trips in JSON; never set or honored. |
| `SeanceTheme.monoFallback` | Defined; never applied. |
| `redactionEnabled` | Persisted; ignored (§4.1). |
| `deleteAccount` (sync) | Client + server support it; no UI path. |
| `DecryptedRecord.tombstone` | Exists + engine-tested; app never emits one (§1.1). |

---

## 10. Testing & tooling gaps

- No widget test for the **server editor** — §1.2 (key wipe) and the port range
  would both be caught by one.
- No test that the **redaction toggle** is honored (because it isn't, §4.1), and
  none for the **delete → tombstone → sync** round-trip at the app level (§1.1).
- **Danger-linter** tests don't cover the system-path `rm` gap or the missing
  patterns (§4.5) — add cases with the new rules.
- A **1.6 MB `screenshot.png`** now sits at the repo root (`bd0e52a`); consider
  moving large binaries under `media-sources/`/`docs/` to keep clones lean.

---

## 11. Delightful / novel / quirky ideas (lean into "séance")

The "summon remote machines and talk to them" motif currently only surfaces in
the name. A few ideas that fit — some useful *and* fun:

- **Fingerprint sigils (useful + delightful).** Render a deterministic
  identicon / OpenSSH-style randomart from each host key's `fingerprintSha256`,
  on the server tile and prominently in the TOFU dialog. It's a real security aid
  — a changed key changes the sigil, so "this host looks different" becomes
  *visible* — dressed as a per-host "spirit glyph". (The base64 fingerprint alone
  is inhumane to compare.)
- **Ambient presence.** The reachability dot gently *breathes* when online and
  *flickers* faintly when "unknown" (behind a bastion), so liveness reads at a
  glance.
- **A "summoning" connect state** — replace the bare spinner with a brief
  spectral shimmer / planchette glide; the status dot "materializes" when the
  shell opens.
- **"The medium speaks."** Fade assistant replies in; let a `paste_to_prompt`
  land on the prompt line with a brief "possession" glow so the user notices.
- **Latency heartbeat** — a tiny per-session sparkline from keepalive round-trips
  so a laggy link *feels* laggy.
- **Cold-spot offline styling** — offline servers frost/desaturate rather than
  just flip to red.
- **Haptics (mobile)** — a soft tick when a command is staged; a firmer buzz on a
  `critical` danger flag.
- **Command palette (⌘K for everything)** — jump to a server, run a snippet, open
  settings, generate a command: an "incantation bar" that serves power users and
  the theme at once.
- **Per-server epitaph** — a one-line note ("prod — be careful") shown on connect.
- **Opt-in sound** — a faint whoosh on connect, a knock on disconnect. Off by
  default.

---

## Appendix — what's already good (context for future decisions)

So the review is read in proportion — much of this is careful, well-tested work:

- **Crypto is done right.** `vault.dart`: XChaCha20-Poly1305 with a random 24-byte
  nonce, Argon2id with per-account params, HKDF **domain separation** between the
  vault key and the auth verifier, a timing-safe verifier compare, and a
  deliberately-fast-but-justified verifier hash. `recovery_key.dart` even checksums
  against transcription errors. (The gaps in §2 are about *trusting* server inputs
  and *authenticating the envelope*, not the primitives.)
- **TOFU is correct** and never auto-pins on change; the changed-key dialog is
  appropriately alarming and non-dismissible.
- **The paste-safety invariant is exactly right** — "a newline *is* Enter", so
  `PasteSanitizer` refuses multi-line paste-to-prompt and the assistant's staged
  commands genuinely can't self-execute.
- **The nasty terminal bugs were already caught** — the resize→onResize recursion
  and the per-packet trace storm both have fixes *and* regression tests, and the
  connection log is frozen post-connect to stop rebuild churn.
- **Sync convergence is well-proven** at the engine level — two-device
  convergence, concurrent-edit LWW, and tombstone *propagation* are all tested
  (the gap in §1.1 is that the app never *emits* a tombstone, not that the engine
  can't carry one).
- Lots of considerate touches: stable server-tile keys, top-toasts that don't
  cover the prompt, the mobile key row, safe/opaque server errors, and the
  loopback-bound compose file.

_This document is the full review snapshot. As items ship, the implemented ones
are marked and the rest remain here as the working backlog._
