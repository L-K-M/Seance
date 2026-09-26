# Poltergeist — the sibling file-transfer app, and what it asks of Séance

[Poltergeist](https://github.com/L-K-M/Poltergeist) is a cross-platform,
SFTP-first, two-pane file transfer client patterned after Transmit and
ForkLift — a sibling of Séance that reuses this repo's transport, security,
sync, and editor foundations. Its full design plan lives in
[Poltergeist's docs/plan/](https://github.com/L-K-M/Poltergeist/tree/main/docs/plan);
this file records the Séance-facing part: what Poltergeist consumes, the
small upstream changes it needs, and the porting-back arrangement — so a
Séance session touching these areas knows a second consumer exists.
Poltergeist's `docs/plan/` stays canonical for Poltergeist-side
behavior; if the two ever disagree, this file is the one to fix, in the
same change.

## How Poltergeist consumes Séance

- **Git-pinned dependencies, never forks**: `seance_protocol` and
  `seance_core` (records/crypto/DTOs, `SyncEngine`/`HttpSyncClient`/
  `LocalRecordStore`, `RemoteFileSystem` + adapter, `TofuVerifier`, stores,
  ssh_config import, probe service). The pin is a Séance tag, bumped as a
  routine chore.

  Séance's original code uses the root Unlicense. The vendored xterm.dart
  subtree remains MIT-licensed under its own `LICENSE`.

  PR-S0 audited full history and the complete tree at
  `68c08cef4a98f3a326451693b6b0669015e6d06d` on 2026-08-31. Recorded
  identities were the owner's accounts, assistant sessions, and GitHub's
  merge committer; no external human appeared. The whole-message sweep found
  one stranded assistant trailer in squash bodies and no human attribution.
  The 432-entry tree had no gitlinks or `.gitmodules`; `packages/` is the
  first-party workspace, and `third_party/xterm` was the sole vendored tree,
  with its MIT license retained. Any future external contribution needs an
  explicit Unlicense-compatible grant before it lands.
- **Copy-with-attribution** for app-layer assets that live outside the pure
  packages (managed-checkout pipeline, atomic-file helpers, the built-in
  editor stack, toasts, `MiddleEllipsisText`, adaptive layout math, the
  appearance/accent module, the Swift channel patterns). Each copy is
  recorded in Poltergeist's `docs/PORTS.md` with the source path + Séance
  commit, so fixes can flow both ways.
- **Never touched:** Argon2/HKDF parameters and domain-separation salts, the
  sealed-blob layout, the LWW tuple `(updatedAt, deviceId, seq)`, the record
  envelope, and the "UI never sees dartssh2 types" boundary.

Bookmark backup rides the **existing sync server unchanged**: a new
`bookmark` record kind travels inside the encrypted payload — no
endpoint, schema, or protocol-version change, because kind is not a
field of the server's record schema at all. Precision on what the
server *does* see: record **ids** follow Séance's existing kind-prefix
convention (`sync_coordinator.dart` writes `hostkey:<host:port>` today;
bookmarks follow as `bookmark:<uuid>`), so the id prefix — and, for
pins, the host:port inside it — is plaintext on the server, the same
accepted privacy nit Séance already carries. The *serialized envelope* —
the wire form `{id, updatedAt, deviceId, deleted, seq?, blob}` that
wraps the sealed blob — carries no kind string; the kind name itself
travels only inside the sealed blob. That narrower claim is what the
PR-S1 regression test pins.

## Upstream asks (sequenced; each is small and self-contained)

| Id | Change | Why |
|---|---|---|
| PR-S0 | Add the root Unlicense for Séance-authored code; retain xterm.dart's MIT license | Unblocks Poltergeist's copy-with-attribution path and downstream use |
| PR-S1 | **Forward-compatible record kinds** ([#53](https://github.com/L-K-M/Seance/issues/53)) — add `RecordKind.unknown`, map unknown kind names to it, skip-and-preserve unknown kinds in `SyncCoordinator.applyToStores`, add the `bookmark` kind + `Bookmark` model (full spec below the table) | Today an unknown kind decodes as `serverConfig`, which bricks sync rounds or mints a phantom server; a real forward-compat bug independent of Poltergeist, and the hard gate before the two apps may share a sync account — recommended: land the [#56](https://github.com/L-K-M/Seance/issues/56) fix in the same minimum release, so one version assertion covers both axes (see "Cover pin trust too" below) |
| PR-S2 | Extract `openAuthenticatedClient(...)` (socket + TOFU + auth + connection log + failure summarizer, minus shell/PTY) from `SshSessionManager.connect`; recompose `connect()` on top, behavior unchanged | Lets a file manager authenticate without opening a shell channel; it is also what Séance's own "dedicated transfer connection" future item ([docs/SFTP.md](SFTP.md)) needs |
| PR-S3 | Additive `RemoteFileSystem` methods: `setTimes` (SFTP setstat atime+mtime; note SFTP v3 timestamps are whole **uint32** seconds — consumers must round or tolerance-compare mtimes, never compare exactly, and clamp out-of-range values to the 1970–2106 window before setstat rather than letting them wrap), `setOwner` (chown/chgrp), an optional per-call hashing flag. Ranged read is deliberately **not** included — Poltergeist defers it to its resumable-transfer work (v2) and would file it as its own small PR then | `setTimes` is a hard prerequisite for sync convergence (mtime-based comparison); the rest closes documented interface gaps. All additive; in-memory-fake test coverage included |
| PR-S4 | ssh-agent auth (`$SSH_AUTH_SOCK` / Windows named pipe, custom `SSHIdentity` signer) and ProxyJump execution behind the already-modeled `jumpHostId` | Implemented in Séance first for both apps' power users; Poltergeist consumes it as its first post-v1 fast-follow after pinning a containing Séance release |

**PR-S1 detail** (the table row's full spec — sequencing note: the
forward-compat half below, `RecordKind.unknown` + skip-and-preserve +
the per-record try/catch with tests 1–3, fixes live bug
[#53](https://github.com/L-K-M/Seance/issues/53) on its own and may
land first as its own small PR, with the `bookmark` kind + `Bookmark`
model following; test 4 needs *some* newly-learned kind, not
`bookmark` specifically): change
`recordKindFromName`'s `orElse` from `serverConfig` to `unknown`, and
skip-and-preserve unknown kinds in `SyncCoordinator.applyToStores` with a
per-record try/catch. Preserved records keep their original sealed blobs
and kind strings — never re-sealed under a lossy `unknown` name, never
re-pushed — and the pull high-water mark still advances past them so they
aren't re-fetched every round. That no-refetch property (and its
stranding flip side) only bites once the record store **persists across
rounds** — Poltergeist's store today, Séance's after the
persistent-store flow-back; present-day Séance rebuilds its in-memory
store per round, so every pull harmlessly re-delivers preserved records
(see "What flows back"). With a persistent store, a build whose
known-kind set grew must re-scan the **local** store to apply previously
preserved records — the pull will never deliver them again. The trigger
is concrete, not aspirational: persist the build's known-kind set
alongside the store and rescan at startup whenever the current set has
grown beyond the stored one (updating it afterwards) — or simply
re-apply the whole local store at startup, which subsumes the check;
either satisfies the requirement, but nothing else ever re-delivers
those records, so a store with no such trigger strands them forever. A
fresh store recovers them on its first full pull. Add the
`bookmark` kind + `Bookmark`
model. Séance's apply path never decodes bookmark payloads at all
(`case bookmark: break;` — there is no bookmark store), and the
per-record try/catch additionally fail-softs a malformed payload of
*any* known kind, so a future Poltergeist schema change cannot brick a
Séance round through either door — and a malformed known-kind record
gets the same skip-and-preserve, cursor-advance, never-re-push
treatment as an unknown kind: stranded rather than lost until a build
that can decode it arrives (the stranding/no-refetch discussion above
covers it identically), never silently dropped behind the advanced
cursor and never uselessly refetched. Keep all of these properties when
touching this code. Regression tests, one per invariant:

1. **No kind on the wire** — a sealed record's serialized envelope
   carries no kind string (the narrower "kinds never leave the sealed
   envelope" invariant above — the id prefix stays server-visible, as
   already noted).
2. **Preserve is lossless** — a preserved unknown-kind record's id,
   sealed blob, and LWW tuple survive an apply round **byte-identical**
   (blob bytes compared, not decoded equality), with push emitting
   nothing for it — the "never re-sealed, never re-pushed" rule above,
   which a naive implementation breaks invisibly until a later build
   tries to learn the kind.
3. **The cursor advances** — after a round that preserves an
   unknown-kind record, the pull high-water mark has advanced past it,
   so an immediate second round fetches nothing for that id — the
   no-refetch property every persistent store built on this path leans
   on, and the only one of tests 1–3 an apply-only cursor advance would
   break while passing the other two.
4. **The upgrade path works end to end** — a store holding a preserved
   unknown-kind record, re-opened by a build whose known-kind set now
   includes that kind, applies the record through the startup rescan
   above with **no pull involved** (the harness delivers nothing) —
   because no pull will ever deliver it again.

All four tests run against a store and
cursor that persist across rounds — a test double at PR-S1 time, since
present-day Séance rebuilds its store per round (high-water mark
restarting at zero) and the cursor test is unimplementable against that
architecture as-is; the double's shape should match the
persistent-store flow-back so the tests survive it unchanged.

Until PR-S1 ships in a Séance release **and every device runs it**,
Poltergeist defaults to a *separate* account on the same sync server
(works against unmodified Séance today) and treats the shared-account mode
as locked. Nothing server-side enforces this gate (kind is not in the
server's schema — it cannot police what it does not model), so unlocking
shared mode is a **user-asserted switch**. The normative requirements on
Poltergeist's setup flow, one per bullet:

- **Ask before the first write:** the user confirms every device on the
  account runs a PR-S1-era build before the first `bookmark:` record is
  written.
- **Cover pin trust too:** PR-S1 gates *record integrity* (#53); pin
  trust is a second axis. With
  [#56](https://github.com/L-K-M/Seance/issues/56) unfixed, Séance
  devices auto-apply synced pins — pre-existing behavior among Séance's
  own devices, which is why it is not a second hard gate. Recommended:
  land the #56 fix in the **same minimum release** as PR-S1 so one
  version assertion covers both axes; if the minimum release lacks it,
  the setup copy must disclose that Séance devices will trust pushed
  pins without a conflict warning — and this axis carries the same
  permanence caveat as PR-S1's: a pre-#56 build that joins the account
  later (or is rolled back) silently overwrites pins again.
- **State the permanence:** the assertion covers devices present at
  unlock only — a pre-PR-S1 build that joins later (or a device rolled
  back to one) still decodes `bookmark:` records as a phantom
  `serverConfig` (#53) — so the copy says the account stays unsafe for
  old builds *permanently after* unlocking, not only at the switch.
- **Warn in separate mode too:** the same exposure exists through one
  manual path — signing an old Séance build into the Poltergeist-owned
  account — and separate-account setup copy warns against it.

## What flows back

Poltergeist's plan commits to porting improvements back rather than
forking: the persistent local record store with real tombstones — this
fixes the delete-resurrection gap (today nothing in Séance ever writes
a tombstone, so a deleted server resurrects on the next pull, and
every Séance pull is effectively full: the app rebuilds its in-memory
record store each round, so the high-water mark restarts at zero).
One normative requirement when tombstones land: **applying one must
remove the record regardless of kind decodability — preserved
unknown-kind records included** — or a deleted bookmark resurrects on
any device that later learns the kind, a preserved-record variant of
[#54](https://github.com/L-K-M/Seance/issues/54). Also flowing back:
theme-aware status
colors, staged responsive collapse, keyboard/command-registry patterns, and
any bug fix made in a ported file. The `PORTS.md` ledger on the Poltergeist
side is the tracking mechanism; nothing in that flow blocks Séance work.

## The sidebar kit

The flow also runs the other way. Poltergeist's D32 sidebar (its plan,
[10 §5 and §10](https://github.com/L-K-M/Poltergeist/blob/main/docs/plan/10-WORKSPACE-REDESIGN.md))
is built on a portable kit, and Séance's server list now draws with a copy
of it:

- **Source:** Poltergeist
  `app/poltergeist_app/lib/ui/sidebar/sidebar_kit.dart` @ `58605fa`, with
  its test `test/ui/sidebar/sidebar_kit_test.dart`.
- **Copy:** `app/seance_app/lib/ui/sidebar/sidebar_kit.dart` and
  `app/seance_app/test/ui/sidebar/sidebar_kit_test.dart`, at the same
  relative paths so the two files diff cleanly. The kit's one seam,
  `_chrome()`, returns `SeanceChrome` (the same token names as
  `PoltergeistChrome`); `middle_ellipsis_text.dart` was already shared.

Séance-side changes, each worth porting back (all in the kit file, with
tests in the kit test):

1. **Keyboard reach into a row menu (bug).** Shift+F10 or the Menu key
   opened the menu but left focus on the row: the row's own key handler
   saw the arrows (walking the rows behind the menu) and Enter (activating
   the row), because the menu's overlay sits under the row's `Focus` in
   the focus tree. The row handler now ignores keys unless the row itself
   has primary focus; `MenuAnchor` gets `childFocusNode: focusNode`; a
   keyboard-opened menu focuses its first enabled verb
   (`sidebarMenuWidgets(entries, firstFocus:)`); Esc closes, and an arrow
   steps into, a right-clicked menu; a secondary tap moves focus to the
   row like a primary one.
2. **Touch verb sheet (bug).** `showSidebarMenuSheet` was capped at 9/16
   of the screen, so seven verbs scrolled with Delete out of sight. It now
   passes `isScrollControlled: true` and `useSafeArea: true`.
3. **Focus ring shift (bug).** The ring was a border in the row's and
   header's `decoration`, which insets the child by 2 px while focused.
   It is a `foregroundDecoration` now (`_focusRing`).
4. **Touch posture.** Without hover the section chevron and "+" never
   appeared; they stay drawn on touch. Headers (36 + 4 on touch, nested
   rows at the row extent), the filter (40), icon buttons (40) and the
   bottom bar (48) take touch extents, and the mark and dot grow to 24 and
   9 (`sidebarMarkExtent(context)` for hosts sizing their marks).
5. **Hollow dot.** `SidebarDotStyle { solid, ring }` and
   `SidebarRow.statusStyle`: the sibling dot contract's "probe-reachable,
   not connected" is a hollow green ring. Séance also draws the probe's
   "unreachable" as a hollow red ring.
6. **The row surface.** `SidebarKitScope.background`: the dot's cut-out
   ring took `sidebarBackground` even on another surface (a phone's home
   list on the page surface), which drew a halo.
7. **Row options.** `subtitle` (a second line, at first only for touch
   lists, which have no hover tooltip; since the two densities below,
   hosts always pass one and the kit draws it only when comfortable),
   `trailingIcon` (a standing mark, Séance's excluded-from-sync cloud),
   and `showMenuButton` (a visible "⋮" opening the menu at the button on
   desktop, the sheet on touch). `SidebarKitStrings` gains a required
   `rowMenu` tooltip for it.

Séance's theme also gives the kit's menus 8 px corners and compact
desktop items, which Poltergeist gets from its app-wide compact density.

**Converged (Poltergeist 4ba7851).** Poltergeist ported every change above
back, and Séance in turn adopted Poltergeist's one change: a row's dot is
one `SidebarRow.status: SidebarStatusDot?` value (colour plus
`SidebarDotStyle`) instead of separate `statusColor` and `statusStyle`
fields, so a style without a colour cannot be expressed. The two kit files
now differ only in this header, the theme import, and `_chrome()`; keep
them that way by porting any kit change to both.

**Two densities (2026-09-25).** The owner asked for the two views back,
in both apps, comfortable by default (Poltergeist records the decision
as D33, "Sidebar density and restored row detail", in its
`docs/plan/00-OVERVIEW.md`). The kit change landed in both
files at once, so they still differ only in the three places above:

- `SidebarKitDensity { compact, comfortable }` on `SidebarKitScope`
  (`densityOf`; the list layout is comfortable by definition, asserted),
  and `sidebarHomeLayout(density)`: the list when comfortable, touch rail
  rows when compact. Compact is the one-line rail as before (26 px, an
  18 px mark); comfortable is 52 px on desktop and 56 on touch, a 32 px
  mark, a `bodyLarge` title and a `bodySmall` second line.
  `sidebarMarkExtent` and the new `sidebarGlyphSize` follow the density.
- The kit decides the second line: `subtitle` is drawn only when
  comfortable, and the long-press sheet shows it under its title either
  way (`showSidebarMenuSheet(subtitle:)`). `showMenuButton: null` means
  drawn when comfortable or on touch.
- `SidebarRow.accent` (the 4 px line in the server's colour, leading the
  mark, both densities) and `SidebarRow.markRing` (a ring around the
  mark, for a connected server). `SidebarDotStyle.blocked` is a dot
  crossed by a bar in the cut-out colour, for a host key that no longer
  matches. `SidebarSectionHeader.status` puts a dot beside the count for
  live rows the header keeps out of view.
- Comfortable headers draw their chevron, count and "+" at rest.
- `SidebarDensitySwitch`, and `SidebarBottomBar.onDensityChanged`, which
  places it before the gear. `SidebarKitStrings` gains `compactRows` and
  `comfortableRows`.
- ← and → (and their repeats) are swallowed on a header with nothing to
  fold or unfold and on a row, so focus stays in the sidebar.
- The filter's `countText` reads on a line under the field, where
  "N of M · ↵ opens the first" fits at the rail's narrowest.

Séance's host maps its stored `ServerListDensity` to the kit's in one
place and passes the density to every posture, puts the switch in the
bottom bar, the phone home's app bar and macOS's View menu, and passes
`accent`, `markRing`, the blocked dot and the header dot (see
[STATUS.md](STATUS.md)).

**The header dot is announced (2026-09-25).** The header's dot was
drawn only, so a screen reader heard nothing of a live server a fold or
a filter hid. `SidebarSectionHeader.statusLabel` now carries what
`status` means, in the host's words; the two come together (asserted),
and the header's merged label adds the words on a line after
`sectionSemantics`' title and count ("Production, 3 servers", then
"Connected server hidden"). `SidebarKitStrings` is unchanged: the words
are the host's, like the title, and the line break is how a merged
node already joins its parts, so the kit writes no punctuation of its
own. The change landed in both kit files at once.

**Themed corners (2026-09-25).** With themes (see
[STATUS.md](STATUS.md)), the kit's pill corner (`_radius`, which the
focus ring shares) and its other desktop pill corners (`_pill`: the icon
buttons, the filter field, the sync chip) go through
`_chrome(context).corner(...)`, the chrome's corner scale. Poltergeist's
copy takes the same change with its own device themes
([L-K-M/Poltergeist#203](https://github.com/L-K-M/Poltergeist/pull/203)),
where `PoltergeistChrome` gains `cornerScale` and `corner()`; with it,
the two kit files again differ only in the header, the chrome import and
`_chrome()`.

## The colour vocabulary

Poltergeist's D34 (its `docs/plan/00-OVERVIEW.md`, "Colour that means
something") gives both apps one set of twelve family hues, each with
one meaning: blue for places and folders, cyan for motion, teal for
saved recipes, green for go, yellow for attention, orange for code, red
for destruction and PDF, pink for images, purple for audio, video and
the assistant, indigo for sync, brown for cargo, graphite for the rest.
The owner asked for it for both apps at once: the chrome's glyphs had
become too bland to tell apart.

- **The table** is `lib/family_hues.dart` here and
  `lib/theme/family_hues.dart` in Poltergeist, byte-identical:
  `FamilyHue`, a `FamilyPalette` theme extension with per-theme glyph
  tints (registered in `SeanceTheme`), and `FamilyHueTile`. Change it
  in both, in the same pair of changes.
- **The rule** is D11's quiet chrome with colour on glyphs only: the
  surfaces, the accent and the status dots are untouched, text stays in
  the ink, and a coloured verb keeps its colour only while it is live.
- **The kind table** in `lib/ui/file_kinds.dart` is a port of
  Poltergeist's `pane_format.dart` classifier and `kind_glyph.dart`
  glyphs, so a folder, a photo or a script reads the same in both
  Files views.
- **Here it colours** the side panel's tabs (the Assistant purple,
  Snippets teal, Files blue, Git orange, each glyph over its label, the
  underline in the open tab's hue), the Files listing's kinds and its
  Home, download, upload and finished-transfer glyphs, the Git pane's
  glyphs and its Stage (green) and Discard (red) verbs, the assistant's
  sparkle and the command generator's wand, the snippets' glyph and
  their suggestions' bulb, and the Settings tabs. Git's status letters
  are text and keep their colours: the family green is below 4.5:1 on
  the light panel.

## Cross-app behaviors worth knowing about

- In shared-account mode Poltergeist reads `serverConfig` records
  **read-only** (the user's Séance servers appear as ready-made bookmark
  sources), syncs host-key pins bidirectionally as standard
  `hostkey:<host:port>` records — the same trust the user's other Séance
  devices already exchange — and therefore extends TOFU trust to every
  app on the account. The moving parts, one per sub-bullet:
  - **Endpoint pinning — connect-time, record-agnostic.** Each
    Poltergeist device records the endpoint it bookmarked, and
    connecting to any endpoint that differs from the
    recorded one costs a one-time confirmation on that device (and a
    device with nothing recorded yet prompts on its **first** connect:
    the record is only ever written by a local user act — creating the
    bookmark on this device, or confirming a connect — never seeded from
    a synced-in record, or a fresh device bookmarking an
    already-rewritten server would record the attacker endpoint and
    connect silently).
    Confirming *replaces* the recorded endpoint, never adds to an
    allowlist, so flip-flopping between two previously confirmed
    endpoints re-triggers the check every time and cannot redirect
    silently; and the dialog shows the recorded endpoint beside the new
    one (old → new, plus which record kind delivered the change) — a
    generic prompt indistinguishable from first-connect TOFU would train
    exactly the click-through an attacker needs — whether
    the change arrived through a Séance-side `serverConfig` edit or a
    rewritten `bookmark:` record (Poltergeist devices legitimately write
    that kind, so a compromised one could LWW-rewrite either record and
    redirect a connection to a credential-collecting host that no pin
    conflict would ever flag).
  - **First-seen keys, and the account key's true scope.** Where a
    device holds no local pin to conflict with, a synced pin is
    applied as trusted with no warning (that silent propagation *is* the
    multi-device pin-sync feature), which means one compromised device on
    the account can mint trust for hosts the fleet has never seen — a
    residual risk the shared-mode setup copy must disclose, quarantine or
    no quarantine — alongside the broadest exposure underneath all of
    this: any app signed into the shared account derives the account key
    and **can decrypt every synced record**, `secret` records (stored
    credentials) included, not only the kinds it writes. Poltergeist's
    never-decrypt dispatch for `secret:`/`snippet:` ids (its plan's
    04 §3.2) is an implementation courtesy that keeps the vault out of
    its memory, not a cryptographic boundary — the setup copy says so
    plainly rather than letting the narrower pin warnings imply the key
    is scoped.
  - **Forgetting a host tombstones the pin.** The inverse path is
    specified too: removing a locally
    trusted pin ("forget host") **tombstones the matching `hostkey:`
    record** — a present record with no local pin is exactly the
    first-seen auto-apply state above, so without the tombstone the
    untrusted key would silently resurrect on the next pull or startup
    re-derivation diff (the pin analogue of #54's resurrection, in the
    very section built to prevent that class; a tombstone that later
    loses LWW to a genuinely newer pin edit resolves to the edit — the
    intended semantics). The cross-device half is specified too:
    **pulling that tombstone on a device that still trusts the key
    drops its local TOFU pin** — forget-host is a fleet-wide act, and
    a device that kept local trust would re-push the forgotten key
    under a newer LWW tuple on its next local pin write, resurrecting
    it everywhere (removal is also the fail-safe direction: the next
    connect there falls back to a first-connect prompt, never to
    silent trust — unlike replacement, which the quarantine gates);
    and the startup re-derivation diff classifies "tombstoned record,
    no local pin" as **resolved**, never a conflict — re-arming a MITM
    warning after every forget would train exactly the dismissal the
    warning must not.
  - **Conflicting pins quarantine — durably.** A synced pin that
    conflicts with a
    locally known key must surface a user-visible warning (treated as a
    possible MITM), never a silent overwrite — and the conflicting incoming
    pin is **quarantined at the application layer**: held unapplied to the
    local TOFU store until the user resolves the warning — and durably
    so: quarantine state survives restarts and a dismissed dialog,
    persisted or (simpler and self-healing) **re-derived at startup by
    diffing the stored `hostkey:` records against the local TOFU store**,
    because a persistent record store advances its pull high-water mark
    past the merged record and never re-delivers it to re-arm the warning
    (the same no-refetch property the PR-S1 preserve path notes above) —
    a memory-only quarantine would silently evaporate on restart while
    the store keeps the attacker's pin as the LWW winner.
  - **LWW merge stays; the trusted apply is what's gated.** The record store
    itself still merges by LWW (the wire behavior stays untouched, per the
    never-touch list above); what is gated is applying the synced key as
    trusted — otherwise a newer LWW tuple from a compromised device would
    replace the locally trusted key and the warning would be cosmetic.
  - **Resolution semantics.** **Keep local** re-pushes the kept pin under a
    newer LWW tuple, so the user's trust decision becomes canonical — the
    conflict stops re-arming here and stops firing on devices that never
    applied the conflicting pin. One caveat: a device that already chose
    **accept synced** holds the conflicting key locally, so the canonical
    pin fires one more warning there — and opposite answers ping-pong
    (each keep-local re-pushes its own key under a newer tuple, re-arming
    the other side) until the affected devices agree; convergence costs
    **at least** one resolution per device that applied the conflicting
    key — and keeps costing more for as long as devices keep giving
    opposite answers (the floor holds only once they stop opposing).
    **Accept
    synced** applies the quarantined key.
  - **The weakest device bounds the protection.** Séance
    itself currently applies pulled pins unconditionally
    (`sync_coordinator.dart` — filed as
    [#56](https://github.com/L-K-M/Seance/issues/56)), so until that lands,
    shared mode silently overwrites trust on Séance devices even while
    Poltergeist quarantines.
- Poltergeist writes only `bookmark:` and `hostkey:` records; it never
  edits `serverConfig`/`secret`/`snippet` records and never exposes
  `DELETE /v1/account` in shared mode (that endpoint nukes both apps'
  data).
- Record sizes are a few hundred bytes — far under the server's 1 MiB blob
  cap; sync tokens coexist per app (one row per login, no expiry).
