import XCTest
@testable import RemoteAIMobile

@MainActor
final class StopLifecycleDiagnosticsTests: XCTestCase {
    private let sessionId = "web-stop-identity-fixture"
    private let canonicalURL = "https://chatgpt.com/g/g-p-remoteai/c/mock-1"

    func testStaleStopRefreshesIdentityAndRequiresAnotherExplicitTap() async throws {
        let (store, mock) = try await preparedWebChat()
        await mock.setOpenWebTabInspectionOverrides(tabId: 12, fields: inspection(
            diagnosisState: "generating",
            generating: true,
            expectedKey: "observer:1",
            observedKey: "observer:1",
            currentKey: "observer:1",
            identityState: "matched"
        ))
        await mock.enqueueStopReceipt([
            "stopped": .bool(false),
            "settled": .bool(true),
            "staleGeneration": .bool(true),
            "confirmedIdle": .bool(false),
            "stopIdentity": stopIdentity(
                expectedKey: "observer:1",
                observedKey: "observer:2",
                currentKey: "observer:2",
                state: "changed",
                generating: true
            ),
        ])

        let firstStop = await store.stop(runtimeId: "runtime.web", instanceId: "web.chatgpt", sessionId: sessionId)
        XCTAssertFalse(firstStop)
        let diagnostic = try XCTUnwrap(store.stopDiagnosticsBySession[sessionId])
        XCTAssertEqual(diagnostic.code, .staleGeneration)
        XCTAssertEqual(diagnostic.recovery, .readyForExplicitStop)
        XCTAssertTrue(diagnostic.generationIdentityRefreshed)
        let firstAttemptCount = await mock.actionAttemptCount("stopGeneration")
        let staleTerminalEvents = await mock.eventCount(type: "GENERATION_STOPPED", sessionId: sessionId)
        XCTAssertEqual(firstAttemptCount, 1)
        XCTAssertEqual(staleTerminalEvents, 0,
            "A stale identity receipt must not synthesize a terminal event.")
        XCTAssertNotEqual(store.errors[sessionId], "停止命令针对的生成已变化；没有停止新的生成。")

        // The explicit confirmation must inspect the updated generation again.
        await mock.setOpenWebTabInspectionOverrides(tabId: 12, fields: inspection(
            diagnosisState: "generating",
            generating: true,
            expectedKey: "observer:2",
            observedKey: "observer:2",
            currentKey: "observer:2",
            identityState: "matched"
        ))
        let secondStop = await store.stop(runtimeId: "runtime.web", instanceId: "web.chatgpt", sessionId: sessionId)
        XCTAssertTrue(secondStop)
        let payloads = await mock.commandPayloads(action: "stopGeneration")
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0]["expectedGenerationKey"]?.stringValue, "observer:1")
        XCTAssertEqual(payloads[1]["expectedGenerationKey"]?.stringValue, "observer:2")
        XCTAssertNil(store.stopDiagnosticsBySession[sessionId])
        XCTAssertEqual(store.sessions.first(where: { $0.id == sessionId })?.state, .idle)
        await store.suspend()
    }

    func testMissingIdentityCapabilityBlocksStopAndReadOnlyRecheck() async throws {
        let (store, mock) = try await preparedWebChat()
        await mock.setOpenWebTabInspectionOverrides(tabId: 12, fields: [
            "state": .string("generating"),
            "generating": .bool(true),
        ])

        let stopped = await store.stop(runtimeId: "runtime.web", instanceId: "web.chatgpt", sessionId: sessionId)
        XCTAssertFalse(stopped)
        let firstAttemptCount = await mock.actionAttemptCount("stopGeneration")
        XCTAssertEqual(firstAttemptCount, 0,
            "An older Agent without the identity capability must fail closed before Stop.")
        XCTAssertEqual(store.stopDiagnosticsBySession[sessionId]?.recovery, .needsComputerVerification)
        let rechecked = await store.recheckStopIdentity(sessionId: sessionId)
        let secondAttemptCount = await mock.actionAttemptCount("stopGeneration")
        XCTAssertFalse(rechecked)
        XCTAssertEqual(secondAttemptCount, 0,
            "The computer-check action is read-only and never dispatches Stop.")
        XCTAssertEqual(store.sessions.first(where: { $0.id == sessionId })?.state, .busy)
        await store.suspend()
    }

    func testProgressDuringIdentityInspectionDoesNotInvalidateSameRunStop() async throws {
        let (store, mock) = try await preparedWebChat()
        await mock.setOpenWebTabInspectionOverrides(tabId: 12, fields: inspection(
            diagnosisState: "generating",
            generating: true,
            expectedKey: "observer:1",
            observedKey: "observer:1",
            currentKey: "observer:1",
            identityState: "matched"
        ))
        await mock.setResponseDelay(action: "inspectOpenWebTab", nanoseconds: 250_000_000)

        let stopTask = Task {
            await store.stop(runtimeId: "runtime.web", instanceId: "web.chatgpt", sessionId: sessionId)
        }
        let inspectionStarted = await waitForActionCount("inspectOpenWebTab", 1, from: mock)
        XCTAssertTrue(inspectionStarted)
        let progressAt = Date()
        await mock.injectEvent(event(
            sequence: 1202,
            type: "TOOL_STARTED",
            at: progressAt,
            payload: ["tool": .object(["id": .string("search-1"), "name": .string("web_search")])]
        ), deliverLive: true)
        let progressApplied = await waitForActivity(atOrAfter: progressAt, in: store)
        XCTAssertTrue(progressApplied)

        let stopped = await stopTask.value
        let stopAttempts = await mock.actionAttemptCount("stopGeneration")
        XCTAssertTrue(stopped)
        XCTAssertEqual(stopAttempts, 1)
        XCTAssertEqual(store.sessions.first(where: { $0.id == sessionId })?.state, .idle)
        await store.suspend()
    }

    func testNewGenerationDuringIdentityInspectionBlocksOldStop() async throws {
        let (store, mock) = try await preparedWebChat()
        await mock.setOpenWebTabInspectionOverrides(tabId: 12, fields: inspection(
            diagnosisState: "generating",
            generating: true,
            expectedKey: "observer:1",
            observedKey: "observer:1",
            currentKey: "observer:1",
            identityState: "matched"
        ))
        await mock.setResponseDelay(action: "inspectOpenWebTab", nanoseconds: 250_000_000)

        let stopTask = Task {
            await store.stop(runtimeId: "runtime.web", instanceId: "web.chatgpt", sessionId: sessionId)
        }
        let inspectionStarted = await waitForActionCount("inspectOpenWebTab", 1, from: mock)
        XCTAssertTrue(inspectionStarted)
        let nextRunAt = Date()
        await mock.injectEvent(event(
            sequence: 1202,
            type: "GENERATION_STARTED",
            at: nextRunAt,
            payload: ["generationKey": .string("observer:2")]
        ), deliverLive: true)
        let nextRunApplied = await waitForActivity(atOrAfter: nextRunAt, in: store)
        XCTAssertTrue(nextRunApplied)

        let stopped = await stopTask.value
        let stopAttempts = await mock.actionAttemptCount("stopGeneration")
        XCTAssertFalse(stopped)
        XCTAssertEqual(stopAttempts, 0)
        XCTAssertEqual(store.sessions.first(where: { $0.id == sessionId })?.state, .busy)
        XCTAssertNil(store.stopDiagnosticsBySession[sessionId],
            "A late preflight from the prior run must not overwrite the new run's diagnostic state.")
        await store.suspend()
    }

    func testOfflinePresenceRefreshUsesBackoffSchedule() {
        XCTAssertEqual(ConnectionFailureEpisode.offlineProbeDelay(occurrenceCount: 1), 5)
        XCTAssertEqual(ConnectionFailureEpisode.offlineProbeDelay(occurrenceCount: 2), 10)
        XCTAssertEqual(ConnectionFailureEpisode.offlineProbeDelay(occurrenceCount: 3), 20)
        XCTAssertEqual(ConnectionFailureEpisode.offlineProbeDelay(occurrenceCount: 4), 40)
        XCTAssertEqual(ConnectionFailureEpisode.offlineProbeDelay(occurrenceCount: 5), 60)
        XCTAssertEqual(ConnectionFailureEpisode.offlineProbeDelay(occurrenceCount: 99), 60)

        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var episode = ConnectionFailureEpisode(fingerprint: "offline", observedAt: startedAt)
        XCTAssertFalse(episode.isPresenceRefreshDue(at: startedAt.addingTimeInterval(4.999)))
        XCTAssertTrue(episode.isPresenceRefreshDue(at: startedAt.addingTimeInterval(5)))
        episode.recordPresenceRefreshAttempt(at: startedAt.addingTimeInterval(5))
        XCTAssertFalse(episode.isPresenceRefreshDue(at: startedAt.addingTimeInterval(14.999)))
        XCTAssertTrue(episode.isPresenceRefreshDue(at: startedAt.addingTimeInterval(15)))
    }

    private func preparedWebChat() async throws -> (WorkspaceStore, MockTransport) {
        let mock = MockTransport(historyCount: 0)
        let runAt = Date().addingTimeInterval(-1)
        await mock.seedWebChatSession(
            sessionId: sessionId,
            canonicalUrl: canonicalURL,
            status: "generating",
            projectAlias: "g-p-remoteai",
            lastActivityAt: runAt
        )
        await mock.setOpenWebTabCurrentSessionOverride(tabId: 12, sessionId: sessionId)
        let store = WorkspaceStore(transport: mock, cache: try SQLiteStore.inMemory())
        await store.start()
        await store.refreshOpenWebTabs()
        let runtime = try XCTUnwrap(store.runtimes.first(where: { $0.id == "runtime.web" }))
        await store.refreshRuntime(runtime)
        let instance = try XCTUnwrap(store.instances.first(where: { $0.id == "web.chatgpt" }))
        await store.refreshSessions(runtime: runtime, instance: instance)
        await mock.setSessionStatus(sessionId, status: "generating", lastActivityAt: runAt, updatedAt: runAt)
        await mock.injectEvent(event(
            sequence: 1201,
            type: "GENERATION_STARTED",
            at: runAt,
            payload: ["generationKey": .string("observer:1")]
        ), deliverLive: true)
        let activityApplied = await waitForActivity(atOrAfter: runAt, in: store)
        XCTAssertTrue(activityApplied)
        return (store, mock)
    }

    private func inspection(
        diagnosisState: String,
        generating: Bool,
        expectedKey: String?,
        observedKey: String?,
        currentKey: String?,
        identityState: String
    ) -> [String: JSONValue] {
        [
            "state": .string(diagnosisState),
            "generating": .bool(generating),
            "stopIdentity": stopIdentity(
                expectedKey: expectedKey,
                observedKey: observedKey,
                currentKey: currentKey,
                state: identityState,
                generating: generating
            ),
        ]
    }

    private func stopIdentity(
        expectedKey: String?,
        observedKey: String?,
        currentKey: String?,
        state: String,
        generating: Bool
    ) -> JSONValue {
        .object([
            "expectedGenerationKey": expectedKey.map(JSONValue.string) ?? .null,
            "observedGenerationKey": observedKey.map(JSONValue.string) ?? .null,
            "currentGenerationKey": currentKey.map(JSONValue.string) ?? .null,
            "state": .string(state),
            "source": .string("chatgpt-extension-observer"),
            "observedAt": .string(RemoteAIDate.string(Date())),
            "pageVerified": .bool(true),
            "generating": .bool(generating),
        ])
    }

    private func event(
        sequence: Int64,
        type: String,
        at: Date,
        payload: [String: JSONValue]
    ) -> RemoteEvent {
        RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: sequence,
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "web.chatgpt",
            sessionId: sessionId,
            type: type,
            payload: payload,
            createdAt: at
        )
    }

    private func waitForActionCount(_ action: String, _ expected: Int, from mock: MockTransport) async -> Bool {
        for _ in 0..<100 {
            if await mock.actionAttemptCount(action) >= expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await mock.actionAttemptCount(action) >= expected
    }

    private func waitForActivity(atOrAfter date: Date, in store: WorkspaceStore) async -> Bool {
        for _ in 0..<100 {
            if let activity = store.sessions.first(where: { $0.id == sessionId })?.lastActivityAt,
               activity >= date { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return (store.sessions.first(where: { $0.id == sessionId })?.lastActivityAt ?? .distantPast) >= date
    }
}
