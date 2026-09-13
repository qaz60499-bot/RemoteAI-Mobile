import Foundation
import CryptoKit

struct RemoteAIConfig: Codable, Equatable {
    var relayBaseURL: URL
    var machineId: String

    static let placeholder = RemoteAIConfig(relayBaseURL: URL(string: "https://relay.example.invalid")!, machineId: "my-pc")
    static let preferredRelayBaseURL = URL(string: "https://remote.guessyy.ccwu.cc")!
    private static let legacyRelayHosts: Set<String> = ["remoteai-relay.qaz60499.workers.dev"]
    private static let relayKey = "remoteai.relayBaseURL"
    private static let machineKey = "remoteai.machineId"

    static func migratedRelayURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), legacyRelayHosts.contains(host) else { return url }
        return preferredRelayBaseURL
    }

    static func loadMetadata() -> RemoteAIConfig {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: relayKey), let storedURL = URL(string: raw) else { return .placeholder }
        let url = migratedRelayURL(storedURL)
        if url != storedURL { defaults.set(url.absoluteString, forKey: relayKey) }
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
    func healthStream() async -> AsyncStream<TransportHealthEvent>
}

enum TransportHealthChannel: String, Equatable {
    case relay
    case agent
}

enum TransportHealthState: String, Equatable {
    case connecting
    case online
    case reconnecting
    case offline
}

struct TransportHealthEvent: Equatable {
    let channel: TransportHealthChannel
    let state: TransportHealthState
    let at: Date
    let detail: String?
}

struct AgentStatusSnapshot: Equatable {
    let latestSequence: Int64
    let browserConnected: Bool?
    let relayOnline: Bool?
    let relayLastConnectedAt: Date?
    let relayLastDisconnectedAt: Date?
}

struct RemoteSessionStatusSnapshot: Equatable {
    let sessionId: String
    let state: SessionState
    let browserConnected: Bool?
    let lastActivityAt: Date?
    let lastProgressStatus: String?
    let lastProgressAt: Date?
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

    var diagnosticFields: [String: String] {
        switch self {
        case .offline: return ["transportKind": "offline"]
        case .badResponse(let status): return ["transportKind": "badResponse", "httpStatus": String(status)]
        case .malformedData: return ["transportKind": "malformedData"]
        case .pairingRequired: return ["transportKind": "pairingRequired"]
        case .disconnected: return ["transportKind": "disconnected"]
        case .timeout: return ["transportKind": "timeout"]
        case .insecureRelay: return ["transportKind": "insecureRelay"]
        case .frameTooLarge: return ["transportKind": "frameTooLarge"]
        case .replayDetected: return ["transportKind": "replayDetected"]
        case .remote(let code, _): return ["transportKind": "remote", "remoteCode": code]
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
    func healthStream() async -> AsyncStream<TransportHealthEvent> {
        AsyncStream { _ in }
    }

    func send(_ command: RemoteCommand) async throws -> CommandState {
        let response = try await execute(command)
        if response.ok { return .completed }
        if let error = response.error { throw TransportError.remote(error.code, error.message) }
        return .failed
    }

    func agentStatusSnapshot(machineId: String) async throws -> AgentStatusSnapshot {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "getStatus", payload: ["assistantDeltaVersion": .number(1)])
        let response = try await requireSuccess(execute(command))
        guard let object = response.objectValue,
              let sequence = object["latestSequence"]?.intValue else { throw TransportError.malformedData }
        let browser = object["browser"]?.objectValue
        let relay = object["relay"]?.objectValue
        return AgentStatusSnapshot(
            latestSequence: max(0, sequence),
            browserConnected: browser?["connected"]?.boolValue,
            relayOnline: relay?["online"]?.boolValue,
            relayLastConnectedAt: relay?["lastConnectedAt"]?.stringValue.flatMap(RemoteAIDate.parse),
            relayLastDisconnectedAt: relay?["lastDisconnectedAt"]?.stringValue.flatMap(RemoteAIDate.parse)
        )
    }

    func latestSequence(machineId: String) async throws -> Int64 {
        try await agentStatusSnapshot(machineId: machineId).latestSequence
    }

    func diagnosticsSnapshot(machineId: String) async throws -> JSONValue {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: "runtime.web", instanceId: "agent", action: "getDiagnostics")
        return try await requireSuccess(execute(command))
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

    func sessionStatus(machineId: String, runtimeId: String, instanceId: String, sessionId: String) async throws -> RemoteSessionStatusSnapshot {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "getSessionStatus")
        let response = try await requireSuccess(execute(command))
        guard let object = response.objectValue,
              object["sessionId"]?.stringValue == sessionId,
              let status = object["status"]?.stringValue else { throw TransportError.malformedData }
        let metadata = object["metadata"]?.objectValue ?? [:]
        return RemoteSessionStatusSnapshot(
            sessionId: sessionId,
            state: .server(status),
            browserConnected: object["browserConnected"]?.boolValue,
            lastActivityAt: metadata["lastActivityAt"]?.stringValue.flatMap(RemoteAIDate.parse),
            lastProgressStatus: metadata["lastProgressStatus"]?.stringValue,
            lastProgressAt: metadata["lastProgressAt"]?.stringValue.flatMap(RemoteAIDate.parse)
        )
    }

    func createSession(machineId: String, runtimeId: String, instanceId: String, payload: [String: JSONValue], commandId: UUID = UUID()) async throws -> SessionDescriptor? {
        let command = RemoteCommand.make(machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, action: "createSession", payload: payload, commandId: commandId)
        let response = try await requireSuccess(execute(command))
        return try? response.decode(ServerSession.self).descriptor
    }

    func listProjectsResponse(machineId: String, forceRefresh: Bool = false) async throws -> WebProjectListResponse {
        let command = RemoteCommand.make(
            machineId: machineId,
            runtimeId: "runtime.web",
            instanceId: "web.chatgpt",
            action: "listProjects",
            payload: ["preferCache": .bool(!forceRefresh)]
        )
        let response = try await requireSuccess(execute(command))
        return try response.decode(WebProjectListResponse.self)
    }

    func listProjects(machineId: String, forceRefresh: Bool = false) async throws -> [WebProjectDescriptor] {
        try await listProjectsResponse(machineId: machineId, forceRefresh: forceRefresh).items
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

    func downloadMessageAttachment(machineId: String, runtimeId: String, instanceId: String, sessionId: String, attachmentId: String, attachmentName: String? = nil) async throws -> DownloadedMessageAttachment {
        try ProtocolSecurity.validateIdentifier(attachmentId)

        let first = try await readMessageAttachmentChunk(
            machineId: machineId,
            runtimeId: runtimeId,
            instanceId: instanceId,
            sessionId: sessionId,
            attachmentId: attachmentId,
            attachmentName: attachmentName,
            index: 0
        )
        let totalChunks = (first.chunk.sizeBytes + first.chunk.chunkBytes - 1) / first.chunk.chunkBytes
        guard totalChunks >= 1, totalChunks <= MessageAttachmentTransferPolicy.maxDownloadChunks else { throw TransportError.frameTooLarge }
        if totalChunks == 1 {
            return DownloadedMessageAttachment(
                attachmentId: attachmentId,
                name: first.chunk.name,
                contentType: first.chunk.contentType,
                data: first.data
            )
        }

        let expectedSize = first.chunk.sizeBytes
        let expectedChunkBytes = first.chunk.chunkBytes
        let expectedName = first.chunk.name
        let expectedContentType = first.chunk.contentType
        var parts = Array<Data?>(repeating: nil, count: totalChunks)
        parts[0] = first.data

        // Relay responses are independent protocol frames, so several read-only chunks can
        // safely be in flight together. Keep the window deliberately small to reduce a
        // multi-megabyte image from dozens of serial relay round-trips without flooding the
        // WebSocket/Durable Object or increasing any individual frame beyond its existing cap.
        let maxConcurrentChunks = 6
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextIndex = 1
            for _ in 0..<min(maxConcurrentChunks, totalChunks - 1) {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    let item = try await self.readMessageAttachmentChunk(
                        machineId: machineId,
                        runtimeId: runtimeId,
                        instanceId: instanceId,
                        sessionId: sessionId,
                        attachmentId: attachmentId,
                        attachmentName: attachmentName,
                        index: index
                    )
                    guard item.chunk.sizeBytes == expectedSize,
                          item.chunk.chunkBytes == expectedChunkBytes,
                          item.chunk.name == expectedName,
                          item.chunk.contentType == expectedContentType else { throw TransportError.malformedData }
                    return (index, item.data)
                }
            }

            while let (index, data) = try await group.next() {
                parts[index] = data
                if nextIndex < totalChunks {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let item = try await self.readMessageAttachmentChunk(
                            machineId: machineId,
                            runtimeId: runtimeId,
                            instanceId: instanceId,
                            sessionId: sessionId,
                            attachmentId: attachmentId,
                            attachmentName: attachmentName,
                            index: index
                        )
                        guard item.chunk.sizeBytes == expectedSize,
                              item.chunk.chunkBytes == expectedChunkBytes,
                              item.chunk.name == expectedName,
                              item.chunk.contentType == expectedContentType else { throw TransportError.malformedData }
                        return (index, item.data)
                    }
                }
            }
        }

        var data = Data()
        data.reserveCapacity(expectedSize)
        for part in parts {
            guard let part else { throw TransportError.malformedData }
            data.append(part)
        }
        guard data.count == expectedSize else { throw TransportError.malformedData }
        return DownloadedMessageAttachment(attachmentId: attachmentId, name: expectedName, contentType: expectedContentType, data: data)
    }

    func downloadMessageAttachmentFile(machineId: String, runtimeId: String, instanceId: String, sessionId: String, attachmentId: String, attachmentName: String? = nil, destinationDirectory: URL) async throws -> DownloadedMessageAttachmentFile {
        try ProtocolSecurity.validateIdentifier(attachmentId)
        let first = try await readMessageAttachmentChunk(
            machineId: machineId,
            runtimeId: runtimeId,
            instanceId: instanceId,
            sessionId: sessionId,
            attachmentId: attachmentId,
            attachmentName: attachmentName,
            index: 0
        )
        let expectedSize = first.chunk.sizeBytes
        let expectedChunkBytes = first.chunk.chunkBytes
        let expectedName = first.chunk.name
        let expectedContentType = first.chunk.contentType
        let totalChunks = (expectedSize + expectedChunkBytes - 1) / expectedChunkBytes
        guard totalChunks >= 1, totalChunks <= MessageAttachmentTransferPolicy.maxDownloadChunks else { throw TransportError.frameTooLarge }

        let rawName = URL(fileURLWithPath: expectedName).lastPathComponent
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let sanitized = rawName
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeName = sanitized.isEmpty ? "attachment" : String(sanitized.prefix(180))
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let originalURL = destinationDirectory.appendingPathComponent(safeName)
        let base = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        var fileURL = originalURL
        var suffix = 2
        while FileManager.default.fileExists(atPath: fileURL.path), suffix <= 999 {
            let candidateName = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            fileURL = destinationDirectory.appendingPathComponent(candidateName)
            suffix += 1
        }
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw TransportError.malformedData }
        let handle = try FileHandle(forWritingTo: fileURL)

        do {
            try handle.write(contentsOf: first.data)
            let maxConcurrentChunks = 6
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var nextIndex = 1
                for _ in 0..<min(maxConcurrentChunks, totalChunks - 1) {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let item = try await self.readMessageAttachmentChunk(
                            machineId: machineId,
                            runtimeId: runtimeId,
                            instanceId: instanceId,
                            sessionId: sessionId,
                            attachmentId: attachmentId,
                            attachmentName: attachmentName,
                            index: index
                        )
                        guard item.chunk.sizeBytes == expectedSize,
                              item.chunk.chunkBytes == expectedChunkBytes,
                              item.chunk.name == expectedName,
                              item.chunk.contentType == expectedContentType else { throw TransportError.malformedData }
                        return (index, item.data)
                    }
                }
                while let (index, data) = try await group.next() {
                    try handle.seek(toOffset: UInt64(index * expectedChunkBytes))
                    try handle.write(contentsOf: data)
                    if nextIndex < totalChunks {
                        let index = nextIndex
                        nextIndex += 1
                        group.addTask {
                            let item = try await self.readMessageAttachmentChunk(
                                machineId: machineId,
                                runtimeId: runtimeId,
                                instanceId: instanceId,
                                sessionId: sessionId,
                                attachmentId: attachmentId,
                                attachmentName: attachmentName,
                                index: index
                            )
                            guard item.chunk.sizeBytes == expectedSize,
                                  item.chunk.chunkBytes == expectedChunkBytes,
                                  item.chunk.name == expectedName,
                                  item.chunk.contentType == expectedContentType else { throw TransportError.malformedData }
                            return (index, item.data)
                        }
                    }
                }
            }
            try handle.synchronize()
            try handle.close()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size == expectedSize else {
                try? FileManager.default.removeItem(at: fileURL)
                throw TransportError.malformedData
            }
            return DownloadedMessageAttachmentFile(
                attachmentId: attachmentId,
                name: safeName,
                contentType: expectedContentType,
                sizeBytes: expectedSize,
                url: fileURL
            )
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    private func readMessageAttachmentChunk(machineId: String, runtimeId: String, instanceId: String, sessionId: String, attachmentId: String, attachmentName: String?, index: Int) async throws -> (chunk: MessageAttachmentChunk, data: Data) {
        guard index >= 0 && index < MessageAttachmentTransferPolicy.maxDownloadChunks else { throw TransportError.frameTooLarge }
        var payload: [String: JSONValue] = [
            "attachmentId": .string(attachmentId),
            "index": .number(Double(index))
        ]
        if let attachmentName {
            let normalized = attachmentName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { payload["attachmentName"] = .string(String(normalized.prefix(220))) }
        }
        let command = RemoteCommand.make(
            machineId: machineId,
            runtimeId: runtimeId,
            instanceId: instanceId,
            sessionId: sessionId,
            action: "readMessageAttachmentChunk",
            payload: payload
        )
        let chunk = try await requireSuccess(execute(command)).decode(MessageAttachmentChunk.self)
        guard chunk.attachmentId == attachmentId,
              chunk.index == index,
              chunk.sizeBytes > 0,
              chunk.sizeBytes <= MessageAttachmentTransferPolicy.maxDownloadBytes,
              chunk.chunkBytes >= 16 * 1024,
              chunk.chunkBytes <= 96 * 1024,
              let data = Data(base64Encoded: chunk.dataBase64) else { throw TransportError.malformedData }
        let offset = index * chunk.chunkBytes
        guard offset < chunk.sizeBytes else { throw TransportError.malformedData }
        let expectedLength = min(chunk.chunkBytes, chunk.sizeBytes - offset)
        guard data.count == expectedLength,
              chunk.hasMore == (offset + data.count < chunk.sizeBytes) else { throw TransportError.malformedData }
        return (chunk, data)
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
