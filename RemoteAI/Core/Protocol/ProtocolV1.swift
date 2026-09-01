import Foundation

public enum ProtocolV1 {
    public static let version = "protocol-v1"

    public enum CommandType: String, Codable, Sendable {
        case sync
        case createSession
        case sendMessage
        case retry
        case stop
    }

    public struct Command: Codable, Equatable, Identifiable, Sendable {
        public let protocolVersion: String
        public let commandId: String
        public let type: CommandType
        public let runtimeID: String?
        public let instanceID: String?
        public let sessionID: String?
        public let messageID: String?
        public let text: String?
        public let cursor: String?
        public let limit: Int?
        public let title: String?

        public var id: String { commandId }

        public init(
            commandId: String = UUID().uuidString,
            type: CommandType,
            runtimeID: String? = nil,
            instanceID: String? = nil,
            sessionID: String? = nil,
            messageID: String? = nil,
            text: String? = nil,
            cursor: String? = nil,
            limit: Int? = nil,
            title: String? = nil,
            protocolVersion: String = ProtocolV1.version
        ) {
            self.protocolVersion = protocolVersion
            self.commandId = commandId
            self.type = type
            self.runtimeID = runtimeID
            self.instanceID = instanceID
            self.sessionID = sessionID
            self.messageID = messageID
            self.text = text
            self.cursor = cursor
            self.limit = limit
            self.title = title
        }

        public static func sync(
            commandId: String = UUID().uuidString,
            runtimeID: String,
            sessionID: String? = nil,
            cursor: String? = nil,
            limit: Int = 50
        ) -> Command {
            Command(commandId: commandId, type: .sync, runtimeID: runtimeID, sessionID: sessionID, cursor: cursor, limit: limit)
        }

        public static func createSession(
            commandId: String = UUID().uuidString,
            runtimeID: String,
            instanceID: String,
            title: String
        ) -> Command {
            Command(commandId: commandId, type: .createSession, runtimeID: runtimeID, instanceID: instanceID, title: title)
        }

        public static func sendMessage(
            commandId: String = UUID().uuidString,
            runtimeID: String,
            sessionID: String,
            text: String
        ) -> Command {
            Command(commandId: commandId, type: .sendMessage, runtimeID: runtimeID, sessionID: sessionID, text: text)
        }
    }

    public enum EventType: String, Codable, Sendable {
        case runtimeSnapshot
        case instanceSnapshot
        case sessionSnapshot
        case historyPage
        case messageStarted
        case messageDelta
        case messageCompleted
        case toolStarted
        case toolOutput
        case toolCompleted
        case commandAccepted
        case commandRejected
        case syncCompleted
        case error
        case transportState
    }

    public enum TransportState: String, Codable, Sendable {
        case connecting
        case connected
        case reconnecting
        case disconnected
        case offline
    }

    public struct EventBody: Codable, Equatable, Sendable {
        public var text: String?
        public var role: ChatRole?
        public var toolName: String?
        public var toolInput: String?
        public var toolOutput: String?
        public var toolState: ToolState?
        public var message: ChatMessage?
        public var items: [ChatMessage]?
        public var runtime: RuntimeNode?
        public var instance: InstanceNode?
        public var session: SessionSummary?
        public var state: TransportState?
        public var errorCode: String?
        public var errorMessage: String?
        public var expectedSequence: Int64?
        public var receivedSequence: Int64?
        public var nextCursor: String?
        public var hasMore: Bool?

        public init(
            text: String? = nil,
            role: ChatRole? = nil,
            toolName: String? = nil,
            toolInput: String? = nil,
            toolOutput: String? = nil,
            toolState: ToolState? = nil,
            message: ChatMessage? = nil,
            items: [ChatMessage]? = nil,
            runtime: RuntimeNode? = nil,
            instance: InstanceNode? = nil,
            session: SessionSummary? = nil,
            state: TransportState? = nil,
            errorCode: String? = nil,
            errorMessage: String? = nil,
            expectedSequence: Int64? = nil,
            receivedSequence: Int64? = nil,
            nextCursor: String? = nil,
            hasMore: Bool? = nil
        ) {
            self.text = text
            self.role = role
            self.toolName = toolName
            self.toolInput = toolInput
            self.toolOutput = toolOutput
            self.toolState = toolState
            self.message = message
            self.items = items
            self.runtime = runtime
            self.instance = instance
            self.session = session
            self.state = state
            self.errorCode = errorCode
            self.errorMessage = errorMessage
            self.expectedSequence = expectedSequence
            self.receivedSequence = receivedSequence
            self.nextCursor = nextCursor
            self.hasMore = hasMore
        }
    }

    public struct Event: Codable, Equatable, Identifiable, Sendable {
        public let protocolVersion: String
        public let eventId: String
        public let sequence: Int64
        public let type: EventType
        public let commandId: String?
        public let runtimeID: String?
        public let instanceID: String?
        public let sessionID: String?
        public let body: EventBody
        public let timestamp: Date

        public var id: String { eventId }

        public init(
            eventId: String = UUID().uuidString,
            sequence: Int64,
            type: EventType,
            commandId: String? = nil,
            runtimeID: String? = nil,
            instanceID: String? = nil,
            sessionID: String? = nil,
            body: EventBody = EventBody(),
            timestamp: Date = Date(),
            protocolVersion: String = ProtocolV1.version
        ) {
            self.protocolVersion = protocolVersion
            self.eventId = eventId
            self.sequence = sequence
            self.type = type
            self.commandId = commandId
            self.runtimeID = runtimeID
            self.instanceID = instanceID
            self.sessionID = sessionID
            self.body = body
            self.timestamp = timestamp
        }
    }
}

public typealias Command = ProtocolV1.Command
public typealias Event = ProtocolV1.Event
