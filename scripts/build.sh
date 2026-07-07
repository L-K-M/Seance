#!/usr/bin/env bash
#
# Build every Séance target this host can build, and print one clear summary.
# The single local entry point; CI builds the same targets in
# .github/workflows/ci.yml and release.yml.
#
#   server — sync server as a native binary (dart compile exe) → build/seance-sync
#   docker — sync-server image (packages/seance_sync_server/Dockerfile, build
#            context = repo root) → seance-sync:local
#   app    — Flutter desktop app for THIS host (linux/macos/windows); platform
#            folders are committed (missing ones are regenerated as a fallback)
#   apk    — Android APK (needs flutter + an Android SDK)
#
# Usage:
#   scripts/build.sh                 # every target this host can build
#   scripts/build.sh server docker   # just these (naming a target turns an
#                                    # infeasible target into an error, not a skip)
#   scripts/build.sh --debug app     # debug-mode Flutter builds (server/docker
#                                    # have no debug variant; flag ignored there)
#   scripts/build.sh --install       # build the app for THIS host and install
#                                    # it (macOS: /Applications/Séance.app;
#                                    # Linux: ~/.local/opt/seance), then reveal
#                                    # the installed copy
#
# Every produced file (server binary, .app bundle, APK, …) is also copied into
# dist/ at the repo root — one folder with the final artifacts — and on macOS
# dist/ is opened in the Finder when anything landed there.
#
# Exit status is non-zero if any requested target fails to build. Targets that
# simply can't build on this host (no dart/flutter/docker, no Android SDK) are
# reported as skipped, and only fail the run when you named them explicitly.
set -uo pipefail

# Absolute path to this script — usage() must find it after the cd below, even
# when invoked via a relative path from a subdirectory.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PROFILE="release"
INSTALL=false
declare -a REQUESTED=()
EXPLICIT=0

usage() {
  # Print the leading comment block (the file header), minus the shebang.
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --debug) PROFILE="debug"; shift ;;
    --install) INSTALL=true; shift ;;
    server|docker|app|apk) REQUESTED+=("$1"); EXPLICIT=1; shift ;;
    all) REQUESTED=(server docker app apk); EXPLICIT=1; shift ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

# --install is about the host platform's app: with no explicit targets it
# builds just that (not the whole matrix), and with explicit targets it makes
# sure `app` is among them.
if $INSTALL; then
  if [[ ${#REQUESTED[@]} -eq 0 ]]; then
    REQUESTED=(app); EXPLICIT=1
  else
    found=0
    for t in "${REQUESTED[@]}"; do [[ "$t" == "app" ]] && found=1; done
    [[ $found -eq 0 ]] && REQUESTED+=(app)
  fi
fi

# Default to all targets; feasibility is decided per-target below.
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  REQUESTED=(server docker app apk)
fi

case "$(uname -s)" in
  Darwin) HOST="macos" ;;
  Linux) HOST="linux" ;;
  MINGW*|MSYS*|CYGWIN*) HOST="windows" ;;
  *) HOST="unknown" ;;
esac

echo "Séance build"
echo "  host:    $HOST ($(uname -s))"
echo "  profile: $PROFILE"
echo "  targets: ${REQUESTED[*]}"
echo

have() { command -v "$1" >/dev/null 2>&1; }

declare -a RESULTS=()
record() { RESULTS+=("$1"); }   # "server: built -> …" | "app: skipped (…)" | "apk: FAILED"

# Collect a finished artifact into dist/ (file or directory). The staged copy
# is what the summary points at — one folder with everything this run built.
DIST="$ROOT/dist"
STAGED=0
stage() {
  local src="$1" name="${2:-$(basename "$1")}"
  mkdir -p "$DIST"
  rm -rf "${DIST:?}/$name"
  cp -R "$src" "$DIST/$name" || return 1
  STAGED=$((STAGED + 1))
  echo "-- staged dist/$name"
}

# Was a given target explicitly named on the command line?
was_named() {
  [[ $EXPLICIT -eq 1 ]] || return 1
  local t
  for t in "${REQUESTED[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# Skip a target: a soft skip on a default run, a hard error when named.
skip_or_fail() {
  local target="$1" reason="$2"
  if was_named "$target"; then
    echo "!! $target: cannot build on this host — $reason" >&2
    record "$target: FAILED ($reason)"
    return 1
  fi
  echo ".. $target: skipped — $reason"
  record "$target: skipped ($reason)"
  return 0
}

# `dart pub get` for the workspace, once, shared by targets that need it.
PUB_RESOLVED=0
resolve_workspace() {
  [[ $PUB_RESOLVED -eq 1 ]] && return 0
  echo "-- dart pub get (workspace)"
  dart pub get || return 1
  PUB_RESOLVED=1
}

# ---------------------------------------------------------------------------
build_server() {
  echo "== server (native sync-server binary) =="
  if ! have dart; then skip_or_fail server "Dart SDK (dart) not found"; return; fi
  if ! resolve_workspace; then
    echo "!! server: dart pub get failed" >&2
    record "server: FAILED (pub get)"; return 1
  fi
  local exe="build/seance-sync"
  [[ "$HOST" == "windows" ]] && exe="build/seance-sync.exe"
  mkdir -p build
  echo "-- dart compile exe → $exe"
  if dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart -o "$exe"; then
    stage "$exe"
    record "server: built -> dist/$(basename "$exe")"
  else
    echo "!! server: dart compile exe failed" >&2
    record "server: FAILED (compile)"; return 1
  fi
}

# ---------------------------------------------------------------------------
build_docker() {
  echo "== docker (sync-server image) =="
  if ! have docker; then skip_or_fail docker "docker not found"; return; fi
  if ! docker info >/dev/null 2>&1; then
    skip_or_fail docker "docker daemon not reachable"; return
  fi
  # Build context MUST be the repo root so the pub workspace resolves.
  echo "-- docker build → seance-sync:local"
  if docker build -f packages/seance_sync_server/Dockerfile -t seance-sync:local .; then
    record "docker: built -> seance-sync:local"
  else
    echo "!! docker: image build failed" >&2
    record "docker: FAILED (docker build)"; return 1
  fi
}

# ---------------------------------------------------------------------------
# The platform folders are committed (they carry the app name, icons, and
# entitlements — AGENTS.md §3); regenerating here is only a fallback for a
# deleted folder, and such a regenerated folder loses those customizations.
ensure_platform() {
  local platform="$1"
  [[ -d "app/seance_app/$platform" ]] && return 0
  echo "-- platform folder app/seance_app/$platform missing; generating (flutter create)"
  ( cd app/seance_app && flutter create --platforms="$platform" --project-name seance_app . )
}

build_app() {
  echo "== app (Flutter desktop, this host) =="
  if [[ "$HOST" == "unknown" ]]; then
    skip_or_fail app "unrecognized host platform"; return
  fi
  if ! have flutter; then skip_or_fail app "Flutter SDK (flutter) not found"; return; fi
  if ! ensure_platform "$HOST"; then
    echo "!! app: flutter create failed" >&2
    record "app: FAILED (flutter create)"; return 1
  fi
  local mode_flag=""
  [[ "$PROFILE" == "debug" ]] && mode_flag="--debug"
  echo "-- flutter build $HOST ${mode_flag}"
  if ( cd app/seance_app && flutter pub get && flutter build "$HOST" $mode_flag ); then
    # Stage the final product; the nested output path differs per platform
    # (and per arch on linux), so glob for it.
    local cfg="Release" out=""
    [[ "$PROFILE" == "debug" ]] && cfg="Debug"
    case "$HOST" in
      macos)
        out=$(ls -d app/seance_app/build/macos/Build/Products/"$cfg"/*.app 2>/dev/null | head -1)
        # Xcode signs the ASCII "Seance.app" (codesign rejects accented file
        # names); the user-facing copy is renamed — safe, the wrapper name
        # isn't part of the signature seal.
        [[ -n "$out" ]] && stage "$out" "Séance.app"
        ;;
      linux)
        out=$(ls -d app/seance_app/build/linux/*/"$PROFILE"/bundle 2>/dev/null | head -1)
        [[ -n "$out" ]] && stage "$out" "seance-linux"
        ;;
      windows)
        out=$(ls -d app/seance_app/build/windows/*/runner/"$cfg" 2>/dev/null | head -1)
        [[ -n "$out" ]] && stage "$out" "seance-windows"
        ;;
    esac
    if [[ -n "$out" ]]; then
      record "app: built ($HOST, $PROFILE) -> dist/"
    else
      record "app: built ($HOST, $PROFILE) — product not found to stage"
    fi
    if $INSTALL; then
      if [[ -z "$out" ]]; then
        echo "!! app: nothing to install (product not found)" >&2
        record "app: install FAILED (product not found)"; return 1
      fi
      case "$HOST" in
        macos)
          echo "-- installing /Applications/Séance.app"
          rm -rf "/Applications/Séance.app"
          # ditto preserves the signature, resource forks, and permissions.
          if ditto "$out" "/Applications/Séance.app"; then
            INSTALLED="/Applications/Séance.app"
            record "app: installed -> /Applications/Séance.app"
            # Post-install sanity: surface the known "can't be opened" causes
            # here, instead of leaving Finder's generic refusal as the only
            # signal.
            if ! codesign --verify --deep --strict "$INSTALLED" 2>/dev/null; then
              echo "!! app: $INSTALLED fails codesign verification — it will not launch." >&2
              record "app: WARNING — installed app fails codesign verify"
            fi
            if codesign -d --entitlements - "$INSTALLED" 2>/dev/null \
                | grep -q keychain-access-groups; then
              echo "!! app: the installed build still carries the restricted" >&2
              echo "   keychain-access-groups entitlement, which blocks ad-hoc-signed" >&2
              echo "   launches — the checkout or build is stale. Fix with:" >&2
              echo "     git pull && (cd app/seance_app && flutter clean) && scripts/build.sh --install" >&2
              record "app: WARNING — stale build with keychain-access-groups"
            fi
          else
            record "app: install FAILED (ditto)"; return 1
          fi
          ;;
        linux)
          echo "-- installing $HOME/.local/opt/seance"
          rm -rf "$HOME/.local/opt/seance" && mkdir -p "$HOME/.local/opt"
          if cp -R "$out" "$HOME/.local/opt/seance"; then
            INSTALLED="$HOME/.local/opt/seance"
            record "app: installed -> ~/.local/opt/seance (binary: seance_app)"
          else
            record "app: install FAILED (copy)"; return 1
          fi
          ;;
        *)
          echo "!! app: --install is not supported on $HOST" >&2
          record "app: install FAILED (unsupported on $HOST)"; return 1
          ;;
      esac
    fi
  else
    echo "!! app: flutter build $HOST failed" >&2
    record "app: FAILED (flutter build $HOST)"; return 1
  fi
}

# ---------------------------------------------------------------------------
# An installed Android SDK is what separates "can build the APK" from a long
# doomed Gradle run; probe the usual locations like `flutter doctor` does.
detect_android_sdk() {
  local c
  for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$c" && -d "$c/platforms" ]] && { echo "$c"; return 0; }
  done
  return 1
}

build_apk() {
  echo "== apk (Android) =="
  if ! have flutter; then skip_or_fail apk "Flutter SDK (flutter) not found"; return; fi
  local sdk
  if ! sdk="$(detect_android_sdk)"; then
    skip_or_fail apk "no Android SDK found (set ANDROID_SDK_ROOT, or install one via Android Studio)"; return
  fi
  echo "-- Android SDK: $sdk"
  if ! ensure_platform android; then
    echo "!! apk: flutter create failed" >&2
    record "apk: FAILED (flutter create)"; return 1
  fi
  local mode_flag=""
  [[ "$PROFILE" == "debug" ]] && mode_flag="--debug"
  echo "-- flutter build apk ${mode_flag}"
  if ( cd app/seance_app && flutter pub get && flutter build apk $mode_flag ); then
    local apk
    apk="$(ls app/seance_app/build/app/outputs/flutter-apk/*.apk 2>/dev/null | head -1)"
    [[ -n "$apk" ]] && stage "$apk" "seance.apk"
    record "apk: built ($PROFILE)${apk:+ -> dist/seance.apk}"
  else
    echo "!! apk: flutter build apk failed" >&2
    record "apk: FAILED (flutter build apk)"; return 1
  fi
}

# ---------------------------------------------------------------------------
FAILED=0
INSTALLED=""
for target in "${REQUESTED[@]}"; do
  case "$target" in
    server) build_server || FAILED=1 ;;
    docker) build_docker || FAILED=1 ;;
    app)    build_app    || FAILED=1 ;;
    apk)    build_apk    || FAILED=1 ;;
  esac
  echo
done

echo "Summary"
for line in "${RESULTS[@]}"; do echo "  $line"; done

# Reveal the result: the installed copy when --install ran, else the dist/
# folder with everything this run produced (macOS only — elsewhere the paths
# in the summary are the deliverable).
if [[ -n "$INSTALLED" ]]; then
  echo "  installed: $INSTALLED"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    open -R "$INSTALLED"          # Finder, with the app selected
  elif have xdg-open; then
    xdg-open "$INSTALLED" >/dev/null 2>&1 || true
  fi
elif [[ "$STAGED" -gt 0 ]]; then
  echo "  artifacts: $DIST"
  if [[ "$(uname -s)" == "Darwin" ]]; then open "$DIST"; fi
fi

exit "$FAILED"
