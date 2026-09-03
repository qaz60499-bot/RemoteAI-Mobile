import XCTest
import Security
@testable import RemoteAIMobile

final class RemoteAIMobileTests: XCTestCase {
    func testSpeechInputLifecyclePermissionAndInterruptionStateMachine() {
        var state: SpeechInputLifecycleState = .idle
        state = SpeechInputLifecycleReducer.reduce(state, event: .startRequested)
        XCTAssertEqual(state, .requestingPermissions)
        state = SpeechInputLifecycleReducer.reduce(state, event: .permissionDenied)
        XCTAssertEqual(state, .idle, "Denied permissions must return voice input to an interactive idle composer")

        state = SpeechInputLifecycleReducer.reduce(state, event: .startRequested)
        state = SpeechInputLifecycleReducer.reduce(state, event: .recordingStarted)
        XCTAssertEqual(state, .recording)
        state = SpeechInputLifecycleReducer.reduce(state, event: .interrupted)
        XCTAssertEqual(state, .idle, "Backgrounding or recognition interruption must not leave the composer stuck recording")

        state = SpeechInputLifecycleReducer.reduce(state, event: .startRequested)
        state = SpeechInputLifecycleReducer.reduce(state, event: .stopRequested)
        XCTAssertEqual(state, .idle, "Repeated user stop must remain idempotent")
        state = SpeechInputLifecycleReducer.reduce(state, event: .stopRequested)
        XCTAssertEqual(state, .idle)
    }

    func testSpeechRecognitionCallbackStopsOnPartialResultWithTerminalError() {
        let partialFailure = SpeechRecognitionCallbackDecision.evaluate(isFinal: false, hasError: true)
        XCTAssertTrue(partialFailure.shouldStop, "A terminal recognition error must stop audio even when the callback also carries a partial transcript")
        XCTAssertTrue(partialFailure.shouldReportError)

        let finalSuccessWithTrailingError = SpeechRecognitionCallbackDecision.evaluate(isFinal: true, hasError: true)
        XCTAssertTrue(finalSuccessWithTrailingError.shouldStop)
        XCTAssertFalse(finalSuccessWithTrailingError.shouldReportError, "A final transcript should win over a trailing recognizer error")

        let partialSuccess = SpeechRecognitionCallbackDecision.evaluate(isFinal: false, hasError: false)
        XCTAssertFalse(partialSuccess.shouldStop)
        XCTAssertFalse(partialSuccess.shouldReportError)
    }

    func testCommandRoundTripKeepsIdempotencyIdAndNumericProtocolVersion() throws {
        let id = UUID()
        let command = RemoteCommand.make(machineId: "pc", runtimeId: "runtime.web", instanceId: "agent", sessionId: "s", action: "sendMessage", payload: ["text": .string("hello")], commandId: id)
        let decoded = try JSONDecoder.remoteAI.decode(RemoteCommand.self, from: JSONEncoder.remoteAI.encode(command))
        XCTAssertEqual(decoded.commandId, id)
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.payload["text"]?.stringValue, "hello")
    }

    func testEventRoundTripPreservesSequence() throws {
        let event = RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: 42, machineId: "pc", runtimeId: "runtime.codex", instanceId: "codex6", sessionId: "s", type: "MESSAGE_ADDED", payload: ["content": .string("ok")], createdAt: Date())
        let decoded = try JSONDecoder.remoteAI.decode(RemoteEvent.self, from: JSONEncoder.remoteAI.encode(event))
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.type, "MESSAGE_ADDED")
    }

    func testSequenceTrackerDropsDuplicate() {
        var tracker = SequenceTracker(lastSequence: 10)
        XCTAssertTrue(tracker.ingest(10).duplicate)
        XCTAssertFalse(tracker.ingest(11).duplicate)
        XCTAssertEqual(tracker.lastSequence, 11)
    }

    func testSequenceTrackerDetectsGap() {
        var tracker = SequenceTracker(lastSequence: 10)
        let decision = tracker.ingest(13)
        XCTAssertTrue(decision.gap)
        XCTAssertFalse(decision.duplicate)
    }

    func testBase64URLRoundTrip() throws {
        let data = Data([0xfb, 0xff, 0x00, 0x10, 0x7f])
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Base64URL.decode(encoded), data)
    }

    func testWindowsPairingProofVector() {
        let proof = PayloadCrypto.pairingProof(
            pairingCode: "12345678",
            challenge: "challenge_test_123",
            machineId: "machine-test-001",
            deviceId: "ios-test-001",
            devicePublicKeyB64: "MCowBQYDK2VuAyEAT14+n+/J0UNC2Z8kSyBbnt4dU2+P8xOCPKc14UHIF3g="
        )
        XCTAssertEqual(proof, "-aimXXz2Bt84NKf1cpt3YSeTSI6PhPrOP7PxTY6a7Fo")
    }

    func testWindowsX25519HKDFVector() throws {
        let privatePKCS8 = Data(base64Encoded: "MC4CAQAwBQYDK2VuBCIEIDDswlYnNeavIx4tzsUq2sYCQc1nAZTUU80ahYByK/x4")!
        let privateRaw = Data(privatePKCS8.suffix(32))
        let key = try PayloadCrypto.deriveSharedKey(
            privateKeyRaw: privateRaw,
            machinePublicKeyB64: "MCowBQYDK2VuAyEAVr06jCbV51kSzd0v7tBO792LaFqWw1OmZ8FX5LdMhzY=",
            machineId: "machine-test-001",
            deviceId: "ios-test-001"
        )
        XCTAssertEqual(key.base64EncodedString(), "6zdQi/1ISlyQF1K/60BC1faFTOYa5Po/LUm7TUKdTAI=")
    }

    func testDecryptsWindowsAESGCMVector() throws {
        let key = Data(base64Encoded: "6zdQi/1ISlyQF1K/60BC1faFTOYa5Po/LUm7TUKdTAI=")!
        let body = EncryptedRelayBody(
            alg: "A256GCM",
            nonce: "7bbcpBwLpVmbPZzm",
            ciphertext: "DZ543nZlttX-MuGry7Ssuj6f8H_aRqIfkDq2KiO-kjnRMP8mTPNydYEkKE5SOTIJ_AfpdcdovPWHyJuw1MXQ3o7G4qeW1pxa074SnqIjvPWIwLPMNGAOlOtnLYk7FXYqN3ypTnl8EbBUkyWwp9hudQ8QpeF3CgH_7afdZ7a6sQqEFy_7qmcmzJ0L1ExsFQWVsjh5fzwxMPV1BTzqpfvBK7sb_UrsuN64pU2jQM0GT_McofWgy0WhynqjRC1SAtI37DGcSMvoEnnL3bjEGJRZMTz3BHdURdTou_ezvzh_KxG_DcSZsJOxZUVoEk44rvNDOrAl",
            tag: "FMq6uFeoyzsM0QB9326P2A"
        )
        let clear = try PayloadCrypto.decrypt(body, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        let command = try JSONDecoder.remoteAI.decode(RemoteCommand.self, from: clear)
        XCTAssertEqual(command.protocolVersion, 1)
        XCTAssertEqual(command.action, "listRuntimes")
        XCTAssertEqual(command.runtimeId, "runtime.web")
    }

    func testAESGCMRoundTripUsesAAD() throws {
        let key = Data(repeating: 7, count: 32)
        let clear = Data("secret payload".utf8)
        let body = try PayloadCrypto.encrypt(clear, keyData: key, machineId: "machine-a", deviceId: "device-a", messageId: "message-a")
        XCTAssertEqual(try PayloadCrypto.decrypt(body, keyData: key, machineId: "machine-a", deviceId: "device-a", messageId: "message-a"), clear)
        XCTAssertThrowsError(try PayloadCrypto.decrypt(body, keyData: key, machineId: "machine-a", deviceId: "device-a", messageId: "message-b"))
    }

    func testKeychainUsesWhenUnlockedThisDeviceOnly() throws {
        let account = "security-test.\(UUID().uuidString)"
        defer { KeychainStore.shared.delete(account: account) }
        try KeychainStore.shared.save(Data("not-a-real-secret".utf8), account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.remoteai.mobile.pairing",
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testPairingStorePersistsOnlyDerivedSharedKeyAndCleansLegacyPrivateKey() throws {
        let machineId = "security-test-\(UUID().uuidString)"
        let legacyPrivateAccount = "x25519-private-v1.\(machineId)"
        defer { PairingKeyStore.deletePairing(machineId: machineId) }
        try KeychainStore.shared.save(Data(repeating: 1, count: 32), account: legacyPrivateAccount)

        let shared = Data(repeating: 7, count: 32)
        try PairingKeyStore.savePairing(machineId: machineId, sharedKey: shared)

        XCTAssertEqual(PairingKeyStore.sharedKey(machineId: machineId), shared)
        XCTAssertNil(KeychainStore.shared.load(account: legacyPrivateAccount))
    }

    func testRelayRejectsPlainHTTP() {
        XCTAssertThrowsError(try RemoteAIConfig.validateSecureRelay(URL(string: "http://example.com")!))
        XCTAssertNoThrow(try RemoteAIConfig.validateSecureRelay(URL(string: "https://example.com")!))
    }

    func testRelayDeviceURLUsesFrozenConnectContract() throws {
        let url = try RemoteAIConfig.deviceWebSocketURL(baseURL: URL(string: "https://relay.example.com/base")!, machineId: "machine-a", deviceId: "ios-a")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/connect")
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["machineId"], "machine-a")
        XCTAssertEqual(values["role"], "device")
        XCTAssertEqual(values["deviceId"], "ios-a")
    }

    func testMockListsFrozenRuntimeIds() async throws {
        let mock = MockTransport(historyCount: 10)
        try await mock.connect()
        let runtimes = try await mock.listRuntimes(machineId: "my-pc")
        XCTAssertEqual(Set(runtimes.map(\.id)), Set(["runtime.web", "runtime.codex"]))
        XCTAssertFalse(runtimes.contains(where: { $0.id == "runtime.cloudcode" }))
    }

    func testMockProjectsAreLazyAndProjectConversationCreationStaysScoped() async throws {
        let mock = MockTransport(historyCount: 10)
        try await mock.connect()
        let projects = try await mock.listProjects(machineId: "my-pc")
        XCTAssertEqual(projects.count, 2)
        let project = try XCTUnwrap(projects.first(where: { $0.projectAlias == "g-p-remoteai" }))
        XCTAssertEqual(project.displayName, "RemoteAI")

        let before = try await mock.listProjectConversations(machineId: "my-pc", projectAlias: project.projectAlias, limit: 30)
        XCTAssertEqual(before.items.count, 1)
        XCTAssertTrue(before.items.allSatisfy { $0.projectAlias == project.projectAlias })

        let created = try await mock.createWebConversation(machineId: "my-pc", projectAlias: project.projectAlias)
        XCTAssertEqual(created.projectAlias, project.projectAlias)
        XCTAssertTrue(created.canonicalUrl.contains(project.projectAlias))

        let after = try await mock.listProjectConversations(machineId: "my-pc", projectAlias: project.projectAlias, limit: 30)
        XCTAssertEqual(after.items.first?.id, created.id)
        XCTAssertTrue(after.items.allSatisfy { $0.projectAlias == project.projectAlias })

        let newProject = try await mock.createWebProject(machineId: "my-pc", projectName: "Created from iPhone")
        XCTAssertEqual(newProject.displayName, "Created from iPhone")
        let refreshed = try await mock.listProjects(machineId: "my-pc")
        XCTAssertTrue(refreshed.contains(where: { $0.projectAlias == newProject.projectAlias }))
    }

    func testProjectOrderStressPreservesAuthoritativeServerOrder() throws {
        let projects = (0..<250).map { index in
            WebProjectDescriptor(
                projectAlias: "g-p-order-\(index)",
                projectId: "id-\(index)",
                displayName: index.isMultiple(of: 3) ? "项目 \(index)" : "Project \(index)",
                canonicalUrl: "https://chatgpt.com/g/g-p-order-\(index)/project",
                lastSeenAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                lastOpenedAt: nil
            )
        }
        let response = WebProjectListResponse(items: projects, observedAt: Date(timeIntervalSince1970: 1_700_100_000))
        let encoded = try JSONEncoder.remoteAI.encode(response)
        let expected = projects.map(\.projectAlias)
        for _ in 0..<100 {
            let decoded = try JSONDecoder.remoteAI.decode(WebProjectListResponse.self, from: encoded)
            XCTAssertEqual(decoded.items.map(\.projectAlias), expected)
        }
        print("PROJECT_ORDER_STRESS_TOTAL=25000")
    }

    func testMockProjectCreateRefreshStressDoesNotDropOrDuplicateProjects() async throws {
        let mock = MockTransport(historyCount: 1)
        try await mock.connect()
        for index in 0..<100 {
            _ = try await mock.createWebProject(machineId: "my-pc", projectName: "Stress Project \(index)")
        }
        for _ in 0..<25 {
            let projects = try await mock.listProjects(machineId: "my-pc")
            XCTAssertEqual(projects.count, 102)
            XCTAssertEqual(Set(projects.map(\.projectAlias)).count, 102)
            XCTAssertEqual(projects.first?.displayName, "Stress Project 99")
        }
        print("PROJECT_REFRESH_STRESS_TOTAL=2500")
    }

    func testCodexInstanceCarriesSafeSelectableModelCatalog() throws {
        let catalog = CodexCatalog(
            models: [
                CodexModelOption(id: "gpt-5.6-sol", label: "GPT-5.6-Sol"),
                CodexModelOption(id: "gpt-5.4-mini", label: "GPT-5.4-Mini")
            ],
            defaultModel: "gpt-5.6-sol"
        )
        let server = ServerInstance(
            instanceId: "codex.1",
            runtimeId: "runtime.codex",
            label: "Codex1",
            kind: "codex-cli",
            config: [
                "model": .string("gpt-5.6-sol"),
                "codexCatalog": try JSONValue.encode(catalog)
            ],
            status: "ready",
            updatedAt: Date()
        )
        let descriptor = server.descriptor
        let decoded = try XCTUnwrap(descriptor.codexCatalog)
        XCTAssertEqual(descriptor.configuredModel, "gpt-5.6-sol")
        XCTAssertEqual(decoded.defaultModel, "gpt-5.6-sol")
        XCTAssertEqual(decoded.models.map(\.id), ["gpt-5.6-sol", "gpt-5.4-mini"])
        XCTAssertEqual(decoded.models.map(\.label), ["GPT-5.6-Sol", "GPT-5.4-Mini"])
    }

    func testMockExposesAllElevenDesktopCodexInstances() async throws {
        let mock = MockTransport(historyCount: 10)
        try await mock.connect()
        let instances = try await mock.listInstances(machineId: "my-pc", runtimeId: "runtime.codex")
        XCTAssertEqual(instances.filter { $0.name.hasPrefix("Codex") }.count, 11)
        XCTAssertEqual(Set(instances.map(\.name)), Set((1...11).map { "Codex\($0)" }))
    }

    func testMockAttachmentUploadIsChunkedAndReturnsDescriptor() async throws {
        let mock = MockTransport(historyCount: 1)
        try await mock.connect()
        let payload = Data(repeating: 0x41, count: 220_000)
        let local = PendingAttachment(name: "photo.jpg", contentType: "image/jpeg", data: payload)
        let uploaded = try await mock.uploadAttachment(machineId: "my-pc", runtimeId: "runtime.codex", instanceId: "codex.1", sessionId: "codex6-a", attachment: local)
        XCTAssertEqual(uploaded.name, "photo.jpg")
        XCTAssertEqual(uploaded.contentType, "image/jpeg")
        XCTAssertEqual(uploaded.sizeBytes, payload.count)
        XCTAssertFalse(uploaded.attachmentId.isEmpty)
    }

    func testMockRecentIsPaginated() async throws {
        let mock = MockTransport(historyCount: 1200)
        try await mock.connect()
        let page = try await mock.loadRecent(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", limit: 50)
        XCTAssertEqual(page.items.count, 50)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.last?.id, "mock-1200")
    }

    func testMockLoadBeforeUsesCreatedAtAndMessageIdCursor() async throws {
        let mock = MockTransport(historyCount: 1200)
        try await mock.connect()
        let recent = try await mock.loadRecent(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", limit: 50)
        let cursor = try XCTUnwrap(recent.items.first?.cursor)
        let older = try await mock.loadBefore(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", before: cursor, limit: 40)
        XCTAssertEqual(older.items.count, 40)
        XCTAssertTrue(older.items.allSatisfy { $0.createdAt < cursor.createdAt || ($0.createdAt == cursor.createdAt && $0.id < cursor.messageId) })
    }

    func testMockCommandIdempotencyReturnsReplay() async throws {
        let mock = MockTransport(historyCount: 10)
        try await mock.connect()
        let id = UUID()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage", payload: ["text": .string("once")], commandId: id)
        let first = try await mock.execute(command)
        let second = try await mock.execute(command)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(second.idempotentReplay, true)
    }

    func testMockOfflineRejectsConnect() async {
        let mock = MockTransport(scenario: .offline, historyCount: 10)
        do { try await mock.connect(); XCTFail("Expected offline") }
        catch { XCTAssertEqual(error as? TransportError, .offline) }
    }

    func testMockStreamingToolAndCompletionEvents() async throws {
        let mock = MockTransport(historyCount: 10)
        try await mock.connect()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage", payload: ["text": .string("stream")])
        _ = try await mock.execute(command)
        try await Task.sleep(nanoseconds: 800_000_000)
        let events = try await mock.delta(machineId: "my-pc", after: 0).events
        let types = Set(events.map(\.type))
        XCTAssertTrue(types.contains("GENERATION_STARTED"))
        XCTAssertTrue(types.contains("MESSAGE_UPDATED"))
        XCTAssertTrue(types.contains("MESSAGE_ADDED"))
        XCTAssertTrue(types.contains("TOOL_STARTED"))
        XCTAssertTrue(types.contains("TOOL_FINISHED"))
        XCTAssertTrue(types.contains("GENERATION_STOPPED"))
    }

    func testMockCommandFailureScenario() async throws {
        let mock = MockTransport(scenario: .commandFailure, historyCount: 10)
        try await mock.connect()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage")
        do {
            _ = try await mock.send(command)
            XCTFail("Expected command failure")
        } catch {
            guard let transportError = error as? TransportError else { return XCTFail("Unexpected error: \(error)") }
            guard case .remote(let code, _) = transportError else { return XCTFail("Unexpected transport error: \(transportError)") }
            XCTAssertEqual(code, "PROVIDER_UNAVAILABLE")
        }
    }

    func testMockDisconnectThenReconnectScenario() async throws {
        let mock = MockTransport(scenario: .disconnect, historyCount: 10)
        try await mock.connect()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage")
        _ = try await mock.execute(command)
        try await Task.sleep(nanoseconds: 800_000_000)
        let disconnected = await mock.isConnected
        XCTAssertFalse(disconnected)
        await mock.setScenario(.normal)
        try await mock.connect()
        let reconnected = await mock.isConnected
        XCTAssertTrue(reconnected)
    }

    func testMockSequenceGapScenarioIsRejectedByStrictDeltaValidation() async throws {
        let mock = MockTransport(scenario: .sequenceGap, historyCount: 10)
        try await mock.connect()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage")
        _ = try await mock.execute(command)
        try await Task.sleep(nanoseconds: 800_000_000)
        do {
            _ = try await mock.delta(machineId: "my-pc", after: 0)
            XCTFail("Expected a delta batch with a sequence gap to be rejected")
        } catch {
            XCTAssertEqual(error as? TransportError, .malformedData)
        }
    }

    func testMockDuplicateEventScenario() async throws {
        let mock = MockTransport(scenario: .duplicateEvent, historyCount: 10)
        try await mock.connect()
        let stream = await mock.eventStream()
        let duplicate = expectation(description: "duplicate event yielded")
        let reader = Task {
            var seen = Set<UUID>()
            for await event in stream {
                if !seen.insert(event.eventId).inserted { duplicate.fulfill(); break }
            }
        }
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage")
        _ = try await mock.execute(command)
        await fulfillment(of: [duplicate], timeout: 3.0)
        reader.cancel()
    }

    func testDerivedCommandIdsAreStableAndSeparatedByStep() {
        let parent = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let beginA = RemoteCommand.derivedCommandId(namespace: parent, label: "attachment:0:begin")
        let beginB = RemoteCommand.derivedCommandId(namespace: parent, label: "attachment:0:begin")
        let chunk = RemoteCommand.derivedCommandId(namespace: parent, label: "attachment:0:chunk:0")
        XCTAssertEqual(beginA, beginB)
        XCTAssertNotEqual(beginA, chunk)
        XCTAssertNotEqual(beginA, parent)
    }

    @MainActor
    func testWorkspaceCoalescesDuplicateInitializationAndLifecycleRace() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.setExecutionDelay(nanoseconds: 120_000_000)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())

        async let first: Void = store.start()
        async let second: Void = store.start()
        _ = await (first, second)
        let connectionAttempts = await mock.connectionAttemptCount()
        let statusAttempts = await mock.actionAttemptCount("getStatus")
        let runtimeCatalogAttempts = await mock.actionAttemptCount("listRuntimes")
        XCTAssertEqual(connectionAttempts, 1, "Duplicate start must share one transport connection")
        XCTAssertEqual(statusAttempts, 1, "Startup authentication and fresh-delta seeding must reuse one getStatus request")
        XCTAssertEqual(runtimeCatalogAttempts, 1, "Duplicate start must not initialize runtime metadata twice")
        XCTAssertEqual(store.machine.state, .online)

        await store.suspend()
        await mock.setExecutionDelay(nanoseconds: 220_000_000)
        let starting = Task { await store.resumeFromForeground() }
        try await Task.sleep(nanoseconds: 35_000_000)
        await store.suspend()
        await starting.value
        XCTAssertEqual(store.machine.state, .offline, "A stale startup must not overwrite a later background suspend")
        XCTAssertEqual(store.connectionPhase, .idle)

        await mock.setExecutionDelay(nanoseconds: 0)
        await store.resumeFromForeground()
        XCTAssertEqual(store.machine.state, .online)
        await store.suspend()
    }

    @MainActor
    func testDeltaRecoveryRejectsWrongMachineEventBeforeApplyingReplay() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let initialSequence = try await cache.lastSequence()
        XCTAssertEqual(initialSequence, 1200)

        let invalid = RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: 1201,
            machineId: "other-machine",
            runtimeId: "runtime.web",
            instanceId: "photo",
            sessionId: "photo-upload",
            type: "GENERATION_STARTED",
            payload: [:],
            createdAt: Date()
        )
        let gapTrigger = RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: 1202,
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "photo",
            sessionId: "photo-upload",
            type: "TRANSPORT_STATUS",
            payload: ["state": .string("gap-trigger")],
            createdAt: Date()
        )
        await mock.injectEvent(invalid)
        await mock.injectEvent(gapTrigger, deliverLive: true)

        for _ in 0..<80 {
            if store.errors["sync"] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(store.errors["sync"], "Delta replay must fail closed when an event belongs to another machine")
        let replaySequence = try await cache.lastSequence()
        XCTAssertEqual(replaySequence, 1200, "Invalid replay events must not advance the durable sequence cursor")
        await store.suspend()
    }

    @MainActor
    func testCreateSessionCannotBeErasedByConcurrentOlderRefresh() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let runtime = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.codex" }))
        await store.refreshRuntime(runtime)
        let instance = try XCTUnwrap(store.instances.first(where: { $0.id == "codex.6" }))

        await mock.setRequestDelay(action: "createSession", nanoseconds: 120_000_000)
        await mock.setResponseDelay(action: "listSessions", nanoseconds: 250_000_000)
        async let created = store.createSession(runtime: runtime, instance: instance, title: "Race New Session")
        try await Task.sleep(nanoseconds: 20_000_000)
        async let refreshed: Void = store.refreshSessions(runtime: runtime, instance: instance)
        let createResult = await created
        await refreshed

        XCTAssertTrue(createResult)
        XCTAssertTrue(store.sessions.contains { $0.instanceId == instance.id && $0.title == "Race New Session" }, "A late stale refresh must not erase a successfully created session")
        await store.suspend()
    }

    @MainActor
    func testWorkspaceCoalescesRefreshAndDoubleCreateWithFinalServerState() async throws {
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await mock.setExecutionDelay(nanoseconds: 140_000_000)

        async let refreshA: Void = store.refreshWebProjects()
        async let refreshB: Void = store.refreshWebProjects()
        _ = await (refreshA, refreshB)
        let listProjectAttempts = await mock.actionAttemptCount("listProjects")
        XCTAssertEqual(listProjectAttempts, 1)
        XCTAssertEqual(store.webProjects.count, 2)

        async let createA = store.createWebProject(name: "Race Project")
        async let createB = store.createWebProject(name: "Race Project")
        let (createdA, createdB) = await (createA, createB)
        let created = [createdA, createdB].compactMap { $0 }
        XCTAssertEqual(created.count, 1)
        let createProjectAttempts = await mock.actionAttemptCount("createProject")
        let finalProjectCount = await mock.projectCount()
        XCTAssertEqual(createProjectAttempts, 1)
        XCTAssertEqual(finalProjectCount, 3, "Server state must contain exactly one newly created Project")
        XCTAssertEqual(store.webProjects.filter { $0.displayName == "Race Project" }.count, 1)

        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        async let conversationA = store.createWebConversation(projectAlias: "g-p-remoteai")
        async let conversationB = store.createWebConversation(projectAlias: "g-p-remoteai")
        let (conversationResultA, conversationResultB) = await (conversationA, conversationB)
        let conversations = [conversationResultA, conversationResultB].compactMap { $0 }
        XCTAssertEqual(conversations.count, 1)
        let createConversationAttempts = await mock.actionAttemptCount("createConversation")
        let finalConversationCount = await mock.projectConversationCount("g-p-remoteai")
        XCTAssertEqual(createConversationAttempts, 1)
        XCTAssertEqual(finalConversationCount, 2, "Server Project must gain exactly one conversation")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 2)
        await store.suspend()
    }

    @MainActor
    func testStaleProjectAndConversationResponsesCannotOverwriteNewerMutations() async throws {
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()

        await mock.setResponseDelay(action: "listProjects", nanoseconds: 220_000_000)
        let staleProjectRefresh = Task { await store.refreshWebProjects() }
        for _ in 0..<100 {
            if await mock.actionAttemptCount("listProjects") > 0 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let createdProjectResult = await store.createWebProject(name: "Created During Stale Refresh")
        let createdProject = try XCTUnwrap(createdProjectResult)
        await staleProjectRefresh.value
        let serverProjectCount = await mock.projectCount()
        XCTAssertEqual(serverProjectCount, 3)
        XCTAssertEqual(store.webProjects.filter { $0.projectAlias == createdProject.projectAlias }.count, 1)
        XCTAssertEqual(store.webProjects.first?.projectAlias, createdProject.projectAlias, "A stale listProjects response must not erase the newly created Project")

        await mock.setResponseDelay(action: "listProjects", nanoseconds: 0)
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        await mock.setResponseDelay(action: "listProjectConversations", nanoseconds: 220_000_000)
        let baselineAttempts = await mock.actionAttemptCount("listProjectConversations")
        let staleConversationRefresh = Task { await store.loadProjectConversations(projectAlias: "g-p-remoteai") }
        for _ in 0..<100 {
            if await mock.actionAttemptCount("listProjectConversations") > baselineAttempts { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let createdConversationResult = await store.createWebConversation(projectAlias: "g-p-remoteai")
        let createdConversation = try XCTUnwrap(createdConversationResult)
        await staleConversationRefresh.value
        let serverConversationCount = await mock.projectConversationCount("g-p-remoteai")
        XCTAssertEqual(serverConversationCount, 2)
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.filter { $0.id == createdConversation.id }.count, 1)
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.first?.id, createdConversation.id, "A stale conversation page must not overwrite the newly created conversation")
        await store.suspend()
    }

    @MainActor
    func testPartialWebCatalogCannotOverwriteVerifiedProjectsConversationsOrCache() async throws {
        let mock = MockTransport(historyCount: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        await store.refreshWebProjects()
        await mock.setProjectConversationTitle(alias: "g-p-remoteai", conversationAlias: "mock-1", title: "ChatGPT deadbeef")
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        let verifiedProjects = store.webProjects
        let verifiedConversations = store.projectConversationsByAlias["g-p-remoteai"] ?? []
        XCTAssertEqual(verifiedProjects.count, 2)
        XCTAssertEqual(verifiedConversations.count, 1)
        XCTAssertEqual(verifiedConversations.first?.displayTitle, "ChatGPT deadbeef")

        await mock.setProjectConversationTitle(alias: "g-p-remoteai", conversationAlias: "mock-1", title: "Recovered real title")
        await mock.setScenario(.partialWebCatalog)
        await store.refreshWebProjects()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")

        XCTAssertEqual(store.webProjects, verifiedProjects, "A successful-but-partial Project snapshot must not replace verified live DOM state")
        let repairedConversations = store.projectConversationsByAlias["g-p-remoteai"] ?? []
        XCTAssertEqual(repairedConversations.map(\.localConversationId), verifiedConversations.map(\.localConversationId), "A partial conversation snapshot must not replace verified identities")
        XCTAssertEqual(repairedConversations.first?.displayTitle, "Recovered real title", "A matching verified alias may accept safer live title metadata from a partial DOM")
        let cachedProjects: [WebProjectDescriptor]? = try await cache.get([WebProjectDescriptor].self, key: "web.projects")
        let cachedConversations: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.g-p-remoteai.conversations")
        XCTAssertEqual(cachedProjects, verifiedProjects)
        XCTAssertEqual(cachedConversations?.map(\.localConversationId), verifiedConversations.map(\.localConversationId))
        XCTAssertEqual(cachedConversations?.first?.displayTitle, "Recovered real title")
        XCTAssertNotNil(store.errors["web.projects"])
        XCTAssertNotNil(store.errors["web.project.g-p-remoteai"])
        await store.suspend()
    }

    @MainActor
    func testUnseenProjectExplainsOfflineStateAndLoadsAfterReconnect() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-photo", count: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects()

        let cachedBefore: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.g-p-photo.conversations")
        XCTAssertNil(cachedBefore, "The regression requires a Project the phone has never loaded before")

        await store.suspend()
        await store.loadProjectConversations(projectAlias: "g-p-photo")
        XCTAssertTrue(store.projectConversationsByAlias["g-p-photo", default: []].isEmpty)
        XCTAssertEqual(store.errors["web.project.g-p-photo"], "PC Offline — connect to Windows to load this Project's conversations.")

        await store.resumeFromForeground()
        XCTAssertEqual(store.machine.state, .online)
        await store.loadProjectConversations(projectAlias: "g-p-photo")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-photo"]?.count, 1)
        XCTAssertNil(store.errors["web.project.g-p-photo"])
        let cachedAfter: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.g-p-photo.conversations")
        XCTAssertEqual(cachedAfter?.count, 1, "The first authoritative live load should become the phone's last-known-good Project cache")
        await store.suspend()
    }

    @MainActor
    func testDiagnosticsLogFiltersSensitiveFieldsAndKeepsSafeOperationalMetadata() throws {
        let log = DiagnosticsLog.shared
        log.clear()
        log.record("send_failed", fields: [
            "project": "g-p-safe",
            "messageText": "TOP_SECRET_MESSAGE",
            "accessToken": "TOP_SECRET_TOKEN",
            "errorType": "TransportError"
        ], level: "ERROR")
        XCTAssertTrue(log.text.contains("send_failed"))
        XCTAssertTrue(log.text.contains("project=g-p-safe"))
        XCTAssertTrue(log.text.contains("errorType=TransportError"))
        XCTAssertFalse(log.text.contains("TOP_SECRET_MESSAGE"))
        XCTAssertFalse(log.text.contains("TOP_SECRET_TOKEN"))
        log.clear()
    }

    @MainActor
    func testFreshPhoneBootstrapsFromWindowsLastKnownGoodWithoutPromotingItToAuthoritativeCache() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.setScenario(.staleWebCatalog)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        XCTAssertTrue(store.webProjects.isEmpty)
        await store.refreshWebProjects()
        XCTAssertEqual(store.webProjects.map(\.projectAlias), ["g-p-remoteai", "g-p-photo"])
        XCTAssertEqual(store.webProjectsSnapshotState, .staleCache)
        XCTAssertTrue(store.hasLoadedWebProjects)
        let cachedProjects: [WebProjectDescriptor]? = try await cache.get([WebProjectDescriptor].self, key: "web.projects")
        XCTAssertNil(cachedProjects, "Remote stale bootstrap must not become the phone's authoritative cache")

        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.map(\.conversationAlias), ["mock-1"])
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .staleCache)
        let cachedConversations: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.g-p-remoteai.conversations")
        XCTAssertNil(cachedConversations, "Remote stale conversation bootstrap must stay non-authoritative")
        await store.suspend()
    }

    @MainActor
    func testUnclassifiedWebCatalogFailsClosedAndKeepsLastKnownGoodState() async throws {
        let mock = MockTransport(historyCount: 1)
        let cache = try SQLiteStore.inMemory()
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await store.refreshWebProjects()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        let verifiedProjects = store.webProjects
        let verifiedConversations = store.projectConversationsByAlias["g-p-remoteai"] ?? []

        await mock.setScenario(.unclassifiedWebCatalog)
        await store.refreshWebProjects()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")

        XCTAssertEqual(store.webProjects, verifiedProjects, "Missing freshness metadata must never be treated as authoritative")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"], verifiedConversations)
        XCTAssertEqual(store.webProjectsSnapshotState, .providerUnavailable)
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .providerUnavailable)
        let cachedProjects: [WebProjectDescriptor]? = try await cache.get([WebProjectDescriptor].self, key: "web.projects")
        let cachedConversations: [WebConversationDescriptor]? = try await cache.get([WebConversationDescriptor].self, key: "web.project.g-p-remoteai.conversations")
        XCTAssertEqual(cachedProjects, verifiedProjects)
        XCTAssertEqual(cachedConversations, verifiedConversations)
        await store.suspend()
    }

    @MainActor
    func testRefreshStartedDuringCreateCannotOverwriteCommittedProjectOrConversation() async throws {
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.refreshWebProjects()

        await mock.setRequestDelay(action: "createProject", nanoseconds: 220_000_000)
        await mock.setResponseDelay(action: "listProjects", nanoseconds: 320_000_000)
        let createProjectTask = Task { await store.createWebProject(name: "Create Wins") }
        for _ in 0..<100 {
            if await mock.actionAttemptCount("createProject") > 0 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let refreshProjectTask = Task { await store.refreshWebProjects() }
        let createdProjectResult = await createProjectTask.value
        let createdProject = try XCTUnwrap(createdProjectResult)
        await refreshProjectTask.value
        XCTAssertEqual(store.webProjects.filter { $0.projectAlias == createdProject.projectAlias }.count, 1)
        XCTAssertEqual(store.webProjects.first?.projectAlias, createdProject.projectAlias, "A refresh launched during create must be invalidated by the create commit epoch")

        await mock.setRequestDelay(action: "createProject", nanoseconds: 0)
        await mock.setResponseDelay(action: "listProjects", nanoseconds: 0)
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        let baselineCreateAttempts = await mock.actionAttemptCount("createConversation")
        await mock.setRequestDelay(action: "createConversation", nanoseconds: 220_000_000)
        await mock.setResponseDelay(action: "listProjectConversations", nanoseconds: 320_000_000)
        let createConversationTask = Task { await store.createWebConversation(projectAlias: "g-p-remoteai") }
        for _ in 0..<100 {
            if await mock.actionAttemptCount("createConversation") > baselineCreateAttempts { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let refreshConversationTask = Task { await store.loadProjectConversations(projectAlias: "g-p-remoteai") }
        let createdConversationResult = await createConversationTask.value
        let createdConversation = try XCTUnwrap(createdConversationResult)
        await refreshConversationTask.value
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.filter { $0.id == createdConversation.id }.count, 1)
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.first?.id, createdConversation.id, "A refresh launched during create must not erase the committed conversation")
        await store.suspend()
    }

    @MainActor
    func testConversationPaginationRejectsSnapshotChange() async throws {
        let mock = MockTransport(historyCount: 1)
        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 65)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 30)
        XCTAssertEqual(store.projectHasMoreByAlias["g-p-remoteai"], true)

        await mock.seedProjectConversations(alias: "g-p-remoteai", count: 66)
        await store.loadMoreProjectConversations(projectAlias: "g-p-remoteai")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 30, "A page from a different server snapshot must not be merged")
        XCTAssertNotNil(store.errors["web.project.g-p-remoteai"])

        await store.loadProjectConversations(projectAlias: "g-p-remoteai")
        XCTAssertEqual(store.projectConversationsByAlias["g-p-remoteai"]?.count, 30)
        XCTAssertEqual(store.projectConversationSnapshotStateByAlias["g-p-remoteai"], .authoritativeLiveDOM)
        XCTAssertNil(store.errors["web.project.g-p-remoteai"])
        await store.suspend()
    }

    @MainActor
    func testUnknownCreateProjectDeliveryReusesCommandAndDoesNotDuplicateServerProject() async throws {
        let mock = MockTransport(scenario: .disconnectAfterCreateProject, historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()

        let first = await store.createWebProject(name: "Idempotent Project")
        XCTAssertNil(first)
        let afterUnknown = await mock.projectCount()
        XCTAssertEqual(afterUnknown, 3, "The first create side effect was committed before the response was lost")

        await mock.setScenario(.normal)
        try await mock.connect()
        let secondResult = await store.createWebProject(name: "Idempotent Project")
        let second = try XCTUnwrap(secondResult)
        let finalCount = await mock.projectCount()
        let createAttempts = await mock.actionAttemptCount("createProject")
        XCTAssertEqual(finalCount, 3, "Retry must replay the same command instead of creating a second Project")
        XCTAssertEqual(createAttempts, 2)
        XCTAssertEqual(store.webProjects.filter { $0.projectAlias == second.projectAlias }.count, 1)
        await store.suspend()
    }

    @MainActor
    func testAttachmentChunkDisconnectReplaysSameUploadWithoutDuplicatingBytes() async throws {
        let mock = MockTransport(scenario: .disconnectAfterAttachmentChunk, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        let operationId = UUID()
        let payload = Data((0..<220_000).map { UInt8($0 % 251) })
        let attachment = PendingAttachment(name: "large.bin", contentType: "application/octet-stream", data: payload)

        let first = await store.send(text: "chunk-recovery", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", attachments: [attachment], commandId: operationId)
        XCTAssertFalse(first)
        XCTAssertEqual(store.commandStates[operationId], .unknown)
        let interruptedFinishedCount = await mock.finishedAttachmentCount()
        XCTAssertEqual(interruptedFinishedCount, 0, "Interrupted upload must not be finalized early")

        await mock.setScenario(.normal)
        try await mock.connect()
        let second = await store.send(text: "chunk-recovery", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", attachments: [attachment], commandId: operationId)
        XCTAssertTrue(second)
        let finishedCount = await mock.finishedAttachmentCount()
        let finishedPayloads = await mock.finishedAttachmentPayloads()
        let serverUserCount = await mock.userMessageCount(sessionId: "photo-upload", text: "chunk-recovery")
        XCTAssertEqual(finishedCount, 1)
        XCTAssertEqual(finishedPayloads, [payload], "Chunk replay must converge to exactly the original bytes once")
        XCTAssertEqual(serverUserCount, 1)
        await store.suspend()
    }

    @MainActor
    func testUnknownAttachmentDeliveryRetriesExactCommandWithoutDuplicateSideEffect() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(scenario: .disconnectImmediatelyAfterSend, historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let commandId = UUID()
        let attachment = PendingAttachment(name: "proof.txt", contentType: "text/plain", data: Data("payload".utf8))

        let sent = await store.send(text: "unknown-with-attachment", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", attachments: [attachment], commandId: commandId)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.commandStates[commandId], .unknown)
        let saved = try await cache.get(RemoteCommand.self, key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertEqual(saved?.commandId, commandId)
        XCTAssertEqual(saved?.payload["attachmentIds"]?.arrayValue?.count, 1, "Retry payload must retain remote attachment IDs")
        let initialServerUserCount = await mock.userMessageCount(sessionId: "photo-upload", text: "unknown-with-attachment")
        XCTAssertEqual(initialServerUserCount, 1)

        await mock.setScenario(.normal)
        try await mock.connect()
        let web = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.web" }))
        await store.refreshRuntime(web)
        let photo = try XCTUnwrap(store.instances.first(where: { $0.id == "photo" }))
        await store.refreshSessions(runtime: web, instance: photo)
        let optimistic = try XCTUnwrap(store.messagesBySession["photo-upload"]?.first(where: { $0.id.caseInsensitiveCompare(commandId.uuidString) == .orderedSame }))
        await store.retry(message: optimistic, runtimeId: "runtime.web", instanceId: "photo")

        XCTAssertEqual(store.commandStates[commandId], .completed)
        let sendAttempts = await mock.actionAttemptCount("sendMessage")
        let finalServerUserCount = await mock.userMessageCount(sessionId: "photo-upload", text: "unknown-with-attachment")
        XCTAssertEqual(sendAttempts, 2, "One initial attempt plus one idempotent replay is expected")
        XCTAssertEqual(finalServerUserCount, 1, "Replay must not create a second server user message")
        let pendingAfter: RemoteCommand? = try await cache.get(RemoteCommand.self, key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertNil(pendingAfter)
        await store.suspend()
    }

    @MainActor
    func testRestartReconcilesUnknownDeliveryFromAuthoritativeServerState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = try SQLiteStore(url: url)
        let mock = MockTransport(scenario: .disconnectImmediatelyAfterSend, historyCount: 0)
        let firstStore = WorkspaceStore(transport: mock, cache: cache)
        await firstStore.start()
        let commandId = UUID()
        let firstSent = await firstStore.send(text: "restart-unknown", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", commandId: commandId)
        XCTAssertFalse(firstSent)
        XCTAssertEqual(firstStore.commandStates[commandId], .unknown)
        await firstStore.suspend()

        await mock.setScenario(.normal)
        let restored = WorkspaceStore(transport: mock, cache: cache)
        await restored.start()
        let web = try XCTUnwrap(restored.runtimes.first(where: { $0.id == "runtime.web" }))
        await restored.refreshRuntime(web)
        let photo = try XCTUnwrap(restored.instances.first(where: { $0.id == "photo" }))
        await restored.refreshSessions(runtime: web, instance: photo)
        await restored.loadSession("photo-upload")

        XCTAssertEqual(restored.commandStates[commandId], .completed, "Remote history should resolve unknown delivery after restart")
        let restartServerUserCount = await mock.userMessageCount(sessionId: "photo-upload", text: "restart-unknown")
        XCTAssertEqual(restartServerUserCount, 1)
        XCTAssertEqual(restored.messagesBySession["photo-upload", default: []].filter { $0.role == .user && $0.text == "restart-unknown" }.count, 1)
        let pending: RemoteCommand? = try await cache.get(RemoteCommand.self, key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertNil(pending)
        await restored.suspend()
    }

    @MainActor
    func testDefiniteSendFailureRemovesOptimisticAndPendingState() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await mock.setScenario(.commandFailure)
        let commandId = UUID()
        let sent = await store.send(text: "definite-failure", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", commandId: commandId)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.commandStates[commandId], .failed)
        XCTAssertFalse(store.messagesBySession["photo-upload", default: []].contains { $0.id.caseInsensitiveCompare(commandId.uuidString) == .orderedSame })
        let pending: RemoteCommand? = try await cache.get(RemoteCommand.self, key: "pending.command.my-pc.\(commandId.uuidString.lowercased())")
        XCTAssertNil(pending)
        let failedServerUserCount = await mock.userMessageCount(sessionId: "photo-upload", text: "definite-failure")
        XCTAssertEqual(failedServerUserCount, 0, "HTTP/transport failure must not be mistaken for a committed server message")
        await store.suspend()
    }

    @MainActor
    func testWorkspaceStoreStopReturnsSuccessAndConvergesSessionIdle() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let webRuntime = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.web" }))
        await store.refreshRuntime(webRuntime)
        let photoInstance = try XCTUnwrap(store.instances.first(where: { $0.id == "photo" }))
        await store.refreshSessions(runtime: webRuntime, instance: photoInstance)
        let stopped = await store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.sessions.first(where: { $0.id == "photo-upload" })?.state, .idle)
        await store.suspend()
    }

    @MainActor
    func testConcurrentStopRequestsShareOneIdempotentRemoteCommand() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        await mock.setRequestDelay(action: "stopGeneration", nanoseconds: 120_000_000)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        async let first = store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        try await Task.sleep(nanoseconds: 15_000_000)
        async let second = store.stop(runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        let results = await (first, second)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1, "A repeated Stop tap must join the in-flight idempotent Stop instead of reporting a false failure")
        let stopAttempts = await mock.actionAttemptCount("stopGeneration")
        XCTAssertEqual(stopAttempts, 1, "Concurrent Stop taps must produce exactly one remote Stop command")
        await store.suspend()
    }

    @MainActor
    func testWorkspaceStoreExposesLiveRunStatusUntilGenerationStops() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        _ = await store.send(text: "show-progress", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")

        for _ in 0..<80 {
            if store.liveRunStatusBySession["photo-upload"] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(store.liveRunStatusBySession["photo-upload"], "Live generation/tool progress should be visible while the remote run is active")

        for _ in 0..<100 {
            if store.liveRunStatusBySession["photo-upload"] == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(store.liveRunStatusBySession["photo-upload"], "Generation stop must clear the transient progress strip")
        await store.suspend()
    }

    @MainActor
    func testWorkspaceStoreReconcilesOptimisticAndStreamingMessages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        let db = try SQLiteStore(url: url)
        let mock = MockTransport(historyCount: 10)
        let store = WorkspaceStore(transport: mock, cache: db)
        await store.start()
        await store.send(text: "dedupe-check", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let messages = store.messagesBySession["photo-upload", default: []]
        XCTAssertEqual(messages.filter { $0.role == .user && $0.text == "dedupe-check" }.count, 1)
        XCTAssertEqual(messages.filter { $0.role == .assistant && $0.text == "Remote AI mock streaming response." }.count, 1)
        XCTAssertFalse(messages.contains { $0.role == .assistant && $0.toolStatus == "Streaming" })
        let tools = messages.filter { $0.kind == .toolEvent }
        XCTAssertEqual(tools.count, 1, "Tool start/finish events with the same provider tool id should update one card")
        XCTAssertEqual(tools.first?.toolStatus, "Completed")
        XCTAssertTrue(tools.first?.detail?.contains("Output\n384 tests passed") == true)
        await store.suspend()
    }

    func testSQLitePrefixKeysSupportPendingCommandRecoveryIsolation() async throws {
        let db = try SQLiteStore.inMemory()
        try await db.put("a", key: "pending.command.machine-a.111")
        try await db.put("b", key: "pending.command.machine-a.222")
        try await db.put("c", key: "pending.command.machine-b.333")
        let machineA: [String] = try await db.values(String.self, keyPrefix: "pending.command.machine-a.")
        XCTAssertEqual(machineA, ["a", "b"])
        let machineB: [String] = try await db.values(String.self, keyPrefix: "pending.command.machine-b.")
        XCTAssertEqual(machineB, ["c"])
    }

    func testSQLitePersistsMetadataAndCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        let db = try SQLiteStore(url: url)
        let machine = MachineMetadata(id: "pc", name: "My PC", state: .online)
        try await db.put(machine, key: "machine")
        try await db.setLastSequence(99)
        let restored: MachineMetadata? = try await db.get(MachineMetadata.self, key: "machine")
        XCTAssertEqual(restored, machine)
        let restoredSequence = try await db.lastSequence()
        XCTAssertEqual(restoredSequence, 99)
    }

    func testSQLiteRejectsOversizedDraftAndKeepsIntegrity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteStore(url: url)
        do {
            try await db.saveDraft(String(repeating: "x", count: SQLiteStore.maxKVBytes + 1), sessionId: "oversized")
            XCTFail("Expected oversized draft to be rejected")
        } catch {
            XCTAssertEqual(error as? StoreError, .valueTooLarge)
        }
        let integrityOK = try await db.integrityCheck()
        XCTAssertTrue(integrityOK)
    }

    func testSQLiteRejectsCorruptDatabaseFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not-a-sqlite-database".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try SQLiteStore(url: url))
    }

    func testSQLiteClearAllRemovesMetadataMessagesAndDrafts() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteStore(url: url)
        let message = ChatMessage(id: "m1", sessionId: "s", sequence: 1, role: .assistant, kind: .text, text: "cached", toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
        try await db.put("machine-a", key: "machine-id")
        try await db.saveDraft("draft", sessionId: "s")
        try await db.upsertMessages([message])

        try await db.clearAll()

        let machineId: String? = try await db.get(String.self, key: "machine-id")
        let draft = try await db.draft(sessionId: "s")
        let count = try await db.messageCount(sessionId: "s")
        let integrityOK = try await db.integrityCheck()
        XCTAssertNil(machineId)
        XCTAssertEqual(draft, "")
        XCTAssertEqual(count, 0)
        XCTAssertTrue(integrityOK)
    }

    func testSQLiteMessagePaginationUsesStableCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        let db = try SQLiteStore(url: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (1...100).map { index in
            ChatMessage(id: String(format: "m%03d", index), sessionId: "s", sequence: nil, role: .assistant, kind: .text, text: "\(index)", toolName: nil, toolStatus: nil, detail: nil, createdAt: base.addingTimeInterval(Double(index)))
        }
        try await db.upsertMessages(items)
        let recent = try await db.recentMessages(sessionId: "s", limit: 30)
        XCTAssertEqual(recent.count, 30)
        XCTAssertEqual(recent.first?.id, "m071")
        let cursor = try XCTUnwrap(recent.first?.cursor)
        let older = try await db.messagesBefore(sessionId: "s", before: cursor, limit: 20)
        XCTAssertEqual(older.first?.id, "m051")
        let count = try await db.messageCount(sessionId: "s")
        let minPage = try await db.recentMessages(sessionId: "s", limit: 0)
        let maxPage = try await db.recentMessages(sessionId: "s", limit: 1_000)
        XCTAssertEqual(count, 100)
        XCTAssertEqual(minPage.count, 1)
        XCTAssertEqual(maxPage.count, 100)
    }

    func testRuntimeHierarchyNamesAreDistinct() {
        XCTAssertEqual(RuntimeKind.web.displayName, "Web")
        XCTAssertEqual(RuntimeKind.codex.displayName, "Codex")
    }
}
