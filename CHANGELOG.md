# Changelog

## Unreleased

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
