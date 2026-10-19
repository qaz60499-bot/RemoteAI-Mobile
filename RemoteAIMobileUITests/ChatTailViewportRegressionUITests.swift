import XCTest

final class ChatTailViewportRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTallTailViewportShowsLatestMessageOnOpenAndReturn() throws {
        let app = makeTallTailApp()
        openTallTailConversation(in: app)

        let latest = app.staticTexts["message-content-tall-tail-G-0"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        assertEventuallyHittable(latest, message: "The short G tail must be visible when the tall transcript opens")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))
        app.staticTexts["上传性能优化"].tap()

        let returnedLatest = app.staticTexts["message-content-tall-tail-G-0"]
        XCTAssertTrue(returnedLatest.waitForExistence(timeout: 5))
        assertEventuallyHittable(returnedLatest, message: "Returning to the tall transcript must position the viewport at G")
    }

    func testTallTailReturnControlReachesLatestAfterBrowsing() throws {
        let app = makeTallTailApp()
        openTallTailConversation(in: app)

        let latest = app.staticTexts["message-content-tall-tail-G-0"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        assertEventuallyHittable(latest, message: "The fixture must start at its visible tail")

        app.swipeDown()
        let older = app.staticTexts["message-content-tall-tail-F-0"]
        XCTAssertTrue(older.waitForExistence(timeout: 5))
        assertEventuallyHittable(older, message: "A downward swipe must expose the tall F row")
        let returnToLatest = app.buttons["回到最新消息"]
        XCTAssertTrue(returnToLatest.waitForExistence(timeout: 3))

        returnToLatest.tap()
        assertEventuallyHittable(latest, message: "The explicit return control must reach G after browsing the tall transcript")
    }

    private func makeTallTailApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launchEnvironment["REMOTEAI_UI_TEST_MOCK"] = "1"
        app.launchEnvironment["REMOTEAI_UI_TEST_SCENARIO"] = "tallTailViewport"
        return app
    }

    private func openTallTailConversation(in app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.staticTexts["Web"].waitForExistence(timeout: 5))
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 5))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))
        app.staticTexts["上传性能优化"].tap()
        XCTAssertTrue(app.buttons["Attachments"].waitForExistence(timeout: 5))
    }

    private func assertEventuallyHittable(_ element: XCUIElement, message: String) {
        let predicate = NSPredicate { _, _ in element.exists && element.isHittable }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, message)
    }
}
