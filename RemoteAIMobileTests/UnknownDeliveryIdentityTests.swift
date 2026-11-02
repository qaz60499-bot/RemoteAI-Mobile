import XCTest
@testable import RemoteAIMobile

final class UnknownDeliveryIdentityTests: XCTestCase {
    @MainActor
    func testRecentSameTextWebHistoryCannotConfirmUnknownCommand() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(scenario: .webSendDeliveryUnknown, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let commandId = UUID()
        let priorMessageId = "prior-same-text-provider-turn"
        await mock.appendHistoryMessage(ServerMessage(
            messageId: priorMessageId,
            sessionId: "photo-upload",
            role: "user",
            content: "same prompt",
            externalId: nil,
            createdAt: Date().addingTimeInterval(-2)
        ))

        let sent = await store.send(text: "same prompt", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", commandId: commandId)

        XCTAssertFalse(sent)
        XCTAssertEqual(store.commandStates[commandId], .unknown,
            "A provider row two seconds before Send is not command identity evidence")
        XCTAssertNotNil(store.sendDeliveryDiagnosticsByCommand[commandId])
        let users = store.messagesBySession["photo-upload", default: []].filter { $0.role == .user && $0.text == "same prompt" }
        XCTAssertEqual(users.count, 2, "The prior provider turn and unknown new command remain separate rows")
        XCTAssertTrue(users.contains { $0.id == priorMessageId })
        XCTAssertTrue(users.contains { $0.id.caseInsensitiveCompare(commandId.uuidString) == .orderedSame })
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 1, "Identity reconciliation never issues a second send")
        await store.suspend()
    }

    @MainActor
    func testOneProviderTurnCannotCompleteTwoSameTextUnknownCommands() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        let firstId = UUID()
        let secondId = UUID()
        let firstBubble = try await seedUnknownSend(id: firstId, text: "same prompt", cache: cache, store: store)
        _ = try await seedUnknownSend(id: secondId, text: "same prompt", cache: cache, store: store)
        await mock.appendHistoryMessage(ServerMessage(
            messageId: "single-provider-turn",
            sessionId: "photo-upload",
            role: "user",
            content: "same prompt",
            externalId: nil,
            createdAt: Date()
        ))

        await store.retry(message: firstBubble, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[firstId], .unknown)
        XCTAssertEqual(store.commandStates[secondId], .unknown,
            "One ambiguous provider row must not satisfy two same-text pending operations")
        let firstPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(firstId.uuidString.lowercased())")
        let secondPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(secondId.uuidString.lowercased())")
        XCTAssertNotNil(firstPending)
        XCTAssertNotNil(secondPending)
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0, "A status check must remain read-only")
        await store.suspend()
    }

    @MainActor
    func testExactProviderMessageIdResolvesOnlyItsMatchingUnknownCommand() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        let exactId = UUID()
        let ambiguousId = UUID()
        let bubble = try await seedUnknownSend(id: ambiguousId, text: "same prompt", cache: cache, store: store)
        _ = try await seedUnknownSend(id: exactId, text: "same prompt", cache: cache, store: store)
        await mock.appendHistoryMessage(ServerMessage(
            messageId: "provider-message-id",
            sessionId: "photo-upload",
            role: "user",
            content: "same prompt",
            externalId: exactId.uuidString,
            createdAt: Date()
        ))

        await store.retry(message: bubble, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[exactId], .completed,
            "The legacy providerMessageId alias is exact command identity evidence")
        XCTAssertEqual(store.commandStates[ambiguousId], .unknown,
            "An exact match must reserve its provider row from another same-text command")
        let exactPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(exactId.uuidString.lowercased())")
        let ambiguousPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(ambiguousId.uuidString.lowercased())")
        XCTAssertNil(exactPending)
        XCTAssertNotNil(ambiguousPending)
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0)
        await store.suspend()
    }

    @MainActor
    func testConflictingExactMessageAliasesCannotCompleteTwoUnknownCommands() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let firstId = UUID()
        let secondId = UUID()
        let firstBubble = try await seedUnknownSend(id: firstId, text: "conflicting aliases", cache: cache, store: store)
        _ = try await seedUnknownSend(id: secondId, text: "another command", cache: cache, store: store)
        await mock.appendHistoryMessage(ServerMessage(
            messageId: firstId.uuidString,
            sessionId: "photo-upload",
            role: "user",
            content: "conflicting aliases",
            externalId: secondId.uuidString,
            createdAt: Date()
        ))

        await store.retry(message: firstBubble, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[firstId], .unknown,
            "A provider row with contradictory command-ID and external-ID aliases is ambiguous")
        XCTAssertEqual(store.commandStates[secondId], .unknown,
            "One row cannot complete two commands through separate identity aliases")
        let firstPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(firstId.uuidString.lowercased())")
        let secondPending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(secondId.uuidString.lowercased())")
        XCTAssertNotNil(firstPending)
        XCTAssertNotNil(secondPending)
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0, "Identity ambiguity must never trigger a new send")
        await store.suspend()
    }

    @MainActor
    func testExactProviderConfirmationClearsOnlyItsCommandDiagnosticWithoutResending() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(scenario: .webSendDeliveryUnknown, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let commandId = UUID()

        let sent = await store.send(text: "confirm exact identity", runtimeId: "runtime.web",
            instanceId: "photo", sessionId: "photo-upload", commandId: commandId)

        XCTAssertFalse(sent)
        XCTAssertNotNil(store.sendDeliveryDiagnosticsByCommand[commandId])
        await mock.appendHistoryMessage(ServerMessage(
            messageId: "exact-provider-confirmation",
            sessionId: "photo-upload",
            role: "user",
            content: "confirm exact identity",
            externalId: commandId.uuidString,
            createdAt: Date().addingTimeInterval(-12)
        ))
        await store.loadSession("photo-upload")

        XCTAssertEqual(store.commandStates[commandId], .completed)
        XCTAssertNil(store.sendDeliveryDiagnosticsByCommand[commandId],
            "Only exact provider/command identity confirmation clears the matching unknown notice")
        XCTAssertFalse(store.messagesBySession["photo-upload", default: []].contains {
            $0.id.caseInsensitiveCompare(commandId.uuidString) == .orderedSame
        })
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 1, "Exact status reconciliation must remain read-only")
        await store.suspend()
    }

    @MainActor
    func testSuspendedLifecycleIgnoresDelayedUnknownDeliveryHistory() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let commandId = UUID()
        let bubble = try await seedUnknownSend(id: commandId, text: "lifecycle pending", cache: cache, store: store)
        await mock.appendHistoryMessage(ServerMessage(
            messageId: "provider-after-suspend",
            sessionId: "photo-upload",
            role: "user",
            content: "lifecycle pending",
            externalId: nil,
            createdAt: Date()
        ))
        await mock.setResponseDelay(action: "loadRecentMessages", nanoseconds: 450_000_000)
        let baselineReads = await mock.actionAttemptCount("loadRecentMessages")
        let statusCheck = Task { @MainActor in
            await store.retry(message: bubble, runtimeId: "runtime.web", instanceId: "photo")
        }

        var readStarted = false
        for _ in 0..<400 {
            if await mock.actionAttemptCount("loadRecentMessages") > baselineReads {
                readStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(readStarted, "The delayed authoritative history request should start before suspension")
        await store.suspend()
        await statusCheck.value

        XCTAssertEqual(store.commandStates[commandId], .unknown,
            "A response from the previous lifecycle cannot resolve delivery after suspension")
        let pending: RemoteCommand? = try await cache.get(RemoteCommand.self,
            key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertNotNil(pending)
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        XCTAssertEqual(sendAttempts, 0)
    }

    @MainActor
    private func seedUnknownSend(id: UUID, text: String, cache: SQLiteStore,
                                 store: WorkspaceStore) async throws -> ChatMessage {
        let command = RemoteCommand.make(
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "photo",
            sessionId: "photo-upload",
            action: "sendMessage",
            payload: ["text": .string(text)],
            commandId: id
        )
        try await cache.put(command, key: "pending.command.my-pc.\(id.uuidString.lowercased())")
        store.commandStates[id] = .unknown
        return ChatMessage(
            id: id.uuidString,
            sessionId: "photo-upload",
            sequence: nil,
            role: .user,
            kind: .text,
            text: text,
            toolName: nil,
            toolStatus: nil,
            detail: nil,
            createdAt: command.createdAt
        )
    }
}
