import XCTest

final class RemoteAIMobileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func makeMockApp(scenario: String? = nil, loadRecentDelayMilliseconds: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockMode", "1"]
        app.launchEnvironment["REMOTEAI_UI_TEST_MOCK"] = "1"
        if let scenario {
            app.launchEnvironment["REMOTEAI_UI_TEST_SCENARIO"] = scenario
        }
        if let loadRecentDelayMilliseconds {
            app.launchEnvironment["REMOTEAI_UI_TEST_LOAD_DELAY_MS"] = String(loadRecentDelayMilliseconds)
        }
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

    func testDraftSurvivesLeavingAndReopeningConversation() throws {
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
        composer.typeText("navigation draft")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))
        app.staticTexts["上传性能优化"].tap()

        let reopenedComposer = app.textViews["MessageComposer"]
        XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedComposer.value as? String, "navigation draft")
    }

    func testFastBackDuringDraftLoadDoesNotOverwriteSavedDraft() throws {
        let app = makeMockApp(loadRecentDelayMilliseconds: 2_000)
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()

        let composer = app.textViews["MessageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("preserve during slow history load")
        XCTAssertEqual(composer.value as? String, "preserve during slow history load")
        Thread.sleep(forTimeInterval: 2.5) // Let autosave and the first delayed load finish before starting a fresh delayed re-entry.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))

        // The new ChatView has an empty local composer while its fresh history load is delayed.
        // Leaving now must not flush that empty value over the persisted draft.
        app.staticTexts["上传性能优化"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))

        app.staticTexts["上传性能优化"].tap()
        let restoredComposer = app.textViews["MessageComposer"]
        XCTAssertTrue(restoredComposer.waitForExistence(timeout: 5))
        let restoredDraft = NSPredicate(format: "value == %@", "preserve during slow history load")
        expectation(for: restoredDraft, evaluatedWith: restoredComposer)
        waitForExpectations(timeout: 8)
    }

    func testRejectedSendDraftSurvivesConversationReopen() throws {
        let app = makeMockApp(scenario: "webSendNotAccepted")
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()

        let composer = app.textViews["MessageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("restore after rejection")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["WEB_SEND_NOT_ACCEPTED: Mock page kept the original composer text"].waitForExistence(timeout: 5))
        let restoredText = NSPredicate(format: "value == %@", "restore after rejection")
        expectation(for: restoredText, evaluatedWith: composer)
        waitForExpectations(timeout: 5)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))
        app.staticTexts["上传性能优化"].tap()

        let reopenedComposer = app.textViews["MessageComposer"]
        XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedComposer.value as? String, "restore after rejection")
    }

    func testUnknownSendDraftIsNotFlushedEmptyWhenConversationReopens() throws {
        let app = makeMockApp(scenario: "webSendDeliveryUnknown")
        let unknownDeliveryMessage = "Delivery is unknown after the ChatGPT page changed. Retry replays the exact same command ID; RemoteAI will reconcile before any duplicate is allowed."
        let unknownDeliveryBanner = app.staticTexts.matching(NSPredicate(format: "label == %@", unknownDeliveryMessage)).firstMatch
        app.launch()
        app.staticTexts["Web"].tap()
        XCTAssertTrue(app.staticTexts["Photo SaaS"].waitForExistence(timeout: 3))
        app.staticTexts["Photo SaaS"].tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 3))
        app.staticTexts["上传性能优化"].tap()

        let composer = app.textViews["MessageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("retain pending delivery draft")
        app.buttons["Send"].tap()
        XCTAssertTrue(unknownDeliveryBanner.waitForExistence(timeout: 8))
        let composerCleared = NSPredicate(format: "value == %@", "")
        expectation(for: composerCleared, evaluatedWith: composer)
        waitForExpectations(timeout: 5)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["上传性能优化"].waitForExistence(timeout: 5))
        app.staticTexts["上传性能优化"].tap()

        let reopenedComposer = app.textViews["MessageComposer"]
        XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 5))
        XCTAssertTrue(unknownDeliveryBanner.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedComposer.value as? String, "")
        XCTAssertFalse(app.buttons["Send"].isEnabled)
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

    private func readingPosition(_ element: XCUIElement) throws -> [String: String] {
        let raw = try XCTUnwrap(element.value as? String, "Native reading-position observation must be present")
        let fields = Dictionary(uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
        let row = try XCTUnwrap(fields["readingRow"])
        XCTAssertFalse(["none", "unattached"].contains(row), "Must observe an actual rendered row: " + raw)
        return fields
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
        let transcript = app.scrollViews["ChatTranscript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        // The native trace in 40202895055 proves that closing the keyboard can
        // expand the viewport more than this swipe moves it. Test the two user
        // actions separately, keeping the actual off-tail requirement strict.
        let dismissKeyboard = app.buttons["DismissComposerKeyboard"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3))
        dismissKeyboard.tap()
        let nativePosition = app.otherElements["TranscriptNativeReadingPosition"]
        XCTAssertTrue(nativePosition.waitForExistence(timeout: 3))
        let settledTail = NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
                && (transcript.value as? String)?.contains("followTail=true;atBottom=true") == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settledTail, object: nil)], timeout: 10), .completed,
                       "History browsing must start with a closed keyboard and a confirmed visible tail")
        let tailPosition = try readingPosition(nativePosition)
        XCTAssertEqual(tailPosition["readingTailVisible"], "true", "The actual native bottom marker must be visible after closing the keyboard")
        print("READING_UI keyboardClosed=" + String(describing: tailPosition))
        XCTAssertEqual(composer.value as? String, "still responsive", "Closing the keyboard must preserve the unsent draft")
        // Target the transcript and record its follow state to distinguish an
        // ignored gesture from an automatic return to the tail during streaming.
        print("TRANSCRIPT_UI before=\(transcript.value ?? "nil")")
        let readingBefore = try readingPosition(nativePosition)
        print("READING_UI before=" + String(describing: readingBefore))
        transcript.swipeDown()
        let historyState = transcript.value as? String
        print("TRANSCRIPT_UI after=\(historyState ?? "nil")")
        // Use the first confirmed history state; another swipe can return to the tail while streaming.
        XCTAssertTrue(historyState?.contains("followTail=false;atBottom=false") == true,
                      "A single transcript swipe must move away from the live tail")
        let latest = app.buttons["回到最新消息"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        // CI 40198580210 visibly browsed history and then jumped back to the
        // streaming tail without a new scroll request. A single immediate sample
        // can miss that delayed jump. Observe a fixed history interval before the
        // explicit return; do not retry the swipe or wait for a failed check to pass.
        let readingBaseline = try readingPosition(nativePosition)
        let baselineBytes = try XCTUnwrap(Int(readingBaseline["readingStreamBytes"] ?? ""))
        let baselineRow = try XCTUnwrap(readingBaseline["readingRow"])
        let preview = app.buttons["assistant-stream-current-copy"]
        let baselineFingerprint = baselineRow == "stream-photo-upload" ? try XCTUnwrap(preview.value as? String) : nil
        let baselineIntra = try XCTUnwrap(Double(readingBaseline["readingIntra"] ?? ""))
        let baselineUptime = try XCTUnwrap(Double(readingBaseline["readingUptime"] ?? ""))
        XCTAssertEqual(readingBaseline["readingDragging"], "false")
        XCTAssertEqual(readingBaseline["readingDecelerating"], "false", "Sample after the single swipe settles")
        print("READING_UI baseline=" + String(describing: readingBaseline))
        var lastReadingUptime = baselineUptime
        var lastReceivedBytes = baselineBytes
        for sample in 1...3 {
            Thread.sleep(forTimeInterval: 1)
            let heldHistoryState = transcript.value as? String
            print("TRANSCRIPT_UI historySample=\(sample) state=\(heldHistoryState ?? "nil")")
            XCTAssertTrue(heldHistoryState?.contains("followTail=false;atBottom=false") == true,
                          "Streaming must preserve the user's history position: \(heldHistoryState ?? "nil")")
            let reading = try readingPosition(nativePosition)
            print("READING_UI held=" + String(describing: reading))
            XCTAssertEqual(reading["readingRow"], baselineRow, "Streaming must preserve the actual visible row")
            let intra = try XCTUnwrap(Double(reading["readingIntra"] ?? ""))
            XCTAssertEqual(intra, baselineIntra, accuracy: 24, "Streaming must preserve the position inside a long row")
            lastReadingUptime = try XCTUnwrap(Double(reading["readingUptime"] ?? ""))
            lastReceivedBytes = try XCTUnwrap(Int(reading["readingStreamBytes"] ?? ""))
            if let baselineFingerprint { XCTAssertEqual(preview.value as? String, baselineFingerprint, "The rendered preview text must stay fixed while browsing") }
            XCTAssertTrue(latest.exists && latest.isHittable,
                          "Return to latest must stay available while browsing history")
        }
        XCTAssertGreaterThan(lastReceivedBytes, baselineBytes, "The stream must continue receiving while history is held")
        XCTAssertGreaterThanOrEqual(lastReadingUptime - baselineUptime, 3, "History location must remain stable for at least three native seconds")
        let beforePaging = try readingPosition(nativePosition)
        let rowsBeforePaging = try XCTUnwrap(Int(beforePaging["readingLoadedRows"] ?? ""))
        let pagingAnchor = try XCTUnwrap(beforePaging["readingRow"])
        // The direct stress fixture starts with only the bounded streaming row.
        // Reach its actual measured boundary, load an older page, then browse it.
        transcript.swipeDown()
        let pageLoaded = NSPredicate { _, _ in
            guard let value = nativePosition.value as? String else { return false }
            let fields = Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                return pair.count == 2 ? (pair[0], pair[1]) : nil
            })
            return (Int(fields["readingLoadedRows"] ?? "") ?? 0) > rowsBeforePaging
                && fields["readingRow"] == pagingAnchor
                && abs(Double(fields["readingIntra"] ?? "") ?? .infinity) <= 64
                && fields["readingDragging"] == "false"
                && fields["readingDecelerating"] == "false"
        }
        let pageRestoreResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pageLoaded, object: nil)], timeout: 8)
        print("READING_UI afterPaging=" + String(describing: nativePosition.value))
        XCTAssertEqual(pageRestoreResult, .completed, "Paging must restore the original row near its top after loading older history")
        transcript.swipeDown()
        let olderBaseline = try readingPosition(nativePosition)
        let olderRow = try XCTUnwrap(olderBaseline["readingRow"])
        XCTAssertTrue(olderRow.hasPrefix("mock-"), "An actual older message must be visible after paging")
        let olderIntra = try XCTUnwrap(Double(olderBaseline["readingIntra"] ?? ""))
        let olderBytes = try XCTUnwrap(Int(olderBaseline["readingStreamBytes"] ?? ""))
        let olderUptime = try XCTUnwrap(Double(olderBaseline["readingUptime"] ?? ""))
        var olderLast = olderBaseline
        for _ in 1...3 {
            Thread.sleep(forTimeInterval: 1)
            olderLast = try readingPosition(nativePosition)
            print("READING_UI olderHeld=" + String(describing: olderLast))
            XCTAssertEqual(olderLast["readingRow"], olderRow)
            XCTAssertEqual(try XCTUnwrap(Double(olderLast["readingIntra"] ?? "")), olderIntra, accuracy: 24)
        }
        XCTAssertGreaterThan(try XCTUnwrap(Int(olderLast["readingStreamBytes"] ?? "")), olderBytes)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Double(olderLast["readingUptime"] ?? "")) - olderUptime, 3)
        latest.tap()
        print("STREAM_UI chars=\(chars) historyAndReturnInteractionMs=\((ProcessInfo.processInfo.systemUptime - scrollingBegan) * 1000)")
        let marker = "STRESS_BEGIN_\(chars)"
        // The final message has a unique, stable text identifier. A global
        // staticTexts.containing(label CONTAINS ...) scan can stall XCTest's
        // accessibility snapshot for 30 seconds under a long transcript.
        // The final is emitted only after every delta is appended by MockTransport.
        let final = app.staticTexts["message-content-stress-final-\(chars)-0"]
        // The UI-only fixture emits 100 characters at the configured chunk interval.
        // Budget its complete duration plus runner/accessibility slack instead of retaining the
        // old 40-second timeout that predates the deterministic slow fixture.
        let expectedFixtureSeconds = (Double(chars) / 100.0) * (Double(fixtureChunkMilliseconds) / 1000.0)
        XCTAssertTrue(final.waitForExistence(timeout: max(180, expectedFixtureSeconds + 90)),
                      "The actual final message must replace the streaming row")
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
