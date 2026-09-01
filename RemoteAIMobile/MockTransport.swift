import Foundation

enum MockScenario: String, CaseIterable { case normal, commandFailure, disconnect, duplicateEvent, sequenceGap, offline }

actor MockTransport: Transport {
    private var connected = false
    private var scenario: MockScenario
    private var sequence: Int64 = 1100
    private var continuation: AsyncStream<RemoteEvent>.Continuation?
    private var stream: AsyncStream<RemoteEvent>?
    private var processedCommands: [UUID: CommandState] = [:]
    private var history: [String: [ChatMessage]] = [:]
    private var eventLog: [RemoteEvent] = []

    init(scenario: MockScenario = .normal, historyCount: Int = 1200) {
        self.scenario = scenario
        var messages: [ChatMessage] = []
        for i in 1...historyCount {
            let assistant = i % 2 == 0
            messages.append(ChatMessage(id: "mock-\(i)", sessionId: "photo-upload", sequence: Int64(i), role: assistant ? .assistant : .user, kind: .text, text: assistant ? "Mock assistant response \(i). This verifies long-history pagination without rendering everything at once." : "Mock user message \(i)", toolName: nil, toolStatus: nil, detail: nil, createdAt: Date(timeIntervalSinceNow: Double(i-historyCount) * 30)))
        }
        history["photo-upload"] = messages
        history["photo-ios"] = Array(messages.suffix(80)).map { m in var c = m; return ChatMessage(id: "ios-\(c.id)", sessionId: "photo-ios", sequence: c.sequence, role: c.role, kind: c.kind, text: c.text, toolName: c.toolName, toolStatus: c.toolStatus, detail: c.detail, createdAt: c.createdAt) }
        history["cloud-photo-a"] = Array(messages.suffix(60)).map { m in ChatMessage(id: "cloud-\(m.id)", sessionId: "cloud-photo-a", sequence: m.sequence, role: m.role, kind: m.kind, text: m.text, toolName: m.toolName, toolStatus: m.toolStatus, detail: m.detail, createdAt: m.createdAt) }
        history["codex6-a"] = Array(messages.suffix(60)).map { m in ChatMessage(id: "codex-\(m.id)", sessionId: "codex6-a", sequence: m.sequence, role: m.role, kind: m.kind, text: m.text, toolName: m.toolName, toolStatus: m.toolStatus, detail: m.detail, createdAt: m.createdAt) }
    }

    var isConnected: Bool { connected }
    func setScenario(_ value: MockScenario) { scenario = value }
    func connect() async throws { guard scenario != .offline else { throw TransportError.offline }; connected = true }
    func disconnect() async { connected = false }
    func eventStream() async -> AsyncStream<RemoteEvent> {
        if let stream { return stream }
        var captured: AsyncStream<RemoteEvent>.Continuation?
        let s = AsyncStream<RemoteEvent> { captured = $0 }
        continuation = captured
        stream = s
        return s
    }

    func send(_ command: RemoteCommand) async throws -> CommandState {
        if let prior = processedCommands[command.commandId] { return prior }
        guard connected, scenario != .offline else { throw TransportError.offline }
        if scenario == .commandFailure { processedCommands[command.commandId] = .failed; throw TransportError.badResponse(503) }
        processedCommands[command.commandId] = .acknowledged
        await emit(type: "command.acknowledged", command: command, payload: ["commandId": .string(command.commandId.uuidString)])
        if command.action == "sendMessage" {
            let text = command.payload["text"]?.stringValue ?? ""
            let user = ChatMessage(id: command.commandId.uuidString, sessionId: command.sessionId ?? "", sequence: nextSequence(), role: .user, kind: .text, text: text, toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
            history[user.sessionId, default: []].append(user)
            Task { await self.simulateResponse(for: command) }
        } else if command.action == "stopGeneration" {
            await emit(type: "generation.stopped", command: command, payload: [:])
        } else if command.action == "createSession" {
            await emit(type: "session.created", command: command, payload: ["title": .string("New Session")])
        }
        return .acknowledged
    }

    private func simulateResponse(for command: RemoteCommand) async {
        guard let sessionId = command.sessionId else { return }
        await emit(type: "command.executing", command: command, payload: ["commandId": .string(command.commandId.uuidString)])
        let toolSeq = nextSequence()
        let tool = ChatMessage(id: UUID().uuidString, sessionId: sessionId, sequence: toolSeq, role: .tool, kind: .toolEvent, text: "", toolName: command.runtimeId == "web" ? "Web Adapter" : "DevSpace", toolStatus: "Running", detail: "Mock tool event", createdAt: Date())
        history[sessionId, default: []].append(tool)
        await emitRaw(sessionId: sessionId, runtimeId: command.runtimeId, instanceId: command.instanceId, type: "tool.event", sequence: toolSeq, payload: ["toolName": .string(tool.toolName ?? "Tool"), "status": .string("Running")])
        let responseId = UUID().uuidString
        var text = ""
        for chunk in ["Remote ", "AI ", "mock ", "streaming ", "response."] {
            try? await Task.sleep(nanoseconds: 70_000_000); text += chunk
            await emitRaw(sessionId: sessionId, runtimeId: command.runtimeId, instanceId: command.instanceId, type: "message.delta", sequence: nextSequence(), payload: ["messageId": .string(responseId), "delta": .string(chunk)])
        }
        let finalSeq = nextSequence()
        let answer = ChatMessage(id: responseId, sessionId: sessionId, sequence: finalSeq, role: .assistant, kind: .text, text: text, toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
        history[sessionId, default: []].append(answer)
        await emitRaw(sessionId: sessionId, runtimeId: command.runtimeId, instanceId: command.instanceId, type: "message.completed", sequence: finalSeq, payload: ["messageId": .string(responseId), "text": .string(text)])
        await emitRaw(sessionId: sessionId, runtimeId: command.runtimeId, instanceId: command.instanceId, type: "tool.event", sequence: nextSequence(), payload: ["toolName": .string(tool.toolName ?? "Tool"), "status": .string("Completed"), "detail": .string("384 tests passed")])
        if scenario == .duplicateEvent, let last = eventLog.last { continuation?.yield(last) }
        if scenario == .sequenceGap { sequence += 2; await emitRaw(sessionId: sessionId, runtimeId: command.runtimeId, instanceId: command.instanceId, type: "sync.gap.demo", sequence: nextSequence(), payload: [:]) }
        if scenario == .disconnect { connected = false; continuation?.finish() }
        processedCommands[command.commandId] = .completed
    }

    func delta(after sequence: Int64) async throws -> DeltaSyncResult {
        let events = eventLog.filter { $0.sequence > sequence }.sorted { $0.sequence < $1.sequence }
        return DeltaSyncResult(events: events, latestSequence: events.last?.sequence ?? self.sequence)
    }
    func loadRecent(sessionId: String, limit: Int) async throws -> Page<ChatMessage> {
        let all = history[sessionId, default: []].sorted { $0.sequence < $1.sequence }; let items = Array(all.suffix(limit)); return Page(items: items, beforeCursor: items.first?.sequence, hasMore: all.count > items.count)
    }
    func loadBefore(sessionId: String, before: Int64, limit: Int) async throws -> Page<ChatMessage> {
        let eligible = history[sessionId, default: []].filter { $0.sequence < before }.sorted { $0.sequence < $1.sequence }; let items = Array(eligible.suffix(limit)); return Page(items: items, beforeCursor: items.first?.sequence, hasMore: eligible.count > items.count)
    }

    private func nextSequence() -> Int64 { sequence += 1; return sequence }
    private func emit(type: String, command: RemoteCommand, payload: [String: JSONValue]) async { await emitRaw(sessionId: command.sessionId, runtimeId: command.runtimeId, instanceId: command.instanceId, type: type, sequence: nextSequence(), payload: payload) }
    private func emitRaw(sessionId: String?, runtimeId: String, instanceId: String, type: String, sequence: Int64, payload: [String: JSONValue]) async {
        let e = RemoteEvent(protocolVersion: "1", eventId: UUID(), sequence: sequence, machineId: "my-pc", runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, type: type, payload: payload, createdAt: Date()); eventLog.append(e); continuation?.yield(e)
    }
}
