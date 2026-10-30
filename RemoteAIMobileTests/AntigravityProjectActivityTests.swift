import XCTest
@testable import RemoteAIMobile

final class AntigravityProjectActivityTests: XCTestCase {
    func testLegacyProjectCacheDecodesWithoutActivityField() throws {
        let data = Data(#"{"projectAlias":"legacy-project","projectId":"legacy-id","displayName":"Legacy","canonicalUrl":"antigravity://project/legacy-project","lastSeenAt":null,"lastOpenedAt":null}"#.utf8)

        let project = try JSONDecoder.remoteAI.decode(WebProjectDescriptor.self, from: data)

        XCTAssertEqual(project.projectAlias, "legacy-project")
        XCTAssertNil(project.lastActivityAt)
    }

    func testActivityFieldRoundTripsThroughProjectCodable() throws {
        let activity = Date(timeIntervalSince1970: 1_700_000_000.125)
        let project = WebProjectDescriptor(
            projectAlias: "active-project",
            projectId: "active-id",
            displayName: "Active",
            canonicalUrl: "antigravity://project/active-project",
            lastSeenAt: nil,
            lastOpenedAt: nil,
            lastActivityAt: activity
        )

        let data = try JSONEncoder.remoteAI.encode(project)
        let decoded = try JSONDecoder.remoteAI.decode(WebProjectDescriptor.self, from: data)

        XCTAssertEqual(decoded.lastActivityAt, activity)
    }

    func testAntigravityProjectsSortByActivityThenAliasWithUnknownActivityLast() {
        let recent = project("recent", activity: date(300))
        let tiedZ = project("zeta", activity: date(200))
        let tiedA = project("alpha", activity: date(200))
        let unknownZ = project("unknown-z", activity: nil)
        let middle = project("middle", activity: date(250))
        let unknownA = project("unknown-a", activity: nil)

        let sorted = AntigravityProjectOrdering.sorted([unknownZ, tiedZ, recent, unknownA, middle, tiedA])

        XCTAssertEqual(sorted.map(\.projectAlias), ["recent", "middle", "alpha", "zeta", "unknown-a", "unknown-z"])
        XCTAssertEqual(AntigravityProjectOrdering.sorted(sorted).map(\.projectAlias), sorted.map(\.projectAlias))
    }

    func testFallbackUsesLatestMemberSessionOrderingDateAndKeepsDefaultWorkspaceUnknown() {
        let sessions = [
            session(id: "alpha-old", instanceId: "ag", alias: "alpha", updatedAt: date(100), activity: date(90)),
            session(id: "alpha-new", instanceId: "ag", alias: "alpha", updatedAt: date(80), activity: date(110)),
            session(id: "beta", instanceId: "ag", alias: "beta", updatedAt: date(105)),
            session(id: "other-instance", instanceId: "other", alias: "ignored", updatedAt: date(500)),
            session(id: "no-project", instanceId: "ag", alias: nil, updatedAt: date(400))
        ]

        let projects = AntigravityProjectOrdering.fallbackProjects(from: sessions, instanceId: "ag")
        let byAlias = Dictionary(uniqueKeysWithValues: projects.map { ($0.projectAlias, $0) })

        XCTAssertEqual(projects.map(\.projectAlias), ["alpha", "beta", "googleac"])
        XCTAssertEqual(byAlias["alpha"]?.lastActivityAt, date(110))
        XCTAssertEqual(byAlias["beta"]?.lastActivityAt, date(105))
        XCTAssertNil(byAlias["googleac"]?.lastActivityAt)
    }

    func testWebProjectResponseKeepsProviderOrderWhenActivityDatesDiffer() throws {
        let providerOrder = [
            project("provider-first", activity: date(100)),
            project("provider-second", activity: date(300)),
            project("provider-third", activity: nil)
        ]
        let response = WebProjectListResponse(items: providerOrder, observedAt: date(400))

        let data = try JSONEncoder.remoteAI.encode(response)
        let decoded = try JSONDecoder.remoteAI.decode(WebProjectListResponse.self, from: data)

        XCTAssertEqual(decoded.items.map(\.projectAlias), providerOrder.map(\.projectAlias))
    }

    private func project(_ alias: String, activity: Date?) -> WebProjectDescriptor {
        WebProjectDescriptor(
            projectAlias: alias,
            projectId: alias,
            displayName: alias,
            canonicalUrl: "antigravity://project/\(alias)",
            lastSeenAt: nil,
            lastOpenedAt: nil,
            lastActivityAt: activity
        )
    }

    private func session(
        id: String,
        instanceId: String,
        alias: String?,
        updatedAt: Date,
        activity: Date? = nil
    ) -> SessionDescriptor {
        SessionDescriptor(
            id: id,
            instanceId: instanceId,
            title: id,
            state: .idle,
            updatedAt: updatedAt,
            projectAlias: alias,
            lastActivityAt: activity
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
