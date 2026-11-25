import XCTest
@testable import RemoteAIMobile

final class CLIMobileTests: XCTestCase {
    @MainActor
    func testSparseCLICacheDoesNotSkipMiddleHistoryOrSameTimestampRows() async throws {
        let mock = MockTransport(historyCount: 0)
        let cache = try SQLiteStore.inMemory()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = (0..<135).map { i in
            ServerMessage(messageId: String(format: "cli-msg-%04d", i), sessionId: "codex6-a",
                          role: i.isMultiple(of: 2) ? "user" : "assistant", content: "row \(i)",
                          externalId: nil, createdAt: date)
        }
        for row in rows { await mock.appendHistoryMessage(row) }
        // Reproduces the physical phone: oldest live events plus a recent page.
        try await cache.upsertMessages([rows[0].chatMessage, rows[17].chatMessage])
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let runtime = try XCTUnwrap(store.runtimes.first { $0.id == "runtime.codex" })
        await store.refreshRuntime(runtime)
        let instance = try XCTUnwrap(store.instances.first { $0.id == "codex.6" })
        await store.refreshSessions(runtime: runtime, instance: instance)
        await store.loadSession("codex6-a")
        for _ in 0..<3 { await store.loadOlder("codex6-a") }
        let actual = store.messagesBySession["codex6-a", default: []]
        XCTAssertEqual(actual.map(\.id), rows.map(\.messageId))
        XCTAssertEqual(Set(actual.map(\.id)).count, 135)
        XCTAssertEqual(store.hasMoreBySession["codex6-a"], false)
        await store.loadSession("codex6-a")
        XCTAssertEqual(store.messagesBySession["codex6-a"]?.count, 135)
        await store.suspend()
    }

    func testHistoricalCLIToolKeepsCanonicalIdentityTimeAndDetails() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let content = #"{"type":"function_call_output","call_id":"call-1","output":"done"}"#
        let message = ServerMessage(messageId: "cli-tool-123", sessionId: "observed",
                                    role: "tool", content: content, externalId: nil, createdAt: at).chatMessage
        XCTAssertEqual(message.id, "cli-tool-123")
        XCTAssertEqual(message.createdAt, at)
        XCTAssertEqual(message.kind, .toolEvent)
        XCTAssertEqual(message.detail, content)
        XCTAssertEqual(message.toolStatus, "Recorded")
    }

    func testClaudeRuntimeAndDistinctStates() throws {
        XCTAssertEqual(RuntimeKind(rawValue: "CloudCode")?.displayName, "Claude Code")
        XCTAssertEqual(CLIStateLabel.text("running"), "执行中")
        XCTAssertEqual(CLIStateLabel.text("initializing"), "正在初始化")
        XCTAssertEqual(CLIStateLabel.text("waiting_approval"), "等待审批")
        XCTAssertEqual(CLIStateLabel.text("rate_limited"), "请求限流")
        XCTAssertEqual(CLIStateLabel.text("calling_tool"), "正在调用工具")
        XCTAssertEqual(CLIStateLabel.text("stopped"), "已停止")
        XCTAssertEqual(CLIStateLabel.text("process_exited"), "CLI 进程已退出")
        XCTAssertEqual(CLIStateLabel.text("recovery_pending"), "等待新指令验证恢复")
        XCTAssertEqual(CLIStateLabel.text(nil), "状态未知")
    }

    func testCLIProtocolKeepsStrictActionsAndExistingWeb() throws {
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("respondApproval"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("configureSession"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("listCLIUpstreams"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("saveCLIUpstream"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("deleteCLIUpstream"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("recoverCLISession"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("getCommandOutcome"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("registerCurrentPage"))
        XCTAssertTrue(ProtocolSecurity.eventTypes.contains("CLI_STATUS"))
        XCTAssertFalse(ProtocolSecurity.commandActions.contains("killProcess"))
    }

    func testCommandOutcomePassesProtocolValidation() throws {
        let command = RemoteCommand.make(
            machineId: "machine-1",
            runtimeId: "runtime.codex",
            instanceId: "codex.remoteai",
            action: "getCommandOutcome",
            payload: ["commandId": .string(UUID().uuidString)]
        )

        XCTAssertNoThrow(try ProtocolSecurity.validate(command, expectedMachineId: "machine-1"))
    }

    func testUpstreamUsesHostAndWindowsCredentialAvailability() throws {
        let data = Data(#"{"id":"configured","label":"Windows","host":"provider.example","models":["configured-model"],"defaultModel":"configured-model","credentialAvailable":true,"health":"unknown"}"#.utf8)
        let upstream = try JSONDecoder().decode(CLIUpstream.self, from: data)
        XCTAssertEqual(upstream.host, "provider.example")
        XCTAssertTrue(upstream.credentialAvailable)
        XCTAssertEqual(upstream.models, ["configured-model"])
    }

    func testUpstreamManagementMetadataIsOptionalForOlderAgents() throws {
        let data = Data(#"{"id":"configured","label":"Windows","host":"provider.example","models":["configured-model"],"defaultModel":"configured-model","credentialAvailable":true,"health":"unknown"}"#.utf8)
        let upstream = try JSONDecoder().decode(CLIUpstream.self, from: data)

        XCTAssertNil(upstream.source)
        XCTAssertNil(upstream.editable)
        XCTAssertNil(upstream.removable)
        XCTAssertNil(upstream.availabilityReason)
        XCTAssertFalse(upstream.canEdit)
        XCTAssertFalse(upstream.canRemove)
    }

    func testRemoteAIOwnedUpstreamMetadataEnablesManagement() throws {
        let data = Data(#"{"id":"custom-provider","label":"Private","host":"provider.example","models":["model-a"],"defaultModel":"model-a","credentialAvailable":true,"health":"unknown","source":"remoteai","editable":true,"removable":true}"#.utf8)
        let upstream = try JSONDecoder().decode(CLIUpstream.self, from: data)

        XCTAssertEqual(upstream.source, "remoteai")
        XCTAssertTrue(upstream.canEdit)
        XCTAssertTrue(upstream.canRemove)
    }

    func testImportedUpstreamCanOnlyBeRemovedWhenExplicitlyRemovable() throws {
        let data = Data(#"{"id":"imported-provider","label":"Windows provider","host":"provider.example","models":["model-a"],"defaultModel":"model-a","credentialAvailable":false,"health":"unknown","source":"discovered","editable":true,"removable":true,"availabilityReason":"session-scoped credential cannot be reused"}"#.utf8)
        let upstream = try JSONDecoder().decode(CLIUpstream.self, from: data)

        XCTAssertEqual(upstream.availabilityReason, "session-scoped credential cannot be reused")
        XCTAssertFalse(upstream.canEdit)
        XCTAssertTrue(upstream.canRemove)
    }
}
