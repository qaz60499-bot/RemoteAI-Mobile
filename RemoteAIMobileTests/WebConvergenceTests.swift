import XCTest
@testable import RemoteAIMobile

final class WebConvergenceTests: XCTestCase {
    @MainActor
    func testAuthoritativeProjectRemovalEvictsChildCacheButKeepsMessagesAndDraft() async throws {
        let alias = "g-p-remoteai"
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects(force: true)
        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        let row = try XCTUnwrap(store.projectConversationsByAlias[alias]?.first)
        let session = row.session
        let message = ChatMessage(
            id: "local-preserved-web-message",
            sessionId: session.id,
            sequence: 7,
            role: .user,
            kind: .text,
            text: "kept locally",
            createdAt: Date()
        )
        try await cache.upsertMessages([message])
        store.messagesBySession[session.id] = [message]
        await store.saveDraft("keep this draft", sessionId: session.id)

        // A shortened but explicitly partial directory is not deletion evidence.
        await mock.removeWebProject(alias: alias)
        await mock.setScenario(.partialWebCatalog)
        await store.refreshWebProjects(force: true)
        XCTAssertTrue(store.webProjects.contains { $0.projectAlias == alias })
        XCTAssertFalse(store.deletedWebSessionIds.contains(session.id))
        XCTAssertEqual(store.projectConversationsByAlias[alias]?.first?.id, row.id)

        // An explicitly empty partial directory is still not deletion evidence.
        await mock.setScenario(.emptyPartialWebCatalog)
        await store.refreshWebProjects(force: true)
        XCTAssertTrue(store.webProjects.contains { $0.projectAlias == alias })
        XCTAssertFalse(store.deletedWebSessionIds.contains(session.id))

        // The next complete directory snapshot confirms the Project removal.
        await mock.setScenario(.normal)
        await store.refreshWebProjects(force: true)
        XCTAssertFalse(store.webProjects.contains { $0.projectAlias == alias })
        XCTAssertNil(store.projectConversationsByAlias[alias])
        XCTAssertTrue(store.deletedWebSessionIds.contains(session.id))
        XCTAssertTrue(store.isWebSessionUnavailable(session))
        let removedProjection: [WebConversationDescriptor]? = try await cache.get(
            [WebConversationDescriptor].self,
            key: "web.project.\(alias).conversations"
        )
        XCTAssertNil(removedProjection)
        let preservedMessages = try await cache.recentMessages(sessionId: session.id, limit: 10)
        let preservedDraft = await store.draft(sessionId: session.id)
        XCTAssertEqual(preservedMessages.map(\.id), [message.id])
        XCTAssertEqual(preservedDraft, "keep this draft")

        let sendsBefore = await mock.actionAttemptCount("sendMessage")
        let sendId = UUID()
        let sent = await store.send(
            text: "must remain a draft",
            runtimeId: "runtime.web",
            instanceId: "web.chatgpt",
            sessionId: session.id,
            commandId: sendId
        )
        XCTAssertFalse(sent)
        let sendsAfter = await mock.actionAttemptCount("sendMessage")
        let blockedDraft = await store.draft(sessionId: session.id)
        XCTAssertEqual(sendsAfter, sendsBefore)
        XCTAssertEqual(blockedDraft, "must remain a draft")

        // A complete empty directory is still a durable proof of absence on cold start.
        await mock.removeWebProject(alias: "g-p-photo")
        await store.refreshWebProjects(force: true)
        XCTAssertTrue(store.webProjects.isEmpty)
        let hasCompleteDirectory: Bool? = try await cache.get(Bool.self, key: "web.projects.authoritative")
        XCTAssertEqual(hasCompleteDirectory, true)
        await store.suspend()

        let offlineStore = WorkspaceStore(transport: MockTransport(scenario: .offline), cache: cache)
        await offlineStore.start()
        XCTAssertTrue(offlineStore.isWebSessionUnavailable(session), "The empty complete directory must still block an old Project route after relaunch")
        let untaggedOldSession = SessionDescriptor(
            id: "not-in-tombstone-set",
            instanceId: "web.chatgpt",
            title: "Old Project chat",
            state: .idle,
            updatedAt: Date(),
            projectAlias: "g-p-photo",
            canonicalUrl: "https://chatgpt.com/g/g-p-photo/c/not-in-tombstone-set"
        )
        XCTAssertTrue(offlineStore.isWebSessionUnavailable(untaggedOldSession), "Directory authority must block a route even when its per-session tombstone is absent")
        await offlineStore.suspend()
    }

    @MainActor
    func testSessionDeletionSurvivesColdStartAndStaleReplayUntilCompleteReappearance() async throws {
        let alias = "g-p-remoteai"
        let sessionId = "webconv-seed-0"
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 3)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects(force: true)
        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        let row = try XCTUnwrap(store.projectConversationsByAlias[alias]?.first { $0.id == sessionId })
        let unknownCommandId = UUID()
        let cachedMessage = ChatMessage(
            id: unknownCommandId.uuidString,
            sessionId: sessionId,
            sequence: nil,
            role: .user,
            kind: .text,
            text: "delivery remains unknown",
            createdAt: Date()
        )
        try await cache.upsertMessages([cachedMessage])
        store.messagesBySession[sessionId] = [cachedMessage]
        store.commandStates[unknownCommandId] = .unknown
        await store.saveDraft("unknown draft", sessionId: sessionId)

        await mock.emitSessionDeleted(sessionId: sessionId)
        for _ in 0..<100 where !store.deletedWebSessionIds.contains(sessionId) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.deletedWebSessionIds.contains(sessionId))
        XCTAssertFalse(store.projectConversationsByAlias[alias, default: []].contains { $0.id == sessionId })
        XCTAssertEqual(store.messagesBySession[sessionId]?.map(\.id), [cachedMessage.id])
        let unknownDraft = await store.draft(sessionId: sessionId)
        XCTAssertEqual(unknownDraft, "unknown draft")
        XCTAssertEqual(store.commandStates[unknownCommandId], .unknown)
        let cachedMessages = try await cache.recentMessages(sessionId: sessionId, limit: 10)
        XCTAssertEqual(cachedMessages.map(\.id), [cachedMessage.id])

        let sendsBefore = await mock.actionAttemptCount("sendMessage")
        let statusChecksBefore = await mock.actionAttemptCount("getSessionStatus")
        await store.retry(message: cachedMessage, runtimeId: "runtime.web", instanceId: "web.chatgpt")
        await store.synchronizeVisibleSession(sessionId, force: true)
        let sendsAfterDeletion = await mock.actionAttemptCount("sendMessage")
        let statusChecksAfterDeletion = await mock.actionAttemptCount("getSessionStatus")
        XCTAssertEqual(sendsAfterDeletion, sendsBefore, "An Unknown command is not replayed after authoritative deletion")
        XCTAssertEqual(statusChecksAfterDeletion, statusChecksBefore, "A deleted route is not reopened by status recovery")
        XCTAssertEqual(store.commandStates[unknownCommandId], .unknown)
        await store.suspend()

        let staleMock = MockTransport(scenario: .staleWebCatalog, historyCount: 1)
        await staleMock.seedProjectConversations(alias: alias, count: 3)
        let relaunched = WorkspaceStore(transport: staleMock, cache: cache)
        await relaunched.start()
        await relaunched.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        XCTAssertTrue(relaunched.deletedWebSessionIds.contains(sessionId))
        XCTAssertFalse(relaunched.projectConversationsByAlias[alias, default: []].contains { $0.id == sessionId })

        // A partial page, even if it includes the old row, cannot clear a deletion.
        await staleMock.setScenario(.partialWebCatalog)
        await relaunched.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        XCTAssertTrue(relaunched.deletedWebSessionIds.contains(sessionId))
        XCTAssertFalse(relaunched.displayedProjectConversations(projectAlias: alias).contains { $0.id == sessionId })

        // Only a completed live snapshot can prove that the same stable ID reappeared.
        await staleMock.setScenario(.normal)
        await relaunched.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        XCTAssertFalse(relaunched.deletedWebSessionIds.contains(sessionId))
        XCTAssertTrue(relaunched.projectConversationsByAlias[alias, default: []].contains { $0.id == sessionId })
        await relaunched.suspend()
    }

    @MainActor
    func testSwitchingChatRejectsMismatchedStatusIdentityAndPreservesTranscriptAndDraft() async throws {
        let alias = "g-p-remoteai"
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects(force: true)
        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        let row = try XCTUnwrap(store.projectConversationsByAlias[alias]?.first)
        let session = row.session
        let cached = ChatMessage(
            id: "verified-local-history",
            sessionId: session.id,
            sequence: nil,
            role: .assistant,
            kind: .text,
            text: "keep this reply",
            createdAt: Date()
        )
        try await cache.upsertMessages([cached])
        store.messagesBySession[session.id] = [cached]
        await store.saveDraft("keep this draft", sessionId: session.id)
        await mock.setSessionStatusIdentityOverride(
            session.id,
            canonicalUrl: "https://chatgpt.com/g/other-project/c/different-chat",
            projectId: session.projectId,
            projectAlias: session.projectAlias
        )
        let historyReadsBefore = await mock.actionAttemptCount("loadRecentMessages")

        await store.synchronizeVisibleSession(session.id, force: true)

        let historyReadsAfter = await mock.actionAttemptCount("loadRecentMessages")
        XCTAssertEqual(historyReadsAfter, historyReadsBefore)
        XCTAssertEqual(store.messagesBySession[session.id]?.map(\.id), [cached.id])
        let preservedDraft = await store.draft(sessionId: session.id)
        XCTAssertEqual(preservedDraft, "keep this draft")
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.canonicalUrl, row.canonicalUrl)
        XCTAssertTrue(store.errors[session.id]?.contains("身份暂未验证") == true)
        await store.suspend()
    }

    @MainActor
    func testLegacyUnknownProjectIdCanBeBackfilledButKnownConflictStillRejectsHistory() async throws {
        let alias = "g-p-remoteai"
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects(force: true)
        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        let row = try XCTUnwrap(store.projectConversationsByAlias[alias]?.first)
        XCTAssertNil(row.projectId, "The fixture models a Build83 cache row without ProjectID")
        await mock.seedHistory(sessionId: row.id, messages: [
            ServerMessage(
                messageId: "legacy-project-id-recovered",
                sessionId: row.id,
                role: "assistant",
                content: "same exact conversation",
                externalId: nil,
                createdAt: Date()
            )
        ])
        await mock.setSessionStatusIdentityOverride(
            row.id,
            canonicalUrl: "https://chatgpt.com/g/g-p-remoteai-renamed/c/seed-0",
            projectId: "stable-project-id",
            projectAlias: alias
        )

        let historyReadsBefore = await mock.actionAttemptCount("loadRecentMessages")
        await store.synchronizeVisibleSession(row.id, force: true)

        let historyReadsAfterBackfill = await mock.actionAttemptCount("loadRecentMessages")
        XCTAssertEqual(historyReadsAfterBackfill, historyReadsBefore + 1)
        XCTAssertEqual(store.sessions.first(where: { $0.id == row.id })?.projectId, "stable-project-id")
        XCTAssertTrue(store.messagesBySession[row.id, default: []].contains { $0.id == "legacy-project-id-recovered" })

        await mock.setSessionStatusIdentityOverride(
            row.id,
            canonicalUrl: "https://chatgpt.com/g/g-p-remoteai-renamed/c/seed-0",
            projectId: "different-project-id",
            projectAlias: alias
        )
        await store.synchronizeVisibleSession(row.id, force: true)

        let historyReadsAfterConflict = await mock.actionAttemptCount("loadRecentMessages")
        XCTAssertEqual(historyReadsAfterConflict, historyReadsAfterBackfill, "A known ProjectID conflict must stop history from being fetched")
        XCTAssertTrue(store.errors[row.id]?.contains("身份暂未验证") == true)
        await store.suspend()
    }

    @MainActor
    func testRecentHistoryRejectsRowsForDifferentSessionAndRetriesWithoutMarkingFresh() async throws {
        let alias = "g-p-remoteai"
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: alias, count: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects(force: true)
        await store.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
        let row = try XCTUnwrap(store.projectConversationsByAlias[alias]?.first)
        let local = ChatMessage(
            id: "cached-before-mismatch",
            sessionId: row.id,
            sequence: nil,
            role: .user,
            kind: .text,
            text: "local history",
            createdAt: Date()
        )
        store.messagesBySession[row.id] = [local]
        let remote = ServerMessage(
            messageId: "server-message-one",
            sessionId: row.id,
            role: "assistant",
            content: "remote reply",
            externalId: nil,
            createdAt: Date()
        )
        await mock.seedHistory(sessionId: row.id, messages: [remote])
        await mock.setRecentMessageSessionIdOverride(requestedSessionId: row.id, responseSessionId: "another-session")

        await store.synchronizeVisibleSession(row.id, force: true)

        XCTAssertEqual(store.messagesBySession[row.id]?.map(\.id), [local.id])
        XCTAssertNotNil(store.errors[row.id])
        await mock.setRecentMessageSessionIdOverride(requestedSessionId: row.id, responseSessionId: nil)
        await store.synchronizeVisibleSession(row.id, force: true)
        XCTAssertTrue(store.messagesBySession[row.id, default: []].contains { $0.id == remote.messageId })
        XCTAssertNil(store.errors[row.id])
        await store.suspend()
    }

    @MainActor
    func testVerifiedRootTabEntryClearsOnlyItsExactDeletedSessionTombstone() async throws {
        let sessionId = "root-chat-reappeared"
        let canonicalUrl = "https://chatgpt.com/c/\(sessionId)"
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        store.sessions.append(SessionDescriptor(
            id: sessionId,
            instanceId: "web.chatgpt",
            title: "Root Chat",
            state: .idle,
            updatedAt: Date(),
            canonicalUrl: canonicalUrl
        ))
        await mock.emitSessionDeleted(sessionId: sessionId)
        for _ in 0..<100 where !store.deletedWebSessionIds.contains(sessionId) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.deletedWebSessionIds.contains(sessionId))

        let conversation = WebConversationDescriptor(
            localConversationId: sessionId,
            canonicalUrl: canonicalUrl,
            projectId: nil,
            displayTitle: "Root Chat",
            projectAlias: nil,
            conversationAlias: sessionId,
            lastVisited: Date(),
            updatedAt: Date()
        )
        let fixture: [String: JSONValue] = [
            "tabId": .number(22),
            "conversation": try JSONValue.encode(conversation),
            "diagnosis": .object([
                "tabId": .number(22),
                "state": .string("ready"),
                "canonicalUrl": .string(canonicalUrl),
                "generating": .bool(false),
                "composerReady": .bool(true),
                "draftPresent": .bool(false),
                "pendingUploads": .bool(false),
                "busy": .bool(false)
            ])
        ]
        await mock.setEnteredOpenWebTabFixture(fixture)
        let tab = OpenWebTab(
            tabId: 22,
            title: "Root Chat",
            canonicalUrl: canonicalUrl,
            active: true,
            loading: false,
            kind: "conversation",
            sessionId: sessionId,
            busy: false
        )

        let destination = await store.enterOpenWebTab(tab)

        guard case .chat(let restored)? = destination else {
            XCTFail("The exact verified root Chat should open")
            await store.suspend()
            return
        }
        XCTAssertEqual(restored.id, sessionId)
        XCTAssertFalse(store.deletedWebSessionIds.contains(sessionId))
        XCTAssertFalse(store.isWebSessionUnavailable(restored))
        await store.suspend()
    }
}
