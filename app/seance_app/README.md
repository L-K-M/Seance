# seance_app

The Séance Flutter app — a thin, cross-platform UI over [`seance_core`](../../packages/seance_core).

## What's here

```
lib/
  main.dart                  app entry, theme, AppScope, dialog wiring
  app_state.dart             ChangeNotifier: servers, statuses, terminal tabs
  theme.dart                 Material 3 theme + status colours
  services/
    app_services.dart        wires seance_core services; sync enrolment/re-key
    app_settings.dart        persisted settings (LLM provider, sync, device id)
    secure_master_key.dart   OS-keystore master key + API keys (flutter_secure_storage)
    file_stores.dart         JSON-file ConfigStore / VaultStore / HostKeyStore
    xterm_engine.dart        TerminalEngine backed by xterm.dart
  ui/
    adaptive_shell.dart      two-pane ⇄ two-screen by breakpoint
    server_list_pane.dart    left pane: servers + online/offline/unknown dots
    server_editor.dart       add/edit a server (password / key / agent)
    terminal_pane.dart       right pane: session tabs + assistant drawer
    host_key_dialog.dart     TOFU: first-use confirm, hard block on change
    keyboard_interactive_dialog.dart   2FA / TOTP prompts
    chat_sidebar.dart        the always-on assistant (web-search + paste tools)
    settings_screen.dart     provider, search backend, redaction, sync
```

The terminal lives behind `seance_core`'s `TerminalEngine` seam; v1 uses
xterm.dart, and a libghostty engine can replace it later without touching the
UI (proposal M10).

## Run it

The library and tests are complete and pass `flutter analyze` + `flutter test`.
Platform scaffolding (the `android/`, `ios/`, `linux/`, `macos/`, `windows/`
folders) is generated once — it's boilerplate, so it isn't committed:

```bash
cd app/seance_app
flutter create --platforms=linux,macos,windows,android,ios --project-name seance_app .
flutter pub get
flutter run -d linux     # or macos / windows / a device
```

`flutter create` only adds the missing platform folders; it leaves `lib/`,
`test/`, and `pubspec.yaml` untouched.

## Design notes / current limitations

- **Local store**: JSON files (configs, encrypted vault, pinned host keys). The
  proposal's SQLite/drift backend is a drop-in future swap behind the same
  `seance_core` interfaces — chosen to avoid `build_runner` codegen for v1.
- **ssh-agent auth** is modelled but not yet wired through the dartssh2 backend
  (see `SshSessionManager.connect`); use password or private-key auth for now.
- **Sync & the vault key**: the account password authenticates with the sync
  server; a separate encryption passphrase derives the end-to-end key and
  re-keys the local vault (re-encrypting secrets referenced by current servers).
  Set sync up early, and use the same encryption passphrase on every device.
  Existing accounts created with one passphrase enter it in both fields.
- The assistant is always on (this is a personal tool). Secret redaction of
  outbound context defaults on; run against local Ollama for a fully-offline
  setup.

## Tests

```bash
flutter test
```

Widget tests cover the TOFU dialog (first-use trust and the changed-key hard
block). The heavy logic the app relies on — crypto, SSH/TOFU, sync, the LLM
layer — is unit-tested in `seance_core` with plain `dart test`.
