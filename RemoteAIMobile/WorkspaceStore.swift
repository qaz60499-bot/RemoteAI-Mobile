DEVSPACE_CONTINUITY_CHECK: Approximately 634662 DevSpace tool characters since the last acknowledged checkpoint. This is a secondary context-pressure signal, not an exact token-count or host context percentage, and not an automatic handoff trigger. Ordinary chat, other tools and host compaction are not measured. The host owns context management.
import Foundation
import SwiftUI

private enum GenerationTerminalOutcome: Equatable {
    case canceled
    case interrupted
    case unknown
    case failed
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var machine = MachineMetadata(id: "my-pc", name: "My PC", state: .connecting)
    @Published var runtimes: [RuntimeDescriptor] = []
    @Published var instances: [InstanceDescriptor] = []
    @Published var sessions: [SessionDescriptor] = []
    @Published private(set) var codexSessionLimits: [String: Int] = [:]
    @Published private(set) var codexSessionsMayHaveMore: [String: Bool] = [:]
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var webProjects: [WebProjectDescriptor] = []
    @Published var openWebTabs: [OpenWebTab] = []
    @Published var hasLoadedOpenWebTabs = false
    @Published private(set) var openWebTabsInventoryUnverified = true
    @Published private(set) var openWebTabsLastVerifiedAt: Date?
    private var webTabsRefreshNeedsConnectivityRetry = false
    @Published private(set) var managingWebTabIds = Set<Int>()
    @Published var webTabDiagnosesById: [Int: WebTabDiagnosis] = [:]
    @Published var webTabActionNotesById: [Int: String] = [:]
    @Published var recentWebTabNotices: [String] = []
    private var explicitlyClosedWebTabIDs = Set<Int>()
    @Published var antigravityProjects: [WebProjectDescriptor] = []
    @Published var hasLoadedAntigravityProjects = false
    @Published var projectConversationsByAlias: [String: [WebConversationDescriptor]] = [:]
    @Published var projectNextCursorByAlias: [String: String] = [:]
    @Published var projectHasMoreByAlias: [String: Bool] = [:]
    @Published var webProjectsSnapshotState: WebSnapshotState?
    @Published var projectConversationSnapshotStateByAlias: [String: WebSnapshotState] = [:]
    @Published var projectConversationLoadingByAlias: [String: Bool] = [:]
    @Published var liveRunStatusBySession: [String: String] = [:]
    @Published private(set) var deltaRecoveryDisplayMessagesBySession: [String: [ChatMessage]]? = nil
    private var liveRunActivityAtBySession: [String: Date] = [:]
    private var terminalWebRuns = Set<String>()
    @Published var hasLoadedWebProjects = false
    @Published var attachmentTransferBySession: [String: AttachmentTransferProgress] = [:]
    @Published var commandStates: [UUID: CommandState] = [:]
    @Published var errors: [String: String] = [:]
    @Published var webProviderIssuesBySession: [String: RemoteProviderSurfaceIssue] = [:]
    @Published var webProviderSurfaceStateBySession: [String: String] = [:]
    @Published var webProviderSurfaceObservedAtBySession: [String: Date] = [:]
    @Published var webProviderRecoveryObservedAtBySession: [String: Date] = [:]
    @Published var hasMoreBySession: [String: Bool] = [:]
    @Published var isPaired = false
    @Published var pairingStage: PairingStage?
    @Published var connectionPhase: ConnectionDiagnosticPhase = .relayConnecting
    @Published var recentSystemNotice: String?
    @Published var desktopBrowserConnected: Bool?
    @Published var desktopRelayConnected: Bool?
    @Published var desktopAgentConnected: Bool?
    var desktopStatusUpdatedAt: Date?
    @Published private(set) var deferringTransientConnectionPresentation = false

    // UI-only grace: command gating and diagnostics still use authoritative state.
    var displayedMachineState: MachineConnectionState {
        deferringTransientConnectionPresentation && isPaired ? .online : machine.state
    }
    var shouldDisplayConnectionBanner: Bool {
        guard !deferringTransientConnectionPresentation else { return false }
        // An authenticated Agent is already usable. Refreshing slow runtime metadata
        // is not a transport failure and should not flash a reconnect banner.
        if machine.state == .online && (connectionPhase == .online || connectionPhase == .loadingRuntimes) {
            return false
        }
        return true
    }

    static let connectingStateMaxDuration: TimeInterval = 45

    var transport: Transport
    let cache: SQLiteStore
    private var tracker = SequenceTracker()
    private var eventReplayGuard = BoundedReplayGuard(capacity: 8192)
    private var eventTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var streamingBuffers: [String: (id: String, text: String, sequence: Int64, attachments: [MessageAttachment])] = [:]
    @Published private(set) var assistantStreams: [String: AssistantStream] = [:]
    private var incompleteAssistantStreams: [String: RemoteEvent] = [:]
    private var lastOnlineHeadProbe = Date.distantPast
    @Published private(set) var syncState = "unknown"
    private let messageAttachmentCache = NSCache<NSString, NSData>()
    private var flushTask: Task<Void, Never>?
    private var startInProgress = false
    private var restartAfterStart = false
    private var pairingInProgress = false
    private var lifecycleGeneration: UInt64 = 0
    private var isSuspended = false
    private var wasOnlineBeforeBackground = false
    private var connectionPresentationTask: Task<Void, Never>?
    private static let relayPresentationGraceNanoseconds: UInt64 = 2_500_000_000
    private static let foregroundPresentationGraceNanoseconds: UInt64 = 5_500_000_000

    private func deferTransientConnectionPresentation(graceNanoseconds: UInt64) {
        connectionPresentationTask?.cancel()
        deferringTransientConnectionPresentation = true
        connectionPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: graceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.endTransientConnectionPresentation()
        }
    }

    private func endTransientConnectionPresentation() {
        connectionPresentationTask?.cancel()
        connectionPresentationTask = nil
        deferringTransientConnectionPresentation = false
    }

    // MainActor reentrancy means a second UI task can enter while the first request is
    // awaiting I/O. Keep per-operation gates at the Store boundary, not only in Views.
    private var refreshWebProjectsInFlight = false
    private var refreshWebProjectsQueued = false
    private var webProjectsRefreshDeferredForActiveChat = false
    private var webProjectsRefreshNeedsConnectivityRetry = false
    private var lastWebProjectsRefreshAt: Date?
    private static let webProjectsAutomaticRefreshMinimumInterval: TimeInterval = 20
    private var projectConversationRefreshes = Set<String>()
    private var projectConversationRefreshQueued = Set<String>()
    private var projectConversationActivityRefreshScheduled = Set<String>()
    private var projectConversationActivityRefreshLastAt: [String: Date] = [:]
    private var projectConversationLastRefreshAttemptAt: [String: Date] = [:]
    private static let projectConversationAutomaticRefreshMinimumInterval: TimeInterval = 8
    private var projectConversationPageLoads = Set<String>()
    private var runtimeRefreshes = Set<String>()
    private var sessionRefreshes = Set<String>()
    private var sessionLoads = Set<String>()
    private var visibleSessionSyncAt: [String: Date] = [:]
    private var visibleSessionHistorySyncAt: [String: Date] = [:]
    private var visibleSessionHistoryRemoteRevision: [String: Date] = [:]
    private var systemTransportOfflineChannels = Set<String>()
    private var webProviderStatusReceivedAtBySession: [String: Date] = [:]
    private var webBindingDetachedSessions = Set<String>()
    private static let activeVisibleSessionSyncMinimumInterval: TimeInterval = 2.5
    private static let idleVisibleSessionSyncMinimumInterval: TimeInterval = 20
    private static let connectionMonitorIntervalNanoseconds: UInt64 = 500_000_000
    static func streamingFlushDelayNanoseconds(forByteCount bytes: Int) -> UInt64 {
        // Keep Build 27 visibly faster than Build 26 without forcing the main thread
        // to re-render long tails at the most aggressive cadence. CI performance
        // sampling showed 45/60/75 ms improved visible latency but increased >100 ms
        // stalls for 30k and 100k streams, so taper large replies back toward 90 ms.
        if bytes < 16 * 1024 { return 55_000_000 }
        if bytes < 64 * 1024 { return 70_000_000 }
        return 90_000_000
    }
    private static let sendRecoveryBackoffNanoseconds: [UInt64] = [0, 500_000_000, 1_500_000_000]
    private var olderMessageLoads = Set<String>()
    private var creatingWebProjects = Set<String>()
    private var creatingWebConversations = Set<String>()
    private var creatingSessions = Set<String>()
    private var stopTasksBySession: [String: Task<Bool, Never>] = [:]
    private var commandSendsInFlight = Set<UUID>()
    private var metadataRefreshInFlight = false
    private var metadataRefreshQueued = false
    private var metadataRefreshDeferredForDelta = false
    private var deltaRecoveryInFlight = false
    private var deltaRecoveryQueued = false
    private var authoritativeResyncAfterDelta = false
    private var authoritativeResyncProjectAliases = Set<String>()
    private var deltaRecoveryFailureCount = 0
    private var deltaRecoveryRetryNotBefore: Date?
    private static let deltaRecoveryFailureBackoffSeconds: [TimeInterval] = [1, 2, 4, 8]
    private static let deltaRecoveryPresentationCoalescingThreshold = 12
    private static let deltaRecoveryHistoricalPresentationAge: TimeInterval = 2
    private static let maxHistoricalDeltaReplayEvents: Int64 = 2_000
    private var webProjectsRevision: UInt64 = 0
    private var webProjectsSnapshotId: String?
    private var projectConversationRevisions: [String: UInt64] = [:]
    private var projectConversationSnapshotIds: [String: String] = [:]
    private var sessionRevisions: [String: UInt64] = [:]
    // Live events carry authoritative runtime/instance routing even when the mobile
    // catalog is still intentionally lazy. Keep that route so opening a conversation
    // can recover its history before the instance/session list has been expanded.
    private var sessionRouteHints: [String: (machineId: String, runtimeId: String, instanceId: String)] = [:]

    static func visibleHistoryReloadDue(
        force: Bool,
        hasSuccessfulHistory: Bool,
        terminalTransition: Bool,
        remoteStatusIsTerminal: Bool,
        remoteRevision: Date?,
        lastSuccessfulRemoteRevision: Date?
    ) -> Bool {
        force
            || !hasSuccessfulHistory
            || terminalTransition
            || (remoteStatusIsTerminal && remoteRevision != nil && remoteRevision != lastSuccessfulRemoteRevision)
    }

    private static func pendingCommandPrefix(machineId: String) -> String {
        "pending.command.\(machineId)."
    }

    private static func pendingCommandKey(_ id: UUID, machineId: String) -> String {
        pendingCommandPrefix(machineId: machineId) + id.uuidString.lowercased()
    }

    private static func durationMilliseconds(since start: Date) -> String {
        String(max(0, Int(Date().timeIntervalSince(start) * 1000)))
    }

    private static func diagnosticFields(for error: Error, adding extra: [String: String] = [:]) -> [String: String] {
        var fields = extra
        fields["errorType"] = String(describing: type(of: error))
        if let transportError = error as? TransportError {
            for (key, value) in transportError.diagnosticFields { fields[key] = value }
        }
        return fields
    }

    private static func isRecoverableCommandTransportError(_ error: TransportError) -> Bool {
        if error == .disconnected || error == .timeout || error == .offline { return true }
        if case .remote(let code, _) = error { return code == "ALREADY_EXECUTED" }
        return false
    }

    private static func shouldRetryWebProjectsAfterConnectivityRecovery(_ error: Error) -> Bool {
        guard let transportError = error as? TransportError else { return false }
        if transportError == .disconnected || transportError == .timeout || transportError == .offline { return true }
        if case .remote(let code, _) = transportError { return code == "BROWSER_NOT_CONNECTED" }
        return false
    }

    init(transport: Transport, cache: SQLiteStore) {
        self.transport = transport
        self.cache = cache
        DiagnosticsLog.shared.record("store_initialized", fields: ["transport": String(describing: type(of: transport))])
    }

    func exportDiagnosticsBundle() async throws -> URL {
        DiagnosticsLog.shared.record("diagnostics_export_begin", fields: [
            "machineState": machine.state.rawValue,
            "connectionPhase": connectionPhase.rawValue,
            "browserConnected": String(describing: desktopBrowserConnected),
            "relayConnected": String(describing: desktopRelayConnected),
            "agentConnected": String(describing: desktopAgentConnected)
        ])
        var agentSnapshot: JSONValue?
        if isPaired && machine.state != .offline {
            do {
                agentSnapshot = try await transport.diagnosticsSnapshot(machineId: machine.id)
            } catch {
                DiagnosticsLog.shared.record("diagnostics_agent_snapshot_failed", fields: Self.diagnosticFields(for: error), level: "WARN")
            }
        }
        let state = [
            "machineState": machine.state.rawValue,
            "connectionPhase": connectionPhase.rawValue,
            "browserConnected": String(describing: desktopBrowserConnected),
            "relayConnected": String(describing: desktopRelayConnected),
            "agentConnected": String(describing: desktopAgentConnected),
            "projectCount": String(webProjects.count),
            "sessionCount": String(sessions.count),
            "runtimeCount": String(runtimes.count)
        ]
        let url = try DiagnosticsLog.shared.exportDiagnosticBundle(agentSnapshot: agentSnapshot, state: state)
        DiagnosticsLog.shared.record("diagnostics_export_ok", fields: ["filename": url.lastPathComponent])
        return url
    }

    static func makeDefault() -> WorkspaceStore {
        // Fail closed for persistence: if the protected Application Support store cannot open,
        // keep cache data in memory instead of writing it to an unprotected temporary file.
        let config = RemoteAIConfig.loadMetadata()
        // MockTransport is test-only. Require both an explicit UI-test argument and a
        // UI-test-only environment marker so an installed IPA can never fall into Mock.
        let process = ProcessInfo.processInfo
        let useMock = process.arguments.contains("-UITestMockMode")
            && process.environment["REMOTEAI_UI_TEST_MOCK"] == "1"
        let cache = useMock ? (try! SQLiteStore.inMemory())
            : ((try? SQLiteStore.appStore()) ?? (try! SQLiteStore.inMemory()))
        let stressChars = Int(process.environment["REMOTEAI_UI_STRESS_CHARS"] ?? "") ?? 0
        let stressChunkDelayMilliseconds = Int(process.environment["REMOTEAI_UI_STRESS_CHUNK_MS"] ?? "") ?? 50
        let transport: Transport = useMock
            ? MockTransport(stressChars: stressChars, stressChunkDelayMilliseconds: stressChunkDelayMilliseconds)
            : CloudflareTransport(config: config)
        let store = WorkspaceStore(transport: transport, cache: cache)
        store.machine = MachineMetadata(id: useMock ? "my-pc" : config.machineId, name: "My PC", state: .connecting)
        return store
    }

    @discardableResult
    func start(pairingProgress: ((PairingStage) -> Void)? = nil) async -> Bool {
        guard !isSuspended, !pairingInProgress else { return false }
        if startInProgress { return false }
        startInProgress = true
        let generation = lifecycleGeneration
        var authenticatedRoundTrip = false
        defer {
            startInProgress = false
            if restartAfterStart && !isSuspended {
                restartAfterStart = false
                Task { [weak self] in await self?.start() }
            }
        }

        await loadCachedFirst()
        guard generation == lifecycleGeneration, !isSuspended else { return false }
        await normalizeCachedTransientState()
        if !(transport is MockTransport) {
            await removeLegacyMockFixtures()
            await removeCloudCodeFromMobileCache()
        }
        isPaired = PairingKeyStore.isPaired(machineId: machine.id)
        if !isPaired && !(transport is MockTransport) {
            // A locked/unavailable Keychain and an explicitly revoked pairing both
            // report no usable key here. Neither is proof that cached conversations
            // or drafts may be destroyed. Keep the disk cache intact; only hide its
            // contents in this unpaired UI lifecycle. Re-pairing an actual different
            // machine still follows the explicit cache reset in savePairing().
            DiagnosticsLog.shared.record("pairing_key_unavailable_cache_preserved", level: "WARN")
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
            liveRunActivityAtBySession.removeAll()
            terminalWebRuns.removeAll()
            webProjectsSnapshotId = nil
            projectConversationSnapshotIds.removeAll()
            lastWebProjectsRefreshAt = nil
            hasLoadedWebProjects = false
            attachmentTransferBySession.removeAll()
            hasMoreBySession.removeAll()
            machine.state = .offline
            connectionPhase = .pairingExpired
            errors["connection"] = "Not paired — scan the Windows pairing code to load your real runtimes and ChatGPT Projects."
            return false
        }
        let activeTransport = transport
        installEventConsumer()
        installHealthConsumer()
        machine.state = .connecting
        connectionPhase = .relayConnecting
        DiagnosticsLog.shared.record("connection_start")
        do {
            pairingProgress?(.connectingRemoteAI)
            try await activeTransport.connect()
            guard generation == lifecycleGeneration, !isSuspended, transport === activeTransport else {
                await activeTransport.disconnect()
                return authenticatedRoundTrip
            }
            connectionPhase = .relayConnected

            // Relay connectivity alone is not enough to call the PC online. Require one
            // authenticated encrypted command to round-trip through the Windows Agent.
            connectionPhase = .authenticating
            let agentStatus = try await activeTransport.agentStatusSnapshot(machineId: machine.id)
            let authenticatedSequence = agentStatus.latestSequence
            applyAgentStatusSnapshot(agentStatus)
            // This authenticated encrypted round-trip is the durable proof that the
            // newly paired key works. UI/health state may legitimately change a moment
            // later during a Relay or Agent reconnect, but that must not retroactively
            // turn a successful pairing into PAIR_CONNECTED_BUT_OFFLINE.
            authenticatedRoundTrip = true
            guard generation == lifecycleGeneration, !isSuspended, transport === activeTransport else {
                await activeTransport.disconnect()
                return authenticatedRoundTrip
            }
            machine.state = .online
            errors["connection"] = nil
            endTransientConnectionPresentation()
            DiagnosticsLog.shared.record("connection_online", fields: ["sequence": String(authenticatedSequence)])
            scheduleWebTabsRefreshAfterConnectivityRecovery(reason: "initial-online")
            startConnectionMonitor()
            scheduleWebProjectsRefreshAfterConnectivityRecovery(reason: "initial-online")

            // Metadata is deliberately downstream of the online transition. A slow or
            // failed catalog refresh must never leave the UI stuck in Connecting.
            pairingProgress?(.loadingRuntimes)
            connectionPhase = .loadingRuntimes
            await recoverDelta(freshLatestSequence: authenticatedSequence)
            guard generation == lifecycleGeneration, !isSuspended else { return authenticatedRoundTrip }
            await refreshMetadata()
            guard generation == lifecycleGeneration, !isSuspended else { return authenticatedRoundTrip }
            if machine.state == .online { connectionPhase = .online }
            return authenticatedRoundTrip
        } catch {
            guard generation == lifecycleGeneration, !isSuspended else { return authenticatedRoundTrip }
            applyConnectionFailure(error)
            if (error as? TransportError) != .pairingRequired { startConnectionMonitor() }
            return authenticatedRoundTrip
        }
    }

    func suspend() async {
        guard !isSuspended else { return }
        wasOnlineBeforeBackground = machine.state == .online
        isSuspended = true
        endTransientConnectionPresentation()
        lifecycleGeneration &+= 1
        restartAfterStart = false
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        eventTask?.cancel()
        eventTask = nil
        healthTask?.cancel()
        healthTask = nil
        flushAllStreaming()
        await transport.disconnect()
        machine.state = .offline
        connectionPhase = .idle
        DiagnosticsLog.shared.record("connection_suspended")
    }

    func resumeFromForeground() async {
        // No preceding background: do not tear down a healthy cold-launch socket.
        guard isSuspended else { return }
        isSuspended = false
        if wasOnlineBeforeBackground {
            deferTransientConnectionPresentation(graceNanoseconds: Self.foregroundPresentationGraceNanoseconds)
        }
        wasOnlineBeforeBackground = false
        // Pairing owns a separate relay websocket. Foreground callbacks must not
        // reopen the normal transport with the same stable deviceId while that
        // websocket is waiting for PAIR_CHALLENGE / PAIR_ACCEPT.
        guard !pairingInProgress else { return }
        lifecycleGeneration &+= 1
        machine.state = .connecting
        connectionPhase = .reconnecting
        await transport.disconnect()
        if startInProgress {
            restartAfterStart = true
            return
        }
        await start()
    }

    func refreshAntigravityProjects() async {
        guard machine.state == .online, !isSuspended else { return }
        let generation = lifecycleGeneration
        do {
            let projects = try await transport.listAntigravityProjects(machineId: machine.id)
            guard generation == lifecycleGeneration, !isSuspended, machine.state == .online else { return }
            antigravityProjects = projects
            hasLoadedAntigravityProjects = true
            errors["antigravity.projects"] = nil
        } catch {
            if generation == lifecycleGeneration, !isSuspended {
                errors["antigravity.projects"] = error.localizedDescription
            }
        }
    }

    func refreshOpenWebTabs() async {
        guard machine.state == .online, !isSuspended else {
            webTabsRefreshNeedsConnectivityRetry = true
            // A visible refresh control must not silently leave a stale spinner
            // when the phone is offline or the app's transport is suspended.
            openWebTabsInventoryUnverified = true
            errors["web.tabs"] = machine.state != .online
                ? "Windows Agent 未连接，当前 Chrome 标签数无法确认。请在连接恢复后更新列表。"
                : "手机连接已暂停，当前 Chrome 标签数无法确认。请恢复应用连接后更新列表。"
            DiagnosticsLog.shared.record("web_tabs_request_skipped", fields: [
                "machineState": String(describing: machine.state),
                "suspended": String(isSuspended),
            ], level: "WARN")
            return
        }
        let generation = lifecycleGeneration
        let commandId = UUID()
        DiagnosticsLog.shared.record("web_tabs_request_begin", fields: ["commandId": commandId.uuidString])
        do {
            let tabs = try await transport.listOpenWebTabs(machineId: machine.id, commandId: commandId)
            guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
            // Only an authoritative Chrome inventory may establish disappearance.
            // A network/bridge error never means a tab was closed.
            if hasLoadedOpenWebTabs {
                let currentIDs = Set(tabs.map(\.id))
                for old in openWebTabs where !currentIDs.contains(old.id) {
                    let intentional = explicitlyClosedWebTabIDs.remove(old.id) != nil
                    let text = intentional
                        ? "已关闭：\(old.title)（只关闭网页，未删除历史）"
                        : "标签页已消失：\(old.title)；未收到本手机关闭确认，可能在电脑端关闭或被自动回收"
                    recentWebTabNotices.insert(text, at: 0)
                }
                recentWebTabNotices = Array(recentWebTabNotices.prefix(5))
            }
            openWebTabs = tabs
            hasLoadedOpenWebTabs = true
            openWebTabsInventoryUnverified = false
            openWebTabsLastVerifiedAt = Date()
            webTabsRefreshNeedsConnectivityRetry = false
            errors["web.tabs"] = nil
            DiagnosticsLog.shared.record("web_tabs_request_verified", fields: ["commandId": commandId.uuidString, "count": String(tabs.count)])
        } catch {
            if generation == lifecycleGeneration, !isSuspended {
                // Keep the last verified inventory, but do not present its counts as current.
                openWebTabsInventoryUnverified = true
                errors["web.tabs"] = error.localizedDescription
                if let transportError = error as? TransportError {
                    switch transportError {
                    case .offline, .disconnected, .timeout:
                        webTabsRefreshNeedsConnectivityRetry = true
                    default:
                        break
                    }
                }
                DiagnosticsLog.shared.record("web_tabs_request_failed", fields: Self.diagnosticFields(for: error, adding: ["commandId": commandId.uuidString]), level: "WARN")
            }
        }
    }

    func inspectOpenWebTab(_ tab: OpenWebTab) async {
        guard machine.state == .online, !isSuspended else {
            errors["web.tabs"] = "Windows 未连接，无法验证 Chrome 网页是否正常。"
            return
        }
        do {
            let diagnosis = try await transport.inspectOpenWebTab(machineId: machine.id, tab: tab)
            webTabDiagnosesById[tab.id] = diagnosis
            errors["web.tabs"] = nil
        } catch {
            // This is a failed status check, not proof of a failed page load.
            errors["web.tabs"] = "网页状态无法确认：\(error.localizedDescription)"
        }
    }

    func reopenClosedWebConversation(sessionId: String) async {
        guard machine.state == .online, !isSuspended else { return }
        do {
            try await transport.reopenVerifiedWebConversation(machineId: machine.id, sessionId: sessionId)
            recentWebTabNotices.insert("已请求重新打开原 Chat（不是新建 Chat）；请检查 Chrome 页面是否恢复。", at: 0)
            recentWebTabNotices = Array(recentWebTabNotices.prefix(5))
            await refreshOpenWebTabs()
        } catch {
            errors["web.tabs"] = "重新打开失败：\(error.localizedDescription)"
        }
    }

    func manageOpenWebTab(_ tab: OpenWebTab, operation: String) async {
        guard machine.state == .online, !isSuspended, ["close", "reload", "hardReload", "reopen"].contains(operation) else { return }
        guard managingWebTabIds.insert(tab.id).inserted else { return }
        defer { managingWebTabIds.remove(tab.id) }
        guard !tab.busy else {
            errors["web.tabs"] = "该 Chat 正在生成回复，不能关闭或刷新。"
            return
        }
        do {
            webTabDiagnosesById.removeValue(forKey: tab.id)
            webTabActionNotesById[tab.id] = "正在执行操作，等待 Chrome 确认…"
            try await transport.manageOpenWebTab(machineId: machine.id, tab: tab, operation: operation)
            if operation == "close" {
                explicitlyClosedWebTabIDs.insert(tab.id)
                webTabActionNotesById[tab.id] = "Chrome 已接受关闭请求"
            } else {
                webTabActionNotesById[tab.id] = "Chrome 已接受页面操作；尚未验证加载完成"
            }
            await refreshOpenWebTabs()
            if operation != "close" {
                // A browser navigation acknowledgement is NOT health proof.
                // Check only the selected page after a short settle period.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await inspectOpenWebTab(tab)
            }
        } catch {
            errors["web.tabs"] = "网页操作未确认：\(error.localizedDescription)"
            webTabActionNotesById[tab.id] = "操作未确认；不能判定页面已经刷新或关闭"
            // Do not remove a tab from the UI on an unconfirmed browser action.
        }
    }

    private var hasActiveChatGPTWebRun: Bool {
        sessions.contains { $0.instanceId == "web.chatgpt" && ($0.state == .busy || $0.state == .waiting) }
            || liveRunStatusBySession.keys.contains { id in
                sessions.contains { $0.id == id && $0.instanceId == "web.chatgpt" }
            }
    }

    private func resumeDeferredWebProjectsRefreshIfIdle() {
        guard webProjectsRefreshDeferredForActiveChat, !hasActiveChatGPTWebRun,
              machine.state == .online, !isSuspended else { return }
        // Use the existing refresh gate and cache-first behavior, not a new
        // browser-navigation path. A terminal event or session reconciliation
        // may arrive while a provider generation is still settling.
        Task { @MainActor [weak self] in
            await self?.refreshWebProjects(force: false)
        }
    }

    func refreshWebProjects(force: Bool = true) async {
        if refreshWebProjectsInFlight {
            refreshWebProjectsQueued = true
            return
        }
        if !force {
            if hasActiveChatGPTWebRun {
                // Yield to the active web page, but never silently forget the
                // requested catalog refresh. A later terminal/session-status
                // transition must recheck the cached Projects.
                webProjectsRefreshDeferredForActiveChat = true
                if webProjectsSnapshotState == .authoritativeLiveDOM {
                    webProjectsSnapshotState = .staleCache
                }
                DiagnosticsLog.shared.record("projects_refresh_deferred_active_chat", fields: ["cachedCount": String(webProjects.count)])
                return
            }
            let wasDeferred = webProjectsRefreshDeferredForActiveChat
            webProjectsRefreshDeferredForActiveChat = false
            if !wasDeferred, let lastWebProjectsRefreshAt,
               Date().timeIntervalSince(lastWebProjectsRefreshAt) < Self.webProjectsAutomaticRefreshMinimumInterval,
               webProjectsSnapshotState == .authoritativeLiveDOM {
                DiagnosticsLog.shared.record("projects_refresh_skipped_fresh", fields: ["cachedCount": String(webProjects.count)])
                return
            }
        }
        refreshWebProjectsInFlight = true
        let refreshStartedAt = Date()
        defer {
            refreshWebProjectsInFlight = false
            if refreshWebProjectsQueued {
                refreshWebProjectsQueued = false
                // Preserve the prior coalescing contract: a request that arrived while
                // discovery was in flight gets one authoritative rerun even if the first
                // request just refreshed the TTL.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.refreshWebProjects(force: !self.hasActiveChatGPTWebRun)
                }
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
            webProjectsRefreshNeedsConnectivityRetry = true
            DiagnosticsLog.shared.record("projects_refresh_skipped_offline", fields: ["cachedCount": String(webProjects.count)], level: "WARN")
            return
        }
        do {
            let response = try await transport.listProjectsResponse(machineId: machine.id, forceRefresh: force)
            guard generation == lifecycleGeneration, revision == webProjectsRevision, machine.state == .online, !isSuspended else { return }
            guard response.isAuthoritativeLiveDOM else {
                if response.state == .staleCache,
                   response.source == "windows-verified-cache" {
                    if webProjects.isEmpty, !response.items.isEmpty {
                        webProjects = response.items
                    }
                    webProjectsSnapshotState = .staleCache
                    hasLoadedWebProjects = !webProjects.isEmpty
                    errors["web.projects"] = nil
                    DiagnosticsLog.shared.record("projects_refresh_cache_fast", fields: ["count": String(response.items.count), "durationMs": Self.durationMilliseconds(since: refreshStartedAt)])
                    if !force {
                        // Reuse the Store's existing coalescing queue for the live DOM
                        // follow-up. This guarantees at most one authoritative rerun even
                        // when another UI refresh arrives while the cache response is in flight.
                        refreshWebProjectsQueued = true
                    }
                    return
                }
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
            webProjectsRefreshNeedsConnectivityRetry = false
            lastWebProjectsRefreshAt = Date()
            hasLoadedWebProjects = true
            try? await cache.put(webProjects, key: "web.projects")
            guard generation == lifecycleGeneration, revision == webProjectsRevision, !isSuspended else { return }
            errors["web.projects"] = nil
            DiagnosticsLog.shared.record("projects_refresh_ok", fields: ["count": String(webProjects.count), "durationMs": Self.durationMilliseconds(since: refreshStartedAt)])
        } catch {
            if generation == lifecycleGeneration, revision == webProjectsRevision, !isSuspended {
                webProjectsSnapshotState = .providerUnavailable
                hasLoadedWebProjects = !webProjects.isEmpty
                webProjectsRefreshNeedsConnectivityRetry = Self.shouldRetryWebProjectsAfterConnectivityRecovery(error)
                errors["web.projects"] = error.localizedDescription
                DiagnosticsLog.shared.record("projects_refresh_failed", fields: Self.diagnosticFields(for: error, adding: ["durationMs": Self.durationMilliseconds(since: refreshStartedAt)]), level: "ERROR")
            }
        }
    }

    func createWebProject(name: String) async -> WebProjectDescriptor? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedOperationKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard creatingWebProjects.insert(normalizedOperationKey).inserted else { return nil }
        defer { creatingWebProjects.remove(normalizedOperationKey) }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        DiagnosticsLog.shared.record("project_create_attempt", fields: [
            "machineState": machine.state.rawValue,
            "connectionPhase": connectionPhase.rawValue,
        ])
        webProjectsRevision &+= 1
        let pendingKey = "createProject.\(normalizedOperationKey)"
        do {
            let commandId = await pendingOperationCommandId(key: pendingKey, machineId: activeMachineId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }

            // machine.state is a presentation snapshot and can briefly lag behind a
            // healthy Relay/Agent connection after foregrounding. Do not silently drop
            // the create before Transport gets a chance to prove the real state. Reuse
            // the same command id across one reconnect retry so an ACK-loss cannot create
            // a duplicate ChatGPT Project.
            let created: WebProjectDescriptor
            do {
                created = try await activeTransport.createWebProject(machineId: activeMachineId, projectName: trimmed, commandId: commandId)
            } catch let transportError as TransportError where Self.isRecoverableCommandTransportError(transportError) {
                DiagnosticsLog.shared.record("project_create_retry", fields: Self.diagnosticFields(for: transportError, adding: ["commandId": commandId.uuidString]), level: "WARN")
                if !(await activeTransport.isConnected) { try await activeTransport.connect() }
                let latest = try await activeTransport.latestSequence(machineId: activeMachineId)
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
                machine.state = .online
                connectionPhase = .online
                errors["connection"] = nil
                await recoverDelta(freshLatestSequence: latest)
                created = try await activeTransport.createWebProject(machineId: activeMachineId, projectName: trimmed, commandId: commandId)
            }
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
            machine.state = .online
            connectionPhase = .online
            desktopAgentConnected = true
            desktopBrowserConnected = true
            // Commit a second epoch bump after the remote mutation succeeds. Any refresh
            // that began while createProject was in flight must not overwrite this row.
            webProjectsRevision &+= 1
            await finishPendingOperation(key: pendingKey, machineId: activeMachineId, expectedCommandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return nil }
            webProjects.removeAll { $0.projectAlias == created.projectAlias }
            webProjects.insert(created, at: 0)
            webProjectsSnapshotState = .localConfirmed
            webProjectsSnapshotId = nil
            hasLoadedWebProjects = true
            try? await cache.put(webProjects, key: "web.projects")
            errors["web.projects"] = nil
            DiagnosticsLog.shared.record("project_create_ok", fields: ["projectAlias": created.projectAlias, "commandId": commandId.uuidString])
            return created
        } catch {
            if generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended {
                if !isUnknownDelivery(error) { await finishPendingOperation(key: pendingKey, machineId: activeMachineId) }
                errors["web.projects"] = error.localizedDescription
                DiagnosticsLog.shared.record("project_create_failed", fields: Self.diagnosticFields(for: error), level: "ERROR")
            }
            return nil
        }
    }

    func loadProjectConversations(projectAlias: String, refresh: Bool = true, force: Bool = true) async {
        if refresh {
            if !force,
               !projectConversationsByAlias[projectAlias, default: []].isEmpty,
               let lastAttempt = projectConversationLastRefreshAttemptAt[projectAlias],
               Date().timeIntervalSince(lastAttempt) < Self.projectConversationAutomaticRefreshMinimumInterval {
                return
            }
            guard projectConversationRefreshes.insert(projectAlias).inserted else {
                // Automatic view/task churn should coalesce into the request already in
                // flight. Only an explicit user refresh asks for one rerun afterwards.
                if force { projectConversationRefreshQueued.insert(projectAlias) }
                return
            }
            projectConversationLastRefreshAttemptAt[projectAlias] = Date()
            projectConversationLoadingByAlias[projectAlias] = true
            // A full refresh supersedes any page-load already in flight for this Project.
            projectConversationRevisions[projectAlias, default: 0] &+= 1
        }
        defer {
            if refresh {
                projectConversationRefreshes.remove(projectAlias)
                projectConversationLoadingByAlias[projectAlias] = false
                if projectConversationRefreshQueued.remove(projectAlias) != nil {
                    Task { @MainActor [weak self] in await self?.loadProjectConversations(projectAlias: projectAlias, refresh: true, force: true) }
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
        let projectLoadStartedAt = Date()
        guard machine.state == .online else {
            if projectConversationsByAlias[projectAlias, default: []].isEmpty {
                errors["web.project.\(projectAlias)"] = "PC Offline — connect to Windows to load this Project's conversations."
            }
            DiagnosticsLog.shared.record("project_load_offline", fields: ["project": projectAlias, "cachedCount": String(projectConversationsByAlias[projectAlias, default: []].count)], level: "WARN")
            return
        }
        let previouslyAcceptedItems = projectConversationsByAlias[projectAlias, default: []]
        do {
            var page = try await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 50, forceRefresh: force)
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], machine.state == .online, !isSuspended else { return }
            // The ChatGPT sidebar lazily mounts Project conversation panels, and a live
            // scan can transiently return partial/stale data even when the phone already
            // has an older verified list. An explicit/foreground refresh must therefore
            // make one bounded second live read instead of treating that old list as a
            // reason to stop. Automatic background refreshes keep the cheaper bootstrap
            // behavior unless the Project has no verified rows at all.
            let shouldRetryIncompleteLiveRead = !page.isAuthoritativeLiveDOM
                && (force || projectConversationsByAlias[projectAlias, default: []].isEmpty)
            if shouldRetryIncompleteLiveRead {
                try? await Task.sleep(nanoseconds: 650_000_000)
                if generation == lifecycleGeneration,
                   revision == projectConversationRevisions[projectAlias, default: 0],
                   machine.state == .online,
                   !isSuspended,
                   let retry = try? await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 50, forceRefresh: force) {
                    // Prefer any fresher retry. Authoritative live DOM is final; a partial
                    // retry may still contain a safe newest-head merge that the logic
                    // below can apply without deleting the verified tail.
                    if retry.isAuthoritativeLiveDOM || retry.source == "browser-dom-partial-head-merge" {
                        page = retry
                    }
                }
            }
            guard page.isAuthoritativeLiveDOM else {
                // Windows can already hold a complete last-known Project catalog while
                // the live ChatGPT sidebar is still mounting or unavailable. Drain that
                // stable cache generation across every page instead of returning after
                // the first 50 rows. A page-local snapshot id used to make large
                // Projects look complete on the phone even though Windows had more.
                if page.state == .staleCache,
                   let staleSnapshotId = page.snapshotId,
                   !page.items.isEmpty {
                    var staleItems = page.items
                    var seenIds = Set(staleItems.map(\.id))
                    var nextCursor = page.nextCursor
                    var hasMore = page.hasMore
                    var seenCursors = Set<String>()
                    var pagingStoppedEarly = false

                    while hasMore, let cursor = nextCursor {
                        guard seenCursors.insert(cursor).inserted else {
                            pagingStoppedEarly = true
                            break
                        }
                        do {
                            let nextPage = try await transport.listProjectConversations(
                                machineId: machine.id,
                                projectAlias: projectAlias,
                                limit: 50,
                                cursor: cursor,
                                forceRefresh: false
                            )
                            guard generation == lifecycleGeneration,
                                  revision == projectConversationRevisions[projectAlias, default: 0],
                                  machine.state == .online,
                                  !isSuspended else { return }
                            guard nextPage.state == .staleCache,

[Showing lines 1-900 of 4977 (50.0KB limit). Use offset=901 to continue.]