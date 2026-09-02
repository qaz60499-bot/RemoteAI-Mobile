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

    private actor ConnectionScenarioTransport: Transport {
        enum Mode: Equatable {
            case normal
            case connectOffline
            case statusTimeout
            case stalePairing
            case runtimesFailure
        }

        private let mode: Mode
        private var connected = false
        private var connectCalls = 0

        init(mode: Mode) { self.mode = mode }

        var isConnected: Bool { connected }
        func connect() async throws {
            connectCalls += 1
            if mode == .connectOffline { throw TransportError.offline }
            connected = true
        }
        func disconnect() async { connected = false }
        func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }
        func connectionCount() -> Int { connectCalls }
        func forceDisconnect() { connected = false }

        func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
            guard connected else { throw TransportError.offline }
            switch command.action {
            case "getStatus":
                if mode == .statusTimeout { throw TransportError.timeout }
                if mode == .stalePairing { throw TransportError.pairingRequired }
                return CommandResponseEnvelope(ok: true, result: .object([
                    "machineId": .string(command.machineId),
                    "latestSequence": .number(0),
                    "capabilities": .array([]),
                    "runtimes": .array([])
                ]), error: nil, idempotentReplay: false)
            case "getChangesAfterCursor":
                return CommandResponseEnvelope(ok: true, result: try JSONValue.encode(DeltaSyncResult(events: [], nextCursor: 0, hasMore: false)), error: nil, idempotentReplay: false)
            case "listRuntimes":
                if mode == .runtimesFailure { throw TransportError.remote("CATALOG_TEMPORARY", "catalog unavailable") }
                let now = Date()
                return CommandResponseEnvelope(ok: true, result: try JSONValue.encode([
                    ServerRuntime(runtimeId: "runtime.web", kind: RuntimeKind.web.rawValue, label: "Web", capabilities: [], status: "READY", updatedAt: now)
                ]), error: nil, idempotentReplay: false)
            default:
                throw TransportError.remote("UNSUPPORTED_ACTION", command.action)
            }
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
            case "getStatus":
                result = .object([
                    "machineId": .string(command.machineId),
                    "latestSequence": .number(0),
                    "capabilities": .array([]),
                    "runtimes": .array([])
                ])
            case "getChangesAfterCursor":
                result = try JSONValue.encode(DeltaSyncResult(events: [], nextCursor: 0, hasMore: false))
            case "listRuntimes":
                result = try JSONValue.encode([
                    ServerRuntime(runtimeId: "runtime.web", kind: RuntimeKind.web.rawValue, label: "Web", capabilities: [], status: "READY", updatedAt: now),
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

    func testMixedTypeWindowsQRCodeParsesAndIsComplete() throws {
        let payload = """
        {"relay":"https://remoteai-relay.qaz60499.workers.dev","machineId":"machine-60e5101d-d386-464b-ac41-3e546ca800a0","pairingCode":"53029504","protocolVersion":1}
        """
        let parsed = try XCTUnwrap(PairingScanPayload.parse(payload))
        XCTAssertEqual(parsed.relayBaseURL?.absoluteString, "https://remoteai-relay.qaz60499.workers.dev")
        XCTAssertEqual(parsed.machineId, "machine-60e5101d-d386-464b-ac41-3e546ca800a0")
        XCTAssertEqual(parsed.pairingCode, "53029504")
        XCTAssertTrue(parsed.isComplete)
    }

    func testPairingURLQRCodeAcceptsFrozenFields() throws {
        let payload = "remoteai://pair?relay=https%3A%2F%2Fremoteai-relay.qaz60499.workers.dev&machineId=machine-test-qr&code=12345678"
        let parsed = try XCTUnwrap(PairingScanPayload.parse(payload))
        XCTAssertEqual(parsed.relayBaseURL?.host, "remoteai-relay.qaz60499.workers.dev")
        XCTAssertEqual(parsed.machineId, "machine-test-qr")
        XCTAssertEqual(parsed.pairingCode, "12345678")
        XCTAssertTrue(parsed.isComplete)
    }

    func testConnectingStateHasFiniteMaximumDurationContract() {
        XCTAssertGreaterThan(WorkspaceStore.connectingStateMaxDuration, 0)
        XCTAssertLessThanOrEqual(WorkspaceStore.connectingStateMaxDuration, 45)
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

    func testConnectSuccessTransitionsToOnlineAfterAuthenticatedStatus() async throws {
        let machineId = "machine-connect-ok-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x31, count: 32))
        let store = WorkspaceStore(transport: ConnectionScenarioTransport(mode: .normal), cache: try SQLiteStore.inMemory())
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        await store.start()
        XCTAssertEqual(store.machine.state, .online)
        XCTAssertEqual(store.connectionPhase, .online)
        XCTAssertNil(store.errors["connection"])
        await store.suspend()
    }

    func testRelayReachableButWindowsOfflineEndsOfflineNotConnecting() async throws {
        let machineId = "machine-windows-offline-state-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x32, count: 32))
        let store = WorkspaceStore(transport: ConnectionScenarioTransport(mode: .connectOffline), cache: try SQLiteStore.inMemory())
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        await store.start()
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.connectionPhase, .windowsOffline)
        await store.suspend()
    }

    func testStalePairingBecomesExplicitRepairRequired() async throws {
        let machineId = "machine-stale-state-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x33, count: 32))
        let store = WorkspaceStore(transport: ConnectionScenarioTransport(mode: .stalePairing), cache: try SQLiteStore.inMemory())
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        await store.start()
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.connectionPhase, .pairingExpired)
        XCTAssertFalse(store.isPaired)
        XCTAssertTrue(store.errors["connection"]?.contains("Repair required") == true)
    }

    func testGetStatusTimeoutCannotLeaveConnecting() async throws {
        let machineId = "machine-status-timeout-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x34, count: 32))
        let store = WorkspaceStore(transport: ConnectionScenarioTransport(mode: .statusTimeout), cache: try SQLiteStore.inMemory())
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        await store.start()
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.connectionPhase, .timedOut)
        await store.suspend()
    }

    func testListRuntimesFailureKeepsMachineOnline() async throws {
        let machineId = "machine-metadata-degraded-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x35, count: 32))
        let store = WorkspaceStore(transport: ConnectionScenarioTransport(mode: .runtimesFailure), cache: try SQLiteStore.inMemory())
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        await store.start()
        XCTAssertEqual(store.machine.state, .online)
        XCTAssertEqual(store.connectionPhase, .online)
        XCTAssertNotNil(store.errors["sync"])
        await store.suspend()
    }

    func testForegroundReconnectReturnsOnline() async throws {
        let machineId = "machine-foreground-reconnect-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x36, count: 32))
        let transport = ConnectionScenarioTransport(mode: .normal)
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)
        await store.start()
        await store.suspend()
        await store.resumeFromForeground()
        XCTAssertEqual(store.machine.state, .online)
        XCTAssertEqual(store.connectionPhase, .online)
        let connectionCount = await transport.connectionCount()
        XCTAssertGreaterThanOrEqual(connectionCount, 2)
        await store.suspend()
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
        XCTAssertEqual(Set(store.runtimes.map(\.id)), Set(["runtime.web", "runtime.codex"]))
        XCTAssertFalse(store.runtimes.contains(where: { $0.id == "runtime.cloudcode" }))
        XCTAssertTrue(store.instances.isEmpty, "Pairing/reconnect should not eagerly scan every runtime instance")
        XCTAssertEqual(stages, [.connectingRemoteAI, .loadingRuntimes])
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
