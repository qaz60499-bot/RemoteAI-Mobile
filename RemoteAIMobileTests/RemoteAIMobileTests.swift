import XCTest
@testable import RemoteAIMobile

final class RemoteAIMobileTests: XCTestCase {
    func testCommandRoundTripKeepsIdempotencyId() throws {
        let id = UUID()
        let c = RemoteCommand.make(machineId: "pc", runtimeId: "web", instanceId: "chatgpt", sessionId: "s", action: "sendMessage", payload: ["text": .string("hello")], commandId: id)
        let data = try JSONEncoder.remoteAI.encode(c)
        let decoded = try JSONDecoder.remoteAI.decode(RemoteCommand.self, from: data)
        XCTAssertEqual(decoded.commandId, id)
        XCTAssertEqual(decoded.protocolVersion, "1")
        XCTAssertEqual(decoded.payload["text"]?.stringValue, "hello")
    }

    func testEventRoundTripPreservesSequence() throws {
        let e = RemoteEvent(protocolVersion: "1", eventId: UUID(), sequence: 42, machineId: "pc", runtimeId: "codex", instanceId: "codex6", sessionId: "s", type: "message.completed", payload: ["text": .string("ok")], createdAt: Date())
        let decoded = try JSONDecoder.remoteAI.decode(RemoteEvent.self, from: JSONEncoder.remoteAI.encode(e))
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.type, "message.completed")
    }

    func testSequenceTrackerDropsDuplicate() {
        var t = SequenceTracker(lastSequence: 10)
        XCTAssertTrue(t.ingest(10).duplicate)
        XCTAssertFalse(t.ingest(11).duplicate)
        XCTAssertEqual(t.lastSequence, 11)
    }

    func testSequenceTrackerDetectsGap() {
        var t = SequenceTracker(lastSequence: 10)
        let d = t.ingest(13)
        XCTAssertTrue(d.gap)
        XCTAssertFalse(d.duplicate)
    }

    func testCryptoRoundTrip() throws {
        let key = PayloadCrypto.mockPairingKey(code: "123456", machineId: "my-pc")
        let clear = Data("secret payload".utf8)
        let encrypted = try PayloadCrypto.encrypt(clear, keyData: key)
        XCTAssertNotEqual(encrypted.ciphertext, clear)
        XCTAssertEqual(try PayloadCrypto.decrypt(encrypted, keyData: key), clear)
    }

    func testMockRecentIsPaginated() async throws {
        let mock = MockTransport(historyCount: 1200)
        try await mock.connect()
        let page = try await mock.loadRecent(sessionId: "photo-upload", limit: 50)
        XCTAssertEqual(page.items.count, 50)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.last?.sequence, 1200)
    }

    func testMockLoadBeforeReturnsOlderPage() async throws {
        let mock = MockTransport(historyCount: 1200)
        let page = try await mock.loadBefore(sessionId: "photo-upload", before: 1151, limit: 40)
        XCTAssertEqual(page.items.count, 40)
        XCTAssertTrue(page.items.allSatisfy { $0.sequence < 1151 })
    }

    func testMockCommandIdempotency() async throws {
        let mock = MockTransport(historyCount: 10)
        try await mock.connect()
        let id = UUID()
        let c = RemoteCommand.make(machineId: "my-pc", runtimeId: "web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage", payload: ["text": .string("once")], commandId: id)
        let first = try await mock.send(c)
        let second = try await mock.send(c)
        XCTAssertEqual(first, .acknowledged)
        XCTAssertEqual(second, .acknowledged)
    }

    func testMockOfflineRejectsSend() async {
        let mock = MockTransport(scenario: .offline, historyCount: 10)
        do { try await mock.connect(); XCTFail("Expected offline") } catch { XCTAssertEqual(error as? TransportError, .offline) }
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

    func testSQLiteMessagePagination() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3")
        let db = try SQLiteStore(url: url)
        let items = (1...100).map { ChatMessage(id: "m\($0)", sessionId: "s", sequence: Int64($0), role: .assistant, kind: .text, text: "\($0)", toolName: nil, toolStatus: nil, detail: nil, createdAt: Date()) }
        try await db.upsertMessages(items)
        let recent = try await db.recentMessages(sessionId: "s", limit: 30)
        XCTAssertEqual(recent.count, 30)
        XCTAssertEqual(recent.first?.sequence, 71)
        let older = try await db.messagesBefore(sessionId: "s", before: 71, limit: 20)
        XCTAssertEqual(older.first?.sequence, 51)
        let count = try await db.messageCount(sessionId: "s")
        XCTAssertEqual(count, 100)
    }

    func testRuntimeHierarchyNamesAreDistinct() {
        XCTAssertEqual(RuntimeKind.web.rawValue, "Web")
        XCTAssertEqual(RuntimeKind.cloudCode.rawValue, "Cloud Code")
        XCTAssertEqual(RuntimeKind.codex.rawValue, "Codex")
    }
}
