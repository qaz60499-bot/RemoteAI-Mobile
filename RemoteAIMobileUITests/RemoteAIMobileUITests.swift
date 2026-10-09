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
        XCTAssertFalse(app.buttons["Stop"].exists, "A completed cached conversation must not show Stop")
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
        XCTAssertFalse(latest.isHittable, "A deliberate swipe must actually expose older history, not only toggle the button")
        app.swipeUp()
        XCTAssertTrue(returnToLatest.exists, "A subsequent vertical swipe must not resume automatic bottom-follow")
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

    func testTappingTranscriptDismissesKeyboardWithoutDiscardingDraft() throws {
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
        composer.typeText("unsent keyboard draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let transcript = app.staticTexts["Mock assistant response 1200. This verifies long-history pagination without rendering everything at once."]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.tap()
        let dismissed = NSPredicate(format: "exists == false")
        expectation(for: dismissed, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(composer.value as? String, "unsent keyboard draft")
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
        // Hosted-runner accessibility setup can consume tens of seconds before the
        // composer interaction starts. The shorter 30k fixture can otherwise reach
        // terminal before XCUI samples a second progress label on slow runners.
        // Keep every assertion; lengthen only this deterministic test-only stream.
        let fixtureChunkMilliseconds = chars <= 30_000 ? 250 : 150
        app.launchEnvironment["REMOTEAI_UI_STRESS_CHUNK_MS"] = String(fixtureChunkMilliseconds)
        app.launch()
        let progress = app.staticTexts["assistant-stream-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let initial = progress.label
        let changed = NSPredicate { _, _ in progress.exists && progress.label != initial }
        expectation(for: changed, evaluatedWith: nil)
        // XCUI accessibility reads on hosted runners can each take several seconds.
        // Give the progress label enough time to be sampled at least twice while
        // the UI-only stream remains active for the interaction checks below.
        waitForExpectations(timeout: 25)
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
        // The UI-only fixture emits 100 characters at the configured chunk interval.
        // Budget its complete duration plus runner/accessibility slack instead of retaining the
        // old 40-second timeout that predates the deterministic slow fixture.
        let expectedFixtureSeconds = (Double(chars) / 100.0) * (Double(fixtureChunkMilliseconds) / 1000.0)
        waitForExpectations(timeout: max(180, expectedFixtureSeconds + 90))
        XCTAssertTrue(final.exists)
    }
}
