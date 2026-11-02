import XCTest
@testable import RemoteAIMobile

private struct CommandOutcomeFixture: Sendable {
    let status: String
    let accepted: Bool?
    let sessionId: String?
    let messageId: String?
}

private extension MockTransport {
    func setOutcome(_ fixture: CommandOutcomeFixture, for commandId: UUID) {
        setCommandOutcomeOverride(for: commandId, status: fixture.status,
            accepted: fixture.accepted, sessionId: fixture.sessionId, messageId: fixture.messageId)
    }
}

final class OptimisticMessageIdentityTests: XCTestCase {
    @MainActor
    func testWebCommandIdentityRemovesOptimisticBubbleDespiteOlderProviderTimestamp() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)

        let commandId = UUID()
        let now = Date()
        try await cache.upsertMessages([optimistic(commandId, text: "same prompt", at: now)])
        await base.appendHistoryMessage(ServerMessage(
            messageId: commandId.uuidString,
            sessionId: "photo-upload",
            role: "user",
            content: "same prompt",
            externalId: nil,
            createdAt: now.addingTimeInterval(-11)
        ))

        await store.loadSession("photo-upload")

        let users = store.messagesBySession["photo-upload", default: []].filter { $0.role == .user }
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.id, commandId.uuidString)
        let lookupCount = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(lookupCount, 0,
            "An exact command/message identity should reconcile without querying the receipt bridge")
        await store.suspend()
    }

    @MainActor
    func testSameTextTrueSendsRemainSeparateWhenOnlyOneExactCommandEchoExists() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)

        let firstId = UUID()
        let secondId = UUID()
        let now = Date()
        try await cache.upsertMessages([
            optimistic(firstId, text: "same prompt", at: now.addingTimeInterval(-0.2)),
            optimistic(secondId, text: "same prompt", at: now),
        ])
        await transport.setOutcome(CommandOutcomeFixture(status: "UNKNOWN_DELIVERY",
            accepted: false, sessionId: "photo-upload", messageId: nil), for: secondId)
        await base.appendHistoryMessage(ServerMessage(
            messageId: firstId.uuidString,
            sessionId: "photo-upload",
            role: "user",
            content: "same prompt",
            externalId: nil,
            createdAt: now.addingTimeInterval(-11)
        ))

        await store.loadSession("photo-upload")

        let users = store.messagesBySession["photo-upload", default: []].filter { $0.role == .user }
        XCTAssertEqual(Set(users.map(\.id)), Set([firstId.uuidString, secondId.uuidString]))
        let sendAttempts = await base.actionAttemptCount("sendMessage")
        let outcomeLookups = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(sendAttempts, 0,
            "An unknown status lookup must never resend either command")
        XCTAssertEqual(outcomeLookups, 1,
            "Only the unmatched optimistic command needs a durable outcome lookup")
        await store.suspend()
    }

    @MainActor
    func testLegacyBuild84ReceiptUsesExactSameSessionServerMessageAndSurvivesRestart() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)

        let commandId = UUID()
        let serverMessageId = "legacy-web-message-42"
        try await cache.upsertMessages([optimistic(commandId, text: "old bubble text", at: Date())])
        await transport.setOutcome(CommandOutcomeFixture(status: "COMPLETED", accepted: true,
            sessionId: "photo-upload", messageId: serverMessageId), for: commandId)

        await store.loadSession("photo-upload")
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains(where: { $0.id == commandId.uuidString }),
            "A receipt without its named page row cannot remove the legacy bubble")
        let firstLookupCount = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(firstLookupCount, 1)
        await store.suspend()

        await base.appendHistoryMessage(ServerMessage(
            messageId: serverMessageId,
            sessionId: "photo-upload",
            role: "user",
            content: "provider text differs from the old cached row",
            externalId: nil,
            createdAt: Date().addingTimeInterval(-11)
        ))
        let restarted = WorkspaceStore(transport: transport, cache: cache)
        await startStore(restarted)
        await restarted.loadSession("photo-upload")

        let users = restarted.messagesBySession["photo-upload", default: []].filter { $0.role == .user }
        XCTAssertEqual(users.map(\.id), [serverMessageId],
            "The persisted receipt's exact server ID, not text or time, resolves the Build84 optimistic row")
        let restartedLookupCount = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(restartedLookupCount, 1,
            "A cached accepted receipt is reused after restart without an extra outcome request")
        await restarted.suspend()
    }

    @MainActor
    func testLegacyReceiptRejectsWrongSessionMissingRowAndExplicitRejection() async throws {
        let cases: [(String, CommandOutcomeFixture, ServerMessage?)] = [
            ("wrong session", CommandOutcomeFixture(status: "COMPLETED", accepted: true,
                sessionId: "another-session", messageId: "wrong-session-row"),
             ServerMessage(messageId: "wrong-session-row", sessionId: "photo-upload", role: "user",
                content: "same prompt", externalId: nil, createdAt: Date())),
            ("missing row", CommandOutcomeFixture(status: "COMPLETED", accepted: true,
                sessionId: "photo-upload", messageId: "row-not-in-page"), nil),
            ("explicit completed rejection", CommandOutcomeFixture(status: "COMPLETED", accepted: false,
                sessionId: "photo-upload", messageId: "rejected-row"),
             ServerMessage(messageId: "rejected-row", sessionId: "photo-upload", role: "user",
                content: "same prompt", externalId: nil, createdAt: Date())),
            ("unknown delivery", CommandOutcomeFixture(status: "UNKNOWN_DELIVERY", accepted: false,
                sessionId: "photo-upload", messageId: nil),
             ServerMessage(messageId: "unrelated-provider-row", sessionId: "photo-upload", role: "user",
                content: "same prompt", externalId: nil, createdAt: Date().addingTimeInterval(-11))),
        ]

        for (name, receipt, serverRow) in cases {
            let cache = try SQLiteStore.inMemory()
            let base = MockTransport(historyCount: 0)
            let transport = base
            let store = WorkspaceStore(transport: transport, cache: cache)
            await startStore(store)
            let commandId = UUID()
            try await cache.upsertMessages([optimistic(commandId, text: "same prompt", at: Date())])
            await transport.setOutcome(receipt, for: commandId)
            if let serverRow { await base.appendHistoryMessage(serverRow) }

            await store.loadSession("photo-upload")

            XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains(where: { $0.id == commandId.uuidString }),
                "\(name) must retain the old optimistic row")
            let sendAttempts = await base.actionAttemptCount("sendMessage")
            XCTAssertEqual(sendAttempts, 0,
                "\(name) must not trigger a blind resend")
            await store.suspend()
        }
    }

    @MainActor
    func testOneLegacyProviderRowCannotConsumeTwoCommandReceiptsAcrossRestart() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)
        let firstId = UUID()
        let secondId = UUID()
        let rowId = "legacy-shared-provider-row"
        try await cache.upsertMessages([
            optimistic(firstId, text: "same prompt", at: Date().addingTimeInterval(-0.1)),
            optimistic(secondId, text: "same prompt", at: Date()),
        ])
        let sharedReceipt = CommandOutcomeFixture(status: "COMPLETED", accepted: true,
            sessionId: "photo-upload", messageId: rowId)
        await transport.setOutcome(sharedReceipt, for: firstId)
        await transport.setOutcome(sharedReceipt, for: secondId)
        await base.appendHistoryMessage(ServerMessage(messageId: rowId, sessionId: "photo-upload",
            role: "user", content: "same prompt", externalId: nil, createdAt: Date().addingTimeInterval(-11)))

        await store.loadSession("photo-upload")

        let firstPassUsers = store.messagesBySession["photo-upload", default: []].filter { $0.role == .user }
        XCTAssertEqual(Set(firstPassUsers.map(\.id)), Set([firstId.uuidString, secondId.uuidString, rowId]),
            "Conflicting durable receipts must leave both optimistic commands visible")
        let firstPassLookups = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(firstPassLookups, 2)
        await store.suspend()

        let restarted = WorkspaceStore(transport: transport, cache: cache)
        await startStore(restarted)
        await restarted.loadSession("photo-upload")
        let restartedUsers = restarted.messagesBySession["photo-upload", default: []].filter { $0.role == .user }
        XCTAssertEqual(Set(restartedUsers.map(\.id)), Set([firstId.uuidString, secondId.uuidString, rowId]),
            "The persisted conflict marker prevents one row consuming a second bubble after restart")
        let restartLookups = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(restartLookups, firstPassLookups,
            "Accepted receipts and the conflict decision are reused across restart")
        await restarted.suspend()
    }

    @MainActor
    func testManualRetryKeepsUnknownWhenAcceptedReceiptNamesMissingHistoryRow() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)
        let commandId = UUID()
        let bubble = try await seedPendingUnknown(commandId, text: "accepted but row missing", cache: cache, store: store)
        await transport.setOutcome(CommandOutcomeFixture(status: "COMPLETED", accepted: true,
            sessionId: "photo-upload", messageId: "not-yet-in-history"), for: commandId)

        await store.retry(message: bubble, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[commandId], .unknown,
            "An accepted receipt cannot consume or complete a legacy bubble until its exact same-session row is present")
        XCTAssertNotNil(store.sendDeliveryDiagnosticsByCommand[commandId])
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains { $0.id == commandId.uuidString })
        let pending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertEqual(pending?.commandId, commandId)
        let sendAttempts = await base.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0, "Manual receipt verification remains read-only")
        await store.suspend()
    }

    @MainActor
    func testManualRetryDoesNotCompleteTwoUnknownCommandsFromOneConflictingReceiptRow() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)
        let firstId = UUID()
        let secondId = UUID()
        let firstBubble = try await seedPendingUnknown(firstId, text: "same prompt", cache: cache, store: store)
        let secondBubble = try await seedPendingUnknown(secondId, text: "same prompt", cache: cache, store: store)
        let rowId = "one-row-for-two-manual-receipts"
        let sharedReceipt = CommandOutcomeFixture(status: "COMPLETED", accepted: true,
            sessionId: "photo-upload", messageId: rowId)
        await transport.setOutcome(sharedReceipt, for: firstId)
        await transport.setOutcome(sharedReceipt, for: secondId)
        await base.appendHistoryMessage(ServerMessage(messageId: rowId, sessionId: "photo-upload",
            role: "user", content: "same prompt", externalId: nil, createdAt: Date().addingTimeInterval(-11)))

        await store.retry(message: firstBubble, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[firstId], .unknown,
            "A conflicting provider-row reservation keeps the retried command unresolved")
        XCTAssertEqual(store.commandStates[secondId], .unknown,
            "One named provider row cannot confirm a second command")
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains { $0.id == firstBubble.id })
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains { $0.id == secondBubble.id })
        let firstPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(firstId.uuidString.lowercased())")
        let secondPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(secondId.uuidString.lowercased())")
        XCTAssertNotNil(firstPending)
        XCTAssertNotNil(secondPending)
        let sendAttempts = await base.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0, "Direct retry only inspects durable receipts and history")
        await store.suspend()
    }

    @MainActor
    func testLoadOlderReconcilesExactReceiptFromHistoryOutsideRecentWindow() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)
        let commandId = UUID()
        let oldRowId = "older-named-provider-row"
        let anchor = Date().addingTimeInterval(-1_000)
        await base.appendHistoryMessage(ServerMessage(messageId: oldRowId, sessionId: "photo-upload",
            role: "user", content: "older accepted send", externalId: nil, createdAt: anchor))
        for index in 0..<50 {
            await base.appendHistoryMessage(ServerMessage(messageId: "recent-\(index)", sessionId: "photo-upload",
                role: "assistant", content: "recent page item \(index)", externalId: nil,
                createdAt: anchor.addingTimeInterval(100 + Double(index))))
        }
        await transport.setOutcome(CommandOutcomeFixture(status: "COMPLETED", accepted: true,
            sessionId: "photo-upload", messageId: oldRowId), for: commandId)
        let pendingCommand = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", action: "sendMessage",
            payload: ["text": .string("older accepted send")], commandId: commandId)
        try await cache.put(pendingCommand,
            key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        let bubble = optimistic(commandId, text: "older accepted send", at: Date())
        try await cache.upsertMessages([bubble])
        store.commandStates[commandId] = .unknown

        await store.loadSession("photo-upload")

        XCTAssertEqual(store.commandStates[commandId], .unknown,
            "The accepted receipt cannot map its older row until that history page is loaded")
        XCTAssertTrue(store.hasMoreBySession["photo-upload"] == true)
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains { $0.id == commandId.uuidString })
        let receiptLookupsBeforeOlderPage = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(receiptLookupsBeforeOlderPage, 1)

        await store.loadOlder("photo-upload")

        XCTAssertEqual(store.commandStates[commandId], .completed,
            "The older exact same-session row lets the one-to-one receipt bridge resolve the command")
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains { $0.id == oldRowId })
        XCTAssertFalse(store.messagesBySession["photo-upload", default: []].contains { $0.id == commandId.uuidString })
        let pendingAfterOlderPage: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertNil(pendingAfterOlderPage)
        let loadBeforeAttempts = await base.actionAttemptCount("loadMessagesBefore")
        XCTAssertEqual(loadBeforeAttempts, 1, "One explicit older-page request is sufficient")
        let receiptLookupsAfterOlderPage = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(receiptLookupsAfterOlderPage, receiptLookupsBeforeOlderPage,
            "The persisted exact receipt is reused without a polling loop")
        let sendAttempts = await base.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0)
        await store.suspend()
    }

    @MainActor
    func testManualResyncRechecksPersistedUnknownReceiptWithoutResending() async throws {
        let cache = try SQLiteStore.inMemory()
        let base = MockTransport(historyCount: 0)
        let transport = base
        let store = WorkspaceStore(transport: transport, cache: cache)
        await startStore(store)
        let commandId = UUID()
        let serverMessageId = "late-legacy-web-row"
        try await cache.upsertMessages([optimistic(commandId, text: "manual check", at: Date())])
        await transport.setOutcome(CommandOutcomeFixture(status: "UNKNOWN_DELIVERY", accepted: false,
            sessionId: "photo-upload", messageId: nil), for: commandId)
        await store.loadSession("photo-upload")
        await store.loadSession("photo-upload")
        let automaticLookupCount = await base.actionAttemptCount("getCommandOutcome")
        XCTAssertEqual(automaticLookupCount, 1,
            "Repeated automatic history loads are throttled by the persisted unresolved receipt")

        await transport.setOutcome(CommandOutcomeFixture(status: "COMPLETED", accepted: true,
            sessionId: "photo-upload", messageId: serverMessageId), for: commandId)
        await base.appendHistoryMessage(ServerMessage(messageId: serverMessageId, sessionId: "photo-upload",
            role: "user", content: "manual check", externalId: nil, createdAt: Date().addingTimeInterval(-11)))
        store.commandStates[commandId] = .unknown
        let bubble = try XCTUnwrap(store.messagesBySession["photo-upload"]?.first(where: { $0.id == commandId.uuidString }))
        await store.retry(message: bubble, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[commandId], .completed,
            "The accepted durable receipt confirms the exact original command")
        XCTAssertFalse(store.messagesBySession["photo-upload", default: []].contains(where: { $0.id == commandId.uuidString }))
        XCTAssertNil(store.sendDeliveryDiagnosticsByCommand[commandId],
            "The exact accepted receipt clears only the matching unknown delivery notice")
        let manualLookupCount = await base.actionAttemptCount("getCommandOutcome")
        let sendAttempts = await base.actionAttemptCount("sendMessage")
        XCTAssertEqual(manualLookupCount, 2,
            "An explicit manual resync can query the existing durable receipt path after an unknown result")
        XCTAssertEqual(sendAttempts, 0)
        await store.suspend()
    }

    @MainActor
    private func startStore(_ store: WorkspaceStore) async {
        let started = await store.start()
        XCTAssertTrue(started, "WorkspaceStore.start() must pass its native MockTransport startup path")
        guard started else { return }
        guard let webRuntime = store.runtimes.first(where: { $0.id == "runtime.web" }) else {
            XCTFail("The Web runtime must be loaded before these history tests run")
            return
        }
        await store.refreshRuntime(webRuntime)
        guard let photoInstance = store.instances.first(where: { $0.id == "photo" }) else {
            XCTFail("The Web test route must include the Photo instance")
            return
        }
        await store.refreshSessions(runtime: webRuntime, instance: photoInstance)
        XCTAssertTrue(store.sessions.contains(where: { $0.id == "photo-upload" }),
            "The Web session must be loaded to provide a route for loadSession and retry")
    }

    @MainActor
    private func seedPendingUnknown(_ commandId: UUID, text: String, cache: SQLiteStore,
        store: WorkspaceStore) async throws -> ChatMessage {
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", action: "sendMessage",
            payload: ["text": .string(text)], commandId: commandId)
        try await cache.put(command, key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        let bubble = optimistic(commandId, text: text, at: command.createdAt)
        try await cache.upsertMessages([bubble])
        store.messagesBySession["photo-upload", default: []].append(bubble)
        store.commandStates[commandId] = .unknown
        return bubble
    }

    @MainActor
    private func optimistic(_ commandId: UUID, text: String, at: Date) -> ChatMessage {
        ChatMessage(id: commandId.uuidString, sessionId: "photo-upload", sequence: nil, role: .user,
            kind: .text, text: text, toolName: nil, toolStatus: nil, detail: nil,
            createdAt: at)
    }
}
