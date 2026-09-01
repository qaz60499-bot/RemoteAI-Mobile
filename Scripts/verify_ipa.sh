#!/bin/bash
set -euo pipefail

IPA="${1:?usage: verify_ipa.sh <ipa> [expected-bundle-id]}"
EXPECTED_BUNDLE="${2:-com.remoteai.mobile}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -s "$IPA" ]] || { echo "IPA missing or empty: $IPA" >&2; exit 1; }
unzip -t "$IPA" >/dev/null
unzip -q "$IPA" -d "$TMP"

APP_COUNT=$(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')
[[ "$APP_COUNT" == "1" ]] || { echo "Expected exactly one Payload/*.app, got $APP_COUNT" >&2; exit 1; }
APP=$(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' | head -1)
PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || { echo "Info.plist missing" >&2; exit 1; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE" ]] || { echo "Bundle ID mismatch: $BUNDLE_ID" >&2; exit 1; }
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")
BIN="$APP/$EXEC"
[[ -f "$BIN" && -x "$BIN" ]] || { echo "Executable missing: $BIN" >&2; exit 1; }

file "$BIN"
ARCHS=$(lipo -archs "$BIN")
echo "Architectures: $ARCHS"
echo "$ARCHS" | tr ' ' '\n' | grep -qx arm64 || { echo "arm64 missing" >&2; exit 1; }
# Device build: Mach-O LC_BUILD_VERSION platform 2 == iOS (not iOS Simulator).
otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1;n=0} f{print;n++} n>8{f=0}' | grep -q 'platform 2' || { echo "Mach-O is not marked for iOS device platform" >&2; exit 1; }

IPA_BYTES=$(stat -f%z "$IPA")
BIN_BYTES=$(stat -f%z "$BIN")
[[ "$IPA_BYTES" -gt 200000 ]] || { echo "IPA suspiciously small: $IPA_BYTES bytes" >&2; exit 1; }
[[ "$BIN_BYTES" -gt 100000 ]] || { echo "Executable suspiciously small: $BIN_BYTES bytes" >&2; exit 1; }

codesign -dv --verbose=2 "$APP" 2>&1 | grep -q 'Signature=' || { echo "App lacks ad-hoc signature" >&2; exit 1; }

echo "IPA verification PASS"
echo "app=$APP"
echo "bundle_id=$BUNDLE_ID"
echo "minimum_ios=$MIN_OS"
echo "ipa_bytes=$IPA_BYTES"
echo "binary_bytes=$BIN_BYTES"
