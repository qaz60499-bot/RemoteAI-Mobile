import XCTest
@testable import RemoteAIMobile

final class ProjectConvergenceTests: XCTestCase {
    @MainActor
    func testAutomaticProjectRefreshEscalatesCachedIncompleteReadOnceAndKeepsThrottle() async throws {
        let mock = MockTransport(scenario: .staleThenFreshProjectConversations, historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 3)
        let cache = try SQLiteStore.inMemory()
        try await cache.put(
            [conversation(alias: "cached-old", title: "Cached old", age: 60)],
            key: "web.project.g-p-remoteai.conversations"
        )
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let baselineAttempts = await mock.actionAttemptCount("listProjectConversations")

        await store.loadProjectConversations(projectAlias: "g-p-remoteai", force: false)

        let attemptsAfterConvergence = await mock.actionAttemptCount("listProjectConversations")
        let cachePreferences = await mock.preferCacheValues("listProjectConversations")
        XCTAssertEqual(attemptsAfterConvergence - baselineAttempts, 2, "A cached automatic read gets one live escalation, with no retry loop")
        XCTAssertEqual(Array(cachePreferences.suffix(2)), [true, false], "The initial automatic read prefers Windows cache, then the bounded escalation requests live state")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.map(\.conversationAlias), ["seed-0", "seed-1", "seed-2"])
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .authoritativeLiveDOM)

        await store.loadProjectConversations(projectAlias: "g-p-remoteai", force: false)

        let attemptsAfterThrottledRefresh = await mock.actionAttemptCount("listProjectConversations")
        XCTAssertEqual(attemptsAfterThrottledRefresh, attemptsAfterConvergence, "A second automatic refresh remains inside the existing freshness throttle")
        await store.suspend()
    }

    @MainActor
    func testProjectRefreshLoadsMoreThanTwoHundredRowsAcrossStablePages() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 225)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        let baselineAttempts = await mock.actionAttemptCount("listProjectConversations")

        await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)

        let rows = store.projectConversationsByAlias["g-p-remoteai"] ?? []
        XCTAssertEqual(rows.count, 225)
        XCTAssertEqual(rows.first?.conversationAlias, "seed-0")
        XCTAssertEqual(rows.last?.conversationAlias, "seed-224")
        XCTAssertEqual(store.projectHasMoreByAlias["g-p-remoteai"], false)
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .authoritativeLiveDOM)
        let attempts = await mock.actionAttemptCount("listProjectConversations")
        XCTAssertEqual(attempts - baselineAttempts, 5, "The complete 225-row catalog is read as five 50-row pages")
        await store.suspend()
    }

    @MainActor
    func testMalformedProjectRefreshPagesKeepPreviouslyAcceptedCatalog() async throws {
        let faults: [MockProjectConversationPaginationFault] = [
            .missingContinuation,
            .repeatedContinuation,
            .emptyNonterminalPage,
            .changedSnapshot,
            .differentProject
        ]

        for fault in faults {
            let mock = MockTransport(historyCount: 1)
            await mock.seedProjectConversations(alias: "g-p-remoteai", count: 65)
            let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
            await store.start()
            await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)
            let acceptedRows = store.projectConversationsByAlias["g-p-remoteai"] ?? []
            XCTAssertEqual(acceptedRows.count, 65, "Fixture precondition for \(fault.rawValue)")

            await mock.setProjectConversationPaginationFault(fault)
            await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)

            XCTAssertEqual(
                store.projectConversationsByAlias["g-p-remoteai"]?.map(\.id),
                acceptedRows.map(\.id),
                "Malformed \(fault.rawValue) pagination must not replace or truncate the last accepted list"
            )
            XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .partialDOM)
            await store.suspend()
        }
    }

    @MainActor
    func testLoadMoreRejectsEmptyNonterminalPageWithoutChangingAcceptedRows() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 65)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)
        let acceptedRows = store.projectConversationsByAlias["g-p-remoteai"] ?? []
        store.projectHasMoreByAlias["g-p-remoteai"] = true
        store.projectNextCursorByAlias["g-p-remoteai"] = "offset:50"
        await mock.setProjectConversationPaginationFault(.emptyNonterminalPage)

        await store.loadMoreProjectConversations(projectAlias: "g-p-remoteai")

        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.map(\.id), acceptedRows.map(\.id))
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .partialDOM)
        XCTAssertNotNil(store.errors["web.project.g-p-remoteai"])
        await store.suspend()
    }

    private func conversation(alias: String, title: String, age: TimeInterval) -> WebConversationDescriptor {
        let updatedAt = Date().addingTimeInterval(-age)
        return WebConversationDescriptor(
            localConversationId: "webconv-\(alias)",
            canonicalUrl: "https://chatgpt.com/g/g-p-remoteai/c/\(alias)",
            projectId: nil,
            displayTitle: title,
            projectAlias: "g-p-remoteai",
            conversationAlias: alias,
            lastVisited: updatedAt,
            updatedAt: updatedAt
        )
    }
}
