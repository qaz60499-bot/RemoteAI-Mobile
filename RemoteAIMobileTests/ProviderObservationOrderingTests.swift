import XCTest
@testable import RemoteAIMobile

final class ProviderObservationOrderingTests: XCTestCase {
    @MainActor
    func testOldOnlinePollCannotClearNewerProviderErrorAndFreshPollCan() async throws {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadSession("photo-upload")
        let observedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 20)
        await mock.injectEvent(RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: 1201,
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            type: "SESSION_STATUS", payload: [
                "providerSurface": .bool(true), "state": .string("degraded"),
                "providerState": .string("connection-lost"), "code": .string("PROVIDER_UNAVAILABLE"),
                "message": .string("网页尚未恢复"), "originalMessage": .string("Failed to fetch"),
                "at": .string(RemoteAIDate.string(observedAt)),
            ], createdAt: observedAt), deliverLive: true)
        for _ in 0..<100 where store.errors["photo-upload"] != "网页尚未恢复" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // The poll begins after the push, so the event-revision fence alone cannot
        // reject an older persisted provider observation returned by the server.
        await mock.setSessionStatusMetadata("photo-upload", metadata: [
            "providerSurfaceState": .string("online"),
            "providerSurfaceObservedAt": .string(RemoteAIDate.string(observedAt.addingTimeInterval(-5))),
        ])
        await store.synchronizeVisibleSession("photo-upload")
        XCTAssertEqual(store.errors["photo-upload"], "网页尚未恢复")
        XCTAssertEqual(store.webProviderIssueOriginalMessage(forSessionId: "photo-upload"), "Failed to fetch")

        // An explicit online state without page observation time is also no proof.
        await mock.setSessionStatusMetadata("photo-upload", metadata: ["providerSurfaceState": .string("online")])
        await store.synchronizeVisibleSession("photo-upload", force: true)
        XCTAssertEqual(store.errors["photo-upload"], "网页尚未恢复")

        let recoveredAt = observedAt.addingTimeInterval(5)
        await mock.setSessionStatusMetadata("photo-upload", metadata: [
            "providerSurfaceState": .string("online"),
            "providerSurfaceObservedAt": .string(RemoteAIDate.string(recoveredAt)),
        ])
        await store.synchronizeVisibleSession("photo-upload", force: true)
        XCTAssertNil(store.errors["photo-upload"])
        XCTAssertEqual(store.webProviderSurfaceState(forSessionId: "photo-upload"), "online")
        XCTAssertEqual(store.webProviderSurfaceObservedAt(forSessionId: "photo-upload"), recoveredAt)
        await store.suspend()
    }
}
