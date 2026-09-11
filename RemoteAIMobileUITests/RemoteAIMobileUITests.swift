import XCTest

final class RemoteAIMobileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func makeMockApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launchEnvironment["REMOTEAI_UI_TEST_MOCK"] = "1"
        return app
    }

    func testMachineRuntimeHierarchyOnIPhone() throws {
        let app = makeMockApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["My PC"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Web"].exists)
        XCTAssertFalse(app.staticTexts["Cloud Code"].exists)
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        // iPhone content must stay below system chrome; this catches accidental
        // ignoresSafeArea/negative-offset regressions on notched devices.
        XCTAssertGreaterThan(app.staticTexts["My PC"].frame.minY, 50)
    }

    func testOpenCachedWebConversation() throws {
        let app = makeMockApp()
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()
        XCTAssertTrue(app.buttons["Attachments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop"].exists)
    }

    func testConversationOpensAtLatestAndOffersReturnToBottomAfterBrowsingHistory() throws {
        let app = makeMockApp()
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()

        let latest = app.staticTexts["Mock assistant response 1200. This verifies long-history pagination without rendering everything at once."]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "Opening a conversation should land on the latest message")
        XCTAssertTrue(latest.isHittable)

        app.swipeDown()
        app.swipeDown()
        let returnToLatest = app.buttons["回到最新消息"]
        XCTAssertTrue(returnToLatest.waitForExistence(timeout: 3), "Browsing older messages should expose a compact return-to-latest control")
        returnToLatest.tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertTrue(latest.isHittable)
    }

    func testComposerFloatsAboveKeyboard() throws {
        let app = makeMockApp()
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
        let app = makeMockApp()
        app.launch()
        app.buttons["Pair Device"].tap()
        XCTAssertTrue(app.navigationBars["Pair Device"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.textFields.count, 3)
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pair"].exists)
    }

    func testLongStreamingTailStaysLiveWhileComposerAndHistoryRemainUsable() throws {
        try verifyStreamingInteraction(chars: 30_000)
    }

    func testLongStreaming50kTailStaysLiveWhileComposerAndHistoryRemainUsable() throws {
        try verifyStreamingInteraction(chars: 50_000)
    }

    private func verifyStreamingInteraction(chars: Int) throws {
        let app = makeMockApp()
        app.launchEnvironment["REMOTEAI_UI_STRESS_CHARS"] = String(chars)
        app.launchEnvironment["REMOTEAI_UI_STRESS_DIRECT"] = "1"
        app.launch()
        let progress = app.staticTexts["assistant-stream-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let initial = progress.label
        let changed = NSPredicate { _, _ in progress.exists && progress.label != initial }
        expectation(for: changed, evaluatedWith: nil)
        waitForExpectations(timeout: 4)
        let composer = app.textViews["MessageComposer"]
        let typingBegan = ProcessInfo.processInfo.systemUptime
        composer.tap()
        composer.typeText("still responsive")
        XCTAssertEqual(composer.value as? String, "still responsive")
        XCTAssertTrue(progress.exists, "Typing must finish while the stream is still live")
        print("STREAM_UI chars=\(chars) composerInteractionMs=\((ProcessInfo.processInfo.systemUptime - typingBegan) * 1000)")
        let scrollingBegan = ProcessInfo.processInfo.systemUptime
        app.swipeDown()
        app.swipeDown()
        let latest = app.buttons["回到最新消息"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        latest.tap()
        print("STREAM_UI chars=\(chars) historyAndReturnInteractionMs=\((ProcessInfo.processInfo.systemUptime - scrollingBegan) * 1000)")
        let marker = "STRESS_BEGIN_\(chars)"
        let final = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        let finished = NSPredicate { _, _ in !progress.exists && final.exists }
        expectation(for: finished, evaluatedWith: nil)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(final.exists)
    }
}
