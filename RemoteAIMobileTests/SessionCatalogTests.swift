import XCTest
import Combine
import UIKit
@testable import RemoteAIMobile

final class SessionCatalogTests: XCTestCase {
    @MainActor
    func testLiveRegistrationAdvancesCursorWith648RowCatalogOverKVLimit() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        let catalog = Self.largeCatalog(count: 648)
        let encodedCatalog = try JSONEncoder.remoteAI.encode(catalog)
        let largestRow = try catalog.map { try JSONEncoder.remoteAI.encode($0).count }.max() ?? 0
        XCTAssertGreaterThan(encodedCatalog.count, SQLiteStore.maxKVBytes)
        XCTAssertLessThan(largestRow, SQLiteStore.maxKVBytes)
        store.sessions = catalog

        await mock.injectEvent(Self.registrationEvent(sequence: 1201, sessionId: "registered-large-catalog"), deliverLive: true)
        for _ in 0..<100 {
            if (try? await cache.lastSequence()) == 1201 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let appliedSequence = try await cache.lastSequence()
        XCTAssertEqual(appliedSequence, 1201, "The registration event must persist before advancing the durable cursor")
        let persistedCatalogValue = try await cache.getSessionCatalog()
        let persistedCatalog = try XCTUnwrap(persistedCatalogValue)
        XCTAssertEqual(persistedCatalog.count, 649)
        XCTAssertTrue(persistedCatalog.contains { $0.id == "registered-large-catalog" })
        XCTAssertTrue(store.sessions.contains { $0.id == "registered-large-catalog" })
        await store.suspend()
    }

    func testSessionCatalogRoundTripsAllRowsInOrder() async throws {
        let cache = try SQLiteStore.inMemory()
        var first = Self.session("first", at: 1_700_000_000)
        first.projectAlias = "g-p-first"
        first.canonicalUrl = "https://chatgpt.com/g/g-p-first/c/first"
        var second = Self.session("second", at: 1_700_000_001)
        second.workingDirectory = "C:\\work\\second"
        let expected = [first, second, Self.session("third", at: 1_700_000_002)]

        try await cache.replaceSessionCatalog(expected)

        let stored = try await cache.getSessionCatalog()
        let actual = try XCTUnwrap(stored)
        XCTAssertEqual(actual, expected)
    }

    func testLegacyCatalogFallsBackOnceAndEmptyReplacementStaysEmpty() async throws {
        let cache = try SQLiteStore.inMemory()
        let legacy = Self.session("legacy", at: 1_700_000_000)
        try await cache.put([legacy], key: "sessions")

        let migratedRead = try await cache.getSessionCatalog()
        XCTAssertEqual(try XCTUnwrap(migratedRead), [legacy])

        try await cache.replaceSessionCatalog([])

        let emptyCatalog = try await cache.getSessionCatalog()
        let removedLegacyValue = try await cache.get([SessionDescriptor].self, key: "sessions")
        XCTAssertEqual(try XCTUnwrap(emptyCatalog), [])
        XCTAssertNil(removedLegacyValue, "A successfully initialized empty catalog must not fall back to stale legacy rows")
    }

    @MainActor
    func testOversizedSessionRowRollsBackCatalogAndLeavesEventCursorUnchanged() async throws {
        let cache = try SQLiteStore.inMemory()
        let mock = MockTransport(historyCount: 0)
        let store = WorkspaceStore(transport: mock, cache: cache)
        await store.start()

        let previousCatalog = [Self.session("previous", at: 1_700_000_000)]
        let normal = Self.session("normal", at: 1_700_000_001)
        try await cache.replaceSessionCatalog(previousCatalog)
        try await cache.setLastSequence(1200)
        let cursorBeforeEvent = try await cache.lastSequence()
        var oversized = Self.session("oversized", at: 1_700_000_002)
        oversized.title = String(repeating: "x", count: SQLiteStore.maxKVBytes)
        store.sessions = [normal, oversized]
        store.errors["sync"] = nil

        await mock.injectEvent(Self.registrationEvent(sequence: 1201, sessionId: "registration-after-oversized-row"), deliverLive: true)
        for _ in 0..<100 {
            if store.errors["sync"] != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let retainedCatalog = try await cache.getSessionCatalog()
        let cursorAfterEvent = try await cache.lastSequence()
        XCTAssertEqual(try XCTUnwrap(retainedCatalog), previousCatalog, "A failed replacement must roll back every catalog row")
        XCTAssertEqual(cursorAfterEvent, cursorBeforeEvent, "A failed registration must not advance the durable cursor")
        XCTAssertNotNil(store.errors["sync"])

        do {
            try await cache.replaceSessionCatalog([normal, oversized])
            XCTFail("An oversized catalog row should be rejected")
        } catch {
            XCTAssertEqual((error as NSError).code, 4, "valueTooLarge must retain the StoreError code reported by the device")
        }
        let retainedAfterDirectReplacement = try await cache.getSessionCatalog()
        XCTAssertEqual(
            try XCTUnwrap(retainedAfterDirectReplacement),
            previousCatalog,
            "A direct replacement must roll back a normal row inserted before the oversized row"
        )
        await store.suspend()
    }

    private static func session(_ id: String, at time: TimeInterval) -> SessionDescriptor {
        SessionDescriptor(
            id: id,
            instanceId: "web.chatgpt",
            title: id,
            state: .idle,
            updatedAt: Date(timeIntervalSince1970: time)
        )
    }

    private static func largeCatalog(count: Int) -> [SessionDescriptor] {
        (0..<count).map { index in
            SessionDescriptor(
                id: "catalog-\(index)",
                instanceId: "web.chatgpt",
                title: "Catalog row \(index) " + String(repeating: "s", count: 512),
                state: .idle,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
    }

    private static func registrationEvent(sequence: Int64, sessionId: String) -> RemoteEvent {
        RemoteEvent(
            protocolVersion: 1,
            eventId: UUID(),
            sequence: sequence,
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "web.chatgpt",
            sessionId: sessionId,
            type: "WEB_PAGE_REGISTERED",
            payload: [
                "localConversationId": .string(sessionId),
                "canonicalUrl": .string("https://chatgpt.com/g/g-p-remoteai/c/\(sessionId)"),
                "displayTitle": .string("Registered large-catalog conversation"),
                "projectAlias": .string("g-p-remoteai"),
                "conversationAlias": .string(sessionId),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }
}
