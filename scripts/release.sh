#!/usr/bin/env bash
# Cuts a release: bumps the `version:` in every pubspec (the three packages +
# the app, in lockstep), keeps the app lockfile and the README version line in
# step, commits, tags "v<version>", and with --push pushes branch + tag — which
# triggers .github/workflows/release.yml to test, build the sync-server
# binaries + Docker image, and publish the GitHub Release.
#
#   scripts/release.sh 0.2.0          # bump pubspecs + README, commit, tag v0.2.0
#   scripts/release.sh 0.2.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current committed version as-is
#
# Usage: scripts/release.sh [X.Y.Z] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

export RELEASE_APP_NAME="Séance"
export RELEASE_KIND="pubspec"
export RELEASE_PUBSPECS="packages/seance_protocol/pubspec.yaml packages/seance_core/pubspec.yaml packages/seance_sync_server/pubspec.yaml app/seance_app/pubspec.yaml"
# The app's committed lockfile pins the workspace packages' versions; keep it
# in step so the post-release `flutter pub get` is a no-op. Each entry's block
# ends at its `version:` line, so the range substitution touches exactly that
# line (BSD/macOS sed, like the engine). ${RELEASE_NEW_VERSION} expands when
# the engine runs this, not here — hence the single quotes.
# shellcheck disable=SC2016
export RELEASE_POST_BUMP='sed -i "" -E \
  -e "/^  seance_core:/,/^    version:/ s/^(    version: \")[^\"]*(\")/\1${RELEASE_NEW_VERSION}\2/" \
  -e "/^  seance_protocol:/,/^    version:/ s/^(    version: \")[^\"]*(\")/\1${RELEASE_NEW_VERSION}\2/" \
  app/seance_app/pubspec.lock'
export RELEASE_CI_NOTE="CI (release.yml) will now test, build the sync-server binaries + Docker image, and publish the GitHub Release for <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
