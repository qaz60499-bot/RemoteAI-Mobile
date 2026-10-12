import XCTest
@testable import RemoteAIMobile

@MainActor
final class WebTabTests: XCTestCase {
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
