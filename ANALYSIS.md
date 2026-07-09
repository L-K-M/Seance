# Séance — Code & Product Review

_A thorough, code-grounded review of the whole project: correctness, data
integrity, end-to-end-encryption soundness, security, performance, UX,
visual/layout, missing features, and some deliberately playful ideas that fit
the "séance" theme._

> **On this file's name.** The review was requested in `claude.md`. The repo
> already ships a load-bearing `CLAUDE.md` (agent instructions), and a lowercase
> `claude.md` beside it would collide on the case-insensitive macOS/Windows
> filesystems this project targets — so the review lives here in `ANALYSIS.md`,
> the file the backlog was always going to be consolidated into. `CLAUDE.md` was
> left untouched.

Reviewed at `main` = `bd0e52a` (by reading every source file plus a fan-out
multi-agent pass with adversarial verification). The mechanism of every
high-severity item was traced by hand in the code. `file:line` references are
anchors, not exact.

---

## ✅ Shipped in this pass (open PRs)

The clearly-scoped, self-contained fixes were implemented, each on its own branch
with tests, `analyze` clean:

| PR | What | Severity |
|---|---|---|
| **#6** | Write local JSON stores atomically; survive a corrupt file (temp+rename, defensive loads) | 🔴 data-loss |
| **#7** | Server setup: don't wipe a stored key on edit, validate the port (1–65535), stop defaulting to the unsupported ssh-agent | 🔴 data-loss + broken flow |
| **#8** | Timeouts on all sync / LLM / search HTTP calls (a hung sync no longer wedges auto-sync) | 🟠 robustness |
| **#9** | Broaden the danger linter (system-path `rm`, `wipefs`, `shred`, `find -delete`, `truncate`, `git clean -f`) | 🟠 safety |
| **#10** | Assistant: honor the "redact secrets" toggle (was a no-op); lint chat-staged commands | 🔴 privacy/safety |
| **#11** | Sync server: cap request body size + per-push record/blob counts (DoS) | 🟠 security |
| **#12** | Terminal: rebind the selection controller on reconnect (Copy/Select-All silently broke); select-all now includes scrollback | 🔴 bug |
| **#13** | Reject a KDF-parameter downgrade at sync login (E2E integrity) | 🔴 security |
| **#14** | Pause the reachability probe while the app is backgrounded (battery / sshd-log spam) | 🟠 perf |
| **#15** | Snippets: add a filter box; dispose the placeholder dialog's leaked controllers | 🟡 UX + leak |

Everything below is the **remaining backlog** — kept in full so the context
survives for whoever decides to pick it up. Legend: 🔴 high · 🟠 medium · 🟡 low.

---

## 1. Correctness & sync integrity (backlog)

### 1.1 🔴 Deleting a server (or snippet) doesn't sync — and it comes back _(top priority)_
`app/seance_app/lib/app_state.dart:186,311`,
`packages/seance_core/lib/src/sync/sync_coordinator.dart:44`,
`packages/seance_protocol/lib/src/records/record.dart:31`

The record model has tombstones (`DecryptedRecord.tombstone`, `deleted: true`)
and the engine + `applyToStores` honor them — the "a delete propagates as a
tombstone" engine test even passes. But **the app never creates a tombstone.**
`deleteServer`/`deleteSnippet` hard-delete from the local store, and
`collectLocal` only emits records for what's *still* in the store. So on the next
sync the deleted item isn't collected → no tombstone is pushed → the server keeps
its live copy → `_pullOnce` pulls it back → `applyToStores` **re-creates it.**
Net: a deleted server reappears after the next sync, and deletions never
propagate to other devices.

**Fix (needs care + multi-device testing — that's why it's backlog, not a rushed
PR):** persist tombstones (e.g. a `deletions.json` of `id → {kind, deletedAt}`),
write one on every local delete, have `collectLocal` emit a `deleted: true`
record for each (reconstructing the same record id it uses per kind), and prune
once the server has accepted it (or after a long offline-horizon). LWW already
resolves a delete-vs-recreate race correctly.

### 1.7 🟠 Assistant chat can drop a final tool call / return an empty reply / break Anthropic role ordering
`packages/seance_core/lib/src/llm/chat_controller.dart:129-171`

At `iterations >= maxToolIterations` on a turn that still has `toolCalls`, it
returns `turn.text` (often empty) **without dispatching** them — a command the
model wanted to stage on the last iteration is lost. And a pure tool-call turn
adds nothing to `_history`, producing two consecutive `user` messages, which the
Anthropic Messages API can reject ("roles must alternate"). **Fix:** dispatch
before the cap-return; insert a synthetic assistant turn (or real
`tool_use`/`tool_result` blocks).

---

## 2. End-to-end encryption & sync integrity (backlog)

The crypto primitives are careful (see the appendix); these are *trust-model* gaps.

### 2.2 🔴 The record envelope isn't authenticated — a breached server can delete/rollback/swap
`packages/seance_protocol/lib/src/records/record.dart:46`

Only `blob` is sealed. `id`, `updatedAt`, `deviceId`, and **`deleted`** live in
the plaintext envelope and the client trusts them for LWW and deletion. So a
malicious server can flip `deleted → true` (destroy data), roll back
`updatedAt`/`seq` (serve stale versions), or move a blob under a different `id` —
without decrypting anything. Confidentiality holds; **integrity/availability
don't**, which undercuts the stated threat model. **Fix:** bind the envelope
fields into the AEAD as associated data (or MAC/sign them with a vault-derived
key) and reject records that don't verify. _(The KDF-downgrade half of this
threat class shipped in #13.)_

### 2.3 🟠 Vault re-key is non-atomic
`app/seance_app/lib/services/app_services.dart:92` — `_rekeyVault` re-encrypts,
swaps `vault`/`vaultKey`, then writes the keystore key. An interruption partway
leaves some secrets under the old key and the keystore under the new one →
undecryptable secrets. (Also only re-encrypts secrets referenced by *current*
configs — STATUS "#4".) **Fix:** stage the re-encrypted blobs, then flip
atomically; keep both keys until verified.

### 2.4 🟠 No passphrase fallback when the OS keystore is unavailable
`app/seance_app/lib/services/secure_master_key.dart` — the class docs promise a
passphrase-derived fallback for headless Linux / a lost keystore entry, but
`MasterKeyManager` only ever touches the keystore; if `flutter_secure_storage`
throws, bootstrap just fails. **Fix:** wire the documented passphrase unlock.

### 2.5 🟡 Rejected-push reconciliation can lag a round
`packages/seance_core/lib/src/sync/sync_engine.dart:85` — a rejected push
`markSynced`s the local (losing) blob and relies on the next pull to bring the
winner; within a single `sync()` the loser can briefly persist. Converges over
rounds; noted for completeness.

---

## 3. Sync server hardening (backlog)

### 3.2 🟠 No per-account storage quota / record caps
`server.dart:183`, `storage.dart` — an authenticated device can grow the DB and
event-loop work without bound. **Fix:** per-account record-count / total-size
quota. _(Per-request body/record caps shipped in #11.)_

### 3.3 🟠 Rate limiter is login-only, username-keyed, and leaks memory
`rate_limiter.dart`, `server.dart:147,119` — only `/v1/login` is limited, keyed
by username (rotate usernames to bypass); register/push/sync are unthrottled;
`_hits` never evicts emptied buckets (memory growth); `/v1/prelogin`
distinguishes 404 vs 200 (username enumeration). **Fix:** add an IP key, prune
buckets, throttle register, uniform prelogin.

### 3.4 🟠 Bearer tokens never expire, are never pruned, can't be revoked
`storage.dart`, `sqlite_storage.dart:103` — every login/register inserts a token
row kept forever. **Fix:** token TTL + periodic prune + a logout/revoke path
(and a client-side re-login on 401 — there's currently no recovery when a token
goes invalid, e.g. after an in-memory server restart).

### 3.5 🟡 Login-timing comment is misleading
`server.dart:150` — the "keep timing uniform" comment is contradicted by the
`account == null` path skipping the hash; prelogin already reveals account
existence, so this is minor, but compute a dummy hash for the missing-account
case or drop the comment.

---

## 4. Client security & privacy (backlog)

### 4.2 🟠 The command generator can send secrets typed at a no-echo prompt to the LLM
`app/seance_app/lib/services/xterm_engine.dart:77`, `ui/command_generator.dart:47`
— `pendingInput` is reconstructed from every outbound keystroke, so a password
typed at a `sudo`/SSH prompt lands in it; the generator prefills its box with it
and sends it (redaction is best-effort and won't catch a bare password). **Fix:**
don't reconstruct/prefill from keystrokes sent while the remote is in no-echo
mode (or move to OSC 133 command-block capture).

### 4.3 🟠 Keyboard-interactive prompts (2FA / passwords) shown in cleartext
`app/seance_app/lib/ui/keyboard_interactive_dialog.dart:29`,
`packages/seance_core/lib/src/ssh/ssh_session.dart:409` — plain `TextField`, and
dartssh2's per-prompt `echo` flag is discarded by the responder wrapper. **Fix:**
thread `echo` through and obscure no-echo prompts.

### 4.6 🟠 No app lock / biometric gate on mobile _(new — from the completeness pass)_
The vault holds SSH passwords and private keys, yet anyone holding an unlocked
phone can open the app and connect. **Fix:** an optional biometric/passcode gate
on launch and resume (`local_auth`), gating both the UI and vault access.

---

## 5. Performance & responsiveness (backlog)

### 5.1 🟠 One monolithic `ChangeNotifier` rebuilds the whole shell on every tick
`app/seance_app/lib/app_state.dart`, `ui/adaptive_shell.dart:37`,
`ui/terminal_pane.dart:46`, `ui/sidebar_panel.dart:17`, `ui/server_list_pane.dart:48`
— any `notifyListeners()` (the probe, the sync spinner toggling per round and per
debounced edit, suggestion recomputes) rebuilds the server list, the terminal-pane
wrapper, and the whole sidebar. The team already froze the connection log
post-connect for exactly this reason. The `TerminalView` glyphs are driven by
xterm's own listenable so they don't repaint, but the churn is real and grows with
server count. **Fix:** split into focused notifiers or use
`Selector`/`ValueListenable` so a probe update only repaints the dots.

### 5.3 🟠 Every sync round re-downloads and re-uploads the whole dataset
`app/seance_app/lib/services/app_services.dart:163`, `sync_coordinator.dart` —
`runSync` uses a fresh `InMemoryLocalRecordStore`, so `highWaterSeq` is always 0
(pull `since=0` every time), `collectLocal` marks everything dirty (push all every
time), and `applyToStores` rewrites every domain file. Fine for dozens of records;
O(all) every 5 min otherwise. **Fix:** persist the local record store (the
documented SQLite swap) with a real high-water mark + dirty tracking (also the
natural home for tombstones, §1.1).

### 5.4 🟡 Terminal engines leak on failed/errored reconnects & at teardown
`app/seance_app/lib/app_state.dart:241`, `services/xterm_engine.dart:154` — if the
prior attempt errored (`session == null`), its `XtermTerminalEngine` (a broadcast
`StreamController` + a `ValueNotifier`) is never disposed; `AppState.dispose` also
never disposes engines. **Fix:** dispose the outgoing engine in `_connect` /
`disconnect` / `closeSession` / `dispose`.

### 5.6 🟡 Window-drag resize forwards a PTY resize every frame _(new)_
`adaptive_shell.dart` drag handles + `app_state.dart` `engine.terminal.onResize`
— dragging a pane divider forwards a `session.resize` to the remote on every
intermediate frame. **Fix:** debounce the PTY resize (send on drag-end / after a
short idle).

---

## 6. UX & workflow friction (backlog)

- 🟠 **No confirm-passphrase on sync registration** — `settings_screen.dart:259`.
  The passphrase *is* the E2E key; a typo at Register derives from the typo and a
  second device with the intended passphrase can't log in, with no obvious cause.
  Add a confirm field + a "can't be reset" note.
- 🟠 **Assistant replies render as raw text, not Markdown** —
  `chat_sidebar.dart:261` (`SelectableText`); code fences/bold/lists show as
  literals, no per-code-block copy. (Adds a dependency.)
- 🟠 **Chat is non-streaming; no cancel / copy / retry** — the sidebar uses
  `chat()`; `streamChat()` exists but is unused. No partial tokens, stop button,
  per-message copy, or retry. (STATUS "#6".)
- 🟠 **The "what was sent" audit trail is computed but never shown** —
  `ChatResult.sent` (`chat_controller.dart:61`) is populated and ignored;
  surfacing it makes the privacy story tangible, and the data already exists.
- 🟠 **`connecting` has no cancel** _(new)_ — a slow/black-holed host blocks the
  pane for the full 15 s connect timeout with no escape. Add a Cancel button that
  aborts the attempt.
- 🟡 **No duplicate detection when adding/editing a server** — two identical
  `user@host:port` entries are allowed silently.
- 🟡 **Mobile arrows/Home/End ignore application-cursor mode (DECCKM)** —
  `terminal_keyboard_bar.dart:22` always sends `ESC [ A`; in vim/less arrows
  should send `ESC O A`, so they misbehave. (Encode through the terminal's key
  encoder instead of hardcoding bytes.)
- 🟡 **Mobile SSH sessions have no lifecycle handling** _(new)_ — backgrounding
  the app lets the OS drop the socket, and there's no auto-reconnect/resume on
  return; sessions come back "disconnected" needing a manual reconnect.
- 🟡 **No un-enroll / delete-account / rotate-passphrase in the UI** —
  `deleteAccount` exists client+server but has no button.
- 🟡 **Bootstrap failure is a dead end** — `main.dart:136` shows static text, no
  retry/copy (more useful once the defensive loads from #6 are in).
- 🟡 **Pane widths reset every launch** — `adaptive_shell.dart:28`. Persist them.
- 🟡 **Always lands on the empty "Select a server" pane** — remembering the
  last-active server (and offering reconnect) on launch would be a nicer open.

---

## 7. Visual & layout (backlog)

- 🟠 **Wide layout can starve the terminal to 0 px / RenderFlex-overflow** —
  `adaptive_shell.dart:50`. `_listWidth` (≤480) + `_assistantWidth` (≤680) + the
  two handles ≈ 1180 px; below that window width the `Expanded` terminal gets
  0/negative width. **Fix:** clamp the pane widths against the live
  `constraints.maxWidth`.
- 🟠 **Terminal has no configurable font/size and ignores the app theme** —
  `theme.dart:24` defines `monoFallback` (JetBrains Mono → …) that's **never
  applied**; `TerminalView` uses xterm's defaults (always dark, even in light
  mode). No font or size control at all — a near-universal SSH-client expectation
  (and an accessibility issue). **Fix:** a themed `TerminalStyle` from the
  fallback stack + a font-size stepper (⌘±).
- 🟡 **Chat bubbles hard-capped at 300 px** — `chat_sidebar.dart:251`; wide
  sidebars waste space.
- 🟡 **Status-dot colors are fixed GitHub-dark hex, ignore theme/contrast** —
  `theme.dart:35` (`StatusColors` ignore `BuildContext`).
- 🟡 **`MiddleEllipsisText` can split surrogate pairs / grapheme clusters** —
  truncating by code unit mangles emoji/combining marks in long labels.
- 🟡 **Terminal + mobile key-row expose no semantics to screen readers** _(new)_ —
  the terminal is an unlabeled canvas and the key-row buttons have no labels;
  VoiceOver/TalkBack users get nothing. Add `Semantics`.
- 🟡 **Dead `connecting` switch arm** — `server_list_pane.dart:276` (already
  handled by the early return at :261). Trivial cleanup.

---

## 8. Missing features (backlog)

- 🟠 **Recovery-code enrollment is built but unshipped** —
  `packages/seance_protocol/lib/src/crypto/recovery_key.dart` is a complete,
  tested Crockford-Base32 + checksum recovery code, but nothing shows it after
  register or accepts it to enroll a second device (sync is passphrase-only).
  Wiring it in is a big, low-risk UX win.
- 🟠 **No grouping / tags / folders / search across servers** — flat alphabetical
  list; power users with many hosts want groups, pinning, recent, and a filter.
- 🟠 **`HostContext` is never populated** — `provider.dart:19` defines OS / distro
  / shell / cwd / exit-code, but only `.unknown` is ever passed to
  `generateCommand`. Gathering `uname`/`$SHELL`/`pwd` at connect would materially
  improve generated commands.
- 🟠 **ProxyJump imported then dropped** — `jumpHostId` round-trips through JSON
  but is never set by the editor or honored at connect; the importer parses
  `ProxyJump` then discards it. Hosts behind a bastion are unreachable without it.
- 🟠 **`Host *` defaults aren't applied on import** — `ssh_config_import.dart`
  drops wildcard-only blocks entirely, so global `User`/`IdentityFile` defaults
  never propagate; imported hosts arrive with empty user/no key.
- 🟡 **No known_hosts import/export** (TOFU is app-only, so it re-prompts for
  hosts the user already trusts on their machine), **no provider-native web
  search** (only client-side SearXNG/Brave; STATUS "#7"), **no session restore /
  last-connected / duration**, **no terminal bell / OSC window-title handling**
  (no completion cue; tabs never reflect the running program), and **`maxTokens`
  fixed at 1024** (`anthropic_provider.dart:21`) so long replies truncate.
- SFTP, port-forwarding UI, and Mosh remain intentionally deferred (proposal),
  though dartssh2 supports forwarding.

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
| `deleteAccount` (sync) | Client + server support it; no UI path. |
| `DecryptedRecord.tombstone` | Exists + engine-tested; app never emits one (§1.1). |

---

## 10. Delightful / novel / quirky ideas (lean into "séance")

The "summon remote machines and talk to them" motif currently only surfaces in
the name. Some fit — and a couple are useful *and* fun:

- **Fingerprint sigils (useful + delightful).** Render a deterministic identicon
  / OpenSSH-style randomart from each host key's `fingerprintSha256`, on the
  server tile and prominently in the TOFU dialog. It's a real security aid — a
  changed key changes the sigil, so "this host looks different" becomes *visible*
  — dressed as a per-host "spirit glyph". (The base64 fingerprint alone is
  inhumane to compare.)
- **Ambient presence.** The reachability dot gently *breathes* when online and
  *flickers* faintly when "unknown" (behind a bastion).
- **A "summoning" connect state** — a brief spectral shimmer / planchette glide
  instead of a bare spinner; the status dot "materializes" when the shell opens.
- **"The medium speaks."** Fade assistant replies in; a `paste_to_prompt` lands
  on the prompt line with a brief "possession" glow.
- **"Last words" / epitaph.** Capture a dropped session's final scrollback and
  show it on the disconnected pane ("its last words were…") — genuinely useful
  for spotting *why* it died, and squarely on-theme.
- **Latency heartbeat** — a tiny per-session sparkline from keepalive round-trips.
- **Cold-spot offline styling** — offline servers frost/desaturate.
- **Haptics (mobile)** — a soft tick when a command is staged; a firmer buzz on a
  `critical` danger flag.
- **Command palette (⌘K for everything)** — jump to a server, run a snippet, open
  settings, generate a command: an "incantation bar" for power users and the theme.
- **Opt-in sound** — a faint whoosh on connect, a knock on disconnect.

---

## Appendix — what's already good (context for future decisions)

Much of this is careful, well-tested work; several "obvious" bugs were already
found and fixed, and one plausible-looking finding turned out to be a non-issue:

- **Crypto is done right.** `vault.dart`: XChaCha20-Poly1305 with a random 24-byte
  nonce, Argon2id with per-account params, HKDF **domain separation** between the
  vault key and the auth verifier, a timing-safe verifier compare, and a
  deliberately-fast-but-justified verifier hash. `recovery_key.dart` even checksums
  against transcription errors. (The §2 gaps are about *trusting server inputs* and
  *authenticating the envelope*, not the primitives.)
- **SSH keepalives are on.** dartssh2's `SSHClient` defaults `keepAliveInterval` to
  10 s, so idle sessions are kept alive behind NAT even though the app doesn't set
  it explicitly — the READMEs' "keepalives" claim holds. (Flagged as a suspected
  bug during review; verified to be a non-issue.)
- **TOFU is correct** and never auto-pins on change; the changed-key dialog is
  appropriately alarming and non-dismissible.
- **The paste-safety invariant is exactly right** — "a newline *is* Enter", so
  `PasteSanitizer` refuses multi-line paste-to-prompt and staged commands can't
  self-execute.
- **The nasty terminal bugs were already caught** — the resize→onResize recursion
  and the per-packet trace storm both have fixes *and* regression tests, and the
  connection log is frozen post-connect to stop rebuild churn.
- **Sync convergence is well-proven** at the engine level — two-device convergence,
  concurrent-edit LWW, and tombstone *propagation* are all tested (the §1.1 gap is
  that the app never *emits* a tombstone, not that the engine can't carry one).
- Lots of considerate touches: stable server-tile keys, top-toasts that don't
  cover the prompt, the mobile key row, safe/opaque server errors, and the
  loopback-bound compose file.

_The first commit of this file was the full review snapshot; this revision moves
the implemented items into the "Shipped" table and keeps the rest as the working
backlog._
