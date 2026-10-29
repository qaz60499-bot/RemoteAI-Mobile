import XCTest
@testable import RemoteAIMobile

final class InterruptedSessionStatusTests: XCTestCase {
    @MainActor
    private func startedStore() async throws -> (MockTransport, WorkspaceStore) {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadSession("photo-upload")
        return (mock, store)
    }

    private func event(_ type: String, sequence: Int64, at: Date, payload: [String: JSONValue] = [:]) -> RemoteEvent {
        RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: sequence,
                    machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo",
                    sessionId: "photo-upload", type: type, payload: payload, createdAt: at)
    }

    @MainActor
    func testFreshInterruptionRetiresPhantomBusyWithoutCompletingPartial() async throws {
        let (mock, store) = try await startedStore()
        let liveAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        let interruptedAt = liveAt.addingTimeInterval(60)
        await mock.injectEvent(event("GENERATION_STARTED", sequence: 1201, at: liveAt), deliverLive: true)
        await mock.injectEvent(event("MESSAGE_UPDATED", sequence: 1202, at: liveAt.addingTimeInterval(1), payload: [
            "role": .string("assistant"), "content": .string("partial retained"), "partial": .bool(true),
        ]), deliverLive: true)
        for _ in 0..<100 where store.assistantStreams["photo-upload"]?.text != "partial retained" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.liveRunStatusBySession["photo-upload"])
        await mock.setSessionStatus("photo-upload", status: "interrupted",
                                    lastActivityAt: liveAt.addingTimeInterval(-5),
                                    updatedAt: interruptedAt, interruptedAt: interruptedAt)
        let decoded = try await mock.sessionStatus(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        XCTAssertEqual(decoded.rawServerStatus, "interrupted")
        XCTAssertEqual(decoded.interruptedAt, interruptedAt)

        await store.synchronizeVisibleSession("photo-upload")
        let session = try XCTUnwrap(store.sessions.first { $0.id == "photo-upload" })
        XCTAssertEqual(session.state, .unknown)
        XCTAssertEqual(session.statusSource, "web-agent-interruption")
        XCTAssertEqual(session.statusObservedAt, interruptedAt)
        XCTAssertNil(store.liveRunStatusBySession["photo-upload"])
        XCTAssertNil(session.lastProgressStatus)
        XCTAssertTrue(store.systemNotice(forSessionId: "photo-upload")?.text.contains("未确认") == true)
        let partial = try XCTUnwrap(store.messagesBySession["photo-upload", default: []].first { $0.text == "partial retained" })
        XCTAssertEqual(partial.toolStatus, "Streaming", "Unknown output must not become a cached successful final")
        XCTAssertEqual(SessionState.server("interrupted"), .idle, "Historical list mapping remains separate from detailed interruption evidence")
        await store.suspend()
    }

    @MainActor
    func testOldInterruptionCannotRetireNewerLiveRun() async throws {
        let (mock, store) = try await startedStore()
        let liveAt = Date().addingTimeInterval(-30)
        await mock.injectEvent(event("GENERATION_STARTED", sequence: 1201, at: liveAt), deliverLive: true)
        for _ in 0..<100 where store.liveRunStatusBySession["photo-upload"] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await mock.setSessionStatus("photo-upload", status: "interrupted",
                                    lastActivityAt: liveAt.addingTimeInterval(-10),
                                    interruptedAt: liveAt.addingTimeInterval(-5))
        await store.synchronizeVisibleSession("photo-upload")
        XCTAssertEqual(store.sessions.first { $0.id == "photo-upload" }?.state, .busy)
        XCTAssertNotNil(store.liveRunStatusBySession["photo-upload"])
        await store.suspend()
    }

    @MainActor
    func testDelayedInterruptionPollCannotOverwriteNewLiveEvent() async throws {
        let (mock, store) = try await startedStore()
        await mock.setSessionStatus("photo-upload", status: "interrupted", interruptedAt: Date().addingTimeInterval(10))
        await mock.setResponseDelay(action: "getSessionStatus", nanoseconds: 400_000_000)
        async let sync: Void = store.synchronizeVisibleSession("photo-upload")
        try await Task.sleep(nanoseconds: 50_000_000)
        await mock.injectEvent(event("GENERATION_STARTED", sequence: 1201, at: Date()), deliverLive: true)
        for _ in 0..<100 where store.liveRunStatusBySession["photo-upload"] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await sync
        XCTAssertEqual(store.sessions.first { $0.id == "photo-upload" }?.state, .busy)
        XCTAssertNotNil(store.liveRunStatusBySession["photo-upload"])
        await store.suspend()
    }
}
