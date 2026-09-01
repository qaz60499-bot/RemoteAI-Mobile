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

    var transport: Transport
    let cache: SQLiteStore
    private var tracker = SequenceTracker()
    private var eventReplayGuard = BoundedReplayGuard(capacity: 8192)
    private var eventTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var streamingBuffers: [String: (id: String, text: String, sequence: Int64)] = [:]
    private var flushTask: Task<Void, Never>?

    init(transport: Transport, cache: SQLiteStore) {
        self.transport = transport
        self.cache = cache
    }

    static func makeDefault() -> WorkspaceStore {
        // Fail closed for persistence: if the protected Application Support store cannot open,
        // keep cache data in memory instead of writing it to an unprotected temporary file.
        let cache = (try? SQLiteStore.appStore()) ?? (try! SQLiteStore.inMemory())
        let config = RemoteAIConfig.loadMetadata()
        let useMock = ProcessInfo.processInfo.arguments.contains("-UITestMockMode") || !PairingKeyStore.isPaired(machineId: config.machineId)
        let transport: Transport = useMock ? MockTransport() : CloudflareTransport(config: config)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: config.machineId, name: "My PC", state: .connecting)
        return store
    }

    func start() async {
        await loadCachedFirst()
        isPaired = PairingKeyStore.isPaired(machineId: machine.id)
        installEventConsumer()
        do {
            try await transport.connect()
            machine.state = .online
            errors["connection"] = nil
            await recoverDelta()
            await refreshMetadata()
            startConnectionMonitor()
        } catch {
            machine.state = .offline
            errors["connection"] = error.localizedDescription
            startConnectionMonitor()
        }
    }

    func suspend() async {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        await transport.disconnect()
        machine.state = .offline
    }

    func resumeFromForeground() async {
        machine.state = .connecting
        await start()
    }

    func loadSession(_ sessionId: String) async {
        if messagesBySession[sessionId] == nil {
            let local = (try? await cache.recentMessages(sessionId: sessionId, limit: 50)) ?? []
            messagesBySession[sessionId] = local
        }
        guard machine.state == .online, let context = contextForSession(sessionId) else { return }
        do {
            let page = try await transport.loadRecent(machineId: machine.id, runtimeId: context.runtime.id, instanceId: context.instance.id, sessionId: sessionId, limit: 50)
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId)
            hasMoreBySession[sessionId] = page.hasMore
        } catch {
            errors[sessionId] = error.localizedDescription
        }
    }

    func loadOlder(_ sessionId: String) async {
        guard let first = messagesBySession[sessionId]?.first, hasMoreBySession[sessionId] != false else { return }
        do {
            let page: Page<ChatMessage>
            if machine.state == .online, let context = contextForSession(sessionId) {
                page = try await transport.loadBefore(machineId: machine.id, runtimeId: context.runtime.id, instanceId: context.instance.id, sessionId: sessionId, before: first.cursor, limit: 40)
            } else {
                let local = try await cache.messagesBefore(sessionId: sessionId, before: first.cursor, limit: 40)
                page = Page(items: local, beforeCursor: local.first?.cursor, hasMore: local.count == 40)
            }
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId)
            hasMoreBySession[sessionId] = page.hasMore
        } catch {
            errors[sessionId] = error.localizedDescription
        }
    }

    func send(text: String, runtimeId: String, instanceId: String, sessionId: String, commandId: UUID = UUID()) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard machine.state == .online else {
            try? await cache.saveDraft(trimmed, sessionId: sessionId)
            errors[sessionId] = "PC Offline — draft saved. Tap Send after reconnecting."
            return
        }

        commandStates[commandId] = .pending
        let optimistic = ChatMessage(id: commandId.uuidString, sessionId: sessionId, sequence: nil, role: .user, kind: .text, text: trimmed, toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
        merge([optimistic], into: sessionId)
        try? await cache.upsertMessages([optimistic])
        let command = RemoteCommand.make(machineId: machine.id, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "sendMessage", payload: ["text": .string(trimmed)], commandId: commandId)
        commandStates[commandId] = .executing
        do {
            commandStates[commandId] = try await transport.send(command)
            try? await cache.saveDraft("", sessionId: sessionId)
        } catch TransportError.disconnected {
            commandStates[commandId] = .unknown
            errors[sessionId] = "Connection dropped after send. Delivery is unknown; retry reuses the same command ID."
        } catch {
            commandStates[commandId] = .failed
            errors[sessionId] = error.localizedDescription
        }
    }

    func retry(message: ChatMessage, runtimeId: String, instanceId: String) async {
        let commandId = UUID(uuidString: message.id) ?? UUID()
        await send(text: message.text, runtimeId: runtimeId, instanceId: instanceId, sessionId: message.sessionId, commandId: commandId)
    }

    func stop(runtimeId: String, instanceId: String, sessionId: String) async {
        let command = RemoteCommand.make(machineId: machine.id, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "stopGeneration")
        commandStates[command.commandId] = .pending
        do { commandStates[command.commandId] = try await transport.send(command) }
        catch { commandStates[command.commandId] = .failed; errors[sessionId] = error.localizedDescription }
    }

    func createSession(runtime: RuntimeDescriptor, instance: InstanceDescriptor, title: String, provider: String = "", model: String = "", credentialProfileId: String = "") async {
        let payload: [String: JSONValue] = [
            "title": .string(title.isEmpty ? "New Session" : title),
            "provider": .string(provider),
            "model": .string(model),
            "credentialProfileId": .string(credentialProfileId)
        ]
        guard machine.state == .online else {
            errors[instance.id] = "PC Offline — new sessions are not queued automatically."
            return
        }
        do {
            if let created = try await transport.createSession(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id, payload: payload) {
                sessions.removeAll { $0.id == created.id }
                sessions.insert(created, at: 0)
                await persistMetadata()
            } else if transport is MockTransport {
                let local = SessionDescriptor(id: UUID().uuidString, instanceId: instance.id, title: title.isEmpty ? (runtime.kind == .web ? "New Chat" : "New Session") : title, state: .idle, updatedAt: Date())
                sessions.insert(local, at: 0)
                await persistMetadata()
            } else {
                await refreshMetadata()
            }
        } catch {
            errors[instance.id] = error.localizedDescription
        }
    }

    func savePairing(baseURL: URL, machineId: String, code: String) async throws {
        eventTask?.cancel()
        connectionMonitorTask?.cancel()
        await transport.disconnect()
        let previousMachineId = machine.id
        let result = try await RelayPairingClient().pair(baseURL: baseURL, machineId: machineId, pairingCode: code)

        if previousMachineId != result.machineId {
            PairingKeyStore.deletePairing(machineId: previousMachineId)
            try await cache.clearAll()
            runtimes.removeAll()
            instances.removeAll()
            sessions.removeAll()
            messagesBySession.removeAll()
            hasMoreBySession.removeAll()
            tracker = SequenceTracker()
            eventReplayGuard = BoundedReplayGuard(capacity: 8192)
        }

        let config = RemoteAIConfig(relayBaseURL: baseURL, machineId: result.machineId)
        config.saveMetadata()
        transport = CloudflareTransport(config: config)
        machine = MachineMetadata(id: result.machineId, name: machine.name, state: .connecting)
        isPaired = true
        await start()
    }

    func draft(sessionId: String) async -> String { (try? await cache.draft(sessionId: sessionId)) ?? "" }
    func clearError(sessionId: String) { errors[sessionId] = nil }

    private func installEventConsumer() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.eventStream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.ingest(event)
            }
        }
    }

    private func startConnectionMonitor() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { break }
                if !(await self.transport.isConnected) {
                    self.machine.state = .connecting
                    do {
                        try await self.transport.connect()
                        self.machine.state = .online
                        self.errors["connection"] = nil
                        await self.recoverDelta()
                        await self.refreshMetadata()
                    } catch {
                        self.machine.state = .offline
                        self.errors["connection"] = error.localizedDescription
                    }
                }
            }
        }
    }

    private func refreshMetadata() async {
        guard machine.state == .online else { return }
        do {
            let remoteRuntimes = try await transport.listRuntimes(machineId: machine.id)
            var remoteInstances: [InstanceDescriptor] = []
            var remoteSessions: [SessionDescriptor] = []
            for runtime in remoteRuntimes {
                let rows = try await transport.listInstances(machineId: machine.id, runtimeId: runtime.id)
                remoteInstances.append(contentsOf: rows)
                for instance in rows {
                    let sessionRows = try await transport.listSessions(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id)
                    remoteSessions.append(contentsOf: sessionRows)
                }
            }
            if !remoteRuntimes.isEmpty { runtimes = remoteRuntimes }
            if !remoteInstances.isEmpty { instances = remoteInstances }
            sessions = remoteSessions.sorted { $0.updatedAt > $1.updatedAt }
            await persistMetadata()
        } catch {
            errors["sync"] = error.localizedDescription
        }
    }

    private func contextForSession(_ sessionId: String) -> (runtime: RuntimeDescriptor, instance: InstanceDescriptor)? {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let instance = instances.first(where: { $0.id == session.instanceId }),
              let runtime = runtimes.first(where: { $0.id == instance.runtimeId }) else { return nil }
        return (runtime, instance)
    }

    private func loadCachedFirst() async {
        if let cached: MachineMetadata = try? await cache.get(MachineMetadata.self, key: "machine") {
            machine = MachineMetadata(id: cached.id, name: cached.name, state: .connecting)
        }
        if let value: [RuntimeDescriptor] = try? await cache.get([RuntimeDescriptor].self, key: "runtimes") { runtimes = value }
        if let value: [InstanceDescriptor] = try? await cache.get([InstanceDescriptor].self, key: "instances") { instances = value }
        if let value: [SessionDescriptor] = try? await cache.get([SessionDescriptor].self, key: "sessions") { sessions = value }
        tracker = SequenceTracker(lastSequence: (try? await cache.lastSequence()) ?? 0)
        if runtimes.isEmpty { seedFixtureMetadata(); await persistMetadata() }
    }

    private func seedFixtureMetadata() {
        runtimes = [
            RuntimeDescriptor(id: "runtime.web", machineId: machine.id, kind: .web, name: "Web"),
            RuntimeDescriptor(id: "runtime.cloudcode", machineId: machine.id, kind: .cloudCode, name: "Cloud Code"),
            RuntimeDescriptor(id: "runtime.codex", machineId: machine.id, kind: .codex, name: "Codex")
        ]
        instances = [
            InstanceDescriptor(id: "web.chatgpt", runtimeId: "runtime.web", name: "ChatGPT", subtitle: "Web runtime"),
            InstanceDescriptor(id: "photo", runtimeId: "runtime.web", name: "Photo SaaS", subtitle: "2 conversations"),
            InstanceDescriptor(id: "excel", runtimeId: "runtime.web", name: "Excel SaaS", subtitle: "1 conversation"),
            InstanceDescriptor(id: "cloud-photo", runtimeId: "runtime.cloudcode", name: "Photo", subtitle: "Cloud Code"),
            InstanceDescriptor(id: "codex1", runtimeId: "runtime.codex", name: "Codex1", subtitle: nil),
            InstanceDescriptor(id: "codex2", runtimeId: "runtime.codex", name: "Codex2", subtitle: nil),
            InstanceDescriptor(id: "codex6", runtimeId: "runtime.codex", name: "Codex6", subtitle: "1 session"),
            InstanceDescriptor(id: "codex11", runtimeId: "runtime.codex", name: "Codex11", subtitle: nil),
            InstanceDescriptor(id: "kali-codex", runtimeId: "runtime.codex", name: "Kali Codex", subtitle: nil),
            InstanceDescriptor(id: "linux-codex", runtimeId: "runtime.codex", name: "Linux Codex", subtitle: nil)
        ]
        sessions = [
            SessionDescriptor(id: "photo-upload", instanceId: "photo", title: "上传性能优化", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "photo-ios", instanceId: "photo", title: "手机 APP", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "excel-permission", instanceId: "excel", title: "权限测试", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "cloud-photo-a", instanceId: "cloud-photo", title: "Session A", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "codex6-a", instanceId: "codex6", title: "Session A", state: .idle, updatedAt: Date())
        ]
    }

    private func persistMetadata() async {
        try? await cache.put(machine, key: "machine")
        try? await cache.put(runtimes, key: "runtimes")
        try? await cache.put(instances, key: "instances")
        try? await cache.put(sessions, key: "sessions")
    }

    private func ingest(_ event: RemoteEvent) async {
        do {
            try ProtocolSecurity.validate(event, expectedMachineId: machine.id)
        } catch {
            errors["sync"] = error.localizedDescription
            return
        }
        let priorSequence = tracker.lastSequence
        let decision = tracker.ingest(event.sequence)
        if decision.duplicate { return }
        if decision.gap {
            await recoverDelta()
            return
        }
        guard eventReplayGuard.accept(event.eventId.uuidString.lowercased()) else {
            tracker = SequenceTracker(lastSequence: priorSequence)
            errors["sync"] = TransportError.replayDetected.localizedDescription
            return
        }
        await applyEvent(event)
        try? await cache.setLastSequence(event.sequence)
    }

    private func recoverDelta() async {
        guard machine.state == .online else { return }
        var cursor = (try? await cache.lastSequence()) ?? 0
        do {
            while true {
                let result = try await transport.delta(machineId: machine.id, after: cursor)
                for event in result.events where event.sequence > cursor {
                    guard eventReplayGuard.accept(event.eventId.uuidString.lowercased()) else { throw TransportError.replayDetected }
                    await applyEvent(event)
                    cursor = event.sequence
                    try? await cache.setLastSequence(cursor)
                }
                cursor = max(cursor, result.nextCursor)
                try? await cache.setLastSequence(cursor)
                if !result.hasMore { break }
            }
            tracker = SequenceTracker(lastSequence: cursor)
        } catch {
            errors["sync"] = error.localizedDescription
        }
    }

    private func applyEvent(_ event: RemoteEvent) async {
        guard let sessionId = event.sessionId else {
            if ["INSTANCE_UPDATED", "RUNTIME_STATUS", "SESSION_CREATED", "SESSION_UPDATED", "SESSION_RENAMED", "SESSION_STATUS", "WEB_PAGE_REGISTERED", "WEB_PAGE_UNREGISTERED"].contains(event.type) {
                await refreshMetadata()
            }
            return
        }

        switch event.type {
        case "MESSAGE_UPDATED":
            let content = event.payload["content"]?.stringValue ?? ""
            let id = event.payload["messageId"]?.stringValue ?? streamingBuffers[sessionId]?.id ?? "stream-\(sessionId)"
            bufferStreaming(sessionId: sessionId, id: id, content: content, sequence: event.sequence)
        case "MESSAGE_ADDED":
            if let server = try? JSONValue.object(event.payload).decode(ServerMessage.self) {
                let base = server.chatMessage
                if base.role == .assistant { discardStreamingPlaceholder(sessionId: sessionId) }
                if base.role == .user { await reconcileOptimisticUserEcho(base, sessionId: sessionId) }
                let message = ChatMessage(id: base.id, sessionId: base.sessionId, sequence: event.sequence, role: base.role, kind: base.kind, text: base.text, toolName: nil, toolStatus: nil, detail: nil, createdAt: base.createdAt)
                merge([message], into: sessionId)
                try? await cache.upsertMessages([message])
            }
        case "TOOL_STARTED", "TOOL_FINISHED":
            let completed = event.type == "TOOL_FINISHED"
            let toolValue = event.payload["tool"]
            let toolName = toolValue?.stringValue ?? toolValue?.objectValue?["name"]?.stringValue ?? toolValue?.objectValue?["type"]?.stringValue ?? "Tool"
            let detail = event.payload["summary"]?.stringValue ?? event.payload["provider"]?.stringValue
            let message = ChatMessage(id: event.eventId.uuidString, sessionId: sessionId, sequence: event.sequence, role: .tool, kind: .toolEvent, text: "", toolName: toolName, toolStatus: completed ? "Completed" : "Running", detail: detail, createdAt: event.createdAt)
            merge([message], into: sessionId)
            try? await cache.upsertMessages([message])
        case "GENERATION_STARTED":
            setSessionState(sessionId, .busy)
        case "GENERATION_STOPPED":
            flushStreaming(sessionId: sessionId)
            setSessionState(sessionId, .idle)
        case "SESSION_CREATED", "SESSION_UPDATED", "SESSION_RENAMED", "SESSION_STATUS", "WEB_PAGE_REGISTERED", "WEB_PAGE_UNREGISTERED", "WEB_BINDING_CHANGED":
            await refreshMetadata()
        case "COMMAND_RESULT", "COMMAND_REJECTED":
            if let raw = event.payload["commandId"]?.stringValue, let commandId = UUID(uuidString: raw) {
                commandStates[commandId] = event.type == "COMMAND_RESULT" ? .completed : .failed
            }
        default:
            break
        }
    }

    private func setSessionState(_ sessionId: String, _ state: SessionState) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) { sessions[index].state = state }
    }

    private func bufferStreaming(sessionId: String, id: String, content: String, sequence: Int64) {
        streamingBuffers[sessionId] = (id, content, sequence)
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000)
                self?.flushAllStreaming()
            }
        }
    }

    private func flushStreaming(sessionId: String) {
        guard let item = streamingBuffers.removeValue(forKey: sessionId) else { return }
        var list = messagesBySession[sessionId, default: []]
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list[index].text = item.text
        } else {
            list.append(ChatMessage(id: item.id, sessionId: sessionId, sequence: item.sequence, role: .assistant, kind: .text, text: item.text, toolName: nil, toolStatus: "Streaming", detail: nil, createdAt: Date()))
        }
        messagesBySession[sessionId] = sortedMessages(list)
    }

    private func flushAllStreaming() {
        for sessionId in Array(streamingBuffers.keys) { flushStreaming(sessionId: sessionId) }
        flushTask = nil
    }

    private func discardStreamingPlaceholder(sessionId: String) {
        streamingBuffers.removeValue(forKey: sessionId)
        var list = messagesBySession[sessionId, default: []]
        list.removeAll { $0.role == .assistant && ($0.toolStatus == "Streaming" || $0.id == "stream-\(sessionId)") }
        messagesBySession[sessionId] = list
    }

    private func reconcileOptimisticUserEcho(_ serverMessage: ChatMessage, sessionId: String) async {
        guard let optimistic = messagesBySession[sessionId, default: []].last(where: {
            $0.role == .user && $0.sequence == nil && UUID(uuidString: $0.id) != nil && $0.text == serverMessage.text && abs($0.createdAt.timeIntervalSince(serverMessage.createdAt)) < 180
        }) else { return }
        messagesBySession[sessionId]?.removeAll { $0.id == optimistic.id }
        try? await cache.deleteMessage(id: optimistic.id)
    }

    private func merge(_ incoming: [ChatMessage], into sessionId: String) {
        var map = Dictionary(uniqueKeysWithValues: messagesBySession[sessionId, default: []].map { ($0.id, $0) })
        for message in incoming { map[message.id] = message }
        messagesBySession[sessionId] = sortedMessages(Array(map.values))
    }

    private func sortedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }
}
