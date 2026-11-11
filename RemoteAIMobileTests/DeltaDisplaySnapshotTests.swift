import XCTest
@testable import RemoteAIMobile

final class DeltaDisplaySnapshotTests: XCTestCase {
    @MainActor
    func testDetachedChatFaultRestoresFromProtectedCacheAfterColdStartWithoutCrossChatLeak() async throws {
        let cache = try SQLiteStore.inMemory()
        let observed = Date(timeIntervalSince1970: 1_799_000_000)
        let original = SessionDescriptor(id: "original-chat", instanceId: "web.chatgpt",
            title: "Original Chat", state: .idle, updatedAt: observed)
        let different = SessionDescriptor(id: "other-chat", instanceId: "web.chatgpt",
            title: "Other Chat", state: .idle, updatedAt: observed)
        let nonWeb = SessionDescriptor(id: "non-web", instanceId: "codex.instance",
            title: "Other Runtime", state: .idle, updatedAt: observed)
        let note = "本 Chat 的电脑端 ChatGPT 标签页已关闭；原历史缓存保留，需人工核验。"
        try await cache.put(WorkspaceStore.StoredWebBindingFault(machineId: "my-pc",
            sessionId: original.id, observedAt: observed, note: note),
            key: WorkspaceStore.webBindingFaultKey(original.id))
        try await cache.put(WorkspaceStore.StoredWebBindingFault(machineId: "different-machine",
            sessionId: different.id, observedAt: observed, note: "Foreign machine"),
            key: WorkspaceStore.webBindingFaultKey(different.id))
        try await cache.put(WorkspaceStore.StoredWebBindingFault(machineId: "my-pc",
            sessionId: nonWeb.id, observedAt: observed, note: "Not Web"),
            key: WorkspaceStore.webBindingFaultKey(nonWeb.id))
        for _ in 0..<2 {
            // A new WorkspaceStore models an app restart with a persisted event cursor:
            // it must not need the old WEB_BINDING_CHANGED event to be redelivered.
            let rebooted = WorkspaceStore(transport: MockTransport(historyCount: 0), cache: cache)
            rebooted.sessions = [original, different, nonWeb]
            await rebooted.restorePersistedWebBindingFaults()
            XCTAssertTrue(rebooted.isWebBindingDetached(original.id))
            XCTAssertEqual(rebooted.webChatBindingFaultAtBySession[original.id], observed)
            XCTAssertEqual(rebooted.webChatRecoveryNotesBySession[original.id], note)
            XCTAssertFalse(rebooted.isWebBindingDetached(different.id), "Never show other machine's fault")
            XCTAssertFalse(rebooted.isWebBindingDetached(nonWeb.id), "Only real web Chat scope")
        }
    }

    @MainActor
    func testWebFaultFilteringKeepsStaleAndDisconnectedReportsUnconfirmed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-30)
        let stale = now.addingTimeInterval(-180)
        let current = WebAnomalyDisplayStatus.classify(
            surfaceState: "degraded", hasIssue: true, observedAt: recent, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(current, .current)

        let offline = WebAnomalyDisplayStatus.classify(
            surfaceState: "degraded", hasIssue: true, observedAt: recent, recoveredAt: nil,
            machineOnline: false, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(offline, .uncertain, "Disconnected Windows must never present a cached issue as current")

        let old = WebAnomalyDisplayStatus.classify(
            surfaceState: "degraded", hasIssue: true, observedAt: stale, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(old, .uncertain, "Old Provider errors require a fresh inspection")

        let recovered = WebAnomalyDisplayStatus.classify(
            surfaceState: "online", hasIssue: false, observedAt: recent, recoveredAt: recent,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(recovered, .recovered)

        let noSource = WebAnomalyDisplayStatus.classify(
            surfaceState: nil, hasIssue: false, observedAt: nil, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertNil(noSource, "Unknown-only categories must not invent a fault for an unobserved Chat")
        let sessionOnly = WebAnomalyDisplayStatus.classify(
            surfaceState: nil, hasIssue: false, hasSessionError: true,
            observedAt: nil, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(sessionOnly, .uncertain, "Unverified selector/history errors must be filterable, never called live Provider faults")

        let closedOriginalTab = WebAnomalyDisplayStatus.classify(
            surfaceState: nil, hasIssue: false, bindingDetached: true,
            observedAt: nil, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(closedOriginalTab, .uncertain,
            "A real tabClosed binding event must remain visible in 待核验 even without a Provider issue object")
        XCTAssertEqual(WebAnomalyDisplayStatus.detachedErrorCode, "WEB_BINDING_UNVERIFIED",
            "The detached original Chat needs a stable visible reason code")
        let detachedPreviouslyRecovered = WebAnomalyDisplayStatus.classify(
            surfaceState: "online", hasIssue: false, bindingDetached: true,
            observedAt: recent, recoveredAt: recent,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(detachedPreviouslyRecovered, .uncertain,
            "Stale source recovery cannot override a newly detached original Chat")
        let detachedWhileProviderDegraded = WebAnomalyDisplayStatus.classify(
            surfaceState: "degraded", hasIssue: true, bindingDetached: true,
            observedAt: recent, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: now)
        XCTAssertEqual(detachedWhileProviderDegraded, .uncertain,
            "Without the exact bound document, a Provider report must not be labeled a current verified fault")

        let browserDown = WebAnomalyDisplayStatus.classify(
            surfaceState: "degraded", hasIssue: true, observedAt: recent, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: false, now: now)
        XCTAssertEqual(browserDown, .uncertain)
    }

    @MainActor
    func testReadyChromeWithInvalidDocumentProofMustRemainUnverifiedOnIPhone() throws {
        let invalid = """
        {
          "tabId": 12,
          "state": "ready",
          "generating": false,
          "composerReady": true,
          "freshDocumentProofPresent": true,
          "freshDocumentProofValid": false,
          "proofValidityFailure": "invalidated",
          "firstProofInvalidation": {
            "source": "navigate",
            "navigationType": "replace",
            "destinationSameDocument": true,
            "destinationExactInitialUrl": true,
            "at": "2026-11-10T13:34:18.615Z"
          }
        }
        """.data(using: .utf8)!
        let diagnosis = try JSONDecoder().decode(WebTabDiagnosis.self, from: invalid)
        XCTAssertEqual(diagnosis.state, "ready", "Chrome shell can appear healthy")
        XCTAssertEqual(diagnosis.freshDocumentProofPresent, true)
        XCTAssertEqual(diagnosis.freshDocumentProofValid, false)
        XCTAssertTrue(diagnosis.sourceProofReason?.contains("同文档 replace") == true,
            "Exact same-URL replace invalidation must show its reason on the phone")
        XCTAssertEqual(WebAnomalyDisplayStatus.classify(
            surfaceState: nil, hasIssue: false, hasSessionError: diagnosis.sourceProofReason != nil,
            observedAt: nil, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: true, now: Date()), .uncertain,
            "An invalid document proof must be filterable as 待核验, never current Provider outage or recovered")

        let valid = """
        {"tabId":12,"state":"ready","freshDocumentProofPresent":true,"freshDocumentProofValid":true}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(WebTabDiagnosis.self, from: valid).sourceProofReason,
            "A valid source proof must not display a historical invalidation")

        let legacy = """
        {"tabId":12,"state":"ready"}
        """.data(using: .utf8)!
        XCTAssertNotNil(try JSONDecoder().decode(WebTabDiagnosis.self, from: legacy).sourceProofReason,
            "A legacy Agent that omits proof cannot certify complete Provider history")
    }

    @MainActor
    func testEmptyDeltaSnapshotCannotHideHydratedOriginalWebHistory() {
        let cached = [
            ServerMessage(
                messageId: "cached-original-user",
                sessionId: "original-web",
                role: "user",
                content: "Durable original question",
                externalId: nil,
                createdAt: Date().addingTimeInterval(-30)
            ).chatMessage,
            ServerMessage(
                messageId: "cached-original-assistant",
                sessionId: "original-web",
                role: "assistant",
                content: "Durable original reply",
                externalId: nil,
                createdAt: Date().addingTimeInterval(-20)
            ).chatMessage
        ]
        let ids = cached.map(\.id)
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: []).map(\.id),
            ids,
            "An empty historical delta snapshot must not hide durable User/Assistant history"
        )
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: nil).map(\.id),
            ids
        )
        let runningOnly = ChatMessage(
            id: "frozen-running", sessionId: "original-web", sequence: nil,
            role: .tool, kind: .toolEvent, text: "", toolName: "ChatGPT Web",
            toolStatus: "Running", detail: nil, attachments: nil, createdAt: Date()
        )
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: [runningOnly]).map(\.id),
            ids,
            "A frozen Running-only tool row must not replace cached User/Assistant history"
        )
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: [cached[0]]).map(\.id),
            ids,
            "A replay snapshot with one cached turn must not hide the remaining durable reply"
        )
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(canonical: cached, deltaSnapshot: cached).map(\.id),
            ids,
            "A complete replay snapshot retains normal coalescing behavior"
        )
        XCTAssertTrue(ChatView.visibleHistoryMessages(canonical: [], deltaSnapshot: []).isEmpty)
    }

    @MainActor
    func testRunningOnlyAndEmptyAssistantMustNotSuppressWebHistoryRecovery() {
        let runningOnly = ChatMessage(
            id: "tool-running-only", sessionId: "web-no-source", sequence: nil,
            role: .tool, kind: .toolEvent, text: "",
            toolName: "ChatGPT Web", toolStatus: "Running",
            detail: nil, attachments: nil, createdAt: Date()
        )
        XCTAssertFalse(ChatView.hasDisplayableWebTranscriptBody([runningOnly]),
            "A Running tool row alone must not hide the history-not-ready and recovery controls")
        XCTAssertFalse(ChatView.hasDisplayableWebTranscriptBody([]),
            "No cached rows must still display history-not-ready")

        let blankReply = ServerMessage(
            messageId: "assistant-empty", sessionId: "web-no-source",
            role: "assistant", content: "", externalId: nil, createdAt: Date()
        ).chatMessage
        XCTAssertFalse(ChatView.hasDisplayableWebTranscriptBody([runningOnly, blankReply]),
            "A blank Assistant envelope must not count as original transcript body")

        let durable = ServerMessage(
            messageId: "assistant-present", sessionId: "web-no-source",
            role: "assistant", content: "Original durable reply", externalId: nil, createdAt: Date()
        ).chatMessage
        XCTAssertTrue(ChatView.hasDisplayableWebTranscriptBody([runningOnly, durable]),
            "Real User/Assistant body should keep the ordinary chat layout")

        var activeAssistant = blankReply
        activeAssistant.toolStatus = "Streaming"
        XCTAssertTrue(ChatView.hasDisplayableWebTranscriptBody([activeAssistant],
            hasActiveAssistantStream: true),
            "An existing live Assistant stream must not be overlaid by history-not-ready")
        XCTAssertFalse(ChatView.hasDisplayableWebTranscriptBody([activeAssistant],
            hasActiveAssistantStream: false),
            "A stale Streaming marker without an active stream is not a verified body")
    }

    @MainActor
    func testDeltaWithSameMessageIdsMustNotHideLongerDurableBodies() {
        let first = ServerMessage(
            messageId: "user-stable-id", sessionId: "original-web",
            role: "user", content: "Complete durable User body",
            externalId: nil, createdAt: Date().addingTimeInterval(-30)
        ).chatMessage
        let reply = ServerMessage(
            messageId: "assistant-stable-id", sessionId: "original-web",
            role: "assistant", content: "Complete durable Assistant answer",
            externalId: nil, createdAt: Date().addingTimeInterval(-20)
        ).chatMessage
        var emptyReplay = reply
        emptyReplay.text = ""
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(
                canonical: [first, reply], deltaSnapshot: [first, emptyReplay]
            ).map(\.text),
            [first.text, reply.text],
            "A delta with matching IDs but blank Assistant text must not erase durable history"
        )
        var shorterReplay = reply
        shorterReplay.text = "Complete"
        XCTAssertEqual(
            ChatView.visibleHistoryMessages(
                canonical: [first, reply], deltaSnapshot: [first, shorterReplay]
            ).last?.text,
            reply.text,
            "A truncated replay with the same UUID cannot replace a previously hydrated reply"
        )
    }
}
