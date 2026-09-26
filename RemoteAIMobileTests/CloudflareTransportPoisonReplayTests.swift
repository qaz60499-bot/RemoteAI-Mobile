import XCTest
@testable import RemoteAIMobile

final class CloudflareTransportPoisonReplayTests: XCTestCase {
    func testMalformedReliableReplayIsQuarantinedInsteadOfDroppingSocket() {
        XCTAssertTrue(
            CloudflareTransport.shouldQuarantineInboundEncryptedFrame(TransportError.malformedData)
        )
    }

    func testOversizedReliableReplayIsQuarantinedInsteadOfDroppingSocket() {
        XCTAssertTrue(
            CloudflareTransport.shouldQuarantineInboundEncryptedFrame(TransportError.frameTooLarge)
        )
    }

    func testOperationalTransportFailuresStillTearDownSocket() {
        XCTAssertFalse(
            CloudflareTransport.shouldQuarantineInboundEncryptedFrame(TransportError.disconnected)
        )
        XCTAssertFalse(
            CloudflareTransport.shouldQuarantineInboundEncryptedFrame(TransportError.timeout)
        )
        XCTAssertFalse(
            CloudflareTransport.shouldQuarantineInboundEncryptedFrame(TransportError.pairingRequired)
        )
        XCTAssertFalse(
            CloudflareTransport.shouldQuarantineInboundEncryptedFrame(
                TransportError.remote("UNAUTHORIZED_DEVICE", "repair required")
            )
        )
    }
}
