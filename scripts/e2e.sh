#!/bin/bash
# End-to-end test across languages: the Swift sender (VideoToolbox + AAC + encrypted channel)
# casts a generated test pattern to the Kotlin receiver server running headless on the JVM.
#
# Checks: PIN pairing, encrypted streaming, SPS/PPS + keyframes, audio, token re-pair without PIN,
# wrong-PIN rejection. Exits non-zero on the first failed assertion.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/austialcast-e2e.XXXXXX")"
PORT="${E2E_PORT:-17491}"
PIN=123456
FAILED=0
RECEIVER_PID=""

stop_receiver() { [ -n "$RECEIVER_PID" ] && { kill "$RECEIVER_PID" 2>/dev/null; wait "$RECEIVER_PID" 2>/dev/null; }; RECEIVER_PID=""; }
cleanup() { stop_receiver; rm -rf "$WORK"; }
trap cleanup EXIT

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

echo "Building…"
(cd "$ROOT/android" && ./gradlew :core:installDist --console=plain -q) || { echo "gradle build failed"; exit 1; }
(cd "$ROOT/mac" && swift build --product austialcast 2>&1 | tail -3) || { echo "swift build failed"; exit 1; }
SENDER="$ROOT/mac/.build/debug/austialcast"
RECEIVER="$ROOT/android/core/build/install/core/bin/core"

start_receiver() {
  : > "$WORK/receiver.log"
  local expect=()
  [ "$1" -gt 0 ] && expect=(--expect-frames "$1")
  "$RECEIVER" --port "$PORT" --pin "$PIN" --fixed-pin --dump "$WORK/out.h264" --audio-dump "$WORK/out.aac" \
    ${expect[@]+"${expect[@]}"} --timeout 60 > "$WORK/receiver.log" 2>&1 &
  RECEIVER_PID=$!
  for _ in $(seq 1 100); do grep -q LISTENING "$WORK/receiver.log" 2>/dev/null && return 0; sleep 0.1; done
  echo "receiver did not start"; cat "$WORK/receiver.log"; exit 1
}

echo "1. First cast: PIN pairing, encrypted video + audio"
start_receiver 40
"$SENDER" send --host "127.0.0.1:$PORT" --pin "$PIN" --test-pattern --preset 720p30 --seconds 4 --token-file "$WORK/tokens.json" > "$WORK/sender1.log" 2>&1
SENDER_RC=$?
wait "$RECEIVER_PID"; RECEIVER_RC=$?; RECEIVER_PID=""
check "sender exited cleanly"                       "[ $SENDER_RC -eq 0 ]"
check "receiver reported success (>=40 frames)"     "[ $RECEIVER_RC -eq 0 ]"
check "receiver authenticated via PIN"              "grep -q 'AUTHENTICATED .* token=false' '$WORK/receiver.log'"
check "stream parameters announced (1280x720@30)"   "grep -q 'STREAM 1280x720@30' '$WORK/receiver.log'"
check "audio announced"                             "grep -q 'audio=true' '$WORK/receiver.log'"
check "no keyframe-flag mismatches"                 "! grep -q 'WARN' '$WORK/receiver.log'"
check "video dump starts with an SPS NAL (type 7)"  "[ \$(( 0x\$(xxd -p -s 4 -l 1 '$WORK/out.h264') & 31 )) -eq 7 ]"
check "video dump is non-trivial (>20 KB)"          "[ \$(stat -f%z '$WORK/out.h264') -gt 20000 ]"
check "audio packets received"                      "[ \$(stat -f%z '$WORK/out.aac') -gt 500 ]"
check "pairing token saved by sender"               "grep -q token '$WORK/tokens.json'"

echo "2. Second cast: trusted device reconnects without a PIN"
# Fresh receiver process has an empty trust store, so pair again then reconnect within the same process.
start_receiver 0
"$SENDER" send --host "127.0.0.1:$PORT" --pin "$PIN" --test-pattern --preset 720p30 --seconds 2 --token-file "$WORK/tokens2.json" > "$WORK/sender2a.log" 2>&1
"$SENDER" send --host "127.0.0.1:$PORT" --test-pattern --preset 720p30 --seconds 3 --token-file "$WORK/tokens2.json" > "$WORK/sender2b.log" 2>&1
SENDER_RC=$?
sleep 0.5; stop_receiver
check "token reconnect needs no PIN"                "[ $SENDER_RC -eq 0 ]"
check "receiver authenticated via token"            "grep -q 'AUTHENTICATED .* token=true' '$WORK/receiver.log'"

echo "3. Wrong PIN and missing PIN are rejected"
start_receiver 0
"$SENDER" send --host "127.0.0.1:$PORT" --pin 000000 --test-pattern --seconds 2 --token-file "$WORK/tokens3.json" > "$WORK/sender3.log" 2>&1
check "wrong PIN exits with code 11"               "[ $? -eq 11 ]"
"$SENDER" send --host "127.0.0.1:$PORT" --test-pattern --seconds 2 --token-file "$WORK/tokens3.json" > "$WORK/sender3b.log" 2>&1
check "missing PIN exits with code 10"             "[ $? -eq 10 ]"
check "receiver logged AUTH_FAILED bad_pin"        "grep -q 'AUTH_FAILED bad_pin' '$WORK/receiver.log'"
stop_receiver

echo
if [ $FAILED -eq 0 ]; then echo "E2E PASSED"; else echo "E2E FAILED"; echo "--- receiver log ---"; cat "$WORK/receiver.log"; echo "--- sender1 ---"; cat "$WORK/sender1.log"; fi
exit $FAILED
