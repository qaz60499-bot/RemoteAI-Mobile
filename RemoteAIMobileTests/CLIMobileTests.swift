import XCTest
@testable import RemoteAIMobile

final class CLIMobileTests: XCTestCase {
    func testCLIDirectoryKeepsSubtasksAndExitedHistoryOutOfCurrentProcesses() {
        let current: [String: JSONValue] = ["pid": .number(1776), "stale": .bool(false), "sessionScope": .string("current"), "processAlive": .bool(true)]
        XCTAssertEqual(CLISessionDirectory.section(current), .current)
        XCTAssertEqual(CLISessionDirectory.section(current.merging(["sessionScope": .string("subtask"), "nativeRole": .string("subtask")]) { _, new in new }), .subtask)
        XCTAssertEqual(CLISessionDirectory.section(current.merging(["sessionScope": .string("related")]) { _, new in new }), .related)
        XCTAssertEqual(CLISessionDirectory.section(current.merging(["cliState": .string("process_exited")]) { _, new in new }), .history)
        XCTAssertEqual(CLISessionDirectory.section(["controlMode": .string("managed"), "pid": .null]), .history)
        XCTAssertEqual(CLISessionDirectory.section(current.merging(["stale": .bool(true)]) { _, new in new }), .history)
    }
    @MainActor
    func testCLIListReplacesStaleProcessCacheAndRejectsOlderStatusReplay() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let old: [String: JSONValue] = ["cliMobile": .bool(true), "cliState": .string("running"), "pid": .number(100), "controlMode": .string("read-only"), "lastObservedAt": .string("2026-11-27T10:00:00Z")]
        let fresh: [String: JSONValue] = ["cliMobile": .bool(true), "cliState": .string("completed"), "pid": .null, "controlMode": .string("managed"), "lastObservedAt": .string("2026-11-27T11:00:00Z")]
        let transport = CLISnapshotTransport(metadata: fresh, at: at)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine.state = .online
        let runtime = RuntimeDescriptor(id: "runtime.cloudcode", machineId: "my-pc", kind: .cloudcode, name: "Claude")
        let instance = InstanceDescriptor(id: "cloudcode.remoteai", runtimeId: runtime.id, name: "CLI", subtitle: nil)
        store.cliStatus["snapshot-session"] = old
        await store.refreshSessions(runtime: runtime, instance: instance)
        XCTAssertEqual(store.cliStatus["snapshot-session"], fresh)
        XCTAssertEqual(store.sessions.first?.cliMetadata, fresh)
        let saved = try await cache.get([String: JSONValue].self, key: "cli.status.snapshot-session")
        XCTAssertEqual(saved, fresh)
        await transport.setMetadata(old)
        _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: "snapshot-session", action: "getSessionStatus")
        XCTAssertEqual(store.cliStatus["snapshot-session"], fresh)
        await store.refreshSessions(runtime: runtime, instance: instance)
        XCTAssertEqual(store.cliStatus["snapshot-session"], fresh)
        XCTAssertEqual(store.sessions.first?.cliMetadata, fresh)
    }
    @MainActor
    func testCLIErrorSeparatesAgentOfflineFromRelayAndProvider() async throws {
        let cases: [(TransportError, String)] = [(.offline, "windows-agent"), (.disconnected, "relay"), (.remote("HTTP_503", "upstream unavailable"), "model-api")]
        for (error, source) in cases {
            let transport = CLIReceiptTransport(status: "FAILED", queryError: error)
            let store = WorkspaceStore(transport: transport, cache: try SQLiteStore.inMemory())
            store.machine.state = .online
            let runtime = RuntimeDescriptor(id: "runtime.codex", machineId: "my-pc", kind: .codex, name: "Codex")
            let instance = InstanceDescriptor(id: "codex.remoteai", runtimeId: runtime.id, name: "CLI", subtitle: nil)
            _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: "s", action: "getSessionStatus")
            XCTAssertEqual(store.cliErrorHistoryBySession["s"]?.last?.source, source)
        }
    }
    func testCLIReconnectQueriesReceiptBeforeAnySubmission() async throws {
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.codex", instanceId: "codex.remoteai", sessionId: "s", action: "sendMessage", payload: ["text": .string("once")])
        for status in ["COMPLETED", "RUNNING", "UNKNOWN_DELIVERY", "NOT_FOUND"] {
            let transport = CLIReceiptTransport(status: status)
            let state = try await transport.reconcileCLISend(command)
            let actions = await transport.actions
            XCTAssertEqual(actions.first, "getCommandOutcome")
            XCTAssertEqual(actions.filter { $0 == "sendMessage" }.count, status == "NOT_FOUND" ? 1 : 0)
            XCTAssertEqual(state, ["RUNNING", "UNKNOWN_DELIVERY"].contains(status) ? .unknown : .completed)
            let submittedID = await transport.submittedID
            if status == "NOT_FOUND" { XCTAssertEqual(submittedID, command.commandId) }
        }
    }

    func testCLIReceiptQueryFailureNeverResends() async throws {
        let transport = CLIReceiptTransport(status: "FAILED", queryError: .timeout)
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.codex", instanceId: "codex.remoteai", sessionId: "s", action: "sendMessage")
        do { _ = try await transport.reconcileCLISend(command); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? TransportError, .timeout) }
        let actions = await transport.actions
        XCTAssertEqual(actions, ["getCommandOutcome"])
    }
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
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("testCLIUpstream"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("refreshCLIUpstreamModels"))
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

    func testRichUpstreamMetadataDecodesBackwardCompatibly() throws {
        let data = Data(#"{"id":"upstream-custom-1","label":"Sync","host":"api.example.test","models":["m1","m2"],"defaultModel":"m1","credentialAvailable":true,"health":"verified","healthDetail":"HTTP 200","source":"remoteai","editable":true,"removable":true,"enabled":false,"keySet":true,"keyHint":"sk-1***90","secretRef":"cli-upstream-1","revision":5,"customModels":["m2"],"hiddenModels":[],"canTest":true,"canRefreshModels":true,"canManageModels":true}"#.utf8)
        let upstream = try JSONDecoder().decode(CLIUpstream.self, from: data)
        XCTAssertFalse(upstream.isEnabled)
        XCTAssertEqual(upstream.keyHint, "sk-1***90")
        XCTAssertEqual(upstream.revision, 5)
        XCTAssertTrue(upstream.canEditSettings)
        XCTAssertEqual(upstream.customModels, ["m2"])
    }

    func testThreeDimensionCLIStatesAndNaturalLanguageGrouping() {
        XCTAssertEqual(CLIStateLabel.connectionText("Connected"), "已连接")
        XCTAssertEqual(CLIStateLabel.connectionText("Reconnecting"), "重连中")
        XCTAssertEqual(CLIStateLabel.taskText("waiting_user"), "等待用户输入")
        XCTAssertEqual(CLIStateLabel.syncText("Delivery Unknown"), "发送回执未知")
        let sync = CLIStateLabel.syncDimension(cliState: "running", stale: true, machineOnline: false, automaticRetry: false, synchronizing: false)
        XCTAssertEqual(sync.code, "Stale")
        XCTAssertTrue(sync.isWarning)

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let user = ChatMessage(id: "u1", sessionId: "s1", sequence: 1, role: .user, kind: .text, text: "请修复中文进度", createdAt: now)
        let tool1 = ServerMessage(messageId: "cli-tool-1", sessionId: "s1", role: "tool", content: #"{"name":"Bash","command":"ls"}"#, externalId: nil, createdAt: now).chatMessage
        let tool2 = ServerMessage(messageId: "cli-tool-2", sessionId: "s1", role: "tool", content: #"{"type":"function_call_output","output":"ok"}"#, externalId: nil, createdAt: now).chatMessage
        let assistant = ChatMessage(id: "a1", sessionId: "s1", sequence: 2, role: .assistant, kind: .text, text: "\u{001B}[32m已完成验证\u{001B}[0m", createdAt: now)

        let collapsed = CLIConversationFormatter.groupMessages([user, tool1, tool1, tool2, assistant], search: "", showTechnicalLogs: false)
        XCTAssertEqual(collapsed.count, 3)
        if case .toolGroup(_, let items) = collapsed[1] {
            XCTAssertEqual(items.count, 2)
        } else {
            XCTFail("Expected collapsed tool group")
        }
        XCTAssertEqual(CLIConversationFormatter.cleanNaturalText(assistant.text), "已完成验证")
    }

    @MainActor
    func testCLIErrorHistoryRetainedAcrossReloadAndRedactsSecrets() async throws {
        let mock = MockTransport(historyCount: 0)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        let errJSON = JSONValue.object([
            "code": .string("HTTP_429"),
            "message": .string("Rate limit reached Authorization: Bearer sk-verysecret123456"),
            "source": .string("model-api"),
            "retryAfterSeconds": .number(30),
            "at": .string("2026-11-26T00:00:00Z")
        ])
        let statusEvent = RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: 1,
            machineId: "my-pc",
            runtimeId: "runtime.codex",
            instanceId: "codex.remoteai",
            sessionId: "s-err",
            type: "CLI_STATUS",
            payload: ["cliState": .string("rate_limited"), "errorHistory": .array([errJSON])],
            createdAt: Date()
        )
        let encoder = JSONEncoder.remoteAI
        let data = try encoder.encode(statusEvent)
        let decoded = try JSONDecoder.remoteAI.decode(RemoteEvent.self, from: data)
        XCTAssertEqual(decoded.type, "CLI_STATUS")

        let record = CLIErrorRecord.fromJSON(errJSON.objectValue!, fallbackSessionId: "s-err")
        XCTAssertEqual(record.code, "HTTP_429")
        XCTAssertEqual(record.sourceDisplayName, "模型 API")
        XCTAssertEqual(record.retryAfterSeconds, 30)
        XCTAssertFalse(record.message.contains("sk-verysecret123456"))
        try await cache.put([record], key: "cli.errors.s-err")
        await store.loadSession("s-err")
        XCTAssertEqual(store.cliErrorHistoryBySession["s-err"]?.count, 1)
    }
}

private actor CLISnapshotTransport: Transport {
    var metadata: [String: JSONValue]
    let at: Date
    init(metadata: [String: JSONValue], at: Date) { self.metadata = metadata; self.at = at }
    func setMetadata(_ value: [String: JSONValue]) { metadata = value }
    var isConnected: Bool { true }
    func connect() async throws {}
    func disconnect() async {}
    func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { $0.finish() } }
    func healthStream() async -> AsyncStream<TransportHealthEvent> { AsyncStream { $0.finish() } }
    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        let result: JSONValue
        if command.action == "listSessions" {
            result = try JSONValue.encode([ServerSession(sessionId: "snapshot-session", runtimeId: "runtime.cloudcode", instanceId: "cloudcode.remoteai", externalId: "native-uuid", title: "Existing", canonicalUrl: nil, status: "idle", metadata: metadata, createdAt: at, updatedAt: at, lastVisited: nil)])
        } else { result = .object(metadata) }
        return CommandResponseEnvelope(ok: true, result: result, error: nil, idempotentReplay: nil)
    }
}

private actor CLIReceiptTransport: Transport {
    let status: String
    let queryError: TransportError?
    private(set) var actions: [String] = []
    private(set) var submittedID: UUID?
    init(status: String, queryError: TransportError? = nil) { self.status = status; self.queryError = queryError }
    var isConnected: Bool { true }
    func connect() async throws {}
    func disconnect() async {}
    func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { $0.finish() } }
    func healthStream() async -> AsyncStream<TransportHealthEvent> { AsyncStream { $0.finish() } }
    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        actions.append(command.action)
        if command.action == "getSessionStatus", let queryError { throw queryError }
        if command.action == "getCommandOutcome" {
            if let queryError { throw queryError }
            return CommandResponseEnvelope(ok: true, result: .object([
                "status": .string(status), "outcome": .object(["ok": .bool(true)])
            ]), error: nil, idempotentReplay: nil)
        }
        submittedID = command.commandId
        return CommandResponseEnvelope(ok: true, result: nil, error: nil, idempotentReplay: nil)
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
