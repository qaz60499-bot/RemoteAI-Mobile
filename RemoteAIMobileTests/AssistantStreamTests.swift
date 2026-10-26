import XCTest
import Combine
import UIKit
@testable import RemoteAIMobile

final class AssistantStreamTests: XCTestCase {
    func testVisibleTailAdvancesAfterPreviewLimitWithoutFullMaterialization() {
        let stream = AssistantStream(id: "tail", revision: 0, text: String(repeating: "旧", count: 50_000))
        let before = stream.visibleText
        XCTAssertTrue(stream.append(id: "tail", baseRevision: 0, revision: 1, delta: "最新🙂e\u{301}"))
        XCTAssertEqual(stream.visibleText, before, "Network events wait for the presentation flush")
        stream.flushPresentation()
        XCTAssertTrue(stream.visibleText.hasSuffix("最新🙂e\u{301}"))
        XCTAssertLessThanOrEqual(stream.visibleText.count, 2001)
        XCTAssertEqual(stream.materializedBytes, 0)
        XCTAssertNotEqual(stream.visibleText, before)
        XCTAssertEqual(stream.text, String(repeating: "旧", count: 50_000) + "最新🙂e\u{301}")
    }

    @MainActor
    func testActiveTailPublishesWithoutRepublishingHistoryArray() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 100)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await mock.injectEvent(event(1201, payload: ["streamId": .string("tail"), "revision": .number(0), "content": .string(String(repeating: "a", count: 30_000)), "partial": .bool(true)]), deliverLive: true)
        for _ in 0..<100 {
            if store.messagesBySession["photo-upload", default: []].contains(where: { $0.toolStatus == "Streaming" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stream = try XCTUnwrap(store.assistantStreams["photo-upload"])
        var arrayPublications = 0
        let subscription = store.$messagesBySession.dropFirst().sink { _ in arrayPublications += 1 }
        let history = store.messagesBySession["photo-upload"]
        for revision in 1...3 {
            let marker = " 新内容\(revision)🙂"
            await mock.injectEvent(event(Int64(1201 + revision), payload: ["streamId": .string("tail"), "revision": .number(Double(revision)), "baseRevision": .number(Double(revision - 1)), "contentDelta": .string(marker), "partial": .bool(true)]), deliverLive: true)
            for _ in 0..<100 {
                if stream.visibleText.hasSuffix(marker) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(stream.visibleText.hasSuffix(marker))
        }
        XCTAssertEqual(arrayPublications, 0)
        XCTAssertEqual(store.messagesBySession["photo-upload"], history)
        XCTAssertEqual(stream.materializedBytes, 0)
        subscription.cancel()
        await store.suspend()
    }

    func testPresentationFlushPublishesTextAndByteCountAtomically() {
        let stream = AssistantStream(id: "atomic", revision: 0, text: "start")
        var publications = 0
        let subscription = stream.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(stream.append(id: "atomic", baseRevision: 0, revision: 1, delta: " more"))
        XCTAssertEqual(publications, 0, "Network deltas should remain buffered until the presentation flush")
        stream.flushPresentation()

        XCTAssertEqual(publications, 1, "One presentation flush must invalidate the streaming row only once")
        XCTAssertEqual(stream.visibleText, "start more")
        XCTAssertEqual(stream.visibleBytes, "start more".utf8.count)
        subscription.cancel()
    }

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

    @MainActor
    func testLoadOlderReportsOnlyActualPrepending() async throws {
        let store = WorkspaceStore(transport: MockTransport(historyCount: 120), cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadSession("photo-upload")
        let initial = store.messagesBySession["photo-upload", default: []]
        XCTAssertFalse(initial.isEmpty)
        var prepends = 0
        for _ in 0..<5 {
            let before = store.messagesBySession["photo-upload", default: []]
            let inserted = await store.loadOlder("photo-upload")
            let after = store.messagesBySession["photo-upload", default: []]
            if inserted {
                prepends += 1
                XCTAssertGreaterThan(after.count, before.count)
                XCTAssertNotEqual(after.first?.id, before.first?.id)
                XCTAssertEqual(Array(after.suffix(before.count)).map { $0.id }, before.map { $0.id })
            } else {
                XCTAssertEqual(after, before, "A no-op page must not claim a positioning correction")
                break
            }
        }
        XCTAssertGreaterThan(prepends, 0)
        let completed = store.messagesBySession["photo-upload"]
        let noMore = await store.loadOlder("photo-upload")
        XCTAssertFalse(noMore)
        XCTAssertEqual(store.messagesBySession["photo-upload"], completed)
        await store.suspend()
    }

    @MainActor
    func testCancelledOlderPageDoesNotPublishOrRequestRestoration() async throws {
        let store = WorkspaceStore(transport: MockTransport(historyCount: 120), cache: try SQLiteStore.inMemory())
        await store.start()
        await store.loadSession("photo-upload")
        let before = store.messagesBySession["photo-upload"]
        let load = Task { @MainActor in await store.loadOlder("photo-upload") }
        load.cancel()
        let inserted = await load.value
        XCTAssertFalse(inserted)
        XCTAssertEqual(store.messagesBySession["photo-upload"], before)
        await store.suspend()
    }

    @MainActor
    private final class ReadinessScroll: UIScrollView {
        var simulatedTracking = false
        var simulatedDragging = false
        var simulatedDecelerating = true
        override var isTracking: Bool { simulatedTracking }
        override var isDragging: Bool { simulatedDragging }
        override var isDecelerating: Bool { simulatedDecelerating }
    }

    @MainActor
    private func readinessFixture() -> (TranscriptLayoutReadiness, ReadinessScroll, UIView, UIWindow, UUID, TranscriptLayoutGeneration) {
        let readiness = TranscriptLayoutReadiness()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let scroll = ReadinessScroll(frame: window.bounds)
        window.addSubview(scroll)
        scroll.contentSize = CGSize(width: 390, height: 30_000)
        let root = UIView(frame: CGRect(origin: .zero, size: scroll.contentSize))
        scroll.addSubview(root)
        let binding = UUID()
        readiness.bind(scroll, root: root, id: binding)
        let generation = TranscriptLayoutGeneration(sessionID: "session", firstRowID: "older", rowCount: 41, browseRevision: 2, loading: false)
        return (readiness, scroll, root, window, binding, generation)
    }

    @MainActor
    func testPaginationReadinessRequiresCommittedGenerationAndNativeIdle() async {
        let (readiness, scroll, _, window, _, expected) = readinessFixture()
        let offset = scroll.contentOffset
        let wait = Task { @MainActor in await readiness.wait(for: expected) }
        for _ in 0..<100 where !readiness.isWaiting { await Task.yield() }
        XCTAssertTrue(readiness.isWaiting)
        scroll.simulatedDecelerating = false
        readiness.rendered(TranscriptLayoutGeneration(sessionID: "session", firstRowID: "older", rowCount: 41, browseRevision: 2, loading: true), size: scroll.contentSize)
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(readiness.isWaiting, "The loading-indicator layout is not the committed page")
        readiness.rendered(expected, size: CGSize(width: 390, height: 1_491))
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(readiness.isWaiting, "A root measurement without its matching mounted native root frame is premature")
        readiness.rendered(expected, size: scroll.contentSize)
        scroll.simulatedTracking = true
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(readiness.isWaiting)
        scroll.simulatedTracking = false
        scroll.simulatedDragging = true
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(readiness.isWaiting)
        scroll.simulatedDragging = false
        scroll.simulatedDecelerating = true
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(readiness.isWaiting)
        scroll.simulatedDecelerating = false
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        let ready = await wait.value
        XCTAssertTrue(ready)
        XCTAssertFalse(readiness.isWaiting)
        scroll.simulatedTracking = true
        XCTAssertFalse(readiness.isReady(for: expected), "A new native touch must invalidate readiness before the resumed task positions")
        scroll.simulatedTracking = false
        XCTAssertEqual(scroll.contentOffset, offset, "Readiness must never position the scroll view")
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testPaginationRootWitnessRejectsStaleFrameWithoutEquatingNativeContentExtent() {
        let (readiness, scroll, root, window, _, expected) = readinessFixture()
        scroll.simulatedDecelerating = false
        let committedSize = CGSize(width: 390, height: 35_019)
        readiness.rendered(expected, size: committedSize)
        root.frame.size.height = 1_491
        scroll.contentSize.height = 35_059
        XCTAssertFalse(readiness.isReady(for: expected), "Generation alone cannot acknowledge the old root frame")
        root.frame.size = committedSize
        XCTAssertTrue(readiness.isReady(for: expected), "A mounted matching root need not equal the scroll view's lazy content extent")
        root.removeFromSuperview()
        XCTAssertFalse(readiness.isReady(for: expected), "A detached root cannot witness this scroll view's layout")
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testPaginationCancelledWaitCannotConsumeReplacementIntent() async {
        let (readiness, scroll, window, _, expected) = readinessFixture()
        let first = Task { @MainActor in await readiness.wait(for: expected) }
        for _ in 0..<100 where !readiness.isWaiting { await Task.yield() }
        first.cancel()
        let replacement = Task { @MainActor in await readiness.wait(for: expected) }
        let cancelled = await first.value
        XCTAssertFalse(cancelled)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(readiness.isWaiting, "Late cancellation of an old intent must not cancel its replacement")
        readiness.rendered(expected, size: scroll.contentSize)
        scroll.simulatedDecelerating = false
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        let ready = await replacement.value
        XCTAssertTrue(ready)
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testPaginationReadinessTimeoutAndBindingOwnership() async {
        let (readiness, scroll, root, window, binding, expected) = readinessFixture()
        let wait = Task { @MainActor in await readiness.wait(for: expected) }
        for _ in 0..<100 where !readiness.isWaiting { await Task.yield() }
        readiness.unbind(id: UUID())
        XCTAssertTrue(readiness.isWaiting, "An obsolete marker must not detach its successor")
        readiness.sample(now: ProcessInfo.processInfo.systemUptime + 6)
        let timedOut = await wait.value
        XCTAssertFalse(timedOut)
        let detached = Task { @MainActor in await readiness.wait(for: expected) }
        for _ in 0..<100 where !readiness.isWaiting { await Task.yield() }
        readiness.unbind(id: binding)
        let detachedReady = await detached.value
        XCTAssertFalse(detachedReady)
        readiness.bind(scroll, root: root, id: UUID())
        readiness.rendered(expected, size: scroll.contentSize)
        scroll.simulatedDecelerating = false
        readiness.sample(now: ProcessInfo.processInfo.systemUptime)
        XCTAssertFalse(readiness.isWaiting, "Reattachment must not resurrect a consumed intent")
        withExtendedLifetime(window) {}
    }

    private func event(_ sequence: Int64, type: String = "MESSAGE_UPDATED", payload: [String: JSONValue]) -> RemoteEvent {
        RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: sequence, machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", type: type, payload: payload, createdAt: Date())
    }

    @MainActor
    func testLateToolFinishedCannotReviveStoppedWebRun() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 1)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()
        await mock.injectEvent(event(1201, type: "GENERATION_STARTED", payload: [:]), deliverLive: true)
        await mock.injectEvent(event(1202, type: "TOOL_STARTED", payload: ["tool": .string("ChatGPT Web"), "summary": .string("Thinking")]), deliverLive: true)
        await mock.injectEvent(event(1203, type: "GENERATION_STOPPED", payload: ["ok": .bool(true), "confirmedIdle": .bool(true)]), deliverLive: true)
        await mock.injectEvent(event(1204, type: "TOOL_FINISHED", payload: ["tool": .string("ChatGPT Web"), "summary": .string("Generation finished")]), deliverLive: true)
        for _ in 0..<100 {
            if (try? await cache.lastSequence()) == 1204 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.liveRunStatusBySession["photo-upload"])
        XCTAssertEqual(store.sessions.first(where: { $0.id == "photo-upload" })?.state, .idle)
        XCTAssertFalse(store.messagesBySession["photo-upload", default: []].contains { $0.toolStatus == "Running" })
        await store.suspend()
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
    func testProcessRestartRebuildsTransientStreamWithoutAdvancingDurableCursor() async throws {
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
        XCTAssertEqual(applied, 1201, "Transient stream content must remain replayable after process reset")
        await store.suspend()
    }
}
