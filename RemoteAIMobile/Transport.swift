import Foundation

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
        guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false else { throw TransportError.insecureRelay }
    }

    static func deviceWebSocketURL(baseURL: URL, machineId: String, deviceId: String) throws -> URL {
        try validateSecureRelay(baseURL)
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
        case .remote(let code, let message): return "\(code): \(message)"
        }
    }
}

extension RemoteCommand {
    static func make(machineId: String, runtimeId: String, instanceId: String, sessionId: String? = nil, action: String, payload: [String: JSONValue] = [:], commandId: UUID = UUID()) -> RemoteCommand {
        RemoteCommand(protocolVersion: 1, commandId: commandId, machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: action, payload: payload, createdAt: Date())
    }
}

extension Transport {
    func send(_ command: RemoteCommand) async throws -> CommandState {
        let response = try await execute(command)
        if response.ok { return .completed }
        if let error = response.error { throw TransportError.remote(error.code, error.message) }
        return .failed
    }

    func listRuntimes(machineId: String) async throws -> [RuntimeDescriptor] {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "listRuntimes")
        let response = try await requireSuccess(execute(command))
        let rows = try response.decode([ServerRuntime].self)
        return rows.compactMap { $0.descriptor(machineId: machineId) }
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

    func createSession(machineId: String, runtimeId: String, instanceId: String, payload: [String: JSONValue]) async throws -> SessionDescriptor? {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, action: "createSession", payload: payload)
        let response = try await requireSuccess(execute(command))
        return try? response.decode(ServerSession.self).descriptor
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
        let beforeValue = try JSONValue.encode(before)
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "loadMessagesBefore", payload: ["before": beforeValue, "limit": .number(Double(safeLimit))])
        let response = try await requireSuccess(execute(command))
        let items = try response.decode([ServerMessage].self).map(\.chatMessage)
        return Page(items: items, beforeCursor: items.first?.cursor, hasMore: items.count == safeLimit)
    }

    func delta(machineId: String, after sequence: Int64, limit: Int = 500) async throws -> DeltaSyncResult {
        let safeLimit = max(1, min(limit, 1000))
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "getChangesAfterCursor", payload: [
            "cursor": .number(Double(max(0, sequence))),
            "limit": .number(Double(safeLimit))
        ])
        let response = try await requireSuccess(execute(command))
        return try response.decode(DeltaSyncResult.self)
    }

    private func requireSuccess(_ response: CommandResponseEnvelope) throws -> JSONValue {
        guard response.ok else {
            if let error = response.error { throw TransportError.remote(error.code, error.message) }
            throw TransportError.malformedData
        }
        return response.result ?? .null
    }
}
