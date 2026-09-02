import XCTest
@testable import RemoteAIMobile

@MainActor
final class PairingTests: XCTestCase {
    private final class ScriptedSocket: PairingWebSocket {
        var inbound: [Result<URLSessionWebSocketTask.Message, Error>]
        var outbound: [URLSessionWebSocketTask.Message] = []
        private(set) var resumed = false
        private(set) var cancelled = false

        init(_ inbound: [Result<URLSessionWebSocketTask.Message, Error>]) {
            self.inbound = inbound
        }

        func setMaximumMessageSize(_ bytes: Int) {}
        func resume() { resumed = true }
        func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancelled = true }

        func send(_ message: URLSessionWebSocketTask.Message, timeout: TimeInterval) async throws {
            guard timeout > 0 else { throw TransportError.timeout }
            outbound.append(message)
        }

        func receive(timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
            guard timeout > 0 else { throw TransportError.timeout }
            guard !inbound.isEmpty else { throw TransportError.timeout }
            return try inbound.removeFirst().get()
        }
    }

    private actor RuntimeLoadingTransport: Transport {
        private var connected = false
        var isConnected: Bool { connected }

        func connect() async throws { connected = true }
        func disconnect() async { connected = false }
        func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }

        func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
            guard connected else { throw TransportError.offline }
            let now = Date()
            let result: JSONValue
            switch command.action {
            case "getChangesAfterCursor":
                result = try JSONValue.encode(DeltaSyncResult(events: [], nextCursor: 0, hasMore: false))
            case "listRuntimes":
                result = try JSONValue.encode([
                    ServerRuntime(runtimeId: "runtime.web", kind: RuntimeKind.web.rawValue, label: "Web", capabilities: [], status: "READY", updatedAt: now),
                    ServerRuntime(runtimeId: "runtime.cloudcode", kind: RuntimeKind.cloudCode.rawValue, label: "Cloud Code", capabilities: [], status: "READY", updatedAt: now),
                    ServerRuntime(runtimeId: "runtime.codex", kind: RuntimeKind.codex.rawValue, label: "Codex", capabilities: [], status: "READY", updatedAt: now)
                ])
            case "listInstances":
                let runtimeId = command.runtimeId
                result = try JSONValue.encode([
                    ServerInstance(instanceId: "\(runtimeId).primary", runtimeId: runtimeId, label: runtimeId, kind: "test", config: [:], status: "READY", updatedAt: now)
                ])
            default:
                throw TransportError.remote("UNSUPPORTED_ACTION", command.action)
            }
            return CommandResponseEnvelope(ok: true, result: result, error: nil, idempotentReplay: false)
        }
    }

    private func frameMessage(_ frame: RelayFrame) throws -> URLSessionWebSocketTask.Message {
        .data(try JSONEncoder.remoteAI.encode(frame))
    }

    private func relayReady(machineId: String, deviceId: String, agentOnline: Bool = true) throws -> URLSessionWebSocketTask.Message {
        try frameMessage(RelayFrame(
            v: 1,
            kind: "ACK",
            machineId: machineId,
            deviceId: deviceId,
            messageId: UUID().uuidString,
            body: ["relay": .string("device-connected"), "agentOnline": .bool(agentOnline)]
        ))
    }

    private func machinePublicKey() throws -> String {
        try PayloadCrypto.publicKeySPKIBase64(privateKeyRaw: PayloadCrypto.generateDevicePrivateKey())
    }

    private func challenge(machineId: String, deviceId: String, machinePublicKeyB64: String) throws -> URLSessionWebSocketTask.Message {
        try frameMessage(RelayFrame(
            v: 1,
            kind: "PAIR_CHALLENGE",
            machineId: machineId,
            deviceId: deviceId,
            messageId: UUID().uuidString,
            body: [
                "challenge": .string("challenge-\(UUID().uuidString)"),
                "machinePublicKeyB64": .string(machinePublicKeyB64),
                "expiresInSeconds": .number(120)
            ]
        ))
    }

    private func accept(machineId: String, deviceId: String, machinePublicKeyB64: String) throws -> URLSessionWebSocketTask.Message {
        try frameMessage(RelayFrame(
            v: 1,
            kind: "PAIR_ACCEPT",
            machineId: machineId,
            deviceId: deviceId,
            messageId: UUID().uuidString,
            body: ["machinePublicKeyB64": .string(machinePublicKeyB64), "protocolVersion": .number(1)]
        ))
    }

    private func rejection(machineId: String, deviceId: String, message: String) throws -> URLSessionWebSocketTask.Message {
        try frameMessage(RelayFrame(
            v: 1,
            kind: "ACK",
            machineId: machineId,
            deviceId: deviceId,
            messageId: UUID().uuidString,
            body: ["error": .string("UNAUTHORIZED_DEVICE"), "message": .string(message)]
        ))
    }

    private func makeClient(socket: ScriptedSocket, totalTimeout: TimeInterval = 1) -> RelayPairingClient {
        RelayPairingClient(totalTimeout: totalTimeout) { _, protocols in
            XCTAssertEqual(protocols, ["remoteai.v1"])
            return socket
        }
    }

    private func assertStageError(_ error: Error, _ stage: PairingStage, file: StaticString = #filePath, line: UInt = #line) {
        guard let step = error as? PairingStepError else {
            return XCTFail("Expected PairingStepError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(step.stage, stage, file: file, line: line)
    }

    func testPairingRelayOfflineFailsInsteadOfHanging() async throws {
        let machineId = "machine-relay-offline-\(UUID().uuidString)"
        let socket = ScriptedSocket([.failure(TransportError.offline)])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected relay offline failure")
        } catch {
            assertStageError(error, .connectingRelay)
        }
        XCTAssertTrue(socket.cancelled)
    }

    func testPairingWindowsOfflineFailsAtRelayConnection() async throws {
        let machineId = "machine-windows-offline-\(UUID().uuidString)"
        let deviceId = try PairingKeyStore.deviceId()
        let socket = ScriptedSocket([.success(try relayReady(machineId: machineId, deviceId: deviceId, agentOnline: false))])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected Windows offline failure")
        } catch {
            assertStageError(error, .connectingRelay)
        }
    }

    func testWrongPairingCodeReturnsExplicitInvalidOrExpiredError() async throws {
        let machineId = "machine-wrong-code-\(UUID().uuidString)"
        let deviceId = try PairingKeyStore.deviceId()
        let key = try machinePublicKey()
        let socket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
            .success(try rejection(machineId: machineId, deviceId: deviceId, message: "Pairing proof rejected"))
        ])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "00000000")
            XCTFail("Expected rejected code")
        } catch {
            assertStageError(error, .waitingApproval)
            XCTAssertTrue(error.localizedDescription.contains("Invalid or expired pairing code"))
        }
    }

    func testExpiredPairingCodeReturnsExplicitError() async throws {
        let machineId = "machine-expired-code-\(UUID().uuidString)"
        let deviceId = try PairingKeyStore.deviceId()
        let key = try machinePublicKey()
        let socket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
            .success(try rejection(machineId: machineId, deviceId: deviceId, message: "Pairing challenge expired"))
        ])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected expired code")
        } catch {
            assertStageError(error, .waitingApproval)
            XCTAssertTrue(error.localizedDescription.contains("Invalid or expired pairing code"))
        }
    }

    func testMissingChallengeTimesOutAndReturnsControl() async throws {
        let machineId = "machine-no-challenge-\(UUID().uuidString)"
        let deviceId = try PairingKeyStore.deviceId()
        let socket = ScriptedSocket([.success(try relayReady(machineId: machineId, deviceId: deviceId)), .failure(TransportError.timeout)])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected timeout")
        } catch { assertStageError(error, .waitingChallenge) }
    }

    func testMissingAcceptTimesOutAndReturnsControl() async throws {
        let machineId = "machine-no-accept-\(UUID().uuidString)"
        let deviceId = try PairingKeyStore.deviceId()
        let key = try machinePublicKey()
        let socket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
            .failure(TransportError.timeout)
        ])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected timeout")
        } catch { assertStageError(error, .waitingApproval) }
    }

    func testWebSocketDisconnectDuringPairingReturnsControl() async throws {
        let machineId = "machine-disconnect-\(UUID().uuidString)"
        let deviceId = try PairingKeyStore.deviceId()
        let key = try machinePublicKey()
        let socket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
            .failure(TransportError.disconnected)
        ])
        do {
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected disconnect")
        } catch { assertStageError(error, .waitingApproval) }
    }

    func testPairingTimeoutCannotRemainPendingForever() async throws {
        let machineId = "machine-timeout-\(UUID().uuidString)"
        let socket = ScriptedSocket([.failure(TransportError.timeout)])
        let started = Date()
        do {
            _ = try await makeClient(socket: socket, totalTimeout: 0.2).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
            XCTFail("Expected timeout")
        } catch {
            assertStageError(error, .connectingRelay)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }

    func testStaleKeychainPairingIsReplacedBySuccessfulRepair() async throws {
        let machineId = "machine-stale-key-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        let stale = Data(repeating: 0xA5, count: 32)
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: stale)
        let deviceId = try PairingKeyStore.deviceId()
        let key = try machinePublicKey()
        let socket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
            .success(try accept(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key))
        ])
        _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
        XCTAssertNotEqual(PairingKeyStore.sharedKey(machineId: machineId), stale)
    }

    func testRepairSameMachineRotatesSharedKeyWithoutHanging() async throws {
        let machineId = "machine-repair-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        let deviceId = try PairingKeyStore.deviceId()
        let firstKey = try machinePublicKey()
        let firstSocket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: firstKey)),
            .success(try accept(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: firstKey))
        ])
        _ = try await makeClient(socket: firstSocket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
        let firstShared = try XCTUnwrap(PairingKeyStore.sharedKey(machineId: machineId))

        let secondKey = try machinePublicKey()
        let secondSocket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: secondKey)),
            .success(try accept(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: secondKey))
        ])
        _ = try await makeClient(socket: secondSocket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
        let secondShared = try XCTUnwrap(PairingKeyStore.sharedKey(machineId: machineId))
        XCTAssertNotEqual(firstShared, secondShared)
    }

    func testSwitchingMachineIdKeepsPairingMaterialStrictlyMachineScoped() async throws {
        let machineA = "machine-switch-a-\(UUID().uuidString)"
        let machineB = "machine-switch-b-\(UUID().uuidString)"
        defer {
            PairingKeyStore.deletePairing(machineId: machineA)
            PairingKeyStore.deletePairing(machineId: machineB)
        }
        let deviceId = try PairingKeyStore.deviceId()
        for machineId in [machineA, machineB] {
            let key = try machinePublicKey()
            let socket = ScriptedSocket([
                .success(try relayReady(machineId: machineId, deviceId: deviceId)),
                .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
                .success(try accept(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key))
            ])
            _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678")
        }
        let keyA = try XCTUnwrap(PairingKeyStore.sharedKey(machineId: machineA))
        let keyB = try XCTUnwrap(PairingKeyStore.sharedKey(machineId: machineB))
        XCTAssertNotEqual(keyA, keyB)
    }

    func testLiveRelayChallengeFromIOSURLSession() async throws {
#if REMOTEAI_LIVE_PAIRING
        let relayURL = try XCTUnwrap(URL(string: "https://remoteai-relay.qaz60499.workers.dev"))
        let machineId = "machine-60e5101d-d386-464b-ac41-3e546ca800a0"
#else
        let relayURL = URL(string: "https://relay.example.invalid")!
        let machineId = "live-pairing-disabled"
        throw XCTSkip("Live Relay pairing smoke is enabled only by the dedicated GitHub workflow step")
#endif

        let deviceId = "ios-ci-\(UUID().uuidString.lowercased())"
        let socketURL = try RemoteAIConfig.deviceWebSocketURL(baseURL: relayURL, machineId: machineId, deviceId: deviceId)
        let task = URLSession.shared.webSocketTask(with: socketURL, protocols: ["remoteai.v1"])
        task.maximumMessageSize = ProtocolSecurity.maxInboundFrameBytes
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        var relayReady = false
        for _ in 0..<4 {
            let message = try await WebSocketIO.receive(from: task, timeout: 8, timeoutReason: "ci-relay-connect-timeout")
            let frame = try ProtocolSecurity.decodeRelayFrame(WebSocketIO.data(from: message))
            try ProtocolSecurity.validate(frame, expectedMachineId: machineId)
            if frame.kind == "ACK", frame.body["relay"]?.stringValue == "device-connected" {
                XCTAssertEqual(frame.deviceId, deviceId)
                XCTAssertEqual(frame.body["agentOnline"]?.boolValue, true, "Windows Agent must be online for the live iOS pairing smoke")
                relayReady = true
                break
            }
        }
        XCTAssertTrue(relayReady, "iOS URLSessionWebSocketTask did not receive the Relay device-connected ACK")

        let privateKey = PayloadCrypto.generateDevicePrivateKey()
        let request = RelayFrame(
            v: 1,
            kind: "PAIR_REQUEST",
            machineId: machineId,
            deviceId: deviceId,
            messageId: UUID().uuidString,
            body: [
                "devicePublicKeyB64": .string(try PayloadCrypto.publicKeySPKIBase64(privateKeyRaw: privateKey)),
                "label": .string("GitHub iOS URLSession live smoke")
            ]
        )
        let requestData = try JSONEncoder.remoteAI.encode(request)
        try await WebSocketIO.send(.data(requestData), on: task, timeout: 5, timeoutReason: "ci-pair-request-timeout")

        var challengeReceived = false
        for _ in 0..<6 {
            let message = try await WebSocketIO.receive(from: task, timeout: 8, timeoutReason: "ci-pair-challenge-timeout")
            let frame = try ProtocolSecurity.decodeRelayFrame(WebSocketIO.data(from: message))
            try ProtocolSecurity.validate(frame, expectedMachineId: machineId)
            guard frame.deviceId == deviceId else { continue }
            if frame.kind == "PAIR_CHALLENGE" {
                XCTAssertNotNil(frame.body["challenge"]?.stringValue)
                XCTAssertNoThrow(try ProtocolSecurity.validatedPairingMachineKey(
                    challengeKey: frame.body["machinePublicKeyB64"]?.stringValue ?? "",
                    acceptedKey: nil
                ))
                challengeReceived = true
                break
            }
            if frame.kind == "ACK", let error = frame.body["error"]?.stringValue {
                XCTFail("Windows rejected the live PAIR_REQUEST: \(error) \(frame.body["message"]?.stringValue ?? "")")
                break
            }
        }
        XCTAssertTrue(challengeReceived, "Real Windows Agent did not return PAIR_CHALLENGE to the iOS URLSession client")
        if challengeReceived {
            print("LIVE_PAIRING_OK deviceId=\(deviceId)")
        }
    }

    func testSuccessfulPairingLoadsRuntimeCatalogAndDefersInstanceDiscovery() async throws {
        let machineId = "machine-load-runtimes-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x33, count: 32))
        let cache = try SQLiteStore.inMemory()
        let transport = RuntimeLoadingTransport()
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        var stages: [PairingStage] = []

        await store.start { stages.append($0) }

        XCTAssertEqual(store.machine.state, .online)
        XCTAssertEqual(Set(store.runtimes.map(\.id)), Set(["runtime.web", "runtime.cloudcode", "runtime.codex"]))
        XCTAssertTrue(store.instances.isEmpty, "Pairing/reconnect should not eagerly scan every runtime instance")
        XCTAssertEqual(stages, [.connectingRemoteAI, .loadingRuntimes])

        let cloudRuntime = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.cloudcode" }))
        await store.refreshRuntime(cloudRuntime)
        XCTAssertEqual(store.instances.map(\.runtimeId), ["runtime.cloudcode"])
        XCTAssertEqual(store.instances.map(\.id), ["runtime.cloudcode.primary"])
        await store.suspend()
    }

    func testSuccessfulPairingReportsAllStagesThroughSecureKeySaved() async throws {
        let machineId = "machine-success-stages-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        let deviceId = try PairingKeyStore.deviceId()
        let key = try machinePublicKey()
        let socket = ScriptedSocket([
            .success(try relayReady(machineId: machineId, deviceId: deviceId)),
            .success(try challenge(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key)),
            .success(try accept(machineId: machineId, deviceId: deviceId, machinePublicKeyB64: key))
        ])
        var stages: [PairingStage] = []
        _ = try await makeClient(socket: socket).pair(baseURL: URL(string: "https://relay.example.com")!, machineId: machineId, pairingCode: "12345678") { stages.append($0) }
        XCTAssertEqual(stages, [.preparing, .connectingRelay, .relayConnected, .sendingRequest, .waitingChallenge, .challengeReceived, .verifyingWindowsKey, .sendingProof, .waitingApproval, .secureKeySaved])
        XCTAssertEqual(socket.outbound.count, 2)
    }
}
