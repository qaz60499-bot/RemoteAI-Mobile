import XCTest
@testable import RemoteAIMobile

final class RecoveryFinalVisibilityTests: XCTestCase {
    @MainActor
    func testDurableFinalOlderThanLiveWindowUnmasksBeforeUnrelatedPagesFinish() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let old = Date().addingTimeInterval(-30)
        let final = ServerMessage(messageId: "reconnected-final", sessionId: "photo-upload",
            role: "assistant", content: "final already durable", externalId: nil, createdAt: old)
        await mock.injectEvent(RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: 1201,
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo",
            sessionId: "photo-upload", type: "MESSAGE_ADDED",
            payload: try XCTUnwrap(try JSONValue.encode(final).objectValue), createdAt: old))
        for sequence in 1202...1224 {
            await mock.injectEvent(RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: Int64(sequence),
                machineId: "my-pc", runtimeId: "runtime.system", instanceId: "agent",
                sessionId: "unrelated-session", type: "TRANSPORT_STATUS",
                payload: ["channel": .string("relay"), "state": .string("online")], createdAt: old))
        }
        await mock.setDeltaPageLimitForTests(12)
        await mock.setResponseDelay(action: "getChangesAfterCursor", nanoseconds: 500_000_000)
        let baseline = await mock.actionAttemptCount("getChangesAfterCursor")
        let recovery = Task { await store.verifyOnlineSyncHead() }
        for _ in 0..<400 {
            if await mock.actionAttemptCount("getChangesAfterCursor") >= baseline + 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let requests = await mock.actionAttemptCount("getChangesAfterCursor")
        XCTAssertGreaterThanOrEqual(requests, baseline + 2)
        XCTAssertEqual(store.messagesBySession["photo-upload"]?.first(where: { $0.id == final.messageId })?.text,
                       final.content)
        XCTAssertNil(store.deltaRecoveryDisplayMessagesBySession?["photo-upload"],
            "A durable reply must be visible while unrelated recovery pages remain in flight")
        await recovery.value
        await store.suspend()
    }

    func testCodexModelAndEffortSurviveWireDescriptorAndCacheRoundTrip() throws {
        let now = Date()
        let wire = ServerSession(sessionId: "codex-pending-test", runtimeId: "runtime.codex", instanceId: "codex.8",
            externalId: nil, title: "CLI draft", canonicalUrl: nil, status: "idle",
            metadata: ["model": .string("gpt-5.6-luna"), "reasoningEffort": .string("low")],
            createdAt: now, updatedAt: now, lastVisited: now)
        let descriptor = wire.descriptor
        XCTAssertEqual(descriptor.modelId, "gpt-5.6-luna")
        XCTAssertEqual(descriptor.reasoningEffort, "low")
        let restored = try JSONDecoder.remoteAI.decode(SessionDescriptor.self,
            from: JSONEncoder.remoteAI.encode(descriptor))
        XCTAssertEqual(restored.reasoningEffort, "low")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.remoteAI.encode(descriptor)) as? [String: Any])
        legacy.removeValue(forKey: "reasoningEffort")
        let old = try JSONDecoder.remoteAI.decode(SessionDescriptor.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.reasoningEffort)
    }
}
