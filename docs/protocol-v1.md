# RemoteAI Protocol v1

RemoteAI Mobile is a control-plane client. Windows remains the execution plane. The hierarchy is fixed as **Machine → Runtime → Instance → Session/Conversation → Message**.

## Transport

The production transport uses HTTPS for commands/history/delta sync and WSS for real-time events. `Transport` is abstracted so the same UI/store runs on `CloudflareTransport` or `MockTransport`. Future `LANDirectTransport` and `FallbackHTTPTransport` can conform without changing views.

## Command idempotency

Every command has a UUID `commandId`. A retry caused by reconnect must reuse the same ID. The relay/Windows Agent must persist or otherwise deduplicate IDs and return the prior lifecycle state rather than executing twice.

Lifecycle: `Pending → Acknowledged → Executing → Completed|Failed`; `Unknown` is used when the client cannot establish the final result.

## Event ordering and recovery

Each event has a monotonically increasing `sequence` for a machine stream. iOS persists `lastSequence` in SQLite.

- `sequence <= lastSequence`: duplicate, ignore.
- `sequence == lastSequence + 1`: apply normally.
- `sequence > lastSequence + 1`: gap, call `getChangesAfterCursor(lastSequence)`, sort, dedupe and apply recovered events.
- foreground after background: reconnect WSS, then delta sync before relying on real-time state.

## History

A session opens from the SQLite cache immediately, then refreshes the most recent 50 messages. Older history is loaded 40 messages at a time with `loadMessagesBefore(cursor)`. The UI uses `LazyVStack` and preserves the prior top anchor when older rows are inserted.

## Security

Pairing exchanges a one-time code for a trusted-device shared secret. The secret is stored only in Keychain. AES-GCM from CryptoKit is used for the optional encrypted command envelope. No provider API key is stored on iOS; Cloud Code accepts only `credentialProfileId`.

## Windows integration endpoints

The client expects these relay paths relative to the configured HTTPS relay base URL:

- `POST /v1/pair`
- `POST /v1/command`
- `GET /v1/sync?after=<sequence>`
- `GET /v1/messages/recent?sessionId=<id>&limit=<n>`
- `GET /v1/messages/before?sessionId=<id>&before=<sequence>&limit=<n>`
- `WSS /v1/ws`

The canonical machine-readable contract is `contracts/protocol-v1.json`.
