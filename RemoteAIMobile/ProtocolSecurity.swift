import Foundation

enum ProtocolSecurity {
    static let maxIdentifierBytes = 160
    static let maxOutboundFrameBytes = 256 * 1024
    static let maxInboundFrameBytes = 512 * 1024

    static let relayKinds: Set<String> = [
        "PAIR_REQUEST", "PAIR_CHALLENGE", "PAIR_PROOF", "PAIR_ACCEPT",
        "ENCRYPTED", "ACK", "PING", "PONG"
    ]

    static let eventTypes: Set<String> = [
        "COMMAND_RESULT", "COMMAND_REJECTED", "SYSTEM_STATUS", "RUNTIME_STATUS",
        "INSTANCE_UPDATED", "SESSION_CREATED", "SESSION_UPDATED", "SESSION_RENAMED", "SESSION_STATUS",
        "MESSAGE_ADDED", "MESSAGE_UPDATED", "GENERATION_STARTED", "GENERATION_STOPPED",
        "TOOL_STARTED", "TOOL_FINISHED", "WEB_PAGE_REGISTERED", "WEB_PAGE_UNREGISTERED", "WEB_CONVERSATION_CREATED",
        "WEB_BINDING_CHANGED", "WEB_SELECTOR_DEGRADED", "PAIRING_REQUESTED", "DEVICE_PAIRED",
        "DEVICE_REJECTED", "TRANSPORT_STATUS"
    ]

    static let commandActions: Set<String> = [
        "getStatus", "listRuntimes", "listInstances", "listSessions",
        "createSession", "resumeSession", "stopSession", "getSessionStatus",
        "sendMessage", "stopGeneration", "loadRecentMessages", "loadMessagesBefore",
        "getChangesAfterCursor",
        "registerCurrentPage", "unregisterConversation", "openConversation", "focusConversation", "createConversation",
        "listProjects", "listProjectConversations", "openProject", "createProject",
        "beginAttachmentUpload", "uploadAttachmentChunk", "finishAttachmentUpload", "discardAttachmentUpload"
    ]

    private static let commandKeys: Set<String> = [
        "protocolVersion", "commandId", "machineId", "runtimeId", "instanceId", "sessionId", "action", "payload", "createdAt"
    ]
    private static let requiredCommandKeys: Set<String> = [
        "protocolVersion", "commandId", "machineId", "runtimeId", "instanceId", "action", "payload", "createdAt"
    ]
    private static let eventKeys: Set<String> = [
        "protocolVersion", "eventId", "sequence", "machineId", "runtimeId", "instanceId", "sessionId", "type", "payload", "createdAt"
    ]
    private static let relayFrameKeys: Set<String> = ["v", "kind", "machineId", "deviceId", "messageId", "body"]
    private static let encryptedBodyKeys: Set<String> = ["alg", "nonce", "ciphertext", "tag"]
    private static let decryptedPayloadKeys: Set<String> = ["kind", "commandId", "response", "event", "error"]
    private static let commandResponseKeys: Set<String> = ["ok", "result", "error", "idempotentReplay"]
    private static let errorKeys: Set<String> = ["code", "message", "retryable", "details"]
    private static let errorCodes: Set<String> = [
        "INVALID_COMMAND", "UNAUTHORIZED_DEVICE", "UNKNOWN_RUNTIME", "UNKNOWN_INSTANCE", "UNKNOWN_SESSION",
        "CAPABILITY_DENIED", "ALREADY_EXECUTED", "BROWSER_NOT_CONNECTED", "BROWSER_BINDING_MISSING",
        "WEB_SELECTOR_FAILED", "PROVIDER_RATE_LIMITED", "PROVIDER_UNAVAILABLE", "SESSION_UNAVAILABLE", "PAGINATION_CURSOR_INVALID",
        "TRANSPORT_OFFLINE", "INTERNAL_ERROR"
    ]
    private static let deltaKeys: Set<String> = ["events", "nextCursor", "hasMore"]

    static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maxIdentifierBytes else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122: return true // - . 0-9 : A-Z _ a-z
            default: return false
            }
        }
    }

    static func validateIdentifier(_ value: String) throws {
        guard isValidIdentifier(value) else { throw TransportError.malformedData }
    }

    static func validateOptionalIdentifier(_ value: String?) throws {
        if let value { try validateIdentifier(value) }
    }

    static func validatePairingCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 8 && bytes.allSatisfy { (48...57).contains($0) }
    }

    static func validatedPairingMachineKey(challengeKey: String, acceptedKey: String?) throws -> String {
        _ = try PayloadCrypto.parseX25519SPKI(challengeKey)
        if let acceptedKey, acceptedKey != challengeKey { throw TransportError.malformedData }
        return challengeKey
    }

    static func validate(_ command: RemoteCommand, expectedMachineId: String? = nil) throws {
        guard command.protocolVersion == 1,
              commandActions.contains(command.action),
              expectedMachineId == nil || command.machineId == expectedMachineId else {
            throw TransportError.malformedData
        }
        try validateIdentifier(command.commandId.uuidString)
        try validateIdentifier(command.machineId)
        try validateIdentifier(command.runtimeId)
        try validateIdentifier(command.instanceId)
        try validateOptionalIdentifier(command.sessionId)
    }

    static func validate(_ event: RemoteEvent, expectedMachineId: String? = nil) throws {
        guard event.protocolVersion == 1,
              event.sequence > 0,
              eventTypes.contains(event.type),
              expectedMachineId == nil || event.machineId == expectedMachineId else {
            throw TransportError.malformedData
        }
        try validateIdentifier(event.eventId.uuidString)
        try validateIdentifier(event.machineId)
        try validateIdentifier(event.runtimeId)
        try validateIdentifier(event.instanceId)
        try validateOptionalIdentifier(event.sessionId)
    }

    static func validate(_ frame: RelayFrame, expectedMachineId: String? = nil, expectedDeviceId: String? = nil) throws {
        guard frame.v == 1,
              relayKinds.contains(frame.kind),
              expectedMachineId == nil || frame.machineId == expectedMachineId else {
            throw TransportError.malformedData
        }
        try validateIdentifier(frame.machineId)
        try validateOptionalIdentifier(frame.deviceId)
        try validateIdentifier(frame.messageId)
        if let expectedDeviceId {
            guard frame.deviceId == expectedDeviceId else { throw TransportError.malformedData }
        }
        if frame.kind == "ENCRYPTED" {
            guard frame.deviceId != nil else { throw TransportError.malformedData }
            _ = try JSONValue.object(frame.body).decode(EncryptedRelayBody.self)
        }
    }

    static func decodeCommand(_ data: Data) throws -> RemoteCommand {
        let object = try objectDictionary(data)
        try requireKeys(object, allowed: commandKeys, required: requiredCommandKeys)
        let command = try JSONDecoder.remoteAI.decode(RemoteCommand.self, from: data)
        try validate(command)
        return command
    }

    static func decodeEvent(_ data: Data, expectedMachineId: String? = nil) throws -> RemoteEvent {
        let object = try objectDictionary(data)
        try requireKeys(object, allowed: eventKeys, required: eventKeys)
        let event = try JSONDecoder.remoteAI.decode(RemoteEvent.self, from: data)
        try validate(event, expectedMachineId: expectedMachineId)
        return event
    }

    static func decodeRelayFrame(_ data: Data, maxBytes: Int = maxInboundFrameBytes) throws -> RelayFrame {
        guard data.count <= maxBytes else { throw TransportError.frameTooLarge }
        let object = try objectDictionary(data)
        try requireKeys(object, allowed: relayFrameKeys, required: relayFrameKeys)
        guard let body = object["body"] as? [String: Any] else { throw TransportError.malformedData }
        if object["kind"] as? String == "ENCRYPTED" {
            try requireKeys(body, allowed: encryptedBodyKeys, required: encryptedBodyKeys)
        }
        let frame = try JSONDecoder.remoteAI.decode(RelayFrame.self, from: data)
        try validate(frame)
        return frame
    }

    static func decodeDecryptedPayload(_ data: Data, expectedMachineId: String) throws -> DecryptedRelayPayload {
        guard data.count <= maxInboundFrameBytes else { throw TransportError.frameTooLarge }
        let object = try objectDictionary(data)
        try requireKeys(object, allowed: decryptedPayloadKeys, required: ["kind"])

        guard let kind = object["kind"] as? String else { throw TransportError.malformedData }

        switch kind {
        case "event":
            try requireKeys(object, allowed: ["kind", "event"], required: ["kind", "event"])
            guard let rawEvent = object["event"] as? [String: Any] else { throw TransportError.malformedData }
            try requireKeys(rawEvent, allowed: eventKeys, required: eventKeys)
        case "commandResponse":
            try requireKeys(object, allowed: ["kind", "commandId", "response", "event"], required: ["kind", "commandId", "response"])
            guard let commandId = object["commandId"] as? String,
                  UUID(uuidString: commandId) != nil,
                  let response = object["response"] as? [String: Any] else { throw TransportError.malformedData }
            try requireKeys(response, allowed: commandResponseKeys, required: ["ok"])
            guard response["ok"] is Bool else { throw TransportError.malformedData }
            if let rawError = response["error"] as? [String: Any] {
                try validateErrorObject(rawError)
            } else if let rawError = response["error"], !(rawError is NSNull) {
                throw TransportError.malformedData
            }
            if let rawEvent = object["event"] as? [String: Any] {
                try requireKeys(rawEvent, allowed: eventKeys, required: eventKeys)
            } else if let rawEvent = object["event"], !(rawEvent is NSNull) {
                throw TransportError.malformedData
            }
        case "error":
            try requireKeys(object, allowed: ["kind", "error"], required: ["kind", "error"])
            guard let rawError = object["error"] as? [String: Any] else { throw TransportError.malformedData }
            try validateErrorObject(rawError)
        default:
            throw TransportError.malformedData
        }

        let payload = try JSONDecoder.remoteAI.decode(DecryptedRelayPayload.self, from: data)
        if let event = payload.event { try validate(event, expectedMachineId: expectedMachineId) }
        return payload
    }

    static func decodeDelta(_ value: JSONValue, after cursor: Int64, expectedMachineId: String) throws -> DeltaSyncResult {
        guard cursor >= 0, value.objectValue != nil else { throw TransportError.malformedData }
        let rawData = try JSONEncoder.remoteAI.encode(value)
        let rawObject = try objectDictionary(rawData)
        try requireKeys(rawObject, allowed: deltaKeys, required: deltaKeys)
        if let rawEvents = rawObject["events"] as? [[String: Any]] {
            for rawEvent in rawEvents { try requireKeys(rawEvent, allowed: eventKeys, required: eventKeys) }
        } else {
            throw TransportError.malformedData
        }
        let result = try value.decode(DeltaSyncResult.self)
        try validateDelta(result, after: cursor, expectedMachineId: expectedMachineId)
        return result
    }

    static func validateDelta(_ result: DeltaSyncResult, after cursor: Int64, expectedMachineId: String) throws {
        guard cursor >= 0, result.nextCursor >= cursor else { throw TransportError.malformedData }
        var previous = cursor
        var eventIds = Set<UUID>()
        var sequences = Set<Int64>()

        for event in result.events {
            try validate(event, expectedMachineId: expectedMachineId)
            guard event.sequence > cursor,
                  event.sequence > previous,
                  eventIds.insert(event.eventId).inserted,
                  sequences.insert(event.sequence).inserted else {
                throw TransportError.malformedData
            }
            if cursor > 0 && previous == cursor && event.sequence != cursor + 1 {
                throw TransportError.malformedData
            }
            if previous > cursor && event.sequence != previous + 1 {
                throw TransportError.malformedData
            }
            previous = event.sequence
        }

        let expectedCursor = result.events.last?.sequence ?? cursor
        guard result.nextCursor == expectedCursor else { throw TransportError.malformedData }
        if result.hasMore && result.events.isEmpty { throw TransportError.malformedData }
    }

    static func validateCursor(_ cursor: MessageCursor) throws {
        try validateIdentifier(cursor.messageId)
        guard cursor.createdAt.timeIntervalSince1970.isFinite else { throw TransportError.malformedData }
    }

    static func validateEncodedSize(_ data: Data, outbound: Bool) throws {
        let limit = outbound ? maxOutboundFrameBytes : maxInboundFrameBytes
        guard data.count <= limit else { throw TransportError.frameTooLarge }
    }

    private static func validateErrorObject(_ object: [String: Any]) throws {
        try requireKeys(object, allowed: errorKeys, required: ["code", "message"])
        guard let code = object["code"] as? String,
              errorCodes.contains(code),
              object["message"] is String else { throw TransportError.malformedData }
        if let retryable = object["retryable"], !(retryable is Bool) { throw TransportError.malformedData }
        if let details = object["details"], !(details is NSNull), !(details is [String: Any]) { throw TransportError.malformedData }
    }

    private static func objectDictionary(_ data: Data) throws -> [String: Any] {
        do {
            let raw = try JSONSerialization.jsonObject(with: data, options: [])
            guard let object = raw as? [String: Any] else { throw TransportError.malformedData }
            return object
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.malformedData
        }
    }

    private static func requireKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String>) throws {
        let keys = Set(object.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else { throw TransportError.malformedData }
    }
}

struct BoundedReplayGuard {
    private let capacity: Int
    private var seen: Set<String> = []
    private var order: [String] = []

    init(capacity: Int = 4096) {
        self.capacity = max(1, capacity)
    }

    mutating func accept(_ identifier: String) -> Bool {
        guard !seen.contains(identifier) else { return false }
        seen.insert(identifier)
        order.append(identifier)
        if order.count > capacity {
            let overflow = order.count - capacity
            let evicted = Array(order.prefix(overflow))
            order.removeFirst(overflow)
            for value in evicted { seen.remove(value) }
        }
        return true
    }
}
