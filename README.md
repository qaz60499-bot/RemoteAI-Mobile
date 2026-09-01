# RemoteAI Mobile

Native iPhone control-plane client for **Remote AI Workspace**. Windows remains the execution plane for ChatGPT Web, Cloud Code, Codex, browser adapters and tools; the phone provides a mobile workspace and chat UI rather than remote desktop, SSH or terminal mirroring.

Hierarchy is fixed:

**Machine → Runtime → Instance → Session / Conversation → Message**

## P0 implemented

- Machine home with Online / Offline / Connecting state.
- Web, Cloud Code and Codex runtimes using the frozen Windows IDs `runtime.web`, `runtime.cloudcode`, and `runtime.codex`.
- Cached Runtime / Instance / Session metadata renders before remote refresh.
- Chat UI with user/assistant bubbles, Tool/Event cards, streaming text, command state, Retry, Stop Generation, older-message loading and scroll preservation.
- iPhone-safe layout: native safe areas plus extra top breathing room; composer follows the keyboard and primary touch targets are at least 44×44 pt.
- Recent 50-message window plus 40-message upward pagination over `LazyVStack`.
- SQLite WAL cache for metadata, recent messages, sync cursor, drafts and UI state. Remote and cached history share the same `(createdAt, messageId)` pagination semantics.
- Persisted event sequence cursor with duplicate filtering, gap recovery, reconnect and delta sync.
- Stable command UUID idempotency. Unknown delivery keeps the original command ID for explicit Retry rather than silently executing twice.
- Pairing by QR/manual code using X25519, HMAC-SHA256 proof and HKDF-SHA256.
- Device private/shared key material stored in iOS Keychain with `WhenUnlockedThisDeviceOnly` accessibility.
- End-to-end AES-256-GCM command/response/event payloads with authenticated AAD. Cloudflare routes encrypted relay frames and does not receive the payload key.
- Cloud Code accepts `credentialProfileId`; provider API keys stay on Windows.
- `MockTransport` covers normal, 1200-message history, streaming, tool event, offline, command failure, disconnect/reconnect, duplicate event and sequence-gap behavior.
- iOS 15 minimum target; no Apple Developer certificate, provisioning profile, App Store Connect or notarization requirement.
- GitHub macOS runner builds a real `iphoneos` arm64 app, applies ad-hoc signing, validates the Mach-O/device platform and packages a TrollStore-targeted IPA plus SHA256.

## Frozen Windows protocol v1

The machine-readable source of truth is:

- `contracts/protocol-v1.json`
- `docs/protocol-v1.md`

It is synchronized with the Windows Agent protocol contract.

Production device connection:

```text
wss://<relay>/connect?machineId=<machineId>&role=device&deviceId=<stable-device-id>
Sec-WebSocket-Protocol: remoteai.v1
```

The Relay base URL is configured from **Pair Device** and must use HTTPS. The app rejects plain HTTP relay configuration.

Pairing flow:

```text
PAIR_REQUEST
→ PAIR_CHALLENGE
→ PAIR_PROOF
→ PAIR_ACCEPT
→ X25519 + HKDF shared key
→ ENCRYPTED AES-256-GCM frames
```

Runtime IDs:

- `runtime.web`
- `runtime.cloudcode`
- `runtime.codex`

Every command contains numeric `protocolVersion: 1` and a stable `commandId`. Every event contains a monotonically increasing `sequence` used for delta recovery.

## Cache-first behavior

App startup does not wait for Windows discovery:

1. Open local SQLite metadata and recent history.
2. Render the cached workspace immediately.
3. Connect or reconnect WSS in the foreground.
4. Call `getChangesAfterCursor(lastSequence)`.
5. Refresh Runtime / Instance / Session metadata.

When the PC is offline, cached Runtime / Instance / Session and message history remain readable. Sending a message while offline saves a draft; high-risk commands are not silently queued.

## Local development on macOS

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open RemoteAIMobile.xcodeproj
```

`project.yml` is the checked-in source of truth; the generated `.xcodeproj` is ignored.

Until a real Windows machine is paired, the app can run with `MockTransport`. UI tests force mock mode using `-UITestMockMode 1`.

## CI / TrollStore IPA

`.github/workflows/build-ipa.yml` runs on push to `main` and `workflow_dispatch`:

1. checkout
2. security/config audit and protocol JSON validation
3. select a stable non-beta Xcode
4. install XcodeGen and generate the project
5. create an iPhone 13 Pro simulator
6. run unit + UI tests
7. build Release using `-sdk iphoneos`, `ARCHS=arm64`, with Apple Developer signing disabled
8. verify `.app`, Info.plist, bundle ID, iOS device Mach-O platform and arm64 architecture
9. ad-hoc sign using system `codesign`
10. package `Payload/RemoteAI.app`
11. unzip-test the IPA and reject suspiciously small/fake artifacts
12. calculate SHA256
13. upload the `RemoteAI-TrollStore-IPA` artifact

No API keys, Cloudflare secrets, Apple credentials, account cookies, browser sessions, pairing codes, device private keys or derived pairing secrets belong in this repository.

## Windows integration still requiring a live-device check

The client and Windows Agent now share the same protocol and cross-platform crypto test vectors. A final physical integration check still requires a deployed Cloudflare Relay plus the running Windows Agent and an actual paired iPhone to verify the end-to-end network path, real ChatGPT Web registration, real Cloud Code provider sessions and real Codex sessions. Mock/CI coverage does not pretend those external runtimes were exercised when they were not.
