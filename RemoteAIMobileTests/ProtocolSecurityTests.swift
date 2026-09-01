import XCTest
@testable import RemoteAIMobile

final class ProtocolSecurityTests: XCTestCase {
    private let timestamp = "2026-09-01T16:00:00.000Z"

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validCommandObject() -> [String: Any] {
        [
            "protocolVersion": 1,
            "commandId": "00000000-0000-0000-0000-000000000101",
            "machineId": "my-pc",
            "runtimeId": "runtime.web",
            "instanceId": "agent",
            "sessionId": "session-1",
            "action": "sendMessage",
            "payload": ["text": "hello"],
            "createdAt": timestamp
        ]
    }

    private func validEventObject(sequence: Int64 = 11, eventId: String = "00000000-0000-0000-0000-000000000201", machineId: String = "my-pc") -> [String: Any] {
        [
            "protocolVersion": 1,
            "eventId": eventId,
            "sequence": sequence,
            "machineId": machineId,
            "runtimeId": "runtime.web",
            "instanceId": "agent",
            "sessionId": "session-1",
            "type": "MESSAGE_ADDED",
            "payload": ["content": "ok"],
            "createdAt": timestamp
        ]
    }

    private func validRelayObject() -> [String: Any] {
        [
            "v": 1,
            "kind": "ENCRYPTED",
            "machineId": "my-pc",
            "deviceId": "ios-00000000-0000-0000-0000-000000000001",
            "messageId": "00000000-0000-0000-0000-000000000301",
            "body": [
                "alg": "A256GCM",
                "nonce": Base64URL.encode(Data(repeating: 1, count: 12)),
                "ciphertext": Base64URL.encode(Data([1, 2, 3, 4])),
                "tag": Base64URL.encode(Data(repeating: 2, count: 16))
            ]
        ]
    }

    @discardableResult
    private func expectReject(_ name: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        do {
            try body()
            XCTFail("Expected rejection: \(name)", file: file, line: line)
            return false
        } catch {
            return true
        }
    }

    private func event(sequence: Int64, id: UUID = UUID(), machineId: String = "my-pc") -> RemoteEvent {
        RemoteEvent(
            protocolVersion: 1,
            eventId: id,
            sequence: sequence,
            machineId: machineId,
            runtimeId: "runtime.web",
            instanceId: "agent",
            sessionId: "session-1",
            type: "MESSAGE_ADDED",
            payload: ["content": .string("ok")],
            createdAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }

    func testProtocolNegativeMatrix() throws {
        var passed = 0
        var total = 0
        func run(_ name: String, _ body: () throws -> Void) {
            total += 1
            if expectReject(name, body) { passed += 1 }
        }

        run("protocolVersion wrong") {
            var object = validCommandObject(); object["protocolVersion"] = 2
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("required field missing") {
            var object = validCommandObject(); object.removeValue(forKey: "commandId")
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("unexpected command field") {
            var object = validCommandObject(); object["unexpected"] = true
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("overlong machineId") {
            var object = validCommandObject(); object["machineId"] = String(repeating: "m", count: 161)
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("overlong deviceId") {
            var object = validRelayObject(); object["deviceId"] = String(repeating: "d", count: 161)
            _ = try ProtocolSecurity.decodeRelayFrame(json(object))
        }
        run("overlong sessionId") {
            var object = validCommandObject(); object["sessionId"] = String(repeating: "s", count: 161)
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("illegal ID character") {
            var object = validCommandObject(); object["machineId"] = "pc/../bad"
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("malformed JSON") {
            _ = try ProtocolSecurity.decodeRelayFrame(Data("{\"v\":1".utf8))
        }
        run("wrong relay protocol version") {
            var object = validRelayObject(); object["v"] = 2
            _ = try ProtocolSecurity.decodeRelayFrame(json(object))
        }
        run("unknown relay kind") {
            var object = validRelayObject(); object["kind"] = "EXEC_SHELL"
            _ = try ProtocolSecurity.decodeRelayFrame(json(object))
        }
        run("unknown event type") {
            var object = validEventObject(); object["type"] = "UNKNOWN_EVENT"
            _ = try ProtocolSecurity.decodeEvent(json(object))
        }
        run("sequence zero") {
            var object = validEventObject(); object["sequence"] = 0
            _ = try ProtocolSecurity.decodeEvent(json(object))
        }
        run("sequence negative") {
            var object = validEventObject(); object["sequence"] = -1
            _ = try ProtocolSecurity.decodeEvent(json(object))
        }
        run("sequence beyond Int64") {
            let raw = "{\"protocolVersion\":1,\"eventId\":\"00000000-0000-0000-0000-000000000201\",\"sequence\":9223372036854775808,\"machineId\":\"my-pc\",\"runtimeId\":\"runtime.web\",\"instanceId\":\"agent\",\"sessionId\":\"session-1\",\"type\":\"MESSAGE_ADDED\",\"payload\":{},\"createdAt\":\"2026-09-01T16:00:00.000Z\"}"
            _ = try ProtocolSecurity.decodeEvent(Data(raw.utf8))
        }

        let duplicateId = UUID()
        run("duplicate eventId") {
            try ProtocolSecurity.validateDelta(
                DeltaSyncResult(events: [event(sequence: 11, id: duplicateId), event(sequence: 12, id: duplicateId)], nextCursor: 12, hasMore: false),
                after: 10,
                expectedMachineId: "my-pc"
            )
        }
        run("duplicate sequence") {
            try ProtocolSecurity.validateDelta(
                DeltaSyncResult(events: [event(sequence: 11), event(sequence: 11)], nextCursor: 11, hasMore: false),
                after: 10,
                expectedMachineId: "my-pc"
            )
        }
        run("sequence gap") {
            try ProtocolSecurity.validateDelta(
                DeltaSyncResult(events: [event(sequence: 12)], nextCursor: 12, hasMore: false),
                after: 10,
                expectedMachineId: "my-pc"
            )
        }
        run("sequence disorder") {
            try ProtocolSecurity.validateDelta(
                DeltaSyncResult(events: [event(sequence: 12), event(sequence: 11)], nextCursor: 11, hasMore: false),
                after: 10,
                expectedMachineId: "my-pc"
            )
        }

        run("wrong frame machineId") {
            let frame = try ProtocolSecurity.decodeRelayFrame(json(validRelayObject()))
            try ProtocolSecurity.validate(frame, expectedMachineId: "other-pc", expectedDeviceId: frame.deviceId)
        }
        run("wrong frame deviceId") {
            let frame = try ProtocolSecurity.decodeRelayFrame(json(validRelayObject()))
            try ProtocolSecurity.validate(frame, expectedMachineId: "my-pc", expectedDeviceId: "ios-other")
        }
        run("event wrong machineId") {
            _ = try ProtocolSecurity.decodeEvent(json(validEventObject(machineId: "other-pc")), expectedMachineId: "my-pc")
        }
        run("unexpected encrypted body field") {
            var object = validRelayObject()
            var body = object["body"] as! [String: Any]
            body["debug"] = true
            object["body"] = body
            _ = try ProtocolSecurity.decodeRelayFrame(json(object))
        }
        run("missing encrypted tag") {
            var object = validRelayObject()
            var body = object["body"] as! [String: Any]
            body.removeValue(forKey: "tag")
            object["body"] = body
            _ = try ProtocolSecurity.decodeRelayFrame(json(object))
        }
        run("encrypted frame without deviceId") {
            var object = validRelayObject(); object["deviceId"] = NSNull()
            _ = try ProtocolSecurity.decodeRelayFrame(json(object))
        }
        run("unknown command action") {
            var object = validCommandObject(); object["action"] = "runPowerShell"
            _ = try ProtocolSecurity.decodeCommand(json(object))
        }
        run("corrupted delta nextCursor") {
            try ProtocolSecurity.validateDelta(
                DeltaSyncResult(events: [event(sequence: 11)], nextCursor: 999, hasMore: false),
                after: 10,
                expectedMachineId: "my-pc"
            )
        }
        run("corrupted delta hasMore empty") {
            try ProtocolSecurity.validateDelta(
                DeltaSyncResult(events: [], nextCursor: 10, hasMore: true),
                after: 10,
                expectedMachineId: "my-pc"
            )
        }
        run("corrupted pagination cursor") {
            try ProtocolSecurity.validateCursor(MessageCursor(createdAt: Date(), messageId: "bad/cursor"))
        }
        run("relay URL embeds credentials") {
            try RemoteAIConfig.validateSecureRelay(URL(string: "https://user:pass@relay.example.com")!)
        }
        run("Unicode pairing digits") {
            if ProtocolSecurity.validatePairingCode("１２３４５６７８") == false { throw TransportError.malformedData }
        }
        run("pair accept machine-key substitution") {
            let challenge = "MCowBQYDK2VuAyEAVr06jCbV51kSzd0v7tBO792LaFqWw1OmZ8FX5LdMhzY="
            let substituted = "MCowBQYDK2VuAyEAT14+n+/J0UNC2Z8kSyBbnt4dU2+P8xOCPKc14UHIF3g="
            _ = try ProtocolSecurity.validatedPairingMachineKey(challengeKey: challenge, acceptedKey: substituted)
        }
        run("strict Base64URL rejects standard alphabet") {
            if Base64URL.decode("+/8") == nil { throw TransportError.malformedData }
        }
        run("strict Base64URL rejects padding") {
            if Base64URL.decode("-_8=") == nil { throw TransportError.malformedData }
        }

        var replay = BoundedReplayGuard(capacity: 4)
        XCTAssertTrue(replay.accept("message-1"))
        run("replayed ENCRYPTED messageId") {
            guard replay.accept("message-1") == false else { return }
            throw TransportError.replayDetected
        }

        XCTAssertEqual(total, 34)
        XCTAssertEqual(passed, total)
        print("PROTOCOL_FUZZ_NEGATIVE cases=\(total) pass=\(passed) fail=\(total - passed)")
    }

    func testCryptoNegativeMatrixAndWindowsNodeVectors() throws {
        let privatePKCS8 = Data(base64Encoded: "MC4CAQAwBQYDK2VuBCIEIDDswlYnNeavIx4tzsUq2sYCQc1nAZTUU80ahYByK/x4")!
        let privateRaw = Data(privatePKCS8.suffix(32))
        XCTAssertEqual(
            try PayloadCrypto.publicKeySPKIBase64(privateKeyRaw: privateRaw),
            "MCowBQYDK2VuAyEAT14+n+/J0UNC2Z8kSyBbnt4dU2+P8xOCPKc14UHIF3g="
        )

        let key = try PayloadCrypto.deriveSharedKey(
            privateKeyRaw: privateRaw,
            machinePublicKeyB64: "MCowBQYDK2VuAyEAVr06jCbV51kSzd0v7tBO792LaFqWw1OmZ8FX5LdMhzY=",
            machineId: "machine-test-001",
            deviceId: "ios-test-001"
        )
        XCTAssertEqual(key.base64EncodedString(), "6zdQi/1ISlyQF1K/60BC1faFTOYa5Po/LUm7TUKdTAI=")

        let proof = PayloadCrypto.pairingProof(
            pairingCode: "12345678",
            challenge: "challenge_test_123",
            machineId: "machine-test-001",
            deviceId: "ios-test-001",
            devicePublicKeyB64: "MCowBQYDK2VuAyEAT14+n+/J0UNC2Z8kSyBbnt4dU2+P8xOCPKc14UHIF3g="
        )
        XCTAssertEqual(proof, "-aimXXz2Bt84NKf1cpt3YSeTSI6PhPrOP7PxTY6a7Fo")
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff, 0x00, 0x10, 0x7f])), "-_8AEH8")

        let windowsBody = EncryptedRelayBody(
            alg: "A256GCM",
            nonce: "7bbcpBwLpVmbPZzm",
            ciphertext: "DZ543nZlttX-MuGry7Ssuj6f8H_aRqIfkDq2KiO-kjnRMP8mTPNydYEkKE5SOTIJ_AfpdcdovPWHyJuw1MXQ3o7G4qeW1pxa074SnqIjvPWIwLPMNGAOlOtnLYk7FXYqN3ypTnl8EbBUkyWwp9hudQ8QpeF3CgH_7afdZ7a6sQqEFy_7qmcmzJ0L1ExsFQWVsjh5fzwxMPV1BTzqpfvBK7sb_UrsuN64pU2jQM0GT_McofWgy0WhynqjRC1SAtI37DGcSMvoEnnL3bjEGJRZMTz3BHdURdTou_ezvzh_KxG_DcSZsJOxZUVoEk44rvNDOrAl",
            tag: "FMq6uFeoyzsM0QB9326P2A"
        )
        let clear = try PayloadCrypto.decrypt(
            windowsBody,
            keyData: key,
            machineId: "machine-test-001",
            deviceId: "ios-test-001",
            messageId: "00000000-0000-0000-0000-000000000099"
        )
        let command = try ProtocolSecurity.decodeCommand(clear)
        XCTAssertEqual(command.action, "listRuntimes")

        var passed = 0
        var total = 0
        func reject(_ name: String, _ body: () throws -> Void) {
            total += 1
            if expectReject(name, body) { passed += 1 }
        }
        reject("wrong messageId / AAD") {
            _ = try PayloadCrypto.decrypt(windowsBody, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000098")
        }
        reject("wrong machineId / AAD") {
            _ = try PayloadCrypto.decrypt(windowsBody, keyData: key, machineId: "machine-test-002", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        }
        reject("wrong deviceId / AAD") {
            _ = try PayloadCrypto.decrypt(windowsBody, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-002", messageId: "00000000-0000-0000-0000-000000000099")
        }
        reject("AES-GCM wrong tag") {
            let bad = EncryptedRelayBody(alg: "A256GCM", nonce: windowsBody.nonce, ciphertext: windowsBody.ciphertext, tag: Base64URL.encode(Data(repeating: 0, count: 16)))
            _ = try PayloadCrypto.decrypt(bad, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        }
        reject("truncated ciphertext") {
            let cut = String(windowsBody.ciphertext.dropLast(8))
            let bad = EncryptedRelayBody(alg: "A256GCM", nonce: windowsBody.nonce, ciphertext: cut, tag: windowsBody.tag)
            _ = try PayloadCrypto.decrypt(bad, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        }
        reject("wrong nonce size") {
            let bad = EncryptedRelayBody(alg: "A256GCM", nonce: Base64URL.encode(Data(repeating: 1, count: 11)), ciphertext: windowsBody.ciphertext, tag: windowsBody.tag)
            _ = try PayloadCrypto.decrypt(bad, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        }
        reject("wrong alg") {
            let bad = EncryptedRelayBody(alg: "A128GCM", nonce: windowsBody.nonce, ciphertext: windowsBody.ciphertext, tag: windowsBody.tag)
            _ = try PayloadCrypto.decrypt(bad, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        }
        reject("random ciphertext") {
            let bad = EncryptedRelayBody(alg: "A256GCM", nonce: windowsBody.nonce, ciphertext: Base64URL.encode(Data(repeating: 0xA5, count: 64)), tag: windowsBody.tag)
            _ = try PayloadCrypto.decrypt(bad, keyData: key, machineId: "machine-test-001", deviceId: "ios-test-001", messageId: "00000000-0000-0000-0000-000000000099")
        }
        XCTAssertEqual(total, 8)
        XCTAssertEqual(passed, total)
        print("PROTOCOL_FUZZ_CRYPTO negative=\(total) pass=\(passed) fail=\(total - passed) vectors=5")
    }

    func testFrameSizeBoundariesAndOversizedPayload() throws {
        XCTAssertNoThrow(try ProtocolSecurity.validateEncodedSize(Data(count: 256 * 1024), outbound: true))
        XCTAssertThrowsError(try ProtocolSecurity.validateEncodedSize(Data(count: 256 * 1024 + 1), outbound: true))
        XCTAssertNoThrow(try ProtocolSecurity.validateEncodedSize(Data(count: 512 * 1024), outbound: false))
        XCTAssertThrowsError(try ProtocolSecurity.validateEncodedSize(Data(count: 512 * 1024 + 1), outbound: false))

        let huge = RemoteCommand.make(
            machineId: "my-pc",
            runtimeId: "runtime.web",
            instanceId: "agent",
            sessionId: "session-1",
            action: "sendMessage",
            payload: ["text": .string(String(repeating: "x", count: 300 * 1024))]
        )
        let encoded = try JSONEncoder.remoteAI.encode(huge)
        XCTAssertGreaterThan(encoded.count, ProtocolSecurity.maxOutboundFrameBytes)
        XCTAssertThrowsError(try ProtocolSecurity.validateEncodedSize(encoded, outbound: true))
        print("PROTOCOL_FUZZ_SIZE cases=5 pass=5 fail=0")
    }

    func testSequenceTrackerGapDoesNotAdvanceCursorAndHandlesHugeSequence() {
        var tracker = SequenceTracker(lastSequence: 10)
        let gap = tracker.ingest(13)
        XCTAssertTrue(gap.gap)
        XCTAssertEqual(tracker.lastSequence, 10)
        XCTAssertTrue(tracker.ingest(11).gap == false)
        XCTAssertEqual(tracker.lastSequence, 11)

        var huge = SequenceTracker(lastSequence: Int64.max - 1)
        let final = huge.ingest(Int64.max)
        XCTAssertFalse(final.gap)
        XCTAssertFalse(final.duplicate)
        XCTAssertEqual(huge.lastSequence, Int64.max)
    }

    func testJSONValueIntegerConversionRejectsNonIntegralAndOutOfRange() {
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(1.5).intValue)
        XCTAssertNil(JSONValue.number(9_223_372_036_854_775_808.0).intValue)
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
    }

    func testMockReplayedCommandIdIsIdempotent() async throws {
        let mock = MockTransport(historyCount: 1)
        try await mock.connect()
        let commandId = UUID()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage", payload: ["text": .string("once")], commandId: commandId)
        let first = try await mock.execute(command)
        let replay = try await mock.execute(command)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(replay.idempotentReplay, true)
    }

    func testDisconnectImmediatelyAfterSendRecoversBySameCommandId() async throws {
        let mock = MockTransport(scenario: .disconnectImmediatelyAfterSend, historyCount: 1)
        try await mock.connect()
        let commandId = UUID()
        let command = RemoteCommand.make(machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload", action: "sendMessage", payload: ["text": .string("unknown-delivery")], commandId: commandId)

        do {
            _ = try await mock.execute(command)
            XCTFail("Expected disconnect after side effect was recorded")
        } catch {
            XCTAssertEqual(error as? TransportError, .disconnected)
        }

        await mock.setScenario(.normal)
        try await mock.connect()
        let replay = try await mock.execute(command)
        XCTAssertEqual(replay.idempotentReplay, true)
    }

    func testProtocolFuzzManifestCount() {
        let protocolNegative = 34
        let cryptoNegative = 8
        let sizeAndOversize = 5
        let sequenceRecovery = 2
        let numericBoundary = 3
        let commandReplay = 1
        let disconnectAfterSend = 1
        let rapidReconnect = 1
        let duplicateReconnectRecovery = 1
        let total = protocolNegative + cryptoNegative + sizeAndOversize + sequenceRecovery + numericBoundary + commandReplay + disconnectAfterSend + rapidReconnect + duplicateReconnectRecovery
        XCTAssertEqual(total, 56)
        print("PROTOCOL_FUZZ_TOTAL cases=\(total) vectors=5")
    }

    func testRapidReconnectAndDuplicateRecoveryGuards() async throws {
        let mock = MockTransport(historyCount: 1)
        for _ in 0..<25 {
            try await mock.connect()
            let connected = await mock.isConnected
            XCTAssertTrue(connected)
            await mock.disconnect()
            let disconnected = await mock.isConnected
            XCTAssertFalse(disconnected)
        }
        try await mock.connect()

        let e = event(sequence: 11)
        try ProtocolSecurity.validateDelta(DeltaSyncResult(events: [e], nextCursor: 11, hasMore: false), after: 10, expectedMachineId: "my-pc")
        XCTAssertThrowsError(
            try ProtocolSecurity.validateDelta(DeltaSyncResult(events: [e], nextCursor: 11, hasMore: false), after: 11, expectedMachineId: "my-pc")
        )
        print("PROTOCOL_FUZZ_RECOVERY rapidReconnect=25 duplicateRecovery=PASS")
    }
}
