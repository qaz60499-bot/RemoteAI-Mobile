import XCTest
@testable import RemoteAIMobile

final class WebTabEntryTests: XCTestCase {
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
        diagnosisState: String = "ready", diagnosisBusy: Bool = false) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "tabId": .number(Double(tab.tabId)),
            "diagnosis": .object([
                "tabId": .number(Double(tab.tabId)),
                "state": .string(diagnosisState),
                "canonicalUrl": .string(tab.canonicalUrl),
                "generating": .bool(diagnosisBusy),
                "busy": .bool(diagnosisBusy)
            ])
        ]
        if let conversation { result["conversation"] = try JSONValue.encode(conversation) }
        if let project { result["project"] = try JSONValue.encode(project) }
        return result
    }
}
