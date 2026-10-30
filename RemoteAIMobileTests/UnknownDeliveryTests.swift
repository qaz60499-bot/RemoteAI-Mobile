import XCTest
@testable import RemoteAIMobile

final class UnknownDeliveryTests: XCTestCase {
    @MainActor
    func testMalformedReplyAfterCommittedSendReconcilesWithoutFalseFailureOrReplay() async throws {
        let mock = MockTransport(scenario: .malformedSendReplyAfterCommit, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        let commandId = UUID()
        let sent = await store.send(text: "bad-ack-with-commit", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", commandId: commandId)
        XCTAssertTrue(sent, "A malformed reply must not turn a provable committed send into a red failure")
        XCTAssertEqual(store.commandStates[commandId], .completed)
        let attempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(attempts, 1)
        await store.suspend()
    }

    @MainActor
    func testManualUnknownStatusCheckNeverReplaysCachedAmbiguousFailureOrDropsPayload() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(scenario: .webSendDeliveryUnknown, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let commandId = UUID()
        let sent = await store.send(text: "unknown-manual-check", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", commandId: commandId)
        XCTAssertFalse(sent)
        let bubble = try XCTUnwrap(store.messagesBySession["photo-upload"]?.first(where: {
            $0.id.caseInsensitiveCompare(commandId.uuidString) == .orderedSame
        }))
        await store.retry(message: bubble, runtimeId: "runtime.web", instanceId: "photo")
        let attempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(attempts, 1, "A status check must not issue any additional provider send")
        XCTAssertEqual(store.commandStates[commandId], .unknown)
        let pending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertEqual(pending?.commandId, commandId)
        XCTAssertEqual(pending?.payload["text"]?.stringValue, "unknown-manual-check")
        await store.suspend()
    }

    @MainActor
    func testCancellationAfterDispatchKeepsUnknownPayloadAndBubble() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(scenario: .cancelledSendReplyAfterCommit, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let commandId = UUID()
        let sent = await store.send(text: "cancelled-ack", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", commandId: commandId)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.commandStates[commandId], .unknown,
            "Cancelling a confirmation cannot prove an already-dispatched send failed")
        let pending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertEqual(pending?.commandId, commandId)
        let attempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(attempts, 1)
        await store.suspend()
    }
}
