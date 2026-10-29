import XCTest
import Combine
@testable import RemoteAIMobile

private actor ControlledStopTransport: Transport {
    private let base: MockTransport
    private let holdStopResponses: Bool
    private var shouldTimeoutNextStop = false
    private var stopCommands: [RemoteCommand] = []
    private var stopResponseContinuations: [UUID: CheckedContinuation<CommandResponseEnvelope, Error>] = [:]

    init(base: MockTransport, holdStopResponses: Bool = true) {
        self.base = base
        self.holdStopResponses = holdStopResponses
    }

    var isConnected: Bool { get async { await base.isConnected } }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func eventStream() async -> AsyncStream<RemoteEvent> { await base.eventStream() }
    func healthStream() async -> AsyncStream<TransportHealthEvent> { await base.healthStream() }

    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        guard command.action == "stopGeneration" else { return try await base.execute(command) }
        try ProtocolSecurity.validate(command, expectedMachineId: "my-pc")
        stopCommands.append(command)
        if shouldTimeoutNextStop {
            shouldTimeoutNextStop = false
            throw TransportError.timeout
        }
        guard holdStopResponses else { return Self.successEnvelope }
        return try await withCheckedThrowingContinuation { continuation in
            stopResponseContinuations[command.commandId] = continuation
        }
    }

    func setSessionStatus(_ sessionId: String, status: String, lastActivityAt: Date? = nil, updatedAt: Date? = nil) async {
        await base.setSessionStatus(sessionId, status: status, lastActivityAt: lastActivityAt, updatedAt: updatedAt)
    }

    func emitLive(_ event: RemoteEvent) async {
        await base.injectEvent(event, deliverLive: true)
    }

    func failNextStopWithTimeout() { shouldTimeoutNextStop = true }

    func waitForStopCommandCount(_ count: Int) async -> [RemoteCommand] {
        // Broken test setup must fail rather than strand a CI runner indefinitely.
        for _ in 0..<100 {
            if stopCommands.count >= count { return stopCommands }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return stopCommands
    }

    func currentStopCommands() -> [RemoteCommand] { stopCommands }

    func releaseStopResponse(commandId: UUID) {
        stopResponseContinuations.removeValue(forKey: commandId)?.resume(returning: Self.successEnvelope)
    }

    private static let successEnvelope = CommandResponseEnvelope(
        ok: true,
        result: .object(["accepted": .bool(true)]),
        error: nil,
        idempotentReplay: nil
    )
}

final class StopIdentityTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // ControlledStopTransport wraps MockTransport but is not itself MockTransport.
        // WorkspaceStore therefore requires an explicit test pairing before start().
        try PairingKeyStore.savePairing(machineId: "my-pc", sharedKey: Data(repeating: 0x53, count: 32))
    }

    override func tearDownWithError() throws {
        PairingKeyStore.deletePairing(machineId: "my-pc")
        try super.tearDownWithError()
    }

    @MainActor
    func testLateStopAckCannotIdleNewGenerationAndStop2UsesNewCommandId() async throws {
        let base = MockTransport(historyCount: 0)
        let transport = ControlledStopTransport(base: base)
        await transport.setSessionStatus("photo-upload", status: "idle")
        let store = await makeStartedStore(transport: transport, cache: try SQLiteStore.inMemory())

        await transport.emitLive(generationEvent(sequence: 1201, type: "GENERATION_STARTED"))
        let firstRunBecameBusy = await waitForState(.busy, sessionId: "photo-upload", store: store)
        XCTAssertTrue(firstRunBecameBusy)

        let stop1Task = Task { @MainActor in
            await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        }
        let firstCommands = await transport.waitForStopCommandCount(1)
        let stop1 = try XCTUnwrap(firstCommands.first)

        await transport.emitLive(generationEvent(sequence: 1202, type: "GENERATION_STOPPED"))
        let firstRunBecameIdle = await waitForState(.idle, sessionId: "photo-upload", store: store)
        XCTAssertTrue(firstRunBecameIdle)
        await transport.setSessionStatus("photo-upload", status: "generating")
        await transport.emitLive(generationEvent(sequence: 1203, type: "GENERATION_STARTED"))
        let secondRunBecameBusy = await waitForState(.busy, sessionId: "photo-upload", store: store)
        XCTAssertTrue(secondRunBecameBusy)

        let stop2Task = Task { @MainActor in
            await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        }
        let bothCommands = await transport.waitForStopCommandCount(2)
        let stop2 = try XCTUnwrap(bothCommands.last)
        XCTAssertNotEqual(stop1.commandId, stop2.commandId)

        await transport.releaseStopResponse(commandId: stop1.commandId)
        let stop1Result = await stop1Task.value
        XCTAssertTrue(stop1Result)
        XCTAssertEqual(store.sessions.first(where: { $0.id == "photo-upload" })?.state, .busy, "The old Stop ACK must not idle the newer run")

        await transport.releaseStopResponse(commandId: stop2.commandId)
        let stop2Result = await stop2Task.value
        XCTAssertTrue(stop2Result)
        await store.suspend()
    }

    @MainActor
    func testRestartedStoreDoesNotReuseDurablePendingStopId() async throws {
        let cache = try SQLiteStore.inMemory()
        let firstTransport = ControlledStopTransport(base: MockTransport(historyCount: 0), holdStopResponses: false)
        await firstTransport.failNextStopWithTimeout()
        let firstStore = await makeStartedStore(transport: firstTransport, cache: cache)

        let firstStopResult = await firstStore.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        XCTAssertFalse(firstStopResult)
        let firstStopCommands = await firstTransport.currentStopCommands()
        let oldCommand = try XCTUnwrap(firstStopCommands.first)
        await firstStore.suspend()

        let secondTransport = ControlledStopTransport(base: MockTransport(historyCount: 0), holdStopResponses: false)
        await secondTransport.setSessionStatus("photo-upload", status: "generating")
        let secondStore = await makeStartedStore(transport: secondTransport, cache: cache)

        let secondStopResult = await secondStore.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        XCTAssertTrue(secondStopResult)
        let secondStopCommands = await secondTransport.currentStopCommands()
        let newCommand = try XCTUnwrap(secondStopCommands.first)
        XCTAssertNotEqual(oldCommand.commandId, newCommand.commandId, "A different store epoch must verify live status and use a fresh Stop identity")
        await secondStore.suspend()
    }

    @MainActor
    func testLegacyStringPendingStopIsNeverReplayed() async throws {
        let cache = try SQLiteStore.inMemory()
        let legacyId = UUID()
        let key = "pending.operation.my-pc.stop.runtime.web.photo.photo-upload"
        try await cache.put(legacyId.uuidString.lowercased(), key: key)

        let transport = ControlledStopTransport(base: MockTransport(historyCount: 0), holdStopResponses: false)
        await transport.setSessionStatus("photo-upload", status: "generating")
        let store = await makeStartedStore(transport: transport, cache: cache)

        let stopResult = await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        XCTAssertTrue(stopResult)
        let stopCommands = await transport.currentStopCommands()
        let command = try XCTUnwrap(stopCommands.first)
        XCTAssertNotEqual(legacyId, command.commandId, "Legacy UUID strings have no run metadata and must not be replayed")
        await store.suspend()
    }

    func testStaleStopCleanupCannotRemoveReplacementRecord() async throws {
        let cache = try SQLiteStore.inMemory()
        let key = "pending.operation.my-pc.stop.runtime.web.photo.photo-upload"
        let oldRecord = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "stopGeneration")
        let newRecord = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "stopGeneration")
        try await cache.put(oldRecord, key: key)
        let cachedOldRecord = try await cache.get(RemoteCommand.self, key: key)
        let capturedOldRecord = try XCTUnwrap(cachedOldRecord)

        try await cache.put(newRecord, key: key)
        let removed = try await cache.remove(key: key, matching: capturedOldRecord)
        let current = try await cache.get(RemoteCommand.self, key: key)

        XCTAssertFalse(removed)
        XCTAssertEqual(current, newRecord)
    }

    func testStaleStopPreparationCannotOverwriteReplacementRecord() async throws {
        let cache = try SQLiteStore.inMemory()
        let key = "pending.operation.my-pc.stop.runtime.web.photo.photo-upload"
        let oldRecord = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "stopGeneration")
        let replacementRecord = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "stopGeneration")
        let staleWrite = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "stopGeneration")
        try await cache.put(oldRecord, key: key)

        let cachedOldRecord = try await cache.get(RemoteCommand.self, key: key)
        let capturedOldRecord = try XCTUnwrap(cachedOldRecord)
        try await cache.put(replacementRecord, key: key)
        let replaced = try await cache.replace(staleWrite, key: key, matching: capturedOldRecord)
        let current = try await cache.get(RemoteCommand.self, key: key)

        XCTAssertFalse(replaced)
        XCTAssertEqual(current, replacementRecord)
    }

    @MainActor
    private func makeStartedStore(transport: ControlledStopTransport, cache: SQLiteStore) async -> WorkspaceStore {
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: "my-pc", name: "Stop Identity Test", state: .connecting)
        _ = await store.start()
        if let runtime = store.runtimes.first(where: { $0.id == "runtime.web" }) {
            await store.refreshRuntime(runtime)
            if let instance = store.instances.first(where: { $0.id == "photo" }) {
                await store.refreshSessions(runtime: runtime, instance: instance)
            }
        }
        return store
    }

    @MainActor
    private func waitForState(_ state: SessionState, sessionId: String, store: WorkspaceStore) async -> Bool {
        for _ in 0..<100 {
            if store.sessions.first(where: { $0.id == sessionId })?.state == state { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.sessions.first(where: { $0.id == sessionId })?.state == state
    }

    private func generationEvent(sequence: Int64, type: String) -> RemoteEvent {
        RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: sequence,
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "photo",
            sessionId: "photo-upload",
            type: type,
            payload: [:],
            createdAt: Date()
        )
    }
}
