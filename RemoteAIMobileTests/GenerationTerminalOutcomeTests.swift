import XCTest
@testable import RemoteAIMobile

final class GenerationTerminalOutcomeTests: XCTestCase {
    @MainActor
    func testAntigravityCanceledTerminalKeepsPartialAndDoesNotDuplicateIt() async throws {
        let (mock, store) = try await makeStartedStore()
        let now = Date()
        await inject(mock, sequence: 1201, type: "GENERATION_STARTED", payload: [:], at: now)
        await inject(mock, sequence: 1202, type: "MESSAGE_UPDATED", payload: [
            "role": .string("assistant"),
            "content": .string("partial answer"),
            "partial": .bool(true),
        ], at: now.addingTimeInterval(0.01))
        await inject(mock, sequence: 1203, type: "TOOL_STARTED", payload: [
            "tool": .object(["id": .string("tool-1"), "name": .string("Editor")]),
            "summary": .string("editing"),
        ], at: now.addingTimeInterval(0.02))

        let canceled: [String: JSONValue] = [
            "ok": .bool(false),
            "stopped": .bool(true),
            "reason": .string("canceled"),
            "errorCode": .string("GENERATION_CANCELED"),
        ]
        await inject(mock, sequence: 1204, type: "GENERATION_STOPPED", payload: canceled, at: now.addingTimeInterval(0.03))
        for _ in 0..<100 where store.systemNotice(forSessionId: "photo-upload")?.text.contains("取消") != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.sessions.first(where: { $0.id == "photo-upload" })?.state, .idle)
        XCTAssertTrue(store.systemNotice(forSessionId: "photo-upload")?.text.contains("取消") == true)
        XCTAssertNil(store.errors["photo-upload"])
        XCTAssertNil(store.liveRunStatusBySession["photo-upload"])
        XCTAssertNil(store.assistantStreams["photo-upload"])
        let partials = store.messagesBySession["photo-upload", default: []].filter {
            $0.role == .assistant && $0.text == "partial answer"
        }
        XCTAssertEqual(partials.count, 1)
        XCTAssertNil(partials.first?.toolStatus)
        let tool = try XCTUnwrap(store.messagesBySession["photo-upload", default: []].first { $0.kind == .toolEvent })
        XCTAssertEqual(tool.toolStatus, "Interrupted")

        await inject(mock, sequence: 1205, type: "GENERATION_STOPPED", payload: canceled, at: now.addingTimeInterval(0.04))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.messagesBySession["photo-upload", default: []].filter {
            $0.role == .assistant && $0.text == "partial answer"
        }.count, 1)
        XCTAssertNil(store.liveRunStatusBySession["photo-upload"])
        await store.suspend()
    }

    @MainActor
    func testAntigravityInterruptedUnknownAndConfirmedFailureHaveDistinctTerminalStates() async throws {
        let cases: [(payload: [String: JSONValue], state: SessionState, banner: String)] = [
            (
                [
                    "ok": .bool(false),
                    "reason": .string("interrupted"),
                    "errorCode": .string("GENERATION_INTERRUPTED"),
                    "errorMessage": .string("generation interrupted; partial answer retained"),
                ],
                .idle,
                "interrupted"
            ),
            (
                [
                    "ok": .bool(false),
                    "reason": .string("terminal-unknown"),
                    "delivery": .string("unknown"),
                    "errorMessage": .string("generation outcome unknown; partial answer retained"),
                ],
                .unknown,
                "unknown"
            ),
            (
                ["ok": .bool(false)],
                .unknown,
                "未知"
            ),
            (
                [
                    "ok": .bool(false),
                    "reason": .string("failed"),
                    "errorCode": .string("GENERATION_FAILED"),
                    "errorMessage": .string("provider failed"),
                ],
                .error,
                "provider failed"
            ),
        ]

        for (index, terminalCase) in cases.enumerated() {
            let (mock, store) = try await makeStartedStore()
            let now = Date()
            // Each case creates a fresh MockTransport with a 1200 cursor baseline.
            // Do not invent gaps (1301+) here: those exercise unrelated delta recovery
            // and can prevent the terminal-state event from reaching WorkspaceStore.
            let startSequence: Int64 = 1201
            let sessionId = "photo-upload"
            await inject(mock, sequence: startSequence, type: "GENERATION_STARTED", payload: [:], at: now)
            await inject(mock, sequence: startSequence + 1, type: "MESSAGE_UPDATED", payload: [
                "role": .string("assistant"),
                "content": .string("partial answer"),
                "partial": .bool(true),
            ], at: now.addingTimeInterval(0.01))
            await inject(mock, sequence: startSequence + 2, type: "TOOL_STARTED", payload: [
                "tool": .object(["id": .string("tool-\(index)"), "name": .string("Editor")]),
                "summary": .string("editing"),
            ], at: now.addingTimeInterval(0.02))
            await inject(mock, sequence: startSequence + 3, type: "GENERATION_STOPPED", payload: terminalCase.payload, at: now.addingTimeInterval(0.03))

            for _ in 0..<100 {
                let hasFailureBanner = store.errors[sessionId]?.localizedCaseInsensitiveContains(terminalCase.banner) == true
                let hasTerminalNotice = store.systemNotice(forSessionId: sessionId)?.text.localizedCaseInsensitiveContains(terminalCase.banner) == true
                if hasFailureBanner || hasTerminalNotice { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(store.sessions.first(where: { $0.id == sessionId })?.state, terminalCase.state)
            let hasFailureBanner = store.errors[sessionId]?.localizedCaseInsensitiveContains(terminalCase.banner) == true
            let hasTerminalNotice = store.systemNotice(forSessionId: sessionId)?.text.localizedCaseInsensitiveContains(terminalCase.banner) == true
            XCTAssertTrue(hasFailureBanner || hasTerminalNotice)
            if terminalCase.state == .error {
                XCTAssertTrue(hasFailureBanner)
            } else {
                XCTAssertFalse(hasFailureBanner)
                XCTAssertNotNil(store.systemNotice(forSessionId: sessionId))
            }
            XCTAssertNil(store.liveRunStatusBySession[sessionId])
            XCTAssertNil(store.assistantStreams[sessionId])
            let partials = store.messagesBySession[sessionId, default: []].filter {
                $0.role == .assistant && $0.text == "partial answer"
            }
            XCTAssertEqual(partials.count, 1)
            XCTAssertNil(partials.first?.toolStatus)
            let tool = try XCTUnwrap(store.messagesBySession[sessionId, default: []].first { $0.kind == .toolEvent })
            XCTAssertEqual(tool.toolStatus, "Interrupted")
            await store.suspend()
        }
    }

    @MainActor
    private func makeStartedStore() async throws -> (MockTransport, WorkspaceStore) {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        return (mock, store)
    }

    @MainActor
    private func inject(
        _ mock: MockTransport,
        sequence: Int64,
        type: String,
        payload: [String: JSONValue],
        at date: Date
    ) async {
        await mock.injectEvent(
            RemoteEvent(
                protocolVersion: 1,
                eventId: UUID(),
                sequence: sequence,
                machineId: "my-pc",
                runtimeId: "runtime.antigravity",
                instanceId: "photo",
                sessionId: "photo-upload",
                type: type,
                payload: payload,
                createdAt: date
            ),
            deliverLive: true
        )
    }
}
