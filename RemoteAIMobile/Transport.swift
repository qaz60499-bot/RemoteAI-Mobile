import Foundation
import CryptoKit

struct RemoteAIConfig: Codable, Equatable {
    var relayBaseURL: URL
    var machineId: String

    static let placeholder = RemoteAIConfig(relayBaseURL: URL(string: "https://relay.example.invalid")!, machineId: "my-pc")
    private static let relayKey = "remoteai.relayBaseURL"
    private static let machineKey = "remoteai.machineId"

    static func loadMetadata() -> RemoteAIConfig {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: relayKey), let url = URL(string: raw) else { return .placeholder }
        return RemoteAIConfig(relayBaseURL: url, machineId: defaults.string(forKey: machineKey) ?? "my-pc")
    }

    func saveMetadata() {
        UserDefaults.standard.set(relayBaseURL.absoluteString, forKey: Self.relayKey)
        UserDefaults.standard.set(machineId, forKey: Self.machineKey)
    }

    static func validateSecureRelay(_ baseURL: URL) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host?.isEmpty == false,
              baseURL.user == nil,
              baseURL.password == nil else { throw TransportError.insecureRelay }
    }

    static func deviceWebSocketURL(baseURL: URL, machineId: String, deviceId: String) throws -> URL {
        try validateSecureRelay(baseURL)
        try ProtocolSecurity.validateIdentifier(machineId)
        try ProtocolSecurity.validateIdentifier(deviceId)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.path = "/connect"
        components?.queryItems = [
            URLQueryItem(name: "machineId", value: machineId),
            URLQueryItem(name: "role", value: "device"),
            URLQueryItem(name: "deviceId", value: deviceId)
        ]
        guard let url = components?.url else { throw TransportError.malformedData }
        return url
    }
}

protocol Transport: AnyObject {
    var isConnected: Bool { get async }
    func connect() async throws
    func disconnect() async
    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope
    func eventStream() async -> AsyncStream<RemoteEvent>
}

enum TransportError: LocalizedError, Equatable {
    case offline
    case badResponse(Int)
    case malformedData
    case pairingRequired
    case disconnected
    case timeout
    case insecureRelay
    case frameTooLarge
    case replayDetected
    case remote(String, String)

    var errorDescription: String? {
        switch self {
        case .offline: return "PC is offline"
        case .badResponse(let code): return "Relay returned HTTP \(code)"
        case .malformedData: return "Malformed relay data"
        case .pairingRequired: return "Pairing is required"
        case .disconnected: return "Connection closed"
        case .timeout: return "RemoteAI request timed out"
        case .insecureRelay: return "RemoteAI Relay must use HTTPS/WSS"
        case .frameTooLarge: return "RemoteAI relay frame exceeds the protocol size limit"
        case .replayDetected: return "RemoteAI rejected a replayed relay message"
        case .remote(let code, let message): return "\(code): \(message)"
        }
    }
}

extension RemoteCommand {
    static func make(machineId: String, runtimeId: String, instanceId: String, sessionId: String? = nil, action: String, payload: [String: JSONValue] = [:], commandId: UUID = UUID()) -> RemoteCommand {
        RemoteCommand(protocolVersion: 1, commandId: commandId, machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: action, payload: payload, createdAt: Date())
    }

    /// Stable child command IDs let a multi-step operation be replayed safely after a
    /// timeout/disconnect without creating a second remote side effect.
    static func derivedCommandId(namespace: UUID, label: String) -> UUID {
        let seed = Data((namespace.uuidString.lowercased() + "|" + label).utf8)
        let digest = SHA256.hash(data: seed)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let text = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: text)!
    }
}

extension Transport {
    func send(_ command: RemoteCommand) async throws -> CommandState {
        let response = try await execute(command)
        if response.ok { return .completed }
        if let error = response.error { throw TransportError.remote(error.code, error.message) }
        return .failed
    }

    func latestSequence(machineId: String) async throws -> Int64 {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "getStatus")
        let response = try await requireSuccess(execute(command))
        guard let sequence = response.objectValue?["latestSequence"]?.intValue else { throw TransportError.malformedData }
        return max(0, sequence)
    }

    func listRuntimes(machineId: String) async throws -> [RuntimeDescriptor] {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "listRuntimes")
        let response = try await requireSuccess(execute(command))
        let rows = try response.decode([ServerRuntime].self)
        return rows
            .filter { $0.runtimeId != "runtime.cloudcode" }
            .compactMap { $0.descriptor(machineId: machineId) }
    }

    func listInstances(machineId: String, runtimeId: String) async throws -> [InstanceDescriptor] {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: "agent", action: "listInstances")
        let response = try await requireSuccess(execute(command))
        return try response.decode([ServerInstance].self).map(\.descriptor)
    }

    func listSessions(machineId: String, runtimeId: String, instanceId: String) async throws -> [SessionDescriptor] {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, action: "listSessions")
        let response = try await requireSuccess(execute(command))
        return try response.decode([ServerSession].self).map(\.descriptor)
    }

    func createSession(machineId: String, runtimeId: String, instanceId: String, payload: [String: JSONValue], commandId: UUID = UUID()) async throws -> SessionDescriptor? {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, action: "createSession", payload: payload, commandId: commandId)
        let response = try await requireSuccess(execute(command))
        return try? response.decode(ServerSession.self).descriptor
    }

    func listProjects(machineId: String) async throws -> [WebProjectDescriptor] {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "web.chatgpt", action: "listProjects")
        let response = try await requireSuccess(execute(command))
        return try response.decode(WebProjectListResponse.self).items
    }

    func listProjectConversations(machineId: String, projectAlias: String, limit: Int = 30, cursor: String? = nil) async throws -> WebProjectConversationPage {
        let safeLimit = max(1, min(limit, 50))
        var payload: [String: JSONValue] = [
            "projectAlias": .string(projectAlias),
            "limit": .number(Double(safeLimit))
        ]
        if let cursor, !cursor.isEmpty { payload["cursor"] = .string(cursor) }
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "web.chatgpt", action: "listProjectConversations", payload: payload)
        let response = try await requireSuccess(execute(command))
        return try response.decode(WebProjectConversationPage.self)
    }

    func createWebProject(machineId: String, projectName: String, commandId: UUID = UUID()) async throws -> WebProjectDescriptor {
        let command = RemoteCommand.make(
            machineId: machineId,
            runtimeId: "runtime.web",
            instanceId: "web.chatgpt",
            action: "createProject",
            payload: ["projectName": .string(projectName)],
            commandId: commandId
        )
        let response = try await requireSuccess(execute(command))
        return try response.decode(WebProjectDescriptor.self)
    }

    func createWebConversation(machineId: String, projectAlias: String? = nil, commandId: UUID = UUID()) async throws -> WebConversationDescriptor {
        var payload: [String: JSONValue] = [:]
        if let projectAlias { payload["projectAlias"] = .string(projectAlias) }
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "web.chatgpt", action: "createConversation", payload: payload, commandId: commandId)
        let response = try await requireSuccess(execute(command))
        return try response.decode(WebConversationDescriptor.self)
    }

    func openProject(machineId: String, projectAlias: String) async throws {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "web.chatgpt", action: "openProject", payload: ["projectAlias": .string(projectAlias)])
        _ = try await requireSuccess(execute(command))
    }

    func uploadAttachment(machineId: String, runtimeId: String, instanceId: String, sessionId: String, attachment: PendingAttachment, operationId: UUID = UUID(), attachmentIndex: Int = 0) async throws -> RemoteAttachmentDescriptor {
        let begin = RemoteCommand.make(
            machineId: machineId,
            runtimeId: runtimeId,
            instanceId: instanceId,
            sessionId: sessionId,
            action: "beginAttachmentUpload",
            payload: [
                "name": .string(attachment.name),
                "contentType": .string(attachment.contentType),
                "sizeBytes": .number(Double(attachment.sizeBytes))
            ],
            commandId: RemoteCommand.derivedCommandId(namespace: operationId, label: "attachment:\(attachmentIndex):begin")
        )
        let ticket = try await requireSuccess(execute(begin)).decode(AttachmentUploadTicket.self)
        let chunkSize = max(16 * 1024, min(ticket.chunkBytes, 128 * 1024))
        var index = 0
        var offset = 0
        do {
            while offset < attachment.data.count {
                try Task.checkCancellation()
                let end = min(attachment.data.count, offset + chunkSize)
                let chunk = attachment.data.subdata(in: offset..<end)
                let command = RemoteCommand.make(
                    machineId: machineId,
                    runtimeId: runtimeId,
                    instanceId: instanceId,
                    sessionId: sessionId,
                    action: "uploadAttachmentChunk",
                    payload: [
                        "uploadId": .string(ticket.uploadId),
                        "index": .number(Double(index)),
                        "dataBase64": .string(chunk.base64EncodedString())
                    ],
                    commandId: RemoteCommand.derivedCommandId(namespace: operationId, label: "attachment:\(attachmentIndex):chunk:\(index)")
                )
                _ = try await requireSuccess(execute(command))
                index += 1
                offset = end
            }
            let finish = RemoteCommand.make(
                machineId: machineId,
                runtimeId: runtimeId,
                instanceId: instanceId,
                sessionId: sessionId,
                action: "finishAttachmentUpload",
                payload: ["uploadId": .string(ticket.uploadId)],
                commandId: RemoteCommand.derivedCommandId(namespace: operationId, label: "attachment:\(attachmentIndex):finish")
            )
            return try await requireSuccess(execute(finish)).decode(RemoteAttachmentDescriptor.self)
        } catch {
            let keepForReplay: Bool = {
                guard let transportError = error as? TransportError else { return false }
                return transportError == .timeout || transportError == .disconnected || transportError == .offline
            }()
            if !keepForReplay {
                let discard = RemoteCommand.make(
                    machineId: machineId,
                    runtimeId: runtimeId,
                    instanceId: instanceId,
                    sessionId: sessionId,
                    action: "discardAttachmentUpload",
                    payload: ["uploadId": .string(ticket.uploadId)],
                    commandId: RemoteCommand.derivedCommandId(namespace: operationId, label: "attachment:\(attachmentIndex):discard")
                )
                _ = try? await execute(discard)
            }
            throw error
        }
    }

    func loadRecent(machineId: String, runtimeId: String, instanceId: String, sessionId: String, limit: Int) async throws -> Page<ChatMessage> {
        let safeLimit = max(1, min(limit, 100))
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "loadRecentMessages", payload: ["limit": .number(Double(safeLimit))])
        let response = try await requireSuccess(execute(command))
        let items = try response.decode([ServerMessage].self).map(\.chatMessage)
        return Page(items: items, beforeCursor: items.first?.cursor, hasMore: items.count == safeLimit)
    }

    func loadBefore(machineId: String, runtimeId: String, instanceId: String, sessionId: String, before: MessageCursor, limit: Int) async throws -> Page<ChatMessage> {
        let safeLimit = max(1, min(limit, 100))
        try ProtocolSecurity.validateCursor(before)
        let beforeValue = try JSONValue.encode(before)
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "loadMessagesBefore", payload: ["before": beforeValue, "limit": .number(Double(safeLimit))])
        let response = try await requireSuccess(execute(command))
        let items = try response.decode([ServerMessage].self).map(\.chatMessage)
        return Page(items: items, beforeCursor: items.first?.cursor, hasMore: items.count == safeLimit)
    }

    func delta(machineId: String, after sequence: Int64, limit: Int = 100) async throws -> DeltaSyncResult {
        let safeLimit = max(1, min(limit, 1000))
        let safeCursor = max(0, sequence)
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "getChangesAfterCursor", payload: [
            "cursor": .number(Double(safeCursor)),
            "limit": .number(Double(safeLimit))
        ])
        let response = try await requireSuccess(execute(command))
        return try ProtocolSecurity.decodeDelta(response, after: safeCursor, expectedMachineId: machineId)
    }

    private func requireSuccess(_ response: CommandResponseEnvelope) throws -> JSONValue {
        guard response.ok else {
            if let error = response.error { throw TransportError.remote(error.code, error.message) }
            throw TransportError.malformedData
        }
        return response.result ?? .null
    }
}
