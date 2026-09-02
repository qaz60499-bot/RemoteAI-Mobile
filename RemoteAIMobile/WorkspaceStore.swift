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
    @Published var hasLoadedWebProjects = false
    @Published var attachmentTransferBySession: [String: AttachmentTransferProgress] = [:]
    @Published var commandStates: [UUID: CommandState] = [:]
    @Published var errors: [String: String] = [:]
    @Published var hasMoreBySession: [String: Bool] = [:]
    @Published var isPaired = false
    @Published var pairingStage: PairingStage?
    @Published var connectionPhase: ConnectionDiagnosticPhase = .relayConnecting

    static let connectingStateMaxDuration: TimeInterval = 45

    var transport: Transport
    let cache: SQLiteStore
    private var tracker = SequenceTracker()
    private var eventReplayGuard = BoundedReplayGuard(capacity: 8192)
    private var eventTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var streamingBuffers: [String: (id: String, text: String, sequence: Int64)] = [:]
    private var flushTask: Task<Void, Never>?
    private var startInProgress = false

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

    func start(pairingProgress: ((PairingStage) -> Void)? = nil) async {
        guard !startInProgress else { return }
        startInProgress = true
        defer { startInProgress = false }

        await loadCachedFirst()
        await normalizeCachedTransientState()
        if !(transport is MockTransport) {
            await removeLegacyMockFixtures()
            await removeCloudCodeFromMobileCache()
        }
        isPaired = PairingKeyStore.isPaired(machineId: machine.id)
        if !isPaired && !(transport is MockTransport) {
            try? await cache.clearAll()
            runtimes.removeAll()
            instances.removeAll()
            sessions.removeAll()
            messagesBySession.removeAll()
            webProjects.removeAll()
            projectConversationsByAlias.removeAll()
            projectNextCursorByAlias.removeAll()
            projectHasMoreByAlias.removeAll()
            hasLoadedWebProjects = false
            attachmentTransferBySession.removeAll()
            hasMoreBySession.removeAll()
            machine.state = .offline
            connectionPhase = .pairingExpired
            errors["connection"] = "Not paired — scan the Windows pairing code to load your real runtimes and ChatGPT Projects."
            return
        }
        installEventConsumer()
        machine.state = .connecting
        connectionPhase = .relayConnecting
        do {
            pairingProgress?(.connectingRemoteAI)
            try await transport.connect()
            connectionPhase = .relayConnected

            // Relay connectivity alone is not enough to call the PC online. Require one
            // authenticated encrypted command to round-trip through the Windows Agent.
            connectionPhase = .authenticating
            _ = try await transport.latestSequence(machineId: machine.id)
            machine.state = .online
            errors["connection"] = nil
            startConnectionMonitor()

            // Metadata is deliberately downstream of the online transition. A slow or
            // failed catalog refresh must never leave the UI stuck in Connecting.
            pairingProgress?(.loadingRuntimes)
            connectionPhase = .loadingRuntimes
            await recoverDelta()
            await refreshMetadata()
            connectionPhase = .online
        } catch {
            applyConnectionFailure(error)
            if (error as? TransportError) != .pairingRequired { startConnectionMonitor() }
        }
    }

    func suspend() async {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        await transport.disconnect()
        machine.state = .offline
        connectionPhase = .idle
    }

    func resumeFromForeground() async {
        machine.state = .connecting
        connectionPhase = .reconnecting
        await start()
    }

    func refreshWebProjects() async {
        if webProjects.isEmpty,
           let cached: [WebProjectDescriptor] = try? await cache.get([WebProjectDescriptor].self, key: "web.projects") {
            // Keep cache available for offline use, but do not mark it authoritative.
            // The live Web view hides this stale snapshot until Windows returns the
            // current ChatGPT DOM list, preventing the old/wrong Project flash.
            webProjects = cached
        }
        guard machine.state == .online else { return }
        do {
            let remote = try await transport.listProjects(machineId: machine.id)
            // Preserve the authoritative DOM order from Windows. Sorting by cached
            // timestamps can make a complete Project list look random or incomplete.
            webProjects = remote
            hasLoadedWebProjects = true
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
            hasLoadedWebProjects = true
            try? await cache.put(webProjects, key: "web.projects")
            errors["web.projects"] = nil
            return created
        } catch {
            errors["web.projects"] = error.localizedDescription
            return nil
        }
    }

    func loadProjectConversations(projectAlias: String, refresh: Bool = true) async {
        // Online Project pages should never flash cached placeholder/UUID titles before
        // the authoritative browser DOM has loaded. Cache is still useful offline.
        if (!refresh || machine.state != .online),
           projectConversationsByAlias[projectAlias] == nil,
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
            // Preserve the authoritative newest-first order supplied by ChatGPT.
            // Registry update timestamps reflect our scan time, not conversation age.
            projectConversationsByAlias[projectAlias] = Array(merged.prefix(50))
            if let next = page.nextCursor { projectNextCursorByAlias[projectAlias] = next }
            else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
            projectHasMoreByAlias[projectAlias] = page.hasMore
            try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
            mergeProjectSessions(page.items)
            errors["web.project.\(projectAlias)"] = nil
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
            errors[projectAlias.map { "web.project.\($0)" } ?? "web.root"] = nil
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
            var local = (try? await cache.recentMessages(sessionId: sessionId, limit: 50)) ?? []
            if sessions.first(where: { $0.id == sessionId })?.state != .busy {
                var changed = false
                for index in local.indices where local[index].kind == .toolEvent && local[index].toolStatus == "Running" {
                    local[index].toolStatus = "Interrupted"
                    if local[index].detail == nil { local[index].detail = "Previous app/connection lifecycle ended before a terminal tool event." }
                    changed = true
                }
                if changed { try? await cache.upsertMessages(local) }
            }
            messagesBySession[sessionId] = local
        }
        guard machine.state == .online, let context = contextForSession(sessionId) else { return }
        do {
            let page = try await transport.loadRecent(machineId: machine.id, runtimeId: context.runtime.id, instanceId: context.instance.id, sessionId: sessionId, limit: 50)
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId)
            hasMoreBySession[sessionId] = page.hasMore
            errors[sessionId] = nil
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
            errors[sessionId] = nil
        } catch {
            errors[sessionId] = error.localizedDescription
        }
    }

    @discardableResult
    func send(text: String, runtimeId: String, instanceId: String, sessionId: String, attachments: [PendingAttachment] = [], model: String = "", commandId: UUID = UUID()) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        guard attachments.count <= 8, attachments.allSatisfy({ $0.sizeBytes > 0 && $0.sizeBytes <= 20 * 1024 * 1024 }) else {
            errors[sessionId] = "最多一次发送 8 个附件，每个附件不能超过 20MB。"
            return false
        }
        guard machine.state == .online else {
            if !trimmed.isEmpty { try? await cache.saveDraft(trimmed, sessionId: sessionId) }
            errors[sessionId] = attachments.isEmpty
                ? "PC Offline — draft saved. Tap Send after reconnecting."
                : "PC Offline — 附件需要连接 Windows 后才能上传。"
            return false
        }

        commandStates[commandId] = .pending
        do {
            var remoteAttachments: [RemoteAttachmentDescriptor] = []
            if !attachments.isEmpty {
                attachmentTransferBySession[sessionId] = AttachmentTransferProgress(completed: 0, total: attachments.count, name: attachments[0].name)
            }
            for (index, attachment) in attachments.enumerated() {
                try Task.checkCancellation()
                attachmentTransferBySession[sessionId] = AttachmentTransferProgress(completed: index, total: attachments.count, name: attachment.name)
                let remote = try await transport.uploadAttachment(
                    machineId: machine.id,
                    runtimeId: runtimeId,
                    instanceId: instanceId,
                    sessionId: sessionId,
                    attachment: attachment
                )
                remoteAttachments.append(remote)
                attachmentTransferBySession[sessionId] = AttachmentTransferProgress(completed: index + 1, total: attachments.count, name: attachment.name)
            }
            try Task.checkCancellation()
            attachmentTransferBySession.removeValue(forKey: sessionId)

            let names = remoteAttachments.map(\.name).joined(separator: ", ")
            let displayText = "\(trimmed)\(!names.isEmpty ? "\(trimmed.isEmpty ? "" : "\n\n")[Attachments: \(names)]" : "")"
            let optimistic = ChatMessage(id: commandId.uuidString, sessionId: sessionId, sequence: nil, role: .user, kind: .text, text: displayText, toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
            merge([optimistic], into: sessionId)
            try? await cache.upsertMessages([optimistic])

            var payload: [String: JSONValue] = ["text": .string(trimmed)]
            if !model.isEmpty { payload["model"] = .string(model) }
            if !remoteAttachments.isEmpty { payload["attachmentIds"] = .array(remoteAttachments.map { .string($0.attachmentId) }) }
            let command = RemoteCommand.make(machineId: machine.id, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "sendMessage", payload: payload, commandId: commandId)
            commandStates[commandId] = .executing
            commandStates[commandId] = try await transport.send(command)
            try? await cache.saveDraft("", sessionId: sessionId)
            errors[sessionId] = nil
            return true
        } catch is CancellationError {
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .failed
            errors[sessionId] = "Attachment upload cancelled. The message was not sent; you can retry without reselecting the files."
            return false
        } catch TransportError.disconnected {
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .unknown
            errors[sessionId] = "Connection dropped after send. Delivery is unknown; retry reuses the same command ID."
            return false
        } catch {
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .failed
            errors[sessionId] = error.localizedDescription
            return false
        }
    }

    func retry(message: ChatMessage, runtimeId: String, instanceId: String, model: String = "") async {
        let commandId = UUID(uuidString: message.id) ?? UUID()
        await send(text: message.text, runtimeId: runtimeId, instanceId: instanceId, sessionId: message.sessionId, model: model, commandId: commandId)
    }

    func stop(runtimeId: String, instanceId: String, sessionId: String) async {
        let command = RemoteCommand.make(machineId: machine.id, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "stopGeneration")
        commandStates[command.commandId] = .pending
        do {
            commandStates[command.commandId] = try await transport.send(command)
            errors[sessionId] = nil
        } catch {
            commandStates[command.commandId] = .failed
            errors[sessionId] = error.localizedDescription
        }
    }

    func createSession(
        runtime: RuntimeDescriptor,
        instance: InstanceDescriptor,
        title: String,
        model: String = ""
    ) async -> Bool {
        var payload: [String: JSONValue] = [
            "title": .string(title.isEmpty ? "New Session" : title)
        ]
        if runtime.kind == .codex, !model.isEmpty {
            payload["model"] = .string(model)
        }
        guard machine.state == .online else {
            errors[instance.id] = "PC Offline — new sessions are not queued automatically."
            return false
        }
        do {
            if let created = try await transport.createSession(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id, payload: payload) {
                sessions.removeAll { $0.id == created.id }
                sessions.insert(created, at: 0)
                errors[instance.id] = nil
                await persistMetadata()
                return true
            } else if transport is MockTransport {
                let local = SessionDescriptor(id: UUID().uuidString, instanceId: instance.id, title: title.isEmpty ? (runtime.kind == .web ? "New Chat" : "New Session") : title, state: .idle, updatedAt: Date())
                sessions.insert(local, at: 0)
                errors[instance.id] = nil
                await persistMetadata()
                return true
            } else {
                await refreshMetadata()
                errors[instance.id] = nil
                return true
            }
        } catch {
            errors[instance.id] = error.localizedDescription
            return false
        }
    }

    func savePairing(baseURL: URL, machineId: String, code: String) async throws {
        pairingStage = .preparing
        eventTask?.cancel()
        connectionMonitorTask?.cancel()
        await transport.disconnect()
        let previousMachineId = machine.id
        let result = try await RelayPairingClient().pair(baseURL: baseURL, machineId: machineId, pairingCode: code) { [weak self] stage in
            self?.pairingStage = stage
        }

        if previousMachineId != result.machineId {
            PairingKeyStore.deletePairing(machineId: previousMachineId)
        }

        // A successful pairing establishes a new authoritative machine identity.
        // Always clear connection-derived cache before reconnecting so an older cached
        // MachineMetadata cannot overwrite the just-paired machine during start().
        try await cache.clearAll()
        runtimes.removeAll()
        instances.removeAll()
        sessions.removeAll()
        messagesBySession.removeAll()
        webProjects.removeAll()
        projectConversationsByAlias.removeAll()
        projectNextCursorByAlias.removeAll()
        projectHasMoreByAlias.removeAll()
        hasLoadedWebProjects = false
        attachmentTransferBySession.removeAll()
        hasMoreBySession.removeAll()
        tracker = SequenceTracker()
        eventReplayGuard = BoundedReplayGuard(capacity: 8192)

        let config = RemoteAIConfig(relayBaseURL: baseURL, machineId: result.machineId)
        config.saveMetadata()
        transport = CloudflareTransport(config: config)
        machine = MachineMetadata(id: result.machineId, name: machine.name, state: .connecting)
        isPaired = true
        errors["connection"] = nil
        await start { [weak self] stage in
            self?.pairingStage = stage
        }
        if machine.state != .online {
            throw TransportError.remote("PAIR_CONNECTED_BUT_OFFLINE", errors["connection"] ?? "Pairing succeeded, but the Windows service did not become reachable.")
        }
        pairingStage = .completed
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
                    self.connectionPhase = .reconnecting
                    do {
                        try await self.transport.connect()
                        self.connectionPhase = .authenticating
                        _ = try await self.transport.latestSequence(machineId: self.machine.id)
                        self.machine.state = .online
                        self.connectionPhase = .online
                        self.errors["connection"] = nil
                        await self.recoverDelta()
                        await self.refreshMetadata()
                    } catch {
                        self.applyConnectionFailure(error)
                        if (error as? TransportError) == .pairingRequired { break }
                    }
                }
            }
        }
    }

    private func applyConnectionFailure(_ error: Error) {
        machine.state = .offline
        if let transportError = error as? TransportError {
            switch transportError {
            case .pairingRequired:
                isPaired = false
                connectionPhase = .pairingExpired
                errors["connection"] = "Pairing expired / Repair required — scan the current Windows pairing QR code."
                connectionMonitorTask?.cancel()
                connectionMonitorTask = nil
            case .offline:
                connectionPhase = .windowsOffline
                errors["connection"] = "Windows offline — Relay is reachable but the RemoteAI Agent is not online."
            case .timeout:
                connectionPhase = .timedOut
                errors["connection"] = "Connection timed out — check Relay reachability and the Windows Agent."
            default:
                connectionPhase = .relayError
                errors["connection"] = transportError.localizedDescription
            }
        } else {
            connectionPhase = .relayError
            errors["connection"] = error.localizedDescription
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
            // Runtime instance discovery is intentionally lazy. Each RuntimeView
            // refreshes only the selected runtime, which keeps app launch and
            // reconnects from scanning every Codex workspace.
            errors["sync"] = nil
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
        if webProjects.isEmpty,
           let value: [WebProjectDescriptor] = try? await cache.get([WebProjectDescriptor].self, key: "web.projects") {
            webProjects = value
            // Cached Projects are an offline snapshot. Only refreshWebProjects() may
            // mark the list as live/current for this store lifetime.
        }
        tracker = SequenceTracker(lastSequence: (try? await cache.lastSequence()) ?? 0)
        let process = ProcessInfo.processInfo
        if runtimes.isEmpty,
           process.arguments.contains("-UITestMockMode"),
           process.environment["REMOTEAI_UI_TEST_MOCK"] == "1" {
            seedFixtureMetadata()
            await persistMetadata()
        }
    }

    private func normalizeCachedTransientState() async {
        var changed = false
        for index in sessions.indices where sessions[index].state == .busy || sessions[index].state == .waiting {
            let sessionId = sessions[index].id
            sessions[index].state = .idle
            errors[sessionId] = "Previous generation did not reach a terminal event before the app/connection ended. Its stale RUNNING state was reset."
            changed = true
        }
        if changed { try? await cache.put(sessions, key: "sessions") }
    }

    private func removeCloudCodeFromMobileCache() async {
        let cloudInstanceIds = Set(instances.filter { $0.runtimeId == "runtime.cloudcode" }.map(\.id))
        let cloudSessionIds = Set(sessions.filter { cloudInstanceIds.contains($0.instanceId) }.map(\.id))
        let changed = runtimes.contains { $0.id == "runtime.cloudcode" }
            || !cloudInstanceIds.isEmpty
            || !cloudSessionIds.isEmpty
        guard changed else { return }

        runtimes.removeAll { $0.id == "runtime.cloudcode" }
        instances.removeAll { $0.runtimeId == "runtime.cloudcode" }
        sessions.removeAll { cloudInstanceIds.contains($0.instanceId) }
        for sessionId in cloudSessionIds {
            messagesBySession.removeValue(forKey: sessionId)
            hasMoreBySession.removeValue(forKey: sessionId)
        }
        await persistMetadata()
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
            RuntimeDescriptor(id: "runtime.codex", machineId: machine.id, kind: .codex, name: "Codex")
        ]
        instances = [
            InstanceDescriptor(id: "web.chatgpt", runtimeId: "runtime.web", name: "ChatGPT", subtitle: "Web runtime"),
            InstanceDescriptor(id: "photo", runtimeId: "runtime.web", name: "Photo SaaS", subtitle: "2 conversations"),
            InstanceDescriptor(id: "excel", runtimeId: "runtime.web", name: "Excel SaaS", subtitle: "1 conversation")
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
            if cursor == 0 && instances.isEmpty && sessions.isEmpty && webProjects.isEmpty {
                // A fresh install has no local state to reconcile, so replaying the
                // entire historical event log only delays startup. Current state is
                // loaded lazily from the authoritative runtime/project/session APIs.
                cursor = try await transport.latestSequence(machineId: machine.id)
                try? await cache.setLastSequence(cursor)
                tracker = SequenceTracker(lastSequence: cursor)
                return
            }
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
