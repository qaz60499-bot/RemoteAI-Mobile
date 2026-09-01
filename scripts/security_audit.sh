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
EXPECTED_CONTRACT_SHA="4ad8eb5e7f58e5e0179489e0a0c9abdd6c9b9f19c307a603897532dee6869947"
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
if grep -nE '^  (actions|checks|contents|deployments|id-token|issues|packages|pull-requests|security-events|statuses): write$' .github/workflows/build-ipa.yml; then
  fail "workflow write permission detected"
fi
grep -q 'persist-credentials: false' .github/workflows/build-ipa.yml || fail "checkout must not persist GITHUB_TOKEN credentials"
grep -q 'fetch-depth: 0' .github/workflows/build-ipa.yml || fail "full Git history is required for secret scanning"
if grep -nE '^\s*uses:\s*[^#[:space:]]+@(v[0-9]+|main|master|latest)\s*$' .github/workflows/build-ipa.yml; then
  fail "mutable GitHub Action tag detected; pin actions to full commit SHA"
fi

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
