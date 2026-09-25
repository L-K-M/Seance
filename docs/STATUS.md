# Status & next steps

Living snapshot of where Séance is, what's proven, and what to pick up next.
Read [AGENTS.md](../AGENTS.md) first for how to build/test.

Review update (2026-09-12): fixed defects in shared-credential sync and
enrollment, concurrent persistence, assistant lifecycle, and terminal behavior.
See [the review findings and verification](review-2026-09-12.md).

_Last updated: 2026-09-25. Séance has themes: one editable palette per
device, started from ten presets and changed live on a new Appearance tab
in Settings. Before that, on desktop, Settings opens in a window of its
own instead of covering the app: a second native window on a second
Flutter engine, which reaches the app's state over a link the runners
relay between the two engines; closing it hides it. Before that, the
server list has its two views back, on the
rail, on tablets and on the phone home: comfortable (the default) draws
two lines under the 32 px badge with the colour line, the connected ring
and a visible "⋮", compact keeps the one-line rail, and a switch in the
bottom bar, the home app bar and macOS's View menu picks between them.
Before that, the server list became the sibling sidebar Séance
shares with Poltergeist: a rail with PINNED and SERVERS sections,
rows with one status dot, a filter, and a bottom bar with "+", sync status
and Settings, over a kit ported from Poltergeist (see
[POLTERGEIST.md](POLTERGEIST.md#the-sidebar-kit)); on a phone the same list
is the home screen. Before that, Android's system back no longer closes the app
from the narrow terminal screen (which ended every live session), and walks
up the Files tree before leaving it; the built-in editor keeps a checkout's
permissions when it saves and highlights CSS, Ruby, Perl and Lua (both
ported from Poltergeist); the Linux and Windows windows are titled Séance,
and every desktop window first opens at 1280x800. Before that,
the built-in file editor opens as a tab in the
owning server's strip — beside the terminals the file was browsed through —
instead of a route that covered the whole app; an unsaved buffer marks the
tab and is confirmed away, and the tab follows its session across a
reconnect and dies with it. Before that,
a server's colour is a line down the leading edge
of its row *and* the fill under its mark: the line is the carrier every kind
of mark keeps, the fill the echo a glyph or an emoji adds to it. Before that,
the server list gained signals the eye can pick out for which row is selected
and which servers are connected,
a server's colour could be one of the user's own, an SVG could
be its image, and Return saved the editor. Before that, the server list gained a compact row and
pinning: the app bar's density switch trades the address line for a row that
is 40 px instead of 72, and a pinned server sits in its own section at the top
(device-local, never synced). Before that, a single record past the server's
per-record blob
cap no longer stopped the whole account's sync: that cap is advertised alongside
the other two, and such a record is now pushed alone and last. An emoji mark
must also carry a character of its own — a lone joiner or combining mark was
accepted and painted an empty badge. Before that, the
terminal font could be picked from the fonts
actually installed on the host; a drag through the empty area under the shell
prompt no longer paints a selection over it; and a server's mark can now be one
of 77 built-in glyphs, an emoji, or an imported image. The "Add server" button
also no longer covers the last row's menu. The TOFU
host-key dialog's review content is
now scrollable, so the changed-key warning and both fingerprints stay
reachable and the buttons stay pinned in constrained layouts (ported back
from Poltergeist); the TOFU and keyboard-interactive dialogs now
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

## Themes (2026-09-25)

Vervellum's theming model, ported to the app: one editable theme per
device, not a library of saved ones. Settings has an Appearance tab
(second, after General) with ten presets (Séance, Graphite, Paper,
Newsprint, Solarized, Midnight, Terminal, Vapor, Bubblegum, High
contrast). A preset is a starting point, not a mode: picking one copies
its values in, and every value then stays editable, with the app and the
settings window repainting on each change. There is no Save button.

**The model.** `ThemePalette` (`lib/theme/theme_palette.dart`) is one
JSON object under `themePalette` in `settings.json`, with the mode under
`themeMode` (`ThemeModePreference`: system, light, dark). Both are
device-local like the terminal's appearance and never sync; a test pins
that neither reaches the assistant record's fingerprint. The decode is
lenient: a missing or unreadable accent or corner scale takes the default
preset's, an unreadable Automatic-able colour is Automatic, a terminal
block is taken whole or not at all, and garbage under the key is the
default. Colours read `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA` (alpha
last, as CSS writes it; `#` or `0x` optional) and write `#RRGGBB`, or
eight digits when translucent. Only the lines and the selection keep an
alpha; every other colour is stored opaque. A preset is recognised by its
values, not its name (`matchingPreset`), and every edit renames the
palette to the preset it now matches or "Custom".

**Automatic.** Every slot but the accent can be Automatic (null). The
default preset leaves all of them Automatic and its accent is the violet
seed, which keeps the tables' hand-tuned primary family, so an install
that never opens the tab draws exactly what it did:
`theme_build_test.dart` compares the colour scheme, the chrome, the
status colours, the type ramp and the component themes with the theme as
it was built before, from the tables written out in the test, at both
brightnesses on desktop and mobile. While the surface is Automatic,
Automatic slots are the sibling tables for the mode's brightness. Once a
palette sets its own surface, that surface decides the brightness (by
`ThemeData.estimateBrightnessForColor`: dark below a relative luminance
of about 0.34, Material's cut-off, which leans toward light text), the
mode control is disabled with a line saying why, and the Automatic slots
are mixed from that surface and the palette's text instead: the tables'
slate rail beside a Solarized pane would be neither theme. Mixed from
the dark table's own surface and text, the ratios land within 6 units
per channel of its container ladder and lines (within 18 of its bluer
secondary text and outline). Any accent other than the seed is drawn as
picked; an Automatic selection pill for it is the accent darkened until
white text clears 4.5:1, and the pill's label (`onSelection`) is white or
black by contrast.

**Where it lands.** `SeanceTheme.build(palette, brightness)` builds the
ThemeData; `light()`/`dark()` are the default palette. The chrome takes
its colours from the resolved palette, the four status colours moved to
a `SeanceStatusColors` theme extension that `StatusColors` reads (their
old brightness-aware values are the Automatic ones), and the corner scale
(0 to 2) reaches the dialog, card, menu, popup menu, tooltip, input,
filled/outlined/text button, segmented button, chip, bottom sheet and
snack bar shapes. At exactly 1 those components keep Material's own
shapes, stadium buttons included. `SeanceChrome.cornerScale` and
`corner(base)` carry it to hand-drawn shapes: the sidebar kit's pills,
focus rings, icon buttons, filter field and sync chip. The interface font
is a family name handed to the platform (null for its own), picked from
the installed-font picker without the monospace filter; terminals and
code keep their monospace stack. A terminal whose Colors setting is
"Follow the app theme" uses the palette's terminal block when it has one
(search highlights derived from its yellow and cursor); "Always dark" and
"Always light" keep the built-in palettes.

**Rebuilding.** The app's MaterialApp listens to
`AppState.appearance` (a `ValueListenable<AppAppearance>`) and to nothing
else, so it rebuilds for a theme change and never for the connection,
probe and tab changes AppState notifies for (`bootstrap_test.dart`).
`LocalSettingsBackend.setAppearance` applies before it saves, like the
terminal's appearance, and is a no-op when nothing changed; the link has
a `setAppearance` case both ways. The settings window's MaterialApp
listens to `RemoteSettingsBackend.appearance`, which each snapshot
updates and which notifies only when the theme in it changed. The tab
coalesces its writes: one in flight at a time, and changes made meanwhile
fold into one write of whatever is current after it, so a corner drag is
not dozens of saves and round trips.

**The tab.** Theme (the preset grid, each tile drawn in its preset's
surface, text, accent, status colours and corners), Mode, Colours (accent
plus seven slots, each with an Automatic box), Status colours, Terminal
colours (a switch, background, text, cursor, selection, the 16 ANSI
colours as two rows of eight, and a preview), Shape and type (interface
font, corners), Share (Copy theme puts pretty JSON on the clipboard;
Paste theme decodes leniently, and text that is not a theme at all shows
a toast and changes nothing) and Start over (Reset to Séance, confirmed;
the mode is kept). A colour handed back to Automatic is remembered for
the session, so unticking Automatic again restores it; otherwise a slot
leaves Automatic at the colour it draws right now, never black. The
colour picker is `lib/ui/color_picker.dart`, generalised from the server
colour picker (which is now a thin wrapper with its badge preview) with
an optional preview and an optional opacity slider.

**The presets.** Vervellum's colours, with every slot Séance needs
derived for the eight that bring their own surface: rail, headers, lines,
selection, four status colours and a terminal palette (Solarized's is the
official one). `theme_presets_test.dart` holds each, at every brightness
it can draw at, to: text on the surface and on the rail at 4.5:1,
secondary text at 4.5:1 (Solarized at 3:1: its hierarchy puts secondary
text below base0, itself 4.7:1 on base03), the accent as drawn and every
status colour at 3:1, four distinct status colours, the selected row's
label at 4.5:1, and the terminal's text at 4.5:1 with its normal ANSI
colours at 3:1 (Paper's at 4.5:1, all sixteen). Bubblegum's accent is a
shade deeper than Vervellum's #FF59AD, which is 2.7:1 on its own surface.
The family glyph hues (see "Colour that means something" below) keep
3:1 on every preset's surface and rail too, in both modes; they follow
the drawn brightness, not the palette.

**Not ported.** Vervellum's `backdrop` (glass, frosted, solid) has no
Flutter equivalent without a vibrancy plugin; `fontDesign` (system,
serif, rounded, monospaced) cannot be addressed portably by name and is
replaced by the font family; its verdict colours are Séance's four
status colours; its scrim and card fill are panel-specific.

**Known limits.** Editor syntax colours still follow the brightness, not
the palette. Server badge fills and accent lines are derived per
brightness as before, not per palette. The bootstrap spinner draws in the
default theme, because the settings are read during bootstrap, and the
user's theme fades in when the shell appears. The sidebar kit's corner
change is Séance-only for now (see
[POLTERGEIST.md](POLTERGEIST.md#the-sidebar-kit)). Verified by the test
suite only: the tab has not been driven in a built app on any platform.

**Poltergeist.** It should get the same model: its
`lib/theme/app_theme.dart` keeps "the tables in step" with Séance's
`lib/theme.dart`, so the palette, the presets, the Automatic rules and
the tab port with the chrome's rename, and its kit copy then takes the
corner change.

## Settings in its own window (2026-09-25)

On macOS, Linux and Windows, Settings (⌘, / Ctrl+, the bottom bar's gear,
"Sync off", "Open Settings" in the assistant panel) opens a window of its
own, titled Settings (Séance Settings on Linux and Windows), 760x640 over
the app's window. Choosing Settings again brings it forward on the tab
asked for. Phones and tablets keep the route, and so does a desktop runner
that has no settings window.

**Why a second engine.** Flutter stable has no multi-window API: the
framework's windowing classes are `@internal` and gated on the `windowing`
feature, which the 3.47 tool offers on the master channel only, and the
macOS embedder only admits a second view on one engine after a private
`enableMultiView`. So the window is a second `FlutterViewController` /
`FlView` with its own engine, started with `--seance-settings-window`,
which `main` turns into `runSettingsWindow` instead of the app. The two
isolates share nothing.

**The link.** Each runner (`macos/Runner/SettingsWindow.swift`,
`linux/runner/settings_window.cc`, `windows/runner/settings_window.cpp`)
owns the window and relays every message either engine sends on
`seance/settings_link` to the other, byte for byte, with the reply; the
app's engine also gets `seance/settings_window` (`open` in, `closed` out).
On top of that, `SettingsBackend` (`lib/services/settings_backend.dart`)
is everything the screen reads and does. `LocalSettingsBackend` is the
logic the screen used to hold — the assistant save's keys-first ordering
and adoption guards, the sync switches' rollbacks, the keep-alive race —
moved out unchanged in substance and now under test
(`local_settings_backend_test.dart`, which the screen never had). The
route uses it directly; `SettingsWindowHost` answers the window's
`RemoteSettingsBackend` with it and pushes a snapshot (the settings JSON,
the configuration version, the sync status) whenever the app's state moves
something the window shows. Payloads are JSON strings both ways. The
screen's own pre-check of the configuration version before Save is gone:
against a snapshot that can trail a save result it read the lag as an
adoption; the backend's guard, against the live version, is the one that
counts. The per-change writes on General and Files now report a failure
("… not saved — reason") instead of leaving an unhandled async error behind
a control that looks saved.

**Closing hides.** The window and its engine are created on first use and
kept until the app's window closes (which takes the settings window with
it, so the app still quits with its window). Measured on Linux under
Xvfb: disposing the second engine terminates the EGL display every engine
in the process shares (`fl_opengl_manager` calls `eglTerminate`), and the
app's window then dies with a GLX `BadAccess`. Hidden, nothing is torn
down, and reopening is immediate. The screen is not kept: the window
unmounts it on `hidden` — dropping anything typed into the key fields —
and mounts a fresh one from the settings as they are on `show`. Linux also
needs its own `delete-event` handler, connected before the view: `FlView`
hooks its window's and asks Dart whether the whole application should
quit, which the framework answers yes.

**Quitting stays the app's call.** On macOS every engine makes itself the
app delegate's termination handler when it starts, so once the window
exists ⌘Q asks the window's isolate, whose framework answers "exit" with
no observer to ask. The window forwards the request over the link and
the app's isolate answers with its own `handleRequestAppExit`. Séance
registers no exit observer today, so nothing changes for it now; the
forwarding keeps it that way when one is added (Poltergeist's quit guard
is one).

**Verified.** Dart: the link end to end over an in-memory relay
(`settings_window_test.dart`: hello, writes, results and errors crossing,
snapshots, hide/show, tab switching, the no-host and no-window cases), the
backend (`local_settings_backend_test.dart`) and the screen against a fake
backend (`settings_screen_test.dart`). Linux: built and driven under Xvfb +
openbox — open from the button and the "Sync off" chip, a switch written
through to `settings.json`, close, the app's window still drawing, reopen
on the requested tab, a tab switch on the open window, and closing the
app's window quitting with status 0. Under Xvfb the second engine draws
only with GDK on EGL (`GDK_GL=gles`) or Skia: with GDK on GLX its
compositor cannot make its context current, a mixing limit of Xvfb's
software GL that the app's own window, which mixes the two as well, does
not show on real drivers — not verified on a GPU. macOS and Windows: CI's
client builds compile the runners; neither has been run.

**Known limits.** The macOS menu's New Tab (⌘T) and Generate Command…
(⌘K) still act on the app's window while Settings is key. Settings'
window size and position are not remembered. Edit ▸ Copy/Paste now reach
a terminal only when the app's window is key, so the Settings window's
fields get the native actions. Closing the window discards what was typed
into its fields and not saved, the API keys included; a reopened window
starts from the settings as saved.

## Colour that means something (2026-09-25)

The owner found both apps' glyphs too bland to tell apart and asked for
the colour-coded icons of iTunes, Postbox and the old Finder sidebar.
Poltergeist's D34 records the shared vocabulary;
[POLTERGEIST.md](POLTERGEIST.md#the-colour-vocabulary) has this side's
record.

- **Palette:** `lib/family_hues.dart`, identical to Poltergeist's, with
  the `FamilyPalette` extension in `SeanceTheme`.
- **Side panel:** each tab's glyph in its hue over its label (the
  labels had been clipping at the panel's usual width), the underline
  blending to the open tab's hue as it slides.
- **Files:** kind glyphs from `lib/ui/file_kinds.dart` (ported from
  Poltergeist); Home blue, downloads and uploads cyan, a finished
  transfer green and a failed one red.
- **Git:** the header, repo folder and branch glyphs, a clean tree's
  check, Stage in green and Discard in red; the status letters are
  unchanged.
- **Elsewhere:** the assistant's sparkle and the wand purple, the
  snippets teal with a yellow suggestions bulb, and the Settings tabs.
- **Tests:** `family_hues_test.dart` (every hue at 3:1 on every chrome
  surface and the tab strip, at rest and hovered, and every tile glyph
  on its fill), `file_kinds_test.dart`, and
  `family_hues_capture_test.dart`, which checks the tab hues and the
  underline and writes before/after PNGs with `SEANCE_CAPTURE=1`; this
  change's pair is in `docs/captures/d34-colour/`.
- **Not verified here:** the running app on a device or desktop; the
  captures are real-font widget renders on Linux.

## Two views of the server list again (2026-09-25)

The owner's call after the kit port below: aligning the two sidebars
lost "the two views", so both apps now offer a compact and a comfortable
density, comfortable by default on every platform (Poltergeist's plan
records the decision as D33, "Sidebar density and restored row detail",
in its `docs/plan/00-OVERVIEW.md`). This supersedes the port's "the
density preference survives here only" and its one-line rail.

**Density.** The kit gained `SidebarKitDensity` (its record is in
[POLTERGEIST.md](POLTERGEIST.md#the-sidebar-kit)). `ServerListPane` maps
the stored `serverListDensity` to it in one place and every posture
follows it: the desktop rail, a tablet's touch rail and a narrow desktop
window draw the rail at that density, and the phone home is the Android
list when comfortable and one-line touch rows when compact (the kit's
`sidebarHomeLayout`), so the two gates that each decided "comfortable
home" are gone. `toJson` always wrote the preference and its old default
was comfortable, so an existing install comes back comfortable, which is
the look the owner asked for.

**Rows.** Comfortable rows are 52 px (56 on touch) with a 32 px
`ServerBadge`, the neutral tile behind an uncoloured glyph, a 14 px title
and a 12 px second line; compact is the port's 26 px row, unchanged. The
tile always hands the kit its second line and the kit draws it only when
comfortable: `user@host` (the port only when not 22), led by the state
when a session is connecting, failed or blocked or the probe found the
host unreachable ("Connection failed · deploy@host", Poltergeist's
order). The server's colour is the kit's 4 px accent line in both
densities, so the frame an image mark wore in its place is gone, and the
editor's and colour picker's previews of `ServerAccentBar` describe the
list again. A connected session rings the badge in green beside the dot
(the kit's `markRing`, not `ServerAvatar`, which stays unused by the
list). The "⋮" is the kit's default: drawn when comfortable or on touch.
Headers draw their count, chevron and SERVERS' "+" at rest when
comfortable.

**Blocked.** A connect whose host-key prompt was shown a changed key
(the verdict `changed`) and answered no, because the user declined or
the unwired prompt refused by default, sets
`TerminalSession.hostKeyBlocked`; a declined first use stays an ordinary
failure. `_connect` wraps the prompt per attempt (`_HostKeyAttempt` in
`app_state.dart`) and reads the verdict and answer from there. It first
read the error instead, the core's `SshConnectException.isHostKeyRefusal`
plus a pinned-key lookup, but dartssh2 raises the same host-key error for
an RSA or ECDSA key-exchange signature that fails to verify, and checks
that before the key reaches the prompt, so a pinned host whose key never
changed read as blocked. That is now an ordinary failure, its error shown.
`isHostKeyRefusal` stays in the core unchanged (Poltergeist consumes the
core through a git pin); the app no longer reads it. Its row draws the
kit's blocked dot (the no-entry sign Poltergeist uses) and says
"Connection blocked" with what unblocks it. dartssh2 does not throw its
host-key error: it reports an authentication abort that carries it as
the reason, so `isHostKeyRefusal` unwraps that. The first cut checked
only the bare error and never matched a real connection;
`ssh_host_key_refusal_test.dart` now drives dartssh2's real key
exchange through a fixture socket, and a check against a local OpenSSH
`sshd` gave the verdict `changed` and a refusal. The app half is tested
in `host_key_blocked_test.dart`, which replays a handshake at
`AppState`'s `openSshSession` seam: the key goes through the real TOFU
check and prompt (`SshSessionManager.verifyHostKey`), and the failure is
built from dartssh2's own error types (an app dev dependency now, pinned
like the core's). The dot and the copy are tested apart, with
`hostKeyBlocked` set directly.

**Hidden live sessions.** A folded group, or a filter, that hides a
connected or connecting server puts its dot on the header hiding it
(`hiddenByHeader` in `server_grouping.dart` picks the innermost header
still on screen). The header also says so: the kit's
`SidebarSectionHeader.statusLabel` comes with its dot, and the pane
passes "Connected server hidden" or "Connecting server hidden" (the
row's word for the state), which the header's merged label carries on
a line after its title and count. Before, the dot was drawn only, so a
folded group hiding a connected server was silent to a screen reader.
While a query is live, a section the filter empties keeps its header
when a live server is among what it hid (Poltergeist's rule,
`sectionsHoldingLive`), so the server's dot still has a header to show
on; with nothing live hidden, the section goes as before. A kept header
counts 0 and is not a match: "No servers match" shows under it and
Enter opens nothing.

**Switches.** The kit's `SidebarDensitySwitch` sits in the rail's bottom
bar and, in a scope of its own, in the phone home's app bar, replacing
the segmented button. On macOS, View opens with "Use Compact Sidebar
Rows" or "Use Comfortable Sidebar Rows", one item whose title Dart sets
over `seance/menu` (`setServerListDensityTitle`); the item calls
`toggleServerListDensity`. The channel's Dart half moved from `main.dart`
to `installMacMenu` in `app_menus.dart`, where `mac_menu_test.dart`
drives it over a mocked channel. The Swift half was not compiled here
(no Swift toolchain on Linux).

**Filter.** The field shows from five servers again (both apps had five
before the kit), and the count reads "N of M · ↵ opens the first" while a
match exists. `ServerListPane.revealFilter()` returns false and latches
nothing on an empty list, where it used to pop the field open once the
first server arrived.

**Verification.** `server_list_capture_test.dart` now renders the rail
comfortable and compact, the rail at its 200 px minimum, a tablet rail,
the phone home and a narrow desktop window at both densities, and a
folded group keeping its dot. Not verified: macOS (the View menu item,
VoiceOver), a real tablet, and the blocked row in a running app against
a real server (the core half was checked against a local `sshd`).

## The server list is the sibling sidebar (2026-09-24)

**The kit.** Poltergeist rebuilt its sidebar (its plan, 10 §5) on
`lib/ui/sidebar/sidebar_kit.dart`, written for Séance to copy. It is
ported from Poltergeist 58605fa to the same relative path here, so a
`diff` of the two files shows only the chrome seam (`_chrome()` returns
`SeanceChrome`) and the changes listed in
[POLTERGEIST.md](POLTERGEIST.md#the-sidebar-kit) for porting back: a
hollow ring dot, a host-named row surface, a second line and a "⋮" for
touch lists, a trailing standing icon, touch extents, and fixes for a
keyboard-opened row menu the keyboard could not operate, a touch verb
sheet capped at 9/16 of the screen, and a focus ring that shifted rows
by 2 px. Its tests are ported with it.

**The rail.** In the wide layout `ServerListPane` (posture `rail`) has no
app bar. PINNED leads when anything is pinned; SERVERS lists its
ungrouped servers first, then each group as a nested disclosure row
(`server_grouping.dart`'s new `ServerSidebarSections`); folds persist in
`collapsedServerGroups`, now including the SERVERS key. A row
(`server_tile.dart`) is one 26 px line: the mark at 18 px (a plain glyph
for an uncoloured server, as Poltergeist draws it; the badge for a
coloured one, framed in the colour when an image covers the fill), one
dot, the middle-ellipsized name, `×N` past one tab, and a cloud-off mark
for a server kept off sync. The selection pill marks the server of the
focused session; the ring shows only in keyboard mode. The dot
(`server_status_dot.dart`) means the same in both apps: solid green
connected, amber connecting, red failed, a hollow green ring when the
probe reached a host nothing is connected to, none when unknown. The
probe's "unreachable", which the contract leaves open, is a hollow red
ring. Right-click opens the verbs at the pointer (Connect, Connect in new
tab, Disconnect, Reconnect for a lone dead tab, Pin to top or Unpin,
Edit…, Duplicate, Delete…), Shift+F10 and the Menu key open them with
focus inside, and a connected row shows an eject glyph on hover. ⌘-click
(Ctrl-click off Apple platforms, where Control-click is the secondary
click and opens the row's verbs, as right-click does) opens another tab. The filter shows at eight servers (it was
five; superseded on 2026-09-25, five again, see above), while a query is live, or on ⌥⌘F (Ctrl+Alt+F off Apple
platforms, where the terminal keeps the chord for the shell); Esc
clears, then closes, and Enter opens the first row shown. The bottom bar
has a "+" menu (New server…, Import SSH config…; Séance has no group
entities, so no New group), the sync chip ("Sync off", "Syncing…",
"Synced · 2 min", or red "Sync failed" whose click retries), and the
gear. The update banner stays above the list, compacted. There is no
drag-reorder to keep: the store sorts by label.

**The home.** In the narrow layout (posture `home`) the list is the full
screen with its app bar (sync indicator, density switch, import,
settings) and a "+" button for a new server. Rows take the platform's
extent (48 dp on touch, with a 24 dp mark) and a visible "⋮"; a
long-press opens the same verbs as a sheet. The density preference
survives here only: comfortable adds the address as a second line,
because touch has no hover to show the tooltip; the rail's rows are one
line by the anatomy. (Superseded on 2026-09-25: every posture follows
the density again, see above.) Back from the terminal returns to the list with its
query and scroll offset, kept in the route's page storage. The back
handling from a938373, 6643a3b and 367e4ea is untouched and its tests
pass.

**Verification.** `server_list_capture_test.dart` renders both postures
in both brightnesses with DejaVu Sans at 2x (written only with
`SEANCE_CAPTURE=1`, to `SEANCE_CAPTURE_DIR`). A `flutter build linux
--debug` run under Xvfb was driven with `xdotool`: importing hosts
through the empty state and the "+" menu, the filter appearing at nine
servers, a connecting then failed dot, right-click and Esc on a row
menu, Ctrl+Alt+F filtering to "2 of 9", and the narrow home. It showed
the focus-ring shift that the kit fix removes. Not verified: a real
Android device (system back, TalkBack), macOS (⌥⌘F, VoiceOver),
Windows, and a live SSH session's green dot outside tests. 830 Flutter
tests pass after the review rounds (812 at the port) and `flutter
analyze` is clean; the pure-Dart packages were not touched.

`ServerAvatar` (the badge with a connected ring) is no longer used by
the list; its tests stay until the editor or a sibling decides whether
to keep it.

## Back keeps sessions; editor saves keep modes (2026-09-24)

**Android back.** The narrow layout switches to the terminal with a state
flag, not a pushed route, and nothing handled a system back there. It
reached the root route, bubbled to `SystemNavigator.pop`, and
`FlutterActivity` answered with `finish()`; `MainActivity.onDestroy` then
stopped the keep-alive service, so one back press ended every live SSH
session. `AdaptiveShell` now wraps the narrow panes in a `PopScope` that
blocks the pop while the terminal shows and returns to the server list, as
the app bar arrow does. A blocking `PopScope` outranks the route's local
history, so the handler lets an open drawer close first. On the server list
the back stays the platform's. On the pushed Files screen, system back
climbs one folder per press (`RemoteFilesController.canGoUp`, shared with
the header's Up button) and leaves at `/`, or once a listing has failed so
an unreadable parent cannot trap it; the app bar arrow pops outright from
any folder. The manifest sets `android:enableOnBackInvokedCallback`, so
Android 13+ hands a back to Flutter only while one of these scopes wants it.
`narrow_back_navigation_test.dart` drives real system backs through
`handlePopRoute` at 400 px wide; the terminal and Files cases failed before
the fix (the back went to the platform, and Files popped instead of going
up). Not verified on a device. On Android 12L and older, back on the server
list still reaches `finish()` and ends sessions, as it did before; on 13+
the system's own back-to-home should background the app instead.

**Editor saves (ported from Poltergeist).** Poltergeist's hardened copy of
the built-in editor's document I/O
(`packages/poltergeist_core/lib/src/editor/built_in_text_document.dart`)
fixed defects this file still had, and they are ported back. The temp file
was created at the default umask and renamed over the checkout, so a save
turned a 0600 checkout into 0644 and dropped a script's execute bits. The
temp is now owner-only before its first byte and takes the original's
permission bits (`applyPermissionBits`, beside `restrictFileToOwner`) just
before the rename. A symlinked checkout is refused on open as well as on
save, and a failed digest read in the conflict guard restores the original.
Refusals are `BuiltInEditorException`, whose text is the bare sentence, so
the editor no longer shows `Bad state:` prefixes. A save whose write
committed after its tab closed used to skip the reconcile or upload; it now
runs them, as Poltergeist's editor does.

One deliberate divergence: Poltergeist strips the BOM from the bytes and
decodes the rest, but `Utf8Decoder` drops a BOM at the start of whatever it
is handed, so a file that starts with two BOMs loses the second, which is
content. Séance skips every leading BOM and restores all but the first as
U+FEFF, so such a file round-trips byte for byte. Worth porting the other
way.

**Syntax parity (ported from Poltergeist).** CSS/SCSS/LESS, Ruby, Perl and
Lua families, `.htaccess`/`.htpasswd` as ini, Ruby/Perl/Lua shebangs,
`multilineStringPairs` for Lua's `[[ ]]`, and a guard for optional meta
groups (which threw before). The palette stays Séance's. Language detection
now takes the basename after `\` as well as `/`. Poltergeist lists
`font-face` as a CSS keyword; keywords are single identifiers that stop at
`-`, so it can never match and is left out here. Perl's `#` comments
start anywhere in Poltergeist; here, as for Ruby, only at a line start
or after whitespace, so `$#list`, `s#a#b#` and `s/#.*//` stay code and
only a comment glued to code (`1;# note`) is missed. Worth porting the
other way.

The status bar's byte count is cached per text instance and counted without
encoding the buffer. The Linux runner titles its window Séance (it said
`seance_app`) and opens at 1280x800; a `flutter build linux --debug` run
under Xvfb reported exactly that through `xdotool`. The Windows runner now
titles its window Séance too (it said `seance_app`), and it and the macOS
window first open at 1280x800 instead of 1800x1600; neither was built
here. The Windows version resource (`Runner.rc`: `FileDescription` and
`ProductName`, which Explorer and Task Manager show) deliberately says
ASCII `Seance`, the spelling the macOS `PRODUCT_NAME` keeps: an accent
there needs the resource script to declare its code page
(`#pragma code_page(65001)` for UTF-8), and nothing here can build
Windows to check how it renders.

755 Flutter tests pass (32 new) and `flutter analyze` is clean; the
pure-Dart packages were not touched and analyze clean.

## The editor is a tab, not a screen (2026-09-19)

The built-in file editor used to open as a pushed route: every file took the
whole window, and the shell it was checked out through — and every other
file — was a navigation away. It now opens as a tab in the owning server's
strip, beside the terminals, sharing their `IndexedStack` so a switch keeps
buffer, caret and scroll the way it keeps a terminal's state.

`AppState.sessions` is a list of `PaneTab` — `TerminalSession` or `EditorTab`
— so the strip, the per-server grouping and the close-fallback chain were
already the right shape; editor tabs ride on the same invariants (a server's
tabs stay contiguous, one is active) and are skipped by everything
terminal-only. Ownership is keyed on the session's durable `editSessionId`,
the identity a reconnect preserves, so the tab survives one; closing the
session still deletes the checkout it writes to, so its editors close with
it — after asking about each unsaved buffer. A dirty buffer turns the chip's
close button into the filled dot and the tooltip says so. Everything that
needs "the current session" — Files, Git, the assistant, command insertion —
still gets it: for an editor tab that is the session that owns the checkout.

## The list's marks, tightened (2026-09-14)

Three consistency fixes in the server list:

- A border on a badge now means one thing: the session is connected. A
  dropped or connecting session used to keep a ring of its own — grey, or a
  highlight sweeping the frame while connecting — which read as a stray
  outline on rows that were not live. `ServerAvatar` draws the ring only
  while `connection == connected`, and the sweep and the per-status colours
  went with the other states.
- The selected row's bar is painted over the tile as a foreground
  decoration rather than through the tile's shape: a shape border insets
  the content by its width, which sat the row a few pixels right of every
  unselected one.
- An emoji mark is painted with its ink centred in the badge instead of a
  `Text` in a `FittedBox`: centring the cluster's advance box left the
  glyph wherever the system font's bearings put it — visibly left and low.

## The badge wears the colour again, beside the line (2026-09-14)

The entry below took the colour off the badge when it made it a line. The line
is what a list can be read down, but the mark is the thing the eye lands on,
and a neutral tile under every mark made two servers a row apart look like the
same kind of thing.

So the fill is back, and the line stays. `ServerBadge` takes a tint again: the
accent's container tone under the mark, its `onContainer` tone for the glyph
on top, and no frame for the one mark that covers the fill — an image simply
hides it, because the line beside the badge is the carrier that does not
depend on which mark is drawn. That is what the previous entry's frame existed
to work around, and why it is not coming back with the fill.

The accent returns to the mark picker with it, where a candidate is again
previewed on the fill it will sit on, and a transparent image again shows the
server's colour through it. The editor and the custom-colour picker preview
the pair the list draws: the line beside the mark, the colour under it.

## The server colour is a line, not a fill (2026-09-14)

The colour was the badge's fill, which an image mark covers edge to edge — so
an image badge wore it as a frame instead (the entry below), and one colour
then read as a pastel square on one row and a saturated outline on the next.

It is now a rounded vertical line at the leading edge of the row
(`ServerAccentBar`), drawn inside the tile's content padding so the selected
row's own bar — the app's colour, hard against the pane edge — stays a
separate mark. The badge lost both the fill and the frame: every mark sits on
the same neutral tile, so a glyph, an emoji and a logo read the same way, and
a transparent image now shows that tile rather than the colour. The line's
slot is reserved whether or not a colour is set, so the marks of coloured and
uncoloured servers stay in one column, and it is drawn to the avatar's full
height — session ring included — at either density.

`ServerBadge` no longer takes a tint at all, which also took the accent out of
the mark picker, where it existed only to preview candidates on the colour
they would have sat on. The editor and the custom-colour picker preview the
pair the way the list draws it: the line beside the mark. The terminal's tab
strip is unchanged — it still carries the colour as its bottom rule.

## List signals, custom colours, SVG marks, Return saves (2026-09-13)

Five things about the server list and its editor, all asked for together.

**Selected and connected rows.** The selected row used to differ from its
neighbours only by a tinted title, and a connected server only by the colour
of a ten-pixel dot — both the kind of difference the eye is worst at picking
out of a list of coloured badges. The selected row is now filled (the
standard "selected" surface, so it means the same on every row), barred down
its leading edge in the app's colour, and set in a heavier title. The corner
dot is gone: a server with a session open wears a *ring* around its badge,
green when connected, red on error, grey when the session dropped, and with a
highlight sweeping round it while connecting. A server with no session wears
no ring at all, so the live rows are the framed rows and the colour then says
how each is doing. The ring sits outside the badge with a gap, so it stays a
separate mark over any fill or image; its footprint is reserved either way so
rows never shift. Both the ring and the selection styling scale with the
compact row. `ServerAvatar` takes `hasSession` for this, since
`TerminalStatus.disconnected` covers both "dropped" and "never opened".

**The accent under an image.** An imported image covers the badge's fill edge
to edge, which hid the server's colour exactly where a logo made the row most
distinctive. An image badge now carries the accent as a frame around the
image, in the accent's line colour rather than its pastel fill (invisible at
two pixels). Glyph and emoji badges are unchanged: the fill shows it there.

**Custom colours.** The colour row's ten named accents gained a picker. The
protocol's `ServerConfig` grew a `customColor` field (`#RRGGBB`, normalized
like the other presentation fields, dropped on read when malformed) beside
the named `color`, on the same forward-compatibility arrangement as the mark
fields: the editor keeps `color` set to the nearest named accent (by hue,
greys to slate), so a build without the field still draws something chosen.
The named accents are derived with the tonal-spot scheme, which folds every
seed into the same pastel; a custom colour uses the fidelity variant instead,
so what was picked is what is painted, with the foreground derived for
legibility in both themes — the reason `ServerColor` is a closed set still
holds, and a custom colour is a seed, not a raw fill. The app resolves the
two fields through `ServerTint`, the colour analogue of `ServerMark`. The
picker itself is hue, saturation and brightness sliders on gradient tracks, a
hex box, and the badge previewed on the colour; the exact value is kept
beside the slider state so a typed colour comes back untouched and a hue
survives being desaturated.

**SVG marks.** The image tab accepts SVG. The file is told apart from a bitmap
by its content, rasterized with `flutter_svg` (short edge at twice the stored
side, long edge capped so a banner cannot ask for a fifty-thousand-pixel
bitmap), and then cropped, bounded and re-encoded by exactly the code a PNG
goes through, so a transparent drawing shows the server's colour through it.
Unsupported SVG is reported as "not an image" rather than crashing: the
parser signals it with `Error` subclasses, which that path catches on
purpose. Desktop pickers get an explicit extension list because the plugin's
own image filter leaves SVG out on Linux and Windows; mobile keeps the
platform image type, which already covers it.

**Return saves.** Return in the editor triggers Save from any one-line field,
through a `Shortcuts`/`Actions` pair whose action declines — leaving the key
to whoever owned it — when the focus is in a multi-line field (a newline) or
on a control that activates on Return (the buttons, the switches, the auth
dropdown). Ctrl+Return and Cmd+Return save from anywhere, including the login
script. The editor's button row also became flexible, since at a large text
scale it overflowed the dialog on a phone.

**Density switch.** The app bar's density menu is a two-segment button: both
choices in view, the current one filled, one tap to switch.

## The vault re-key survives a crash (2026-09-12)

Sync enrolment re-keys the vault, which means changing two stores no single
operation spans: the vault file and the OS keystore. The file was re-sealed
under the new key first and the keystore told about it second, so a process
that died in between left the two disagreeing: a vault sealed with a key
nothing holds. That is not a state the app could talk its way out of either:
every credential read throws rather than returning null, and retrying the
enrolment throws in the same place, because re-keying starts by reading the
very credentials that no longer open. The only repair was deleting
`vault.json` by hand.

`FileVaultStore` now implements a `VaultRekeyJournal`. `stageRekey` writes both
complete generations to a `vault.json.rekey` sidecar, each sealed under the key
it belongs to, *before* the keystore is touched; `settleRekey` then adopts
whichever generation the key actually installed can open, commits it to
`vault.json` and clears the sidecar. `AppServices` settles at startup and again
whenever `unlockVaultFromKeystore` finds the keyring back, so a crash anywhere
in the window resolves on the next launch instead of stranding the vault. A
keyring that is locked settles nothing and leaves the vault locked with the
journal intact, which is the existing retry affordance rather than a new state.

Staging never writes `vault.json`, which is what makes the sidecar safe: while
one exists the stored vault still holds a complete, openable generation, so a
journal that is damaged, stray, or matched by neither key is moved aside and
the stored vault stands. The machinery that shipped unwired in 6f3d7f3 made the
sidecar authoritative instead. It failed every read while one existed and no
code path could clear it, so a sidecar arriving by any route (a restored
backup, a half-shipped build) would have wedged the vault permanently. Nineteen
tests cover it: both crash sides at the store and through `AppServices`, the
locked-keyring hold, the unmatched and damaged journals, an orphan entry the
current key cannot open, refused mutations while staged, and that the sidecar
holds no plaintext.

Settling only ever happens against a key the OS keystore can actually testify
to holding. A failed install whose keyring is then too locked to answer leaves
the journal staged rather than guess: guessing the old key would finalize the
vault on that generation and clear the only copy of the other one, so a keyring
that *had* committed the new key would be left holding one nothing on disk
matches. Nothing is lost by waiting, because staging never wrote `vault.json` —
the stored vault and the session keep the key that still opens them, and the
next unlock, launch, or retry settles it. A key that opens neither staged
generation is not adopted either.

Reading the journal separates a failed read from damaged content, which
`readAsString` cannot: it reports malformed UTF-8 as a `FileSystemException`,
the same type a locked file raises. The read takes bytes and decodes them, so
I/O failures propagate and are retried with the journal intact while damage
still quarantines. The vault file itself is now written owner-only, like the
journal beside it and the identity audit log; it held the same sealed blobs for
longer under default permissions. Opening tightens an existing vault too, with a
twentieth test locking that in, since one that is only ever read would
otherwise keep the mode it was created with and the oldest installs would be
the ones the change missed.

Two things fell out. Re-keying now re-seals every stored entry rather than only
the credentials current configs reference, because staging rewrites the whole
map anyway, which closes most of known limitation 4 without the
`VaultStore.listIds` it asked for. And `_rekeyVault` no longer rolls the vault
file back when the keystore refuses the new key: there is nothing to roll back,
since staging left the file on the generation the installed key still opens.
That replaces the witnessed rollback #98 added: it read the keystore back to
decide which of two equally-unreadable states to leave behind, and documented
the residual it could not close — a keyring that accepted the write and then
locked cannot testify. Staging removes the choice, because both generations
are on disk and the next launch settles on whichever key survived. It still
reads the keystore back through `readKeystoreKey`, never `probeKeystore`,
which invents a key when it finds none: a random key there would match neither
staged generation and seal the vault shut.

## Two view options for the server list (2026-09-12)

The left pane's list gained the two things a list of a few dozen servers
starts to want.

**Density.** A switch in the pane's app bar chooses between the two-line row
the list has always drawn and a one-line compact row — 40 px against 72, so
roughly twice as many servers fit a screen. The `user@host:port` line is what
the compact row trades away; it becomes a tooltip for a pointer and part of the
row's spoken label for a screen reader rather than being lost, and the badge
and its status dot scale down with the row.

**Pinning.** A row's menu pins it into a `Pinned` section at the top, built out
of the same sectioning the groups already use — so the shortlist folds away,
counts its members and renders like any other section. A pinned server leaves
its group rather than appearing twice, and that group's count reports what is
actually left in it.

**Filtering.** Enter now opens the first row the user can *see* rather than the
head of the filtered list. Grouping already sorted sections by name, so store
order was never quite what the eye read; pinning would have widened the gap.

Both are device-local settings, alongside the folded sections and the pane
widths. Pins deliberately do not sync and there is no switch to make them: a
pin says "this is what I reach for *here*", which is rarely the same answer on
a phone as at the desk, and keeping it out of the record layer means there is
nothing to publish, retract or resolve — one device's shortlist can never
reorder another's list. The obvious follow-up, if that turns out to be wanted,
is an opt-in `pinnedServers` record modelled on the assistant's (off by
default), which is why the pin lives in settings rather than on `ServerConfig`,
where it would have synced unconditionally.

## One over-sized record no longer stops sync (2026-09-12)

Push batching sizes a request against the server's advertised body and record
limits, but the server enforces a third cap the advertisement left out: at most
1 MiB (env-tunable) on a single record's sealed blob. That one is refused with a
413 for the *whole* push, exactly like an over-sized body — so a record past it
took every record batched beside it down with it, and because batching is
deterministic the next round rebuilt the same doomed batch. One record the user
could not even see stopped the account's sync outright, with an opaque 413
naming a byte count.

`PushLimits` now carries `maxBlobBytes`, the server advertises it in every pull
response, and `batchForPush` treats a record past it the way it already treats
one too large for any body: sent alone, and last. The record still fails — a
sealed blob cannot be shrunk client-side, and the server stays the authority on
its own limits — but the failure stays with it instead of holding back
everything else. A regression test in the server package drives the real stack
and asserts the other records reach the server while the failure still
surfaces. A client falls back to the shipped 1 MiB in two cases, not one: when
the server sends no limits at all, and when it sends the two older ones without
this — which is every deployment predating the field. So a server with
`SEANCE_MAX_BLOB_BYTES` tuned below 1 MiB has to be upgraded too before its
clients can isolate anything; untuned, the default is what it enforces anyway.

## An emoji mark has to draw something (2026-09-12)

`normalizeServerEmoji` refuses the invisible characters one at a time — the
zero-width space, the zero-width non-joiner, the bidi controls, the Hangul
fillers, plane 14 — because each of them alone is a valid grapheme cluster that
paints an empty badge. Three kinds got through anyway:

* **U+200D, the zero-width joiner.** Deliberately absent from that list, since
  it is what holds a multi-part emoji together — so it could never be caught
  there, and a mark that was nothing but a joiner drew nothing.
* **Variation selectors** (U+FE0E/U+FE0F), which select a presentation for the
  character before them and have none here.
* **Combining marks** — an accent, the combining grapheme joiner, an enclosing
  keycap without its keycap.

A fourth kind hides behind the same property but in the other direction:
`Grapheme_Cluster_Break=Prepend` characters — U+0600 ARABIC NUMBER SIGN and its
siblings, all invisible format characters — attach to what *follows* them
(UAX #29 GB9b) rather than to what precedes.

All of them share one property: the cluster has no base character, only the
decorations that attach to one. That is now the rule, asked of the same
grapheme engine rather than of a table of combining ranges that would go stale
each Unicode revision — put a plain base character on each side of the cluster
and see whether either one absorbed the whole thing. Both sides, because GB9/
GB9a join backward and GB9b joins forward, and a probe on one side alone reads
the other direction as a clean break. A subdivision flag, a ZWJ sequence, a
keycap and a skin-toned emoji all keep working, which the existing tests pin;
the visible-but-baseless cases — a lone skin-tone modifier, a lone spacing mark
— are refused too, deliberately, since "the beige square" reads as a rendering
failure on the next device.

Where the rule stops is pinned too, rather than left to be rediscovered. A
cluster needs a base; it is not required to be *only* that base, so an
invisible character glued to a real one (U+0600 attaching forward onto an
emoji, a plane-14 tag character attaching backward) still passes — both draw
the emoji, so neither is the empty badge this refuses. The tag half could not
be closed wholesale anyway: a subdivision flag is a base followed by exactly
those characters. What would actually be reordered or hidden — the bidi
controls, the zero-width characters, the Hangul fillers — is refused wherever
it sits, because that loop reads every code unit rather than the first.

The picker's curated grid is now pinned against the normalizer as well: an
entry it refused would have been a tile that silently did nothing when tapped.

## Font picker, server marks, and terminal selection (2026-09-11)

Three requests, each its own commit on top of the section below. A fourth —
the "Add server" button covering the last row's menu — was reported at the same
time and fixed independently on its own branch; this work was rebuilt on top of
that rather than duplicating it.

**A terminal font picker on desktop** (`services/system_fonts.dart`,
`ui/font_picker.dart`). The font family was a name typed from memory. The
installed families are now read out of the font files themselves: the sfnt
`name` table carries the family name the OS advertises, which is exactly the
name Flutter hands to the platform font manager, so it is the name the setting
needs. Pure Dart, no platform channel and no new dependency — only the table
directory and three tables are read per file, and `post.isFixedPitch` (with the
PANOSE proportion as a fallback) drives the monospace filter the dialog starts
on. The dialog previews each family in its own face. It is offered only where
there is a user-managed collection to read, which is the three desktops; the
free-text field stays everywhere, because what the OS registers and what the
engine renders are not quite the same set. Verified against this container's
own fonts as well as synthetic ones: 22 families, with DejaVu Sans Mono,
FreeMono, Liberation Mono and Unifont correctly marked fixed-pitch.

**Terminal selection is bounded by the content** (vendored fork patch 28).
Dragging through the blank area under the shell prompt painted a selection band
across it and copied one newline per row crossed. Nothing was out of bounds: a
`Buffer` is built with one `BufferLine` per viewport row and gains one per
newline, so every row below the prompt is a real, addressable line, and the
pixel-to-cell conversion clamps to the line count rather than to anything about
content. `Buffer.contentEnd` now reports one cell past the last cell holding
anything, and every selection path in `RenderTerminal` goes through it — so a
drag that never leaves the void collapses to a single cell, painting and
copying nothing, while a drag out of the output ends where the output does.
`getCellOffset` itself is unchanged, because mouse reporting and link
hit-testing need the row the pointer is really on.

**Server marks: 77 glyphs, emoji, and imported images**
(`server_mark.dart`, `ui/server_mark_picker.dart`, `services/badge_image.dart`).
The sixteen built-in icons became 77 under seven headings, searchable by label
*and* by terms nobody would guess from the label (`k8s` finds the cluster
glyph, `postgres` the database one). Beyond them a server can carry an emoji or
an imported image.

The model is three independent optional fields — `icon`, `iconEmoji`,
`iconImage` — resolved by `ServerMark` richest-first (an image outranks an
emoji, which outranks the glyph), rather than one tagged value. That is a forward-compatibility choice: records sync between
versions in both directions, and a build that has never heard of `iconEmoji`
ignores the key and goes on drawing the glyph every richer mark keeps beside
it, which approximates the choice instead of losing it. A tag inside the
existing `icon` field would have failed that build's name lookup and left it
with the default badge. `ServerMark.stored` is the inverse, so the editor holds
one mark and writes the three together and they cannot disagree.

Image bytes live inside the server's own config record. That keeps them
impossible to orphan (an image cannot outlive, or arrive without, the server it
marks), needs no new `RecordKind` and no collection step, and means a device
has either the whole appearance of a server or none of it. The cost is a bigger
config record, bounded at 192 KiB of image payload (the re-encoded PNG,
measured before sealing) and stored at 256 px square.

Both numbers are measured rather than guessed. The side is set by the largest
badge the app draws, the 64-pixel preview in the mark picker: 192 physical
pixels at 3x and 256 at 4x, and 256 is what is stored, so the top of the
density range is covered rather than the middle. The byte cap is set so
realistic content never
trips the step-down: a PNG at 256 px measures about 1 KiB for a flat logo, 53
KiB for a photograph and 154 KiB for pure noise. What bounds it is the sync
server's 1 MiB per-record limit, measured on the decoded sealed blob — a config
at the cap with every other field at its longest seals to 258 KiB, a quarter of
what is allowed, which `record_size_test.dart` asserts against the server's real
setting rather than against arithmetic.

The other server-side limit, 8 MiB per *request*, was the one an image could
have reached: the blob is base64 on the wire, so a cap-sized config costs about
344 KiB of request body, and a push that carried every dirty record at once
would have overflowed on two dozen of them — fewer beside the rest of a dirty
set — taking a 413 for the whole push rather than a refusal of any one record.
That is closed: `batchForPush` (landed separately) splits a push to the
server's advertised body and record limits, measured on the encoded body. A
cap-sized config is a twenty-fourth of the body budget, so an image record always
fits a batch, and the sizing above now only has to clear the *per-record*
limit.

Every import is re-encoded rather than trusted: cropped square (the badge draws
edge to edge, and letterboxing reads as a broken image), scaled to at most 256
px, never scaled up, and stepped down through 192, 128 and 96 if the PNG will
not fit. The crop is measured on the *decoded* image, which is what makes a
phone photo come out upright: the engine applies EXIF orientation, so a
rotation flag is already spent by the time the pixels are cropped (measured —
a JPEG whose SOF says 6000x4000 with Orientation=6 reports 4000x6000 from both
the descriptor and the decoded frame). That is `dart:ui` throughout — the
engine already decodes every format the platform knows, so no image package was
added. A value that fails validation
on read is not re-published either, so a device never passes on a mark it could
not draw as though it had accepted it.

Two ceilings guard memory, because a file's compressed size says nothing about
what decoding it costs. On import the dimensions are read from the header
through an `ImageDescriptor` and refused before any pixel buffer is allocated:
a 48 MP phone photo is a few megabytes of JPEG and ~190 MB of RGBA, and picking
a recent photo is the most ordinary thing a user does here. On read, an image
mark's declared IHDR dimensions are bounded too — PNG compresses a flat colour
so well that a few hundred bytes can ask for a 65535x65535 buffer at paint
time, and a record can arrive from a device this one does not control.

Emoji are validated as exactly one grapheme cluster (👩🏽‍🚀 is four code points and
one choice) with a code-unit ceiling, since a cluster can be extended with
joiners indefinitely and a record from elsewhere should not be able to park a
kilobyte of them in a config. An emoji renders through the host's own emoji
font, so a device without one shows a box — which is the other reason every
mark keeps a glyph beside it.

The editor's flat icon grid became a preview plus a "Choose…" button opening a
three-tab picker (Icons / Emoji / Image), since 77 glyphs no longer fit a form
field. Duplicating a server carries all three fields, which its whole-record
comparison test now catches.

Every analyzer is clean and the whole suite passes; the selection fix was
confirmed to fail before it and pass after. Counts are in AGENTS.md section 4.

## Host-key review reachability (2026-09-09)

`showHostKeyDialog`'s `AlertDialog` is now `scrollable`, matching the
keyboard-interactive dialog: the changed-key review (warning + two
fingerprints) scrolls inside the dialog when height is scarce — small
windows, split screens, accessibility text scaling — instead of the content
column overflowing past the dialog bounds, and Cancel/Trust stay pinned
below the scroll area so they never leave the screen. Result contracts,
the current-route guards from the port-back below, barrier behavior,
warning style/copy, and fingerprint semantics are unchanged.

Two widget regressions (changed-key and first-use) render the public
dialog through a real route at 390×644 logical px with text scale 2.0 and
realistic 43-character fingerprints; before the fix they failed on actual
rendering overflow (`A RenderFlex overflowed by 1616 pixels` changed-key,
`280 pixels` first-use), and after it they additionally scroll the
previously-trusted fingerprint and the warning into view and back. Widget
render captures before/after are recorded in Poltergeist's ledger. All 465
Flutter tests (463 prior + these 2) and `flutter analyze` pass. The fix was
developed in Poltergeist's ported prompt dialog (its M2 prompt UI) and
ported back; its local ledger entry records the provenance.

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
| `seance_app` | Complete; `flutter analyze` clean, widget tests pass. Server list is the top-level list; each server can hold several sessions shown as a per-server tab strip (a strip appears only at 2+ tabs, so a single session looks title-bar-less as before) that the built-in file editor also opens into — a file is a tab beside the terminals, not a route over the app — with ⌘T/Ctrl+Shift+T + a "New tab" affordance, status dot: green/grey/red + connecting spinner; resizable tiled panes); right-hand utility panel with Assistant + Snippets + **Files** + **Git** tabs. Files is session-scoped SFTP over the existing SSH transport: responsive navigation, OSC 7 follow mode, picker/desktop-drop upload, local open + conflict-checked upload-back, mkdir/rename/delete, progress/cancel; managed checkouts re-stat the server copy on reopen and after finished shell commands — a clean checkout refreshes itself, a dirty one keeps the local edits and the built-in editor offers a Reload banner to discard them — and narrow/Android gets a full-screen route. See [`docs/SFTP.md`](SFTP.md) for implementation state and remaining real-device work. Git is session-scoped too: it probes the shell's OSC 7 directory (terminal-title fallback) over a separate exec channel via `SshSession.runCommand` — never the interactive shell — shows branch/ahead-behind/staged/unstaged/untracked/conflicted plus recent commits, follows cwd changes and refreshes after shell commands finish (OSC 133), and offers stage/unstage/discard/commit/pull/push/branch actions; git < 2.11 gets the porcelain v1 fallback. Snippets are synced command templates with `{{placeholder}}` fill-in dialogs; assistant chat when configured, ⌘/Ctrl+↵ sends; inline command generator (⌘K / Ctrl+Shift+K, prefilled from the current shell line, Enter generates+inserts+closes) turns NL into a reviewed command; the native macOS menu is kept intact (Edit/Window/…) with Settings wired to ⌘, and a Terminal ▸ Generate Command… (⌘K) item; Settings opens in a window of its own on desktop and as a route on phones and tablets (see "Settings in its own window" below); settings suggest models from the endpoint with manual fallback; failed connections show a summary + expandable connection log. **Automatic sync** runs at startup, after any server/snippet add/edit/delete (debounced), and every 5 min, with a live header/settings status; the "Sync now" button remains. **Credential sync** is opt-in (global toggle × per-server "allow this credential to sync"; E2E-encrypted). The editor has a **Test connection** button: it authenticates with what the form holds right now (a password or key typed but not yet saved, or the stored credential wherever a box is left blank — the rule Save follows, with one exception Save shares: a blank passphrase box beside a *pasted* key means "no passphrase", not "keep the stored one"; see known limitations 17 and 21, which are the two halves of that caveat, and 20 for the Label validator that gates the button), without opening a shell or running the login script, and reports how authentication completed plus the same summary and expandable transcript a failed connection shows. A host key approved during a test is pinned for the attempt only — `liveHostAuthenticator` takes the *store* and wraps it in `UnpinnedHostKeyStore` itself, so a caller cannot wire the persistent verifier by accident — and a configured jump host is called out, since ProxyJump is modelled but not executed. The connection transcript now redacts keyboard-interactive answers at capture: dartssh2 prints `SSH_Message_Userauth_InfoResponse(responses: […])` through `toString`, and for a host doing password login that way the list *is* the password — which the log's Copy button would otherwise hand straight to a bug report. An `InfoResponse` whose shape this build does not recognize — a dartssh2 upgrade that renamed the field or quoted the elements — is withheld whole rather than passed through, since every other test of the pattern is written against the same reading of that library and would keep passing while the password flowed into the transcript; one test builds the message the client actually sends and redacts its own `toString`, so an upgrade fails there instead. The match runs to the end of what it is handed rather than to a bracket or a line break (a Dart list does not escape its elements, so a password containing `]` — or a newline, from a password manager — would otherwise keep its tail), and the log's line list is a read-only *view*, so nothing can append past the redaction and a live transcript is not copied on every repaint. Any field edit, auth-method change or key-source toggle supersedes a test already in flight, so a verdict can never land describing a form the user has moved on from. A server row's menu also **duplicates** it: fresh id and timestamps, a "… copy" / "… copy 2" label that continues rather than stutters, everything else carried over, and the credential copied into a vault entry of its own (never shared — a copy that shared one would be rewritten by an edit to either server, and the sync layer keys a credential record by the credential rather than by the server holding it, so two owners would push two versions of one record). Deleting a server now drops its vault entry only when no other server still names it — the check the `secret:` tombstone path already made, extended to the local delete, since a shared entry is reachable through sync and through the editor whatever duplication does — and shares one queue with duplication — as do saving a server and applying a sync round, since both write the config store and the vault; re-entry is detected by zone identity against the action that is running, so a callback registered inside a mutation (a listener's microtask, the auto-sync debounce a save schedules) can queue one of its own once that mutation is over — so two deletes of servers sharing an entry cannot each read the list before the other's removal lands and both leave it behind, and a credential rewritten in place under an unchanged ref cannot happen while a duplicate is reading it. A duplicate also re-reads its source before saving, since the guard is cheaper than the invariant it stands in for: planning is a read, so nothing is created until it passes, and `SourceServerChanged` can say so. A server can also be **excluded from sync** outright (per-server switch in the editor, confirmed when there is something to retract; `cloud_off` mark on its row): its config is never pushed, and a copy pushed before the switch went on is retracted with a tombstone — so it also leaves the other devices, which the switch's subtitle says. A retraction the copy on the sync server outranks (another device's clock running ahead of this one's, or an edit made while this one was offline) is re-dated one millisecond past the record that beat it and pushed again in the same run: re-minting the same losing date every five minutes would leave the switch on here and the config on every other device forever, which is the multi-device case the switch exists for. Turning the switch back off is the mirror: the retraction it revokes may have been re-dated past this device's own clock, so an honest re-inclusion stamp would still lose — the live record is re-dated past its own tombstone instead, and the device stops applying a retraction it has withdrawn rather than deleting the server it just brought back. Its credential is retracted with it, off the sync server — unless a still-synced server shares that vault entry, in which case it is neither withdrawn nor frozen, since a secret record is keyed by the credential rather than by the server holding it. What a `secret:` tombstone does *not* do is delete anything from a vault: it is staged and pushed, never honoured on apply. A tombstone carries no sealed payload — `RecordCodec.decrypt` reads the envelope's flag without opening anything — so a delete is the one signal a sync server can assert entirely on its own, and honouring these would hand it a way to empty the vault (tombstone the configs, then the credentials no config still names). The cost is that the other devices keep an orphaned vault entry no config names, invisible in a UI that lists servers; the fix is sealing tombstones, not trusting this one — and until then a config tombstone is honoured on the same say-so, as it always has been, so a hostile sync server can still delete every synced server's *settings* on every device (never a credential or a pin); sealing closes that too. A pinned host key is withheld for the same reason (it is keyed by `host:port`, and deleting it elsewhere would drop that device back to trust-on-first-use), though new pins for an address only excluded servers use are no longer pushed. **Assistant sync** is a separate opt-in (off by default, and independent of credential sync — the assistant's API keys travel on this switch alone, whatever the credential toggle says): provider, model, endpoint, web-search backends and redaction travel as one end-to-end encrypted record, *with* the API keys they reference — a configuration whose keys stayed behind leaves the other device looking set up and answering nothing. Keys are gathered from the references the configuration itself carries, never by sweeping the keystore (the sync token and the vault key live there too), and the reserved-entry refusal runs in both directions — a configuration whose own references name a reserved entry publishes nothing rather than shipping it, which is what makes the refusal on the way in safe to rely on. An incoming record is held to that rule twice over: it may only write the entries its own configuration names, and a record whose configuration names a reserved entry (the sync token shares the API-key namespace) is refused whole rather than adopted — the allow-list is the record's, the deny-list is this device's, and the vault key is out of reach of both, stored under a prefix no key reference can name. Removals deliberately do not travel: a record says which keys a configuration uses, never which ones a device should forget — so a rotated key leaves the entry it replaced behind on every device that adopted it, to be deleted there by hand, in the OS keychain where the platform has one (the app has no keystore browser, and Android offers no user-facing way to remove a single app's entry, so a stale key stays there). A record whose provider name is empty is not a configuration at all — that field is written from an enum — and is skipped rather than adopted over a working one. Adopting rebuilds the chat provider only when something actually changed, since the record is handed over every round whether or not it moved. The trust boundary that draws is the account, not the device: an opted-in peer can repoint every other one's assistant, endpoint included, just by saving, and the rebuild is silent — so a compromised peer redirects prompts and terminal context to an endpoint of its choosing, and surfacing an adopted change of provider or endpoint is a follow-up. Turning the switch on adopts what the account already holds — a device that configured its own assistant while opted out replaces that configuration with the account's, which the switch's subtitle says before it is thrown — and publishes this device's only when there was nothing to adopt *and* this device has an assistant worth publishing. "Worth publishing" is whether the assistant here is usable at all (a key stored under the reference it names, or a local endpoint that needs none), not whether it carries a timestamp: the stamp is zero both for a laptop that never configured an assistant, whose defaults must not land on the account over a phone that configured a real provider and keys while sync was off, and for an install that configured its assistant before this feature shipped, which is every existing device and would otherwise adopt nothing, publish nothing, and sit there doing nothing until its settings happened to be edited again. A pulled configuration that changed something rebuilds the chat provider, since one already built notices neither a new model nor a new key. A record whose provider name this build does not know is not adopted at all, rather than half-adopted with a matching stamp to hide the disagreement — the local stamp does not advance either, so this device's next Save republishes its own configuration over the newer build's record, which is the accepted cost of not faking agreement; a keyring that is locked publishes nothing that round rather than a keyless copy that would outrank the keyed record on the account; a Save that changed nothing does not stamp; and a stamp never lands below a record this device already holds. Turning the switch off stops this device sharing further changes and deliberately does not retract what was shared — the switch is a per-device preference, and withdrawing the account's record because one device opted out would take the configuration away from the devices that did not. There is no tombstone for the record, so taking keys back off the account means clearing the key references and saving *while still opted in* — the key fields, not the provider and model, which stay set. A record whose provider name is empty is neither published nor adopted, so emptying that field instead could not carry the removal anywhere: this device would publish nothing and the keyed copy would stay on the account, for every other device to go on adopting. What clearing the key *references* publishes is a keyless record with its provider name still set, under a newer stamp — and the server keys records by id, so it replaces the keyed copy rather than sitting beside it, and is then adopted like any other, since nothing skips it. Which is the point and also the cost: every opted-in device's assistant stops answering until a key is entered there, and the entries the removal was about stay in each device's keystore, since removals never travel. A first-class "stop sharing the keys" action would want a sealed tombstone, which is a follow-up of its own. A device that never edited its assistant publishes nothing in the rounds that follow either, and that gate is the stamp: zero means "never edited here", and a laptop parking its shipped defaults on the account would be adopted by every device that opted in on the same zero stamp — which is every install that configured its assistant before this feature shipped. The two gates ask different questions without disagreeing: the switch asks whether this assistant is usable, and stamps before it publishes, so a pre-feature install passes the round's gate from the moment it opts in; a device with nothing usable to publish never gets a stamp to pass it with. The **built-in text editor** opens at the top with the app's monospace stack, has an in-file find bar (⌘F/Ctrl+F; Enter/F3/⌘G cycle, match-case toggle, all matches highlighted) and basic syntax highlighting (shell, python, js/ts, dart, json, yaml, ini/conf, dockerfile, sql, c-family, xml, markdown — detected by name/extension/shebang); for a server file ⌘S/Ctrl+S saves **and uploads immediately** (⇧⌘S keeps it local; conflicts still prompt). Transient notices app-wide use **top toasts**, never bottom SnackBars, so they can't cover the shell prompt at the bottom of the terminal. On **touch platforms** the terminal shows an on-screen key row (Esc/Tab/Ctrl [sticky]/^C/arrows/Home/End/PgUp/PgDn/`\|` `/` `-` `~` + hide-keyboard) and reflows above the soft keyboard. **Command suggestions** (opt-in, local only) surface frequently-run commands in the Snippets tab to save as snippets. **Server groups, colours and icons** are per-server and synced: the rail is the sibling kit's sidebar shared with Poltergeist — a PINNED shortlist above SERVERS, ungrouped servers first and named groups nested below as collapsible disclosure rows, no header for an empty section, and a live filter overrides collapsed sections so it can never hide a match — each row carries the server's *mark* (a coloured badge, or the bare glyph for an uncoloured server) with the connection dot in its corner, and the accent also rules the terminal's tab strip. A mark is one of 77 built-in glyphs (grouped and searchable in a three-tab picker), an emoji, or an imported image — the image cropped square, stored at 256 px and carried inside the server's own config record, so it reaches the other devices with everything else about the server and can never arrive without it. The three travel as three independent fields, so a build that predates the richer two still draws the glyph every mark keeps beside it. The terminal's font family can also be **picked from the fonts installed on the host** on desktop, each previewed in its own face and filtered to fixed-pitch by default, with the free-text field still there for anything the scan misses. Folded sections are device-local (settings), the grouping itself syncs. On **Android**, backgrounding no longer kills the sessions: a `dataSync` foreground service anchors the process while any session is connecting/connected (ongoing notification with the live count, opt-out in Settings ▸ General; `BackgroundKeepAlive` drives it through the `seance/keepalive` channel — on other platforms it is a no-op). Default desktop window 1280×800 on first launch; afterwards the desktop **window state persists** across restarts — size, position (which encodes the monitor), and maximized/full-screen mode (device-local `window_state.json`, restored before the first frame; macOS hides the window until it's placed, Windows applies maximize/full-screen just after the runner shows the window) — and the pane-split widths persist too (settings). Reopening never auto-connects servers. Platform folders committed. |
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
  obscured dialog cannot pop any route but the dialog's own; the review
  stays scrollable and reachable in constrained layouts (warning and both
  fingerprints scroll into view, buttons stay on screen).
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
- `app/seance_app/test/server_grouping_test.dart` — sectioning: PINNED
  then SERVERS (ungrouped first, groups nested and sorted), case-folded
  keys with the first spelling kept, no empty section headers (unless a
  filter hid a live server there), folding a group, the shortlist or
  SERVERS itself, and a stale collapsed key doing nothing.
- `app/seance_app/test/server_status_dot_test.dart` — the shared dot
  mapping (live session over probe; solid for sessions, ring for probe
  observations) and the tab aggregation behind it.
- `app/seance_app/test/host_key_blocked_test.dart`: a session is
  blocked only when its own prompt refused a changed key (declined, or
  the unwired prompt's default); a declined first use, an accepted key
  that then fails, and a host-key error on the unchanged pinned key are
  ordinary failures, and a reconnect is decided by its own prompt.
- `app/seance_app/test/server_list_pane_test.dart` — the rail (no app
  bar; the bottom bar's "+" menu, sync chip states and gear; sections
  and nesting; folds persisting; the filter at five servers, its
  "↵ opens the first" count and on ⌥⌘F / Ctrl+Alt+F with Esc clearing
  then closing, and neither a refused nor an emptied reveal reopening
  it; the selection pill; pinning from a right-click; a header's dot for
  a hidden live session, its announcement, and the section header a
  filter keeps for one; the blocked row; the empty state) and the
  home's "+" never covering the last row's "⋮".
- `app/seance_app/test/ui/sidebar/sidebar_kit_test.dart` — the ported
  kit's tests plus Séance's additions: ring dots, the host surface, two
  lines, the menu button on desktop and touch, touch headers, keyboard
  focus inside a row menu, a focus ring that does not move content, and
  a header dot's words in the header's announcement.
- `app/seance_app/test/server_list_capture_test.dart` — renders the
  rail (also at its 200 px minimum), a tablet rail, the phone home and a
  narrow desktop window at both densities and brightnesses, plus a folded
  group keeping its dot, for review; writes PNGs only with
  `SEANCE_CAPTURE=1`.
- `app/seance_app/test/mac_menu_test.dart` — View's density item over a
  mocked `seance/menu` channel: it flips the density and its title
  follows.
- `app/seance_app/test/server_editor_test.dart` — Return saves from a
  one-line field, is a newline in the login script, presses a focused button
  instead, and does nothing while the form is invalid; a custom colour is
  saved with its nearest named accent and reopens as itself.
- `app/seance_app/test/server_color_picker_test.dart` — the picker returns
  the colour handed in untouched, follows a typed hex value and a dragged
  slider, flags a non-colour, keeps a hue through desaturation.
- `app/seance_app/test/server_tile_test.dart` — a row is one 26 px line
  with the address in its tooltip; the selected row wears the pill and a
  semibold title without shifting; the mark per colour and mark kind;
  every dot drawn and announced; `×N`; the hover eject; ⌘-click opening
  a tab; the verbs by state; the touch sheet.
- `app/seance_app/test/server_appearance_test.dart` — every colour × icon
  renders, the same accent resolves differently per brightness, and the status
  dot keeps its tooltip inside the badge.
- `app/seance_app/test/editor_syntax_test.dart` — language detection
  (extension/basename/shebang, either path separator), tokenizer per family
  (comments, strings with escapes, numbers, keywords, meta; CSS, Ruby, Perl,
  Lua), optional meta groups, non-overlap invariant, search matching and
  caps, and search-over-syntax span layering that reassembles the text.
- `app/seance_app/test/built_in_text_editor_test.dart` — atomic save
  round-trips, BOM/CRLF preservation (a second BOM survives), external-change
  refusal, typed refusals without prefixes, symlink refusal, permission
  bits kept across a save with an owner-only temp, and the editor
  screen: Ctrl-S save-and-upload (immediate, no dialog; reconcile fallback on
  failure), local-only save without an upload target, reconcile or upload
  after the tab closed mid-save, open-at-top, monospace
  stack, the UTF-8 byte count, and the find bar (counts, wrap, case toggle,
  highlight ranges).
- `app/seance_app/test/narrow_back_navigation_test.dart` — system back at
  phone width: the terminal returns to the list with the session kept (and
  the list's filter query), an
  open drawer closes first, the list leaves it to the platform, and Files
  walks up to `/` before popping (or pops after a parent fails to list)
  while its app bar arrow pops at once.
- `app/seance_app/test/server_exclude_from_sync_test.dart` — the row's
  exclusion mark appears only for an excluded server, and is described in
  the row's spoken label and its tooltip (the row's visuals are excluded
  from semantics); plus when
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
4. **Sync re-key leaves unreadable entries unreadable.** Enrolling in sync
   re-keys the vault to the encryption-passphrase-derived key. Every stored
   entry is re-sealed now, not just the ones current configs reference, and the
   re-key is crash-safe (see the dated entry above), but an entry the *current*
   key cannot open is carried over byte for byte rather than failing the
   enrolment, so an orphan from an earlier lost re-key stays orphaned. Deciding
   such an entry is garbage and dropping it needs a UI that can show the user
   what is being discarded.
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
    scrollback trims, and mouse-report hygiene for remote apps. Links are
    both the URLs visible in the output and the OSC 8 hyperlinks a program
    attaches to its cells (which is what makes a CLI's "click here" line, or
    a URL that CLI wrapped across its own newlines, open the whole target).
    Right-click gives Copy / Paste / Select all. Ctrl+Shift+C/V/A elsewhere; ⌘C/⌘V/⌘A
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
