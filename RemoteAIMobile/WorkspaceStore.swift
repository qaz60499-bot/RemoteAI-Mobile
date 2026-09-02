import Foundation
import SwiftUI

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var machine = MachineMetadata(id: "my-pc", name: "My PC", state: .connecting)
    @Published var runtimes: [RuntimeDescriptor] = []
    @Published var instances: [InstanceDescriptor] = []
    @Published var sessions: [SessionDescriptor] = []
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var webProjects: [WebProjectDescriptor] = []
    @Published var projectConversationsByAlias: [String: [WebConversationDescriptor]] = [:]
    @Published var projectNextCursorByAlias: [String: String] = [:]
    @Published var projectHasMoreByAlias: [String: Bool] = [:]
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
        // MockTransport is test-only. Require both an explicit UI-test argument and a
        // UI-test-only environment marker so an installed IPA can never fall into Mock.
        let process = ProcessInfo.processInfo
        let useMock = process.arguments.contains("-UITestMockMode")
            && process.environment["REMOTEAI_UI_TEST_MOCK"] == "1"
        let transport: Transport = useMock ? MockTransport() : CloudflareTransport(config: config)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: config.machineId, name: "My PC", state: .connecting)
        return store
    }

    func start() async {
        await loadCachedFirst()
        if !(transport is MockTransport) { await removeLegacyMockFixtures() }
        isPaired = PairingKeyStore.isPaired(machineId: machine.id)
        if !isPaired && !(transport is MockTransport) {
            // Older builds incorrectly used MockTransport whenever the phone was not
            // paired, which could persist fake Photo/Excel workspaces in SQLite.
            // Remove that stale workspace state and fail closed until real pairing.
            try? await cache.clearAll()
            runtimes.removeAll()
            instances.removeAll()
            sessions.removeAll()
            messagesBySession.removeAll()
            webProjects.removeAll()
            projectConversationsByAlias.removeAll()
            projectNextCursorByAlias.removeAll()
            projectHasMoreByAlias.removeAll()
            hasMoreBySession.removeAll()
            machine.state = .offline
            errors["connection"] = "Not paired — scan the Windows pairing code to load your real runtimes and ChatGPT Projects."
            return
        }
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

    func refreshWebProjects() async {
        if webProjects.isEmpty,
           let cached: [WebProjectDescriptor] = try? await cache.get([WebProjectDescriptor].self, key: "web.projects") {
            webProjects = cached
        }
        guard machine.state == .online else { return }
        do {
            let remote = try await transport.listProjects(machineId: machine.id)
            webProjects = remote.sorted { ($0.lastOpenedAt ?? $0.lastSeenAt ?? .distantPast) > ($1.lastOpenedAt ?? $1.lastSeenAt ?? .distantPast) }
            try? await cache.put(webProjects, key: "web.projects")
            errors["web.projects"] = nil
        } catch {
            errors["web.projects"] = error.localizedDescription
        }
    }

    func createWebProject(name: String) async -> WebProjectDescriptor? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard machine.state == .online else {
            errors["web.projects"] = "PC Offline — new Projects require the Windows browser runtime."
            return nil
        }
        do {
            let created = try await transport.createWebProject(machineId: machine.id, projectName: trimmed)
            webProjects.removeAll { $0.projectAlias == created.projectAlias }
            webProjects.insert(created, at: 0)
            try? await cache.put(webProjects, key: "web.projects")
            errors["web.projects"] = nil
            return created
        } catch {
            errors["web.projects"] = error.localizedDescription
            return nil
        }
    }

    func loadProjectConversations(projectAlias: String, refresh: Bool = true) async {
        if projectConversationsByAlias[projectAlias] == nil,
           let cached: [WebConversationDescriptor] = try? await cache.get([WebConversationDescriptor].self, key: "web.project.\(projectAlias).conversations") {
            projectConversationsByAlias[projectAlias] = cached
        }
        guard refresh, machine.state == .online else { return }
        do {
            let page = try await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 30)
            projectConversationsByAlias[projectAlias] = page.items
            if let cursor = page.nextCursor { projectNextCursorByAlias[projectAlias] = cursor }
            else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
            projectHasMoreByAlias[projectAlias] = page.hasMore
            try? await cache.put(page.items, key: "web.project.\(projectAlias).conversations")
            mergeProjectSessions(page.items)
            errors["web.project.\(projectAlias)"] = nil
        } catch {
            errors["web.project.\(projectAlias)"] = error.localizedDescription
        }
    }

    func loadMoreProjectConversations(projectAlias: String) async {
        guard machine.state == .online,
              projectHasMoreByAlias[projectAlias] == true,
              let cursor = projectNextCursorByAlias[projectAlias] else { return }
        do {
            let page = try await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 30, cursor: cursor)
            var merged = projectConversationsByAlias[projectAlias, default: []]
            for item in page.items where !merged.contains(where: { $0.id == item.id }) { merged.append(item) }
            merged.sort { $0.updatedAt > $1.updatedAt }
            projectConversationsByAlias[projectAlias] = Array(merged.prefix(50))
            if let next = page.nextCursor { projectNextCursorByAlias[projectAlias] = next }
            else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
            projectHasMoreByAlias[projectAlias] = page.hasMore
            try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
            mergeProjectSessions(page.items)
        } catch {
            errors["web.project.\(projectAlias)"] = error.localizedDescription
        }
    }

    func createWebConversation(projectAlias: String? = nil) async -> SessionDescriptor? {
        guard machine.state == .online else {
            errors[projectAlias.map { "web.project.\($0)" } ?? "web.root"] = "PC Offline — new conversations require the Windows browser runtime."
            return nil
        }
        do {
            let created = try await transport.createWebConversation(machineId: machine.id, projectAlias: projectAlias)
            let session = created.session
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            if let alias = projectAlias {
                var rows = projectConversationsByAlias[alias, default: []]
                rows.removeAll { $0.id == created.id }
                rows.insert(created, at: 0)
                projectConversationsByAlias[alias] = Array(rows.prefix(50))
                try? await cache.put(projectConversationsByAlias[alias] ?? [], key: "web.project.\(alias).conversations")
            }
            await persistMetadata()
            return session
        } catch {
            errors[projectAlias.map { "web.project.\($0)" } ?? "web.root"] = error.localizedDescription
            return nil
        }
    }

    func refreshSessions(runtime: RuntimeDescriptor, instance: InstanceDescriptor) async {
        guard machine.state == .online else { return }
        do {
            let remote = try await transport.listSessions(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id)
            sessions.removeAll { $0.instanceId == instance.id }
            sessions.append(contentsOf: remote)
            sessions.sort { $0.updatedAt > $1.updatedAt }
            await persistMetadata()
            errors["instance.\(instance.id)"] = nil
        } catch {
            errors["instance.\(instance.id)"] = error.localizedDescription
        }
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

    func createSession(
        runtime: RuntimeDescriptor,
        instance: InstanceDescriptor,
        title: String,
        providerId: String = "current",
        providerBaseURL: String = "",
        model: String = "",
        credentialProfileId: String = "",
        newCredentialProfileId: String = "",
        apiKey: String = ""
    ) async {
        var payload: [String: JSONValue] = [
            "title": .string(title.isEmpty ? "New Session" : title),
            "providerId": .string(providerId),
            "model": .string(model),
            "credentialProfileId": .string(credentialProfileId)
        ]
        if !providerBaseURL.isEmpty { payload["providerBaseURL"] = .string(providerBaseURL) }
        if !newCredentialProfileId.isEmpty { payload["newCredentialProfileId"] = .string(newCredentialProfileId) }
        if !apiKey.isEmpty { payload["apiKey"] = .string(apiKey) }
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
            webProjects.removeAll()
            projectConversationsByAlias.removeAll()
            projectNextCursorByAlias.removeAll()
            projectHasMoreByAlias.removeAll()
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

    func refreshRuntime(_ runtime: RuntimeDescriptor) async {
        guard machine.state == .online else { return }
        do {
            let rows = try await transport.listInstances(machineId: machine.id, runtimeId: runtime.id)
            instances.removeAll { $0.runtimeId == runtime.id }
            instances.append(contentsOf: rows)
            instances.sort { lhs, rhs in
                if lhs.runtimeId == rhs.runtimeId { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.runtimeId < rhs.runtimeId
            }
            // Instance discovery stays cheap. Session history is loaded only after the
            // user opens one instance, otherwise Codex1...Codex11 would all scan their
            // JSONL stores just to render this list.
            errors["runtime.\(runtime.id)"] = nil
            await persistMetadata()
        } catch {
            errors["runtime.\(runtime.id)"] = error.localizedDescription
        }
    }

    private func refreshMetadata() async {
        guard machine.state == .online else { return }
        do {
            let remoteRuntimes = try await transport.listRuntimes(machineId: machine.id)
            if !remoteRuntimes.isEmpty { runtimes = remoteRuntimes }
            for runtime in runtimes { await refreshRuntime(runtime) }
            errors["sync"] = nil
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
        if let value: [WebProjectDescriptor] = try? await cache.get([WebProjectDescriptor].self, key: "web.projects") { webProjects = value }
        tracker = SequenceTracker(lastSequence: (try? await cache.lastSequence()) ?? 0)
        let process = ProcessInfo.processInfo
        if runtimes.isEmpty,
           process.arguments.contains("-UITestMockMode"),
           process.environment["REMOTEAI_UI_TEST_MOCK"] == "1" {
            seedFixtureMetadata()
            await persistMetadata()
        }
    }

    private func removeLegacyMockFixtures() async {
        let fixtureInstanceIds: Set<String> = ["photo", "excel", "cloud-photo"]
        let fixtureSessionIds: Set<String> = ["photo-upload", "photo-ios", "excel-permission", "cloud-photo-a", "codex6-a"]
        let fixtureProjectAliases: Set<String> = ["g-p-remoteai", "g-p-photo"]
        let hadFixture = instances.contains { fixtureInstanceIds.contains($0.id) }
            || sessions.contains { fixtureSessionIds.contains($0.id) }
            || webProjects.contains { fixtureProjectAliases.contains($0.projectAlias) }
        guard hadFixture else { return }

        instances.removeAll { fixtureInstanceIds.contains($0.id) }
        sessions.removeAll { fixtureSessionIds.contains($0.id) || fixtureInstanceIds.contains($0.instanceId) }
        webProjects.removeAll { fixtureProjectAliases.contains($0.projectAlias) }
        for alias in fixtureProjectAliases {
            projectConversationsByAlias.removeValue(forKey: alias)
            projectNextCursorByAlias.removeValue(forKey: alias)
            projectHasMoreByAlias.removeValue(forKey: alias)
        }
        for sessionId in fixtureSessionIds {
            messagesBySession.removeValue(forKey: sessionId)
            hasMoreBySession.removeValue(forKey: sessionId)
        }
        await persistMetadata()
        try? await cache.put(webProjects, key: "web.projects")
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
            InstanceDescriptor(id: "cloud-photo", runtimeId: "runtime.cloudcode", name: "Photo", subtitle: "Cloud Code")
        ] + (1...11).map {
            InstanceDescriptor(id: "codex.\($0)", runtimeId: "runtime.codex", name: "Codex\($0)", subtitle: nil)
        } + [
            InstanceDescriptor(id: "codex.kali", runtimeId: "runtime.codex", name: "Kali Codex", subtitle: nil),
            InstanceDescriptor(id: "codex.linux", runtimeId: "runtime.codex", name: "Linux Codex", subtitle: nil)
        ]
        sessions = [
            SessionDescriptor(id: "photo-upload", instanceId: "photo", title: "上传性能优化", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "photo-ios", instanceId: "photo", title: "手机 APP", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "excel-permission", instanceId: "excel", title: "权限测试", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "cloud-photo-a", instanceId: "cloud-photo", title: "Session A", state: .idle, updatedAt: Date()),
            SessionDescriptor(id: "codex6-a", instanceId: "codex.6", title: "Session A", state: .idle, updatedAt: Date())
        ]
    }

    private func mergeProjectSessions(_ items: [WebConversationDescriptor]) {
        for item in items {
            let session = item.session
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
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
