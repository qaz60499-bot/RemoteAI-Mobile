import XCTest
@testable import RemoteAIMobile

@MainActor
final class RecoveryDiagnosticsTests: XCTestCase {
    func testNonTransportFailureFingerprintIncludesErrorDomainAndNumericCode() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        let offlineFingerprint = WorkspaceStore.connectionFailureFingerprint(for: offline)
        let timeoutFingerprint = WorkspaceStore.connectionFailureFingerprint(for: timeout)

        XCTAssertEqual(offlineFingerprint, "NSURLErrorDomain_\(NSURLErrorNotConnectedToInternet)")
        XCTAssertEqual(timeoutFingerprint, "NSURLErrorDomain_\(NSURLErrorTimedOut)")
        XCTAssertNotEqual(offlineFingerprint, timeoutFingerprint,
            "Different underlying network errors must begin distinct observable episodes.")

        let observedAt = Date()
        var episode = ConnectionFailureEpisode(fingerprint: offlineFingerprint, observedAt: observedAt)
        XCTAssertFalse(episode.observe(fingerprint: timeoutFingerprint, at: observedAt.addingTimeInterval(1)))
        XCTAssertEqual(episode.occurrenceCount, 1)
    }
}
