import XCTest
@testable import RemoteAIMobile

final class WebTabEntryTests: XCTestCase {
    func testWebFirstSendCanReachConnectedTransportRecoveryWhenDisplayIsStaleOffline() {
        XCTAssertTrue(ChatComposerSendAvailability.enabled(machineOnline: false, isWeb: true,
            sending: false, sessionUnavailable: false, readOnly: false),
            "Web first Send must reach the existing authenticated recovery or draft-preserving failure path")
        XCTAssertTrue(ChatComposerSendAvailability.enabled(machineOnline: true, isWeb: true,
            sending: false, sessionUnavailable: false, readOnly: false))
        XCTAssertFalse(ChatComposerSendAvailability.enabled(machineOnline: false, isWeb: false,
            sending: false, sessionUnavailable: false, readOnly: false))
        XCTAssertFalse(ChatComposerSendAvailability.enabled(machineOnline: false, isWeb: true,
            sending: true, sessionUnavailable: false, readOnly: false))
        XCTAssertFalse(ChatComposerSendAvailability.enabled(machineOnline: false, isWeb: true,
            sending: false, sessionUnavailable: true, readOnly: false))
        XCTAssertFalse(ChatComposerSendAvailability.enabled(machineOnline: false, isWeb: true,
            sending: false, sessionUnavailable: false, readOnly: true))
    }

    func testClosedTabNoticeCannotLeakIntoNewlyCreatedChat() {
        let closed = "电脑端对应的 ChatGPT 标签页已关闭；RemoteAI 会在需要时重新打开并绑定该会话。"
        let rebound = "电脑端 ChatGPT 会话已重新绑定；手机正在补同步最新状态。"
        XCTAssertTrue(WebChatNoticeVisibility.shouldDisplay(closed,
            sessionId: "webconv-old", sourceSessionId: "webconv-old"))
        XCTAssertFalse(WebChatNoticeVisibility.shouldDisplay(closed,
            sessionId: "webconv-new", sourceSessionId: "webconv-old"))
        XCTAssertFalse(WebChatNoticeVisibility.shouldDisplay(rebound,
            sessionId: "webconv-new", sourceSessionId: nil))
        XCTAssertTrue(WebChatNoticeVisibility.shouldDisplay("Relay 已恢复",
            sessionId: "webconv-new", sourceSessionId: "webconv-old"))
    }

    func testStaleWebTabRowRefreshesInventoryInsteadOfDisablingTheTap() {
        let stale = WebTabEntryStatus(isLoading: false,
            code: "BROWSER_BINDING_MISSING", diagnosisCode: nil,
            message: "Tab identity changed", observedAt: Date(),
            rawMessage: nil, retryable: false,
            requiresInventoryRefresh: true, cachedSession: nil)
        let recoverableWarning = WebTabEntryStatus(isLoading: false,
            code: "PROVIDER_UNAVAILABLE", diagnosisCode: nil,
            message: "Page unavailable", observedAt: Date(),
            rawMessage: nil, retryable: true,
            requiresInventoryRefresh: false, cachedSession: nil)
        XCTAssertEqual(WebTabRowIntent.resolve(stale), .refreshInventory)
        XCTAssertEqual(WebTabRowIntent.resolve(recoverableWarning), .enter)
        XCTAssertEqual(WebTabRowIntent.resolve(nil), .enter)
    }

    @MainActor
    func testOrdinaryWebHistoryKeepsRouteThroughCatalogRaceWithoutOpeningChrome() async throws {
        let mock = MockTransport(historyCount: 0, includeOrdinaryWebHistoryFixture: true)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        let started = await store.start()
        XCTAssertTrue(started)
        // start() loads runtime metadata but intentionally leaves session catalogs
        // lazy. Entering Web > ChatGPT triggers this exact two-stage catalog read.
        let runtime = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.web" }))
        await store.refreshRuntime(runtime)
        let instance = try XCTUnwrap(store.instances.first(where: { $0.id == "web.chatgpt" }))
        await store.refreshSessions(runtime: runtime, instance: instance)
        let session = try XCTUnwrap(store.sessions.first(where: { $0.id == "webconv-root-history-mock" }))
        store.prepareHistoricalWebChat(session)

        // The historical row was tapped, but an incomplete listSessions refresh
        // evicted it before ChatView's asynchronous first read could start.
        store.sessions.removeAll { $0.id == session.id }
        await store.loadSession(session.id)
        let messages = store.messagesBySession[session.id] ?? []
        XCTAssertEqual(messages.map(\.text), ["普通历史消息", "普通历史助手回复"])
        let tabEntryAttempts = await mock.actionAttemptCount("manageOpenWebTab")
        let reopenAttempts = await mock.actionAttemptCount("reopenVerifiedWebConversation")
        XCTAssertEqual(tabEntryAttempts, 0)
        XCTAssertEqual(reopenAttempts, 0)
        await store.suspend()
    }

    @MainActor
    func testConfirmedWebTabRecoveryUsesExactTabAndDisruptiveConsent() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first(where: { $0.isChat && $0.sessionId != nil }))
        await store.recoverWebChat(try XCTUnwrap(tab.sessionId),
            operation: "hardReload", expectedTabId: tab.tabId)
        let attempts = await mock.actionAttemptCount("manageOpenWebTab")
        let consent = await mock.lastManagedWebTabConsent()
        XCTAssertEqual(attempts, 1, "Explicit user confirmation must be delivered only once")
        XCTAssertEqual(consent, true, "Chrome needs explicit permission to reload an errored document")
    }

    @MainActor
    func testConfirmedReloadInspectsTheSameTabAfterDispatch() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first(where: { $0.isChat && $0.sessionId != nil }))
        let sessionId = try XCTUnwrap(tab.sessionId)

        await store.recoverWebChat(sessionId, operation: "reload", expectedTabId: tab.tabId)

        let reloadAttempts = await mock.actionAttemptCount("manageOpenWebTab")
        let inspectionAttempts = await mock.actionAttemptCount("inspectOpenWebTab")
        XCTAssertEqual(reloadAttempts, 1)
        XCTAssertEqual(inspectionAttempts, 1,
            "The post-reload probe must run even while recoverWebChat owns the tab lock")
        XCTAssertEqual(store.webTabDiagnosesById[tab.id]?.tabId, tab.id)
        XCTAssertEqual(store.webTabDiagnosesById[tab.id]?.state, "ready")
        XCTAssertTrue(store.webChatRecoveryNotesBySession[sessionId]?.contains("ready") == true,
            "The UI must report the newly probed state even when history recovery is incomplete")
    }

    @MainActor
    func testReloadDoesNotClaimPageRecoveredWhenPostReloadProbeFails() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first(where: { $0.isChat && $0.sessionId != nil }))
        let sessionId = try XCTUnwrap(tab.sessionId)
        await mock.failNextAction("inspectOpenWebTab")

        await store.recoverWebChat(sessionId, operation: "hardReload", expectedTabId: tab.tabId)

        let reloadAttempts = await mock.actionAttemptCount("manageOpenWebTab")
        let inspectionAttempts = await mock.actionAttemptCount("inspectOpenWebTab")
        XCTAssertEqual(reloadAttempts, 1)
        XCTAssertEqual(inspectionAttempts, 1)
        XCTAssertNil(store.webTabDiagnosesById[tab.id],
            "A pre-refresh diagnosis must never be reused as proof of page recovery")
        XCTAssertTrue(store.webChatRecoveryNotesBySession[sessionId]?.contains("检查失败") == true)
    }

    @MainActor
    func testStaleSelectedWebTabDoesNotReloadAnotherMatchingChat() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first(where: { $0.isChat && $0.sessionId != nil }))
        await store.recoverWebChat(try XCTUnwrap(tab.sessionId),
            operation: "reload", expectedTabId: tab.tabId + 1000)
        let attempts = await mock.actionAttemptCount("manageOpenWebTab")
        XCTAssertEqual(attempts, 0, "Changed tab identities must never receive a reload")
    }

    @MainActor
    func testEnterKeepsDiagnosisAndAllowsViewingBusyTab() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)
        let busyTab = OpenWebTab(tabId: tab.tabId, title: tab.title,
            canonicalUrl: tab.canonicalUrl, active: tab.active, loading: false,
            kind: tab.kind, sessionId: tab.sessionId, busy: true)
        let now = Date()
        let conversation = WebConversationDescriptor(localConversationId: tab.sessionId ?? "webconv-project-1",
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "mock-1", lastVisited: now, updatedAt: now)
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: conversation,
            project: nil, diagnosisState: "generating", diagnosisBusy: true))

        let destination = await store.enterOpenWebTab(busyTab)
        guard let destination else {
            return XCTFail("Entry was rejected")
        }
        guard case .chat(let session) = destination else {
            return XCTFail("Expected the selected existing Chat even while its page is generating")
        }
        XCTAssertEqual(session.id, tab.sessionId ?? "")
        let diagnosis = store.webTabDiagnosesById[tab.id]
        XCTAssertEqual(diagnosis?.tabId, tab.tabId)
        XCTAssertEqual(diagnosis?.state, "generating")
        XCTAssertEqual(diagnosis?.canonicalUrl, tab.canonicalUrl)
        XCTAssertTrue(diagnosis?.busy == true)
    }

    @MainActor
    func testConcurrentEnterClicksShareOnePerTabRequestAndExposeLoadingState() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        await mock.setResponseDelay(action: "manageOpenWebTab", nanoseconds: 250_000_000)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let expectedSessionId = try XCTUnwrap(tab.sessionId)

        let firstEnter = Task { @MainActor in await store.enterOpenWebTab(tab) }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(store.webTabEntryStatusById[tab.id]?.isLoading == true,
            "The selected row should show its own pending entry state")
        let duplicateEnter = await store.enterOpenWebTab(tab)
        XCTAssertNil(duplicateEnter, "A concurrent click on the same tab must coalesce")
        let destination = await firstEnter.value

        guard let destination, case .chat(let session) = destination else {
            return XCTFail("The single verified entry should return its Chat")
        }
        XCTAssertEqual(session.id, expectedSessionId)
        let enterAttempts = await mock.actionAttemptCount("manageOpenWebTab")
        XCTAssertEqual(enterAttempts, 1)
        XCTAssertNil(store.webTabEntryStatusById[tab.id], "Successful verification clears the row error/loading state")
    }

    @MainActor
    func testFailedEntryOffersOnlyExactCachedHistoryAndVerifiedEnterRestoresLiveMode() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        let session = SessionDescriptor(
            id: sessionId,
            instanceId: "web.chatgpt",
            title: tab.title,
            state: .idle,
            updatedAt: Date(),
            projectAlias: "g-p-remoteai",
            canonicalUrl: tab.canonicalUrl
        )
        let cachedMessage = ChatMessage(
            id: "cached-exact-web-history",
            sessionId: sessionId,
            sequence: 1,
            role: .user,
            kind: .text,
            text: "cached locally",
            createdAt: Date()
        )
        store.sessions = [session]
        try await cache.upsertMessages([cachedMessage])
        await mock.failNextAction("manageOpenWebTab")

        let failedDestination = await store.enterOpenWebTab(tab)
        XCTAssertNil(failedDestination)
        let issue = try XCTUnwrap(store.webTabEntryStatusById[tab.id])
        XCTAssertEqual(issue.code, "MOCK_ACTION_FAILURE")
        XCTAssertFalse(issue.isLoading)
        XCTAssertTrue(issue.message.contains("网页身份校验未通过"))
        XCTAssertGreaterThanOrEqual(issue.observedAt, Date().addingTimeInterval(-5))
        XCTAssertEqual(issue.rawMessage, "Mock action failed once")
        XCTAssertEqual(issue.cachedSession?.id, sessionId)

        let cachedDestination = await store.openCachedWebTabHistory(tab)
        XCTAssertEqual(cachedDestination?.id, sessionId)
        XCTAssertTrue(store.isCachedWebSessionReadOnly(sessionId))
        let historyAttempts = await mock.actionAttemptCount("loadRecentMessages")
        XCTAssertEqual(historyAttempts, 0,
            "Opening the fallback must use local cache and make no remote history request")

        await store.loadSession(sessionId, localOnly: true)
        XCTAssertNotNil(store.messagesBySession[sessionId]?.first,
            "The read-only Chat must have its cached cursor before testing older-page loading")
        store.hasMoreBySession[sessionId] = true
        let retainedSessionError = "Keep the verified session error visible"
        store.errors[sessionId] = retainedSessionError
        await store.loadOlder(sessionId)
        let olderPageAttempts = await mock.actionAttemptCount("loadMessagesBefore")
        XCTAssertEqual(olderPageAttempts, 0,
            "Read-only cached history must page from SQLite without a remote history request")
        XCTAssertEqual(store.errors[sessionId], retainedSessionError,
            "A cache-only read is not authenticated recovery and cannot clear a true session error")

        let liveDestination = await store.enterOpenWebTab(tab)
        guard let liveDestination, case .chat(let liveSession) = liveDestination else {
            return XCTFail("A later verified live entry should restore the same Chat")
        }
        XCTAssertEqual(liveSession.id, sessionId)
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId),
            "Only the verified live receipt should clear cached-history read-only mode")
    }

    @MainActor
    func testCachedHistoryFallbackRejectsSameTitleWithDifferentCanonicalChat() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        store.sessions = [SessionDescriptor(
            id: sessionId,
            instanceId: "web.chatgpt",
            title: tab.title,
            state: .idle,
            updatedAt: Date(),
            projectAlias: "g-p-remoteai",
            canonicalUrl: "https://chatgpt.com/g/g-p-remoteai/c/a-different-chat"
        )]
        try await cache.upsertMessages([ChatMessage(
            id: "cached-wrong-chat",
            sessionId: sessionId,
            sequence: 1,
            role: .user,
            kind: .text,
            text: "same visible title",
            createdAt: Date()
        )])
        await mock.failNextAction("manageOpenWebTab")

        _ = await store.enterOpenWebTab(tab)

        XCTAssertNil(store.webTabEntryStatusById[tab.id]?.cachedSession,
            "A matching title/session key cannot override a different canonical conversation identity")
        let cachedDestination = await store.openCachedWebTabHistory(tab)
        XCTAssertNil(cachedDestination)
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId))
    }

    @MainActor
    func testExactPersistedChatOpensWhenPageIdentityIsUnverifiedWithoutImportingPageHistory() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        let session = SessionDescriptor(
            id: sessionId,
            instanceId: "web.chatgpt",
            title: tab.title,
            state: .idle,
            updatedAt: Date(),
            projectAlias: "g-p-remoteai",
            canonicalUrl: tab.canonicalUrl
        )
        store.sessions = [session]
        try await cache.upsertMessages([ChatMessage(
            id: "cached-unverified-entry-history",
            sessionId: sessionId,
            sequence: 1,
            role: .user,
            kind: .text,
            text: "cached history",
            createdAt: Date()
        )])
        let observedAt = Date(timeIntervalSince1970: 1_798_900_000)
        let conversation = WebConversationDescriptor(
            localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl,
            projectId: nil,
            displayTitle: "Unverified page title must not replace the persisted Chat",
            projectAlias: "g-p-remoteai",
            conversationAlias: "seed-0",
            lastVisited: observedAt,
            updatedAt: observedAt
        )
        await mock.setEnteredOpenWebTabFixture(try enterFixture(
            tab: tab,
            conversation: conversation,
            project: nil,
            diagnosisState: "not-ready",
            issueCode: "CONVERSATION_IDENTITY_UNVERIFIED",
            issueMessage: "Conversation identity and composer are not verified.",
            observedAt: observedAt
        ))
        let cachedMessagesBeforeEntry = try await cache.recentMessages(sessionId: sessionId, limit: 10)

        let destination = await store.enterOpenWebTab(tab)

        guard case .chat(let openedSession)? = destination else {
            await store.suspend()
            return XCTFail("The exact persisted Chat receipt should open even while page identity is unverified")
        }
        XCTAssertEqual(openedSession, session, "Use the already-persisted identity, not page metadata")
        XCTAssertEqual(store.sessions, [session], "Entry must not import or replace a transcript/session from the page")
        XCTAssertNil(store.messagesBySession[sessionId], "Entry itself must not import page history")
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId),
            "Opening the Chat must leave normal Agent-validated sending available")
        XCTAssertTrue(ChatComposerSendAvailability.enabled(machineOnline: true, isWeb: true,
            sending: false, sessionUnavailable: false,
            readOnly: store.isCachedWebSessionReadOnly(sessionId)))
        let cachedMessagesAfterEntry = try await cache.recentMessages(sessionId: sessionId, limit: 10)
        XCTAssertEqual(cachedMessagesAfterEntry, cachedMessagesBeforeEntry)
        let issue = try XCTUnwrap(store.webTabEntryStatusById[tab.id])
        XCTAssertEqual(issue.code, "CONVERSATION_IDENTITY_UNVERIFIED")
        XCTAssertEqual(issue.observedAt, observedAt)
        XCTAssertEqual(issue.rawMessage, "Conversation identity and composer are not verified.")
        XCTAssertNotNil(issue.cachedSession, "The row may offer only the exact locally cached Chat history")
        XCTAssertTrue(issue.message.contains("身份"))
        await store.suspend()
    }

    @MainActor
    func testUnverifiedPersistedEntryKeepsAgentHistorySynchronizationAvailable() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        let session = SessionDescriptor(id: sessionId, instanceId: "web.chatgpt",
            title: tab.title, state: .idle, updatedAt: Date(),
            projectAlias: "g-p-remoteai", canonicalUrl: tab.canonicalUrl)
        store.sessions = [session]
        let conversation = WebConversationDescriptor(localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "seed-0",
            lastVisited: Date(), updatedAt: Date())
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: conversation,
            project: nil, diagnosisState: "not-ready",
            issueCode: "CONVERSATION_IDENTITY_UNVERIFIED"))

        let destination = await store.enterOpenWebTab(tab)
        guard case .chat(let openedSession)? = destination else {
            await store.suspend()
            return XCTFail("The exact persisted Chat should open")
        }
        XCTAssertEqual(openedSession.id, sessionId)
        await store.synchronizeVisibleSession(sessionId, force: true)
        let historyReads = await mock.actionAttemptCount("loadRecentMessages")
        XCTAssertGreaterThan(historyReads, 0,
            "Unverified DOM diagnosis must not block history from the exact persisted Agent Chat")
        XCTAssertEqual(store.webTabDiagnosesById[tab.id]?.issueCode, "CONVERSATION_IDENTITY_UNVERIFIED",
            "The Agent-backed sync remains available without rewriting or trusting the DOM diagnosis")
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId))
        await store.suspend()
    }

    @MainActor
    func testUnverifiedEntryRejectsWrongChatProjectAndTabReceipts() async throws {
        let mock = MockTransport(historyCount: 0)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        let session = SessionDescriptor(id: sessionId, instanceId: "web.chatgpt",
            title: tab.title, state: .idle, updatedAt: Date(),
            projectAlias: "g-p-remoteai", canonicalUrl: tab.canonicalUrl)
        store.sessions = [session]
        let now = Date()
        let wrongChat = WebConversationDescriptor(localConversationId: "webconv-other-chat",
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "seed-0",
            lastVisited: now, updatedAt: now)
        let wrongProject = WebConversationDescriptor(localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-photo", conversationAlias: "seed-0",
            lastVisited: now, updatedAt: now)
        let correctConversation = WebConversationDescriptor(localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "seed-0",
            lastVisited: now, updatedAt: now)
        let fixtures: [(String, [String: JSONValue])] = [
            ("wrong Chat", try enterFixture(tab: tab, conversation: wrongChat, project: nil,
                diagnosisState: "not-ready", issueCode: "CONVERSATION_IDENTITY_UNVERIFIED")),
            ("wrong Project", try enterFixture(tab: tab, conversation: wrongProject, project: nil,
                diagnosisState: "not-ready", issueCode: "CONVERSATION_IDENTITY_UNVERIFIED")),
            ("wrong tab", try enterFixture(tab: tab, conversation: correctConversation, project: nil,
                diagnosisState: "not-ready", issueCode: "CONVERSATION_IDENTITY_UNVERIFIED",
                receiptTabId: tab.tabId + 100, diagnosisTabId: tab.tabId + 100))
        ]

        for (identity, fixture) in fixtures {
            await mock.setEnteredOpenWebTabFixture(fixture)
            let destination = await store.enterOpenWebTab(tab)
            XCTAssertNil(destination, "An unverified diagnosis cannot open a receipt for a different \(identity)")
            XCTAssertEqual(store.webTabEntryStatusById[tab.id]?.code, "IDENTITY_RECEIPT_REJECTED")
            XCTAssertEqual(store.sessions, [session])
            XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId))
        }
        await store.suspend()
    }

    @MainActor
    func testUnverifiedEntryDoesNotAcceptUnknownUnboundChat() async throws {
        let mock = MockTransport(historyCount: 0)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let boundTab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(boundTab.sessionId)
        let unboundTab = OpenWebTab(tabId: boundTab.tabId, title: boundTab.title,
            canonicalUrl: boundTab.canonicalUrl, active: boundTab.active,
            loading: boundTab.loading, kind: boundTab.kind, sessionId: nil,
            busy: boundTab.busy)
        let unknownConversation = WebConversationDescriptor(localConversationId: sessionId,
            canonicalUrl: unboundTab.canonicalUrl, projectId: nil, displayTitle: unboundTab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "seed-0",
            lastVisited: Date(), updatedAt: Date())
        store.openWebTabs = [unboundTab]
        store.sessions = []
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: unboundTab,
            conversation: unknownConversation, project: nil, diagnosisState: "not-ready",
            issueCode: "CONVERSATION_IDENTITY_UNVERIFIED"))

        let destination = await store.enterOpenWebTab(unboundTab)

        XCTAssertNil(destination, "A new or unbound receipt cannot bypass page identity verification")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.webTabEntryStatusById[unboundTab.id]?.cachedSession)
        let attempts = await mock.actionAttemptCount("manageOpenWebTab")
        XCTAssertEqual(attempts, 1, "The server receipt is validated before the unbound case is rejected")
        await store.suspend()
    }

    @MainActor
    func testGeneratingEntryRemainsLiveAndWritable() async throws {
        let mock = MockTransport(historyCount: 0)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        let session = SessionDescriptor(id: sessionId, instanceId: "web.chatgpt",
            title: tab.title, state: .busy, updatedAt: Date(),
            projectAlias: "g-p-remoteai", canonicalUrl: tab.canonicalUrl)
        store.sessions = [session]
        let conversation = WebConversationDescriptor(localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "seed-0",
            lastVisited: Date(), updatedAt: Date())
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: conversation,
            project: nil, diagnosisState: "generating", diagnosisBusy: true))

        let destination = await store.enterOpenWebTab(tab)

        guard case .chat(let openedSession)? = destination else {
            await store.suspend()
            return XCTFail("A verified generating Chat should remain enterable")
        }
        XCTAssertEqual(openedSession.id, sessionId)
        XCTAssertEqual(store.webTabDiagnosesById[tab.id]?.state, "generating")
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId))
        XCTAssertTrue(ChatComposerSendAvailability.enabled(machineOnline: true, isWeb: true,
            sending: false, sessionUnavailable: false,
            readOnly: store.isCachedWebSessionReadOnly(sessionId)))
        await store.suspend()
    }

    @MainActor
    func testUnverifiedGeneratingReceiptOpensKnownDesktopChatWithoutLocalCatalogRow() async throws {
        let mock = MockTransport(historyCount: 0)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        let conversation = WebConversationDescriptor(localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "seed-0",
            lastVisited: Date(), updatedAt: Date())
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: conversation,
            project: nil, diagnosisState: "generating", diagnosisBusy: true,
            issueCode: "CONVERSATION_IDENTITY_UNVERIFIED",
            issueMessage: "Conversation identity is not verified."))

        let destination = await store.enterOpenWebTab(tab)

        guard case .chat(let openedSession)? = destination else {
            await store.suspend()
            return XCTFail("An exact persisted generating Chat should open without a local catalog row")
        }
        XCTAssertEqual(openedSession.id, sessionId)
        XCTAssertEqual(store.sessions.map(\.id), [sessionId],
            "The validated receipt may create the Chat's metadata row without importing messages")
        XCTAssertNil(store.messagesBySession[sessionId])
        XCTAssertEqual(store.webTabDiagnosesById[tab.id]?.state, "generating")
        XCTAssertEqual(store.webTabEntryStatusById[tab.id]?.code, "CONVERSATION_IDENTITY_UNVERIFIED")
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId),
            "The Chat remains writable through the Agent's independent send preflight")
        XCTAssertTrue(ChatComposerSendAvailability.enabled(machineOnline: true, isWeb: true,
            sending: false, sessionUnavailable: false,
            readOnly: store.isCachedWebSessionReadOnly(sessionId)))
        await store.suspend()
    }

    @MainActor
    func testVerifiedReceiptCannotReuseCachedSessionIdWithConflictingIdentity() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        store.sessions = [SessionDescriptor(
            id: sessionId,
            instanceId: "web.chatgpt",
            title: tab.title,
            state: .idle,
            updatedAt: Date(),
            projectAlias: "g-p-remoteai",
            canonicalUrl: "https://chatgpt.com/g/g-p-remoteai/c/a-different-chat"
        )]
        try await cache.upsertMessages([ChatMessage(
            id: "cached-conflicting-session-id",
            sessionId: sessionId,
            sequence: 1,
            role: .user,
            kind: .text,
            text: "must not be attached to the selected live Chat",
            createdAt: Date()
        )])
        let now = Date()
        let conversation = WebConversationDescriptor(
            localConversationId: sessionId,
            canonicalUrl: tab.canonicalUrl,
            projectId: nil,
            displayTitle: tab.title,
            projectAlias: "g-p-remoteai",
            conversationAlias: "seed-0",
            lastVisited: now,
            updatedAt: now
        )
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: conversation, project: nil))

        let destination = await store.enterOpenWebTab(tab)

        XCTAssertNil(destination, "A canonical identity collision must not load cached messages under the receipt")
        let issue = try XCTUnwrap(store.webTabEntryStatusById[tab.id])
        XCTAssertEqual(issue.code, "IDENTITY_RECEIPT_REJECTED")
        XCTAssertNil(issue.cachedSession)
        XCTAssertEqual(store.sessions.first?.canonicalUrl,
            "https://chatgpt.com/g/g-p-remoteai/c/a-different-chat",
            "The conflicting cached identity must remain untouched")
        await store.suspend()
    }

    @MainActor
    func testReadOnlyCachedHistoryBlocksDirectRecoveryAndClearsAfterExactInspection() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 1)
        try await mock.connect()
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tab = try XCTUnwrap(store.openWebTabs.first(where: \.isChat))
        let sessionId = try XCTUnwrap(tab.sessionId)
        store.sessions = [SessionDescriptor(
            id: sessionId,
            instanceId: "web.chatgpt",
            title: tab.title,
            state: .idle,
            updatedAt: Date(),
            projectAlias: "g-p-remoteai",
            canonicalUrl: tab.canonicalUrl
        )]
        try await cache.upsertMessages([ChatMessage(
            id: "cached-read-only-history",
            sessionId: sessionId,
            sequence: 1,
            role: .user,
            kind: .text,
            text: "read only",
            createdAt: Date()
        )])
        await mock.failNextAction("manageOpenWebTab")
        _ = await store.enterOpenWebTab(tab)
        _ = await store.openCachedWebTabHistory(tab)
        XCTAssertTrue(store.isCachedWebSessionReadOnly(sessionId))

        await store.recoverWebChat(sessionId, operation: "hardReload", expectedTabId: tab.tabId)
        await store.reopenClosedWebConversation(sessionId: sessionId)
        let manageAttemptsBeforeInspection = await mock.actionAttemptCount("manageOpenWebTab")
        XCTAssertEqual(manageAttemptsBeforeInspection, 1,
            "Only the original failed entry may reach manageOpenWebTab before live verification")
        let reopenAttemptsBeforeInspection = await mock.actionAttemptCount("resumeSession")
        XCTAssertEqual(reopenAttemptsBeforeInspection, 0)
        XCTAssertTrue(store.isCachedWebSessionReadOnly(sessionId))

        await mock.setOpenWebTabCurrentSessionOverride(tabId: tab.id, sessionId: "webconv-reused-session")
        await store.inspectOpenWebTab(tab)
        XCTAssertTrue(store.isCachedWebSessionReadOnly(sessionId),
            "A ready URL diagnosis cannot clear read-only mode when a fresh inventory shows a different session ID")
        let recycledTab = store.openWebTabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(recycledTab?.canonicalUrl, tab.canonicalUrl,
            "The recycled binding fixture keeps the same URL to exercise session-ID verification")
        XCTAssertEqual(recycledTab?.sessionId, "webconv-reused-session")

        await mock.setOpenWebTabCurrentSessionOverride(tabId: tab.id, sessionId: nil)
        await store.recoverWebChat(sessionId, operation: "inspect", expectedTabId: tab.tabId)
        XCTAssertFalse(store.isCachedWebSessionReadOnly(sessionId),
            "An explicit exact-session inspection may safely return the Chat to live mode")
        await store.suspend()
    }

    @MainActor
    func testEnterAndCloseSharePerTabExclusion() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        await mock.setResponseDelay(action: "manageOpenWebTab", nanoseconds: 300_000_000)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)

        let closeTask = Task { @MainActor in
            await store.manageOpenWebTab(tab, operation: "close")
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        let overlappingEnter = await store.enterOpenWebTab(tab)
        XCTAssertNil(overlappingEnter, "Enter must not race a close on the same Chrome tab ID")
        await closeTask.value

        let attempts = await mock.actionAttemptCount("manageOpenWebTab")
        XCTAssertEqual(attempts, 1)
        let isLocked = store.managingWebTabIds.contains(tab.id)
        XCTAssertFalse(isLocked)
    }

    @MainActor
    func testEnterAndInspectSharePerTabExclusion() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        await mock.setResponseDelay(action: "manageOpenWebTab", nanoseconds: 250_000_000)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)

        let enterTask = Task { @MainActor in await store.enterOpenWebTab(tab) }
        try await Task.sleep(nanoseconds: 40_000_000)
        await store.inspectOpenWebTab(tab)
        let inspectAttempts = await mock.actionAttemptCount("inspectOpenWebTab")
        XCTAssertEqual(inspectAttempts, 0, "A status probe must not overlap entry of the same tab")
        _ = await enterTask.value
    }

    @MainActor
    func testEntryResultIsDiscardedAfterLifecycleChanges() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        await mock.setResponseDelay(action: "manageOpenWebTab", nanoseconds: 250_000_000)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)

        let enterTask = Task { @MainActor in await store.enterOpenWebTab(tab) }
        try await Task.sleep(nanoseconds: 40_000_000)
        await store.suspend()
        let destination = await enterTask.value

        XCTAssertNil(destination, "A reply from the previous transport lifecycle cannot navigate")
        XCTAssertNil(store.webTabDiagnosesById[tab.id])
        XCTAssertFalse(store.managingWebTabIds.contains(tab.id))
    }

    @MainActor
    func testEnterRejectsReusedTabIdWithDifferentLiveChat() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)
        await mock.setOpenWebTabCurrentURLOverride(tabId: tab.id,
            canonicalUrl: "https://chatgpt.com/g/g-p-remoteai/c/reused-by-another-chat")

        do {
            _ = try await mock.enterOpenWebTab(machineId: "my-pc", tab: tab)
            XCTFail("A recycled tab ID cannot authorize the stale selected Chat")
        } catch let error as TransportError {
            guard case .remote(let code, _) = error else {
                return XCTFail("Expected a stale browser binding rejection")
            }
            XCTAssertEqual(code, "BROWSER_BINDING_MISSING")
        }
        let creates = await mock.actionAttemptCount("createConversation")
        XCTAssertEqual(creates, 0)
    }

    @MainActor
    func testEnterRejectsReusedTabIdWithDifferentSessionEvenWhenUrlMatches() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)
        await mock.setOpenWebTabCurrentSessionOverride(tabId: tab.id, sessionId: "webconv-reused-session")

        do {
            _ = try await mock.enterOpenWebTab(machineId: "my-pc", tab: tab)
            XCTFail("A recycled tab ID with a different session must not authorize the old Chat")
        } catch let error as TransportError {
            guard case .remote(let code, _) = error else {
                return XCTFail("Expected a stale session binding rejection")
            }
            XCTAssertEqual(code, "BROWSER_BINDING_MISSING")
        }
    }

    @MainActor
    func testEnterRejectsMalformedReceiptWithBothOrNeitherIdentity() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let tab = try XCTUnwrap(tabs.first)
        let now = Date()
        let conversation = WebConversationDescriptor(localConversationId: "webconv-existing",
            canonicalUrl: tab.canonicalUrl, projectId: nil, displayTitle: tab.title,
            projectAlias: "g-p-remoteai", conversationAlias: "mock-1", lastVisited: now, updatedAt: now)
        let project = WebProjectDescriptor(projectAlias: "g-p-remoteai", projectId: nil,
            displayName: "RemoteAI", canonicalUrl: "https://chatgpt.com/g/g-p-remoteai/project",
            lastSeenAt: now, lastOpenedAt: now)

        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: conversation, project: project))
        do {
            _ = try await mock.enterOpenWebTab(machineId: "my-pc", tab: tab)
            XCTFail("An entry receipt containing both Chat and Project must fail closed")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }

        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: tab, conversation: nil, project: nil))
        do {
            _ = try await mock.enterOpenWebTab(machineId: "my-pc", tab: tab)
            XCTFail("An entry receipt with neither identity must fail closed")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }
    }

    @MainActor
    func testEnterRejectsProjectIdentityFromAnotherTarget() async throws {
        let mock = MockTransport(historyCount: 0)
        try await mock.connect()
        let tabs = try await mock.listOpenWebTabs(machineId: "my-pc")
        let projectTab = try XCTUnwrap(tabs.last)
        let otherProject = WebProjectDescriptor(projectAlias: "g-p-photo", projectId: nil,
            displayName: "Photo SaaS", canonicalUrl: "https://chatgpt.com/g/g-p-photo/project",
            lastSeenAt: Date(), lastOpenedAt: nil)
        await mock.setEnteredOpenWebTabFixture(try enterFixture(tab: projectTab, conversation: nil, project: otherProject))

        do {
            _ = try await mock.enterOpenWebTab(machineId: "my-pc", tab: projectTab)
            XCTFail("A valid Project descriptor for a different alias must not be opened")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }
    }

    private func enterFixture(tab: OpenWebTab, conversation: WebConversationDescriptor?, project: WebProjectDescriptor?,
        diagnosisState: String = "ready", diagnosisBusy: Bool = false,
        issueCode: String? = nil, issueMessage: String? = nil, observedAt: Date? = nil,
        receiptTabId: Int? = nil, diagnosisTabId: Int? = nil) throws -> [String: JSONValue] {
        let returnedTabId = receiptTabId ?? tab.tabId
        var diagnosis: [String: JSONValue] = [
            "tabId": .number(Double(diagnosisTabId ?? returnedTabId)),
            "state": .string(diagnosisState),
            "canonicalUrl": .string(tab.canonicalUrl),
            "generating": .bool(diagnosisBusy),
            "busy": .bool(diagnosisBusy)
        ]
        if let issueCode { diagnosis["issueCode"] = .string(issueCode) }
        if let issueMessage { diagnosis["issueMessage"] = .string(issueMessage) }
        if let observedAt { diagnosis["observedAt"] = .string(RemoteAIDate.string(observedAt)) }
        var result: [String: JSONValue] = [
            "tabId": .number(Double(returnedTabId)),
            "diagnosis": .object(diagnosis)
        ]
        if let conversation { result["conversation"] = try JSONValue.encode(conversation) }
        if let project { result["project"] = try JSONValue.encode(project) }
        return result
    }
}
