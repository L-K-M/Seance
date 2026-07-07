# CLAUDE.md

Start with **[AGENTS.md](AGENTS.md)** — it's the full working guide (toolchain
setup, build/test commands, API constraints, seams, gotchas). Current status
and the next-steps checklist are in **[docs/STATUS.md](docs/STATUS.md)**. Product
design rationale is in **[PROPOSAL.md](PROPOSAL.md)**.

Quick reminders:
- No Dart/Flutter is pre-installed here — see AGENTS.md §1 to install them.
- Analyze/test the pure-Dart packages with explicit paths, never bare at the
  repo root (it would try to build the Flutter app): `dart test packages/seance_protocol packages/seance_core packages/seance_sync_server`.
- The app is `app/seance_app` (Flutter); its platform folders are committed
  (they carry the app name, icons, and macOS entitlements — see AGENTS.md §3).
