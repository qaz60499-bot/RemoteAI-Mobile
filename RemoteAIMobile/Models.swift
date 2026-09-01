import Foundation

enum RuntimeKind: String, Codable, CaseIterable, Identifiable { case web = "Web", cloudCode = "Cloud Code", codex = "Codex"; var id: String { rawValue } }
enum MachineConnectionState: String, Codable { case online = "Online", offline = "Offline", connecting = "Connecting" }
enum SessionState: String, Codable { case idle = "Idle", busy = "Busy", waiting = "Waiting", sleeping = "Sleeping", error = "Error" }
enum CommandState: String, Codable { case pending = "Pending", acknowledged = "Acknowledged", executing = "Executing", completed = "Completed", failed = "Failed", unknown = "Unknown" }
enum WebState: String, Codable { case registered = "Registered", browserClosed = "BrowserClosed", attached = "Attached", unsupported = "Unsupported" }
enum MessageRole: String, Codable { case user, assistant, system, tool }
enum MessageKind: String, Codable { case text, toolEvent, error }

struct MachineMetadata: Codable, Identifiable, Hashable { let id: String; var name: String; var state: MachineConnectionState }
struct RuntimeDescriptor: Codable, Identifiable, Hashable { let id: String; let machineId: String; let kind: RuntimeKind; let name: String }
struct InstanceDescriptor: Codable, Identifiable, Hashable { let id: String; let runtimeId: String; let name: String; let subtitle: String? }
struct SessionDescriptor: Codable, Identifiable, Hashable { let id: String; let instanceId: String; var title: String; var state: SessionState; var updatedAt: Date }

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    let sequence: Int64
    let role: MessageRole
    let kind: MessageKind
    var text: String
    var toolName: String?
    var toolStatus: String?
    var detail: String?
    let createdAt: Date
}

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}

struct RemoteCommand: Codable, Identifiable, Hashable {
    let protocolVersion: String
    let commandId: UUID
    let machineId: String
    let runtimeId: String
    let instanceId: String
    let sessionId: String?
    let action: String
    let payload: [String: JSONValue]
    let createdAt: Date
    var id: UUID { commandId }
}

struct RemoteEvent: Codable, Identifiable, Hashable {
    let protocolVersion: String
    let eventId: UUID
    let sequence: Int64
    let machineId: String
    let runtimeId: String
    let instanceId: String
    let sessionId: String?
    let type: String
    let payload: [String: JSONValue]
    let createdAt: Date
    var id: UUID { eventId }
}

struct DeltaSyncResult: Codable { let events: [RemoteEvent]; let latestSequence: Int64 }
struct Page<T: Codable>: Codable { let items: [T]; let beforeCursor: Int64?; let hasMore: Bool }

struct SequenceDecision: Equatable { let duplicate: Bool; let gap: Bool }
struct SequenceTracker {
    private(set) var lastSequence: Int64
    init(lastSequence: Int64 = 0) { self.lastSequence = lastSequence }
    mutating func ingest(_ sequence: Int64) -> SequenceDecision {
        if sequence <= lastSequence { return .init(duplicate: true, gap: false) }
        let gap = lastSequence > 0 && sequence > lastSequence + 1
        lastSequence = sequence
        return .init(duplicate: false, gap: gap)
    }
}
