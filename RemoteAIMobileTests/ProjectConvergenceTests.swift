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
    func testCompletedWebProgressLabelDoesNotBlockProjectRefresh() async throws {
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.refreshWebProjects(force: true)
        let before = await mock.actionAttemptCount("listProjects")

        // A delayed tool-status update can leave a finished banner visible
        // after the provider reports the Chat idle. This is not proof of an
        // active generation and must not indefinitely defer Project discovery.
        let idleId = "completed-web-label"
        store.sessions.append(SessionDescriptor(
            id: idleId, instanceId: "web.chatgpt",
            title: "Already finished", state: .idle, updatedAt: Date()
        ))
        store.liveRunStatusBySession[idleId] = "回答已生成，正在确认同步…"
        store.webProjectsSnapshotState = .staleCache
        await store.refreshWebProjects(force: false)

        let after = await mock.actionAttemptCount("listProjects")
        XCTAssertGreaterThan(after, before,
            "An idle Chat with only a stale progress label must not indefinitely suppress Project refresh")
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
            XCTAssertNotNil(store.errors["web.project.g-p-remoteai"], "Incomplete pagination must remain visibly retryable, not falsely display success")
            await store.suspend()
        }
    }

    @MainActor
    func testLoadMoreCannotCommitHalfPagedProjectAsComplete() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 125)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai", refresh: true, force: true)
        let fullyAccepted = store.projectConversationsByAlias["g-p-remoteai"] ?? []
        XCTAssertEqual(fullyAccepted.count, 125)

        // Reproduce a session that has displayed only the first 50 of a known
        // generation, while the last complete durable catalog still has 125 rows.
        store.projectConversationsByAlias["g-p-remoteai"] = Array(fullyAccepted.prefix(50))
        store.projectNextCursorByAlias["g-p-remoteai"] = "offset:50"
        store.projectHasMoreByAlias["g-p-remoteai"] = true
        await store.loadMoreProjectConversations(projectAlias: "g-p-remoteai")

        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 100)
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .partialDOM)
        XCTAssertNotNil(store.errors["web.project.g-p-remoteai"])
        let unchangedCache: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.g-p-remoteai.conversations")
        XCTAssertEqual(unchangedCache?.count, 125, "Page 2 must not replace the prior complete durable catalog")

        await store.loadMoreProjectConversations(projectAlias: "g-p-remoteai")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 125)
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .authoritativeLiveDOM)
        XCTAssertNil(store.errors["web.project.g-p-remoteai"])
        await store.suspend()
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

    @MainActor
    func testFailedFullRefreshPersistsVerifiedNewestHeadWithoutTruncatingAcceptedTail() async throws {
        let alias = "g-p-remoteai"
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 230)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        let accepted = try XCTUnwrap(store.projectConversationsByAlias[alias])
        XCTAssertEqual(accepted.count, 230)
        XCTAssertEqual(accepted.first?.conversationAlias, "seed-0")

        // The live first page proves one newly created head row followed by an
        // accepted identity. A later page failure must not hide that new chat or
        // replace the existing full catalog with the incomplete prefix.
        await mock.prependProjectConversation(alias: alias, conversationAlias: "newest-head", title: "Newest head")
        await mock.setProjectConversationPaginationFault(.emptyNonterminalPage)

        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)

        let rows = try XCTUnwrap(store.projectConversationsByAlias[alias])
        XCTAssertEqual(rows.first?.conversationAlias, "newest-head")
        XCTAssertEqual(rows.count, 231)
        XCTAssertEqual(Set(rows.compactMap(\.conversationAlias)), Set(["newest-head"] + (0..<230).map { "seed-\($0)" }))
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias[alias], .partialDOM)
        XCTAssertNotNil(store.errors["web.project.\(alias)"], "A failed full scan remains visibly incomplete")

        let cached: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.\(alias).conversations")
        XCTAssertEqual(cached?.map(\.conversationAlias), rows.map(\.conversationAlias), "The safe head merge must persist so a relaunch can show the latest Chat")
        await store.suspend()
    }

    @MainActor
    func testStaleSixtyFiveRowSnapshotPreservesCachedTwoHundredThirtyUntilFullLiveSnapshot() async throws {
        let alias = "g-p-remoteai"
        let cachedRows = (0..<230).map { index in
            conversation(alias: "seed-\(index)", title: "Seed \(index)", age: TimeInterval(index))
        }
        let cache = try SQLiteStore.inMemory()
        try await cache.put(cachedRows, key: "web.project.\(alias).conversations")

        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 65)
        await mock.setScenario(.staleWebCatalog)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online

        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)

        XCTAssertEqual(store.projectConversationsByAlias[alias]?.map(\.id), cachedRows.map(\.id),
            "A stable but stale 65-row Windows snapshot is positive recovery evidence, not deletion authority")
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias[alias], .staleCache)
        let stillCached: [WebConversationDescriptor]? = try await cache.get(
            [WebConversationDescriptor].self,
            key: "web.project.\(alias).conversations"
        )
        XCTAssertEqual(stillCached?.map(\.id), cachedRows.map(\.id),
            "The stale prefix must not replace the last accepted 230-row phone cache")

        await mock.setScenario(.normal)
        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)

        XCTAssertEqual(store.projectConversationsByAlias[alias]?.map(\.conversationAlias),
            (0..<65).map { "seed-\($0)" },
            "A complete, stably paged live snapshot may replace the catalog and confirm the 165 missing rows")
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias[alias], .authoritativeLiveDOM)
        let authoritativeCache: [WebConversationDescriptor]? = try await cache.get(
            [WebConversationDescriptor].self,
            key: "web.project.\(alias).conversations"
        )
        XCTAssertEqual(authoritativeCache?.count, 65)
        await store.suspend()
    }

    @MainActor
    func testProjectRevisionChangeDuringDelayedRefreshCannotReplaceAcceptedCatalog() async throws {
        let alias = "g-p-remoteai"
        let cachedRows = (0..<230).map { index in
            conversation(alias: "seed-\(index)", title: "Seed \(index)", age: TimeInterval(index))
        }
        let cache = try SQLiteStore.inMemory()
        try await cache.put(cachedRows, key: "web.project.\(alias).conversations")

        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 65)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online
        store.projectConversationsByAlias[alias] = cachedRows
        await mock.setResponseDelay(action: "listProjectConversations", nanoseconds: 350_000_000)
        await mock.failNextAction("createConversation")
        let baselineAttempts = await mock.actionAttemptCount("listProjectConversations")

        let delayedRefresh = Task { @MainActor in
            await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        }
        for _ in 0..<120 {
            if await mock.actionAttemptCount("listProjectConversations") > baselineAttempts { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let startedAttempts = await mock.actionAttemptCount("listProjectConversations")
        XCTAssertGreaterThan(startedAttempts, baselineAttempts,
            "The test must advance the create revision while the provider snapshot is delayed")

        let failedCreate = await store.createWebConversation(projectAlias: alias)
        XCTAssertNil(failedCreate, "The injected failure advances only the local Project revision")
        await delayedRefresh.value

        XCTAssertEqual(store.projectConversationsByAlias[alias]?.map(\.id), cachedRows.map(\.id),
            "A delayed response from the previous revision must not replace the last accepted 230 rows")
        let durableRows: [WebConversationDescriptor]? = try await cache.get(
            [WebConversationDescriptor].self,
            key: "web.project.\(alias).conversations"
        )
        XCTAssertEqual(durableRows?.map(\.id), cachedRows.map(\.id),
            "The stale response must not overwrite the durable accepted catalog")

        await mock.setResponseDelay(action: "listProjectConversations", nanoseconds: 0)
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
