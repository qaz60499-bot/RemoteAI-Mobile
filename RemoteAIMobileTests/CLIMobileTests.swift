import XCTest
@testable import RemoteAIMobile

final class CLIMobileTests: XCTestCase {
    func testLargeCLIToolPagesCrossRelayLimitWithoutLosingHistory() async throws {
        let mock = MockTransport(historyCount: 0)
        let transport = BoundedCLIHistoryTransport(base: mock)
        try await transport.connect()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = (0..<55).map { index in
            ServerMessage(messageId: String(format: "cli-tool-%04d", index), sessionId: "large-cli",
                          role: "tool", content: String(repeating: "large command output ", count: 550) + "\(index)",
                          externalId: nil, createdAt: at)
        }
        for row in rows { await mock.appendHistoryMessage(row) }
        var page = try await transport.loadRecent(machineId: "my-pc", runtimeId: "runtime.codex", instanceId: "codex.6", sessionId: "large-cli", limit: 50)
        var received = page.items
        var pages = 1
        while page.hasMore && pages < 12 {
            let cursor = try XCTUnwrap(page.beforeCursor)
            page = try await transport.loadBefore(machineId: "my-pc", runtimeId: "runtime.codex", instanceId: "codex.6", sessionId: "large-cli", before: cursor, limit: 40)
            received = page.items + received
            pages += 1
        }
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(received.map(\.id), rows.map(\.messageId))
        XCTAssertEqual(received.map(\.text), rows.map(\.content))
        XCTAssertEqual(Set(received.map(\.id)).count, rows.count)
        let rejected = await transport.rejectedPages
        XCTAssertGreaterThan(rejected, 0)
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testCLIHistoryReadDoesNotRetryDisconnectionOrWebErrors() async throws {
        for (runtime, failure) in [("runtime.codex", TransportError.disconnected), ("runtime.codex", .timeout), ("runtime.codex", .malformedData), ("runtime.web", .remote("INTERNAL_ERROR", "Internal error"))] {
            let transport = BoundedCLIHistoryTransport(base: MockTransport(historyCount: 0), failure: failure)
            do {
                _ = try await transport.loadRecent(machineId: "my-pc", runtimeId: runtime, instanceId: "codex.6", sessionId: "large-cli", limit: 50)
                XCTFail("Expected read failure")
            } catch { XCTAssertEqual(error as? TransportError, failure) }
            let attempts = await transport.readAttempts
            XCTAssertEqual(attempts, 1)
        }
    }

    func testSingleOversizedCLIRecordTerminatesBoundedRead() async throws {
        let transport = BoundedCLIHistoryTransport(base: MockTransport(historyCount: 0), failure: .remote("INTERNAL_ERROR", "Internal error"))
        do {
            _ = try await transport.loadRecent(machineId: "my-pc", runtimeId: "runtime.cloudcode", instanceId: "cloudcode.remoteai", sessionId: "large-cli", limit: 100)
            XCTFail("Expected oversized record failure")
        } catch { XCTAssertEqual(error as? TransportError, .remote("INTERNAL_ERROR", "Internal error")) }
        let attempts = await transport.readAttempts
        XCTAssertEqual(attempts, 7)
    }

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

private actor BoundedCLIHistoryTransport: Transport {
    let base: MockTransport
    let failure: TransportError?
    private(set) var rejectedPages = 0
    private(set) var readAttempts = 0
    private(set) var writeCount = 0
    init(base: MockTransport, failure: TransportError? = nil) { self.base = base; self.failure = failure }
    var isConnected: Bool { get async { await base.isConnected } }
    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func eventStream() async -> AsyncStream<RemoteEvent> { await base.eventStream() }
    func healthStream() async -> AsyncStream<TransportHealthEvent> { await base.healthStream() }
    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        let historyRead = ["loadRecentMessages", "loadMessagesBefore"].contains(command.action)
        if historyRead {
            readAttempts += 1
            if let failure { throw failure }
        } else { writeCount += 1 }
        let response = try await base.execute(command)
        if historyRead {
            let payload = JSONValue.object(["kind": .string("commandResponse"), "commandId": .string(command.commandId.uuidString), "response": try JSONValue.encode(response)])
            let plaintextBytes = try JSONEncoder.remoteAI.encode(payload).count
            let encryptedFrameBytes = ((plaintextBytes + 2) / 3) * 4 + 1024
            if encryptedFrameBytes > 256 * 1024 {
                rejectedPages += 1
                return CommandResponseEnvelope(ok: false, result: nil,
                    error: RemoteErrorPayload(code: "INTERNAL_ERROR", message: "Internal error", retryable: false, details: nil),
                    idempotentReplay: nil)
            }
        }
        return response
    }
}
