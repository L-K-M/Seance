# seance_core

The platform-agnostic client core, shared unchanged by the Flutter app. Pure
Dart. Re-exports [`seance_protocol`](../seance_protocol), so app code imports
only `package:seance_core/seance_core.dart`.

## Modules

- **SSH** (`src/ssh/ssh_session.dart`): `SshSessionManager` over dartssh2 —
  password / private-key auth, keyboard-interactive, keepalives, resize; TOFU
  host-key verification via a public, testable `verifyHostKey`. (`AuthMethod.agent`
  currently throws — see docs/STATUS.md.)
- **TOFU** (`src/hostkey/tofu.dart`): first-use / trusted / **changed** verdicts;
  never auto-updates a changed key.
- **Terminal** (`src/terminal/`): the `TerminalEngine` seam (xterm backend lives
  in the app; `HeadlessTerminalEngine` for tests) + `PasteSanitizer` (rejects
  newlines so a pasted command can't self-execute).
- **ssh_config import** (`src/ssh_config/`): read-only `~/.ssh/config` → configs.
- **Probe** (`src/probe/`): tri-state online / offline / **unknown** reachability.
- **Sync** (`src/sync/`): `SyncEngine` (LWW pull/push), `SyncCoordinator`
  (domain⇄record mapping), `HttpSyncClient`, `LocalRecordStore`.
- **LLM** (`src/llm/`): `LlmProvider` with Anthropic + OpenAI-compatible impls,
  NL→command with an independent `DangerLinter`, `ChatController` whose only two
  tools are web search and a never-executing paste, `SecretRedactor`, SSE parse.
- **Stores** (`src/store/`): `ConfigStore` / `VaultStore` / `SecretVault` /
  `HostKeyStore` interfaces + in-memory impls.

## Test

```bash
dart test packages/seance_core
```
