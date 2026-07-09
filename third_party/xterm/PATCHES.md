# Séance's xterm fork — divergences from upstream 4.0.0

This package is a vendored copy of [xterm.dart] 4.0.0 (MIT, see LICENSE),
taken verbatim from pub.dev and then patched. The fork exists because the
selection defects it fixes live in private `State`/render wiring that no
public API reaches — the app cannot fix them from outside, and upstream has
no seam to inject behavior (PROPOSAL.md M2 planned this vendoring; the
libghostty engine eventually replaces the whole package behind seance_core's
`TerminalEngine` seam).

Keep this file exhaustive: every behavioral divergence from upstream 4.0.0
gets an entry, so a future upgrade (or the libghostty swap) knows exactly
what must be preserved.

[xterm.dart]: https://github.com/TerminalStudio/xterm.dart

## Patches

1. **Test goldens regenerated** (`test/src/_goldens/*.png`): upstream's golden
   images were rendered under an older Flutter; the SDK this project pins
   renders text a fraction of a percent differently (0.06–0.13% pixel diff),
   failing the two `TerminalView.textScaler` golden tests. Regenerated with
   `flutter test --update-goldens` — a test-asset refresh, zero library-code
   change.
