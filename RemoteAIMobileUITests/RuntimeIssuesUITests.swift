import XCTest

final class RuntimeIssuesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRuntimeIssuesSummaryEntryOpensAndOffersManualRefresh() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launchEnvironment["REMOTEAI_UI_TEST_MOCK"] = "1"
        app.launch()

        let summaryLink = app.descendants(matching: .any).matching(identifier: "runtimeIssuesLink").firstMatch
        XCTAssertTrue(summaryLink.waitForExistence(timeout: 10))
        summaryLink.tap()

        XCTAssertTrue(app.navigationBars["运行异常"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "runtimeIssueSummaryEmpty").firstMatch.exists)
        let refresh = app.buttons["refreshRuntimeInstances"]
        XCTAssertTrue(refresh.exists)
        refresh.tap()
        XCTAssertTrue(app.navigationBars["运行异常"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "runtime-issues-summary"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
