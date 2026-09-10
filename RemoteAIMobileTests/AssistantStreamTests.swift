import XCTest
@testable import RemoteAIMobile

final class AssistantStreamTests: XCTestCase {
    func testUnicodeDuplicateGapAndRewrite() {
        let stream = AssistantStream(id: "one", revision: 1, text: "中文🙂")
        XCTAssertTrue(stream.append(id: "one", baseRevision: 1, revision: 2, delta: " e\u{301}"))
        XCTAssertFalse(stream.append(id: "one", baseRevision: 1, revision: 2, delta: "duplicate"))
        XCTAssertFalse(stream.append(id: "one", baseRevision: 3, revision: 4, delta: "gap"))
        XCTAssertFalse(stream.append(id: "other", baseRevision: 2, revision: 3, delta: "wrong generation"))
        XCTAssertEqual(stream.text, "中文🙂 e\u{301}")
        let rewritten = AssistantStream(id: "one", revision: 3, text: "重写")
        XCTAssertTrue(rewritten.append(id: "one", baseRevision: 3, revision: 4, delta: "完成"))
        XCTAssertEqual(rewritten.text, "重写完成")
    }

    func testLongStreamMaterializesOnlyOnExplicitFullTextAccess() {
        for count in [1_000, 10_000, 30_000, 50_000, 100_000, 150_000] {
            let stream = AssistantStream(id: "long", revision: 0, text: "")
            let start = Date()
            let cache = MessageRenderCache()
            var preparationMs = 0.0
            for n in 0..<(count / 100) {
                XCTAssertTrue(stream.append(id: "long", baseRevision: Int64(n), revision: Int64(n + 1), delta: String(repeating: "x", count: 100)))
                XCTAssertLessThanOrEqual(stream.presentationText.count, 2001)
                let renderStart = Date()
                let message = ChatMessage(id: "stream", sessionId: "bench", sequence: 1, role: .assistant, kind: .text, text: stream.presentationText, toolName: nil, toolStatus: "Streaming", detail: nil, createdAt: .distantPast)
                _ = cache.content(for: message)
                preparationMs += Date().timeIntervalSince(renderStart) * 1000
            }
            let applyMs = Date().timeIntervalSince(start) * 1000
            XCTAssertEqual(stream.materializedBytes, 0)
            XCTAssertEqual(stream.utf8Count, count)
            XCTAssertEqual(stream.text, String(repeating: "x", count: count))
            XCTAssertEqual(stream.materializedBytes, count)
            print("STREAM_BUFFER_BENCH chars=\(count) applyAndPreparationMs=\(applyMs) preparationMs=\(preparationMs) previewChars=\(stream.presentationText.count) fullMaterializations=1 layoutMs=unmeasured")
        }
    }

    private func event(_ sequence: Int64, type: String = "MESSAGE_UPDATED", payload: [String: JSONValue]) -> RemoteEvent {
        RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: sequence, machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", type: type, payload: payload, createdAt: Date())
    }

    @MainActor
    func testOnlineQuietSocketDetectsMissingFinalAndRecoversWithoutReconnect() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        let final = event(1201, type: "MESSAGE_ADDED", payload: ["messageId": .string("canonical-final"), "sessionId": .string("photo-upload"), "role": .string("assistant"), "content": .string("电脑已经完成🙂"), "createdAt": .string(Date().ISO8601Format())])
        await mock.injectEvent(final, deliverLive: false)
        await mock.setSequence(1201)
        XCTAssertEqual(store.machine.state, .online)
        await store.verifyOnlineSyncHead()
        XCTAssertEqual(store.syncState, "synced")
        let applied = try await cache.lastSequence()
        XCTAssertEqual(applied, 1201)
        XCTAssertTrue(store.messagesBySession["photo-upload", default: []].contains { $0.id == "canonical-final" && $0.text == "电脑已经完成🙂" })
        XCTAssertEqual(store.machine.state, .online)
        await store.suspend()
    }

    @MainActor
    func testProcessRestartRebuildsTransientStreamFromExistingCursorAPI() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 1)
        // Cursor survives but the in-memory prefix does not.
        try await cache.setLastSequence(1201)
        await mock.setSequence(1201)
        await mock.injectEvent(event(1201, payload: ["streamId": .string("resume"), "revision": .number(1), "content": .string("prefix🙂"), "partial": .bool(true)]))
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await mock.injectEvent(event(1202, payload: ["streamId": .string("resume"), "revision": .number(2), "baseRevision": .number(1), "streamStartSequence": .number(1201), "contentDelta": .string(" tail"), "partial": .bool(true)]), deliverLive: true)
        for _ in 0..<100 {
            if store.streamingFullText(sessionId: "photo-upload", fallback: "") == "prefix🙂 tail" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.streamingFullText(sessionId: "photo-upload", fallback: ""), "prefix🙂 tail")
        XCTAssertNil(store.errors["sync"])
        let applied = try await cache.lastSequence()
        XCTAssertEqual(applied, 1202)
        await store.suspend()
    }
}
