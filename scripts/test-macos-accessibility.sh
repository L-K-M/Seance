#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This native accessibility test requires macOS." >&2
  exit 1
fi

generated_config="$repo_root/app/seance_app/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
flutter_sdk="${FLUTTER_ROOT:-}"
if [[ -z "$flutter_sdk" && -f "$generated_config" ]]; then
  flutter_sdk="$(sed -n 's/^FLUTTER_ROOT=//p' "$generated_config")"
fi
if [[ -z "$flutter_sdk" ]]; then
  echo "Set FLUTTER_ROOT or run flutter build macos before this test." >&2
  exit 1
fi

framework_dir="$flutter_sdk/bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64"
if [[ ! -d "$framework_dir" ]]; then
  echo "Missing macOS release engine. Run flutter precache --macos." >&2
  exit 1
fi

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/seance-accessibility.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
runner_dir="$repo_root/app/seance_app/macos/Runner"
guard_flags=(-DSEANCE_USE_GUARD=1)
if [[ $# == 1 && "$1" == --stock-engine ]]; then
  guard_flags=(-DSEANCE_USE_GUARD=0)
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--stock-engine]" >&2
  exit 1
fi

# Build the same controller used by the app against the real Flutter framework.
# The fixture injects semantics directly; it never starts the Dart application.
xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa -framework FlutterMacOS \
  -F "$framework_dir" -I "$flutter_sdk/engine/src" -I "$runner_dir" \
  -Wl,-rpath,"$framework_dir" "${guard_flags[@]}" \
  "$repo_root/app/seance_app/macos/RunnerTests/AccessibilityLifecycleTest.mm" \
  -x objective-c++ "$runner_dir/SeanceFlutterViewController.m" \
  -o "$test_dir/accessibility-test"
"$test_dir/accessibility-test"
