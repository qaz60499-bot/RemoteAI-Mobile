import Foundation
import SwiftUI

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var machine = MachineMetadata(id: "my-pc", name: "My PC", state: .connecting)
    @Published var runtimes: [RuntimeDescriptor] = []
    @Published var instances: [InstanceDescriptor] = []
    @Published var sessions: [SessionDescriptor] = []
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var commandStates: [UUID: CommandState] = [:]
    @Published var errors: [String: String] = [:]
    @Published var hasMoreBySession: [String: Bool] = [:]
    @Published var isPaired = false

    let transport: Transport
    let cache: SQLiteStore
    private var tracker = SequenceTracker()
    private var eventTask: Task<Void, Never>?
    private var deltaBuffers: [String: (id: String, text: String)] = [:]
    private var flushTask: Task<Void, Never>?

    init(transport: Transport, cache: SQLiteStore) { self.transport = transport; self.cache = cache }

    static func makeDefault() -> WorkspaceStore {
        let cache = (try? SQLiteStore.appStore()) ?? (try! SQLiteStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("remoteai-cache.sqlite3")))
        let config = RemoteAIConfig.loadMetadata()
        let useMock = ProcessInfo.processInfo.arguments.contains("-UITestMockMode") || KeychainStore.shared.load(account: config.machineId) == nil
        let transport: Transport = useMock ? MockTransport() : CloudflareTransport(config: config)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: config.machineId, name: "My PC", state: .connecting)
        return store
    }

    func start() async {
        await loadCachedFirst()
        isPaired = KeychainStore.shared.load(account: machine.id) != nil
        do {
            try await transport.connect(); machine.state = .online
            await recoverDelta()
            let stream = await transport.eventStream()
            eventTask?.cancel(); eventTask = Task { [weak self] in
                for await event in stream { guard !Task.isCancelled else { break }; await self?.ingest(event) }
            }
        } catch { machine.state = .offline; errors["connection"] = error.localizedDescription }
    }

    func suspend() async { await transport.disconnect(); machine.state = .offline }
    func resumeFromForeground() async { machine.state = .connecting; await start() }

    func loadSession(_ sessionId: String) async {
        if messagesBySession[sessionId] == nil {
            let local = (try? await cache.recentMessages(sessionId: sessionId, limit: 50)) ?? []
            messagesBySession[sessionId] = local
        }
        guard machine.state == .online else { return }
        do {
            let page = try await transport.loadRecent(sessionId: sessionId, limit: 50)
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId); hasMoreBySession[sessionId] = page.hasMore
        } catch { errors[sessionId] = error.localizedDescription }
    }

    func loadOlder(_ sessionId: String) async {
        guard let first = messagesBySession[sessionId]?.first, hasMoreBySession[sessionId] != false else { return }
        do {
            let page: Page<ChatMessage>
            if machine.state == .online { page = try await transport.loadBefore(sessionId: sessionId, before: first.sequence, limit: 40) }
            else { let local = try await cache.messagesBefore(sessionId: sessionId, before: first.sequence, limit: 40); page = Page(items: local, beforeCursor: local.first?.sequence, hasMore: local.count == 40) }
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId); hasMoreBySession[sessionId] = page.hasMore
        } catch { errors[sessionId] = error.localizedDescription }
    }

    func send(text: String, runtimeId: String, instanceId: String, sessionId: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { return }
        guard machine.state == .online else { try? await cache.saveDraft(trimmed, sessionId: sessionId); errors[sessionId] = "PC Offline — draft saved. Tap Send after reconnecting."; return }
        let commandId = UUID(); commandStates[commandId] = .pending
        let optimistic = ChatMessage(id: commandId.uuidString, sessionId: sessionId, sequence: tracker.lastSequence + 1, role: .user, kind: .text, text: trimmed, toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
        merge([optimistic], into: sessionId); try? await cache.upsertMessages([optimistic])
        let command = RemoteCommand.make(machineId: machine.id, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "sendMessage", payload: ["text": .string(trimmed)], commandId: commandId)
        do { commandStates[commandId] = try await transport.send(command) } catch { commandStates[commandId] = .failed; errors[sessionId] = error.localizedDescription }
    }

    func retry(message: ChatMessage, runtimeId: String, instanceId: String) async { await send(text: message.text, runtimeId: runtimeId, instanceId: instanceId, sessionId: message.sessionId) }
    func stop(runtimeId: String, instanceId: String, sessionId: String) async {
        let command = RemoteCommand.make(machineId: machine.id, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "stopGeneration")
        commandStates[command.commandId] = .pending
        do { commandStates[command.commandId] = try await transport.send(command) } catch { commandStates[command.commandId] = .failed }
    }

    func createSession(runtime: RuntimeDescriptor, instance: InstanceDescriptor, title: String, provider: String = "", model: String = "", credentialProfileId: String = "") async {
        let id = UUID().uuidString; let s = SessionDescriptor(id: id, instanceId: instance.id, title: title.isEmpty ? "New Session" : title, state: .idle, updatedAt: Date()); sessions.insert(s, at: 0); await persistMetadata()
        let payload: [String: JSONValue] = ["provider": .string(provider), "model": .string(model), "credentialProfileId": .string(credentialProfileId)]
        let c = RemoteCommand.make(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id, sessionId: id, action: "createSession", payload: payload)
        if machine.state == .online { _ = try? await transport.send(c) }
    }

    func savePairing(baseURL: URL, code: String) async throws {
        let response = try await PairingClient().pair(baseURL: baseURL, code: code)
        guard let data = Data(base64Encoded: response.sharedSecretBase64), data.count >= 16 else { throw TransportError.malformedData }
        try KeychainStore.shared.save(data, account: response.machineId)
        let config = RemoteAIConfig(relayBaseURL: baseURL, machineId: response.machineId)
        config.saveMetadata()
        machine = MachineMetadata(id: response.machineId, name: machine.name, state: machine.state)
        isPaired = true
    }

    func draft(sessionId: String) async -> String { (try? await cache.draft(sessionId: sessionId)) ?? "" }
    func clearError(sessionId: String) { errors[sessionId] = nil }

    private func loadCachedFirst() async {
        if let m: MachineMetadata = try? await cache.get(MachineMetadata.self, key: "machine") { machine = m; machine.state = .connecting }
        if let v: [RuntimeDescriptor] = try? await cache.get([RuntimeDescriptor].self, key: "runtimes") { runtimes = v }
        if let v: [InstanceDescriptor] = try? await cache.get([InstanceDescriptor].self, key: "instances") { instances = v }
        if let v: [SessionDescriptor] = try? await cache.get([SessionDescriptor].self, key: "sessions") { sessions = v }
        tracker = SequenceTracker(lastSequence: (try? await cache.lastSequence()) ?? 0)
        if runtimes.isEmpty { seedFixtureMetadata(); await persistMetadata() }
    }

    private func seedFixtureMetadata() {
        runtimes = [.init(id: "web", machineId: machine.id, kind: .web, name: "Web"), .init(id: "cloud", machineId: machine.id, kind: .cloudCode, name: "Cloud Code"), .init(id: "codex", machineId: machine.id, kind: .codex, name: "Codex")]
        instances = [
            .init(id: "chatgpt", runtimeId: "web", name: "ChatGPT", subtitle: "Web runtime"), .init(id: "photo", runtimeId: "web", name: "Photo SaaS", subtitle: "2 conversations"), .init(id: "excel", runtimeId: "web", name: "Excel SaaS", subtitle: "1 conversation"),
            .init(id: "cloud-photo", runtimeId: "cloud", name: "Photo", subtitle: "Cloud Code"),
            .init(id: "codex1", runtimeId: "codex", name: "Codex1", subtitle: nil), .init(id: "codex2", runtimeId: "codex", name: "Codex2", subtitle: nil), .init(id: "codex6", runtimeId: "codex", name: "Codex6", subtitle: "1 session"), .init(id: "codex11", runtimeId: "codex", name: "Codex11", subtitle: nil), .init(id: "kali-codex", runtimeId: "codex", name: "Kali Codex", subtitle: nil), .init(id: "linux-codex", runtimeId: "codex", name: "Linux Codex", subtitle: nil)]
        sessions = [.init(id: "photo-upload", instanceId: "photo", title: "上传性能优化", state: .idle, updatedAt: Date()), .init(id: "photo-ios", instanceId: "photo", title: "手机 APP", state: .idle, updatedAt: Date()), .init(id: "excel-permission", instanceId: "excel", title: "权限测试", state: .idle, updatedAt: Date()), .init(id: "cloud-photo-a", instanceId: "cloud-photo", title: "Session A", state: .idle, updatedAt: Date()), .init(id: "codex6-a", instanceId: "codex6", title: "Session A", state: .idle, updatedAt: Date())]
    }
    private func persistMetadata() async { try? await cache.put(machine, key: "machine"); try? await cache.put(runtimes, key: "runtimes"); try? await cache.put(instances, key: "instances"); try? await cache.put(sessions, key: "sessions") }

    private func ingest(_ event: RemoteEvent) async {
        let decision = tracker.ingest(event.sequence); if decision.duplicate { return }; if decision.gap { await recoverDelta(); return }
        try? await cache.setLastSequence(tracker.lastSequence)
        guard let sessionId = event.sessionId else { return }
        switch event.type {
        case "message.delta": bufferDelta(sessionId: sessionId, id: event.payload["messageId"]?.stringValue ?? UUID().uuidString, delta: event.payload["delta"]?.stringValue ?? "")
        case "message.completed":
            flushDeltas(); let id = event.payload["messageId"]?.stringValue ?? UUID().uuidString; let text = event.payload["text"]?.stringValue ?? ""; let m = ChatMessage(id: id, sessionId: sessionId, sequence: event.sequence, role: .assistant, kind: .text, text: text, toolName: nil, toolStatus: nil, detail: nil, createdAt: event.createdAt); merge([m], into: sessionId); try? await cache.upsertMessages([m])
        case "tool.event":
            let name = event.payload["toolName"]?.stringValue ?? "Tool"; let status = event.payload["status"]?.stringValue ?? "Running"; let m = ChatMessage(id: event.eventId.uuidString, sessionId: sessionId, sequence: event.sequence, role: .tool, kind: .toolEvent, text: "", toolName: name, toolStatus: status, detail: event.payload["detail"]?.stringValue, createdAt: event.createdAt); merge([m], into: sessionId); try? await cache.upsertMessages([m])
        default: break
        }
    }

    private func recoverDelta() async {
        let base = (try? await cache.lastSequence()) ?? max(0, tracker.lastSequence - 1)
        guard let result = try? await transport.delta(after: base) else { return }
        var recovery = SequenceTracker(lastSequence: base)
        for event in result.events.sorted(by: { $0.sequence < $1.sequence }) { let d = recovery.ingest(event.sequence); if !d.duplicate && !d.gap { await ingestRecovered(event) } }
        tracker = SequenceTracker(lastSequence: max(recovery.lastSequence, result.latestSequence)); try? await cache.setLastSequence(tracker.lastSequence)
    }
    private func ingestRecovered(_ event: RemoteEvent) async { guard let sessionId = event.sessionId else { return }; if event.type == "message.completed" { let m = ChatMessage(id: event.payload["messageId"]?.stringValue ?? event.eventId.uuidString, sessionId: sessionId, sequence: event.sequence, role: .assistant, kind: .text, text: event.payload["text"]?.stringValue ?? "", toolName: nil, toolStatus: nil, detail: nil, createdAt: event.createdAt); merge([m], into: sessionId); try? await cache.upsertMessages([m]) } }

    private func bufferDelta(sessionId: String, id: String, delta: String) {
        var current = deltaBuffers[sessionId] ?? (id, ""); current.text += delta; deltaBuffers[sessionId] = current
        if flushTask == nil { flushTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 90_000_000); self?.flushDeltas() } }
    }
    private func flushDeltas() {
        for (sessionId, item) in deltaBuffers { var list = messagesBySession[sessionId, default: []]; if let i = list.firstIndex(where: { $0.id == item.id }) { list[i].text = item.text } else { list.append(ChatMessage(id: item.id, sessionId: sessionId, sequence: tracker.lastSequence, role: .assistant, kind: .text, text: item.text, toolName: nil, toolStatus: "Streaming", detail: nil, createdAt: Date())) }; messagesBySession[sessionId] = list }
        deltaBuffers.removeAll(); flushTask = nil
    }
    private func merge(_ incoming: [ChatMessage], into sessionId: String) { var map = Dictionary(uniqueKeysWithValues: messagesBySession[sessionId, default: []].map { ($0.id, $0) }); for m in incoming { map[m.id] = m }; messagesBySession[sessionId] = map.values.sorted { $0.sequence == $1.sequence ? $0.createdAt < $1.createdAt : $0.sequence < $1.sequence } }
}
