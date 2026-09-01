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

Windows displays a machine ID and an 8-digit rotating pairing code. iOS creates an X25519 private key locally and stores private/shared key material in `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` Keychain items.

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

The pairing code and private/shared keys are never written to UserDefaults, SQLite, source, or GitHub.

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

SQLite is WAL-mode and uses bound SQL parameters. The application cache directory/database are marked with iOS data protection (`completeUntilFirstUserAuthentication`). Pairing secrets are not stored in SQLite.

## Windows integration source of truth

The Windows Agent's frozen integration document is `docs/IOS-INTEGRATION.md` in the Windows project. When it changes compatibly, update this client contract, interoperability vectors, and MockTransport in the same change.
