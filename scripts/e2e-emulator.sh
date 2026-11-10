#!/bin/bash
# End-to-end test against a running Android TV emulator/device (adb must see exactly one device):
#   Swift sender (Mac)  --adb forward-->  real TV app (MediaCodec + Surface)
#
# Verifies: install + launch, PIN shown on the TV, PIN pairing, decoded video on screen (pixel check),
# end-of-cast notice, wrong-PIN notice, and PIN-less reconnect with the stored token.
#
# Start an emulator first, e.g.:  emulator -avd austialcast_tv -no-window -no-audio -no-snapshot &
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/platform-tools:$PATH"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/austialcast-emu.XXXXXX")"
trap 'rm -rf "$WORK"; adb forward --remove tcp:17391 >/dev/null 2>&1' EXIT
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

ui_text() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml; }

adb get-state >/dev/null 2>&1 || { echo "no adb device/emulator connected"; exit 1; }

echo "Building…"
(cd "$ROOT/android" && ./gradlew :app:assembleDebug --console=plain -q) || { echo "gradle build failed"; exit 1; }
(cd "$ROOT/mac" && swift build --product austialcast 2>&1 | tail -1)
SENDER="$ROOT/mac/.build/debug/austialcast"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"

echo "1. Install and launch the TV app"
adb uninstall app.austial.cast.tv >/dev/null 2>&1   # a differently signed build may be installed
adb install "$APK" >/dev/null 2>&1; check "APK installs" "[ $? -eq 0 ]"
adb shell pm clear app.austial.cast.tv >/dev/null 2>&1
adb logcat -c
adb shell am start -n app.austial.cast.tv/.MainActivity >/dev/null 2>&1
sleep 4
UI="$(ui_text)"
PIN="$(echo "$UI" | grep -o 'text="[0-9]\{3\} [0-9]\{3\}"' | head -1 | tr -dc '0-9')"
check "TV shows a 6 digit PIN ($PIN)" "[ ${#PIN} -eq 6 ]"
check "TV shows its address"          "echo \"\$UI\" | grep -q ':7391'"
adb forward tcp:17391 tcp:7391 >/dev/null

echo "2. Pair with the PIN and stream"
"$SENDER" send --host 127.0.0.1:17391 --pin "$PIN" --test-pattern --preset 720p30 --seconds 12 --token-file "$WORK/tokens.json" > "$WORK/sender1.log" 2>&1 &
SENDER_PID=$!
sleep 7
adb exec-out screencap -p > "$WORK/streaming.png"
check "TV renders decoded video (colour bars on screen)" "python3 '$ROOT/scripts/png_check.py' colorful '$WORK/streaming.png' >/dev/null"
wait $SENDER_PID; RC=$?
check "sender exited cleanly"                   "[ $RC -eq 0 ]"
check "sender reached streaming state"          "grep -q 'state: streaming' '$WORK/sender1.log'"
check "sender measured a round-trip time"       "grep -Eq 'rtt [0-9.]+ ms' '$WORK/sender1.log'"
check "no dropped frames on loopback"           "grep -q 'dropped 0' '$WORK/sender1.log'"
sleep 1
UI="$(ui_text)"
check "TV returns to the pairing screen with a notice" "echo \"\$UI\" | grep -q 'stopped casting'"
check "pairing token stored by the sender"      "grep -q token '$WORK/tokens.json'"

echo "3. Reconnect without PIN (trusted device)"
"$SENDER" send --host 127.0.0.1:17391 --test-pattern --preset 720p30 --seconds 4 --token-file "$WORK/tokens.json" > "$WORK/sender2.log" 2>&1
check "token reconnect succeeds without a PIN"  "[ $? -eq 0 ]"

echo "4. Wrong PIN"
"$SENDER" send --host 127.0.0.1:17391 --pin 000000 --test-pattern --seconds 3 --token-file "$WORK/tokens-other.json" > "$WORK/sender3.log" 2>&1
check "wrong PIN exits with code 11"            "[ $? -eq 11 ]"
sleep 1
UI="$(ui_text)"
check "TV tells the user about the wrong PIN"   "echo \"\$UI\" | grep -q 'Wrong PIN'"

echo "5. App health"
check "no crashes in logcat"                    "! adb logcat -d | grep -E 'FATAL EXCEPTION|AndroidRuntime.*app.austial.cast' | grep -q ."

echo
if [ $FAILED -eq 0 ]; then echo "EMULATOR E2E PASSED"; else echo "EMULATOR E2E FAILED"; echo "--- sender1 ---"; cat "$WORK/sender1.log"; adb logcat -d | grep -E "AustialCast|AndroidRuntime" | tail -20; fi
exit $FAILED
