import Foundation

public enum RuntimeKind: String, Codable, CaseIterable, Sendable {
    case web
    case cloudCode
    case codexRuntime

    public var displayName: String {
        switch self {
        case .web: return "Web"
        case .cloudCode: return "Cloud Code"
        case .codexRuntime: return "Codex Runtime"
        }
    }
}

public enum RuntimeStatus: String, Codable, Sendable {
    case connected
    case reconnecting
    case disconnected
    case offline
}

public struct RuntimeNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var kind: RuntimeKind
    public var status: RuntimeStatus

    public init(id: String, name: String, kind: RuntimeKind, status: RuntimeStatus = .disconnected) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
    }
}

public struct InstanceNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let runtimeID: String
    public var name: String
    public var status: RuntimeStatus

    public init(id: String, runtimeID: String, name: String, status: RuntimeStatus = .disconnected) {
        self.id = id
        self.runtimeID = runtimeID
        self.name = name
        self.status = status
    }
}

public struct SessionSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let instanceID: String
    public var name: String
    public var updatedAt: Date

    public init(id: String, instanceID: String, name: String, updatedAt: Date = Date()) {
        self.id = id
        self.instanceID = instanceID
        self.name = name
        self.updatedAt = updatedAt
    }
}

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public enum ToolState: String, Codable, Sendable {
    case started
    case running
    case completed
    case failed
}

public struct ChatMessage: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public var role: ChatRole
    public var text: String
    public var createdAt: Date
    public var isStreaming: Bool
    public var toolName: String?
    public var toolState: ToolState?

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        role: ChatRole,
        text: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        toolName: String? = nil,
        toolState: ToolState? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.toolName = toolName
        self.toolState = toolState
    }
}

public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public let items: [Element]
    public let hasMore: Bool
    public let nextCursor: String?

    public init(items: [Element], hasMore: Bool, nextCursor: String? = nil) {
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}
