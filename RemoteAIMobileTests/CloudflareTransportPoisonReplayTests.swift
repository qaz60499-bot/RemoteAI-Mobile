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

    func testRelaySessionDoesNotInheritSystemProxy() {
        let configuration = CloudflareTransport.relaySessionConfiguration()
        XCTAssertNotNil(configuration.connectionProxyDictionary)
        XCTAssertTrue(configuration.connectionProxyDictionary?.isEmpty == true)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testHeartbeatTimeoutReconnectsWhenNoInboundTrafficArrivesAfterPing() {
        let pingSentAt = Date()
        XCTAssertTrue(CloudflareTransport.shouldReconnectAfterHeartbeatTimeout(
            awaitingPongMessageId: "ping-1",
            expectedMessageId: "ping-1",
            lastInboundFrameAt: pingSentAt.addingTimeInterval(-1),
            pingSentAt: pingSentAt
        ))
    }

    func testHeartbeatTimeoutKeepsSocketWhenAuthenticatedInboundTrafficArrivesAfterPing() {
        let pingSentAt = Date()
        XCTAssertFalse(CloudflareTransport.shouldReconnectAfterHeartbeatTimeout(
            awaitingPongMessageId: "ping-1",
            expectedMessageId: "ping-1",
            lastInboundFrameAt: pingSentAt.addingTimeInterval(0.25),
            pingSentAt: pingSentAt
        ))
    }

    func testHeartbeatTimeoutIsAlreadySatisfiedWhenPongClearedAwaitingId() {
        let pingSentAt = Date()
        XCTAssertFalse(CloudflareTransport.shouldReconnectAfterHeartbeatTimeout(
            awaitingPongMessageId: nil,
            expectedMessageId: "ping-1",
            lastInboundFrameAt: nil,
            pingSentAt: pingSentAt
        ))
    }
}
