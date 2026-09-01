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
    var webSocketURL: URL {
        var c = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/v1/ws"
        return c.url!
    }
}

protocol Transport: AnyObject {
    var isConnected: Bool { get async }
    func connect() async throws
    func disconnect() async
    func send(_ command: RemoteCommand) async throws -> CommandState
    func eventStream() async -> AsyncStream<RemoteEvent>
    func delta(after sequence: Int64) async throws -> DeltaSyncResult
    func loadRecent(sessionId: String, limit: Int) async throws -> Page<ChatMessage>
    func loadBefore(sessionId: String, before: Int64, limit: Int) async throws -> Page<ChatMessage>
}

enum TransportError: LocalizedError, Equatable {
    case offline, badResponse(Int), malformedData, pairingRequired, disconnected
    var errorDescription: String? {
        switch self { case .offline: return "PC is offline"; case .badResponse(let code): return "Relay returned HTTP \(code)"; case .malformedData: return "Malformed relay data"; case .pairingRequired: return "Pairing is required"; case .disconnected: return "Connection closed" }
    }
}

extension RemoteCommand {
    static func make(machineId: String, runtimeId: String, instanceId: String, sessionId: String? = nil, action: String, payload: [String: JSONValue] = [:], commandId: UUID = UUID()) -> RemoteCommand {
        RemoteCommand(protocolVersion: "1", commandId: commandId, machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: action, payload: payload, createdAt: Date())
    }
}
