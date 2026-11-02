import XCTest
@testable import RemoteAIMobile

final class WebErrorExplanationTests: XCTestCase {
    @MainActor
    func testRepeatedProviderIssueKeepsOneVisibleIssueAndFreshRecoveryWins() async throws {
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        let at = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        for index in 0..<12 {
            let observed = at.addingTimeInterval(Double(index))
            await mock.injectEvent(RemoteEvent(
                protocolVersion: 1, eventId: UUID(), sequence: Int64(1501 + index),
                machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo",
                sessionId: "photo-upload", type: "SESSION_STATUS",
                payload: ["providerSurface": .bool(true), "state": .string("degraded"),
                          "providerState": .string("connection-lost"),
                          "code": .string(index == 11 ? "PROVIDER_RATE_LIMITED" : "PROVIDER_UNAVAILABLE"),
                          "message": .string("网页请求暂时异常"), "originalMessage": .string("Failed to fetch"),
                          "retryable": .bool(true), "at": .string(RemoteAIDate.string(observed)),
                          "statusObservedAt": .string(RemoteAIDate.string(observed))],
                createdAt: observed), deliverLive: true)
        }
        for _ in 0..<100 where store.webProviderIssuesBySession["photo-upload"]?.code != "PROVIDER_RATE_LIMITED" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.webProviderIssuesBySession.count, 1)
        XCTAssertEqual(store.webProviderIssuesBySession["photo-upload"]?.code, "PROVIDER_RATE_LIMITED")
        XCTAssertEqual(store.webProviderSurfaceObservedAtBySession["photo-upload"], at.addingTimeInterval(11))

        let recovered = at.addingTimeInterval(20)
        await mock.injectEvent(RemoteEvent(
            protocolVersion: 1, eventId: UUID(), sequence: 1513,
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo",
            sessionId: "photo-upload", type: "SESSION_STATUS",
            payload: ["providerSurface": .bool(true), "state": .string("online"),
                      "providerState": .string("online"), "recovered": .bool(true),
                      "at": .string(RemoteAIDate.string(recovered)),
                      "statusObservedAt": .string(RemoteAIDate.string(recovered))],
            createdAt: recovered), deliverLive: true)
        for _ in 0..<100 where store.webProviderIssuesBySession["photo-upload"] != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.webProviderIssuesBySession["photo-upload"])
        XCTAssertNil(store.errors["photo-upload"])
        XCTAssertEqual(store.webProviderRecoveryObservedAtBySession["photo-upload"], recovered)
        await store.suspend()
    }

    func testRequestedErrorDictionaryPreservesDeliveryDistinction() {
        let cases: [(String, String, String, Bool)] = [
            ("PROVIDER_UNAVAILABLE", "response-unavailable", "This response couldn't load", false),
            ("PROVIDER_UNAVAILABLE", "response-network-error", "Network error", false),
            ("PROVIDER_UNAVAILABLE", "connection-lost", "Failed to fetch", false),
            ("PROVIDER_UNAVAILABLE", "", "Message delivery timed out", true),
            ("PROVIDER_UNAVAILABLE", "response-incomplete", "Connection interrupted", false),
            ("PROVIDER_RATE_LIMITED", "rate-limited", "", false),
            ("WEB_SEND_DELIVERY_UNKNOWN", "", "", true),
            ("PAGE_TRANSLATION_ACTIVE", "", "", false),
            ("SESSION_UNAVAILABLE", "", "", false),
            ("CONVERSATION_IDENTITY_UNVERIFIED", "", "", false),
            ("BROWSER_BINDING_MISSING", "", "", false)
        ]
        for (code, state, original, unknown) in cases {
            let result = WebErrorExplanation.resolve(code: code, state: state, original: original)
            XCTAssertFalse(result.summary.isEmpty, code)
            XCTAssertFalse(result.impact.isEmpty, code)
            XCTAssertFalse(result.safeAction.isEmpty, code)
            XCTAssertEqual(result.deliveryUnknown, unknown, code)
        }
    }

    func testUnknownCodeDoesNotInventConfirmedDeliveryOrTranslateMessageBody() {
        let result = WebErrorExplanation.resolve(code: "FUTURE_PROVIDER_CODE", original: "unrecognized text")
        XCTAssertFalse(result.deliveryUnknown)
        XCTAssertTrue(result.summary.contains("异常"))
        XCTAssertFalse(result.summary.contains("unrecognized"))
        XCTAssertFalse(result.impact.contains("已送达"))
    }

    func testIssueRetainsRawErrorAndTimestampWithoutMutatingProviderEvidence() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let issue = RemoteProviderSurfaceIssue(code: "PROVIDER_UNAVAILABLE", state: "response-incomplete", message: "Connection interrupted", retryable: true, at: at, originalMessage: "Connection interrupted. Waiting for the complete answer")
        XCTAssertTrue(issue.explanation.summary.contains("尚未完成"))
        XCTAssertEqual(issue.at, at)
        XCTAssertEqual(issue.originalMessage, "Connection interrupted. Waiting for the complete answer")
        XCTAssertEqual(issue.message, "Connection interrupted")
    }

    func testUnknownDeliveryIsVisibleAsUncertainWithoutSuggestingNewSend() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let issue = RemoteProviderSurfaceIssue(code: "WEB_SEND_DELIVERY_UNKNOWN", state: "delivery-unknown", message: "Message delivery timed out", retryable: false, at: at, originalMessage: "Message delivery timed out")
        let summaries = RuntimeIssueSummary.build(RuntimeIssueSnapshot(providerIssues: ["web-chat": issue], providerStates: ["web-chat": "degraded"]))
        let summary = summaries.first { $0.id == "provider-issue.web-chat" }
        XCTAssertEqual(summary?.level, .uncertain)
        XCTAssertTrue(summary?.detail.contains("WEB_SEND_DELIVERY_UNKNOWN") == true)
        XCTAssertTrue(summary?.detail.contains("Message delivery timed out") == true)
        XCTAssertTrue(summary?.suggestion.contains("不会自动创建新命令重发") == true)
        XCTAssertEqual(summary?.observedAt, at)
    }

    func testTransportDescriptionsExplainChineseAndRetainMachineCode() {
        for code in ["SESSION_UNAVAILABLE", "CONVERSATION_IDENTITY_UNVERIFIED", "BROWSER_BINDING_MISSING", "PROVIDER_RATE_LIMITED", "PROVIDER_UNAVAILABLE", "WEB_SEND_DELIVERY_UNKNOWN", "PAGE_TRANSLATION_ACTIVE"] {
            let description = TransportError.remote(code, "Failed to fetch").localizedDescription
            XCTAssertTrue(description.contains(code))
            XCTAssertTrue(description.contains("。"))
        }
        XCTAssertTrue(TransportError.offline.localizedDescription.contains("offline"))
        XCTAssertTrue(TransportError.timeout.localizedDescription.contains("是否送达"))
        XCTAssertEqual(ConnectionDiagnosticPhase.windowsOffline.rawValue, "windowsOffline")
        XCTAssertEqual(ConnectionDiagnosticPhase.windowsOffline.chineseDisplayName, "Windows Agent 已离线")
    }
}
