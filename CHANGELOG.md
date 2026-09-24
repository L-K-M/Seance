# Changelog

## Unreleased

- Server list: rebuilt on the sidebar Séance now shares with Poltergeist.
  On desktop the list is a rail with no app bar: PINNED, then SERVERS with
  groups as nested disclosure rows (folds persist), one-line rows with the
  server's mark and one status dot (green connected, amber connecting, red
  failed, a hollow ring for what the probe saw), a filter at eight servers
  or on ⌥⌘F (Ctrl+Alt+F elsewhere), and a bottom bar with a "+" menu (New
  server, Import SSH config), the sync status (a click on "Sync failed"
  retries) and Settings. Right-click, Shift+F10 or the Menu key open a
  row's verbs; ⌘- or Ctrl-click opens another tab. On a phone the list is
  the home screen with 48 dp rows, a "⋮" and long-press for the same
  verbs, and a "+" button; back to the list keeps the filter and scroll
  position. The sidebar kit is ported from Poltergeist.
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

Earlier history lives in the commit log and any GitHub releases.
