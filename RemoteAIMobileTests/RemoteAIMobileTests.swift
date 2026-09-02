import XCTest
import Security
@testable import RemoteAIMobile

final class RemoteAIMobileTests: XCTestCase {
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
        XCTAssertEqual(Set(runtimes.map(\.id)), Set(["runtime.web", "runtime.cloudcode", "runtime.codex"]))
        XCTAssertEqual(runtimes.first(where: { $0.id == "runtime.cloudcode" })?.kind, .cloudCode)
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

    func testCloudCodeInstanceCarriesWorkspaceAndProviderCredentialModelCatalog() throws {
        let catalog = CloudCodeCatalog(
            providers: [
                CloudCodeProviderOption(id: "current", label: "Current", models: ["default"], defaultModel: "default", custom: false, requiresApiKey: false),
                CloudCodeProviderOption(id: "anthropic", label: "Anthropic", models: ["sonnet", "opus"], defaultModel: "sonnet", custom: false, requiresApiKey: true),
                CloudCodeProviderOption(id: "custom", label: "Custom", models: [], defaultModel: nil, custom: true, requiresApiKey: true)
            ],
            credentialProfiles: [
                CloudCodeCredentialOption(id: "work", label: "work"),
                CloudCodeCredentialOption(id: "backup", label: "backup")
            ],
            defaultProviderId: "anthropic",
            defaultCredentialProfileId: "work",
            supportsNewCredential: true
        )
        let server = ServerInstance(
            instanceId: "cloudcode.workspace",
            runtimeId: "runtime.cloudcode",
            label: "RemoteAI",
            kind: "claude-code-cli",
            config: [
                "projectPath": .string("D:\\wendangcodex\\RemoteAI"),
                "cloudCodeCatalog": try JSONValue.encode(catalog)
            ],
            status: "ready",
            updatedAt: Date()
        )
        let descriptor = server.descriptor
        XCTAssertEqual(descriptor.subtitle, "D:\\wendangcodex\\RemoteAI")
        let decoded = try XCTUnwrap(descriptor.cloudCodeCatalog)
        XCTAssertEqual(decoded.providers.map(\.id), ["current", "anthropic", "custom"])
        XCTAssertEqual(decoded.credentialProfiles.map(\.id), ["work", "backup"])
        XCTAssertEqual(decoded.defaultProviderId, "anthropic")
        XCTAssertEqual(decoded.defaultCredentialProfileId, "work")
        XCTAssertTrue(decoded.supportsNewCredential)
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
        await store.suspend()
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
        XCTAssertEqual(RuntimeKind.cloudCode.displayName, "Cloud Code")
        XCTAssertEqual(RuntimeKind.codex.displayName, "Codex")
    }
}
