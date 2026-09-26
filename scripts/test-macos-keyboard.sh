#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This native keyboard test requires macOS." >&2
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

controller_flags=(-DSEANCE_USE_CONTROLLER=1)
if [[ $# == 1 && "$1" == --stock-engine ]]; then
  controller_flags=(-DSEANCE_USE_CONTROLLER=0)
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--stock-engine]" >&2
  exit 1
fi

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/seance-keyboard.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
runner_dir="$repo_root/app/seance_app/macos/Runner"
# Compile the actual controller against the bundled engine. The executable
# supplies only framework replies; it starts no Dart application or window,
# and never posts input to the system.
xcrun clang -fobjc-arc -F "$framework_dir" -I "$runner_dir" \
  -c "$runner_dir/SeanceFlutterViewController.m" \
  -o "$test_dir/controller.o"
xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa -framework FlutterMacOS \
  -F "$framework_dir" -I "$flutter_sdk/engine/src" -I "$runner_dir" \
  -Wl,-rpath,"$framework_dir" "${controller_flags[@]}" -x objective-c++ \
  "$repo_root/scripts/test-macos-keyboard.mm" \
  -x none "$test_dir/controller.o" \
  -o "$test_dir/keyboard-test"
"$test_dir/keyboard-test"
