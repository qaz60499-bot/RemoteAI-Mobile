#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "SECURITY AUDIT FAILED: $*" >&2
  exit 1
}

if python3 -c 'import sys' >/dev/null 2>&1; then
  PYTHON=python3
elif python -c 'import sys' >/dev/null 2>&1; then
  PYTHON=python
else
  fail "Python 3 runtime is required for security audit"
fi

"$PYTHON" -m json.tool contracts/protocol-v1.json >/dev/null
EXPECTED_CONTRACT_SHA="18c3305e7d3e275cbe5e8b6698e3a53afe5acd197e62bc4d8b5134e08e46bacc"
ACTUAL_CONTRACT_SHA="$("$PYTHON" -c 'import hashlib; print(hashlib.sha256(open("contracts/protocol-v1.json","rb").read()).hexdigest())')"
[[ "$ACTUAL_CONTRACT_SHA" == "$EXPECTED_CONTRACT_SHA" ]] || fail "protocol-v1.json hash drifted: $ACTUAL_CONTRACT_SHA"

"$PYTHON" - <<'PY'
import plistlib
from pathlib import Path

plist = plistlib.loads(Path("RemoteAIMobile/Info.plist").read_bytes())
if str(plist.get("MinimumOSVersion")) != "15.0":
    raise SystemExit("MinimumOSVersion must remain 15.0")
if not plist.get("NSCameraUsageDescription"):
    raise SystemExit("Camera permission purpose string is missing")
if "CFBundleURLTypes" in plist:
    raise SystemExit("Unexpected custom URL scheme exposure")
if "RemoteAIRelayDefaultURL" in plist:
    raise SystemExit("Relay endpoint must not be embedded in Info.plist")
ats = plist.get("NSAppTransportSecurity")
if ats:
    if ats.get("NSAllowsArbitraryLoads") or ats.get("NSAllowsArbitraryLoadsInWebContent") or ats.get("NSAllowsLocalNetworking"):
        raise SystemExit("Unsafe ATS relaxation detected")
    if ats.get("NSExceptionDomains"):
        raise SystemExit("ATS exception domain detected")
PY

grep -q 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' RemoteAIMobile/Security.swift || fail "Keychain accessibility is not ThisDeviceOnly"
grep -q 'Curve25519.KeyAgreement.PrivateKey' RemoteAIMobile/Security.swift || fail "X25519 private-key generation missing"
grep -q 'A256GCM' RemoteAIMobile/Security.swift || fail "AES-256-GCM envelope missing"
grep -q 'ProtocolSecurity.decodeRelayFrame' RemoteAIMobile/CloudflareTransport.swift || fail "relay frames are not using strict protocol decoding"
grep -q 'inboundReplayGuard.accept(frame.messageId)' RemoteAIMobile/CloudflareTransport.swift || fail "encrypted relay replay guard missing"
grep -q 'ProtocolSecurity.decodeDecryptedPayload' RemoteAIMobile/CloudflareTransport.swift || fail "decrypted relay payload validation missing"
grep -q 'ProtocolSecurity.decodeDelta' RemoteAIMobile/Transport.swift || fail "delta response validation missing"
grep -q 'BoundedReplayGuard' RemoteAIMobile/ProtocolSecurity.swift || fail "bounded replay guard implementation missing"
grep -q 'keychain.delete(account: legacyPrivateAccount(machineId))' RemoteAIMobile/Security.swift || fail "legacy private-key cleanup missing"
if grep -nE 'keychain\.save\(privateKeyRaw|static func privateKey\(' RemoteAIMobile/Security.swift; then
  fail "ephemeral X25519 private key is persisted or exposed after pairing"
fi
if grep -nE 'UserDefaults|SQLiteStore|sqlite3_' RemoteAIMobile/Security.swift; then
  fail "pairing key implementation references non-Keychain persistence"
fi
if grep -R -nE 'print\(|NSLog\(|os_log\(|Logger\(' RemoteAIMobile; then
  fail "runtime logging call detected; review before allowing potentially sensitive payloads"
fi

grep -q 'PRAGMA secure_delete=ON' RemoteAIMobile/SQLiteStore.swift || fail "SQLite secure_delete is not enabled"
grep -q 'PRAGMA journal_mode=WAL' RemoteAIMobile/SQLiteStore.swift || fail "SQLite WAL mode missing"
grep -q 'PRAGMA trusted_schema=OFF' RemoteAIMobile/SQLiteStore.swift || fail "SQLite trusted_schema hardening missing"
grep -q 'FileProtectionType.complete' RemoteAIMobile/SQLiteStore.swift || fail "SQLite is not using complete iOS Data Protection"
grep -q 'SQLiteStore.inMemory()' RemoteAIMobile/WorkspaceStore.swift || fail "secure-store failure must fall back to memory, not temporary disk"
grep -q 'try await cache.clearAll()' RemoteAIMobile/WorkspaceStore.swift || fail "machine re-pair must clear prior cache"
if grep -nEi 'pairing.?secret|shared.?key|x25519.?private|provider.?api.?key|github.?token|cloudflare.?token' RemoteAIMobile/SQLiteStore.swift; then
  fail "SQLite implementation contains a secret-bearing persistence path"
fi

if grep -R -nE 'X-RemoteAI-Device|sharedSecretBase64|/v1/(pair|command)|protocolVersion: "1"' RemoteAIMobile; then
  fail "legacy or secret-bearing transport pattern detected"
fi
if grep -R -nE 'http://[^<"]+|ws://[^<"]+' RemoteAIMobile --include='*.swift'; then
  fail "plain HTTP/WS production URL detected in Swift sources"
fi

grep -q '^permissions:' .github/workflows/build-ipa.yml || fail "workflow permissions block missing"
grep -q '^  contents: read$' .github/workflows/build-ipa.yml || fail "workflow contents permission must be read-only"
if grep -nE '^  (actions|attestations|checks|contents|deployments|id-token|issues|packages|pages|pull-requests|security-events|statuses): write$' .github/workflows/build-ipa.yml; then
  fail "workflow write permission detected"
fi
grep -q 'persist-credentials: false' .github/workflows/build-ipa.yml || fail "checkout must not persist GITHUB_TOKEN credentials"
grep -q 'Protocol Security / Fuzz' .github/workflows/build-ipa.yml || fail "protocol security fuzz step missing from macOS CI"
grep -q 'commandResponseKeys' RemoteAIMobile/ProtocolSecurity.swift || fail "strict decrypted command-response key validation missing"
grep -q 'errorCodes' RemoteAIMobile/ProtocolSecurity.swift || fail "protocol-v1 remote error allowlist missing"
grep -q 'encode(decoded) == value' RemoteAIMobile/Security.swift || fail "canonical Base64URL validation missing"
grep -q 'connectionWaiters' RemoteAIMobile/CloudflareTransport.swift || fail "concurrent WebSocket connect coalescing missing"
grep -Fq 'pending[command.commandId] == nil' RemoteAIMobile/CloudflareTransport.swift || fail "duplicate in-flight commandId guard missing"
grep -q 'fetch-depth: 0' .github/workflows/build-ipa.yml || fail "full Git history is required for secret scanning"
WORKFLOW=.github/workflows/build-ipa.yml
if grep -nE '^  (pull_request|pull_request_target|workflow_run):' "$WORKFLOW"; then
  fail "untrusted PR/workflow_run events must not build release IPA artifacts"
fi
if grep -nF '${{ secrets.' "$WORKFLOW"; then
  fail "release IPA workflow must not consume repository secrets"
fi
if grep -nE '^    inputs:' "$WORKFLOW"; then
  fail "workflow_dispatch inputs are not allowed to influence release builds"
fi
grep -Fq "if: github.ref == 'refs/heads/main'" "$WORKFLOW" || fail "manual release build must be restricted to main"
grep -q '^    runs-on: macos-15$' "$WORKFLOW" || fail "release build must stay on the explicit macos-15 runner label"
if grep -nE 'runs-on: macos-latest|find /Applications.*Xcode_.*tail -1|brew install xcodegen' "$WORKFLOW"; then
  fail "mutable Xcode/XcodeGen toolchain selection detected"
fi
grep -q 'IPA verifier negative tests' "$WORKFLOW" || fail "IPA verifier negative tests missing"
grep -q 'path-traversal-negative.ipa' "$WORKFLOW" || fail "path traversal IPA negative test missing"
grep -q 'duplicate-entry-negative.ipa' "$WORKFLOW" || fail "duplicate ZIP-entry IPA negative test missing"
grep -q 'symlink-negative.ipa' "$WORKFLOW" || fail "symlink IPA negative test missing"
grep -q 'Reproducible packaging check' "$WORKFLOW" || fail "deterministic IPA packaging check missing"
grep -q 'build/build-provenance.txt' "$WORKFLOW" || fail "build provenance artifact missing"

"$PYTHON" - "$WORKFLOW" project.yml <<'PY'
import re
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
project = Path(sys.argv[2]).read_text(encoding="utf-8")

def env(name):
    m = re.search(rf'^  {re.escape(name)}: "([^"]+)"$', workflow, flags=re.MULTILINE)
    if not m:
        raise SystemExit(f"workflow env pin missing: {name}")
    return m.group(1)

xcode = env("XCODE_VERSION")
xcode_build = env("XCODE_BUILD")
sdk = env("IPHONEOS_SDK_VERSION")
sim_runtime = env("IOS_SIM_RUNTIME")
xcodegen = env("XCODEGEN_VERSION")
xcodegen_sha = env("XCODEGEN_SHA256")
xcodegen_url = env("XCODEGEN_URL")
if (xcode, xcode_build, sdk) != ("16.4", "16F6", "18.5"):
    raise SystemExit(f"unapproved Xcode toolchain pin: {(xcode, xcode_build, sdk)}")
if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", xcode):
    raise SystemExit(f"invalid Xcode pin: {xcode}")
if not re.fullmatch(r"[0-9A-Za-z]+", xcode_build):
    raise SystemExit(f"invalid Xcode build pin: {xcode_build}")
if not re.fullmatch(r"\d+\.\d+", sdk):
    raise SystemExit(f"invalid iPhoneOS SDK pin: {sdk}")
expected_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + sdk.replace(".", "-")
if sim_runtime != expected_runtime:
    raise SystemExit(f"simulator runtime pin does not match SDK: {sim_runtime} vs {sdk}")
if xcodegen != "2.46.0":
    raise SystemExit(f"unexpected XcodeGen version pin: {xcodegen}")
if xcodegen_sha != "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806":
    raise SystemExit("XcodeGen archive SHA256 pin mismatch")
if xcodegen_url != f"https://github.com/yonaskolb/XcodeGen/releases/download/{xcodegen}/xcodegen.zip":
    raise SystemExit("XcodeGen download URL is not tied to the pinned release")
px = re.search(r'^  xcodeVersion: "([^"]+)"$', project, flags=re.MULTILINE)
pg = re.search(r'^  minimumXcodeGenVersion: "([^"]+)"$', project, flags=re.MULTILINE)
if not px or px.group(1) != xcode:
    raise SystemExit("project.yml xcodeVersion does not match workflow pin")
if not pg or pg.group(1) != xcodegen:
    raise SystemExit("project.yml minimumXcodeGenVersion does not match workflow pin")
if f'/Applications/Xcode_${{XCODE_VERSION}}.app' not in workflow:
    raise SystemExit("workflow does not select Xcode from the pinned XCODE_VERSION")
if 'test "$ACTUAL_XCODE_VERSION" = "$XCODE_VERSION"' not in workflow or 'test "$ACTUAL_XCODE_BUILD" = "$XCODE_BUILD"' not in workflow:
    raise SystemExit("workflow does not verify actual Xcode version/build")
if 'test "$ACTUAL_SDK" = "$IPHONEOS_SDK_VERSION"' not in workflow:
    raise SystemExit("workflow does not verify actual iPhoneOS SDK")
uses = re.findall(r"^\s*uses:\s*([^\s#]+)", workflow, flags=re.MULTILINE)
if not uses:
    raise SystemExit("workflow contains no actions to audit")
for ref in uses:
    if ref.startswith("./"):
        continue
    if not re.fullmatch(r"[^@]+@[0-9a-fA-F]{40}", ref):
        raise SystemExit(f"GitHub Action is not pinned to a full commit SHA: {ref}")
PY

grep -q 'FORBIDDEN_PATH' scripts/verify_ipa.sh || fail "IPA test/fixture/VCS contamination scan missing"
grep -q 'duplicate ZIP entry' scripts/verify_ipa.sh || fail "IPA duplicate ZIP-entry defense missing"
grep -q 'symlink ZIP entry is not allowed' scripts/verify_ipa.sh || fail "IPA pre-extraction symlink defense missing"
grep -q 'unsafe ZIP path segments' scripts/verify_ipa.sh || fail "IPA path traversal defense missing"
grep -q 'Executable structure audit: PASS' scripts/verify_ipa.sh || fail "IPA extra executable/framework audit missing"
grep -q 'Signature=adhoc' scripts/verify_ipa.sh || fail "IPA ad-hoc signature verification missing"
grep -q 'unexpected entitlements in TrollStore build' scripts/verify_ipa.sh || fail "IPA entitlement audit missing"
grep -q 'SECRET_PATTERN' scripts/verify_ipa.sh || fail "IPA secret scan missing"
grep -q 'DEV_URL_PATTERN' scripts/verify_ipa.sh || fail "IPA development URL scan missing"
grep -q 'Mach-O minimum iOS is not 15.0' scripts/verify_ipa.sh || fail "Mach-O deployment target verification missing"

SECRET_PATTERN='(-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|A(KIA|SIA)[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{32,}|AIza[0-9A-Za-z_-]{35}|(CLOUDFLARE_API_TOKEN|CF_API_TOKEN|GITHUB_TOKEN|PROVIDER_API_KEY|PAIRING_SECRET)[[:space:]]*[:=][[:space:]]*["'"'][^"'"']{8,}["'"'])'
TMP_MATCHES="$(mktemp)"
trap 'rm -f "$TMP_MATCHES"' EXIT

if git grep -Il -E "$SECRET_PATTERN" -- . ':(exclude)scripts/security_audit.sh' >"$TMP_MATCHES"; then
  echo "Potential secret-bearing tracked files:" >&2
  cat "$TMP_MATCHES" >&2
  fail "tracked-source secret scan found a high-confidence pattern"
fi

while IFS= read -r rev; do
  : >"$TMP_MATCHES"
  if git grep -Il -E "$SECRET_PATTERN" "$rev" -- . ':(exclude)scripts/security_audit.sh' >"$TMP_MATCHES"; then
    echo "Potential secret-bearing history paths at $rev:" >&2
    cat "$TMP_MATCHES" >&2
    fail "Git history secret scan found a high-confidence pattern"
  fi
done < <(git rev-list --all)

echo "Security audit PASS; protocol SHA256=$ACTUAL_CONTRACT_SHA"
