import Foundation

enum RuntimeKind: String, Codable, CaseIterable, Identifiable {
    case web = "Web"
    case codex = "Codex"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum MachineConnectionState: String, Codable { case online = "Online", offline = "Offline", connecting = "Connecting" }

enum ConnectionDiagnosticPhase: String, Codable, Equatable {
    case idle
    case relayConnecting
    case relayConnected
    case authenticating
    case loadingRuntimes
    case online
    case reconnecting
    case windowsReconnecting
    case windowsOffline
    case pairingExpired
    case relayError
    case timedOut

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .relayConnecting: return "Relay connecting"
        case .relayConnected: return "Relay connected"
        case .authenticating: return "Authenticating"
        case .loadingRuntimes: return "Loading runtimes"
        case .online: return "Online"
        case .reconnecting: return "Relay reconnecting"
        case .windowsReconnecting: return "Windows Agent reconnecting"
        case .windowsOffline: return "Windows Agent offline"
        case .pairingExpired: return "Pairing expired"
        case .relayError: return "Relay error"
        case .timedOut: return "Connection timed out"
        }
    }
}
enum SessionState: String, Codable { case idle = "Idle", busy = "Busy", waiting = "Waiting", sleeping = "Sleeping", error = "Error" }
enum CommandState: String, Codable { case pending = "Pending", acknowledged = "Acknowledged", executing = "Executing", completed = "Completed", failed = "Failed", unknown = "Unknown" }
enum WebState: String, Codable { case registered = "Registered", browserClosed = "BrowserClosed", attached = "Attached", unsupported = "Unsupported" }
enum MessageRole: String, Codable { case user, assistant, system, tool }
enum MessageKind: String, Codable { case text, toolEvent, error }

struct MachineMetadata: Codable, Identifiable, Hashable { let id: String; var name: String; var state: MachineConnectionState }
struct RuntimeDescriptor: Codable, Identifiable, Hashable { let id: String; let machineId: String; let kind: RuntimeKind; let name: String; var status: String? = nil }
struct InstanceDescriptor: Codable, Identifiable, Hashable {
    let id: String
    let runtimeId: String
    let name: String
    let subtitle: String?
    var status: String? = nil
    var config: [String: JSONValue] = [:]
}

struct CodexModelOption: Codable, Identifiable, Hashable {
    let id: String
    let label: String
}

struct CodexCatalog: Codable, Hashable {
    let models: [CodexModelOption]
    let defaultModel: String?
}

extension InstanceDescriptor {
    var codexCatalog: CodexCatalog? {
        try? config["codexCatalog"]?.decode(CodexCatalog.self)
    }

    var configuredModel: String? {
        config["model"]?.stringValue
    }
}
struct SessionDescriptor: Codable, Identifiable, Hashable {
    let id: String
    let instanceId: String
    var title: String
    var state: SessionState
    var updatedAt: Date
    var projectAlias: String? = nil
    var canonicalUrl: String? = nil
    var lastActivityAt: Date? = nil
    var lastProgressStatus: String? = nil
    var lastProgressAt: Date? = nil

    var orderingDate: Date { max(updatedAt, lastActivityAt ?? updatedAt) }
}

struct AttachmentTransferProgress: Equatable {
    let completed: Int
    let total: Int
    let name: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct PendingAttachment: Identifiable, Hashable {
    let id: UUID
    let name: String
    let contentType: String
    let data: Data

    init(id: UUID = UUID(), name: String, contentType: String, data: Data) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.data = data
    }

    var sizeBytes: Int { data.count }
}

struct AttachmentUploadTicket: Codable, Hashable {
    let uploadId: String
    let chunkBytes: Int
    let maxAttachmentBytes: Int
}

struct RemoteAttachmentDescriptor: Codable, Identifiable, Hashable {
    var id: String { attachmentId }
    let attachmentId: String
    let name: String
    let contentType: String
    let sizeBytes: Int
    let sha256: String
}

struct DownloadedMessageAttachment: Hashable {
    let attachmentId: String
    let name: String
    let contentType: String
    let data: Data
}

struct MessageAttachmentChunk: Codable, Hashable {
    let attachmentId: String
    let name: String
    let contentType: String
    let sizeBytes: Int
    let sha256: String?
    let index: Int
    let chunkBytes: Int
    let dataBase64: String
    let hasMore: Bool
}

struct MessageAttachment: Codable, Identifiable, Hashable {
    let attachmentId: String?
    let name: String
    let contentType: String?
    let sizeBytes: Int?
    let previewURL: String?
    let downloadURL: String?

    var id: String {
        attachmentId ?? "\(name)|\(previewURL ?? downloadURL ?? "")"
    }

    var isImage: Bool {
        if contentType?.lowercased().hasPrefix("image/") == true { return true }
        let lower = name.lowercased()
        return [".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic"].contains { lower.hasSuffix($0) }
    }
}

struct WebProjectDescriptor: Codable, Identifiable, Hashable {
    var id: String { projectAlias }
    let projectAlias: String
    let projectId: String?
    let displayName: String
    let canonicalUrl: String
    let lastSeenAt: Date?
    let lastOpenedAt: Date?
}

struct WebConversationDescriptor: Codable, Identifiable, Hashable {
    var id: String { localConversationId }
    let localConversationId: String
    let canonicalUrl: String
    let projectId: String?
    let displayTitle: String
    let projectAlias: String?
    let conversationAlias: String?
    let lastVisited: Date?
    let updatedAt: Date

    var session: SessionDescriptor {
        SessionDescriptor(
            id: localConversationId,
            instanceId: "web.chatgpt",
            title: displayTitle,
            state: .idle,
            updatedAt: updatedAt,
            projectAlias: projectAlias,
            canonicalUrl: canonicalUrl,
            lastActivityAt: lastVisited
        )
    }
}

enum WebSnapshotState: String, Codable, Hashable {
    case authoritativeLiveDOM = "authoritative-live-dom"
    case partialDOM = "partial-dom"
    case staleCache = "stale-cache"
    case providerUnavailable = "provider-unavailable"
    case localConfirmed = "local-confirmed"
}

struct WebProjectListResponse: Codable {
    let items: [WebProjectDescriptor]
    let observedAt: Date?
    let source: String?
    let stale: Bool?
    let state: WebSnapshotState?
    let snapshotId: String?
    let unavailable: Bool?

    init(items: [WebProjectDescriptor], observedAt: Date?, source: String? = nil, stale: Bool? = nil, state: WebSnapshotState? = nil, snapshotId: String? = nil, unavailable: Bool? = nil) {
        self.items = items
        self.observedAt = observedAt
        self.source = source
        self.stale = stale
        self.state = state
        self.snapshotId = snapshotId
        self.unavailable = unavailable
    }

    var isAuthoritativeLiveDOM: Bool {
        state == .authoritativeLiveDOM && stale != true
    }
}

struct WebProjectConversationPage: Codable {
    let project: WebProjectDescriptor
    let items: [WebConversationDescriptor]
    let cursor: String?
    let nextCursor: String?
    let hasMore: Bool
    let observedAt: Date?
    let source: String?
    let stale: Bool?
    let state: WebSnapshotState?
    let snapshotId: String?

    init(project: WebProjectDescriptor, items: [WebConversationDescriptor], cursor: String?, nextCursor: String?, hasMore: Bool, observedAt: Date?, source: String? = nil, stale: Bool? = nil, state: WebSnapshotState? = nil, snapshotId: String? = nil) {
        self.project = project
        self.items = items
        self.cursor = cursor
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.observedAt = observedAt
        self.source = source
        self.stale = stale
        self.state = state
        self.snapshotId = snapshotId
    }

    var isAuthoritativeLiveDOM: Bool {
        state == .authoritativeLiveDOM && stale != true
    }
}

struct MessageCursor: Codable, Hashable {
    let createdAt: Date
    let messageId: String
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    let sequence: Int64?
    let role: MessageRole
    let kind: MessageKind
    var text: String
    var toolName: String?
    var toolStatus: String?
    var detail: String?
    var attachments: [MessageAttachment]? = nil
    let createdAt: Date

    var cursor: MessageCursor { MessageCursor(createdAt: createdAt, messageId: id) }

    var resolvedAttachments: [MessageAttachment] {
        if let attachments, !attachments.isEmpty {
            return Self.deduplicatedAttachments(attachments)
        }
        return Self.legacyAttachments(in: text)
    }

    var displayText: String {
        guard !resolvedAttachments.isEmpty else { return text }
        return Self.strippingLegacyAttachmentMarkers(from: text)
    }

    private static func legacyAttachments(in text: String) -> [MessageAttachment] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)\[Attachments:\s*([^\]]+)\]"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var attachments: [MessageAttachment] = []
        for match in matches where match.numberOfRanges > 1 {
            let raw = nsText.substring(with: match.range(at: 1))
            for part in raw.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                attachments.append(MessageAttachment(
                    attachmentId: nil,
                    name: name,
                    contentType: nil,
                    sizeBytes: nil,
                    previewURL: nil,
                    downloadURL: nil
                ))
            }
        }
        return deduplicatedAttachments(attachments)
    }

    private static func strippingLegacyAttachmentMarkers(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)\s*\[Attachments:\s*[^\]]+\]"#) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicatedAttachments(_ attachments: [MessageAttachment]) -> [MessageAttachment] {
        var seen = Set<String>()
        return attachments.filter { attachment in
            let key = "\(attachment.attachmentId ?? "")|\(attachment.name.lowercased())|\(attachment.previewURL ?? "")|\(attachment.downloadURL ?? "")"
            return seen.insert(key).inserted
        }
    }
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
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var intValue: Int64? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= -9_223_372_036_854_775_808.0,
              value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int64(value)
    }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder.remoteAI.encode(self)
        return try JSONDecoder.remoteAI.decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.remoteAI.encode(value)
        return try JSONDecoder.remoteAI.decode(JSONValue.self, from: data)
    }
}

struct RemoteCommand: Codable, Identifiable, Hashable {
    let protocolVersion: Int
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
    let protocolVersion: Int
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

struct DeltaSyncResult: Codable {
    let events: [RemoteEvent]
    let nextCursor: Int64
    let hasMore: Bool
}

struct Page<T: Codable>: Codable {
    let items: [T]
    let beforeCursor: MessageCursor?
    let hasMore: Bool
}

struct SequenceDecision: Equatable { let duplicate: Bool; let gap: Bool }
struct SequenceTracker {
    private(set) var lastSequence: Int64
    init(lastSequence: Int64 = 0) { self.lastSequence = max(0, lastSequence) }
    mutating func ingest(_ sequence: Int64) -> SequenceDecision {
        if sequence <= lastSequence { return .init(duplicate: true, gap: false) }
        if lastSequence > 0 && sequence - lastSequence > 1 {
            return .init(duplicate: false, gap: true)
        }
        lastSequence = sequence
        return .init(duplicate: false, gap: false)
    }
}

struct RelayFrame: Codable {
    let v: Int
    let kind: String
    let machineId: String
    let deviceId: String?
    let messageId: String
    let body: [String: JSONValue]
}

struct EncryptedRelayBody: Codable, Equatable {
    let alg: String
    let nonce: String
    let ciphertext: String
    let tag: String
}

struct RemoteErrorPayload: Codable, Error, Equatable {
    let code: String
    let message: String
    let retryable: Bool?
    let details: [String: JSONValue]?
}

struct CommandResponseEnvelope: Codable {
    let ok: Bool
    let result: JSONValue?
    let error: RemoteErrorPayload?
    let idempotentReplay: Bool?
}

struct DecryptedRelayPayload: Codable {
    let kind: String
    let commandId: String?
    let response: CommandResponseEnvelope?
    let event: RemoteEvent?
    let error: RemoteErrorPayload?
}

struct ServerRuntime: Codable {
    let runtimeId: String
    let kind: String
    let label: String
    let capabilities: [String]
    let status: String
    let updatedAt: Date
}

struct ServerInstance: Codable {
    let instanceId: String
    let runtimeId: String
    let label: String
    let kind: String
    let config: [String: JSONValue]
    let status: String
    let updatedAt: Date
}

struct ServerSession: Codable {
    let sessionId: String
    let runtimeId: String
    let instanceId: String
    let externalId: String?
    let title: String
    let canonicalUrl: String?
    let status: String
    let metadata: [String: JSONValue]
    let createdAt: Date
    let updatedAt: Date
    let lastVisited: Date?
}

struct ServerMessage: Codable {
    let messageId: String
    let sessionId: String
    let role: String
    let content: String
    let externalId: String?
    var attachments: [MessageAttachment]? = nil
    let createdAt: Date
}

extension SessionState {
    static func server(_ raw: String) -> SessionState {
        switch raw.lowercased() {
        case "idle", "ready", "configured", "detected": return .idle
        case "running", "busy", "generating": return .busy
        case "waiting": return .waiting
        case "sleeping": return .sleeping
        case "interrupted": return .error
        default: return raw.lowercased().contains("error") || raw.lowercased().contains("fail") ? .error : .idle
        }
    }
}

extension ServerRuntime {
    func descriptor(machineId: String) -> RuntimeDescriptor? {
        guard let kind = RuntimeKind(rawValue: kind) else { return nil }
        return RuntimeDescriptor(id: runtimeId, machineId: machineId, kind: kind, name: label, status: status)
    }
}

extension ServerInstance {
    var descriptor: InstanceDescriptor {
        InstanceDescriptor(id: instanceId, runtimeId: runtimeId, name: label, subtitle: kind, status: status, config: config)
    }
}

extension ServerSession {
    var descriptor: SessionDescriptor {
        let persistedActivity = metadata["lastActivityAt"]?.stringValue.flatMap(RemoteAIDate.parse)
        return SessionDescriptor(
            id: sessionId,
            instanceId: instanceId,
            title: title,
            state: .server(status),
            updatedAt: updatedAt,
            projectAlias: metadata["projectAlias"]?.stringValue,
            canonicalUrl: canonicalUrl,
            lastActivityAt: persistedActivity ?? lastVisited,
            lastProgressStatus: metadata["lastProgressStatus"]?.stringValue,
            lastProgressAt: metadata["lastProgressAt"]?.stringValue.flatMap(RemoteAIDate.parse)
        )
    }
}

extension ServerMessage {
    var chatMessage: ChatMessage {
        let mappedRole = MessageRole(rawValue: role.lowercased()) ?? .system
        return ChatMessage(id: messageId, sessionId: sessionId, sequence: nil, role: mappedRole, kind: .text, text: content, toolName: nil, toolStatus: nil, detail: nil, attachments: attachments, createdAt: createdAt)
    }
}
