#!/bin/bash
set -euo pipefail

IPA="${1:?usage: verify_ipa.sh <ipa> [expected-bundle-id]}"
EXPECTED_BUNDLE="${2:-com.remoteai.mobile}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "IPA VERIFY FAILED: $*" >&2
  exit 1
}

[[ -s "$IPA" ]] || fail "IPA missing or empty: $IPA"
unzip -t "$IPA" >/dev/null || fail "ZIP integrity check failed"

BAD_ENTRY="$(unzip -Z1 "$IPA" | while IFS= read -r entry; do
  case "$entry" in
    Payload|Payload/|Payload/*) ;;
    *) printf '%s\n' "$entry"; break ;;
  esac
  case "$entry" in
    /*|*../*|../*|*\\*) printf '%s\n' "$entry"; break ;;
  esac
done | head -1)"
[[ -z "$BAD_ENTRY" ]] || fail "unexpected or unsafe ZIP entry: $BAD_ENTRY"

unzip -q "$IPA" -d "$TMP"
[[ -d "$TMP/Payload" ]] || fail "Payload directory missing"
[[ -z "$(find "$TMP" -type l -print -quit)" ]] || fail "symlink found inside IPA"

APP_COUNT=$(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')
[[ "$APP_COUNT" == "1" ]] || fail "expected exactly one Payload/*.app, got $APP_COUNT"
APP=$(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' | head -1)
EXTRA_PAYLOAD_ENTRY=$(find "$TMP/Payload" -mindepth 1 -maxdepth 1 ! -path "$APP" -print -quit)
[[ -z "$EXTRA_PAYLOAD_ENTRY" ]] || fail "unexpected sibling in Payload: ${EXTRA_PAYLOAD_ENTRY#$TMP/}"
PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || fail "Info.plist missing"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE" ]] || fail "Bundle ID mismatch: $BUNDLE_ID"
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")
PLATFORM=$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$PLIST")
SUPPORTED_PLATFORM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$PLIST")
[[ "$MIN_OS" == "15.0" ]] || fail "minimum iOS drifted: $MIN_OS"
[[ "$PLATFORM" == "iphoneos" ]] || fail "DTPlatformName is not iphoneos: $PLATFORM"
[[ "$SUPPORTED_PLATFORM" == "iPhoneOS" ]] || fail "CFBundleSupportedPlatforms is not iPhoneOS: $SUPPORTED_PLATFORM"

BIN="$APP/$EXEC"
[[ -f "$BIN" && -x "$BIN" ]] || fail "executable missing: $BIN"
file "$BIN"
ARCHS=$(lipo -archs "$BIN")
echo "Architectures: $ARCHS"
[[ "$ARCHS" == "arm64" ]] || fail "expected arm64-only executable, got: $ARCHS"
# Mach-O LC_BUILD_VERSION platform 2 == iOS device (not iOS Simulator).
LC_BUILD=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1;n=0} f{print;n++} n>8{f=0}')
printf '%s\n' "$LC_BUILD" | grep -q 'platform 2' || fail "Mach-O is not marked for iOS device platform"
printf '%s\n' "$LC_BUILD" | grep -Eq 'minos[[:space:]]+15\.0$' || fail "Mach-O minimum iOS is not 15.0"

IPA_BYTES=$(stat -f%z "$IPA")
BIN_BYTES=$(stat -f%z "$BIN")
[[ "$IPA_BYTES" -gt 200000 ]] || fail "IPA suspiciously small: $IPA_BYTES bytes"
[[ "$IPA_BYTES" -lt 52428800 ]] || fail "IPA unexpectedly large: $IPA_BYTES bytes"
[[ "$BIN_BYTES" -gt 100000 ]] || fail "executable suspiciously small: $BIN_BYTES bytes"
[[ "$BIN_BYTES" -lt 26214400 ]] || fail "executable unexpectedly large: $BIN_BYTES bytes"

SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)" || fail "codesign metadata unavailable"
printf '%s\n' "$SIGNATURE_INFO" | grep -q '^Signature=adhoc$' || fail "app is not ad-hoc signed"
printf '%s\n' "$SIGNATURE_INFO" | grep -q '^TeamIdentifier=not set$' || fail "unexpected signing team present"
codesign --verify --deep --strict "$APP" || fail "codesign verification failed"

ENTITLEMENTS="$TMP/entitlements.plist"
codesign -d --entitlements :- "$APP" >"$ENTITLEMENTS" 2>/dev/null || true
if [[ -s "$ENTITLEMENTS" ]]; then
  python3 - "$ENTITLEMENTS" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = plistlib.loads(path.read_bytes())
except Exception as exc:
    raise SystemExit(f"unable to parse entitlements: {exc}")
if data:
    raise SystemExit(f"unexpected entitlements in TrollStore build: {sorted(data)}")
PY
fi
echo "Entitlement audit: PASS"

FORBIDDEN_PATH="$(find "$APP" \( -type d \( -name '.git' -o -name '.github' -o -name 'Fixtures' -o -name '*Tests*' -o -name '*.xctest' -o -name '*.dSYM' \) -o -type f \( -name '*.map' -o -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.py' -o -name '*.sh' -o -name '*.xcconfig' -o -name '*.mobileprovision' -o -name 'embedded.mobileprovision' -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '.env' -o -name '.env.*' \) \) -print -quit)"
[[ -z "$FORBIDDEN_PATH" ]] || fail "forbidden release content found: ${FORBIDDEN_PATH#$TMP/}"
echo "Release content contamination scan: PASS"

SECRET_PATTERN='(-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|A(KIA|SIA)[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{32,}|AIza[0-9A-Za-z_-]{35}|(CLOUDFLARE_API_TOKEN|CF_API_TOKEN|GITHUB_TOKEN|PROVIDER_API_KEY|PAIRING_SECRET)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}|GITHUB_(SHA|RUN_ID|RUN_NUMBER|WORKFLOW|REPOSITORY|TOKEN)[[:space:]]*[:=])'
if grep -R -I -nE "$SECRET_PATTERN" "$APP" >/dev/null 2>&1; then
  grep -R -I -nE "$SECRET_PATTERN" "$APP" >&2 || true
  fail "secret-like material found in app resources"
fi

DEV_URL_PATTERN='((http|ws)://|(https|wss)://[^[:space:]]*(localhost|127\.0\.0\.1|0\.0\.0\.0|dev[-.]?relay|relay[-.]?dev|staging))'
if grep -R -I -nE "$DEV_URL_PATTERN" "$APP" >/dev/null 2>&1; then
  grep -R -I -nE "$DEV_URL_PATTERN" "$APP" >&2 || true
  fail "development/local URL found in app resources"
fi

BIN_STRINGS="$TMP/binary.strings"
strings -a "$BIN" > "$BIN_STRINGS"
if grep -nE "$SECRET_PATTERN" "$BIN_STRINGS" >/dev/null 2>&1; then
  grep -nE "$SECRET_PATTERN" "$BIN_STRINGS" >&2 || true
  fail "secret-like material found in executable strings"
fi
if grep -nE "$DEV_URL_PATTERN" "$BIN_STRINGS" >/dev/null 2>&1; then
  grep -nE "$DEV_URL_PATTERN" "$BIN_STRINGS" >&2 || true
  fail "development/local URL found in executable strings"
fi
echo "Sensitive-content scan: PASS"

IPA_SHA256=$(shasum -a 256 "$IPA" | awk '{print $1}')

echo "IPA verification PASS"
echo "app=$APP"
echo "bundle_id=$BUNDLE_ID"
echo "minimum_ios=$MIN_OS"
echo "platform=$PLATFORM"
echo "signing=adhoc"
echo "entitlements=none"
echo "ipa_bytes=$IPA_BYTES"
echo "binary_bytes=$BIN_BYTES"
echo "ipa_sha256=$IPA_SHA256"
