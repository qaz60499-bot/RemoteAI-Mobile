import Foundation

enum MockScenario: String, CaseIterable { case normal, commandFailure, disconnect, duplicateEvent, sequenceGap, offline }

actor MockTransport: Transport {
    private var connected = false
    private var scenario: MockScenario
    private var sequence: Int64 = 1200
    private var continuation: AsyncStream<RemoteEvent>.Continuation?
    private var stream: AsyncStream<RemoteEvent>?
    private var processedCommands: [UUID: CommandResponseEnvelope] = [:]
    private var history: [String: [ServerMessage]] = [:]
    private var eventLog: [RemoteEvent] = []
    private var sessions: [ServerSession] = []

    private let machineId = "my-pc"
    private let runtimes: [ServerRuntime]
    private let instances: [ServerInstance]

    init(scenario: MockScenario = .normal, historyCount: Int = 1200) {
        self.scenario = scenario
        // Protocol timestamps are serialized at millisecond precision. Build deterministic
        // mock history on the same precision so `(createdAt, messageId)` cursor comparisons
        // do not change after an encode/decode round-trip.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000)
        runtimes = [
            ServerRuntime(runtimeId: "runtime.web", kind: "Web", label: "Web", capabilities: ["list", "status", "sendMessage"], status: "ready", updatedAt: now),
            ServerRuntime(runtimeId: "runtime.cloudcode", kind: "CloudCode", label: "Cloud Code", capabilities: ["list", "status", "sendMessage"], status: "ready", updatedAt: now),
            ServerRuntime(runtimeId: "runtime.codex", kind: "Codex", label: "Codex", capabilities: ["list", "status", "sendMessage"], status: "ready", updatedAt: now)
        ]
        instances = [
            ServerInstance(instanceId: "web.chatgpt", runtimeId: "runtime.web", label: "ChatGPT", kind: "chatgpt-web", config: [:], status: "ready", updatedAt: now),
            ServerInstance(instanceId: "photo", runtimeId: "runtime.web", label: "Photo SaaS", kind: "cached-project", config: [:], status: "ready", updatedAt: now),
            ServerInstance(instanceId: "excel", runtimeId: "runtime.web", label: "Excel SaaS", kind: "cached-project", config: [:], status: "ready", updatedAt: now),
            ServerInstance(instanceId: "cloud-photo", runtimeId: "runtime.cloudcode", label: "Photo", kind: "claude-code-cli", config: [:], status: "ready", updatedAt: now),
            ServerInstance(instanceId: "codex6", runtimeId: "runtime.codex", label: "Codex6", kind: "codex-cli", config: [:], status: "ready", updatedAt: now)
        ]
        sessions = [
            ServerSession(sessionId: "photo-upload", runtimeId: "runtime.web", instanceId: "photo", externalId: nil, title: "上传性能优化", canonicalUrl: nil, status: "idle", metadata: [:], createdAt: now, updatedAt: now, lastVisited: now),
            ServerSession(sessionId: "photo-ios", runtimeId: "runtime.web", instanceId: "photo", externalId: nil, title: "手机 APP", canonicalUrl: nil, status: "idle", metadata: [:], createdAt: now, updatedAt: now, lastVisited: now),
            ServerSession(sessionId: "excel-permission", runtimeId: "runtime.web", instanceId: "excel", externalId: nil, title: "权限测试", canonicalUrl: nil, status: "idle", metadata: [:], createdAt: now, updatedAt: now, lastVisited: now),
            ServerSession(sessionId: "cloud-photo-a", runtimeId: "runtime.cloudcode", instanceId: "cloud-photo", externalId: nil, title: "Session A", canonicalUrl: nil, status: "idle", metadata: [:], createdAt: now, updatedAt: now, lastVisited: now),
            ServerSession(sessionId: "codex6-a", runtimeId: "runtime.codex", instanceId: "codex6", externalId: nil, title: "Session A", canonicalUrl: nil, status: "idle", metadata: [:], createdAt: now, updatedAt: now, lastVisited: now)
        ]

        var messages: [ServerMessage] = []
        if historyCount > 0 {
            for i in 1...historyCount {
                let assistant = i % 2 == 0
                messages.append(ServerMessage(
                    messageId: "mock-\(i)",
                    sessionId: "photo-upload",
                    role: assistant ? "assistant" : "user",
                    content: assistant ? "Mock assistant response \(i). This verifies long-history pagination without rendering everything at once." : "Mock user message \(i)",
                    externalId: nil,
                    createdAt: now.addingTimeInterval(Double(i - historyCount) * 30)
                ))
            }
        }
        history["photo-upload"] = messages
        history["photo-ios"] = Array(messages.suffix(80)).map { ServerMessage(messageId: "ios-\($0.messageId)", sessionId: "photo-ios", role: $0.role, content: $0.content, externalId: nil, createdAt: $0.createdAt) }
        history["cloud-photo-a"] = Array(messages.suffix(60)).map { ServerMessage(messageId: "cloud-\($0.messageId)", sessionId: "cloud-photo-a", role: $0.role, content: $0.content, externalId: nil, createdAt: $0.createdAt) }
        history["codex6-a"] = Array(messages.suffix(60)).map { ServerMessage(messageId: "codex-\($0.messageId)", sessionId: "codex6-a", role: $0.role, content: $0.content, externalId: nil, createdAt: $0.createdAt) }
    }

    var isConnected: Bool { connected }
    func setScenario(_ value: MockScenario) { scenario = value }
    func connect() async throws { guard scenario != .offline else { throw TransportError.offline }; connected = true }
    func disconnect() async { connected = false }

    func eventStream() async -> AsyncStream<RemoteEvent> {
        if let stream { return stream }
        var captured: AsyncStream<RemoteEvent>.Continuation?
        let created = AsyncStream<RemoteEvent> { captured = $0 }
        continuation = captured
        stream = created
        return created
    }

    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        if let prior = processedCommands[command.commandId] {
            return CommandResponseEnvelope(ok: prior.ok, result: prior.result, error: prior.error, idempotentReplay: true)
        }
        guard connected, scenario != .offline else { throw TransportError.offline }
        if scenario == .commandFailure {
            let response = CommandResponseEnvelope(ok: false, result: nil, error: RemoteErrorPayload(code: "PROVIDER_UNAVAILABLE", message: "Mock provider unavailable", retryable: true, details: nil), idempotentReplay: nil)
            processedCommands[command.commandId] = response
            return response
        }

        let response: CommandResponseEnvelope
        switch command.action {
        case "getStatus":
            response = success(["machineId": .string(machineId), "latestSequence": .number(Double(sequence))])
        case "listRuntimes":
            response = try success(runtimes)
        case "listInstances":
            response = try success(instances.filter { $0.runtimeId == command.runtimeId })
        case "listSessions":
            response = try success(sessions.filter { $0.instanceId == command.instanceId })
        case "loadRecentMessages":
            let limit = Int(command.payload["limit"]?.intValue ?? 40)
            response = try success(Array(history[command.sessionId ?? "", default: []].suffix(max(1, min(limit, 100)))))
        case "loadMessagesBefore":
            let limit = Int(command.payload["limit"]?.intValue ?? 40)
            let before = command.payload["before"]?.objectValue
            let beforeDate = before?["createdAt"]?.stringValue.flatMap(RemoteAIDate.parse)
            let beforeId = before?["messageId"]?.stringValue
            let eligible = history[command.sessionId ?? "", default: []].filter { message in
                guard let beforeDate, let beforeId else { return false }
                return message.createdAt < beforeDate || (message.createdAt == beforeDate && message.messageId < beforeId)
            }
            response = try success(Array(eligible.suffix(max(1, min(limit, 100)))))
        case "getChangesAfterCursor":
            let cursor = command.payload["cursor"]?.intValue ?? 0
            let limit = Int(command.payload["limit"]?.intValue ?? 500)
            let events = Array(eventLog.filter { $0.sequence > cursor }.sorted { $0.sequence < $1.sequence }.prefix(max(1, min(limit, 1000))))
            response = try success(DeltaSyncResult(events: events, nextCursor: events.last?.sequence ?? cursor, hasMore: eventLog.filter { $0.sequence > (events.last?.sequence ?? cursor) }.isEmpty == false))
        case "createSession":
            if command.runtimeId == "runtime.web" {
                response = success(["registrationRequired": .bool(true)])
            } else {
                let session = ServerSession(sessionId: "session-\(UUID().uuidString.lowercased())", runtimeId: command.runtimeId, instanceId: command.instanceId, externalId: nil, title: command.payload["title"]?.stringValue ?? "New Session", canonicalUrl: nil, status: "idle", metadata: [:], createdAt: Date(), updatedAt: Date(), lastVisited: Date())
                sessions.append(session)
                response = try success(session)
                await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: session.sessionId, type: "SESSION_CREATED", payload: try JSONValue.encode(session).objectValue ?? [:])
            }
        case "sendMessage":
            let text = command.payload["text"]?.stringValue ?? ""
            let sessionId = command.sessionId ?? ""
            let user = ServerMessage(messageId: command.commandId.uuidString, sessionId: sessionId, role: "user", content: text, externalId: nil, createdAt: Date())
            history[sessionId, default: []].append(user)
            Task { await self.simulateResponse(for: command, user: user) }
            response = success(["accepted": .bool(true), "sessionId": .string(sessionId), "messageId": .string(user.messageId)])
        case "stopGeneration", "stopSession":
            await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: command.sessionId, type: "GENERATION_STOPPED", payload: ["ok": .bool(true)])
            response = success(["stopped": .bool(true)])
        case "resumeSession", "getSessionStatus", "openConversation", "focusConversation", "registerCurrentPage", "unregisterConversation", "createConversation":
            response = success(["ok": .bool(true)])
        default:
            response = CommandResponseEnvelope(ok: false, result: nil, error: RemoteErrorPayload(code: "INVALID_COMMAND", message: "Unsupported mock action", retryable: false, details: nil), idempotentReplay: nil)
        }
        processedCommands[command.commandId] = response
        return response
    }

    private func simulateResponse(for command: RemoteCommand, user: ServerMessage) async {
        guard let sessionId = command.sessionId else { return }
        await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "GENERATION_STARTED", payload: ["provider": .string("mock")])
        await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "MESSAGE_ADDED", payload: (try? JSONValue.encode(user).objectValue) ?? [:])
        await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "TOOL_STARTED", payload: ["provider": .string("mock"), "tool": .string(command.runtimeId == "runtime.web" ? "Web Adapter" : "DevSpace")])
        let responseId = "message-\(UUID().uuidString.lowercased())"
        var text = ""
        for chunk in ["Remote ", "AI ", "mock ", "streaming ", "response."] {
            try? await Task.sleep(nanoseconds: 70_000_000)
            text += chunk
            await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "MESSAGE_UPDATED", payload: ["messageId": .string(responseId), "role": .string("assistant"), "content": .string(text), "partial": .bool(true), "provider": .string("mock")])
        }
        let assistant = ServerMessage(messageId: responseId, sessionId: sessionId, role: "assistant", content: text, externalId: nil, createdAt: Date())
        history[sessionId, default: []].append(assistant)
        await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "MESSAGE_ADDED", payload: (try? JSONValue.encode(assistant).objectValue) ?? [:])
        await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "TOOL_FINISHED", payload: ["provider": .string("mock"), "tool": .string(command.runtimeId == "runtime.web" ? "Web Adapter" : "DevSpace"), "summary": .string("384 tests passed")])
        await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "GENERATION_STOPPED", payload: ["provider": .string("mock"), "ok": .bool(true)])
        if scenario == .duplicateEvent, let last = eventLog.last { continuation?.yield(last) }
        if scenario == .sequenceGap {
            sequence += 2
            await emit(runtimeId: command.runtimeId, instanceId: command.instanceId, sessionId: sessionId, type: "TRANSPORT_STATUS", payload: ["state": .string("gap-demo")])
        }
        if scenario == .disconnect { connected = false }
    }

    private func emit(runtimeId: String, instanceId: String, sessionId: String?, type: String, payload: [String: JSONValue]) async {
        sequence += 1
        let event = RemoteEvent(protocolVersion: 1, eventId: UUID(), sequence: sequence, machineId: machineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, type: type, payload: payload, createdAt: Date())
        eventLog.append(event)
        continuation?.yield(event)
    }

    private func success(_ result: [String: JSONValue]) -> CommandResponseEnvelope {
        CommandResponseEnvelope(ok: true, result: .object(result), error: nil, idempotentReplay: nil)
    }

    private func success<T: Encodable>(_ result: T) throws -> CommandResponseEnvelope {
        CommandResponseEnvelope(ok: true, result: try JSONValue.encode(result), error: nil, idempotentReplay: nil)
    }
}
