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
        // Shared macOS runner snapshots may outlive XCTest's default 120s per-case budget.
        // The 30k/50k stress cases still assert live progress, typing, scrolling and final.
        executionTimeAllowance = 240
        let app = makeMockApp()
        app.launchEnvironment["REMOTEAI_UI_STRESS_CHARS"] = String(chars)
        app.launchEnvironment["REMOTEAI_UI_STRESS_DIRECT"] = "1"
        // Hosted-runner accessibility setup can consume tens of seconds before the
        // composer interaction starts. The shorter 30k fixture can otherwise reach
        // terminal before XCUI samples a second progress label on slow runners.
        // Keep every assertion; lengthen only this deterministic test-only stream.
        let fixtureChunkMilliseconds = chars <= 30_000 ? 250 : 150
        app.launchEnvironment["REMOTEAI_UI_STRESS_CHUNK_MS"] = String(fixtureChunkMilliseconds)
        let fixtureStartedAt = ProcessInfo.processInfo.systemUptime
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
        // The final message has a unique, stable text identifier. A global
        // staticTexts.containing(label CONTAINS ...) scan can stall XCTest's
        // accessibility snapshot for 30 seconds under a long transcript.
        // The final is emitted only after every delta is appended by MockTransport.
        let final = app.staticTexts["message-content-stress-final-\(chars)-0"]
        // A query for a final-only accessibility element while SwiftUI is actively
        // replacing a 30k/50k streaming row can stall XCTest's *entire* AX snapshot,
        // not merely report that the final is absent. Earlier CI reached all live
        // interaction assertions, then xcodebuild timed out inside this premature
        // query. Keep the live progress/typing/scroll assertions above, but only
        // inspect the terminal accessibility tree after this deterministic fixture
        // has finished sending its 100-character chunks. No app code is changed and
        // the actual final, idle Send button and retained draft remain mandatory.
        let expectedFixtureSeconds = (Double(chars) / 100.0) * (Double(fixtureChunkMilliseconds) / 1000.0)
        // The slower 30k fixture needs terminal event/render drain time before an AX query.
        // The 50k fixture already passed with the existing 12-second buffer.
        let terminalDrainSeconds = chars <= 30_000 ? 30.0 : 12.0
        let quietUntil = fixtureStartedAt + expectedFixtureSeconds + terminalDrainSeconds
        let remaining = max(0, quietUntil - ProcessInfo.processInfo.systemUptime)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        print("STREAM_UI chars=\(chars) terminalQueryQuietWaitSeconds=\(remaining)")
        // The fixture has already ended and drained above. A terminal message
        // still offscreen after 30 seconds is a tail-follow UX regression, not
        // a legitimate slow stream. Keep this failure explicit and bounded.
        XCTAssertTrue(final.waitForExistence(timeout: 30),
                      "The canonical final message must be visible after Return to Latest")
        XCTAssertTrue(final.label.contains(marker), "The rendered final message must have the expected contents")
        // The draft remains populated: "Send correction" changes to "Send"
        // only once the chat's authoritative generation state becomes idle.
        // Check a positive, exact accessibility target rather than repeatedly
        // searching for a vanished progress label across a huge XCUI tree.
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 15),
                      "Final delivery must clear active generation and restore normal sending")
        XCTAssertEqual(composer.value as? String, "still responsive", "Final must preserve the unsent draft")
    }
}
