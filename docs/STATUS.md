# Status & next steps

Living snapshot of where Séance is, what's proven, and what to pick up next.
Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-09-09. The TOFU and keyboard-interactive dialogs now
guard every action on being the current route, so a rapid double activation
cannot pop the page below and an obscured dialog cannot pop or answer a
newer route (ported back from Poltergeist); periodic probe lifecycle repair
prevents overlapping sweeps and stale queued work; the identity audit log
now skips wrong-typed optional fields instead of poisoning a full read and
is stored owner-only on desktop POSIX; before that, upload CAS coverage
with hashing off pins the SFTP adapter's preflight/compare-and-swap
guards; before that, a server can
be excluded from sync and kept on
one device, on top of the additive SSH keepalive controls and SFTP activity
tracking that support Poltergeist's pooled transport policy._

## Prompt dialog route guards (2026-09-09)

`showHostKeyDialog` and `showKeyboardInteractiveDialog` route every button
through a current-route check (`ModalRoute.of(context)?.isCurrent`): an
action only pops when the dialog's own route is still the top one. Two
classes of stray pop are closed. A rapid second activation during the exit
animation — double-tapped Trust, Submit, or Cancel while the dialog is
already dismissing — previously popped the page below the half-dismissed
dialog. A callback from a dialog obscured by a newer route previously
popped and answered that newer route instead of the prompt. Result
contracts, barrier behavior, warning/fingerprint semantics, answer order,
cancellation, reveal/echo behavior, and the controller-dispose-after-exit-
animation lifecycle are unchanged.

Six widget regressions (three per dialog) failed against the unmodified
dialogs before the guard — the double-activation cases by the pushed page
below being popped, the obscured cases by the newer route disappearing —
and pass after; all 463 Flutter tests and `flutter analyze` are green. The
guard was developed in Poltergeist's ported prompt dialogs (its M2 prompt
UI) and ported back; its local ledger entry records the provenance.

## Done (implemented + verified)

| Area | State |
|---|---|
| `seance_protocol` | Complete. Models (incl. strict Bookmark, Snippet with `{{placeholder}}` parsing/fill, and `ServerConfig`'s optional `group`/`color`/`icon`/`loginScript` — named accents and icons rather than raw values, so they render per theme and an unknown name decodes to "none"), E2E crypto, forward-compatible records (serverConfig/hostKey/secret/snippet/bookmark/assistantSettings/unknown), LWW, sync DTOs. |
| `seance_core` | Complete. SSH+TOFU, ssh_config import, prober, sync engine + fail-soft coordinator, LLM providers + chat tools, danger linter, redaction, paste sanitizer, stores; per-server login script typed into the shell once it opens; a `test_connection` probe (one attempt, a redacted transcript, host keys trusted for the attempt only) behind the editor's Test connection. |
| `seance_sync_server` | Complete. 7 endpoints, in-memory + SQLite storage, rate limiting, Dockerfile + compose. |
| `seance_app` | Complete; `flutter analyze` clean, widget tests pass. Server list is the top-level list; each server can hold several sessions shown as a per-server tab strip (a strip appears only at 2+ tabs, so a single session looks title-bar-less as before), with ⌘T/Ctrl+Shift+T + a "New tab" affordance, status dot: green/grey/red + connecting spinner; resizable tiled panes); right-hand utility panel with Assistant + Snippets + **Files** tabs. Files is session-scoped SFTP over the existing SSH transport: responsive navigation, OSC 7 follow mode, picker/desktop-drop upload, local open + conflict-checked upload-back, mkdir/rename/delete, progress/cancel; narrow/Android gets a full-screen route. See [`docs/SFTP.md`](SFTP.md) for implementation state and remaining real-device work. Snippets are synced command templates with `{{placeholder}}` fill-in dialogs; assistant chat when configured, ⌘/Ctrl+↵ sends; inline command generator (⌘K / Ctrl+Shift+K, prefilled from the current shell line, Enter generates+inserts+closes) turns NL into a reviewed command; the native macOS menu is kept intact (Edit/Window/…) with Settings wired to ⌘, and a Terminal ▸ Generate Command… (⌘K) item; Settings is still an in-app route; settings suggest models from the endpoint with manual fallback; failed connections show a summary + expandable connection log. **Automatic sync** runs at startup, after any server/snippet add/edit/delete (debounced), and every 5 min, with a live header/settings status; the "Sync now" button remains. **Credential sync** is opt-in (global toggle × per-server "allow this credential to sync"; E2E-encrypted). The editor has a **Test connection** button: it authenticates with what the form holds right now (a password or key typed but not yet saved, or the stored credential wherever a box is left blank — the rule Save follows, with one exception Save shares: a blank passphrase box beside a *pasted* key means "no passphrase", not "keep the stored one"; see known limitations 17 and 21, which are the two halves of that caveat, and 20 for the Label validator that gates the button), without opening a shell or running the login script, and reports how authentication completed plus the same summary and expandable transcript a failed connection shows. A host key approved during a test is pinned for the attempt only — `liveHostAuthenticator` takes the *store* and wraps it in `UnpinnedHostKeyStore` itself, so a caller cannot wire the persistent verifier by accident — and a configured jump host is called out, since ProxyJump is modelled but not executed. The connection transcript now redacts keyboard-interactive answers at capture: dartssh2 prints `SSH_Message_Userauth_InfoResponse(responses: […])` through `toString`, and for a host doing password login that way the list *is* the password — which the log's Copy button would otherwise hand straight to a bug report. An `InfoResponse` whose shape this build does not recognize — a dartssh2 upgrade that renamed the field or quoted the elements — is withheld whole rather than passed through, since every other test of the pattern is written against the same reading of that library and would keep passing while the password flowed into the transcript; one test builds the message the client actually sends and redacts its own `toString`, so an upgrade fails there instead. The match runs to the end of what it is handed rather than to a bracket or a line break (a Dart list does not escape its elements, so a password containing `]` — or a newline, from a password manager — would otherwise keep its tail), and the log's line list is a read-only *view*, so nothing can append past the redaction and a live transcript is not copied on every repaint. Any field edit, auth-method change or key-source toggle supersedes a test already in flight, so a verdict can never land describing a form the user has moved on from. A server row's menu also **duplicates** it: fresh id and timestamps, a "… copy" / "… copy 2" label that continues rather than stutters, everything else carried over, and the credential copied into a vault entry of its own (never shared — a copy that shared one would be rewritten by an edit to either server, and the sync layer keys a credential record by the credential rather than by the server holding it, so two owners would push two versions of one record). Deleting a server now drops its vault entry only when no other server still names it — the check the `secret:` tombstone path already made, extended to the local delete, since a shared entry is reachable through sync and through the editor whatever duplication does — and shares one queue with duplication — as do saving a server and applying a sync round, since both write the config store and the vault; re-entry is detected by zone identity against the action that is running, so a callback registered inside a mutation (a listener's microtask, the auto-sync debounce a save schedules) can queue one of its own once that mutation is over — so two deletes of servers sharing an entry cannot each read the list before the other's removal lands and both leave it behind, and a credential rewritten in place under an unchanged ref cannot happen while a duplicate is reading it. A duplicate also re-reads its source before saving, since the guard is cheaper than the invariant it stands in for: planning is a read, so nothing is created until it passes, and `SourceServerChanged` can say so. A server can also be **excluded from sync** outright (per-server switch in the editor, confirmed when there is something to retract; `cloud_off` mark on its row): its config is never pushed, and a copy pushed before the switch went on is retracted with a tombstone — so it also leaves the other devices, which the switch's subtitle says. A retraction the copy on the sync server outranks (another device's clock running ahead of this one's, or an edit made while this one was offline) is re-dated one millisecond past the record that beat it and pushed again in the same run: re-minting the same losing date every five minutes would leave the switch on here and the config on every other device forever, which is the multi-device case the switch exists for. Turning the switch back off is the mirror: the retraction it revokes may have been re-dated past this device's own clock, so an honest re-inclusion stamp would still lose — the live record is re-dated past its own tombstone instead, and the device stops applying a retraction it has withdrawn rather than deleting the server it just brought back. Its credential is retracted with it, off the sync server — unless a still-synced server shares that vault entry, in which case it is neither withdrawn nor frozen, since a secret record is keyed by the credential rather than by the server holding it. What a `secret:` tombstone does *not* do is delete anything from a vault: it is staged and pushed, never honoured on apply. A tombstone carries no sealed payload — `RecordCodec.decrypt` reads the envelope's flag without opening anything — so a delete is the one signal a sync server can assert entirely on its own, and honouring these would hand it a way to empty the vault (tombstone the configs, then the credentials no config still names). The cost is that the other devices keep an orphaned vault entry no config names, invisible in a UI that lists servers; the fix is sealing tombstones, not trusting this one — and until then a config tombstone is honoured on the same say-so, as it always has been, so a hostile sync server can still delete every synced server's *settings* on every device (never a credential or a pin); sealing closes that too. A pinned host key is withheld for the same reason (it is keyed by `host:port`, and deleting it elsewhere would drop that device back to trust-on-first-use), though new pins for an address only excluded servers use are no longer pushed. **Assistant sync** is a separate opt-in (off by default, and independent of credential sync — the assistant's API keys travel on this switch alone, whatever the credential toggle says): provider, model, endpoint, web-search backends and redaction travel as one end-to-end encrypted record, *with* the API keys they reference — a configuration whose keys stayed behind leaves the other device looking set up and answering nothing. Keys are gathered from the references the configuration itself carries, never by sweeping the keystore (the sync token and the vault key live there too), and the reserved-entry refusal runs in both directions — a configuration whose own references name a reserved entry publishes nothing rather than shipping it, which is what makes the refusal on the way in safe to rely on. An incoming record is held to that rule twice over: it may only write the entries its own configuration names, and a record whose configuration names a reserved entry (the sync token shares the API-key namespace) is refused whole rather than adopted — the allow-list is the record's, the deny-list is this device's, and the vault key is out of reach of both, stored under a prefix no key reference can name. Removals deliberately do not travel: a record says which keys a configuration uses, never which ones a device should forget — so a rotated key leaves the entry it replaced behind on every device that adopted it, to be deleted there by hand, in the OS keychain where the platform has one (the app has no keystore browser, and Android offers no user-facing way to remove a single app's entry, so a stale key stays there). A record whose provider name is empty is not a configuration at all — that field is written from an enum — and is skipped rather than adopted over a working one. Adopting rebuilds the chat provider only when something actually changed, since the record is handed over every round whether or not it moved. The trust boundary that draws is the account, not the device: an opted-in peer can repoint every other one's assistant, endpoint included, just by saving, and the rebuild is silent — so a compromised peer redirects prompts and terminal context to an endpoint of its choosing, and surfacing an adopted change of provider or endpoint is a follow-up. Turning the switch on adopts what the account already holds — a device that configured its own assistant while opted out replaces that configuration with the account's, which the switch's subtitle says before it is thrown — and publishes this device's only when there was nothing to adopt *and* this device has an assistant worth publishing. "Worth publishing" is whether the assistant here is usable at all (a key stored under the reference it names, or a local endpoint that needs none), not whether it carries a timestamp: the stamp is zero both for a laptop that never configured an assistant, whose defaults must not land on the account over a phone that configured a real provider and keys while sync was off, and for an install that configured its assistant before this feature shipped, which is every existing device and would otherwise adopt nothing, publish nothing, and sit there doing nothing until its settings happened to be edited again. A pulled configuration that changed something rebuilds the chat provider, since one already built notices neither a new model nor a new key. A record whose provider name this build does not know is not adopted at all, rather than half-adopted with a matching stamp to hide the disagreement — the local stamp does not advance either, so this device's next Save republishes its own configuration over the newer build's record, which is the accepted cost of not faking agreement; a keyring that is locked publishes nothing that round rather than a keyless copy that would outrank the keyed record on the account; a Save that changed nothing does not stamp; and a stamp never lands below a record this device already holds. Turning the switch off stops this device sharing further changes and deliberately does not retract what was shared — the switch is a per-device preference, and withdrawing the account's record because one device opted out would take the configuration away from the devices that did not. There is no tombstone for the record, so taking keys back off the account means clearing the key references and saving *while still opted in* — the key fields, not the provider and model, which stay set. A record whose provider name is empty is neither published nor adopted, so emptying that field instead could not carry the removal anywhere: this device would publish nothing and the keyed copy would stay on the account, for every other device to go on adopting. What clearing the key *references* publishes is a keyless record with its provider name still set, under a newer stamp — and the server keys records by id, so it replaces the keyed copy rather than sitting beside it, and is then adopted like any other, since nothing skips it. Which is the point and also the cost: every opted-in device's assistant stops answering until a key is entered there, and the entries the removal was about stay in each device's keystore, since removals never travel. A first-class "stop sharing the keys" action would want a sealed tombstone, which is a follow-up of its own. A device that never edited its assistant publishes nothing in the rounds that follow either, and that gate is the stamp: zero means "never edited here", and a laptop parking its shipped defaults on the account would be adopted by every device that opted in on the same zero stamp — which is every install that configured its assistant before this feature shipped. The two gates ask different questions without disagreeing: the switch asks whether this assistant is usable, and stamps before it publishes, so a pre-feature install passes the round's gate from the moment it opts in; a device with nothing usable to publish never gets a stamp to pass it with. The **built-in text editor** opens at the top with the app's monospace stack, has an in-file find bar (⌘F/Ctrl+F; Enter/F3/⌘G cycle, match-case toggle, all matches highlighted) and basic syntax highlighting (shell, python, js/ts, dart, json, yaml, ini/conf, dockerfile, sql, c-family, xml, markdown — detected by name/extension/shebang); for a server file ⌘S/Ctrl+S saves **and uploads immediately** (⇧⌘S keeps it local; conflicts still prompt). Transient notices app-wide use **top toasts**, never bottom SnackBars, so they can't cover the shell prompt at the bottom of the terminal. On **touch platforms** the terminal shows an on-screen key row (Esc/Tab/Ctrl [sticky]/^C/arrows/Home/End/PgUp/PgDn/`\|` `/` `-` `~` + hide-keyboard) and reflows above the soft keyboard. **Command suggestions** (opt-in, local only) surface frequently-run commands in the Snippets tab to save as snippets. **Server groups, colours and icons** are per-server and synced: the list files servers into collapsible sections (alphabetical, ungrouped last; no headers at all until something is grouped, and a live filter overrides collapsed sections so it can never hide a match), each row carries a badge of the server's icon on its accent with the connection dot in the corner, and the accent also rules the terminal's tab strip. Folded sections are device-local (settings), the grouping itself syncs. On **Android**, backgrounding no longer kills the sessions: a `dataSync` foreground service anchors the process while any session is connecting/connected (ongoing notification with the live count, opt-out in Settings ▸ General; `BackgroundKeepAlive` drives it through the `seance/keepalive` channel — on other platforms it is a no-op). Default desktop window 1800×1600. Platform folders committed. |
| Linux packaging | `scripts/package-linux.sh` turns a built Flutter Linux bundle into `seance_<version>-1_<arch>.deb` and `seance-linux-x64.AppImage`. The .deb's `Depends` is derived from the bundle's actual ELF headers (readelf NEEDED → a soname→package table incl. Ubuntu 24.04 `t64` renames as dpkg alternatives, glibc/libstdc++ floors from symbol versions; a documented optional-soname list covers lazily-loaded native assets like package:jni's `libjvm.so`), the AppImage is built with a pinned appimagetool. Wired into `scripts/build.sh` (Linux `app` target), `ci.yml` (builds + uploads the packages every run), and `release.yml` (x64 assets). **x64 only**: Flutter publishes no linux-arm64 host artifacts (`releases_linux.json` is x64-only), so no arm runner can `flutter build linux` — revisit when that changes. The glibc floor tracks the CI toolchain (currently
2.38, from building on ubuntu-24.04) — dpkg enforces it via `Depends`, and
AppImage users on older distros get a clear loader error instead. Deliberately
no .rpm/Flatpak — the AppImage covers non-Debian distros; it uses the system GTK3 (present on any desktop install) rather than bundling it. |
| CI | `.github/workflows/ci.yml`: dart analyze+test, flutter analyze+test, docker build, and a client build matrix (android/linux x64/macos/ios/windows on native runners — the same matrix `release.yml` publishes; the Linux entry also runs the packaging and uploads the artifacts). |

## Probe lifecycle (2026-09-08)

Periodic sweeps serialize across repeated start and pause/resume. Pausing,
replacing targets, or disposing invalidates queued work and stale results;
already active probes may finish. Target lists are snapshotted. Server updates
preserve cadence and never start or resume the service. Public one-shot
`probeAll`, connected-server skipping, timeout, and jitter remain unchanged.
Metadata-only edits and reordering preserve active results; id, host, or
port changes invalidate them. Explicit start still restarts identical targets.

Seven regression tests failed before their repairs. All 16 fake-clock lifecycle
tests, 594 Dart tests, and 449 Flutter tests pass; analysis is clean. This fixes a
prerequisite found while preparing Poltergeist M2's probe integration.

## SSH pool prerequisites (2026-09-07)

`openAuthenticatedClient` accepts a positive `keepAliveInterval`, or null
for caller-owned scheduling. Omission preserves the existing 10 s timer;
Séance's shell flow is unchanged. `DartSshRemoteFileSystem` exposes read-only
`hasActiveOperations` over outstanding VFS calls, including nested calls,
streams and awaited cleanup. It does not count wire requests settling after
a call ends. No VFS-interface, transfer-safety or crypto changes.

Twenty-five socket-free tests cover timer forwarding/disable/default,
pre-connect validation, every metadata operation, overlap, errors, timeout,
streaming and cleanup. The timer fixture injects authentication completion;
it makes no claim about key exchange or trust. Pool scheduling, ping timeout
and reconnect remain Poltergeist work (03 §3.3 of its plan).

## Upload CAS coverage with hashing off (2026-09-08)

Six socket-free tests through the real `DartSshRemoteFileSystem` over a new
path-aware SFTP fake cover the upload conflict guards when callers skip the
inline digest (`computeHash: false`, the bulk-transfer default downstream in
Poltergeist): both preflights, the `expectedTarget` snapshot and content-hash
CAS, preservation of externally written targets, refusal without a commit
rename, and temporary-file cleanup. The `expectedTarget` digest check is
independent of the outgoing inline hash — verified against the source and
pinned by the same-metadata-different-bytes test.

This closes a coverage gap, not a bug: the guards already behaved correctly.
Passing tests against existing behavior were cross-checked by isolated,
reverted adapter mutations (initial-preflight bypass, second-preflight bypass,
CAS digest bypass, temp-cleanup bypass — each demonstrably failing the suite
before the revert). No production code changed; `dart analyze` is clean and
all `seance_protocol` + `seance_core` tests pass (the sync server's
SQLite tests need libsqlite3, which this no-root container lacks; CI runs
them).

## Identity audit log hardening (2026-09-08)

The device-local identity audit log carries private-key paths, so its
storage is now owner-only (mode 0600) on desktop POSIX: `record` creates
and restricts the file before appending, rotation restricts its temporary
before the rename, and `readAll` repairs a log an older build left
permissive — an already-private log is read without a chmod attempt, so
chmod-incapable mounts keep a private trail readable, while a permissive
log that cannot be restricted fails the read instead of silently
returning a world-readable one. Windows and mobile keep their storage
ACLs. A JSON
line whose optional fields (`serverLabel`, `viaBookmark`, `ok`, `error`)
have the wrong type is now skipped as malformed like any other bad line —
previously a valid line such as `"ok": "yes"` threw a type-cast error
that poisoned the whole `readAll`. Absent fields keep their defaults, and
the record shape, rotation retention, and serialization are unchanged;
`writeStringAtomically` grew an optional `privacy` parameter whose default
preserves every ordinary store's behavior.

Six new tests cover the wrong-typed line (valid neighbors preserved),
absent-field defaults, fresh-file creation, read-side and write-side repair
of a permissive log, and rotation retaining owner-only mode under a
traversable (0755) directory; the POSIX-mode tests skip off Linux/macOS.
All five behavior regressions failed against the previous code before the
repair. Ported back from Poltergeist (its PR #38 review findings, plan
04 §6 priority 1). `flutter analyze` is clean and all 455 app tests pass.

Follow-up (2026-09-08): the review-added read-side gate (skip the repair
chmod when no group/other bits are set) now has durable regressions.
Linux procfs supplies rootless, mountless fixtures chmod cannot touch:
this process's `/proc/self/io` (owner-only 0400, readable, chmod EPERM)
pins that an already-private chmod-incapable file reads back empty with
its mode untouched, while `/proc/self/status` (world-readable 0444, chmod
EPERM) pins that a permissive chmod-incapable file fails `readAll` closed
with the repair chmod's `EPERM` asserted via the `PosixException` errno
— the throw is the proof, since the status text is not JSON and empty
entries would also result from a read that was never rejected. Both tests
assert their fixture's mode/readability, use only this process's
non-sensitive counters/metadata (never environ or memory), never modify
permissions (mode re-checked after), and skip off Linux or without the
procfs fixture with an explicit reason; they run in the Ubuntu CI flutter
job. Runtime evidence: the skip-gate regression failed against pre-gate
`70db26c` (EPERM from `readAll`) and passes on main; the fail-closed
regression failed against pre-privacy `41d5261` (no throw; empty entries
returned) and passes on main. All 457 app tests pass with clean analysis.

## Test inventory (what proves what)

- `packages/seance_protocol/test/crypto_test.dart` — KDF determinism + domain separation,
  seal/open round-trip, wrong-key & tamper rejection, auth-verifier hashing,
  recovery-code round-trip + corruption detection.
- `packages/seance_protocol/test/records_test.dart` — model JSON, record codec opacity,
  unknown-kind logging/refusal, LWW tie-breaking, DTO round-trips.
- `packages/seance_protocol/test/bookmark_test.dart` — every bookmark kind round-trips;
  strict unions, kind fields, ids, dates, and immutable rules.
- `packages/seance_core/test/pure_logic_test.dart` — ssh_config import, TOFU verdicts,
  danger linter, paste sanitizer, secret redaction.
- `packages/seance_core/test/llm_test.dart` — Anthropic/OpenAI request build + response
  parse, command JSON extraction, SSE parse, chat tool loop (paste + search),
  redaction of outbound context.
- `packages/seance_core/test/sync_test.dart` — engine: push, two-device convergence,
  concurrent-edit LWW, tombstones.
- `packages/seance_core/test/sync_coordinator_test.dart` — domain⇄record
  mapping, unknown-kind preservation, fail-soft apply, tombstone dispatch, and
  that a server's group, colour and icon travel between devices with
  regrouping converging like a rename (a group is a name its members carry,
  not a record that can dangle). Plus exclude-from-sync, one bullet per
  invariant:
  - an excluded server is retracted rather than pushed, credential included,
    and the retraction is dated at the exclusion so repeat rounds are no-ops;
  - the credential is retracted under the same id the push used, asserted
    against a real vault, and the tombstone that leaves carries no payload;
  - a `secret:` tombstone is staged and pushed but never honoured against a
    vault — unsealed, so the date on it is the sync server's to choose, which
    is why the refusal is unconditional rather than last-write-wins;
  - a host key is withheld only when no synced server shares the address;
  - a credential a still-synced server shares is neither withdrawn nor frozen;
  - an excluded server survives both its own retraction and another device's
    stale copy, config *and* credential;
  - excluding on one device removes it from the other, even when the copy on
    the sync server outranks the retraction — and re-including supersedes the
    retraction, even one already re-dated past this device's clock;
  - a server nobody excluded is never re-tombstoned, checked against
    `rescheduleOutranked` directly, since reaching it through `applyToStores`
    proves the caller's filter and never the guard;
  - one refused write does not sink the whole re-dating pass;
  - changing the flag without a strictly later `updatedAt` throws in every
    build — a real throw, not an assert, since asserts are stripped from the
    release build users run. The editor builds
    its record through the constructor with a monotonic `updatedAt`, so that
    throw guards `copyWith` callers rather than anything a user can reach.
- `packages/seance_core/test/stores_probe_ssh_test.dart` — SecretVault, ConfigStore,
  ProbeService orchestration, `SshSessionManager.verifyHostKey` (TOFU), headless
  engine.
- `packages/seance_sync_server/test/server_test.dart` — all endpoints, auth, rate limit,
  protocol-version + open-registration gating, per-account isolation.
- `packages/seance_sync_server/test/sqlite_storage_test.dart` — real SQLite round-trips +
  durability across reopen.
- `packages/seance_sync_server/test/integration_test.dart` — real client vs live server,
  two devices converge over HTTP; bad-login rejection.
- `app/seance_app/test/host_key_dialog_test.dart` — TOFU dialog first-use +
  hard changed-key block; rapid double trust/cancel and callbacks from an
  obscured dialog cannot pop any route but the dialog's own.
- `app/seance_app/test/keyboard_interactive_dialog_test.dart` — keyboard-
  interactive prompts are obscured, reveal per field, fit above a phone
  keyboard, dispose controllers after the exit animation, and cannot pop any
  route but the dialog's own (double activation or obscured callback).
- `app/seance_app/test/bootstrap_test.dart` — startup phases stay in one
  MaterialApp; pushed routes resolve `AppScope`.
- `app/seance_app/test/keystore_resilience_test.dart` — a locked/missing OS
  keyring (Ubuntu auto-login, no gnome-keyring) must not kill startup:
  probes return null, reads degrade to "not set", writes fail with a clear
  message, the locked vault throws instead of mis-decrypting, and recovery
  works when the keystore comes back.
- `packages/seance_core/test/ssh_diagnostics_test.dart` — connection-log capture and the
  readable `SshConnectException` summary; agent-auth rejected pre-network; the
  login-script keystroke shape (one Enter, edges trimmed, interior newlines
  and non-ASCII kept).
- `packages/seance_core/test/http_sync_client_test.dart` — sync base-URL normalization
  (trailing slash / whitespace tolerated).
- `packages/seance_core/test/remote_file_system_test.dart` — remote POSIX paths, sticky
  cancellation, POSIX metadata, chmod, readlink, and symlink creation.
- `packages/seance_core/test/remote_file_system_upload_cas_test.dart` — upload
  conflict guards with the inline digest off (`computeHash: false`) through the
  real adapter over a path-aware in-memory SFTP fake: stale `expectedTarget`
  rejected before staging, a target that changed or disappeared mid-staging
  rejected at the second preflight, a destination appearing during a
  non-overwrite upload preserved rather than replaced,
  same-metadata-different-bytes rejected through the `expectedTarget`
  content hash (disabling the outgoing digest never disables the CAS
  hash), and a matching-target success control with committed bytes, one commit rename, and no inline digest. Each
  guard was proven live by an isolated, reverted mutation of the adapter
  (preflight bypasses, digest bypass, cleanup bypass); refusal cases assert no
  commit rename, preservation of the external target, and temp cleanup.
- `app/seance_app/test/remote_files_controller_test.dart` — SFTP browser home,
  sorting/filtering/selection/bookmarks, OSC-directory follow, aggregate
  recursive transfers, durable managed copies, concurrent checkout, and
  save-during-upload guards.
- `app/seance_app/test/managed_remote_file_store_test.dart` — durable index,
  SHA-256 reconciliation, corruption quarantine, and traversal-safe cleanup.
- `app/seance_app/test/file_export_service_test.dart` — streamed staging and
  Android SAF method-channel contract.
- `app/seance_app/test/background_keep_alive_test.dart` — the anchor state
  machine: activates on the first live session, coalesces repeats into count
  updates, deactivates on the last, and honors the enable/disable setting
  (including re-anchoring live sessions on re-enable); the settings field
  round-trips in `app_settings_test.dart`.
- `app/seance_app/test/server_grouping_test.dart` — sectioning: no groups means
  no headers, case-folded keys with the first spelling kept, ungrouped last,
  collapse/expand, and a stale collapsed key doing nothing.
- `app/seance_app/test/server_appearance_test.dart` — every colour × icon
  renders, the same accent resolves differently per brightness, and the status
  dot keeps its tooltip inside the badge.
- `app/seance_app/test/editor_syntax_test.dart` — language detection
  (extension/basename/shebang), tokenizer per family (comments, strings with
  escapes, numbers, keywords, meta), non-overlap invariant, search matching
  and caps, and search-over-syntax span layering that reassembles the text.
- `app/seance_app/test/built_in_text_editor_test.dart` — atomic save
  round-trips, BOM/CRLF preservation, external-change refusal, and the editor
  screen: Ctrl-S save-and-upload (immediate, no dialog; reconcile fallback on
  failure), local-only save without an upload target, open-at-top, monospace
  stack, and the find bar (counts, wrap, case toggle, highlight ranges).
- `app/seance_app/test/server_exclude_from_sync_test.dart` — the row's
  exclusion mark appears only for an excluded server, and describes itself as
  a label rather than a tooltip (a `ListTile` merge keeps one tooltip and
  every label, so a tooltip there would be silently dropped); plus when
  excluding asks for confirmation (only when another device could lose the
  server).

## Open items (roughly prioritized)

### Should do next
1. **ssh-agent auth.** `AuthMethod.agent` currently throws `UnsupportedError`
   (dartssh2 has no local-agent path). Options: implement an agent client
   (`$SSH_AUTH_SOCK` / `\\.\pipe\openssh-ssh-agent`) that signs via a custom
   `SSHKeyPair`, or resolve keys from the agent at the app layer and pass them as
   `privateKey` credentials. This is the power-user gap.
2. **Run the app for real.** Build for Linux/macOS (platform folders are now
   committed), drive a live SSH session, confirm resize + TOFU + assistant
   end-to-end. First real runs exist on macOS and Android; a full end-to-end
   pass is still open.
3. **Honor the redaction toggle.** `AppSettings.redactionEnabled` is persisted
   but `ChatController` always redacts (safe default). Wire the setting through
   (e.g. a pass-through redactor when disabled).

### Known limitations to revisit
4. **Sync re-key UX.** Enrolling in sync re-keys the vault to the
   encryption-passphrase-derived key and re-encrypts only secrets referenced by
   *current* configs. Document/enforce "set up sync before storing lots of
   secrets", or generalize re-encryption (needs a `VaultStore.listIds`).
5. **UTF-8 across packets.** `XtermTerminalEngine.feed` uses lenient UTF-8
   decode; a multibyte sequence split across SSH packets can mangle a glyph.
   A byte-accumulating decoder (or the libghostty engine) fixes it.
6. **LLM context = last-N-lines + selection only.** OSC 133 "last command block"
   extraction isn't implemented. Streaming (`streamChat`) exists in the providers
   but the sidebar uses non-streaming `chat()`; switch for nicer UX.
7. **Provider-native web search** (Anthropic/OpenAI server-side tool) is unused;
   only client-side SearXNG, Brave and Z.AI, queried together and interleaved
   by `CompositeSearch`. Add the native path for cloud providers. (The
   client-lifecycle leak these backends share is item 22, not this one.)
8. **Terminal PTY initial size** is 80×24 for the moment between connect and the
   first widget layout, then the xterm `autoResize` fits the grid to the pane and
   forwards it to the remote PTY. (This resize path used to recurse infinitely —
   `terminal.onResize` → `session.resize` → `engine.resize` → `terminal.resize`
   → … — which left the grid stuck at 80 cols; `XtermTerminalEngine.resize` now
   only records the size. Regression: `test/terminal_resize_test.dart`.)
9. **Command suggestions are keystroke-based.** Capture reconstructs the
   command line from outbound keystrokes, so it can't tell a shell command from
   text typed at a no-echo prompt (a password). That's why the feature is
   opt-in and the stats stay local — only a snippet the user explicitly saves
   syncs. A precise version needs OSC 133 command-block marks (see item 6).
10. **Mobile keyboard reflow** relies on `resizeToAvoidBottomInset` +
    `adjustResize`; the on-screen key row reserves space above the keyboard, and
    with the resize loop fixed the terminal now re-fits its rows/cols as the
    keyboard and key row change the available space. A soft keyboard with a
    floating/overlay mode may still cover the last row — revisit if it recurs.

11. **Terminal selection & copy/paste.** Selection semantics live in the
    vendored xterm fork (`third_party/xterm`, every divergence documented
    in its PATCHES.md): single/double/triple click (word / soft-wrap-aware
    line), shift-click extension, drag selection anchored to content with
    edge autoscroll, selections and the scrolled-up viewport surviving
    scrollback trims, and mouse-report hygiene for remote apps. Right-click
    gives Copy / Paste / Select all. Ctrl+Shift+C/V/A elsewhere; ⌘C/⌘V/⌘A
    on macOS/iPadOS (macOS additionally retargets the native Edit menu via
    `MainFlutterWindow.swift`: routes to the focused terminal, falls back
    to text fields; focus pushed over the `seance/menu` channel, the
    session's `TerminalController` exposed on `TerminalSession`). **Needs a
    macOS build to verify the native-menu path** (no Swift toolchain in the
    Linux dev container).
12. **SFTP browser follow-up.** The delayed edit, file-manager, shell, and
    Android export groups are implemented. Live OpenSSH, BBEdit/macOS, Android
    SAF/provider, and iOS editor validation remain, along with Files widget
    platform fakes, resumable/background transfers, and promised-file drag-out.
    Full design/progress: [`docs/SFTP.md`](SFTP.md).
13. **Android background keep-alive is CI-verified only.** The foreground-
    service anchor (`KeepAliveService`, driven by
    `services/background_keep_alive.dart` through the `seance/keepalive`
    channel) is unit-tested (`background_keep_alive_test.dart`) and compiled
    by the CI matrix, but has not run on real
    hardware: battery impact, OEM task killers ignoring the FGS, the
    POST_NOTIFICATIONS ask, and the Android 15 six-hour `dataSync` timeout
    path are all unexercised on a device. If store distribution ever happens,
    revisit whether Play accepts `dataSync` for an indefinite session anchor
    or whether `specialUse` (with its justification form) is the safer fit.
14. **Split the sync round's fetch from its apply.** `AppState._mutate`
    serializes store mutations, and a sync round joins the queue because it
    writes the config store and the vault. That holds the queue across
    network I/O. It is bounded — `HttpSyncClient` times every request out at
    30 s, a timeout ends the round rather than retrying, and `_mutate`
    releases in a `finally` — so a dead network costs one timeout, not a
    wedged app. A slow-but-alive one costs more, because `SyncEngine.sync`
    runs up to five rounds and `SyncCoordinator.run` up to two passes. The
    fix is a `SyncCoordinator` that fetches outside the queue and applies
    inside it, which preserves the invariant (no store write interleaves with
    a delete's reference count or a duplicate's plan) while a slow fetch stops
    stalling saves and deletes.

15. **A domain exception type for search failures.** `ZaiSearch` and
    `CompositeSearch` raise `http.ClientException` for everything — a 502, a
    rejected key, a missing search tool, a reply of the wrong shape — so the
    only way to tell a user-fixable failure from a transient one is matching
    the message string, which the tests already do. A dedicated type carrying
    the backend and the reason would let a caller retry transport blips
    without retrying a bad key. Worth doing when something actually retries;
    today nothing does.

16. **Seal tombstones.** A tombstone carries no sealed payload, so its date
    is the sync server's to choose: a config tombstone is honoured on that
    say-so today (a hostile server can delete every synced server's *settings*
    on every device), and `secret:` / `hostkey:` tombstones are refused for
    the same reason, at the cost of an orphaned vault entry and an
    unretracted pin on the other devices. An authenticator over id, kind and
    date keyed like the payload closes all three at once.
17. **No way to clear a referenced key's stored passphrase.** In
    "reference a key file on disk" mode a blank passphrase box means "keep what
    is stored", which is what makes `Test connection` faithful to Save — both
    fall back to the stored passphrase. It also means a rotation from a
    passphrase-protected key to an unprotected one cannot be expressed: the box
    is already empty, so the old passphrase keeps being tried, and what that
    costs depends on the key's format. dartssh2 3.0.2 refuses a passphrase it
    does not need for an OpenSSH key (`openssh_key_pair.dart`) and for a
    legacy EC one (`sec1_ec_key_pair.dart`), both with
    `ArgumentError('Passphrase is not required for unencrypted keys')` — so
    the attempt fails, naming the reason, for a configuration that is
    correct. A legacy PKCS#1 RSA key takes the quieter path: `isEncrypted` is
    false, the passphrase is never consulted
    (`pkcs1_rsa_key_pair.dart`), and the connection succeeds while the
    vault keeps a passphrase nothing will ever use — the worse half, since
    nothing surfaces it. Detecting
    "new key material" is not reliable enough to hang the rule on: a changed
    path catches only a rotation to a *different* file, the macOS
    security-scoped bookmark is re-minted per grant (so it differs even for
    the same file) and is null on every other platform, and same-path rotation
    — writing a new key over the old one — needs a stored key fingerprint the
    config does not carry. The fix is
    an explicit "no passphrase" affordance in the editor, honoured identically
    by `resolveCredentials` and `plannedCredential`.
18. **A method switch can leave a credential of the wrong kind referenced.**
    Every credential box starts blank when an existing server is opened, and
    blank means "keep what is stored". Switch the auth method without typing
    anything and nothing is written, so the config keeps a `secretRef` pointing
    at a credential of the old kind — a password under a server now set to key
    auth, which a later connect reads as a PEM and fails to parse. Clearing the
    ref instead would throw away a working credential on a switch the user may
    undo in the same sitting, so neither half is right on its own: the fix is
    for the editor to notice the mismatch and say so, rather than for `_save`
    to pick one silently.

19. **One passphrase slot serves two keys.** A second failure mode of the same
    slot, reachable without any method switch: referencing a key file writes
    the *typed* passphrase beside the PEM the entry already held, because one
    entry carries one passphrase and the referenced key needs its own. A device
    that had a pasted key under passphrase A, then referenced a different key
    file under passphrase B, stores `{PEM A, passphrase B}` — and switching
    back to a pasted key without re-pasting leaves a PEM that no longer
    decrypts. Carrying the old passphrase instead would break the referenced
    key, which is the one the server is actually set to use, so this wants the
    same family of fix as item 18: two slots, or an editor that says which key
    a passphrase belongs to.

20. **Test connection validates the whole form, not the connection.**
    `_testConnection` opens with `_form.currentState!.validate()`, which runs
    every validator on the page. Only three fields carry one — Label, Host and
    Username — so the Label is the single validator that can fail while
    everything the connection needs is filled in, and a user who has typed a
    host, a username and a password but not yet named the server is told to
    name it before the button will try. That reads against the point of a
    probe you run *before* committing to a save. `Form.validate()` is
    all-or-nothing, so routing around it wants a `GlobalKey<FormFieldState>`
    per connection field or the three validators hoisted out of the widget
    tree — a restructure rather than a guard, which is why it is written down
    here instead.

21. **A re-pasted key with a blank passphrase box loses its passphrase.**
    Every other blank credential box in the editor means "keep what is
    stored" — a blank password keeps the stored password, a blank PEM keeps
    the stored key. The passphrase box in *pasted-key* mode is the one that
    means "no passphrase": `plannedCredential` writes `keyPassphrase: null`
    whenever the box is empty and a PEM was pasted. Re-paste the same
    encrypted key without retyping the passphrase and the stored one is gone,
    with nothing in the UI saying a passphrase was ever there — the break
    only shows at the next connect.

    Not simply a bug to invert, which is why it is written down rather than
    fixed: carrying the stored passphrase forward would attach it to a key
    that may not have one, since pasting a *new* key is at least as common as
    re-pasting the old, and the box is blank in both cases for the same
    reason. The editor cannot tell them apart because it never shows whether
    a passphrase is stored. That, and not the branch, is the fix — and it is
    the same family of fix items 17, 18 and 19 want — each names a different
    affordance (a "no passphrase" choice, a kind-mismatch notice, passphrase
    ownership), and all four are the editor saying what is stored instead of
    leaving it implied. Four notes in one family is a design asking for one
    change: an editor that says which key a stored passphrase belongs to, and
    lets it be cleared.

22. **Nothing closes an LLM or search client's connection pool.** Every
    provider in `seance_core/lib/src/llm` takes an optional `http.Client` and
    falls back to `http.Client()` when none is passed — `AnthropicProvider`,
    `OpenAiCompatibleProvider`, `SearxngSearch`, `BraveSearch` and now
    `ZaiSearch` — and none of them exposes a `close`. An instance discarded
    rather than kept for the process (the app rebuilds its search provider
    whenever the settings change) leaves its keep-alive sockets open until
    exit. The fix is one shape applied to all five: remember whether the
    client was created here, expose `close()` that only closes that one, and
    have `AppServices` close the provider it is replacing. Not Z.AI's alone,
    which is why it is written here rather than fixed in the branch that
    added the fifth one.

### Deliberately deferred (per proposal)
Port-forwarding UI, ProxyJump execution (import only), Mosh,
terminal **splits** (multiple panes visible at once), OIDC on the sync server,
libghostty terminal backend (swap behind `TerminalEngine` when it tags a stable
release).

> **Un-deferred:** *per-server connection tabs* — several sessions to one
> server, shown as a tab strip one level below the server list (not top-level
> tabs; adjacent tabs are always the same server). The v1 proposal folded this
> into the deferred "tabs-within-tabs/splits" line; it is now built. Splits
> (showing more than one pane at once) stay deferred.

## Housekeeping
- ~~The GitHub repository is still named `Ghossht`~~ — renamed; the remote is
  `L-K-M/Seance` now.
- **Poltergeist**, the sibling two-pane SFTP app, consumes `seance_protocol`
  and `seance_core` as pinned dependencies, with a short queue of small
  upstream asks (forward-compatible record kinds being the important one) —
  see [docs/POLTERGEIST.md](POLTERGEIST.md). Two remaining gaps it documents
  are live Séance bugs tracked on their own, not just as Poltergeist asks:
  - deletes never writing tombstones, so deleted servers resurrect on
    the next pull — and every pull is effectively full, since the app
    rebuilds its record store per round
    ([#54](https://github.com/L-K-M/Seance/issues/54));
  - pulled hostkey pins silently overwriting a conflicting local pin
    ([#56](https://github.com/L-K-M/Seance/issues/56)).
- Release/build/deploy tooling is in place and aligned with the sibling repos:
  `scripts/release.sh` (pubspec-lockstep bump + `v*` tag →
  `.github/workflows/release.yml` publishes the server binaries, the GHCR image,
  and all app clients: Android APK, Linux `.deb` + AppImage + bundle (x64),
  macOS/Windows desktop bundles,
  unsigned iOS IPA),
  `scripts/build.sh` (all local targets, staged into `dist/`), `./update.sh`
  (compose redeploy; gates on the published `/healthz` answering and honors
  per-deployment overrides in `packages/seance_sync_server/.env`, e.g.
  `SEANCE_PUBLISH_ADDR` for containerized reverse proxies).
- Flutter platform folders are now committed, carrying the `Séance` app name,
  launcher icons from `media-sources/seance-icon.png`, and the macOS
  entitlements. The -34018 keystore startup failure is fixed by using the
  legacy login keychain (`usesDataProtectionKeychain: false`) — not by a
  keychain entitlement, which would stop ad-hoc-signed builds from launching.
  The sync server serves the icon as `/favicon.ico` plus a tiny landing page
  at `/`.
- SQLite storage in the server needs `libsqlite3` at runtime; the Docker image
  installs `libsqlite3-0` and `bin/` sets a loader override for `.so.0`.
- Identity files referenced by path (`~/.ssh/…`) resolve against the *real*
  home on macOS: the sandbox points `$HOME` at the app container, so `~`
  expansion strips the container suffix (`expandHomePath` in seance_core), and
  the entitlements carry a read-only temporary exception for `~/.ssh` so the
  connect-time read is permitted. Unreadable key files now fail with an
  actionable message instead of a raw `PathNotFoundException`. Keys outside
  `~/.ssh` work via the server editor's Browse… button: a native panel (shows
  dot-directories) mints a security-scoped bookmark (`seance/secure_bookmarks`
  channel + `files.bookmarks.app-scope` entitlement), stored device-locally in
  settings — never synced; other devices fall back to the path. Every
  identity-file read (path or bookmark, success or failure) is appended to a
  device-local audit trail, `identity_reads.jsonl` in the app-support dir.
