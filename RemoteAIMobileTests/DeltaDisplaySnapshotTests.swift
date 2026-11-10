import XCTest
@testable import RemoteAIMobile

final class DeltaDisplaySnapshotTests: XCTestCase {
    @MainActor
    func testEmptyDeltaSnapshotCannotHideHydratedOriginalWebHistory() {
        let cached = [
            ServerMessage(
                messageId: "cached-original-user",
                sessionId: "original-web",
                role: "user",
                content: "Durable original question",
                externalId: nil,
                createdAt: Date().addingTimeInterval(-30)
            ).chatMessage,
            ServerMessage(
                messageId: "cached-original-assistant",
                sessionId: "original-web",
                role: "assistant",
                content: "Durable original reply",
                externalId: nil,
                createdAt: Date().addingTimeInterval(-20)
            ).chatMessage
        ]
        let ids = cached.map(\.id)
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: []).map(\.id),
            ids,
            "An empty historical delta snapshot must not hide durable User/Assistant history"
        )
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: nil).map(\.id),
            ids
        )
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: [cached[0]]).map(\.id),
            [cached[0].id],
            "Nonempty delta snapshots should retain their existing coalescing behavior"
        )
        XCTAssertTrue(ChatView.visibleHistoryMessages(canonical: [], deltaSnapshot: []).isEmpty)
    }
}
