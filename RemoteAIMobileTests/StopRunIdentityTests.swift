import XCTest
@testable import RemoteAIMobile

@MainActor
final class StopRunIdentityTests: XCTestCase {
    private let sessionId = "photo-upload"

    func testOldStopAcknowledgementCannotIdleNewGenerationStartedInFlight() async throws {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        try await prepare(store)

        let firstRunAt = Date().addingTimeInterval(-1)
        await mock.setSessionStatus(sessionId, status: "generating", lastActivityAt: firstRunAt, updatedAt: firstRunAt)
        await mock.injectEvent(generationStarted(sequence: 1201, key: "observer:1", at: firstRunAt), deliverLive: true)
        let firstRunVisible = await waitForSessionState(.busy, in: store)
        XCTAssertTrue(firstRunVisible)

        // The mock emits the Stop terminal event before delaying its successful ACK.
        // That leaves a deterministic window in which a newer run can begin.
        await mock.setResponseDelay(action: "stopGeneration", nanoseconds: 600_000_000)
        let stopTask = Task { await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: sessionId) }
        let oldStopEventReceived = await waitForEventCount(1, type: "GENERATION_STOPPED", from: mock)
        XCTAssertTrue(oldStopEventReceived)

        let nextRunAt = Date()
        await mock.setSessionStatus(sessionId, status: "generating", lastActivityAt: nextRunAt, updatedAt: nextRunAt)
        await mock.injectEvent(generationStarted(sequence: 1203, key: "observer:2", at: nextRunAt), deliverLive: true)
        let nextRunVisible = await waitForSessionActivity(atOrAfter: nextRunAt, in: store)
        XCTAssertTrue(nextRunVisible)

        let stopped = await stopTask.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.sessions.first(where: { $0.id == sessionId })?.state, .busy,
            "A successful acknowledgement for the prior run must not roll back a newer run.")
        XCTAssertNotNil(store.liveRunStatusBySession[sessionId])
        await store.suspend()
    }

    func testUnknownStopForPriorRunGetsFreshCommandIdAfterStatusConfirmsNewRun() async throws {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        try await prepare(store)

        let firstRunAt = Date().addingTimeInterval(-1)
        await mock.setSessionStatus(sessionId, status: "generating", lastActivityAt: firstRunAt, updatedAt: firstRunAt)
        await mock.injectEvent(generationStarted(sequence: 1201, key: "observer:1", at: firstRunAt), deliverLive: true)
        let firstRunVisible = await waitForSessionState(.busy, in: store)
        XCTAssertTrue(firstRunVisible)

        // The first Stop is committed and its terminal event emitted, but its reply is
        // lost. A later explicit Stop must inspect status before considering that ID.
        await mock.disconnectAfterNextAction("stopGeneration")
        let firstStopSucceeded = await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: sessionId)
        XCTAssertFalse(firstStopSucceeded)
        let oldStopEventReceived = await waitForEventCount(1, type: "GENERATION_STOPPED", from: mock)
        XCTAssertTrue(oldStopEventReceived)

        let nextRunAt = Date()
        await mock.setSessionStatus(sessionId, status: "generating", lastActivityAt: nextRunAt, updatedAt: nextRunAt)
        await mock.injectEvent(generationStarted(sequence: 1203, key: "observer:2", at: nextRunAt), deliverLive: true)
        let nextRunVisible = await waitForSessionState(.busy, in: store)
        XCTAssertTrue(nextRunVisible)

        let statusReadsBeforeRetry = await mock.actionAttemptCount("getSessionStatus")
        let secondStopSucceeded = await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: sessionId)
        XCTAssertTrue(secondStopSucceeded)
        let statusReadsAfterRetry = await mock.actionAttemptCount("getSessionStatus")
        XCTAssertGreaterThanOrEqual(statusReadsAfterRetry, statusReadsBeforeRetry + 1,
            "An unknown Stop must be status-checked before its command ID can be reused.")

        let stopCommandIds = await mock.commandIds(action: "stopGeneration")
        XCTAssertEqual(stopCommandIds.count, 2)
        XCTAssertNotEqual(stopCommandIds[0], stopCommandIds[1],
            "A cached result for the old generation cannot represent a Stop of the newer generation.")
        await store.suspend()
    }

    func testStopReplyAfterLifecycleSuspensionDoesNotCompleteStaleCommand() async throws {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        try await prepare(store)
        await mock.setResponseDelay(action: "stopGeneration", nanoseconds: 500_000_000)

        let stopTask = Task { await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: sessionId) }
        let stopEventReceived = await waitForEventCount(1, type: "GENERATION_STOPPED", from: mock)
        XCTAssertTrue(stopEventReceived)
        let commandIds = await mock.commandIds(action: "stopGeneration")
        let commandId = try XCTUnwrap(commandIds.first)

        await store.suspend()
        let stopResult = await stopTask.value
        XCTAssertFalse(stopResult)
        XCTAssertEqual(store.machine.state, .offline)
        XCTAssertEqual(store.commandStates[commandId], .pending,
            "A response from the prior lifecycle must not mutate its command state after suspension.")
    }

    private func prepare(_ store: WorkspaceStore) async throws {
        await store.start()
        let runtime = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.web" }))
        let instance = try XCTUnwrap(store.instances.first(where: { $0.id == "photo" }))
        await store.refreshSessions(runtime: runtime, instance: instance)
    }

    private func generationStarted(sequence: Int64, key: String, at: Date) -> RemoteEvent {
        RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: sequence,
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "photo",
            sessionId: sessionId,
            type: "GENERATION_STARTED",
            payload: ["generationKey": .string(key)],
            createdAt: at
        )
    }

    private func waitForSessionState(_ expected: SessionState, in store: WorkspaceStore) async -> Bool {
        for _ in 0..<120 {
            if store.sessions.first(where: { $0.id == sessionId })?.state == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return store.sessions.first(where: { $0.id == sessionId })?.state == expected
    }

    private func waitForSessionActivity(atOrAfter expected: Date, in store: WorkspaceStore) async -> Bool {
        for _ in 0..<120 {
            if let activity = store.sessions.first(where: { $0.id == sessionId })?.lastActivityAt,
               activity >= expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return (store.sessions.first(where: { $0.id == sessionId })?.lastActivityAt ?? .distantPast) >= expected
    }

    private func waitForEventCount(_ expected: Int, type: String, from mock: MockTransport) async -> Bool {
        for _ in 0..<120 {
            if await mock.eventCount(type: type, sessionId: sessionId) >= expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await mock.eventCount(type: type, sessionId: sessionId) >= expected
    }
}
