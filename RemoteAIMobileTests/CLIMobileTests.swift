import XCTest
@testable import RemoteAIMobile

final class CLIMobileTests: XCTestCase {
    func testClaudeRuntimeAndDistinctStates() throws {
        XCTAssertEqual(RuntimeKind(rawValue: "CloudCode")?.displayName, "Claude Code")
        XCTAssertEqual(CLIStateLabel.text("running"), "执行中")
        XCTAssertEqual(CLIStateLabel.text("waiting_approval"), "等待审批")
        XCTAssertEqual(CLIStateLabel.text("rate_limited"), "请求限流")
        XCTAssertEqual(CLIStateLabel.text(nil), "状态未知")
    }

    func testCLIProtocolKeepsStrictActionsAndExistingWeb() throws {
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("respondApproval"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("configureSession"))
        XCTAssertTrue(ProtocolSecurity.commandActions.contains("registerCurrentPage"))
        XCTAssertTrue(ProtocolSecurity.eventTypes.contains("CLI_STATUS"))
        XCTAssertFalse(ProtocolSecurity.commandActions.contains("killProcess"))
    }

    func testUpstreamUsesHostAndWindowsCredentialAvailability() throws {
        let data = Data(#"{"id":"configured","label":"Windows","host":"provider.example","models":["configured-model"],"defaultModel":"configured-model","credentialAvailable":true,"health":"unknown"}"#.utf8)
        let upstream = try JSONDecoder().decode(CLIUpstream.self, from: data)
        XCTAssertEqual(upstream.host, "provider.example")
        XCTAssertTrue(upstream.credentialAvailable)
        XCTAssertEqual(upstream.models, ["configured-model"])
    }
}
