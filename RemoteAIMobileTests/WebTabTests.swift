import XCTest
@testable import RemoteAIMobile

@MainActor
final class WebTabTests: XCTestCase {
    private func inventoryRow(
        id: Int,
        title: String,
        url: String,
        conversationId: String? = nil,
        sessionId: String? = nil,
        projectId: String? = nil,
        projectAlias: String? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "tabId": id,
            "title": title,
            "canonicalUrl": url,
            "active": true,
            "loading": false,
            "kind": "root-conversation",
            "busy": false
        ]
        row["conversationId"] = conversationId
        row["sessionId"] = sessionId
        row["projectId"] = projectId
        row["projectAlias"] = projectAlias
        return row
    }

    private func inventoryJSON(_ rows: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private final class TabTransport: Transport {
        var inventoryFails = false
        var inspectionFails = false
        var delay: UInt64 = 0
        var commands: [RemoteCommand] = []
        var rows = "[{\"tabId\":7,\"title\":\"Existing Chat\",\"canonicalUrl\":\"https://chatgpt.com/c/stable-chat\",\"active\":true,\"loading\":false,\"kind\":\"root-conversation\",\"sessionId\":\"webconv-stable-chat\",\"busy\":false,\"conversationId\":\"stable-chat\",\"projectAlias\":\"g-p-0123456789abcdef0123456789abcdef\",\"projectTitle\":\"Verified Project\"}]"
        var isConnected: Bool { get async { true } }
        func connect() async throws {}
        func disconnect() async {}
        func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { $0.finish() } }
        func healthStream() async -> AsyncStream<TransportHealthEvent> { AsyncStream { $0.finish() } }
        func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
            // The outer XCTestCase does not isolate a nested type in Swift 5.
            // Check before touching shared state so the regression fails safely.
            guard Thread.isMainThread else {
                XCTFail("TAB_TRANSPORT_EXECUTOR: execute must stay on MainActor")
                throw TransportError.malformedData
            }
            commands.append(command)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            let value: String
            switch command.action {
            case "listOpenWebTabs":
                if inventoryFails { throw TransportError.timeout }
                value = rows
            case "inspectOpenWebTab":
                if inspectionFails { throw TransportError.timeout }
                value = "{\"tabId\":7,\"state\":\"ready\",\"observedAt\":\"2026-10-12T12:00:00Z\"}"
            case "manageOpenWebTab":
                value = "{\"tabId\":7,\"diagnosis\":{\"tabId\":7,\"state\":\"ready\"},\"conversation\":{\"localConversationId\":\"webconv-stable-chat\",\"canonicalUrl\":\"https://chatgpt.com/g/g-p-0123456789abcdef0123456789abcdef/c/stable-chat\",\"displayTitle\":\"Existing Chat\",\"projectAlias\":\"g-p-0123456789abcdef0123456789abcdef\",\"conversationAlias\":\"stable-chat\",\"updatedAt\":\"2026-10-12T12:00:00Z\"}}"
            default: throw TransportError.malformedData
            }
            return CommandResponseEnvelope(ok: true, result: try JSONDecoder.remoteAI.decode(JSONValue.self, from: Data(value.utf8)), error: nil, idempotentReplay: nil)
        }
    }

    func testTransportConcurrentCallsAndCancellationStayOnMainActor() async throws {
        let transport = TabTransport()
        transport.delay = 1_000_000
        let commands = (0..<65).map { _ in
            RemoteCommand(protocolVersion: 1, commandId: UUID(), machineId: "my-pc",
                runtimeId: "runtime.web", instanceId: "web-main", sessionId: nil,
                action: "listOpenWebTabs", payload: [:], createdAt: Date())
        }
        // Cancellation occurs before this MainActor task can start. The recorded
        // command survives; its suspended execution must throw CancellationError.
        let cancelled = Task { try await transport.execute(commands[0]) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled execution unexpectedly completed")
        } catch is CancellationError {
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for command in commands.dropFirst() {
                group.addTask { _ = try await transport.execute(command) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(transport.commands.count, commands.count)
        XCTAssertEqual(Set(transport.commands.map(\.commandId)), Set(commands.map(\.commandId)))
        XCTAssertEqual(transport.commands.first?.commandId, commands[0].commandId)
    }

    func testInventoryFailureRetainsConfirmedTabsAndDoesNotDeclareClosure() async throws {
        let transport = TabTransport()
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()
        XCTAssertEqual(store.openWebTabs.count, 1)
        transport.inventoryFails = true
        await store.refreshOpenWebTabs()
        XCTAssertTrue(store.openWebTabsQueryFailed)
        XCTAssertEqual(store.openWebTabs.count, 1)
        XCTAssertTrue(store.closedWebTabs.isEmpty)
        transport.inventoryFails = false
        transport.rows = "[]"
        await store.refreshOpenWebTabs()
        XCTAssertFalse(store.openWebTabsQueryFailed)
        XCTAssertTrue(store.openWebTabs.isEmpty)
        XCTAssertEqual(store.closedWebTabs.first?.sessionId, "webconv-stable-chat")
    }

    func testAuthoritativeInventoryWithNewTabIDKeepsSameChatOpenWithoutSessionId() async throws {
        let transport = TabTransport()
        let chatURL = "https://chatgpt.com/c/stable-chat"
        transport.rows = inventoryJSON([
            inventoryRow(id: 502_907_201, title: "Exactline reply", url: chatURL, conversationId: "stable-chat")
        ])
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online

        await store.refreshOpenWebTabs()
        XCTAssertEqual(store.openWebTabs.map(\.id), [502_907_201])
        XCTAssertNil(store.openWebTabs.first?.sessionId)

        transport.rows = inventoryJSON([
            inventoryRow(id: 502_907_460, title: "Exactline reply", url: chatURL, conversationId: "stable-chat")
        ])
        await store.refreshOpenWebTabs()

        XCTAssertEqual(store.openWebTabs.map(\.id), [502_907_460])
        XCTAssertTrue(store.closedWebTabs.isEmpty)
        XCTAssertTrue(store.recentWebTabNotices.isEmpty)
    }

    func testConfirmedClosureIsRetainedUntilSameConversationReopensWithNewTabID() async throws {
        let transport = TabTransport()
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online

        await store.refreshOpenWebTabs()
        transport.rows = "[]"
        await store.refreshOpenWebTabs()
        XCTAssertEqual(store.closedWebTabs.map(\.id), [7])

        transport.rows = inventoryJSON([
            inventoryRow(
                id: 460,
                title: "Existing Chat",
                url: "https://chatgpt.com/g/g-p-0123456789abcdef0123456789abcdef/c/stable-chat",
                conversationId: "stable-chat",
                projectAlias: "g-p-0123456789abcdef0123456789abcdef"
            )
        ])
        await store.refreshOpenWebTabs()

        XCTAssertEqual(store.openWebTabs.map(\.id), [460])
        XCTAssertTrue(store.closedWebTabs.isEmpty)
        XCTAssertFalse(store.recentWebTabNotices.contains(where: { $0.isClosure }))
    }

    func testSameConversationInDifferentKnownProjectsRemainsASeparateClosedTab() async throws {
        let transport = TabTransport()
        let chatURL = "https://chatgpt.com/g/g-p-0123456789abcdef0123456789abcdef/c/stable-chat"
        transport.rows = inventoryJSON([
            inventoryRow(
                id: 7,
                title: "Project A chat",
                url: chatURL,
                conversationId: "stable-chat",
                projectId: "project-a",
                projectAlias: "g-p-0123456789abcdef0123456789abcdef"
            )
        ])
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()

        transport.rows = inventoryJSON([
            inventoryRow(
                id: 460,
                title: "Project B chat",
                url: chatURL,
                conversationId: "stable-chat",
                projectId: "project-b",
                projectAlias: "g-p-0123456789abcdef0123456789abcdef"
            )
        ])
        await store.refreshOpenWebTabs()

        XCTAssertEqual(store.openWebTabs.map(\.id), [460])
        XCTAssertEqual(store.closedWebTabs.map(\.id), [7])
        XCTAssertEqual(store.closedWebTabs.first?.title, "Project A chat")
    }

    func testDifferentConversationIdentityInSameProjectIsNotMerged() async throws {
        let transport = TabTransport()
        let projectAlias = "g-p-0123456789abcdef0123456789abcdef"
        transport.rows = inventoryJSON([
            inventoryRow(
                id: 7,
                title: "First chat",
                url: "https://chatgpt.com/g/\(projectAlias)/c/first-chat",
                conversationId: "first-chat",
                projectAlias: projectAlias
            )
        ])
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()

        transport.rows = inventoryJSON([
            inventoryRow(
                id: 460,
                title: "Second chat",
                url: "https://chatgpt.com/g/\(projectAlias)/c/second-chat",
                conversationId: "second-chat",
                projectAlias: projectAlias
            )
        ])
        await store.refreshOpenWebTabs()

        XCTAssertEqual(store.openWebTabs.map(\.id), [460])
        XCTAssertEqual(store.closedWebTabs.map(\.id), [7])
    }

    func testAliasOnlyAndProjectIdOnlyMetadataMatchTheSameProject() async throws {
        let transport = TabTransport()
        let chatURL = "https://chatgpt.com/c/stable-chat"
        transport.rows = inventoryJSON([
            inventoryRow(
                id: 7,
                title: "Project chat",
                url: chatURL,
                conversationId: "stable-chat",
                projectAlias: "g-p-0123456789abcdef0123456789abcdef"
            )
        ])
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()

        transport.rows = inventoryJSON([
            inventoryRow(
                id: 460,
                title: "Project chat",
                url: chatURL,
                conversationId: "stable-chat",
                projectId: "01234567-89ab-cdef-0123-456789abcdef"
            )
        ])
        await store.refreshOpenWebTabs()

        XCTAssertEqual(store.openWebTabs.map(\.id), [460])
        XCTAssertTrue(store.closedWebTabs.isEmpty)
    }

    func testCanonicalProjectURLPreventsMergingDifferentProjectsWithoutMetadata() async throws {
        let transport = TabTransport()
        transport.rows = inventoryJSON([
            inventoryRow(
                id: 7,
                title: "Project A chat",
                url: "https://chatgpt.com/g/g-p-0123456789abcdef0123456789abcdef/c/stable-chat",
                conversationId: "stable-chat"
            )
        ])
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()

        transport.rows = inventoryJSON([
            inventoryRow(
                id: 460,
                title: "Project B chat",
                url: "https://chatgpt.com/g/g-p-fedcba9876543210fedcba9876543210/c/stable-chat",
                conversationId: "stable-chat"
            )
        ])
        await store.refreshOpenWebTabs()

        XCTAssertEqual(store.openWebTabs.map(\.id), [460])
        XCTAssertEqual(store.closedWebTabs.map(\.id), [7])
    }

    func testInventoryFailurePreservesPreviouslyConfirmedClosedCards() async throws {
        let transport = TabTransport()
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        await store.refreshOpenWebTabs()

        transport.rows = "[]"
        await store.refreshOpenWebTabs()
        XCTAssertEqual(store.closedWebTabs.map(\.id), [7])

        transport.rows = inventoryJSON([
            inventoryRow(id: 8, title: "Another chat", url: "https://chatgpt.com/c/other-chat", conversationId: "other-chat")
        ])
        await store.refreshOpenWebTabs()
        transport.inventoryFails = true
        await store.refreshOpenWebTabs()

        XCTAssertTrue(store.openWebTabsQueryFailed)
        XCTAssertEqual(store.openWebTabs.map(\.id), [8])
        XCTAssertEqual(store.closedWebTabs.map(\.id), [7])
    }

    func testConcurrentRefreshesIssueOneInventoryRequest() async throws {
        let transport = TabTransport()
        transport.delay = 30_000_000
        let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
        store.machine.state = .online
        let first = Task { await store.refreshOpenWebTabs() }
        let second = Task { await store.refreshOpenWebTabs() }
        await first.value
        await second.value
        XCTAssertEqual(transport.commands.filter { $0.action == "listOpenWebTabs" }.count, 1)
    }

    func testEntryUsesSelectedTabAndRetainsVerifiedProjectSession() async throws {
        let transport = TabTransport()
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine.state = .online
        let tabs = try await transport.listOpenWebTabs(machineId: "my-pc")
        XCTAssertEqual(tabs[0].pageType, "Project 内 Chat")
        let first = await store.enterOpenWebTab(tabs[0])
        let second = await store.enterOpenWebTab(tabs[0])
        XCTAssertEqual(first?.conversation?.id, second?.conversation?.id)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].projectAlias, tabs[0].projectAlias)
        let entries = transport.commands.filter { $0.action == "manageOpenWebTab" }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.payload["operation"]?.stringValue == "enter" && $0.payload["tabId"]?.intValue == 7 })
        XCTAssertFalse(transport.commands.contains { ["createConversation", "openConversation"].contains($0.action) })
    }

    func testOlderTabWireShapeDecodesWithoutInventingProjectIdentity() throws {
        let json = "{\"tabId\":7,\"title\":\"Chat\",\"canonicalUrl\":\"https://chatgpt.com/c/stable-chat\",\"active\":true,\"loading\":false,\"kind\":\"root-conversation\",\"busy\":false}"
        let tab = try JSONDecoder.remoteAI.decode(OpenWebTab.self, from: Data(json.utf8))
        XCTAssertEqual(tab.pageType, "普通 Chat")
        XCTAssertNil(tab.projectAlias)
        XCTAssertNil(tab.sessionId)
    }
}
