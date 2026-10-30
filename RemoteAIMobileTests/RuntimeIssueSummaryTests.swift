import XCTest
@testable import RemoteAIMobile

final class RuntimeIssueSummaryTests: XCTestCase {
    func testSummaryRetainsOriginalErrorSourceAndKnownObservationTime() {
        let observedAt = Date(timeIntervalSince1970: 1_761_800_000)
        let issue = RemoteProviderSurfaceIssue(
            code: "RETRY_VISIBLE",
            state: "retry-visible",
            message: "网页显示 Try Again",
            retryable: true,
            at: observedAt,
            originalMessage: "Failed to fetch: network connection was lost"
        )
        let webRuntime = RuntimeDescriptor(id: "runtime.web", machineId: "pc", kind: .web, name: "Web")
        let webInstance = InstanceDescriptor(id: "web.chatgpt", runtimeId: "runtime.web", name: "ChatGPT", subtitle: "Web")
        let session = SessionDescriptor(
            id: "chat-123",
            instanceId: "web.chatgpt",
            title: "测试对话",
            state: .error,
            updatedAt: observedAt
        )
        let snapshot = RuntimeIssueSnapshot(
            machineState: .online,
            connectionPhase: .online,
            browserConnected: false,
            relayConnected: true,
            agentConnected: true,
            statusUpdatedAt: observedAt,
            errors: ["web.tabs": "Failed to fetch 原文"],
            runtimes: [webRuntime],
            instances: [webInstance],
            sessions: [session],
            commands: [UUID(): .unknown],
            providerIssues: [session.id: issue],
            providerStates: [session.id: "degraded"],
            providerObservedAt: [session.id: observedAt]
        )

        let summaries = RuntimeIssueSummary.build(snapshot)
        let browserError = summaries.first(where: { $0.id == "error.web.tabs" })
        let providerError = summaries.first(where: { $0.id == "provider-issue.\(session.id)" })

        XCTAssertEqual(browserError?.source, "Web · Chrome 标签")
        XCTAssertEqual(browserError?.detail, "Failed to fetch 原文")
        XCTAssertNil(browserError?.observedAt, "The store does not timestamp each arbitrary error entry")
        XCTAssertEqual(providerError?.source, "ChatGPT")
        XCTAssertTrue(providerError?.detail.contains("Failed to fetch: network connection was lost") == true)
        XCTAssertEqual(providerError?.observedAt, observedAt)
        XCTAssertTrue(summaries.contains(where: { $0.id == "bridge" }))
        XCTAssertTrue(summaries.contains(where: { $0.id == "commands.unknown" }))
        XCTAssertTrue(summaries.contains(where: { $0.id == "session.chat-123" }))
    }

    func testRefreshSnapshotDoesNotInventAnObservationTimestamp() {
        let summaries = RuntimeIssueSummary.build(RuntimeIssueSnapshot(errors: ["sync": "No connection"]))
        let sync = summaries.first(where: { $0.id == "error.sync" })

        XCTAssertEqual(sync?.source, "数据同步")
        XCTAssertEqual(sync?.detail, "No connection")
        XCTAssertNil(sync?.observedAt)
    }
}
