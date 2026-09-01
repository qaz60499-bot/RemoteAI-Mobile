# RemoteAI Mobile

Native iPhone control-plane client for **Remote AI Workspace**. The iPhone never becomes the execution plane: ChatGPT Web, Cloud Code, Codex, browser automation and tool execution stay on the paired Windows machine.

Hierarchy: **Machine → Runtime → Instance → Session / Conversation → Message**.

## P0 implemented

- Machine home with Online / Offline / Connecting state.
- Web, Cloud Code and Codex runtimes.
- Cached Instance and Session lists render before network refresh.
- Chat UI with user/assistant bubbles, tool/event cards, streaming text, error/retry, stop generation, older-message loading and scroll preservation.
- 50-message initial window and 40-message backwards pagination over a `LazyVStack`; MockTransport carries 1200 messages for stress coverage.
- SQLite WAL cache for metadata, recent messages, sync cursor, drafts and UI-state keys.
- HTTPS + WSS `CloudflareTransport` and complete `MockTransport`.
- UUID `commandId` idempotency contract and command lifecycle states.
- Persisted `lastSequence`, duplicate/out-of-order filtering, gap recovery and foreground reconnect + delta sync.
- Pairing by code or QR UI. Pairing secret is Keychain-only.
- CryptoKit AES-GCM payload encryption abstraction.
- Cloud Code uses `credentialProfileId`; provider credentials are never stored on iOS.
- iOS 15 minimum target; no App Store or Apple Developer signing dependency.
- GitHub macOS runner builds a real `iphoneos` arm64 app, ad-hoc signs it, packages `Payload/RemoteAI.app`, verifies it and uploads a TrollStore IPA artifact plus SHA256.

## Local development on macOS

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open RemoteAIMobile.xcodeproj
```

The checked-in source of truth is `project.yml`; the generated `.xcodeproj` is intentionally ignored to avoid Xcode project merge noise.

Until a real Windows device is paired, the app automatically uses `MockTransport`. UI tests force mock mode with `-UITestMockMode 1`.

## Windows / Cloudflare integration

The protocol is documented in:

- `contracts/protocol-v1.json`
- `docs/protocol-v1.md`

Production relay endpoints are configured from the **Pair Device** screen. Expected paths are `POST /v1/pair`, `POST /v1/command`, `GET /v1/sync`, message pagination endpoints, and `WSS /v1/ws`.

The Windows Agent must preserve command idempotency by `commandId` and event ordering by `sequence`. If its separately-developed `contracts/protocol-v1.json` changes compatibly, update this client contract and fixtures together.

## CI / IPA

`.github/workflows/build-ipa.yml` runs on push to `main` and `workflow_dispatch`:

1. checkout
2. select a non-beta Xcode
3. install XcodeGen and generate the project
4. create/boot an iPhone 13 Pro simulator
5. run unit + UI tests
6. build Release with `-sdk iphoneos`, `ARCHS=arm64`, signing disabled
7. verify Mach-O platform is iOS device and architecture includes arm64
8. ad-hoc sign with system `codesign` (no developer certificate)
9. package `Payload/RemoteAI.app`
10. unzip-test and validate bundle ID / Info.plist / executable / size
11. calculate SHA256
12. upload `RemoteAI-TrollStore-IPA`

No API keys, Cloudflare secrets, Apple credentials, cookies, browser sessions or pairing secrets belong in this repository.
