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
    @Published var webProjectsSnapshotState: WebSnapshotState?
    @Published var projectConversationSnapshotStateByAlias: [String: WebSnapshotState] = [:]
    @Published var projectConversationLoadingByAlias: [String: Bool] = [:]
    @Published var liveRunStatusBySession: [String: String] = [:]
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
    private var restartAfterStart = false
    private var lifecycleGeneration: UInt64 = 0
    private var isSuspended = false

    // MainActor reentrancy means a second UI task can enter while the first request is
    // awaiting I/O. Keep per-operation gates at the Store boundary, not only in Views.
    private var refreshWebProjectsInFlight = false
    private var refreshWebProjectsQueued = false
    private var projectConversationRefreshes = Set<String>()
    private var projectConversationRefreshQueued = Set<String>()
    private var projectConversationPageLoads = Set<String>()
    private var runtimeRefreshes = Set<String>()
    private var sessionRefreshes = Set<String>()
    private var sessionLoads = Set<String>()
    private var olderMessageLoads = Set<String>()
    private var creatingWebProjects = Set<String>()
    private var creatingWebConversations = Set<String>()
    private var creatingSessions = Set<String>()
    private var stopTasksBySession: [String: Task<Bool, Never>] = [:]
    private var commandSendsInFlight = Set<UUID>()
    private var metadataRefreshInFlight = false
    private var metadataRefreshQueued = false
    private var deltaRecoveryInFlight = false
    private var deltaRecoveryQueued = false
    private var webProjectsRevision: UInt64 = 0
    private var webProjectsSnapshotId: String?
    private var projectConversationRevisions: [String: UInt64] = [:]
    private var projectConversationSnapshotIds: [String: String] = [:]
    private var sessionRevisions: [String: UInt64] = [:]

    private static func pendingCommandPrefix(machineId: String) -> String {
        "pending.command.\(machineId)."
    }

    private static func pendingCommandKey(_ id: UUID, machineId: String) -> String {
        pendingCommandPrefix(machineId: machineId) + id.uuidString.lowercased()
    }

    init(transport: Transport, cache: SQLiteStore) {
        self.transport = transport
        self.cache = cache
        DiagnosticsLog.shared.record("store_initialized", fields: ["transport": String(describing: type(of: transport))])
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
        guard !isSuspended else { return }
        if startInProgress { return }
        startInProgress = true
        let generation = lifecycleGeneration
        defer {
            startInProgress = false
            if restartAfterStart && !isSuspended {
                restartAfterStart = false
                Task { [weak self] in await self?.start() }
            }
        }

        await loadCachedFirst()
        guard generation == lifecycleGeneration, !isSuspended else { return }
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
            webProjectsSnapshotState = nil
            projectConversationSnapshotStateByAlias.removeAll()
            projectConversationLoadingByAlias.removeAll()
            liveRunStatusBySession.removeAll()
            webProjectsSnapshotId = nil
            projectConversationSnapshotIds.removeAll()
            hasLoadedWebProjects = false
            attachmentTransferBySession.removeAll()
            hasMoreBySession.removeAll()
            machine.state = .offline
            connectionPhase = .pairingExpired
            errors["connection"] = "Not paired — scan the Windows pairing code to load your real runtimes and ChatGPT Projects."
            return
        }
        let activeTransport = transport
        installEventConsumer()
        machine.state = .connecting
        connectionPhase = .relayConnecting
        DiagnosticsLog.shared.record("connection_start")
        do {
            pairingProgress?(.connectingRemoteAI)
            try await activeTransport.connect()
            guard generation == lifecycleGeneration, !isSuspended, transport === activeTransport else {
                await activeTransport.disconnect()
                return
            }
            connectionPhase = .relayConnected

            // Relay connectivity alone is not enough to call the PC online. Require one
            // authenticated encrypted command to round-trip through the Windows Agent.
            connectionPhase = .authenticating
            let authenticatedSequence = try await activeTransport.latestSequence(machineId: machine.id)
            guard generation == lifecycleGeneration, !isSuspended, transport === activeTransport else {
                await activeTransport.disconnect()
                return
            }
            machine.state = .online
            errors["connection"] = nil
            DiagnosticsLog.shared.record("connection_online", fields: ["sequence": String(authenticatedSequence)])
            startConnectionMonitor()

            // Metadata is deliberately downstream of the online transition. A slow or
            // failed catalog refresh must never leave the UI stuck in Connecting.
            pairingProgress?(.loadingRuntimes)
            connectionPhase = .loadingRuntimes
            await recoverDelta(freshLatestSequence: authenticatedSequence)
            guard generation == lifecycleGeneration, !isSuspended else { return }
            await refreshMetadata()
            guard generation == lifecycleGeneration, !isSuspended else { return }
            connectionPhase = .online
        } catch {
            guard generation == lifecycleGeneration, !isSuspended else { return }
            applyConnectionFailure(error)
            if (error as? TransportError) != .pairingRequired { startConnectionMonitor() }
        }
    }

    func suspend() async {
        isSuspended = true
        lifecycleGeneration &+= 1
        restartAfterStart = false
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        eventTask?.cancel()
        eventTask = nil
        flushAllStreaming()
        await transport.disconnect()
        machine.state = .offline
        connectionPhase = .idle
        DiagnosticsLog.shared.record("connection_suspended")
    }

    func resumeFromForeground() async {
        isSuspended = false
        lifecycleGeneration &+= 1
        machine.state = .connecting
        connectionPhase = .reconnecting
        if startInProgress {
            restartAfterStart = true
            return
        }
        await start()
    }

    func refreshWebProjects() async {
        if refreshWebProjectsInFlight {
            refreshWebProjectsQueued = true
            return
        }
        refreshWebProjectsInFlight = true
        defer {
            refreshWebProjectsInFlight = false
            if refreshWebProjectsQueued {
                refreshWebProjectsQueued = false
                Task { @MainActor [weak self] in await self?.refreshWebProjects() }
            }
        }
        let generation = lifecycleGeneration
        let revision = webProjectsRevision
        if webProjects.isEmpty,
           let cached: [WebProjectDescriptor] = try? await cache.get([WebProjectDescriptor].self, key: "web.projects") {
            // Cache is last-known-good because degraded snapshots are never persisted.
            // Re-check the resource epoch after the await so a concurrent create cannot
            // be erased by a late cache hydration.
            if generation == lifecycleGeneration,
               revision == webProjectsRevision,
               webProjects.isEmpty,
               !isSuspended {
                webProjects = cached
                webProjectsSnapshotState = .staleCache
            }
        }
        guard machine.state == .online else {
            hasLoadedWebProjects = !webProjects.isEmpty
            DiagnosticsLog.shared.record("projects_refresh_skipped_offline", fields: ["cachedCount": String(webProjects.count)], level: "WARN")
            return
        }
        do {
            let response = try await transport.listProjectsResponse(machineId: machine.id)
            guard generation == lifecycleGeneration, revision == webProjectsRevision, machine.state == .online, !isSuspended else { return }
            guard response.isAuthoritativeLiveDOM else {
                if response.state == .staleCache,
                   webProjects.isEmpty,
                   !response.items.isEmpty {
                    // A fresh install may have no iOS-side cache even though Windows has
                    // a previously verified live-DOM Project snapshot. Bootstrap from
                    // that explicit stale snapshot only when there is no local truth;
                    // never persist it or let it replace a non-empty local list.
                    webProjects = response.items
                    webProjectsSnapshotState = .staleCache
                    hasLoadedWebProjects = true
                    errors["web.projects"] = "Showing the last verified Windows Project list while ChatGPT refreshes."
                    DiagnosticsLog.shared.record("projects_refresh_stale", fields: ["count": String(response.items.count)], level: "WARN")
                    return
                }
                webProjectsSnapshotState = response.state ?? .providerUnavailable
                hasLoadedWebProjects = !webProjects.isEmpty
                errors["web.projects"] = "ChatGPT Projects are temporarily incomplete; keeping the last verified Project list."
                DiagnosticsLog.shared.record("projects_refresh_incomplete", fields: ["cachedCount": String(webProjects.count), "state": String(describing: response.state)], level: "WARN")
                return
            }
            // Preserve the authoritative DOM order from Windows. Sorting by cached
            // timestamps can make a complete Project list look random or incomplete.
            webProjects = response.items
            webProjectsSnapshotState = .authoritativeLiveDOM
            webProjectsSnapshotId = response.snapshotId
            hasLoadedWebProjects = true
            try? await cache.put(webProjects, key: "web.projects")
            guard generation == lifecycleGeneration, revision == webProjectsRevision, !isSuspended else { return }
            errors["web.projects"] = nil
            DiagnosticsLog.shared.record("projects_refresh_ok", fields: ["count": String(webProjects.count)])
        } catch {
            if generation == lifecycleGeneration, revision == webProjectsRevision, !isSuspended {
                webProjectsSnapshotState = .providerUnavailable
                hasLoadedWebProjects = !webProjects.isEmpty
                errors["web.projects"] = error.localizedDescription
                DiagnosticsLog.shared.record("projects_refresh_failed", fields: ["errorType": String(describing: type(of: error))], level: "ERROR")
            }
        }
    }

    func createWebProject(name: String) async -> WebProjectDescriptor? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let operationKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard creatingWebProjects.insert(operationKey).inserted else { return nil }
        defer { creatingWebProjects.remove(operationKey) }
        let generation = lifecycleGeneration
        guard machine.state == .online else {
            errors["web.projects"] = "PC Offline — new Projects require the Windows browser runtime."
            return nil
        }
        let activeTransport = transport
        let activeMachineId = machine.id
        webProjectsRevision &+= 1
        do {
            let commandId = await pendingOperationCommandId(key: "createProject.\(operationKey)", machineId: activeMachineId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
            let created = try await activeTransport.createWebProject(machineId: activeMachineId, projectName: trimmed, commandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, machine.state == .online, !isSuspended else { return nil }
            // Commit a second epoch bump after the remote mutation succeeds. Any refresh
            // that began while createProject was in flight must not overwrite this row.
            webProjectsRevision &+= 1
            await finishPendingOperation(key: "createProject.\(operationKey)", machineId: activeMachineId, expectedCommandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
            webProjects.removeAll { $0.projectAlias == created.projectAlias }
            webProjects.insert(created, at: 0)
            webProjectsSnapshotState = .localConfirmed
            webProjectsSnapshotId = nil
            hasLoadedWebProjects = true
            try? await cache.put(webProjects, key: "web.projects")
            errors["web.projects"] = nil
            return created
        } catch {
            if generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended {
                if !isUnknownDelivery(error) { await finishPendingOperation(key: "createProject.\(operationKey)", machineId: activeMachineId) }
                errors["web.projects"] = error.localizedDescription
            }
            return nil
        }
    }

    func loadProjectConversations(projectAlias: String, refresh: Bool = true) async {
        if refresh {
            guard projectConversationRefreshes.insert(projectAlias).inserted else {
                projectConversationRefreshQueued.insert(projectAlias)
                return
            }
            projectConversationLoadingByAlias[projectAlias] = true
            // A full refresh supersedes any page-load already in flight for this Project.
            projectConversationRevisions[projectAlias, default: 0] &+= 1
        }
        defer {
            if refresh {
                projectConversationRefreshes.remove(projectAlias)
                projectConversationLoadingByAlias[projectAlias] = false
                if projectConversationRefreshQueued.remove(projectAlias) != nil {
                    Task { @MainActor [weak self] in await self?.loadProjectConversations(projectAlias: projectAlias, refresh: true) }
                }
            }
        }
        let generation = lifecycleGeneration
        let revision = projectConversationRevisions[projectAlias, default: 0]
        if projectConversationsByAlias[projectAlias] == nil,
           let cached: [WebConversationDescriptor] = try? await cache.get([WebConversationDescriptor].self, key: "web.project.\(projectAlias).conversations") {
            // This cache contains only previously accepted authoritative snapshots.
            // Check the epoch after the await so a create/refresh cannot be erased.
            if generation == lifecycleGeneration,
               revision == projectConversationRevisions[projectAlias, default: 0],
               projectConversationsByAlias[projectAlias] == nil,
               !isSuspended {
                projectConversationsByAlias[projectAlias] = cached
                projectConversationSnapshotStateByAlias[projectAlias] = .staleCache
            }
        }
        guard refresh else { return }
        guard machine.state == .online else {
            if projectConversationsByAlias[projectAlias, default: []].isEmpty {
                errors["web.project.\(projectAlias)"] = "PC Offline — connect to Windows to load this Project's conversations."
            }
            DiagnosticsLog.shared.record("project_load_offline", fields: ["project": projectAlias, "cachedCount": String(projectConversationsByAlias[projectAlias, default: []].count)], level: "WARN")
            return
        }
        do {
            var page = try await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 30)
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], machine.state == .online, !isSuspended else { return }
            // The ChatGPT sidebar lazily mounts untouched Project conversation panels.
            // If the first read explicitly reports a partial DOM and we have no verified
            // rows yet, one bounded read-only retry is safe and avoids requiring the
            // user to create a New Chat merely to make history appear.
            if !page.isAuthoritativeLiveDOM,
               projectConversationsByAlias[projectAlias, default: []].isEmpty {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if generation == lifecycleGeneration,
                   revision == projectConversationRevisions[projectAlias, default: 0],
                   machine.state == .online,
                   !isSuspended,
                   let retry = try? await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 30),
                   retry.isAuthoritativeLiveDOM {
                    page = retry
                }
            }
            guard page.isAuthoritativeLiveDOM else {
                if page.state == .staleCache,
                   projectConversationsByAlias[projectAlias, default: []].isEmpty,
                   !page.items.isEmpty {
                    // Same bootstrap rule as Projects: accept Windows last-known-good
                    // identities/order only when this phone has none yet. Keep the
                    // snapshot explicitly stale and do not persist it as authoritative.
                    projectConversationsByAlias[projectAlias] = page.items
                    projectConversationSnapshotStateByAlias[projectAlias] = .staleCache
                    projectNextCursorByAlias[projectAlias] = page.nextCursor
                    projectHasMoreByAlias[projectAlias] = page.hasMore
                    mergeProjectSessions(page.items)
                    errors["web.project.\(projectAlias)"] = "Showing the last verified Windows conversation list while ChatGPT refreshes."
                    DiagnosticsLog.shared.record("project_load_stale", fields: ["project": projectAlias, "count": String(page.items.count)], level: "WARN")
                    return
                }
                projectConversationSnapshotStateByAlias[projectAlias] = page.state ?? .providerUnavailable
                // Degraded responses may carry only metadata title hints from local
                // Chrome History. Merge those only when the conversation identity was
                // already verified; stale identity/order is never accepted.
                if mergeConversationTitleHints(page.items, projectAlias: projectAlias) {
                    try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
                    mergeProjectSessions(projectConversationsByAlias[projectAlias] ?? [])
                }
                errors["web.project.\(projectAlias)"] = "ChatGPT conversations are temporarily incomplete; keeping the last verified list."
                DiagnosticsLog.shared.record("project_load_incomplete", fields: ["project": projectAlias, "state": String(describing: page.state), "observedCount": String(page.items.count)], level: "WARN")
                return
            }
            projectConversationsByAlias[projectAlias] = page.items
            projectConversationSnapshotStateByAlias[projectAlias] = .authoritativeLiveDOM
            if let snapshotId = page.snapshotId { projectConversationSnapshotIds[projectAlias] = snapshotId }
            else { projectConversationSnapshotIds.removeValue(forKey: projectAlias) }
            if let cursor = page.nextCursor { projectNextCursorByAlias[projectAlias] = cursor }
            else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
            projectHasMoreByAlias[projectAlias] = page.hasMore
            try? await cache.put(page.items, key: "web.project.\(projectAlias).conversations")
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], !isSuspended else { return }
            mergeProjectSessions(page.items)
            errors["web.project.\(projectAlias)"] = nil
            DiagnosticsLog.shared.record("project_load_ok", fields: ["project": projectAlias, "count": String(page.items.count), "hasMore": String(page.hasMore)])
        } catch {
            if generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], !isSuspended {
                projectConversationSnapshotStateByAlias[projectAlias] = .providerUnavailable
                errors["web.project.\(projectAlias)"] = error.localizedDescription
                DiagnosticsLog.shared.record("project_load_failed", fields: ["project": projectAlias, "errorType": String(describing: type(of: error))], level: "ERROR")
            }
        }
    }

    func loadMoreProjectConversations(projectAlias: String) async {
        guard !projectConversationRefreshes.contains(projectAlias) else { return }
        guard projectConversationPageLoads.insert(projectAlias).inserted else { return }
        defer { projectConversationPageLoads.remove(projectAlias) }
        let generation = lifecycleGeneration
        let revision = projectConversationRevisions[projectAlias, default: 0]
        guard machine.state == .online,
              projectHasMoreByAlias[projectAlias] == true,
              let cursor = projectNextCursorByAlias[projectAlias],
              let expectedSnapshotId = projectConversationSnapshotIds[projectAlias] else { return }
        do {
            let page = try await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 30, cursor: cursor)
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], machine.state == .online, !isSuspended else { return }
            guard page.isAuthoritativeLiveDOM else {
                projectConversationSnapshotStateByAlias[projectAlias] = page.state ?? .providerUnavailable
                if mergeConversationTitleHints(page.items, projectAlias: projectAlias) {
                    try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
                    mergeProjectSessions(projectConversationsByAlias[projectAlias] ?? [])
                }
                errors["web.project.\(projectAlias)"] = "ChatGPT conversations are temporarily incomplete; keeping the last verified list."
                return
            }
            guard page.snapshotId == expectedSnapshotId else {
                errors["web.project.\(projectAlias)"] = "ChatGPT conversation list changed while loading more; refresh to keep ordering consistent."
                return
            }
            var merged = projectConversationsByAlias[projectAlias, default: []]
            for item in page.items where !merged.contains(where: { $0.id == item.id }) { merged.append(item) }
            // Preserve the authoritative newest-first order supplied by ChatGPT.
            // Registry update timestamps reflect our scan time, not conversation age.
            projectConversationsByAlias[projectAlias] = Array(merged.prefix(50))
            projectConversationSnapshotStateByAlias[projectAlias] = .authoritativeLiveDOM
            if let next = page.nextCursor { projectNextCursorByAlias[projectAlias] = next }
            else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
            projectHasMoreByAlias[projectAlias] = page.hasMore
            try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], !isSuspended else { return }
            mergeProjectSessions(page.items)
            errors["web.project.\(projectAlias)"] = nil
        } catch {
            if generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], !isSuspended {
                projectConversationSnapshotStateByAlias[projectAlias] = .providerUnavailable
                errors["web.project.\(projectAlias)"] = error.localizedDescription
            }
        }
    }

    func createWebConversation(projectAlias: String? = nil) async -> SessionDescriptor? {
        let scope = projectAlias ?? "__root__"
        guard creatingWebConversations.insert(scope).inserted else { return nil }
        defer { creatingWebConversations.remove(scope) }
        let generation = lifecycleGeneration
        guard machine.state == .online else {
            errors[projectAlias.map { "web.project.\($0)" } ?? "web.root"] = "PC Offline — new conversations require the Windows browser runtime."
            return nil
        }
        let activeTransport = transport
        let activeMachineId = machine.id
        sessionRevisions["web.chatgpt", default: 0] &+= 1
        if let projectAlias { projectConversationRevisions[projectAlias, default: 0] &+= 1 }
        do {
            let operationKey = "createConversation.\(scope)"
            let commandId = await pendingOperationCommandId(key: operationKey, machineId: activeMachineId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
            let created = try await activeTransport.createWebConversation(machineId: activeMachineId, projectAlias: projectAlias, commandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, machine.state == .online, !isSuspended else { return nil }
            // Successful remote create is a new commit epoch. Refresh/page responses
            // started during the mutation must not erase or reorder this conversation.
            sessionRevisions["web.chatgpt", default: 0] &+= 1
            if let projectAlias { projectConversationRevisions[projectAlias, default: 0] &+= 1 }
            await finishPendingOperation(key: operationKey, machineId: activeMachineId, expectedCommandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
            let session = created.session
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            if let alias = projectAlias {
                var rows = projectConversationsByAlias[alias, default: []]
                rows.removeAll { $0.id == created.id }
                rows.insert(created, at: 0)
                projectConversationsByAlias[alias] = Array(rows.prefix(50))
                projectConversationSnapshotStateByAlias[alias] = .localConfirmed
                projectConversationSnapshotIds.removeValue(forKey: alias)
                projectNextCursorByAlias.removeValue(forKey: alias)
                projectHasMoreByAlias[alias] = false
                try? await cache.put(projectConversationsByAlias[alias] ?? [], key: "web.project.\(alias).conversations")
            }
            await persistMetadata()
            errors[projectAlias.map { "web.project.\($0)" } ?? "web.root"] = nil
            return session
        } catch {
            let operationKey = "createConversation.\(scope)"
            if generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended {
                if !isUnknownDelivery(error) { await finishPendingOperation(key: operationKey, machineId: activeMachineId) }
                errors[projectAlias.map { "web.project.\($0)" } ?? "web.root"] = error.localizedDescription
            }
            return nil
        }
    }

    func refreshSessions(runtime: RuntimeDescriptor, instance: InstanceDescriptor) async {
        guard sessionRefreshes.insert(instance.id).inserted else { return }
        defer { sessionRefreshes.remove(instance.id) }
        let generation = lifecycleGeneration
        let revision = sessionRevisions[instance.id, default: 0]
        guard machine.state == .online else { return }
        do {
            let remote = try await transport.listSessions(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id)
            guard generation == lifecycleGeneration, revision == sessionRevisions[instance.id, default: 0], machine.state == .online, !isSuspended else { return }
            sessions.removeAll { $0.instanceId == instance.id }
            sessions.append(contentsOf: remote)
            sessions.sort { $0.updatedAt > $1.updatedAt }
            await persistMetadata()
            errors["instance.\(instance.id)"] = nil
        } catch {
            if generation == lifecycleGeneration, !isSuspended { errors["instance.\(instance.id)"] = error.localizedDescription }
        }
    }

    func loadSession(_ sessionId: String) async {
        guard sessionLoads.insert(sessionId).inserted else { return }
        defer { sessionLoads.remove(sessionId) }
        let generation = lifecycleGeneration

        // Pending commands are authoritative recovery state in their own right. Do not
        // depend on an optimistic message row surviving the previous lifecycle: the
        // server echo may already have replaced/removed that row before the app exited.
        let pendingPrefix = Self.pendingCommandPrefix(machineId: machine.id)
        let persistedPending = (try? await cache.values(RemoteCommand.self, keyPrefix: pendingPrefix)) ?? []
        for command in persistedPending where command.action == "sendMessage" && command.sessionId == sessionId {
            if commandStates[command.commandId] == nil { commandStates[command.commandId] = .unknown }
        }

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
        await reconcilePendingUnknownCommands(with: messagesBySession[sessionId, default: []], sessionId: sessionId)
        guard machine.state == .online, let context = contextForSession(sessionId) else { return }
        do {
            let page = try await transport.loadRecent(machineId: machine.id, runtimeId: context.runtime.id, instanceId: context.instance.id, sessionId: sessionId, limit: 50)
            guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
            await reconcilePendingUnknownCommands(with: page.items, sessionId: sessionId)
            for remoteUser in page.items where remoteUser.role == .user {
                await reconcileOptimisticUserEcho(remoteUser, sessionId: sessionId)
            }
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId)
            await settleRunStateIfAuthoritativeFinalExists(page.items, sessionId: sessionId)
            hasMoreBySession[sessionId] = page.hasMore
            errors[sessionId] = nil
        } catch {
            if generation == lifecycleGeneration, !isSuspended { errors[sessionId] = error.localizedDescription }
        }
    }

    func loadOlder(_ sessionId: String) async {
        guard olderMessageLoads.insert(sessionId).inserted else { return }
        defer { olderMessageLoads.remove(sessionId) }
        let generation = lifecycleGeneration
        guard let first = messagesBySession[sessionId]?.first, hasMoreBySession[sessionId] != false else { return }
        do {
            let page: Page<ChatMessage>
            if machine.state == .online, let context = contextForSession(sessionId) {
                page = try await transport.loadBefore(machineId: machine.id, runtimeId: context.runtime.id, instanceId: context.instance.id, sessionId: sessionId, before: first.cursor, limit: 40)
                guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
            } else {
                let local = try await cache.messagesBefore(sessionId: sessionId, before: first.cursor, limit: 40)
                page = Page(items: local, beforeCursor: local.first?.cursor, hasMore: local.count == 40)
            }
            try? await cache.upsertMessages(page.items)
            merge(page.items, into: sessionId)
            hasMoreBySession[sessionId] = page.hasMore
            errors[sessionId] = nil
        } catch {
            if generation == lifecycleGeneration, !isSuspended { errors[sessionId] = error.localizedDescription }
        }
    }

    @discardableResult
    func send(text: String, runtimeId: String, instanceId: String, sessionId: String, attachments: [PendingAttachment] = [], model: String = "", commandId: UUID = UUID()) async -> Bool {
        guard commandSendsInFlight.insert(commandId).inserted else { return false }
        defer { commandSendsInFlight.remove(commandId) }
        let generation = lifecycleGeneration
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagnosticsLog.shared.record("send_begin", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "hasInput": String(!trimmed.isEmpty), "attachments": String(attachments.count), "commandId": commandId.uuidString])
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
            DiagnosticsLog.shared.record("send_offline", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString], level: "WARN")
            return false
        }
        let activeTransport = transport
        let activeMachineId = machine.id

        commandStates[commandId] = .pending
        var messageCommandPersisted = false
        do {
            var remoteAttachments: [RemoteAttachmentDescriptor] = []
            if !attachments.isEmpty {
                attachmentTransferBySession[sessionId] = AttachmentTransferProgress(completed: 0, total: attachments.count, name: attachments[0].name)
            }
            for (index, attachment) in attachments.enumerated() {
                try Task.checkCancellation()
                attachmentTransferBySession[sessionId] = AttachmentTransferProgress(completed: index, total: attachments.count, name: attachment.name)
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { throw CancellationError() }
                let remote = try await activeTransport.uploadAttachment(
                    machineId: activeMachineId,
                    runtimeId: runtimeId,
                    instanceId: instanceId,
                    sessionId: sessionId,
                    attachment: attachment,
                    operationId: commandId,
                    attachmentIndex: index
                )
                remoteAttachments.append(remote)
                attachmentTransferBySession[sessionId] = AttachmentTransferProgress(completed: index + 1, total: attachments.count, name: attachment.name)
            }
            try Task.checkCancellation()
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { throw CancellationError() }
            attachmentTransferBySession.removeValue(forKey: sessionId)

            let names = remoteAttachments.map(\.name).joined(separator: ", ")
            let displayText = "\(trimmed)\(!names.isEmpty ? "\(trimmed.isEmpty ? "" : "\n\n")[Attachments: \(names)]" : "")"
            let optimistic = ChatMessage(id: commandId.uuidString, sessionId: sessionId, sequence: nil, role: .user, kind: .text, text: displayText, toolName: nil, toolStatus: nil, detail: nil, createdAt: Date())
            merge([optimistic], into: sessionId)
            try? await cache.upsertMessages([optimistic])
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }

            var payload: [String: JSONValue] = ["text": .string(trimmed)]
            if !model.isEmpty { payload["model"] = .string(model) }
            if !remoteAttachments.isEmpty { payload["attachmentIds"] = .array(remoteAttachments.map { .string($0.attachmentId) }) }
            let command = RemoteCommand.make(machineId: activeMachineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "sendMessage", payload: payload, commandId: commandId)
            try? await cache.put(command, key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            messageCommandPersisted = true
            commandStates[commandId] = .executing
            let finalState = try await activeTransport.send(command)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            commandStates[commandId] = finalState
            // A confirmed browser send is not the end of synchronization. Immediately
            // reconcile the authoritative event delta so a missed websocket user echo,
            // generation/progress event, or fast assistant final cannot leave the phone stale.
            await recoverDelta()
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            try? await cache.saveDraft("", sessionId: sessionId)
            if generation == lifecycleGeneration, !isSuspended { errors[sessionId] = nil }
            DiagnosticsLog.shared.record("send_ok", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "state": finalState.rawValue])
            return true
        } catch is CancellationError {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            await removeOptimisticCommandMessage(commandId: commandId, sessionId: sessionId)
            errors[sessionId] = "Attachment upload cancelled before message delivery. The composer keeps your local text/files so you can send again."
            return false
        } catch let error as TransportError where error == .disconnected || error == .timeout {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .unknown
            errors[sessionId] = messageCommandPersisted
                ? "Delivery is unknown after a disconnect/timeout. Use Retry on this message; it replays the exact same command ID and payload."
                : "Attachment transfer was interrupted before message delivery was attempted. Retry from the composer reuses the same operation ID."
            DiagnosticsLog.shared.record("send_unknown_delivery", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "persisted": String(messageCommandPersisted)], level: "WARN")
            return false
        } catch let error as TransportError {
            if case .remote(let code, let message) = error, code == "WEB_SEND_DELIVERY_UNKNOWN" {
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
                attachmentTransferBySession.removeValue(forKey: sessionId)
                commandStates[commandId] = .unknown
                errors[sessionId] = "Delivery is unknown after the ChatGPT page changed. Retry replays the exact same command ID; RemoteAI will reconcile before any duplicate is allowed."
                DiagnosticsLog.shared.record("send_unknown_delivery", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "remoteCode": code, "message": message], level: "WARN")
                await recoverDelta()
                return false
            }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            await removeOptimisticCommandMessage(commandId: commandId, sessionId: sessionId)
            if !trimmed.isEmpty { try? await cache.saveDraft(trimmed, sessionId: sessionId) }
            errors[sessionId] = error.localizedDescription
            DiagnosticsLog.shared.record("send_failed", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "errorType": String(describing: type(of: error))], level: "ERROR")
            return false
        } catch {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            await removeOptimisticCommandMessage(commandId: commandId, sessionId: sessionId)
            if !trimmed.isEmpty { try? await cache.saveDraft(trimmed, sessionId: sessionId) }
            errors[sessionId] = error.localizedDescription
            DiagnosticsLog.shared.record("send_failed", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "errorType": String(describing: type(of: error))], level: "ERROR")
            return false
        }
    }

    func retry(message: ChatMessage, runtimeId: String, instanceId: String, model: String = "") async {
        guard let commandId = UUID(uuidString: message.id) else { return }
        guard commandStates[commandId] == .unknown else { return }
        guard commandSendsInFlight.insert(commandId).inserted else { return }
        defer { commandSendsInFlight.remove(commandId) }
        guard machine.state == .online else {
            errors[message.sessionId] = "PC Offline — reconnect before retrying this unknown delivery."
            return
        }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        do {
            let command: RemoteCommand
            if let stored = try? await cache.get(RemoteCommand.self, key: Self.pendingCommandKey(commandId, machineId: activeMachineId)) {
                command = stored
            } else {
                guard !message.text.contains("[Attachments:") else {
                    errors[message.sessionId] = "The saved attachment retry payload is unavailable. Refresh the conversation before sending anything again."
                    return
                }
                command = RemoteCommand.make(machineId: activeMachineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: message.sessionId, action: "sendMessage", payload: ["text": .string(message.text)], commandId: commandId)
            }
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return }
            commandStates[commandId] = .executing
            let finalState = try await activeTransport.send(command)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return }
            commandStates[commandId] = finalState
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            errors[message.sessionId] = nil
            // A replayed command response proves the side effect result, but the replay
            // itself may not re-emit the original MESSAGE_ADDED event. Re-read the
            // authoritative session so optimistic UI/cache state converges as well.
            await loadSession(message.sessionId)
        } catch let error as TransportError where error == .disconnected || error == .timeout {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return }
            commandStates[commandId] = .unknown
            errors[message.sessionId] = "Delivery is still unknown. Retry will continue to use the same command ID."
        } catch {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return }
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            errors[message.sessionId] = error.localizedDescription
        }
    }

    @discardableResult
    func stop(runtimeId: String, instanceId: String, sessionId: String) async -> Bool {
        if let inFlight = stopTasksBySession[sessionId] {
            return await inFlight.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performStop(runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId)
        }
        stopTasksBySession[sessionId] = task
        let result = await task.value
        stopTasksBySession.removeValue(forKey: sessionId)
        return result
    }

    private func performStop(runtimeId: String, instanceId: String, sessionId: String) async -> Bool {
        guard machine.state == .online else {
            errors[sessionId] = "PC Offline — stop will not be queued blindly."
            return false
        }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        let operationKey = "stop.\(runtimeId).\(instanceId).\(sessionId)"
        let commandId = await pendingOperationCommandId(key: operationKey, machineId: activeMachineId)
        guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
        let command = RemoteCommand.make(machineId: activeMachineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "stopGeneration", commandId: commandId)
        commandStates[command.commandId] = .pending
        do {
            let state = try await activeTransport.send(command)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            commandStates[command.commandId] = state
            await finishPendingOperation(key: operationKey, machineId: activeMachineId, expectedCommandId: commandId)
            setSessionState(sessionId, .idle)
            errors[sessionId] = nil
            return true
        } catch {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            commandStates[command.commandId] = isUnknownDelivery(error) ? .unknown : .failed
            if !isUnknownDelivery(error) { await finishPendingOperation(key: operationKey, machineId: activeMachineId) }
            errors[sessionId] = error.localizedDescription
            return false
        }
    }

    func createSession(
        runtime: RuntimeDescriptor,
        instance: InstanceDescriptor,
        title: String,
        model: String = ""
    ) async -> Bool {
        guard creatingSessions.insert(instance.id).inserted else { return false }
        defer { creatingSessions.remove(instance.id) }
        let generation = lifecycleGeneration
        let effectiveTitle = title.isEmpty ? "New Session" : title
        var payload: [String: JSONValue] = [
            "title": .string(effectiveTitle)
        ]
        if runtime.kind == .codex, !model.isEmpty {
            payload["model"] = .string(model)
        }
        guard machine.state == .online else {
            errors[instance.id] = "PC Offline — new sessions are not queued automatically."
            return false
        }
        let activeTransport = transport
        let activeMachineId = machine.id
        sessionRevisions[instance.id, default: 0] &+= 1
        let operationKey = "createSession.\(runtime.id).\(instance.id).\(effectiveTitle).\(model)"
        do {
            let commandId = await pendingOperationCommandId(key: operationKey, machineId: activeMachineId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            if let created = try await activeTransport.createSession(machineId: activeMachineId, runtimeId: runtime.id, instanceId: instance.id, payload: payload, commandId: commandId) {
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, machine.state == .online, !isSuspended else { return false }
                await finishPendingOperation(key: operationKey, machineId: activeMachineId, expectedCommandId: commandId)
                sessionRevisions[instance.id, default: 0] &+= 1
                sessions.removeAll { $0.id == created.id }
                sessions.insert(created, at: 0)
                errors[instance.id] = nil
                await persistMetadata()
                return true
            } else if activeTransport is MockTransport {
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
                await finishPendingOperation(key: operationKey, machineId: activeMachineId, expectedCommandId: commandId)
                sessionRevisions[instance.id, default: 0] &+= 1
                let local = SessionDescriptor(id: UUID().uuidString, instanceId: instance.id, title: title.isEmpty ? (runtime.kind == .web ? "New Chat" : "New Session") : title, state: .idle, updatedAt: Date())
                sessions.insert(local, at: 0)
                errors[instance.id] = nil
                await persistMetadata()
                return true
            } else {
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
                await finishPendingOperation(key: operationKey, machineId: activeMachineId, expectedCommandId: commandId)
                sessionRevisions[instance.id, default: 0] &+= 1
                await refreshMetadata()
                errors[instance.id] = nil
                return true
            }
        } catch {
            if generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended {
                if !isUnknownDelivery(error) { await finishPendingOperation(key: operationKey, machineId: activeMachineId) }
                errors[instance.id] = error.localizedDescription
            }
            return false
        }
    }

    func savePairing(baseURL: URL, machineId: String, code: String) async throws {
        pairingStage = .preparing
        isSuspended = false
        lifecycleGeneration &+= 1
        restartAfterStart = false
        eventTask?.cancel()
        eventTask = nil
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
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
        webProjectsSnapshotState = nil
        projectConversationSnapshotStateByAlias.removeAll()
        projectConversationLoadingByAlias.removeAll()
        liveRunStatusBySession.removeAll()
        webProjectsSnapshotId = nil
        projectConversationSnapshotIds.removeAll()
        hasLoadedWebProjects = false
        attachmentTransferBySession.removeAll()
        hasMoreBySession.removeAll()
        commandStates.removeAll()
        errors.removeAll()
        tracker = SequenceTracker()
        eventReplayGuard = BoundedReplayGuard(capacity: 8192)
        refreshWebProjectsInFlight = false
        refreshWebProjectsQueued = false
        projectConversationRefreshes.removeAll()
        projectConversationRefreshQueued.removeAll()
        projectConversationPageLoads.removeAll()
        runtimeRefreshes.removeAll()
        sessionRefreshes.removeAll()
        sessionLoads.removeAll()
        olderMessageLoads.removeAll()
        creatingWebProjects.removeAll()
        creatingWebConversations.removeAll()
        creatingSessions.removeAll()
        for task in stopTasksBySession.values { task.cancel() }
        stopTasksBySession.removeAll()
        commandSendsInFlight.removeAll()
        metadataRefreshInFlight = false
        metadataRefreshQueued = false
        webProjectsRevision &+= 1
        projectConversationRevisions.removeAll()
        sessionRevisions.removeAll()

        let config = RemoteAIConfig(relayBaseURL: baseURL, machineId: result.machineId)
        config.saveMetadata()
        transport = CloudflareTransport(config: config)
        machine = MachineMetadata(id: result.machineId, name: machine.name, state: .connecting)
        isPaired = true
        errors["connection"] = nil
        while startInProgress {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
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

    private func pendingOperationCommandId(key: String, machineId: String) async -> UUID {
        let cacheKey = "pending.operation.\(machineId).\(key)"
        if let raw = try? await cache.get(String.self, key: cacheKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        try? await cache.put(id.uuidString.lowercased(), key: cacheKey)
        return id
    }

    private func finishPendingOperation(key: String, machineId: String, expectedCommandId: UUID? = nil) async {
        let cacheKey = "pending.operation.\(machineId).\(key)"
        if let expectedCommandId {
            let raw = try? await cache.get(String.self, key: cacheKey)
            guard raw?.caseInsensitiveCompare(expectedCommandId.uuidString) == .orderedSame else { return }
        }
        try? await cache.remove(key: cacheKey)
    }

    private func isUnknownDelivery(_ error: Error) -> Bool {
        guard let transportError = error as? TransportError else { return false }
        if transportError == .disconnected || transportError == .timeout { return true }
        if case .remote(let code, _) = transportError { return code == "WEB_SEND_DELIVERY_UNKNOWN" }
        return false
    }

    private func removeOptimisticCommandMessage(commandId: UUID, sessionId: String) async {
        let id = commandId.uuidString
        messagesBySession[sessionId]?.removeAll { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.sequence == nil }
        try? await cache.deleteMessage(id: id)
    }

    private func installEventConsumer() {
        eventTask?.cancel()
        let sourceTransport = transport
        let generation = lifecycleGeneration
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await sourceTransport.eventStream()
            for await event in stream {
                guard !Task.isCancelled,
                      generation == self.lifecycleGeneration,
                      !self.isSuspended,
                      self.transport === sourceTransport else { break }
                await self.ingest(event)
            }
        }
    }

    private func startConnectionMonitor() {
        connectionMonitorTask?.cancel()
        let monitoredTransport = transport
        let generation = lifecycleGeneration
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      generation == self.lifecycleGeneration,
                      !self.isSuspended,
                      self.transport === monitoredTransport else { break }
                if !(await monitoredTransport.isConnected) {
                    self.machine.state = .connecting
                    self.connectionPhase = .reconnecting
                    do {
                        try await monitoredTransport.connect()
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else {
                            await monitoredTransport.disconnect()
                            break
                        }
                        self.connectionPhase = .authenticating
                        let authenticatedSequence = try await monitoredTransport.latestSequence(machineId: self.machine.id)
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else {
                            await monitoredTransport.disconnect()
                            break
                        }
                        self.machine.state = .online
                        self.connectionPhase = .online
                        self.errors["connection"] = nil
                        await self.recoverDelta(freshLatestSequence: authenticatedSequence)
                        await self.refreshMetadata()
                    } catch {
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else { break }
                        self.applyConnectionFailure(error)
                        if (error as? TransportError) == .pairingRequired { break }
                    }
                }
            }
        }
    }

    private func applyConnectionFailure(_ error: Error) {
        machine.state = .offline
        DiagnosticsLog.shared.record("connection_failure", fields: ["errorType": String(describing: type(of: error))], level: "ERROR")
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
        guard runtimeRefreshes.insert(runtime.id).inserted else { return }
        defer { runtimeRefreshes.remove(runtime.id) }
        let generation = lifecycleGeneration
        guard machine.state == .online else { return }
        do {
            let rows = try await transport.listInstances(machineId: machine.id, runtimeId: runtime.id)
            guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
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
            if generation == lifecycleGeneration, !isSuspended { errors["runtime.\(runtime.id)"] = error.localizedDescription }
        }
    }

    private func refreshMetadata() async {
        if metadataRefreshInFlight {
            metadataRefreshQueued = true
            return
        }
        metadataRefreshInFlight = true
        let generation = lifecycleGeneration
        defer {
            metadataRefreshInFlight = false
            if metadataRefreshQueued && !isSuspended {
                metadataRefreshQueued = false
                Task { [weak self] in await self?.refreshMetadata() }
            }
        }
        guard machine.state == .online else { return }
        do {
            let remoteRuntimes = try await transport.listRuntimes(machineId: machine.id)
            guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
            if !remoteRuntimes.isEmpty { runtimes = remoteRuntimes }
            // Runtime instance discovery is intentionally lazy. Each RuntimeView
            // refreshes only the selected runtime, which keeps app launch and
            // reconnects from scanning every Codex workspace.
            errors["sync"] = nil
            await persistMetadata()
        } catch {
            if generation == lifecycleGeneration, !isSuspended { errors["sync"] = error.localizedDescription }
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

    private func isSyntheticConversationTitle(_ title: String, conversationAlias: String?) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.caseInsensitiveCompare("ChatGPT Conversation") == .orderedSame { return true }
        if value.range(of: #"^ChatGPT [0-9a-fA-F]{8}$"#, options: .regularExpression) != nil { return true }
        if let conversationAlias, value.caseInsensitiveCompare(conversationAlias) == .orderedSame { return true }
        return false
    }

    @discardableResult
    private func mergeConversationTitleHints(_ hints: [WebConversationDescriptor], projectAlias: String) -> Bool {
        guard var current = projectConversationsByAlias[projectAlias], !current.isEmpty else { return false }
        let byAlias = Dictionary(uniqueKeysWithValues: hints.compactMap { hint -> (String, WebConversationDescriptor)? in
            guard let alias = hint.conversationAlias, hint.projectAlias == projectAlias else { return nil }
            return (alias, hint)
        })
        var changed = false
        for index in current.indices {
            guard let alias = current[index].conversationAlias,
                  let hint = byAlias[alias],
                  isSyntheticConversationTitle(current[index].displayTitle, conversationAlias: alias),
                  !isSyntheticConversationTitle(hint.displayTitle, conversationAlias: alias) else { continue }
            let prior = current[index]
            current[index] = WebConversationDescriptor(
                localConversationId: prior.localConversationId,
                canonicalUrl: prior.canonicalUrl,
                projectId: prior.projectId,
                displayTitle: hint.displayTitle,
                projectAlias: prior.projectAlias,
                conversationAlias: prior.conversationAlias,
                lastVisited: prior.lastVisited,
                updatedAt: max(prior.updatedAt, hint.updatedAt)
            )
            changed = true
        }
        if changed { projectConversationsByAlias[projectAlias] = current }
        return changed
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

    private func recoverDelta(freshLatestSequence: Int64? = nil) async {
        guard machine.state == .online else { return }
        if deltaRecoveryInFlight {
            // Event ingestion and the reconnect monitor can both notice the same gap
            // while MainActor is suspended in network I/O. Coalesce them instead of
            // creating parallel getChangesAfterCursor loops. One queued pass runs after
            // the active pass so an event that arrived after its final page is not lost.
            deltaRecoveryQueued = true
            return
        }
        deltaRecoveryInFlight = true
        let generation = lifecycleGeneration
        defer {
            deltaRecoveryInFlight = false
            if deltaRecoveryQueued,
               generation == lifecycleGeneration,
               machine.state == .online,
               !isSuspended {
                deltaRecoveryQueued = false
                Task { [weak self] in await self?.recoverDelta() }
            } else {
                deltaRecoveryQueued = false
            }
        }

        var cursor = (try? await cache.lastSequence()) ?? 0
        do {
            if cursor == 0 && instances.isEmpty && sessions.isEmpty && webProjects.isEmpty {
                // A fresh install has no local state to reconcile. Reuse the authenticated
                // getStatus sequence when startup/reconnect already fetched it, so one
                // initialization never issues a duplicate status request.
                if let freshLatestSequence {
                    cursor = freshLatestSequence
                } else {
                    cursor = try await transport.latestSequence(machineId: machine.id)
                }
                try? await cache.setLastSequence(cursor)
                tracker = SequenceTracker(lastSequence: cursor)
                return
            }
            while true {
                guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
                let result = try await transport.delta(machineId: machine.id, after: cursor)
                guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
                for event in result.events where event.sequence > cursor {
                    try ProtocolSecurity.validate(event, expectedMachineId: machine.id)
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
            if generation == lifecycleGeneration, !isSuspended { errors["sync"] = error.localizedDescription }
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
            if event.payload["partial"]?.boolValue != false {
                // A transient event can arrive even when GENERATION_STARTED was lost in
                // transit. Treat streaming content itself as proof that the run is busy
                // so the progress strip remains visible on the phone.
                setSessionState(sessionId, .busy)
                liveRunStatusBySession[sessionId] = processStatusLabel(for: content)
            }
        case "MESSAGE_ADDED":
            if let server = try? JSONValue.object(event.payload).decode(ServerMessage.self) {
                let base = server.chatMessage
                if base.role == .assistant {
                    discardStreamingPlaceholder(sessionId: sessionId)
                    // MESSAGE_ADDED is the durable final boundary. Converge the visible
                    // run state even if the following GENERATION_STOPPED event is lost.
                    setSessionState(sessionId, .idle)
                    liveRunStatusBySession.removeValue(forKey: sessionId)
                }
                if base.role == .user { await reconcileOptimisticUserEcho(base, sessionId: sessionId) }
                let message = ChatMessage(id: base.id, sessionId: base.sessionId, sequence: event.sequence, role: base.role, kind: base.kind, text: base.text, toolName: nil, toolStatus: nil, detail: nil, createdAt: base.createdAt)
                merge([message], into: sessionId)
                try? await cache.upsertMessages([message])
            }
        case "TOOL_STARTED", "TOOL_FINISHED":
            let completed = event.type == "TOOL_FINISHED"
            if !completed { setSessionState(sessionId, .busy) }
            let toolValue = event.payload["tool"]
            let toolObject = toolValue?.objectValue
            let rawToolName = toolValue?.stringValue ?? toolObject?["name"]?.stringValue ?? toolObject?["type"]?.stringValue ?? "Tool"
            let toolName: String
            switch rawToolName {
            case "command_execution": toolName = "Command"
            case "mcp_tool_call": toolName = "MCP Tool"
            case "web_search": toolName = "Web Search"
            default: toolName = rawToolName
            }
            let detail = event.payload["summary"]?.stringValue
                ?? toolObject?["summary"]?.stringValue
                ?? event.payload["provider"]?.stringValue
            let stableToolId = toolObject?["id"]?.stringValue
            let messageId = stableToolId.map { "tool-\(sessionId)-\($0)" } ?? event.eventId.uuidString
            let message = ChatMessage(id: messageId, sessionId: sessionId, sequence: event.sequence, role: .tool, kind: .toolEvent, text: "", toolName: toolName, toolStatus: completed ? "Completed" : "Running", detail: detail, createdAt: event.createdAt)
            merge([message], into: sessionId)
            try? await cache.upsertMessages([message])
            if rawToolName == "ChatGPT Web", let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                liveRunStatusBySession[sessionId] = completed ? "ChatGPT Web 已完成" : detail
            } else {
                liveRunStatusBySession[sessionId] = completed ? "\(toolName) 已完成，继续处理中…" : "正在运行 \(toolName)…"
            }
        case "GENERATION_STARTED":
            setSessionState(sessionId, .busy)
            liveRunStatusBySession[sessionId] = "ChatGPT 正在处理…"
        case "GENERATION_STOPPED":
            flushStreaming(sessionId: sessionId)
            setSessionState(sessionId, .idle)
            liveRunStatusBySession.removeValue(forKey: sessionId)
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

    private func processStatusLabel(for content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "正在生成回答…" }
        let lower = trimmed.lowercased()
        if lower == "thinking" || lower.hasPrefix("thinking ") { return "思考中…" }
        if lower.contains("analyzing image") || lower.contains("analysing image") { return "正在分析图片…" }
        if lower.contains("searching the web") || lower == "searching" { return "正在搜索网页…" }
        if lower.contains("reading") && trimmed.count < 120 { return trimmed }
        if !trimmed.contains("\n"), trimmed.count <= 80 { return trimmed }
        return "正在生成回答…"
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

    private func settleRunStateIfAuthoritativeFinalExists(_ remote: [ChatMessage], sessionId: String) async {
        guard let latestUserIndex = remote.lastIndex(where: { $0.role == .user }) else { return }
        let suffixStart = remote.index(after: latestUserIndex)
        guard suffixStart < remote.endIndex,
              remote[suffixStart...].contains(where: { $0.role == .assistant && $0.kind == .text && $0.toolStatus != "Streaming" }) else { return }

        discardStreamingPlaceholder(sessionId: sessionId)
        liveRunStatusBySession.removeValue(forKey: sessionId)
        setSessionState(sessionId, .idle)

        var changed: [ChatMessage] = []
        if var local = messagesBySession[sessionId] {
            for index in local.indices where local[index].kind == .toolEvent && local[index].toolStatus == "Running" {
                local[index].toolStatus = "Completed"
                changed.append(local[index])
            }
            messagesBySession[sessionId] = local
        }
        if !changed.isEmpty { try? await cache.upsertMessages(changed) }
    }

    private func reconcilePendingUnknownCommands(with remote: [ChatMessage], sessionId: String) async {
        let unknownIds = commandStates.compactMap { $0.value == .unknown ? $0.key : nil }
        guard !unknownIds.isEmpty else { return }
        for id in unknownIds {
            guard let command = try? await cache.get(RemoteCommand.self, key: Self.pendingCommandKey(id, machineId: machine.id)),
                  command.sessionId == sessionId else { continue }
            let text = command.payload["text"]?.stringValue ?? ""
            let delivered = remote.contains { message in
                guard message.role == .user else { return false }
                if message.id.caseInsensitiveCompare(id.uuidString) == .orderedSame { return true }
                guard !text.isEmpty, message.text == text else { return false }
                return abs(message.createdAt.timeIntervalSince(command.createdAt)) < 300
            }
            if delivered {
                commandStates[id] = .completed
                try? await cache.remove(key: Self.pendingCommandKey(id, machineId: machine.id))
            }
        }
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
