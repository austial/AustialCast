#!/bin/bash
# Runs the whole test pyramid:
#   1. Kotlin unit + integration tests (protocol, receiver server over loopback, UI model, app logic)
#   2. Android lint
#   3. Swift tests (protocol vs. Kotlin golden vectors, VideoToolbox round-trip, CastSession flows)
#   4. Cross-language E2E: Swift sender -> Kotlin receiver (headless)
#   5. Emulator E2E: Swift sender -> real Android TV app (only if an adb device/emulator is connected)
#
#   ./scripts/test-all.sh                 run everything available
#   ./scripts/test-all.sh --no-emulator   skip step 5
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/platform-tools:$PATH"
RESULTS=()
FAILED=0

run() {
  local name="$1"; shift
  echo; echo "━━ $name"
  if "$@"; then RESULTS+=("✓ $name"); else RESULTS+=("✗ $name"); FAILED=1; fi
}

run "Kotlin tests (core + app)"      bash -c "cd '$ROOT/android' && ./gradlew test --console=plain -q"
run "Android lint"                   bash -c "cd '$ROOT/android' && ./gradlew :app:lintDebug --console=plain -q"
run "Swift tests"                    bash -c "cd '$ROOT/mac' && swift test 2>&1 | '$ROOT/scripts/clean.sh' | grep -E 'Executed [0-9]+ tests' | tail -1 && swift test 2>&1 | grep -q 'with 0 failures'"
run "E2E: Swift sender -> Kotlin receiver" "$ROOT/scripts/e2e.sh"

if [ "${1:-}" != "--no-emulator" ] && [ "$(adb devices 2>/dev/null | grep -c 'device$')" -eq 1 ]; then
  run "E2E: Swift sender -> Android TV app (emulator)" "$ROOT/scripts/e2e-emulator.sh"
else
  RESULTS+=("- E2E on Android TV emulator skipped (no single adb device, or --no-emulator)")
fi

echo; echo "════════ SUMMARY ════════"
printf '%s\n' "${RESULTS[@]}"
[ $FAILED -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAILED
