import XCTest
@testable import RemoteAIMobile

final class ProjectActivityRefreshTests: XCTestCase {
    @MainActor
    func testStreamProgressDoesNotForceProjectMembershipRescans() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 125)
        // A Web run event updates an existing registered session; without this
        // fixture the synthetic stream cannot prove the Running activity overlay.
        await mock.seedWebProjectSession(
            alias: "g-p-remoteai",
            conversationAlias: "seed-1",
            title: "Desktop running chat",
            status: "idle",
            lastActivityAt: Date().addingTimeInterval(-3600)
        )
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)

        let originalProviderOrder = store.projectConversationsByAlias["g-p-remoteai"]?.map(\.conversationAlias)
        XCTAssertEqual(originalProviderOrder?.count, 125)
        XCTAssertEqual(store.displayedProjectConversations(projectAlias: "g-p-remoteai").first?.conversationAlias,
            "seed-0", "Idle old session must not be promoted before new stream activity")
        let attemptsBeforeRun = await mock.actionAttemptCount("listProjectConversations")
        let now = Date()
        for number in 0..<40 {
            let type = number == 0 ? "GENERATION_STARTED"
                : (number.isMultiple(of: 2) ? "TOOL_STARTED" : "MESSAGE_UPDATED")
            let payload: [String: JSONValue]
            switch type {
            case "TOOL_STARTED":
                payload = ["tool": .string("ChatGPT Web"), "summary": .string("Thinking")]
            case "MESSAGE_UPDATED":
                payload = ["role": .string("assistant"), "content": .string("Working"), "partial": .bool(true)]
            default:
                payload = ["provider": .string("chatgpt-web")]
            }
            await mock.injectEvent(RemoteEvent(
                protocolVersion: 1,
                eventId: UUID(),
                sequence: Int64(1201 + number),
                machineId: "my-pc",
                runtimeId: "runtime.web",
                instanceId: "web.chatgpt",
                sessionId: "webconv-seed-1",
                type: type,
                payload: payload,
                createdAt: now.addingTimeInterval(Double(number) * 0.01)
            ), deliverLive: true)
        }

        // The old 700 ms delayed activity callback would launch an expensive
        // forced Project reload even when no membership changed.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let attemptsAfterProgress = await mock.actionAttemptCount("listProjectConversations")
        XCTAssertEqual(attemptsAfterProgress, attemptsBeforeRun,
            "Stream/tool/status frames must update the activity overlay, not scan 125 sidebar rows")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.map(\.conversationAlias),
            originalProviderOrder, "Activity must not rewrite the provider paging authority")
        XCTAssertEqual(store.displayedProjectConversations(projectAlias: "g-p-remoteai").first?.conversationAlias,
            "seed-1", "A running conversation should be immediately promoted by the in-memory overlay")

        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 126)
        await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 126,
            "Explicit refresh must still discover newly created Chats across all pages")
        await store.suspend()
    }
}
