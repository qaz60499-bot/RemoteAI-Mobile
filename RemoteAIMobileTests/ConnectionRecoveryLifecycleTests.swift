import XCTest
@testable import RemoteAIMobile

@MainActor
final class ConnectionRecoveryLifecycleTests: XCTestCase {
    func testRelayLivenessDoesNotRecoverAgentAndFreshPresenceHandshakeRunsStatusAndDeltaOnce() async throws {
        let machineId = "machine-presence-refresh-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x5A, count: 32))
        let transport = AgentPresenceTransport(machineId: machineId, initiallyOnline: false)
        let cache = try SQLiteStore.inMemory()
        try await cache.setLastSequence(36)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)

        let initiallyAuthenticated = await store.start()
        XCTAssertFalse(initiallyAuthenticated)
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.connectionFailureEpisode?.code, "offline")
        let initialStatusCalls = await transport.statusCallCount()
        XCTAssertEqual(initialStatusCalls, 1)

        // A healthy phone-to-Relay socket says nothing about Windows Agent presence.
        await transport.injectHealth(TransportHealthEvent(channel: .relay, state: .online, at: Date(), detail: nil))
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.connectionFailureEpisode?.code, "offline")
        let statusCallsAfterRelayHealth = await transport.statusCallCount()
        XCTAssertEqual(statusCallsAfterRelayHealth, 1,
            "Relay liveness alone must not issue another getStatus or mark the PC recovered.")

        // Model an agent-online presence frame lost on the retained socket. The fresh
        // bounded handshake observes the real Agent state and resumes authentication.
        await transport.setAgentOnlineWithoutHealthEvent(true)
        let recovered = await waitForAuthenticatedDeltaRecovery(store, transport: transport, timeout: 8)
        XCTAssertTrue(recovered)
        let presenceRefreshes = await transport.presenceRefreshCount()
        let authenticatedStatusCalls = await transport.statusCallCount()
        let deltaCalls = await transport.deltaCallCount()
        XCTAssertEqual(presenceRefreshes, 1)
        XCTAssertEqual(authenticatedStatusCalls, 2,
            "One authenticated getStatus follows the new presence handshake.")
        XCTAssertEqual(deltaCalls, 1,
            "The authenticated recovery performs exactly one durable delta reconciliation.")
        XCTAssertEqual(store.machine.state, .online)
        XCTAssertEqual(store.connectionPhase, .online)
        XCTAssertNil(store.connectionFailureEpisode)
        XCTAssertNil(store.errors["connection"])
        await store.suspend()
    }

    func testPersistentAgentOfflineUsesOneBoundedRefreshWithoutStatusStorm() async throws {
        let machineId = "machine-persistent-offline-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x5B, count: 32))
        let transport = AgentPresenceTransport(machineId: machineId, initiallyOnline: false)
        let cache = try SQLiteStore.inMemory()
        try await cache.setLastSequence(36)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)

        let authenticated = await store.start()
        XCTAssertFalse(authenticated)
        let refreshStarted = await waitForPresenceRefreshCount(1, from: transport, timeout: 8)
        XCTAssertTrue(refreshStarted)
        try await Task.sleep(nanoseconds: 800_000_000)

        let refreshCount = await transport.presenceRefreshCount()
        let statusCount = await transport.statusCallCount()
        XCTAssertEqual(refreshCount, 1,
            "Confirmed offline presence is refreshed at most once before the next backoff interval.")
        XCTAssertEqual(statusCount, 1,
            "A still-offline Agent must not receive a 500 ms getStatus storm.")
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.connectionFailureEpisode?.code, "offline")
        XCTAssertTrue(store.errors["connection"]?.contains("offline") == true)
        await store.suspend()
    }

    func testAgentOnlineHealthEventResetsOfflineEpisodeAndSyncsOnce() async throws {
        let machineId = "machine-agent-online-event-\(UUID().uuidString)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: Data(repeating: 0x5C, count: 32))
        let transport = AgentPresenceTransport(machineId: machineId, initiallyOnline: false)
        let cache = try SQLiteStore.inMemory()
        try await cache.setLastSequence(36)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: machineId, name: "My PC", state: .connecting)

        let initiallyAuthenticated = await store.start()
        XCTAssertFalse(initiallyAuthenticated)
        await transport.setAgentOnlineWithoutHealthEvent(true)
        await transport.injectHealth(TransportHealthEvent(channel: .agent, state: .online, at: Date(), detail: nil))

        let recovered = await waitForAuthenticatedDeltaRecovery(store, transport: transport, timeout: 2)
        XCTAssertTrue(recovered)
        let statusCalls = await transport.statusCallCount()
        let deltaCalls = await transport.deltaCallCount()
        let presenceRefreshes = await transport.presenceRefreshCount()
        XCTAssertEqual(statusCalls, 2)
        XCTAssertEqual(deltaCalls, 1)
        XCTAssertEqual(presenceRefreshes, 0,
            "An online health frame should cancel the need for a fresh-presence socket refresh.")
        XCTAssertNil(store.connectionFailureEpisode)
        XCTAssertEqual(store.machine.state, .online)
        await store.suspend()
    }

    private func waitForAuthenticatedDeltaRecovery(
        _ store: WorkspaceStore,
        transport: AgentPresenceTransport,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let statusCalls = await transport.statusCallCount()
            let deltaCalls = await transport.deltaCallCount()
            if store.machine.state == .online,
               store.connectionPhase == .online,
               statusCalls >= 2,
               deltaCalls >= 1 { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let statusCalls = await transport.statusCallCount()
        let deltaCalls = await transport.deltaCallCount()
        return store.machine.state == .online
            && store.connectionPhase == .online
            && statusCalls >= 2
            && deltaCalls >= 1
    }

    private func waitForPresenceRefreshCount(
        _ expected: Int,
        from transport: AgentPresenceTransport,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await transport.presenceRefreshCount() >= expected { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await transport.presenceRefreshCount() >= expected
    }
}

private actor AgentPresenceTransport: Transport {
    private let machineId: String
    private var connected = false
    private var agentOnline: Bool
    private var statusCalls = 0
    private var deltaCalls = 0
    private var presenceRefreshes = 0
    private let healthPipe = AsyncStream<TransportHealthEvent>.makeStream()

    init(machineId: String, initiallyOnline: Bool) {
        self.machineId = machineId
        self.agentOnline = initiallyOnline
    }

    var isConnected: Bool { connected }

    func connect() async throws {
        connected = true
        healthPipe.continuation.yield(TransportHealthEvent(channel: .relay, state: .online, at: Date(), detail: nil))
        healthPipe.continuation.yield(TransportHealthEvent(
            channel: .agent,
            state: agentOnline ? .online : .offline,
            at: Date(),
            detail: agentOnline ? nil : "test Agent offline"
        ))
    }

    func disconnect() async { connected = false }

    func refreshAgentPresence() async throws -> Bool {
        presenceRefreshes += 1
        await disconnect()
        try await connect()
        return true
    }

    func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }
    func healthStream() async -> AsyncStream<TransportHealthEvent> { healthPipe.stream }

    func injectHealth(_ event: TransportHealthEvent) {
        healthPipe.continuation.yield(event)
    }

    func setAgentOnlineWithoutHealthEvent(_ online: Bool) { agentOnline = online }
    func statusCallCount() -> Int { statusCalls }
    func deltaCallCount() -> Int { deltaCalls }
    func presenceRefreshCount() -> Int { presenceRefreshes }

    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        guard connected else { throw TransportError.disconnected }
        guard command.machineId == machineId else { throw TransportError.malformedData }
        switch command.action {
        case "getStatus":
            statusCalls += 1
            guard agentOnline else { throw TransportError.offline }
            return CommandResponseEnvelope(ok: true, result: .object([
                "machineId": .string(machineId),
                "latestSequence": .number(37),
                "browser": .object(["connected": .bool(true)]),
                "relay": .object(["online": .bool(true)]),
                "capabilities": .array([]),
                "runtimes": .array([]),
            ]), error: nil, idempotentReplay: false)
        case "getChangesAfterCursor":
            deltaCalls += 1
            let cursor = command.payload["cursor"]?.intValue ?? 0
            let result = DeltaSyncResult(events: [], nextCursor: max(37, cursor), hasMore: false)
            return CommandResponseEnvelope(ok: true, result: try JSONValue.encode(result), error: nil, idempotentReplay: false)
        case "listRuntimes":
            return CommandResponseEnvelope(ok: true, result: .array([]), error: nil, idempotentReplay: false)
        case "listOpenWebTabs":
            return CommandResponseEnvelope(ok: true, result: .array([]), error: nil, idempotentReplay: false)
        default:
            throw TransportError.remote("UNSUPPORTED_ACTION", command.action)
        }
    }
}
