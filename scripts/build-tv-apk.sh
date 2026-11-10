#!/bin/bash
# Builds a signed, installable release APK for Android TV / Google TV -> dist/AustialCast-TV.apk
#
# The APK is signed with a private key generated once and kept in ~/.austialcast (so later builds are
# signed by the same key and can update an installed copy). Nothing leaves your machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
KEYDIR="$HOME/.austialcast"
KEYSTORE="$KEYDIR/release.keystore"
PASSFILE="$KEYDIR/keystore.pass"

mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
if [ ! -f "$KEYSTORE" ]; then
  echo "Generating a signing key in $KEYDIR (one time)…"
  PASS="$(openssl rand -hex 16)"
  ( umask 077; echo "$PASS" > "$PASSFILE" )
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storepass "$PASS" -keypass "$PASS" \
    -alias austialcast -keyalg RSA -keysize 3072 -validity 9125 -dname "CN=AustialCast" >/dev/null 2>&1
fi
PASS="$(cat "$PASSFILE")"

echo "Building release APK…"
(cd "$ROOT/android" && ./gradlew :app:assembleRelease --console=plain -q)
UNSIGNED="$ROOT/android/app/build/outputs/apk/release/app-release-unsigned.apk"
mkdir -p "$ROOT/dist"
ALIGNED="$(mktemp -d)/aligned.apk"
"$BT/zipalign" -f -p 4 "$UNSIGNED" "$ALIGNED"
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$PASS" --key-pass "pass:$PASS" --out "$ROOT/dist/AustialCast-TV.apk" "$ALIGNED"
"$BT/apksigner" verify "$ROOT/dist/AustialCast-TV.apk" && echo "Signature verified."
echo "Built $ROOT/dist/AustialCast-TV.apk"
echo "Install with:  adb connect <tv-ip>:5555 && adb install -r dist/AustialCast-TV.apk"
