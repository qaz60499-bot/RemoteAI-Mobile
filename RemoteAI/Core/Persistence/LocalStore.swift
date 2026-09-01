import Foundation

public struct LocalCache: Codable, Sendable {
    public var runtimes: [RuntimeNode]
    public var instances: [InstanceNode]
    public var sessions: [SessionSummary]
    public var messages: [ChatMessage]
    public var lastSequenceBySession: [String: Int64]

    public init(
        runtimes: [RuntimeNode] = [],
        instances: [InstanceNode] = [],
        sessions: [SessionSummary] = [],
        messages: [ChatMessage] = [],
        lastSequenceBySession: [String: Int64] = [:]
    ) {
        self.runtimes = runtimes
        self.instances = instances
        self.sessions = sessions
        self.messages = messages
        self.lastSequenceBySession = lastSequenceBySession
    }
}

public actor LocalStore {
    public nonisolated let fileURL: URL
    private var cache: LocalCache?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fileManager = FileManager.default
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("RemoteAI", isDirectory: true)
                .appendingPathComponent("cache.json")
        }
    }

    public func load() throws -> LocalCache {
        if let cache {
            return cache
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = LocalCache()
            cache = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder.remoteAI.decode(LocalCache.self, from: data)
        cache = decoded
        return decoded
    }

    public func replace(with newCache: LocalCache) throws {
        cache = newCache
        try persist(newCache)
    }

    public func upsert(runtime: RuntimeNode) throws {
        var current = try load()
        if let index = current.runtimes.firstIndex(where: { $0.id == runtime.id }) {
            current.runtimes[index] = runtime
        } else {
            current.runtimes.append(runtime)
        }
        try replace(with: current)
    }

    public func upsert(instance: InstanceNode) throws {
        var current = try load()
        if let index = current.instances.firstIndex(where: { $0.id == instance.id }) {
            current.instances[index] = instance
        } else {
            current.instances.append(instance)
        }
        try replace(with: current)
    }

    public func upsert(session: SessionSummary) throws {
        var current = try load()
        if let index = current.sessions.firstIndex(where: { $0.id == session.id }) {
            current.sessions[index] = session
        } else {
            current.sessions.append(session)
        }
        try replace(with: current)
    }

    public func append(messages newMessages: [ChatMessage], sessionID: String) throws {
        var current = try load()
        let existingIDs = Set(current.messages.filter { $0.sessionID == sessionID }.map(\.id))
        current.messages.append(contentsOf: newMessages.filter { !existingIDs.contains($0.id) })
        current.messages.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
            return lhs.createdAt < rhs.createdAt
        }
        try replace(with: current)
    }

    public func update(message: ChatMessage) throws {
        var current = try load()
        if let index = current.messages.firstIndex(where: { $0.id == message.id }) {
            current.messages[index] = message
        } else {
            current.messages.append(message)
        }
        current.messages.sort { $0.createdAt < $1.createdAt }
        try replace(with: current)
    }

    public func page(sessionID: String, before: Date? = nil, limit: Int = 50) throws -> Page<ChatMessage> {
        let current = try load()
        let safeLimit = max(1, min(limit, 500))
        let eligible = current.messages
            .filter { message in
                message.sessionID == sessionID && (before == nil || message.createdAt < before!)
            }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id > $1.id }
                return $0.createdAt > $1.createdAt
            }
        let selected = Array(eligible.prefix(safeLimit)).sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
        let nextCursor = selected.first.map { String($0.createdAt.timeIntervalSince1970) }
        return Page(items: selected, hasMore: eligible.count > safeLimit, nextCursor: nextCursor)
    }

    public func setLastSequence(_ sequence: Int64, for sessionID: String) throws {
        var current = try load()
        current.lastSequenceBySession[sessionID] = sequence
        try replace(with: current)
    }

    private func persist(_ value: LocalCache) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.remoteAI.encode(value)
        try data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var remoteAI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var remoteAI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
