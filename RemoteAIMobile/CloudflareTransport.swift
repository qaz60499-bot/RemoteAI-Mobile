import Foundation

actor CloudflareTransport: Transport {
    private let config: RemoteAIConfig
    private let session: URLSession
    private let keychain: KeychainStore
    private let maxInboundFrameBytes = ProtocolSecurity.maxInboundFrameBytes
    private let maxOutboundFrameBytes = ProtocolSecurity.maxOutboundFrameBytes
    private let commandTimeoutNanoseconds: UInt64 = 30_000_000_000
    private let connectionTimeoutSeconds: TimeInterval = 8
    private let sendTimeoutSeconds: TimeInterval = 10
    private let heartbeatIntervalNanoseconds: UInt64 = 12_000_000_000
    private let heartbeatTimeoutNanoseconds: UInt64 = 8_000_000_000
    private let agentOfflineGraceNanoseconds: UInt64 = 2_500_000_000

    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var connecting = false
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var continuation: AsyncStream<RemoteEvent>.Continuation?
    private var stream: AsyncStream<RemoteEvent>?
    private var healthContinuation: AsyncStream<TransportHealthEvent>.Continuation?
    private var healthEventStream: AsyncStream<TransportHealthEvent>?
    private var pending: [UUID: CheckedContinuation<CommandResponseEnvelope, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var inboundReplayGuard = BoundedReplayGuard(capacity: 4096)
    private var orphanedResponses: [UUID: CommandResponseEnvelope] = [:]
    private var orphanedResponseOrder: [UUID] = []
    private let orphanedResponseLimit = 256
    private var heartbeatTask: Task<Void, Never>?
    private var agentOfflineTask: Task<Void, Never>?
    private var awaitingPongMessageId: String?
    private var agentOnline = false

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
            publishHealth(channel: .relay, state: .connecting, detail: nil)
            task.resume()
            let relayAgentOnline = try await waitForRelayReady(task, deviceId: deviceId)
            guard socket === task else { throw TransportError.disconnected }
            connected = true
            agentOnline = relayAgentOnline
            agentOfflineTask?.cancel()
            agentOfflineTask = nil
            connecting = false
            publishHealth(channel: .relay, state: .online, detail: nil)
            publishHealth(channel: .agent, state: relayAgentOnline ? .online : .offline, detail: relayAgentOnline ? nil : "Windows Agent is not connected to Relay")
            finishConnectionWaiters()
            Task { [weak self, weak task] in
                guard let self, let task else { return }
                await self.receiveLoop(task)
            }
            startHeartbeat(task)
        } catch {
            if let attemptedSocket, socket === attemptedSocket {
                socket = nil
                attemptedSocket.cancel(with: .goingAway, reason: nil)
            }
            connecting = false
            if (error as? TransportError) != .pairingRequired {
                publishHealth(channel: .relay, state: .offline, detail: String(describing: type(of: error)))
            }
            finishConnectionWaiters(error: error)
            throw error
        }
    }

    func disconnect() async {
        connected = false
        agentOnline = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        agentOfflineTask?.cancel()
        agentOfflineTask = nil
        awaitingPongMessageId = nil
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

    func healthStream() async -> AsyncStream<TransportHealthEvent> {
        if let healthEventStream { return healthEventStream }
        var captured: AsyncStream<TransportHealthEvent>.Continuation?
        let created = AsyncStream<TransportHealthEvent> { captured = $0 }
        healthContinuation = captured
        healthEventStream = created
        return created
    }

    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        try ProtocolSecurity.validate(command, expectedMachineId: config.machineId)
        if let replayed = takeOrphanedResponse(command.commandId) {
            return replayed
        }
        guard connected, socket != nil else { throw TransportError.offline }
        guard agentOnline else { throw TransportError.offline }
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
                    if (error as? TransportError) == .pairingRequired {
                        closeActiveSocket(activeSocket, pendingError: TransportError.pairingRequired)
                    } else {
                        closeActiveSocket(activeSocket, pendingError: TransportError.disconnected)
                    }
                }
                break
            }
        }
    }

    private func handle(_ frame: RelayFrame) async throws {
        let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
        try ProtocolSecurity.validate(frame, expectedMachineId: config.machineId)
        if frame.kind == "ACK" {
            guard frame.deviceId == nil || frame.deviceId == deviceId else { throw TransportError.malformedData }
            if let code = frame.body["error"]?.stringValue {
                let message = frame.body["message"]?.stringValue ?? "Windows rejected this device."
                if code == "UNAUTHORIZED_DEVICE" {
                    PairingKeyStore.deletePairing(machineId: config.machineId, keychain: keychain)
                    throw TransportError.pairingRequired
                }
                throw TransportError.remote(code, message)
            }
            if let relayState = frame.body["relay"]?.stringValue {
                if relayState == "agent-online" {
                    agentOnline = true
                    agentOfflineTask?.cancel()
                    agentOfflineTask = nil
                    publishHealth(channel: .agent, state: .online, detail: nil)
                    await recordDiagnostic("relay_agent_online")
                } else if relayState == "agent-offline" {
                    agentOnline = false
                    publishHealth(channel: .agent, state: .reconnecting, detail: "Windows Agent disconnected from Relay")
                    await recordDiagnostic("relay_agent_offline", level: "WARN")
                    scheduleAgentOfflineConfirmation()
                }
            }
            return
        }
        try ProtocolSecurity.validate(frame, expectedMachineId: config.machineId, expectedDeviceId: deviceId)
        if frame.kind == "PING" {
            try await sendFrame(RelayFrame(v: 1, kind: "PONG", machineId: config.machineId, deviceId: deviceId, messageId: frame.messageId, body: ["at": .number(Date().timeIntervalSince1970 * 1000)]))
            return
        }
        if frame.kind == "PONG" {
            if awaitingPongMessageId == frame.messageId { awaitingPongMessageId = nil }
            return
        }
        guard frame.kind == "ENCRYPTED", let key = PairingKeyStore.sharedKey(machineId: config.machineId, keychain: keychain) else { return }
        let encrypted = try JSONValue.object(frame.body).decode(EncryptedRelayBody.self)
        let clear = try PayloadCrypto.decrypt(encrypted, keyData: key, machineId: config.machineId, deviceId: deviceId, messageId: frame.messageId)
        guard clear.count <= maxInboundFrameBytes else { throw TransportError.frameTooLarge }
        let payload = try ProtocolSecurity.decodeDecryptedPayload(clear, expectedMachineId: config.machineId)
        let firstDelivery = inboundReplayGuard.accept(frame.messageId)
        // Durable relay frames are retained across 1006 until this device ACKs the
        // exact relay message id. ACK only after the encrypted payload validates; if
        // the ACK is lost the frame may replay and is safely ignored below.
        try? await sendRelayDeliveryAck(frame.messageId, direction: "to-device")
        guard firstDelivery else { return }

        if payload.kind == "event", let event = payload.event {
            continuation?.yield(event)
            return
        }
        if payload.kind == "commandResponse", let rawId = payload.commandId, let id = UUID(uuidString: rawId), let response = payload.response {
            if let event = payload.event { continuation?.yield(event) }
            if pending[id] != nil {
                completePending(id, response: response)
            } else {
                cacheOrphanedResponse(id, response: response)
            }
            return
        }
        if payload.kind == "error", let error = payload.error {
            failAllPending(with: TransportError.remote(error.code, error.message))
        }
    }

    private func startHeartbeat(_ activeSocket: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, weak activeSocket] in
            guard let self, let activeSocket else { return }
            await self.heartbeatLoop(activeSocket)
        }
    }

    private func heartbeatLoop(_ activeSocket: URLSessionWebSocketTask) async {
        while connected, socket === activeSocket, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: heartbeatIntervalNanoseconds)
            guard !Task.isCancelled, connected, socket === activeSocket else { return }
            do {
                let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
                let messageId = UUID().uuidString
                awaitingPongMessageId = messageId
                try await sendFrame(RelayFrame(
                    v: 1,
                    kind: "PING",
                    machineId: config.machineId,
                    deviceId: deviceId,
                    messageId: messageId,
                    body: ["at": .number(Date().timeIntervalSince1970 * 1000)]
                ))
                try? await Task.sleep(nanoseconds: heartbeatTimeoutNanoseconds)
                guard !Task.isCancelled, connected, socket === activeSocket else { return }
                if awaitingPongMessageId == messageId {
                    await recordDiagnostic("relay_heartbeat_timeout", fields: ["messageId": messageId], level: "WARN")
                    closeActiveSocket(activeSocket, pendingError: TransportError.disconnected)
                    return
                }
            } catch {
                guard connected, socket === activeSocket else { return }
                await recordDiagnostic("relay_heartbeat_send_failed", fields: ["errorType": String(describing: type(of: error))], level: "WARN")
                closeActiveSocket(activeSocket, pendingError: TransportError.disconnected)
                return
            }
        }
    }

    private func scheduleAgentOfflineConfirmation() {
        agentOfflineTask?.cancel()
        guard let activeSocket = socket else { return }
        agentOfflineTask = Task { [weak self, weak activeSocket] in
            try? await Task.sleep(nanoseconds: self?.agentOfflineGraceNanoseconds ?? 2_500_000_000)
            guard !Task.isCancelled, let self, let activeSocket else { return }
            await self.confirmAgentOffline(activeSocket)
        }
    }

    private func confirmAgentOffline(_ activeSocket: URLSessionWebSocketTask) async {
        agentOfflineTask = nil
        guard !agentOnline, connected, socket === activeSocket else { return }
        // The phone-to-Relay websocket is still healthy. Keep it open so Relay can
        // announce agent-online immediately when Windows returns; do not turn one
        // Windows outage into a second Relay reconnect loop.
        publishHealth(channel: .agent, state: .offline, detail: "Windows Agent remained offline after reconnect grace")
        await recordDiagnostic("relay_agent_offline_confirmed", level: "WARN")
        failAllPending(with: TransportError.offline)
    }

    private func recordDiagnostic(_ event: String, fields: [String: String] = [:], level: String = "INFO") async {
        await MainActor.run {
            DiagnosticsLog.shared.record(event, fields: fields, level: level)
        }
    }

    private func closeActiveSocket(_ activeSocket: URLSessionWebSocketTask, pendingError: Error) {
        guard socket === activeSocket else { return }
        connected = false
        agentOnline = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        agentOfflineTask?.cancel()
        agentOfflineTask = nil
        awaitingPongMessageId = nil
        socket = nil
        publishHealth(channel: .relay, state: .offline, detail: String(describing: type(of: pendingError)))
        activeSocket.cancel(with: .goingAway, reason: nil)
        failAllPending(with: pendingError)
    }

    private func publishHealth(channel: TransportHealthChannel, state: TransportHealthState, detail: String?) {
        healthContinuation?.yield(TransportHealthEvent(channel: channel, state: state, at: Date(), detail: detail))
    }

    private func sendFrame(_ frame: RelayFrame) async throws {
        guard connected, let socket else { throw TransportError.disconnected }
        let data = try JSONEncoder.remoteAI.encode(frame)
        guard data.count <= maxOutboundFrameBytes else { throw TransportError.frameTooLarge }
        try await WebSocketIO.send(.data(data), on: socket, timeout: sendTimeoutSeconds, timeoutReason: "remoteai-send-timeout")
    }

    private func sendRelayDeliveryAck(_ relayMessageId: String, direction: String) async throws {
        let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
        let frame = RelayFrame(
            v: 1,
            kind: "ACK",
            machineId: config.machineId,
            deviceId: deviceId,
            messageId: UUID().uuidString,
            body: [
                "relayAckMessageId": .string(relayMessageId),
                "relayAckDirection": .string(direction)
            ]
        )
        try await sendFrame(frame)
    }

    private func completePending(_ id: UUID, response: CommandResponseEnvelope) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: response)
    }

    private func cacheOrphanedResponse(_ id: UUID, response: CommandResponseEnvelope) {
        if orphanedResponses[id] == nil { orphanedResponseOrder.append(id) }
        orphanedResponses[id] = response
        while orphanedResponseOrder.count > orphanedResponseLimit {
            let expired = orphanedResponseOrder.removeFirst()
            orphanedResponses.removeValue(forKey: expired)
        }
    }

    private func takeOrphanedResponse(_ id: UUID) -> CommandResponseEnvelope? {
        guard let response = orphanedResponses.removeValue(forKey: id) else { return nil }
        orphanedResponseOrder.removeAll { $0 == id }
        return response
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

    private func waitForRelayReady(_ socket: URLSessionWebSocketTask, deviceId: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(connectionTimeoutSeconds)
        for _ in 0..<4 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TransportError.timeout }
            let message = try await WebSocketIO.receive(from: socket, timeout: remaining, timeoutReason: "remoteai-connect-timeout")
            let data = WebSocketIO.data(from: message)
            guard !data.isEmpty else { continue }
            let frame = try ProtocolSecurity.decodeRelayFrame(data, maxBytes: maxInboundFrameBytes)
            try ProtocolSecurity.validate(frame, expectedMachineId: config.machineId)
            guard frame.deviceId == nil || frame.deviceId == deviceId else { throw TransportError.malformedData }
            if frame.kind == "ACK", let code = frame.body["error"]?.stringValue {
                if code == "UNAUTHORIZED_DEVICE" {
                    PairingKeyStore.deletePairing(machineId: config.machineId, keychain: keychain)
                    throw TransportError.pairingRequired
                }
                throw TransportError.remote(code, frame.body["message"]?.stringValue ?? "Relay rejected the connection.")
            }
            if frame.kind == "ACK", frame.body["relay"]?.stringValue == "device-connected" {
                return frame.body["agentOnline"]?.boolValue ?? true
            }
        }
        throw TransportError.timeout
    }
}
