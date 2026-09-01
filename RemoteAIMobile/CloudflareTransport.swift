import Foundation

actor CloudflareTransport: Transport {
    private let config: RemoteAIConfig
    private let session: URLSession
    private let keychain: KeychainStore
    private let maxInboundFrameBytes = ProtocolSecurity.maxInboundFrameBytes
    private let maxOutboundFrameBytes = ProtocolSecurity.maxOutboundFrameBytes
    private let commandTimeoutNanoseconds: UInt64 = 30_000_000_000

    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var connecting = false
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var continuation: AsyncStream<RemoteEvent>.Continuation?
    private var stream: AsyncStream<RemoteEvent>?
    private var pending: [UUID: CheckedContinuation<CommandResponseEnvelope, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var inboundReplayGuard = BoundedReplayGuard(capacity: 4096)

    init(config: RemoteAIConfig, session: URLSession = .shared, keychain: KeychainStore = .shared) {
        self.config = config
        self.session = session
        self.keychain = keychain
    }

    var isConnected: Bool { connected }

    func connect() async throws {
        if connected { return }
        if connecting {
            try await withCheckedThrowingContinuation { continuation in
                connectionWaiters.append(continuation)
            }
            return
        }

        connecting = true
        var attemptedSocket: URLSessionWebSocketTask?
        do {
            try RemoteAIConfig.validateSecureRelay(config.relayBaseURL)
            guard PairingKeyStore.isPaired(machineId: config.machineId, keychain: keychain) else { throw TransportError.pairingRequired }
            try ProtocolSecurity.validateIdentifier(config.machineId)
            let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
            try ProtocolSecurity.validateIdentifier(deviceId)
            let url = try RemoteAIConfig.deviceWebSocketURL(baseURL: config.relayBaseURL, machineId: config.machineId, deviceId: deviceId)
            let task = session.webSocketTask(with: url, protocols: ["remoteai.v1"])
            attemptedSocket = task
            task.maximumMessageSize = maxInboundFrameBytes
            socket = task
            task.resume()
            try await ping(task)
            guard socket === task else { throw TransportError.disconnected }
            connected = true
            connecting = false
            finishConnectionWaiters()
            Task { [weak self, weak task] in
                guard let self, let task else { return }
                await self.receiveLoop(task)
            }
        } catch {
            if let attemptedSocket, socket === attemptedSocket {
                socket = nil
                attemptedSocket.cancel(with: .goingAway, reason: nil)
            }
            connecting = false
            finishConnectionWaiters(error: error)
            throw error
        }
    }

    func disconnect() async {
        connected = false
        let active = socket
        socket = nil
        active?.cancel(with: .goingAway, reason: nil)
        failAllPending(with: TransportError.disconnected)
    }

    func eventStream() async -> AsyncStream<RemoteEvent> {
        if let stream { return stream }
        var captured: AsyncStream<RemoteEvent>.Continuation?
        let created = AsyncStream<RemoteEvent> { captured = $0 }
        continuation = captured
        stream = created
        return created
    }

    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        guard connected, socket != nil else { throw TransportError.offline }
        try ProtocolSecurity.validate(command, expectedMachineId: config.machineId)
        guard pending[command.commandId] == nil else { throw TransportError.replayDetected }
        let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
        guard let key = PairingKeyStore.sharedKey(machineId: config.machineId, keychain: keychain) else { throw TransportError.pairingRequired }
        let clear = try JSONEncoder.remoteAI.encode(command)
        guard clear.count <= maxOutboundFrameBytes else { throw TransportError.frameTooLarge }
        let messageId = UUID().uuidString
        let encrypted = try PayloadCrypto.encrypt(clear, keyData: key, machineId: config.machineId, deviceId: deviceId, messageId: messageId)
        guard let encryptedObject = try JSONValue.encode(encrypted).objectValue else { throw TransportError.malformedData }
        let frame = RelayFrame(v: 1, kind: "ENCRYPTED", machineId: config.machineId, deviceId: deviceId, messageId: messageId, body: encryptedObject)

        return try await withCheckedThrowingContinuation { continuation in
            pending[command.commandId] = continuation
            timeoutTasks[command.commandId]?.cancel()
            timeoutTasks[command.commandId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.commandTimeoutNanoseconds ?? 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.failPending(command.commandId, error: TransportError.timeout)
            }
            Task { [weak self] in
                do { try await self?.sendFrame(frame) }
                catch { await self?.failPending(command.commandId, error: error) }
            }
        }
    }

    private func receiveLoop(_ activeSocket: URLSessionWebSocketTask) async {
        while connected, socket === activeSocket {
            do {
                let message = try await activeSocket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                let frame = try ProtocolSecurity.decodeRelayFrame(data, maxBytes: maxInboundFrameBytes)
                try await handle(frame)
            } catch {
                if socket === activeSocket {
                    connected = false
                    socket = nil
                    activeSocket.cancel(with: .goingAway, reason: nil)
                    failAllPending(with: TransportError.disconnected)
                }
                break
            }
        }
    }

    private func handle(_ frame: RelayFrame) async throws {
        let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
        try ProtocolSecurity.validate(frame, expectedMachineId: config.machineId, expectedDeviceId: deviceId)
        if frame.kind == "PING" {
            try await sendFrame(RelayFrame(v: 1, kind: "PONG", machineId: config.machineId, deviceId: deviceId, messageId: UUID().uuidString, body: ["at": .number(Date().timeIntervalSince1970 * 1000)]))
            return
        }
        guard frame.kind == "ENCRYPTED", let key = PairingKeyStore.sharedKey(machineId: config.machineId, keychain: keychain) else { return }
        let encrypted = try JSONValue.object(frame.body).decode(EncryptedRelayBody.self)
        let clear = try PayloadCrypto.decrypt(encrypted, keyData: key, machineId: config.machineId, deviceId: deviceId, messageId: frame.messageId)
        guard clear.count <= maxInboundFrameBytes else { throw TransportError.frameTooLarge }
        let payload = try ProtocolSecurity.decodeDecryptedPayload(clear, expectedMachineId: config.machineId)
        guard inboundReplayGuard.accept(frame.messageId) else { throw TransportError.replayDetected }

        if payload.kind == "event", let event = payload.event {
            continuation?.yield(event)
            return
        }
        if payload.kind == "commandResponse", let rawId = payload.commandId, let id = UUID(uuidString: rawId), let response = payload.response {
            if let event = payload.event { continuation?.yield(event) }
            completePending(id, response: response)
            return
        }
        if payload.kind == "error", let error = payload.error {
            failAllPending(with: TransportError.remote(error.code, error.message))
        }
    }

    private func sendFrame(_ frame: RelayFrame) async throws {
        guard connected, let socket else { throw TransportError.disconnected }
        let data = try JSONEncoder.remoteAI.encode(frame)
        guard data.count <= maxOutboundFrameBytes else { throw TransportError.frameTooLarge }
        try await socket.send(.data(data))
    }

    private func completePending(_ id: UUID, response: CommandResponseEnvelope) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: response)
    }

    private func failPending(_ id: UUID, error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let continuations = pending
        pending.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for continuation in continuations.values { continuation.resume(throwing: error) }
    }

    private func finishConnectionWaiters(error: Error? = nil) {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume(returning: ()) }
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
