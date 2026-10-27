import XCTest
@testable import RemoteAIMobile

final class RuntimeIssueSummaryTests: XCTestCase {
    private func summarize(
        paired: Bool = true,
        machine: MachineConnectionState = .online,
        phase: ConnectionDiagnosticPhase = .online,
        transient: Bool = false,
        browser: Bool? = true,
        relay: Bool? = true,
        agent: Bool? = true,
        errors: [String: String] = [:],
        sessions: [SessionDescriptor] = [],
        commands: [UUID: CommandState] = [:]
    ) -> [RuntimeIssue] {
        RuntimeIssueSummary.build(
            paired: paired, machineState: machine, connectionPhase: phase,
            transientPresentation: transient, browserConnected: browser,
            relayConnected: relay, agentConnected: agent, errors: errors,
            runtimes: [
                RuntimeDescriptor(id: "runtime.codex", machineId: "pc", kind: .codex, name: "Codex"),
                RuntimeDescriptor(id: "runtime.antigravity", machineId: "pc", kind: .antigravity, name: "Antigravity")
            ],
            instances: [
                InstanceDescriptor(id: "codex.desktop", runtimeId: "runtime.codex", name: "Codex", subtitle: nil),
                InstanceDescriptor(id: "antigravity.desktop", runtimeId: "runtime.antigravity", name: "Antigravity", subtitle: nil)
            ],
            sessions: sessions, commands: commands
        )
    }

    func testNoPairingOrVerifiedHealthyCacheDoesNotManufactureAnIncident() {
        XCTAssertTrue(summarize(paired: false, machine: .offline).isEmpty)
        XCTAssertTrue(summarize().isEmpty)
        XCTAssertTrue(summarize(phase: .reconnecting, transient: true).isEmpty,
                      "Foreground grace must not raise a false failure")
        XCTAssertTrue(summarize(machine: .offline, phase: .timedOut, transient: true).isEmpty,
                      "An offline sample inside foreground grace is not a new incident")
        let reconnect = summarize(machine: .connecting, phase: .windowsReconnecting)
        XCTAssertEqual(reconnect.first?.level, .uncertain)
        XCTAssertTrue(reconnect.first?.title.contains("Windows Agent") == true)
    }

    func testBridgeAndRelayFaultsAreVisibleWithoutChangingCommandDelivery() {
        let issues = summarize(phase: .online, browser: false, relay: false)
        XCTAssertEqual(Set(issues.map(\.id)), Set(["bridge", "relay"]))
        XCTAssertTrue(issues.allSatisfy { $0.level == .failure })
        XCTAssertTrue(issues.allSatisfy { $0.suggestion.contains("不要") || $0.suggestion.contains("检查") })
        let refresh = summarize(errors: ["runtime.runtime.codex": "Probe unavailable"])
        XCTAssertEqual(refresh.first?.id, "runtime.runtime.codex")
        XCTAssertEqual(refresh.first?.level, .uncertain)
    }

    func testUnknownCommandAndSessionAreUncertainNotFailedOrAutoRetried() {
        let command = UUID()
        let item = SessionDescriptor(
            id: "conversation-1", instanceId: "antigravity.desktop", title: "Unknown delivery",
            state: .unknown, updatedAt: Date()
        )
        let issues = summarize(sessions: [item], commands: [command: .unknown])
        XCTAssertEqual(Set(issues.map(\.id)), Set(["session.conversation-1", "commands.unknown"]))
        XCTAssertTrue(issues.allSatisfy { $0.level == .uncertain })
        XCTAssertTrue(issues.allSatisfy { $0.suggestion.contains("不要重复发送") || $0.suggestion.contains("不要点击 Retry") })
        let failed = summarize(commands: [command: .failed])
        XCTAssertEqual(failed.first?.id, "commands.failed")
        XCTAssertEqual(failed.first?.level, .failure)
        XCTAssertTrue(issues.last?.detail.contains("停止") == true,
                      "Unknown command outcomes include Stop and must not claim a failed message")
    }

    func testSessionErrorsRemainScopedAndCappedForLargeCachedCatalog() {
        let rows: [SessionDescriptor] = (0..<30).map { index in
            SessionDescriptor(id: "s-\(index)", instanceId: "codex.desktop",
                              title: "Test \(index)", state: .error,
                              updatedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let issues = summarize(sessions: rows)
        XCTAssertEqual(issues.count, 5)
        XCTAssertEqual(issues.first?.id, "session.s-29")
        XCTAssertTrue(issues.allSatisfy { $0.title.contains("Codex") })
        XCTAssertTrue(issues.allSatisfy { $0.detail.contains("历史状态") && $0.detail.contains("会话记录时间") })
    }

    func testFailedAntigravitySidebarTaskIsVisibleEvenWhenConversationIsIdle() {
        var idle = SessionDescriptor(id: "ag-idle", instanceId: "antigravity.desktop",
                                     title: "Main conversation", state: .idle, updatedAt: Date())
        idle.backgroundTaskStatus = BackgroundTaskStatusSnapshot(
            state: .available, observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tasks: [BackgroundTaskDescriptor(id: "side-1", title: "Research step",
                                             status: .failed, progress: nil)]
        )
        let issues = summarize(sessions: [idle])
        XCTAssertEqual(issues.map(\.id), ["task.ag-idle.side-1"])
        XCTAssertEqual(issues.first?.level, .failure)
        XCTAssertTrue(issues.first?.suggestion.contains("不要直接重发") == true)
    }

    func testOfflineStaleBrowserSnapshotDoesNotClaimLiveWebFailure() {
        let issues = summarize(machine: .offline, phase: .windowsOffline,
                               browser: false, relay: false, agent: false)
        XCTAssertEqual(issues.map(\.id), ["connection"],
                       "Past browser/relay samples must not masquerade as new faults while offline")
    }
}
