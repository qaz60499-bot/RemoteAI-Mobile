DEVSPACE_CONTINUITY_RISK: Approximately 1182342 DevSpace tool characters since the last acknowledged checkpoint. This is a secondary context-pressure signal, not an exact token-count or host context percentage, and not an automatic handoff trigger. Ordinary chat, other tools and host compaction are not measured. The host owns context management.
import XCTest
@testable import RemoteAIMobile

final class DeltaDisplaySnapshotTests: XCTestCase {
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

        let browserDown = WebAnomalyDisplayStatus.classify(
            surfaceState: "degraded", hasIssue: true, observedAt: recent, recoveredAt: nil,
            machineOnline: true, agentOnline: true, browserOnline: false, now: now)
        XCTAssertEqual(browserDown, .uncertain)
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
}
