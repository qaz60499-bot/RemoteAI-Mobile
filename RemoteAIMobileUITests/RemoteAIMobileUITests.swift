import XCTest

final class RemoteAIMobileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMachineRuntimeHierarchyOnIPhone() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My PC"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Web"].exists)
        XCTAssertTrue(app.staticTexts["Cloud Code"].exists)
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        // iPhone content must stay below system chrome; this catches accidental
        // ignoresSafeArea/negative-offset regressions on notched devices.
        XCTAssertGreaterThan(app.staticTexts["My PC"].frame.minY, 50)
    }

    func testOpenCachedWebConversation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()
        XCTAssertTrue(app.buttons["Attachments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop"].exists)
    }

    func testComposerFloatsAboveKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()

        let composer = app.textViews["MessageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("safe area test")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 2)
        XCTAssertTrue(app.buttons["Send"].isHittable)
    }

    func testPairingScreenHasManualAndQRPaths() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launch()
        app.buttons["Pair Device"].tap()
        XCTAssertTrue(app.staticTexts["Windows Relay"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Scan QR Code"].exists)
        XCTAssertTrue(app.buttons["Pair"].exists)
    }
}
