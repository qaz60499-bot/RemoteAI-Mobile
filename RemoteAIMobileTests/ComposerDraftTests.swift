import XCTest
@testable import RemoteAIMobile

final class ComposerDraftTests: XCTestCase {
    @MainActor
    func testDelayedRestoreCannotReplaceEditThatWasClearedToEmpty() async throws {
        let storage = DraftStorage(values: ["chat": "saved text"], delayedLoads: ["chat"])
        let draft = ComposerDraft(debounceNanoseconds: 60_000_000_000)
        draft.bind(sessionId: "chat", load: { await storage.load($0) }, save: { id, text in
            await storage.save(text, sessionId: id)
        })
        try await waitUntil { await storage.isLoadPending("chat") }

        draft.text = "local edit"
        draft.text = ""
        await storage.resolveLoad("chat", with: "saved text")
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(draft.text, "", "An edit followed by clearing the field still invalidates the pending restore")
        await draft.flush()
        let saved = await storage.value(for: "chat")
        XCTAssertEqual(saved, "")
    }

    @MainActor
    func testLateLoadFromPreviousChatCannotChangeOrSaveIntoNewChat() async throws {
        let storage = DraftStorage(
            values: ["chat-a": "A draft", "chat-b": "B draft"],
            delayedLoads: ["chat-a"]
        )
        let draft = ComposerDraft(debounceNanoseconds: 60_000_000_000)
        let load: ComposerDraft.Loader = { await storage.load($0) }
        let save: ComposerDraft.Saver = { id, text in await storage.save(text, sessionId: id) }
        draft.bind(sessionId: "chat-a", load: load, save: save)
        try await waitUntil { await storage.isLoadPending("chat-a") }

        draft.bind(sessionId: "chat-b", load: load, save: save)
        try await waitUntil { draft.text == "B draft" }
        await storage.resolveLoad("chat-a", with: "A draft")
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(draft.text, "B draft")
        draft.text = "B edited"
        await draft.flush()
        let savedA = await storage.value(for: "chat-a")
        let savedB = await storage.value(for: "chat-b")
        XCTAssertEqual(savedA, "A draft")
        XCTAssertEqual(savedB, "B edited")
    }

    @MainActor
    func testFlushWhileInitialLoadIsPendingDoesNotOverwriteSavedDraft() async throws {
        let storage = DraftStorage(values: ["chat": "saved"], delayedLoads: ["chat"])
        let draft = ComposerDraft(debounceNanoseconds: 60_000_000_000)
        draft.bind(sessionId: "chat", load: { await storage.load($0) }, save: { id, text in
            await storage.save(text, sessionId: id)
        })
        try await waitUntil { await storage.isLoadPending("chat") }

        await draft.flush()
        await storage.resolveLoad("chat", with: "saved")
        try await waitUntil { draft.text == "saved" }

        let value = await storage.value(for: "chat")
        XCTAssertEqual(value, "saved")
    }

    @MainActor
    func testFlushPersistsBackgroundSnapshotAndEmptyPostSendSnapshot() async throws {
        let cache = try SQLiteStore.inMemory()
        let draft = ComposerDraft(debounceNanoseconds: 60_000_000_000)
        draft.bind(sessionId: "chat", load: { id in
            (try? await cache.draft(sessionId: id)) ?? ""
        }, save: { id, text in
            try? await cache.saveDraft(text, sessionId: id)
        })
        try await waitUntil { draft.isLoadResolved }

        draft.text = "background draft"
        await draft.flush()
        let backgroundValue = try await cache.draft(sessionId: "chat")
        XCTAssertEqual(backgroundValue, "background draft")

        // ChatView clears the field at send dispatch. Its pre-send flush must land
        // after older debounced writes, so a later accepted-send clear stays durable.
        draft.text = ""
        await draft.flush()
        let sentValue = try await cache.draft(sessionId: "chat")
        XCTAssertEqual(sentValue, "")
    }

    @MainActor
    func testRapidSavesAreSerializedAndLatestValueWins() async throws {
        let storage = DraftStorage(holdFirstSave: true)
        let draft = ComposerDraft(debounceNanoseconds: 10_000_000)
        draft.bind(sessionId: "chat", load: { await storage.load($0) }, save: { id, text in
            await storage.save(text, sessionId: id)
        })
        try await waitUntil { draft.isLoadResolved }

        draft.text = "first"
        try await waitUntil { await storage.isFirstSavePending }
        draft.text = "latest"
        let flush = Task { @MainActor in await draft.flush() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await storage.releaseFirstSave()
        await flush.value

        let history = await storage.saveHistory(for: "chat")
        let latest = await storage.value(for: "chat")
        XCTAssertEqual(history, ["first", "latest"])
        XCTAssertEqual(latest, "latest")
    }

    @MainActor
    func testClearAfterSendKeepsTextTypedAfterDispatch() async throws {
        let storage = DraftStorage()
        let draft = ComposerDraft(debounceNanoseconds: 60_000_000_000)
        draft.bind(sessionId: "chat", load: { await storage.load($0) }, save: { id, text in
            await storage.save(text, sessionId: id)
        })
        try await waitUntil { draft.isLoadResolved }

        let sentRevision = draft.revision
        draft.text = "newer text"
        await draft.clearAfterSend(ifRevision: sentRevision)

        XCTAssertEqual(draft.text, "newer text")
        let saved = await storage.value(for: "chat")
        XCTAssertEqual(saved, "newer text")
    }

    @MainActor
    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor DraftStorage {
    private var values: [String: String]
    private var delayedLoads: Set<String>
    private var pendingLoads: [String: CheckedContinuation<String, Never>] = [:]
    private var pendingLoadIds: Set<String> = []
    private var saveHistoryBySession: [String: [String]] = [:]
    private var holdFirstSave: Bool
    private var didHoldFirstSave = false
    private var firstSavePending = false
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?

    init(
        values: [String: String] = [:],
        delayedLoads: Set<String> = [],
        holdFirstSave: Bool = false
    ) {
        self.values = values
        self.delayedLoads = delayedLoads
        self.holdFirstSave = holdFirstSave
    }

    func load(_ sessionId: String) async -> String {
        guard delayedLoads.contains(sessionId) else { return values[sessionId] ?? "" }
        pendingLoadIds.insert(sessionId)
        return await withCheckedContinuation { continuation in
            pendingLoads[sessionId] = continuation
        }
    }

    func save(_ text: String, sessionId: String) async {
        if holdFirstSave && !didHoldFirstSave {
            didHoldFirstSave = true
            firstSavePending = true
            await withCheckedContinuation { continuation in
                firstSaveContinuation = continuation
            }
            firstSavePending = false
        }
        values[sessionId] = text
        saveHistoryBySession[sessionId, default: []].append(text)
    }

    func resolveLoad(_ sessionId: String, with text: String) {
        pendingLoadIds.remove(sessionId)
        pendingLoads.removeValue(forKey: sessionId)?.resume(returning: text)
    }

    func isLoadPending(_ sessionId: String) -> Bool { pendingLoadIds.contains(sessionId) }
    func isFirstSavePending() -> Bool { firstSavePending }
    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }
    func value(for sessionId: String) -> String? { values[sessionId] }
    func saveHistory(for sessionId: String) -> [String] { saveHistoryBySession[sessionId, default: []] }
}
