import Foundation

actor CloudflareTransport: Transport {
    private let config: RemoteAIConfig
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var continuation: AsyncStream<RemoteEvent>.Continuation?
    private var stream: AsyncStream<RemoteEvent>?
    private let keychain: KeychainStore

    init(config: RemoteAIConfig, session: URLSession = .shared, keychain: KeychainStore = .shared) {
        self.config = config; self.session = session; self.keychain = keychain
    }
    var isConnected: Bool { connected }

    func connect() async throws {
        guard !connected else { return }
        var request = URLRequest(url: config.webSocketURL)
        if let secret = keychain.load(account: config.machineId) { request.setValue(secret.base64EncodedString(), forHTTPHeaderField: "X-RemoteAI-Device") }
        let task = session.webSocketTask(with: request); task.resume(); socket = task; connected = true
        Task { await receiveLoop() }
    }
    func disconnect() async {
        connected = false; socket?.cancel(with: .goingAway, reason: nil); socket = nil; continuation?.finish()
    }
    func eventStream() async -> AsyncStream<RemoteEvent> {
        if let stream { return stream }
        var captured: AsyncStream<RemoteEvent>.Continuation?
        let s = AsyncStream<RemoteEvent> { captured = $0 }
        continuation = captured
        stream = s
        return s
    }
    private func receiveLoop() async {
        while connected, let socket {
            do {
                let msg = try await socket.receive(); let data: Data
                switch msg { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                if let event = try? JSONDecoder.remoteAI.decode(RemoteEvent.self, from: data) { continuation?.yield(event) }
            } catch { connected = false; continuation?.finish(); break }
        }
    }
    func send(_ command: RemoteCommand) async throws -> CommandState {
        var request = URLRequest(url: config.relayBaseURL.appendingPathComponent("v1/command")); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let clear = try JSONEncoder.remoteAI.encode(command)
        if let key = keychain.load(account: config.machineId) {
            request.setValue("aes-gcm-v1", forHTTPHeaderField: "X-RemoteAI-Payload")
            request.httpBody = try JSONEncoder.remoteAI.encode(PayloadCrypto.encrypt(clear, keyData: key))
        } else { request.httpBody = clear }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformedData }
        guard (200..<300).contains(http.statusCode) else { throw TransportError.badResponse(http.statusCode) }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = raw["state"] as? String, let state = CommandState(rawValue: value) { return state }
        return .acknowledged
    }
    func delta(after sequence: Int64) async throws -> DeltaSyncResult {
        try await get(path: "v1/sync", query: [URLQueryItem(name: "after", value: String(sequence))], as: DeltaSyncResult.self)
    }
    func loadRecent(sessionId: String, limit: Int) async throws -> Page<ChatMessage> {
        try await get(path: "v1/messages/recent", query: [.init(name: "sessionId", value: sessionId), .init(name: "limit", value: String(limit))], as: Page<ChatMessage>.self)
    }
    func loadBefore(sessionId: String, before: Int64, limit: Int) async throws -> Page<ChatMessage> {
        try await get(path: "v1/messages/before", query: [.init(name: "sessionId", value: sessionId), .init(name: "before", value: String(before)), .init(name: "limit", value: String(limit))], as: Page<ChatMessage>.self)
    }
    private func get<T: Decodable>(path: String, query: [URLQueryItem], as type: T.Type) async throws -> T {
        var c = URLComponents(url: config.relayBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!; c.queryItems = query
        var r = URLRequest(url: c.url!); if let secret = keychain.load(account: config.machineId) { r.setValue(secret.base64EncodedString(), forHTTPHeaderField: "X-RemoteAI-Device") }
        let (data, response) = try await session.data(for: r); guard let http = response as? HTTPURLResponse else { throw TransportError.malformedData }; guard (200..<300).contains(http.statusCode) else { throw TransportError.badResponse(http.statusCode) }
        return try JSONDecoder.remoteAI.decode(T.self, from: data)
    }
}
