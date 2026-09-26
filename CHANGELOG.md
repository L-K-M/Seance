# Changelog

## Unreleased

- Themes: Settings has an Appearance tab. Pick one of ten themes
  (Séance, Graphite, Paper, Newsprint, Solarized, Midnight, Terminal,
  Vapor, Bubblegum, High contrast) as a starting point, then change any
  colour, the status colours, the terminal's colours, the interface font
  and how round the corners are; the app repaints as you go. Colours left
  on Automatic follow light or dark as you choose. Copy theme and Paste
  theme carry a theme between devices; themes do not sync. The app starts
  in Terminal, green on black; pick Séance for the violet look it had
  before themes.
- On phones and tablets, the server filter field is full height again
  instead of a thin strip above an empty gap, and compact server rows
  are 40 dp instead of 48.
- Tabs switch in place. Settings, the side panel and the server mark
  picker showed the new tab by scrolling the content sideways to it, and
  a sideways swipe or trackpad scroll flipped between tabs. The new tab
  now simply appears, a swipe no longer changes tabs, and each tab keeps
  what you left in it: a half-typed message, a search, the scroll
  position.
- Settings opens in a window of its own on macOS, Linux and Windows,
  instead of covering the app. Choosing Settings again (⌘, or Ctrl+,, the
  gear, "Sync off") brings it forward on that tab; closing it keeps the
  app as it was. Phones and tablets keep the full-screen Settings. A
  change on General or Files that cannot be saved now says so.
- Colour that means something, shared with Poltergeist: each colour
  names one kind of thing in both apps, so you find things by colour
  before you read them. The side panel's tabs are the Assistant purple,
  Snippets teal, Files blue and Git orange, each icon above its label,
  with the underline in the open tab's colour. Files shows folders
  blue, code orange, images pink, audio and video purple, archives
  brown and PDFs red, and a finished transfer is green, a failed one
  red. Git's Stage is green and Discard red. The assistant's sparkle and
  the command wand are purple, and Settings' tabs are coloured too.
- Server list: rebuilt on the sidebar Séance now shares with Poltergeist.
  On desktop the list is a rail with no app bar: PINNED, then SERVERS with
  groups as nested disclosure rows (folds persist), rows with the server's
  mark and one status dot (green connected, amber connecting, red failed,
  a hollow ring for what the probe saw), a filter at five servers or on
  ⌥⌘F (Ctrl+Alt+F elsewhere), and a bottom bar with a "+" menu (New
  server, Import SSH config), the sync status (a click on "Sync failed"
  retries), the density switch and Settings. Right-click, Shift+F10 or
  the Menu key open a row's verbs; ⌘- or Ctrl-click opens another tab. On
  a phone the list is the home screen with a "⋮" and long-press for the
  same verbs, and a "+" button; back to the list keeps the filter and
  scroll position. The sidebar kit is ported from Poltergeist.
- Server list: the two views are back, on the desktop rail, on tablets
  and on the phone home. Comfortable, the default (and what an existing
  install's stored choice already says), draws two lines under the 32 px
  badge: the address, led by the state when a session is connecting,
  failed or blocked or the host is unreachable ("Connection failed ·
  deploy@host"). The server's colour runs down the row's edge again, a
  connected server's badge wears its green ring, the "⋮" is in view, and
  group counts, chevrons and SERVERS' "+" show at rest. Compact keeps the
  one-line rail. Switch with the control in the rail's bottom bar or the
  phone home's app bar, or on macOS with View ▸ Use Compact Sidebar Rows
  (Use Comfortable Sidebar Rows). Also: a folded group, or a filter, that
  hides a connected server shows its dot on the header, and a screen
  reader hears it with the header ("Connected server hidden"); a filter
  that hides a whole section keeps its header for that, as Poltergeist's
  does; a changed host key you declined marks the row blocked rather
  than failed (a key-exchange signature that fails on an unchanged key
  is an ordinary failure, not a block); the filter's count says "↵ opens
  the first" again; the long-press sheet shows the row's second line
  under its name; and the filter chord no longer latches the field open
  on an empty list.
- Android: the system back button on the narrow terminal screen returns to
  the server list instead of closing the app, which had ended every live
  SSH session. In Files, back climbs one folder at a time before leaving
  the screen. The app opts into predictive back.
- Built-in editor: saving keeps the local copy's permissions (an owner-only
  0600 checkout stays owner-only, a script keeps its execute bits), and the
  replacement file is owner-only while it is written. Symlinked copies are
  refused on open as well as on save. Errors read as plain sentences,
  without "Bad state:" prefixes. A save that finishes after its tab closed
  still reconciles or uploads the copy. Ported from Poltergeist's hardened
  copy of this editor.
- Built-in editor: syntax highlighting for CSS/SCSS/LESS, Ruby, Perl and
  Lua, `.htaccess`/`.htpasswd` as ini, and Ruby/Perl/Lua shebangs, ported
  from Poltergeist. Language detection also finds the file name after a
  backslash.
- Linux: the window is titled "Séance" and first opens at 1280x800.
- Security: the Git tab and the staged `cd` now quote paths and arguments
  so fish reads them literally too. Before, when your login shell was fish,
  a directory name with a backslash and a quote could run commands on the
  server, and ordinary terminal output could report such a name to the Git
  tab, which probes it automatically. Reported directories that contain
  control characters are now ignored.
- Files: an upload no longer replaces a symbolic link on the server. Choosing
  Replace over a link used to swap the link for a regular file anyone could
  write (mode 0777) and leave its target unchanged; the upload now stops and
  says the item is a link. FIFOs, sockets and devices are refused the same
  way, and so is a folder, before any bytes are sent. A file whose mode
  keeps others from reading or writing it, such as a 0600 key or an
  ordinary 0644 file, is staged owner-only while it uploads, so other users
  on the server can neither read the new bytes nor write into them.

Earlier history lives in the commit log and any GitHub releases.
