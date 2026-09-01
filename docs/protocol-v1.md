# RemoteAI Protocol v1 — iOS Client Contract

This client follows the frozen Windows contract in `contracts/protocol-v1.json`. The file is byte-for-byte synchronized with the Windows Agent contract.

Hierarchy is fixed:

**Machine → Runtime → Instance → Session / Conversation → Message / Event**

Runtime IDs:

- `runtime.web`
- `runtime.cloudcode`
- `runtime.codex`

## Relay

The iPhone never connects directly to Windows.

```text
iPhone
  -> HTTPS / WSS
Cloudflare Worker + per-Machine Durable Object
  -> WSS
RemoteAI-Agent.exe
```

The configured base endpoint must be HTTPS. Device WebSocket:

```text
wss://<relay>/connect?machineId=<machineId>&role=device&deviceId=<stable-device-id>
Sec-WebSocket-Protocol: remoteai.v1
```

Production code rejects plain `http://` relay configuration.

## Pairing

Windows displays a machine ID and an 8-digit rotating pairing code. iOS creates an ephemeral X25519 private key locally. After `PAIR_ACCEPT`, only the stable device ID and derived 32-byte shared key are persisted in `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` Keychain items; the X25519 private key is discarded after derivation.

Pair flow:

1. iOS sends `PAIR_REQUEST` with its X25519 DER-SPKI public key.
2. Windows returns `PAIR_CHALLENGE` with a random challenge and machine public key.
3. iOS sends `PAIR_PROOF`:

```text
HMAC-SHA256(
  key = UTF8(pairingCode),
  data = challenge + "|" + machineId + "|" + deviceId + "|" + devicePublicKeyB64
)
```

4. After `PAIR_ACCEPT`, both endpoints derive the same 32-byte key:

```text
IKM  = X25519(devicePrivateKey, machinePublicKey)
salt = UTF8("RemoteAI:" + machineId)
info = UTF8("device:" + deviceId + ":protocol-v1")
KDF  = HKDF-SHA256
```

The pairing code, ephemeral private key, and derived shared key are never written to UserDefaults, SQLite, source, or GitHub. Legacy protocol-v1 private-key Keychain entries are deleted during successful pairing migration. When the app pairs to a different machine, the previous machine's pairing key and cached SQLite data are deleted before the new workspace is loaded.

## End-to-end encryption

Commands, command responses, and events use AES-256-GCM before entering Cloudflare. Cloudflare only routes the encrypted relay frame and does not need the payload key.

AAD:

```text
machineId + "|" + deviceId + "|" + messageId + "|v1"
```

Encrypted frame:

```json
{
  "v": 1,
  "kind": "ENCRYPTED",
  "machineId": "...",
  "deviceId": "...",
  "messageId": "...",
  "body": {
    "alg": "A256GCM",
    "nonce": "<base64url>",
    "ciphertext": "<base64url>",
    "tag": "<base64url>"
  }
}
```

Outbound frames are capped at 256 KiB and inbound frames at 512 KiB, matching the Windows Relay boundaries.

### iOS protocol-security profile

The frozen JSON contract remains unchanged, but the iOS decoder applies a fail-closed security profile before `Codable` materialization:

- relay, command, and event top-level keys are checked explicitly so unknown fields are not silently ignored;
- relay kinds, command actions, and event types must be from the protocol-v1 allowlists;
- identifiers are bounded to 160 UTF-8 bytes and the ASCII set `A-Z a-z 0-9 . _ : -`;
- encrypted frame bodies must contain exactly `alg`, `nonce`, `ciphertext`, and `tag`;
- Base64URL input is unpadded URL-safe alphabet only;
- encrypted `messageId` values are tracked in a bounded replay window and authenticated before being admitted to that window;
- decrypted events are revalidated against the paired machine ID;
- delta batches must be strictly ordered, duplicate-free, cursor-consistent, and contiguous when recovering from a nonzero cursor.

Pairing additionally rejects a `PAIR_ACCEPT` machine public key that differs from the key supplied in the corresponding `PAIR_CHALLENGE`.

**Residual protocol-v1 limitation:** the HMAC pairing proof itself does not include the machine public key. Therefore an iOS-only change cannot cryptographically prove that the `PAIR_CHALLENGE` machine key was not substituted by a malicious relay during first pairing. The current HTTPS/WSS relay authentication prevents an ordinary network MITM, and the client now blocks late key substitution, but full protection against a compromised relay during initial pairing requires a coordinated Windows/Relay protocol revision that binds the machine public key into the pairing transcript.

## Command idempotency

`protocolVersion` is numeric `1`. Every command has a UUID `commandId`. If delivery becomes unknown after a socket drop, a retry reuses the same command ID. Windows persists command results and does not repeat side effects for an already completed ID.

Lifecycle shown by the app: `Pending → Executing → Completed|Failed|Unknown`.

## Event cursor / reconnect

Events have a strictly increasing machine-local `sequence`. iOS stores the highest fully applied sequence in SQLite.

- duplicate (`sequence <= lastSequence`): ignore;
- next sequence: apply;
- gap: call `getChangesAfterCursor`;
- foreground/reconnect: reopen WSS, run delta sync, then resume normal event handling.

Delta batches are applied in sequence order. The cursor is persisted only after local application, and repeated while `hasMore=true`.

## Message pagination

Recent history is fetched with `loadRecentMessages(limit=50)`; server maximum is 100.

Older messages use the oldest visible message cursor:

```json
{
  "before": {
    "createdAt": "<oldest-createdAt>",
    "messageId": "<oldest-messageId>"
  },
  "limit": 40
}
```

SQLite uses the same `(createdAt, messageId)` ordering, so cached and remote pagination have identical semantics.

## Supported actions

System: `getStatus`, `listRuntimes`, `listInstances`, `listSessions`.

Session: `createSession`, `resumeSession`, `stopSession`, `getSessionStatus`.

Chat: `sendMessage`, `stopGeneration`, `loadRecentMessages`, `loadMessagesBefore`.

Sync: `getChangesAfterCursor`.

Web: `registerCurrentPage`, `unregisterConversation`, `openConversation`, `focusConversation`, `createConversation`.

The mobile client never exposes arbitrary shell/PowerShell execution.

## Local cache

SQLite is WAL-mode and uses bound SQL parameters, `secure_delete=ON`, `trusted_schema=OFF`, bounded KV/message record sizes, and `PRAGMA quick_check` coverage. The application cache directory/database/WAL/SHM files are marked with iOS `NSFileProtectionComplete`. If protected Application Support storage cannot open, the app falls back to an in-memory SQLite cache rather than an unprotected temporary file. Pairing secrets are not stored in SQLite.

## Windows integration source of truth

The Windows Agent's frozen integration document is `docs/IOS-INTEGRATION.md` in the Windows project. When it changes compatibly, update this client contract, interoperability vectors, and MockTransport in the same change.
