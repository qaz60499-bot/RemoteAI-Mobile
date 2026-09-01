import Foundation

public enum TransportError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case offline
    case commandFailed(String)
    case invalidPayload
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Transport is not connected."
        case .offline: return "Transport is offline."
        case .commandFailed(let message): return message
        case .invalidPayload: return "The transport payload is invalid."
        case .underlying(let message): return message
        }
    }
}

public protocol Transport: AnyObject {
    func events() async -> AsyncThrowingStream<ProtocolV1.Event, Error>
    func connect() async throws
    func disconnect() async
    func send(_ command: ProtocolV1.Command) async throws
    func currentState() async -> ProtocolV1.TransportState
}
