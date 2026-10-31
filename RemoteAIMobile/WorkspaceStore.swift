import Foundation
import SwiftUI

private enum GenerationTerminalOutcome: Equatable {
    case canceled
    case interrupted
    case unknown
    case failed
}

enum OpenWebTabDestination {
    case chat(SessionDescriptor)
    case project(WebProjectDescriptor)
}

@MainActor
final class WorkspaceStore: ObservableObject {
    private struct StopRunIdentity: Codable, Equatable {
        let eventRevision: UInt64
        let generationSequence: Int64?
        let generationKey: String?
        let activityAt: Date?

        func identifiesSameRun(as other: StopRunIdentity) -> Bool {
            if let generationKey, let otherKey = other.generationKey {
                return generationKey == otherKey
            }
            if generationSequence != nil || other.generationSequence != nil {
                return generationSequence == other.generationSequence
            }
            guard let activityAt, let otherActivityAt = other.activityAt else { return false }
            return activityAt == otherActivityAt
        }

        func canCoalesceStopTask(as other: StopRunIdentity) -> Bool {
            if let generationKey, let otherKey = other.generationKey {
                return generationKey == otherKey
            }
            if generationSequence != nil || other.generationSequence != nil {
                return generationSequence == other.generationSequence
            }
            // Without a start event there is no reliable run ID. Keep the existing
            // per-session single-flight behavior and let the exact event-revision
            // guard decide whether the old completion can change visible state.
            return true
        }
    }

    private struct PendingStopOperation: Codable {
        let commandId: UUID
        let runIdentity: StopRunIdentity?
    }

    private struct StopTaskEntry {
        let token: UUID
        let runIdentity: StopRunIdentity
        let task: Task<Bool, Never>
    }

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
    @Published private(set) var webChatRecoveryNotesBySession: [String: String] = [:]
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
    // A late delta page must never re-freeze a chat after a newer live reply
    // has already been applied during the same catch-up pass.
    private var recoveryLivePresentationSessions = Set<String>()
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
    private var reopeningWebConversations = Set<String>()
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
    private var olderMessageLoads = Set<String>()
    private var creatingWebProjects = Set<String>()
    private var creatingWebConversations = Set<String>()
    private var creatingSessions = Set<String>()
    private var stopTasksBySession: [String: StopTaskEntry] = [:]
    @Published private(set) var stopRequestsPending = Set<String>()
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
    private var stopEventRevisionsBySession: [String: UInt64] = [:]
    private var stopRunStartSequenceBySession: [String: Int64] = [:]
    private var stopRunGenerationKeyBySession: [String: String] = [:]
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

    func enterOpenWebTab(_ tab: OpenWebTab) async -> OpenWebTabDestination? {
        guard machine.state == .online, !isSuspended else {
            errors["web.tabs"] = "Windows 未连接，无法打开当前 Chrome 网页。"
            return nil
        }
        guard managingWebTabIds.insert(tab.id).inserted else { return nil }
        defer { managingWebTabIds.remove(tab.id) }
        webTabDiagnosesById.removeValue(forKey: tab.id)
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        do {
            let entered = try await activeTransport.enterOpenWebTab(machineId: activeMachineId, tab: tab)
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return nil }
            webTabDiagnosesById[tab.id] = entered.diagnosis
            errors["web.tabs"] = nil
            if let conversation = entered.conversation {
                // Enter returns a verified existing provider identity, not a
                // new chat. Keep the live Agent status when already available.
                let session = sessions.first(where: { $0.id == conversation.localConversationId })
                    ?? conversation.session
                if !sessions.contains(where: { $0.id == session.id }) {
                    sessions.insert(session, at: 0)
                    await persistMetadata()
                }
                guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return nil }
                return .chat(session)
            }
            if let project = entered.project {
                return .project(project)
            }
            errors["web.tabs"] = "Chrome 已响应，但没有返回可打开的 Chat 或 Project。"
        } catch {
            if isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) {
                errors["web.tabs"] = "打开当前网页失败：\(error.localizedDescription)"
                DiagnosticsLog.shared.record("web_tab_enter_failed",
                    fields: Self.diagnosticFields(for: error, adding: ["tabId": String(tab.tabId)]),
                    level: "WARN")
            }
        }
        return nil
    }

    func inspectOpenWebTab(_ tab: OpenWebTab) async {
        guard machine.state == .online, !isSuspended else {
            errors["web.tabs"] = "Windows 未连接，无法验证 Chrome 网页是否正常。"
            return
        }
        guard managingWebTabIds.insert(tab.id).inserted else { return }
        defer { managingWebTabIds.remove(tab.id) }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        webTabDiagnosesById.removeValue(forKey: tab.id)
        await performInspectOpenWebTab(tab, generation: generation,
            transport: activeTransport, machineId: activeMachineId)
    }

    private func performInspectOpenWebTab(_ tab: OpenWebTab, generation: UInt64,
        transport activeTransport: Transport, machineId activeMachineId: String) async {
        do {
            let diagnosis = try await activeTransport.inspectOpenWebTab(machineId: activeMachineId, tab: tab)
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            webTabDiagnosesById[tab.id] = diagnosis
            errors["web.tabs"] = nil
        } catch {
            // This is a failed status check, not proof of a failed page load.
            if isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) {
                errors["web.tabs"] = "网页状态无法确认：\(error.localizedDescription)"
            }
        }
    }

    func reopenClosedWebConversation(sessionId: String) async {
        guard machine.state == .online, !isSuspended else {
            errors[sessionId] = "Windows 未连接，无法重开原 Chat；历史已保留。"
            return
        }
        // A second tap must not allocate another renderer while the first open is
        // awaiting an uncertain browser response. Never guess a target from title/focus.
        guard reopeningWebConversations.insert(sessionId).inserted else { return }
        defer { reopeningWebConversations.remove(sessionId) }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        webChatRecoveryNotesBySession[sessionId] = "正在按原会话身份重新打开网页…"
        do {
            try await activeTransport.reopenVerifiedWebConversation(machineId: activeMachineId, sessionId: sessionId)
            guard isCurrentWebTabOperation(generation: generation,
                    transport: activeTransport, machineId: activeMachineId) else { return }
            await refreshOpenWebTabs()
            guard isCurrentWebTabOperation(generation: generation,
                    transport: activeTransport, machineId: activeMachineId) else { return }
            let matches = openWebTabsInventoryUnverified ? [] :
                openWebTabs.filter { $0.sessionId == sessionId && $0.isChat }
            guard matches.count == 1, let tab = matches.first else {
                webChatRecoveryNotesBySession[sessionId] = "网页打开请求已返回，但原 Chat 标签身份未核实；不会自动重试。"
                errors[sessionId] = "未能唯一确认原 Chat 的 Chrome 标签；历史保持不变。"
                return
            }
            webTabDiagnosesById.removeValue(forKey: tab.id)
            await performInspectOpenWebTab(tab, generation: generation,
                transport: activeTransport, machineId: activeMachineId)
            guard isCurrentWebTabOperation(generation: generation,
                    transport: activeTransport, machineId: activeMachineId) else { return }
            guard let diagnosis = webTabDiagnosesById[tab.id],
                  ["ready", "generating", "retry-visible"].contains(diagnosis.state) else {
                webChatRecoveryNotesBySession[sessionId] = "已找到原 Chat，但网页状态仍未确认；未刷新其他标签。"
                return
            }
            webChatRecoveryNotesBySession[sessionId] = "已验证原 Chat 标签与网页状态，正在同步消息。"
            errors[sessionId] = nil
            await synchronizeVisibleSession(sessionId, force: true)
        } catch {
            guard isCurrentWebTabOperation(generation: generation,
                    transport: activeTransport, machineId: activeMachineId) else { return }
            errors[sessionId] = "重新打开原 Chat 未确认：\(error.localizedDescription)"
            webChatRecoveryNotesBySession[sessionId] = "当前操作未确认；不会自动重开或重发消息。"
        }
    }

    func manageOpenWebTab(_ tab: OpenWebTab, operation: String) async {
        guard machine.state == .online, !isSuspended, ["close", "reload", "hardReload", "reopen"].contains(operation) else { return }
        guard managingWebTabIds.insert(tab.id).inserted else { return }
        defer { managingWebTabIds.remove(tab.id) }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        guard !tab.busy else {
            errors["web.tabs"] = "该 Chat 正在生成回复，不能关闭或刷新。"
            return
        }
        do {
            webTabActionNotesById[tab.id] = "正在执行操作，等待 Chrome 确认…"
            try await activeTransport.manageOpenWebTab(machineId: activeMachineId, tab: tab, operation: operation)
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            if operation == "close" {
                explicitlyClosedWebTabIDs.insert(tab.id)
                webTabActionNotesById[tab.id] = "Chrome 已接受关闭请求"
            } else {
                webTabActionNotesById[tab.id] = "Chrome 已接受页面操作；尚未验证加载完成"
            }
            await refreshOpenWebTabs()
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            if operation != "close" {
                // A browser navigation acknowledgement is NOT health proof.
                // Check only the selected page after a short settle period.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await performInspectOpenWebTab(tab, generation: generation,
                    transport: activeTransport, machineId: activeMachineId)
            }
        } catch {
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            errors["web.tabs"] = "网页操作未确认：\(error.localizedDescription)"
            webTabActionNotesById[tab.id] = "操作未确认；不能判定页面已经刷新或关闭"
            // Do not remove a tab from the UI on an unconfirmed browser action.
        }
    }

    private func isCurrentWebTabOperation(generation: UInt64, transport activeTransport: Transport, machineId activeMachineId: String) -> Bool {
        generation == lifecycleGeneration
            && transport === activeTransport
            && machine.id == activeMachineId
            && machine.state == .online
            && !isSuspended
    }

    // Chat-level manual recovery is opt-in and never guesses a tab from Chrome focus.
    // Cached history remains untouched when the Browser/Relay is unavailable.
    func recoverWebChat(_ sessionId: String, operation: String) async {
        guard machine.state == .online, !isSuspended else {
            errors[sessionId] = "Windows 未连接；已保留本地历史，等待重连。"
            return
        }
        if operation == "resync" {
            webChatRecoveryNotesBySession[sessionId] = "正在补同步消息；不会刷新网页。"
            await synchronizeVisibleSession(sessionId, force: true)
            webChatRecoveryNotesBySession[sessionId] = "已请求最新消息；若仍缺失，请检测网页状态。"
            return
        }
        if operation == "connection" {
            do {
                let status = try await transport.agentStatusSnapshot(machineId: machine.id)
                if status.browserConnected == false {
                    webChatRecoveryNotesBySession[sessionId] = "Agent 在线，但 Browser Bridge 未连接；等待桌面端恢复。"
                } else {
                    webChatRecoveryNotesBySession[sessionId] = "已收到 Agent 连接回执，正在补同步原 Chat。"
                    await synchronizeVisibleSession(sessionId, force: true)
                }
            } catch {
                errors[sessionId] = "连接状态无法确认：\(error.localizedDescription)"
            }
            return
        }
        guard ["inspect", "reload", "hardReload"].contains(operation) else { return }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        webChatRecoveryNotesBySession[sessionId] = "正在核验当前 Chat 的网页身份…"
        await refreshOpenWebTabs()
        guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId),
              !openWebTabsInventoryUnverified else {
            errors[sessionId] = "无法确认 Chrome 标签身份；未执行网页操作。"
            return
        }
        let matches = openWebTabs.filter { $0.sessionId == sessionId && $0.isChat }
        guard matches.count == 1, let tab = matches.first else {
            errors[sessionId] = "原 Chat 未绑定唯一标签页；不会刷新其他网页。请先重新同步。"
            return
        }
        if operation == "inspect" {
            await inspectOpenWebTab(tab)
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            if let diagnosis = webTabDiagnosesById[tab.id] {
                webChatRecoveryNotesBySession[sessionId] = "网页状态：\(diagnosis.state)" +
                    (diagnosis.issueMessage.map { " · \($0)" } ?? "")
            } else {
                errors[sessionId] = errors["web.tabs"] ?? "网页状态尚未确认。"
            }
            return
        }
        guard managingWebTabIds.insert(tab.id).inserted else {
            errors[sessionId] = "此网页已有管理操作正在运行，未发送重复刷新。"
            return
        }
        defer { managingWebTabIds.remove(tab.id) }
        do {
            webChatRecoveryNotesBySession[sessionId] = "用户已确认风险，正在刷新选中的 Chat 网页…"
            try await activeTransport.manageOpenWebTab(machineId: activeMachineId, tab: tab,
                operation: operation, userConfirmedDisruptive: true)
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            webChatRecoveryNotesBySession[sessionId] = "Chrome 已接受刷新；尚未证明页面恢复。"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshOpenWebTabs()
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            await synchronizeVisibleSession(sessionId, force: true)
            if let after = openWebTabs.first(where: { $0.tabId == tab.id && $0.sessionId == sessionId }) {
                await inspectOpenWebTab(after)
                let diagnosis = webTabDiagnosesById[tab.id]
                webChatRecoveryNotesBySession[sessionId] = "已重新同步原 Chat · 网页状态：\(diagnosis?.state ?? "待验证")"
            } else {
                webChatRecoveryNotesBySession[sessionId] = "刷新后尚未核实原会话绑定；已保留历史。"
            }
        } catch {
            guard isCurrentWebTabOperation(generation: generation, transport: activeTransport, machineId: activeMachineId) else { return }
            errors[sessionId] = "网页操作未确认：\(error.localizedDescription)；未操作其他 Chat。"
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
        // Reserve the deferred refresh synchronously. Several terminal/status
        // callbacks can arrive before an asynchronous Task starts; without this
        // reservation they each queue a refresh, and a later cache-first result
        // can regress an already authoritative Project list back to stale.
        // refreshWebProjects(force: false) will restore the deferred flag itself
        // if another Chat begins before the scheduled read executes.
        webProjectsRefreshDeferredForActiveChat = false
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
            // An automatic read can intentionally prefer the Windows verified cache.
            // If it is stale or partial, escalate exactly once to a live DOM read even
            // when the phone already has rows; otherwise cached rows can permanently
            // suppress convergence. This remains inside the existing per-Project
            // refresh gate and automatic throttle, so it is bounded rather than polling.
            let shouldRetryIncompleteLiveRead = !page.isAuthoritativeLiveDOM
            if shouldRetryIncompleteLiveRead {
                try? await Task.sleep(nanoseconds: 650_000_000)
                if generation == lifecycleGeneration,
                   revision == projectConversationRevisions[projectAlias, default: 0],
                   machine.state == .online,
                   !isSuspended,
                   let retry = try? await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 50, forceRefresh: true) {
                    // Prefer any fresher retry. Authoritative live DOM is final; a partial
                    // retry may still contain a safe newest-head merge that the logic
                    // below can apply without deleting the verified tail.
                    if retry.project.projectAlias == projectAlias,
                       (retry.isAuthoritativeLiveDOM || retry.source == "browser-dom-partial-head-merge") {
                        page = retry
                    }
                }
            }
            guard page.project.projectAlias == projectAlias else {
                throw TransportError.malformedData
            }
            guard page.isAuthoritativeLiveDOM else {
                // Windows can already hold a complete last-known Project catalog while
                // the live ChatGPT sidebar is still mounting or unavailable. Drain that
                // stable cache generation across every page instead of returning after
                // the first 50 rows. A page-local snapshot id used to make large
                // Projects look complete on the phone even though Windows had more.
                if page.state == .staleCache,
                   let staleSnapshotId = page.snapshotId,
                   !staleSnapshotId.isEmpty,
                   !page.items.isEmpty {
                    var staleItems = page.items
                    var seenIds = Set(staleItems.map(\.id))
                    var nextCursor = page.nextCursor
                    var hasMore = page.hasMore
                    var seenCursors = Set<String>()
                    var pagingStoppedEarly = hasMore
                        && (nextCursor?.isEmpty != false || page.items.isEmpty || staleSnapshotId.isEmpty)

                    while hasMore, !pagingStoppedEarly {
                        guard let cursor = nextCursor,
                              !cursor.isEmpty,
                              seenCursors.insert(cursor).inserted else {
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
                            let validContinuation: Bool
                            if nextPage.hasMore {
                                validContinuation = !nextPage.items.isEmpty
                                    && nextPage.nextCursor.map { !$0.isEmpty && !seenCursors.contains($0) } == true
                            } else {
                                validContinuation = nextPage.nextCursor == nil
                            }
                            guard nextPage.project.projectAlias == projectAlias,
                                  nextPage.state == .staleCache,
                                  nextPage.snapshotId == staleSnapshotId,
                                  validContinuation else {
                                pagingStoppedEarly = true
                                break
                            }
                            for item in nextPage.items where seenIds.insert(item.id).inserted {
                                staleItems.append(item)
                            }
                            nextCursor = nextPage.nextCursor
                            hasMore = nextPage.hasMore
                        } catch {
                            pagingStoppedEarly = true
                            break
                        }
                    }

                    if !previouslyAcceptedItems.isEmpty {
                        // A stale Windows catalog is recovery evidence, never deletion
                        // authority. Preserve every row and the relative order the phone
                        // already accepted, but do not let that protection freeze an old
                        // truncated cache forever: verified Windows identities may be
                        // inserted into the gaps/tail without deleting or reordering any
                        // existing phone rows.
                        projectConversationsByAlias[projectAlias] = previouslyAcceptedItems
                        let addedVerifiedRows = mergeConversationVerifiedStaleCatalog(staleItems, projectAlias: projectAlias)
                        let repairedTitles = mergeConversationTitleHints(staleItems, projectAlias: projectAlias)
                        projectConversationSnapshotStateByAlias[projectAlias] = .staleCache
                        let preservedItems = projectConversationsByAlias[projectAlias] ?? previouslyAcceptedItems
                        if addedVerifiedRows > 0 || repairedTitles {
                            try? await cache.put(preservedItems, key: "web.project.\(projectAlias).conversations")
                        }
                        mergeProjectSessions(preservedItems)
                        errors["web.project.\(projectAlias)"] = nil
                        DiagnosticsLog.shared.record("project_load_stale_preserved", fields: [
                            "project": projectAlias,
                            "acceptedCount": String(previouslyAcceptedItems.count),
                            "staleCount": String(staleItems.count),
                            "visibleCount": String(preservedItems.count),
                            "addedVerifiedRows": String(addedVerifiedRows),
                            "repairedTitles": String(repairedTitles),
                            "pagingStoppedEarly": String(pagingStoppedEarly),
                        ], level: "WARN")
                        return
                    }

                    // Fresh-phone bootstrap: there is no accepted local list to protect,
                    // so expose the complete stable Windows cache generation in memory.
                    // It remains non-authoritative and is not written into the durable
                    // phone cache.
                    projectConversationsByAlias[projectAlias] = staleItems
                    projectConversationSnapshotStateByAlias[projectAlias] = .staleCache
                    projectConversationSnapshotIds[projectAlias] = staleSnapshotId
                    if let cursor = nextCursor { projectNextCursorByAlias[projectAlias] = cursor }
                    else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
                    projectHasMoreByAlias[projectAlias] = hasMore
                    mergeProjectSessions(staleItems)
                    errors["web.project.\(projectAlias)"] = nil
                    DiagnosticsLog.shared.record("project_load_stale", fields: [
                        "project": projectAlias,
                        "count": String(staleItems.count),
                        "source": page.source ?? "unknown",
                        "hasMore": String(hasMore),
                        "pagingStoppedEarly": String(pagingStoppedEarly),
                    ], level: "WARN")
                    return
                }

                let verifiedWindowsBootstrap = ["browser-dom-partial-title-hints", "browser-dom-partial-head-merge"].contains(page.source ?? "")
                    && projectConversationsByAlias[projectAlias, default: []].isEmpty
                    && !page.items.isEmpty
                if (page.state == .staleCache || verifiedWindowsBootstrap),
                   projectConversationsByAlias[projectAlias, default: []].isEmpty,
                   !page.items.isEmpty {
                    // Windows may already hold a verified conversation identity/order
                    // snapshot even while the current ChatGPT sidebar DOM is only
                    // partially mounted. Show those verified rows immediately instead
                    // of presenting an empty/error screen, but keep the state non-
                    // authoritative so a later live DOM pass can replace it.
                    projectConversationsByAlias[projectAlias] = page.items
                    projectConversationSnapshotStateByAlias[projectAlias] = page.state ?? .staleCache
                    projectNextCursorByAlias[projectAlias] = page.nextCursor
                    projectHasMoreByAlias[projectAlias] = page.hasMore
                    mergeProjectSessions(page.items)
                    errors["web.project.\(projectAlias)"] = nil
                    DiagnosticsLog.shared.record("project_load_stale", fields: ["project": projectAlias, "count": String(page.items.count), "source": page.source ?? "unknown"], level: "WARN")
                    return
                }
                projectConversationSnapshotStateByAlias[projectAlias] = page.state ?? .providerUnavailable
                // A partial live DOM may prove a monotonic newest-first head before it
                // intersects our verified list. Accept only that safe prefix; never use
                // a partial snapshot to delete/reorder the verified tail. Matching known
                // identities may still repair placeholder titles.
                let mergedHead = page.source == "browser-dom-partial-head-merge"
                    && mergeConversationPartialHead(page.items, projectAlias: projectAlias)
                // A provider/rate-limit failure can leave the browser DOM unavailable even
                // though Windows has already registered an exact new Project conversation
                // from an opened tab. Never let a non-empty phone cache hide that verified
                // identity. Accept only a monotonic unknown prefix before the first known
                // anchor, preserving the entire verified phone tail and never treating the
                // stale response as deletion/reorder authority.
                let mergedVerifiedStaleHead = page.state == .staleCache
                    && mergeConversationVerifiedStaleHead(page.items, projectAlias: projectAlias)
                let repairedTitles = mergeConversationTitleHints(page.items, projectAlias: projectAlias)
                if mergedHead || mergedVerifiedStaleHead || repairedTitles {
                    if mergedHead || repairedTitles {
                        // Preserve the existing title-repair persistence contract and
                        // persist monotonic partial live-DOM head proof. A stale Windows
                        // identity-only head merge remains in-memory and will be re-proved
                        // on the next refresh before it can replace cache truth.
                        try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
                    }
                    mergeProjectSessions(projectConversationsByAlias[projectAlias] ?? [])
                }
                if mergedHead {
                    DiagnosticsLog.shared.record("project_load_partial_head_merged", fields: ["project": projectAlias, "count": String(projectConversationsByAlias[projectAlias, default: []].count)])
                }
                if mergedVerifiedStaleHead {
                    DiagnosticsLog.shared.record("project_load_verified_stale_head_merged", fields: ["project": projectAlias, "count": String(projectConversationsByAlias[projectAlias, default: []].count)], level: "WARN")
                }
                // A partial DOM is a freshness condition, not a confirmed provider
                // failure. Keep any verified rows interactive and avoid flashing a red
                // error banner while the background refresh converges.
                if !projectConversationsByAlias[projectAlias, default: []].isEmpty {
                    errors["web.project.\(projectAlias)"] = nil
                } else {
                    errors["web.project.\(projectAlias)"] = "ChatGPT conversations are still loading."
                }
                DiagnosticsLog.shared.record("project_load_incomplete", fields: ["project": projectAlias, "state": String(describing: page.state), "observedCount": String(page.items.count)], level: "WARN")
                return
            }
            // A Project refresh mirrors the complete ChatGPT left-sidebar list,
            // not only its first lazy page. Follow a stable authoritative snapshot until
            // exhausted; never mix pages from different sidebar revisions.
            var authoritativeItems = page.items
            var nextCursor = page.nextCursor
            var hasMore = page.hasMore
            let authoritativeSnapshotId = page.snapshotId
            var seenIds = Set(authoritativeItems.map(\.id))
            var seenCursors = Set<String>()
            var pagingStoppedEarly = hasMore
                && (nextCursor?.isEmpty != false || page.items.isEmpty || authoritativeSnapshotId?.isEmpty != false)
            if !hasMore, nextCursor != nil { pagingStoppedEarly = true }

            while hasMore, !pagingStoppedEarly {
                guard let cursor = nextCursor,
                      !cursor.isEmpty,
                      seenCursors.insert(cursor).inserted,
                      let expectedSnapshotId = authoritativeSnapshotId,
                      !expectedSnapshotId.isEmpty else {
                    pagingStoppedEarly = true
                    break
                }
                do {
                    let nextPage = try await transport.listProjectConversations(
                        machineId: machine.id,
                        projectAlias: projectAlias,
                        limit: 50,
                        cursor: cursor,
                        forceRefresh: true
                    )
                    guard generation == lifecycleGeneration,
                          revision == projectConversationRevisions[projectAlias, default: 0],
                          machine.state == .online,
                          !isSuspended else { return }
                    let validContinuation: Bool
                    if nextPage.hasMore {
                        validContinuation = !nextPage.items.isEmpty
                            && nextPage.nextCursor.map { !$0.isEmpty && !seenCursors.contains($0) } == true
                    } else {
                        validContinuation = nextPage.nextCursor == nil
                    }
                    guard nextPage.project.projectAlias == projectAlias,
                          nextPage.isAuthoritativeLiveDOM,
                          nextPage.snapshotId == expectedSnapshotId,
                          validContinuation else {
                        pagingStoppedEarly = true
                        break
                    }
                    for item in nextPage.items where seenIds.insert(item.id).inserted {
                        authoritativeItems.append(item)
                    }
                    nextCursor = nextPage.nextCursor
                    hasMore = nextPage.hasMore
                } catch {
                    pagingStoppedEarly = true
                    break
                }
            }

            if pagingStoppedEarly {
                // Never promote a half-paged snapshot to authoritative truth. A Project
                // can change while page 2/3 is loading, or the browser bridge can drop a
                // later page. Preserve the last accepted complete list when available;
                // on first load show the verified prefix only as partial, without caching
                // it as a final Project catalog.
                if previouslyAcceptedItems.isEmpty {
                    projectConversationsByAlias[projectAlias] = authoritativeItems
                    projectConversationSnapshotStateByAlias[projectAlias] = .partialDOM
                    if let cursor = nextCursor { projectNextCursorByAlias[projectAlias] = cursor }
                    else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
                    projectHasMoreByAlias[projectAlias] = hasMore
                    mergeProjectSessions(authoritativeItems)
                } else {
                    projectConversationSnapshotStateByAlias[projectAlias] = .partialDOM
                }
                errors["web.project.\(projectAlias)"] = nil
                DiagnosticsLog.shared.record("project_load_paging_incomplete", fields: [
                    "project": projectAlias,
                    "acceptedCount": String(previouslyAcceptedItems.count),
                    "observedCount": String(authoritativeItems.count),
                    "hasMore": String(hasMore),
                    "durationMs": Self.durationMilliseconds(since: projectLoadStartedAt),
                ], level: "WARN")
                return
            }

            projectConversationsByAlias[projectAlias] = authoritativeItems
            projectConversationSnapshotStateByAlias[projectAlias] = .authoritativeLiveDOM
            if let snapshotId = authoritativeSnapshotId { projectConversationSnapshotIds[projectAlias] = snapshotId }
            else { projectConversationSnapshotIds.removeValue(forKey: projectAlias) }
            if let cursor = nextCursor { projectNextCursorByAlias[projectAlias] = cursor }
            else { projectNextCursorByAlias.removeValue(forKey: projectAlias) }
            projectHasMoreByAlias[projectAlias] = hasMore
            try? await cache.put(authoritativeItems, key: "web.project.\(projectAlias).conversations")
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], !isSuspended else { return }
            mergeProjectSessions(authoritativeItems)
            errors["web.project.\(projectAlias)"] = nil
            let catalogDigests = DiagnosticsLog.catalogDigests(authoritativeItems.map(\.localConversationId))
            DiagnosticsLog.shared.record("project_load_ok", fields: [
                "project": projectAlias,
                "count": String(authoritativeItems.count),
                "hasMore": String(hasMore),
                "pagingStoppedEarly": String(pagingStoppedEarly),
                "identityDigest": catalogDigests.identity,
                "orderDigest": catalogDigests.order,
                "durationMs": Self.durationMilliseconds(since: projectLoadStartedAt),
            ])
        } catch {
            if generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], !isSuspended {
                projectConversationSnapshotStateByAlias[projectAlias] = .providerUnavailable
                errors["web.project.\(projectAlias)"] = error.localizedDescription
                DiagnosticsLog.shared.record("project_load_failed", fields: Self.diagnosticFields(for: error, adding: ["project": projectAlias, "durationMs": Self.durationMilliseconds(since: projectLoadStartedAt)]), level: "ERROR")
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
              !cursor.isEmpty,
              let expectedSnapshotId = projectConversationSnapshotIds[projectAlias],
              !expectedSnapshotId.isEmpty else { return }
        do {
            let page = try await transport.listProjectConversations(machineId: machine.id, projectAlias: projectAlias, limit: 50, cursor: cursor, forceRefresh: true)
            guard generation == lifecycleGeneration, revision == projectConversationRevisions[projectAlias, default: 0], machine.state == .online, !isSuspended else { return }
            guard page.project.projectAlias == projectAlias else {
                projectConversationSnapshotStateByAlias[projectAlias] = .providerUnavailable
                errors["web.project.\(projectAlias)"] = "ChatGPT returned conversations for a different Project; keeping the last verified list."
                return
            }
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
            let validContinuation: Bool
            if page.hasMore {
                validContinuation = !page.items.isEmpty
                    && page.nextCursor.map { !$0.isEmpty && $0 != cursor } == true
            } else {
                validContinuation = page.nextCursor == nil
            }
            guard validContinuation else {
                projectConversationSnapshotStateByAlias[projectAlias] = .partialDOM
                errors["web.project.\(projectAlias)"] = "ChatGPT conversation pagination was incomplete; keeping the last verified list."
                return
            }
            var merged = projectConversationsByAlias[projectAlias, default: []]
            for item in page.items where !merged.contains(where: { $0.id == item.id }) { merged.append(item) }
            // Preserve the authoritative newest-first order supplied by ChatGPT.
            // Registry update timestamps reflect our scan time, not conversation age.
            projectConversationsByAlias[projectAlias] = merged
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
            var session = created.session
            // Creation is real user activity. Keep that semantic timestamp on the
            // session catalog for run recovery, but do not use it to reorder an already
            // discovered Project list; the sidebar refresh below owns durable ordering.
            session.lastActivityAt = created.updatedAt
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            if let alias = projectAlias {
                if projectConversationRefreshes.contains(alias) {
                    projectConversationRefreshQueued.insert(alias)
                } else {
                    Task { @MainActor [weak self] in
                        await self?.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
                    }
                }
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

    func deleteSession(runtime: RuntimeDescriptor, instance: InstanceDescriptor, session: SessionDescriptor) async -> Bool {
        // Only provider-backed Antigravity deletion and native Codex archiving
        // are supported. Web must not be silently unregistered as if deleted.
        guard (runtime.kind == .antigravity || runtime.kind == .codex), session.instanceId == instance.id else { return false }
        guard machine.state == .online else {
            errors["instance.\(instance.id)"] = "PC Offline — cannot confirm upstream deletion."
            return false
        }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        let operationKey = "deleteSession.\(runtime.id).\(session.id)"
        do {
            let commandId = await pendingOperationCommandId(key: operationKey, machineId: activeMachineId)
            try await activeTransport.deleteSession(machineId: activeMachineId, runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id, commandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            await finishPendingOperation(key: operationKey, machineId: activeMachineId, expectedCommandId: commandId)
            sessionRevisions[instance.id, default: 0] &+= 1
            sessions.removeAll { $0.id == session.id }
            messagesBySession.removeValue(forKey: session.id)
            liveRunStatusBySession.removeValue(forKey: session.id)
            await persistMetadata()
            errors["instance.\(instance.id)"] = nil
            return true
        } catch {
            if generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended {
                if !isUnknownDelivery(error) { await finishPendingOperation(key: operationKey, machineId: activeMachineId) }
                errors["instance.\(instance.id)"] = error.localizedDescription
            }
            return false
        }
    }

    func loadMoreCodexSessions(runtime: RuntimeDescriptor, instance: InstanceDescriptor) async {
        guard runtime.kind == .codex, !sessionRefreshes.contains(instance.id) else { return }
        codexSessionLimits[instance.id] = min(5000, codexSessionLimits[instance.id, default: 100] + 100)
        await refreshSessions(runtime: runtime, instance: instance)
    }

    func refreshSessions(runtime: RuntimeDescriptor, instance: InstanceDescriptor) async {
        guard sessionRefreshes.insert(instance.id).inserted else { return }
        defer { sessionRefreshes.remove(instance.id) }
        let generation = lifecycleGeneration
        let revision = sessionRevisions[instance.id, default: 0]
        guard machine.state == .online else { return }
        do {
            let limit = runtime.kind == .codex ? codexSessionLimits[instance.id, default: 100] : nil
            let remote = try await transport.listSessions(machineId: machine.id, runtimeId: runtime.id, instanceId: instance.id, limit: limit)
            guard generation == lifecycleGeneration, revision == sessionRevisions[instance.id, default: 0], machine.state == .online, !isSuspended else { return }
            if let limit { codexSessionsMayHaveMore[instance.id] = remote.count >= limit && limit < 5000 }
            // An unchanged authoritative catalog must not invalidate every Chat row,
            // disturb scroll position, or write the same SQLite metadata again.
            // Keep the existing event revision guard above: a stale list response
            // must never overwrite a newer session created by a live event.
            let currentRows = sessions.filter { $0.instanceId == instance.id }
            let currentById = Dictionary(uniqueKeysWithValues: currentRows.map { ($0.id, $0) })
            let remoteRows = remote.map { row in
                var updated = row
                if let current = currentById[row.id],
                   let known = current.backgroundTaskStatus,
                   known.observedAt >= (row.backgroundTaskStatus?.observedAt ?? .distantPast) {
                    updated.backgroundTaskStatus = known
                    updated.backgroundTaskStatusReceivedAt = current.backgroundTaskStatusReceivedAt
                }
                return updated
            }.sorted(by: Self.sessionOrdersBefore)
            let catalogChanged = currentRows != remoteRows
            if catalogChanged {
                var merged = sessions.filter { $0.instanceId != instance.id }
                merged.append(contentsOf: remoteRows)
                merged.sort(by: Self.sessionOrdersBefore)
                sessions = merged
            }

            // listSessions carries durable Agent-side Project identity and titles.
            // Repair safe metadata in already-loaded rows without reordering them.
            // Busy rows missing from ChatGPT's lazy sidebar are overlaid only at render
            // time by displayedProjectConversations.
            let reconciledProjects = reconcileProjectConversationActivityFromSessions(remote)
            for alias in reconciledProjects {
                try? await cache.put(
                    projectConversationsByAlias[alias] ?? [],
                    key: "web.project.\(alias).conversations"
                )
            }
            if catalogChanged || !reconciledProjects.isEmpty { await persistMetadata() }
            if errors["instance.\(instance.id)"] != nil { errors["instance.\(instance.id)"] = nil }
            if instance.id == "web.chatgpt" { resumeDeferredWebProjectsRefreshIfIdle() }
        } catch {
            if generation == lifecycleGeneration, !isSuspended { errors["instance.\(instance.id)"] = error.localizedDescription }
        }
    }

    func loadSession(_ sessionId: String, remoteRevision: Date? = nil) async {
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
            var normalizedCachedAssistantMessages: [ChatMessage] = []
            if routeForSession(sessionId)?.runtimeId == "runtime.web" {
                for index in local.indices where local[index].role == .assistant && local[index].kind == .text {
                    let normalized = Self.normalizedWebAssistantMessage(local[index])
                    if normalized.text != local[index].text {
                        local[index] = normalized
                        normalizedCachedAssistantMessages.append(normalized)
                    }
                }
            }
            // ChatGPT Web process transitions are transient status signals, not transcript
            // messages. Older builds persisted every Thinking/Reading/Generating transition
            // as a tool row, which can flood the conversation after an upgrade. Hide those
            // legacy rows while preserving real external tool rows such as DevSpace/MCP.
            local.removeAll {
                $0.kind == .toolEvent
                    && $0.toolName == "ChatGPT Web"
                    && isTransientWebProcessDetail($0.detail)
            }
            if !normalizedCachedAssistantMessages.isEmpty {
                try? await cache.upsertMessages(normalizedCachedAssistantMessages)
            }
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
        let cachedMessages = messagesBySession[sessionId, default: []]
        // Never let a cached optimistic user bubble prove its own delivery. Unknown
        // sends are resolved only against a fresh authoritative remote history page
        // below; otherwise a frame that died before reaching the Agent can be marked
        // completed solely because the phone still has its local optimistic row.
        // A cached final assistant after the latest user turn is enough to clear a
        // stale .error/.busy navigation snapshot immediately. Do not make the user
        // wait for the network read just to discover that the conversation already
        // completed successfully on the PC.
        await settleRunStateIfAuthoritativeFinalExists(cachedMessages, sessionId: sessionId)
        guard machine.state == .online, let route = routeForSession(sessionId) else { return }
        await hydrateSessionDescriptorIfNeeded(sessionId: sessionId, route: route, generation: generation)
        do {
            let page = try await transport.loadRecent(machineId: machine.id, runtimeId: route.runtimeId, instanceId: route.instanceId, sessionId: sessionId, limit: 50)
            guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
            let authoritativeItems = route.runtimeId == "runtime.web"
                ? page.items.map(Self.normalizedWebAssistantMessage)
                : page.items
            await reconcilePendingUnknownCommands(with: authoritativeItems, sessionId: sessionId)
            for remoteUser in authoritativeItems where remoteUser.role == .user {
                await reconcileOptimisticUserEcho(remoteUser, sessionId: sessionId)
            }
            if route.runtimeId == "runtime.antigravity",
               sessions.first(where: { $0.id == sessionId })?.state != .busy {
                await reconcileAntigravityAuthoritativeAssistantWindow(authoritativeItems, sessionId: sessionId)
            }
            try? await cache.upsertMessages(authoritativeItems)
            merge(authoritativeItems, into: sessionId)
            if route.runtimeId == "runtime.web" {
                // A verified history page is sufficient to clean legacy visual
                // transcript artifacts. This load path has no status snapshot;
                // provider issue observations are reconciled separately by
                // refreshVisibleSessionStatus, not invented from this history read.
                await collapseWebTranscriptArtifacts(sessionId: sessionId)
                // A successful authoritative history read proves that this exact web
                // conversation is available again, even if the WEB_BINDING_CHANGED
                // recovery push was missed while the phone was backgrounded. Do not
                // leave an old "switched Project/conversation" banner pinned forever.
                if webBindingDetachedSessions.remove(sessionId) != nil,
                   (recentSystemNotice?.contains("ChatGPT 标签页") == true
                       || recentSystemNotice?.contains("标签页绑定") == true) {
                    recentSystemNotice = "电脑端 ChatGPT 会话已重新绑定；手机已补同步最新状态。"
                }
            }
            ensureSessionDescriptorExists(sessionId: sessionId, instanceId: route.instanceId, updatedAt: authoritativeItems.last?.createdAt ?? Date())
            await settleRunStateIfAuthoritativeFinalExists(authoritativeItems, sessionId: sessionId)
            if hasMoreBySession[sessionId] != page.hasMore {
                hasMoreBySession[sessionId] = page.hasMore
            }
            // A successful history read must not erase a provider terminal failure that
            // was delivered as GENERATION_STOPPED. Keeping the error while the session
            // is explicitly .error lets ChatView continue showing rate-limit / unusual-
            // activity evidence even while periodic reconciliation polls are running.
            if sessions.first(where: { $0.id == sessionId })?.state != .error,
               errors[sessionId] != nil {
                errors.removeValue(forKey: sessionId)
            }
            // A successful authoritative history read is the recovery watermark for
            // this visible conversation. Periodic status probes must not immediately
            // reload the same long transcript again unless later evidence invalidates it.
            visibleSessionHistorySyncAt[sessionId] = Date()
            if let remoteRevision {
                // This is a remote revision token, not a wall-clock freshness comparison.
                // Advance it only after loadRecent succeeded so failures remain retryable.
                visibleSessionHistoryRemoteRevision[sessionId] = remoteRevision
            }
        } catch {
            guard generation == lifecycleGeneration, !isSuspended else { return }
            let hasUsableLocalHistory = !messagesBySession[sessionId, default: []].isEmpty
            if let transportError = error as? TransportError,
               hasUsableLocalHistory,
               transportError == .timeout || transportError == .disconnected || transportError == .offline {
                // This is a refresh failure, not a conversation failure. Preserve the
                // cached transcript and let the visible-session reconciler retry instead
                // of flashing a red error that disappears on the next successful poll.
                DiagnosticsLog.shared.record("session_refresh_deferred", fields: ["session": sessionId, "reason": transportError.localizedDescription], level: "WARN")
                return
            }
            errors[sessionId] = error.localizedDescription
        }
    }

    private func refreshVisibleSessionStatus(_ sessionId: String, rejectEvidencePoorIdle: Bool = false) async -> RemoteSessionStatusSnapshot? {
        guard let route = routeForSession(sessionId), machine.state == .online, !isSuspended else { return nil }
        let requestStartedAt = Date()
        do {
            let snapshot = try await transport.sessionStatus(
                machineId: machine.id,
                runtimeId: route.runtimeId,
                instanceId: route.instanceId,
                sessionId: sessionId
            )
            guard machine.state == .online, !isSuspended else { return nil }
            let liveActivityAt = liveRunActivityAtBySession[sessionId]
            let remoteEvidenceAt = [snapshot.lastProgressAt, snapshot.lastActivityAt].compactMap { $0 }.max()
            let staleIdleSnapshot: Bool
            if snapshot.state == .idle, let liveActivityAt {
                // A poll that began before a newer live frame, or whose explicit remote
                // activity evidence predates that frame, cannot end the newer run.
                staleIdleSnapshot = liveActivityAt > requestStartedAt
                    || (remoteEvidenceAt.map { $0 < liveActivityAt } ?? rejectEvidencePoorIdle)
            } else {
                staleIdleSnapshot = false
            }
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                let current = sessions[index]
                var updated = current
                if let receivedBackgroundTaskStatus = snapshot.backgroundTaskStatus {
                    if current.backgroundTaskStatus == nil
                        || receivedBackgroundTaskStatus.observedAt > (current.backgroundTaskStatus?.observedAt ?? .distantPast) {
                        updated.backgroundTaskStatus = receivedBackgroundTaskStatus
                        updated.backgroundTaskStatusReceivedAt = Date()
                    }
                } else if (current.instanceId == "antigravity.desktop" || current.backgroundTaskStatus != nil),
                          requestStartedAt >= (current.backgroundTaskStatusReceivedAt ?? .distantPast) {
                    updated.backgroundTaskStatus = BackgroundTaskStatusSnapshot(
                        state: .unavailable,
                        observedAt: current.backgroundTaskStatus?.observedAt ?? .distantPast,
                        error: "后台任务状态未提供"
                    )
                    updated.backgroundTaskStatusReceivedAt = Date()
                }
                if !staleIdleSnapshot {
                    updated.state = snapshot.state
                    updated.lastProgressStatus = snapshot.lastProgressStatus
                    updated.lastProgressAt = snapshot.lastProgressAt
                }
                if let activity = snapshot.lastActivityAt {
                    updated.lastActivityAt = max(updated.lastActivityAt ?? updated.updatedAt, activity)
                }
                if updated != current {
                    sessions[index] = updated
                }
            }
            if route.runtimeId == "runtime.web", let browserConnected = snapshot.browserConnected {
                let previous = desktopBrowserConnected
                if previous != browserConnected { desktopBrowserConnected = browserConnected }
                desktopStatusUpdatedAt = Date()
                if !browserConnected {
                    systemTransportOfflineChannels.insert("browser-bridge")
                    recentSystemNotice = "电脑端 Agent 在线，但 Browser Bridge 已断开；RemoteAI 正在等待浏览器控制恢复。"
                } else {
                    let recovered = systemTransportOfflineChannels.remove("browser-bridge") != nil || previous == false
                    if recovered { recentSystemNotice = "电脑端 Browser Bridge 已恢复，当前会话正在补同步。" }
                }
            }
            if staleIdleSnapshot {
                DiagnosticsLog.shared.record("stale_session_idle_ignored", fields: [
                    "session": sessionId,
                    "liveActivityAt": liveActivityAt?.ISO8601Format() ?? "unknown",
                    "remoteEvidenceAt": remoteEvidenceAt?.ISO8601Format() ?? "missing",
                ], level: "WARN")
                // This poll is provably older than newer live activity. Ignore it
                // completely so it cannot create a false terminal transition or trigger
                // repeated authoritative history recovery while the newer run is active.
                return nil
            }
            if snapshot.state == .busy || snapshot.state == .waiting {
                if route.runtimeId == "runtime.web" { terminalWebRuns.remove(sessionId) }
                let activeAt = snapshot.lastProgressAt ?? snapshot.lastActivityAt ?? Date()
                markLiveRunActivity(sessionId: sessionId, at: activeAt)
                if route.runtimeId == "runtime.web" {
                    // A status poll is authoritative recovery evidence for a run that
                    // may have started while the phone was backgrounded/disconnected.
                    // Project screens render their own row array, so promote the active
                    // desktop conversation there as well instead of waiting for a new
                    // live GENERATION_STARTED/MESSAGE_UPDATED frame.
                    promoteProjectConversationActivity(sessionId: sessionId, at: activeAt)
                }
                if let raw = snapshot.lastProgressStatus, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let label = route.runtimeId == "runtime.web" ? webProcessStatusLabel(raw) : processStatusLabel(for: raw)
                    if liveRunStatusBySession[sessionId] != label { liveRunStatusBySession[sessionId] = label }
                } else if liveRunStatusBySession[sessionId] == nil {
                    liveRunStatusBySession[sessionId] = route.runtimeId == "runtime.web"
                        ? "电脑端 ChatGPT 仍在运行…"
                        : "电脑端任务仍在运行…"
                }
            } else if snapshot.state == .idle || snapshot.state == .error {
                if route.runtimeId == "runtime.web" { terminalWebRuns.insert(sessionId) }
                // getSessionStatus is authoritative recovery evidence. If the live
                // GENERATION_STOPPED / MESSAGE_ADDED push was lost, do not leave the
                // old streaming placeholder or "正在生成回答" banner pinned forever.
                discardStreamingPlaceholder(sessionId: sessionId)
                if liveRunStatusBySession[sessionId] != nil { liveRunStatusBySession.removeValue(forKey: sessionId) }
                clearLiveRunActivity(sessionId: sessionId)
                await settleRunningToolRows(sessionId: sessionId)
            }
            if route.runtimeId == "runtime.web" {
                // SESSION_STATUS push is the fast path. The authoritative session-status
                // poll carries the same providerSurfaceIssue metadata so a phone that
                // was backgrounded or briefly disconnected still converges to the real
                // ChatGPT page state after reconnect.
                applyWebProviderSurfaceIssue(
                    sessionId: sessionId,
                    issue: snapshot.providerSurfaceIssue,
                    surfaceState: snapshot.providerSurfaceState
                        ?? "degraded",
                    statusObservedAt: snapshot.providerSurfaceObservedAt ?? snapshot.providerSurfaceIssue?.at,
                    requestStartedAt: requestStartedAt
                )
            }
            return snapshot
        } catch let error as TransportError where error == .disconnected || error == .timeout || error == .offline {
            markBackgroundTaskStatusUnavailable(sessionId, requestStartedAt: requestStartedAt)
            DiagnosticsLog.shared.record("session_status_deferred", fields: Self.diagnosticFields(for: error, adding: ["session": sessionId]), level: "WARN")
            return nil
        } catch {
            markBackgroundTaskStatusUnavailable(sessionId, requestStartedAt: requestStartedAt)
            DiagnosticsLog.shared.record("session_status_failed", fields: Self.diagnosticFields(for: error, adding: ["session": sessionId]), level: "WARN")
            return nil
        }
    }

    private func markBackgroundTaskStatusUnavailable(_ sessionId: String, requestStartedAt: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let currentSession = sessions[index]
        guard currentSession.instanceId == "antigravity.desktop" || currentSession.backgroundTaskStatus != nil else { return }
        guard requestStartedAt >= (currentSession.backgroundTaskStatusReceivedAt ?? .distantPast) else { return }
        sessions[index].backgroundTaskStatus = BackgroundTaskStatusSnapshot(
            state: .unavailable,
            observedAt: currentSession.backgroundTaskStatus?.observedAt ?? .distantPast,
            error: "后台任务状态暂不可用"
        )
        sessions[index].backgroundTaskStatusReceivedAt = Date()
    }

    /// Catch up a conversation that is currently visible on the phone. Websocket push
    /// remains the fast path; this bounded reconciliation is the safety net for a live
    /// event that was lost while the relay socket still looked connected. Active runs
    /// poll more frequently so a provider final/progress state appears without requiring
    /// the user to leave and reopen the chat.
    func synchronizeVisibleSession(_ sessionId: String, force: Bool = false) async {
        guard machine.state == .online, !isSuspended else { return }
        guard !sessionLoads.contains(sessionId) else { return }

        let sessionBeforeStatus = sessions.first(where: { $0.id == sessionId })
        let active = sessionBeforeStatus.map { $0.state == .busy || $0.state == .waiting } == true
            || liveRunStatusBySession[sessionId] != nil
        let knownActivityBeforeStatus = [
            sessionBeforeStatus?.lastActivityAt,
            sessionBeforeStatus?.updatedAt,
            liveRunActivityAtBySession[sessionId],
        ].compactMap { $0 }.max()
        let minimumInterval = active
            ? Self.activeVisibleSessionSyncMinimumInterval
            : Self.idleVisibleSessionSyncMinimumInterval
        let now = Date()
        if !force,
           let last = visibleSessionSyncAt[sessionId],
           now.timeIntervalSince(last) < minimumInterval {
            return
        }
        visibleSessionSyncAt[sessionId] = now

        // WebSocket push is the primary event path and the global 15-second sync-head
        // probe already detects a quiet cursor gap. Do not issue getChangesAfterCursor
        // on every 2.5-second visible-chat tick; only repair when lifecycle/stream state
        // says recovery is actually needed.
        let liveActivityBeforeRecovery = liveRunActivityAtBySession[sessionId]
        if force || syncState == "stale" || !incompleteAssistantStreams.isEmpty {
            await recoverDelta()
            guard machine.state == .online, !isSuspended, !deltaRecoveryInFlight else { return }
        }
        let recoveredLiveActivityDuringSync: Bool
        if let after = liveRunActivityAtBySession[sessionId] {
            recoveredLiveActivityDuringSync = liveActivityBeforeRecovery.map { after > $0 } ?? true
        } else {
            recoveredLiveActivityDuringSync = false
        }

        let remoteStatus = await refreshVisibleSessionStatus(sessionId, rejectEvidencePoorIdle: recoveredLiveActivityDuringSync)
        guard machine.state == .online, !isSuspended else { return }

        let terminalTransition = active
            && remoteStatus.map { $0.state == .idle || $0.state == .error } == true
        let stillActive = remoteStatus.map { $0.state == .busy || $0.state == .waiting } ?? active
        let remoteEvidenceAt = remoteStatus.flatMap { snapshot in
            [snapshot.lastProgressAt, snapshot.lastActivityAt].compactMap { $0 }.max()
        }
        // Older Agents omit updatedAt. Keep their existing terminal evidence as a
        // fallback so a newer final/activity timestamp can still recover history.
        // Current Agents use the exact remote revision path below and never compare
        // that server timestamp with the phone's catalog Date.
        let missedTerminalActivity = remoteStatus?.updatedAt == nil
            && !stillActive
            && remoteEvidenceAt.map { remoteAt in
                knownActivityBeforeStatus.map { remoteAt > $0 } ?? true
            } == true
        // Full history/DOM reconciliation is intentionally evidence-driven. Re-reading
        // and re-merging the latest 50 messages on a fixed 10/30-second timer makes long
        // contexts stutter even though push/cursor state is healthy. Reload only when:
        // - the user/lifecycle explicitly forces reconciliation,
        // - the prior authoritative history watermark was invalidated (for example a
        //   large cursor fast-forward clears it),
        // - an active run became terminal, so a missed final must be recovered, or
        // - status reports a different remote session revision than the last successful
        //   history read, including an ordinary idle catalog/message update.
        // updatedAt is a server revision token. The decision compares exact equality
        // with the revision last covered by a successful loadRecent; the phone and PC
        // clocks may be skewed, so their Date values are never ordered here.
        let historyDue = Self.visibleHistoryReloadDue(
            force: force,
            hasSuccessfulHistory: visibleSessionHistorySyncAt[sessionId] != nil,
            terminalTransition: terminalTransition,
            remoteStatusIsTerminal: remoteStatus.map { $0.state == .idle || $0.state == .error } ?? false,
            remoteRevision: remoteStatus?.updatedAt,
            lastSuccessfulRemoteRevision: visibleSessionHistoryRemoteRevision[sessionId]
        ) || missedTerminalActivity
        if historyDue {
            await loadSession(sessionId, remoteRevision: remoteStatus?.updatedAt)
        }
    }

    func downloadMessageAttachmentFile(sessionId: String, attachment: MessageAttachment) async -> URL? {
        guard let attachmentId = attachment.attachmentId, attachmentId.hasPrefix("webasset-") else { return nil }
        guard machine.state == .online, !isSuspended, let route = routeForSession(sessionId) else { return nil }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = documents.appendingPathComponent("Downloads", isDirectory: true)
        do {
            let downloaded = try await transport.downloadMessageAttachmentFile(
                machineId: machine.id,
                runtimeId: route.runtimeId,
                instanceId: route.instanceId,
                sessionId: sessionId,
                attachmentId: attachmentId,
                attachmentName: attachment.name,
                destinationDirectory: directory
            )
            DiagnosticsLog.shared.record("attachment_download_ready", fields: [
                "session": sessionId,
                "attachmentId": attachmentId,
                "sizeBytes": String(downloaded.sizeBytes),
            ])
            return downloaded.url
        } catch {
            var fields: [String: String] = [
                "session": sessionId,
                "attachmentId": attachmentId,
                "errorType": String(describing: type(of: error)),
            ]
            if let transportError = error as? TransportError {
                fields.merge(transportError.diagnosticFields) { _, new in new }
            }
            DiagnosticsLog.shared.record("attachment_download_failed", fields: fields, level: "WARN")
            return nil
        }
    }

    func loadMessageAttachmentData(sessionId: String, attachment: MessageAttachment) async -> Data? {
        guard let attachmentId = attachment.attachmentId, attachmentId.hasPrefix("webasset-") else { return nil }
        let cacheKey = "\(sessionId)|\(attachmentId)" as NSString
        if let cached = messageAttachmentCache.object(forKey: cacheKey) { return cached as Data }
        guard machine.state == .online, !isSuspended, let route = routeForSession(sessionId) else { return nil }
        do {
            let downloaded = try await transport.downloadMessageAttachment(
                machineId: machine.id,
                runtimeId: route.runtimeId,
                instanceId: route.instanceId,
                sessionId: sessionId,
                attachmentId: attachmentId,
                attachmentName: attachment.name
            )
            guard downloaded.data.count <= MessageAttachmentTransferPolicy.maxDownloadBytes else { return nil }
            if downloaded.data.count <= MessageAttachmentTransferPolicy.previewCacheBytes {
                messageAttachmentCache.setObject(downloaded.data as NSData, forKey: cacheKey, cost: downloaded.data.count)
                messageAttachmentCache.totalCostLimit = 40 * 1024 * 1024
            }
            return downloaded.data
        } catch {
            var fields: [String: String] = [
                "session": sessionId,
                "attachmentId": attachmentId,
                "errorType": String(describing: type(of: error)),
            ]
            if let transportError = error as? TransportError {
                fields.merge(transportError.diagnosticFields) { _, new in new }
            }
            DiagnosticsLog.shared.record("attachment_preview_failed", fields: fields, level: "WARN")
            return nil
        }
    }

    func loadOlder(_ sessionId: String) async {
        guard olderMessageLoads.insert(sessionId).inserted else { return }
        defer { olderMessageLoads.remove(sessionId) }
        let generation = lifecycleGeneration
        guard let first = messagesBySession[sessionId]?.first, hasMoreBySession[sessionId] != false else { return }
        do {
            let page: Page<ChatMessage>
            if machine.state == .online, let route = routeForSession(sessionId) {
                page = try await transport.loadBefore(machineId: machine.id, runtimeId: route.runtimeId, instanceId: route.instanceId, sessionId: sessionId, before: first.cursor, limit: 40)
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
    func send(text: String, runtimeId: String, instanceId: String, sessionId: String, attachments: [PendingAttachment] = [], model: String = "", reasoningEffort: String = "", commandId: UUID = UUID()) async -> Bool {
        guard commandSendsInFlight.insert(commandId).inserted else { return false }
        defer { commandSendsInFlight.remove(commandId) }
        let generation = lifecycleGeneration
        let sendStartedAt = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagnosticsLog.shared.record("send_begin", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "hasInput": String(!trimmed.isEmpty), "attachments": String(attachments.count), "commandId": commandId.uuidString])
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        guard attachments.count <= 8, attachments.allSatisfy({ $0.sizeBytes > 0 && $0.sizeBytes <= 20 * 1024 * 1024 }) else {
            errors[sessionId] = "最多一次发送 8 个附件，每个附件不能超过 20MB。"
            return false
        }
        let activeTransport = transport
        let activeMachineId = machine.id
        if machine.state != .online {
            // machine.state is a presentation snapshot and can lag a healthy socket by
            // one reconnect-monitor tick. Before rejecting an explicit user send, let an
            // already-connected Transport prove the authoritative Agent state. This is
            // especially important for attachment replay: the same operation/derived
            // chunk command IDs are idempotent, so a retry immediately after reconnect
            // must not be dropped merely because the UI still says Offline.
            var recoveredConnectedTransport = false
            if await activeTransport.isConnected {
                do {
                    let authenticatedSequence = try await activeTransport.latestSequence(machineId: activeMachineId)
                    guard generation == lifecycleGeneration,
                          transport === activeTransport,
                          machine.id == activeMachineId,
                          !isSuspended else { return false }
                    machine.state = .online
                    connectionPhase = .online
                    errors["connection"] = nil
                    await recoverDelta(freshLatestSequence: authenticatedSequence)
                    recoveredConnectedTransport = true
                    DiagnosticsLog.shared.record("send_stale_offline_recovered", fields: [
                        "runtime": runtimeId,
                        "instance": instanceId,
                        "session": sessionId,
                        "commandId": commandId.uuidString,
                    ])
                } catch {
                    DiagnosticsLog.shared.record("send_stale_offline_probe_failed", fields: Self.diagnosticFields(for: error, adding: [
                        "runtime": runtimeId,
                        "instance": instanceId,
                        "session": sessionId,
                        "commandId": commandId.uuidString,
                    ]), level: "WARN")
                }
            }
            guard recoveredConnectedTransport else {
                if !trimmed.isEmpty { try? await cache.saveDraft(trimmed, sessionId: sessionId) }
                errors[sessionId] = attachments.isEmpty
                    ? "PC Offline — draft saved. Tap Send after reconnecting."
                    : "PC Offline — 附件需要连接 Windows 后才能上传。"
                DiagnosticsLog.shared.record("send_offline", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString], level: "WARN")
                return false
            }
        }

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

            let optimisticAttachments = remoteAttachments.map {
                MessageAttachment(
                    attachmentId: $0.attachmentId,
                    name: $0.name,
                    contentType: $0.contentType,
                    sizeBytes: $0.sizeBytes,
                    previewURL: nil,
                    downloadURL: nil
                )
            }
            let optimistic = ChatMessage(id: commandId.uuidString, sessionId: sessionId, sequence: nil, role: .user, kind: .text, text: trimmed, toolName: nil, toolStatus: nil, detail: nil, attachments: optimisticAttachments, createdAt: Date())
            merge([optimistic], into: sessionId)
            try? await cache.upsertMessages([optimistic])
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }

            var payload: [String: JSONValue] = ["text": .string(trimmed)]
            if !model.isEmpty { payload["model"] = .string(model) }
            // Empty explicitly selects the CLI default. Omitting it would retain
            // the previous model's effort after the user changes models.
            if runtimeId == "runtime.codex" { payload["reasoningEffort"] = .string(reasoningEffort) }
            if !remoteAttachments.isEmpty { payload["attachmentIds"] = .array(remoteAttachments.map { .string($0.attachmentId) }) }
            let command = RemoteCommand.make(machineId: activeMachineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "sendMessage", payload: payload, commandId: commandId)
            try? await cache.put(command, key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            messageCommandPersisted = true
            commandStates[commandId] = .executing
            let finalState = try await activeTransport.send(command)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            commandStates[commandId] = finalState
            // Delivery confirmation is already enough to tell the phone that this turn
            // is active. Do not wait for a GENERATION_STARTED websocket event: that event
            // can be lost during a ChatGPT SPA document replacement even though Send was
            // accepted. The next authoritative final/delta will settle this state.
            let confirmedSendAt = Date()
            setSessionState(sessionId, .busy)
            markLiveRunActivity(sessionId: sessionId, at: confirmedSendAt)
            if runtimeId == "runtime.web" {
                promoteProjectConversationActivity(sessionId: sessionId, at: confirmedSendAt)
            }
            liveRunStatusBySession[sessionId] = runtimeId == "runtime.web"
                ? "已发送，等待 ChatGPT 响应…"
                : "已发送，等待远端响应…"
            // A confirmed browser send is not the end of synchronization. Immediately
            // reconcile the authoritative event delta so a missed websocket user echo,
            // generation/progress event, or fast assistant final cannot leave the phone stale.
            await recoverDelta()
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            try? await cache.saveDraft("", sessionId: sessionId)
            if generation == lifecycleGeneration, !isSuspended { errors[sessionId] = nil }
            DiagnosticsLog.shared.record("send_ok", fields: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "state": finalState.rawValue, "durationMs": Self.durationMilliseconds(since: sendStartedAt)])
            return true
        } catch is CancellationError {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            if messageCommandPersisted {
                commandStates[commandId] = .unknown
                errors[sessionId] = "发送确认已中断，送达状态未知。原命令已保留，核查前不会重发。"
                return false
            }
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            await removeOptimisticCommandMessage(commandId: commandId, sessionId: sessionId)
            errors[sessionId] = "Attachment upload cancelled before message delivery. The composer keeps your local text/files so you can send again."
            return false
        } catch let error as TransportError where Self.isRecoverableCommandTransportError(error) {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .unknown
            DiagnosticsLog.shared.record("send_transport_interrupted", fields: Self.diagnosticFields(for: error, adding: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString, "persisted": String(messageCommandPersisted)]), level: "WARN")

            // An interrupted acknowledgement does not prove delivery failed.
            // Reconnect and inspect durable evidence; never automatically send again.
            if messageCommandPersisted,
               await reconcileUnknownSend(commandId: commandId, runtimeId: runtimeId,
                    instanceId: instanceId, sessionId: sessionId, generation: generation,
                    activeTransport: activeTransport, machineId: activeMachineId) {
                return true
            }
            guard generation == lifecycleGeneration, transport === activeTransport,
                  machine.id == activeMachineId, !isSuspended else { return false }
            errors[sessionId] = messageCommandPersisted
                ? "Connection dropped while sending. Delivery is unknown; check delivery status before sending again."
                : "Attachment transfer was interrupted before message delivery was attempted. Retry from the composer reuses the same operation ID."
            return false
        } catch let error as TransportError {
            guard generation == lifecycleGeneration, transport === activeTransport,
                  machine.id == activeMachineId, !isSuspended else { return false }
            if Self.isUnknownWebSendOutcome(error, runtimeId: runtimeId) {
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
                attachmentTransferBySession.removeValue(forKey: sessionId)
                commandStates[commandId] = .unknown
                errors[sessionId] = "Delivery is unknown after the ChatGPT page changed. Checking durable delivery evidence; no message will be sent again."
                DiagnosticsLog.shared.record("send_unknown_delivery", fields: Self.diagnosticFields(for: error, adding: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString]), level: "WARN")
                return await reconcileUnknownSend(commandId: commandId, runtimeId: runtimeId,
                    instanceId: instanceId, sessionId: sessionId, generation: generation,
                    activeTransport: activeTransport, machineId: activeMachineId)
            }
            if messageCommandPersisted {
                // Only an explicit provider/Agent failure receipt can classify
                // a dispatched send as failed. A malformed or rejected reply
                // frame gives no evidence about the provider side effect.
                if case .remote = error { /* handled as a definitive remote failure below */ }
                else {
                    commandStates[commandId] = .unknown
                    attachmentTransferBySession.removeValue(forKey: sessionId)
                    return await reconcileUnknownSend(commandId: commandId, runtimeId: runtimeId,
                        instanceId: instanceId, sessionId: sessionId, generation: generation,
                        activeTransport: activeTransport, machineId: activeMachineId)
                }
            }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            await removeOptimisticCommandMessage(commandId: commandId, sessionId: sessionId)
            if !trimmed.isEmpty { try? await cache.saveDraft(trimmed, sessionId: sessionId) }
            errors[sessionId] = error.localizedDescription
            DiagnosticsLog.shared.record("send_failed", fields: Self.diagnosticFields(for: error, adding: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString]), level: "ERROR")
            return false
        } catch {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            attachmentTransferBySession.removeValue(forKey: sessionId)
            if messageCommandPersisted {
                commandStates[commandId] = .unknown
                errors[sessionId] = "发送回执无法确认：\(error.localizedDescription)。原命令已保留，不会自动重发。"
                return false
            }
            commandStates[commandId] = .failed
            try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: activeMachineId))
            await removeOptimisticCommandMessage(commandId: commandId, sessionId: sessionId)
            if !trimmed.isEmpty { try? await cache.saveDraft(trimmed, sessionId: sessionId) }
            errors[sessionId] = error.localizedDescription
            DiagnosticsLog.shared.record("send_failed", fields: Self.diagnosticFields(for: error, adding: ["runtime": runtimeId, "instance": instanceId, "session": sessionId, "commandId": commandId.uuidString]), level: "ERROR")
            return false
        }
    }

    // Both automatic reconnect and the user's status check reuse this read-only
    // reconciliation. A cached ambiguous FAILED receipt is never delivery failure.
    private func reconcileUnknownSend(commandId: UUID, runtimeId: String, instanceId: String,
        sessionId: String, generation: UInt64, activeTransport: Transport, machineId: String) async -> Bool {
        func current() -> Bool {
            generation == lifecycleGeneration && transport === activeTransport
                && machine.id == machineId && !isSuspended
        }
        do {
            guard current() else { return false }
            if !(await activeTransport.isConnected) { try await activeTransport.connect() }
            let head = try await activeTransport.latestSequence(machineId: machineId)
            guard current() else { return false }
            machine.state = .online
            connectionPhase = .online
            errors["connection"] = nil
            await recoverDelta(freshLatestSequence: head)
            guard current() else { return false }
            // A successful durable Agent receipt proves the original dispatch was
            // confirmed, even when the websocket reply was lost during reconnect.
            // Older Windows releases lack this query; keep Unknown instead of
            // repeating an uncertain Send or inventing a terminal failure.
            if commandStates[commandId] == .unknown,
               let receipt = try? await activeTransport.commandOutcome(
                   machineId: machineId, targetCommandId: commandId),
               receipt.accepted {
                guard current() else { return false }
                commandStates[commandId] = .completed
                DiagnosticsLog.shared.record("send_durable_receipt_recovered",
                    fields: ["session": sessionId, "commandId": commandId.uuidString])
            }
            for attempt in 0..<3 where commandStates[commandId] == .unknown {
                guard current() else { return false }
                let page = try await activeTransport.loadRecent(machineId: machineId,
                    runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, limit: 50)
                guard current() else { return false }
                await reconcilePendingUnknownCommands(with: page.items, sessionId: sessionId)
                for remoteUser in page.items where remoteUser.role == .user {
                    await reconcileOptimisticUserEcho(remoteUser, sessionId: sessionId)
                }
                try? await cache.upsertMessages(page.items)
                guard current() else { return false }
                merge(page.items, into: sessionId)
                releaseRecoveryDisplaySnapshot(for: sessionId)
                ensureSessionDescriptorExists(sessionId: sessionId, instanceId: instanceId,
                    updatedAt: page.items.last?.createdAt ?? Date())
                await settleRunStateIfAuthoritativeFinalExists(page.items, sessionId: sessionId)
                hasMoreBySession[sessionId] = page.hasMore
                if commandStates[commandId] == .completed { break }
                if attempt < 2 { try await Task.sleep(nanoseconds: 400_000_000) }
            }
            guard current() else { return false }
            if commandStates[commandId] == .completed {
                try? await cache.remove(key: Self.pendingCommandKey(commandId, machineId: machineId))
                try? await cache.saveDraft("", sessionId: sessionId)
                guard current() else { return false }
                errors[sessionId] = nil
                if messagesBySession[sessionId, default: []].last?.role == .user {
                    setSessionState(sessionId, .busy)
                    markLiveRunActivity(sessionId: sessionId, at: Date())
                    liveRunStatusBySession[sessionId] = "已确认发送，等待远端响应…"
                }
                return true
            }
        } catch {
            guard current() else { return false }
            DiagnosticsLog.shared.record("send_reconcile_unconfirmed",
                fields: Self.diagnosticFields(for: error, adding: ["session": sessionId,
                    "commandId": commandId.uuidString]), level: "WARN")
        }
        guard current() else { return false }
        // Keep the exact payload for future evidence matching and manual diagnosis.
        commandStates[commandId] = .unknown
        errors[sessionId] = "送达状态仍未确认。已保留原 command ID；请核查电脑原会话，不会自动重发。"
        return false
    }

    func retry(message: ChatMessage, runtimeId: String, instanceId: String, model: String = "") async {
        guard let commandId = UUID(uuidString: message.id), commandStates[commandId] == .unknown,
              commandSendsInFlight.insert(commandId).inserted else { return }
        defer { commandSendsInFlight.remove(commandId) }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        guard !isSuspended else { return }
        _ = await reconcileUnknownSend(commandId: commandId, runtimeId: runtimeId,
            instanceId: instanceId, sessionId: message.sessionId, generation: generation,
            activeTransport: activeTransport, machineId: activeMachineId)
    }

    @discardableResult
    func stop(runtimeId: String, instanceId: String, sessionId: String) async -> Bool {
        let requestedRun = stopRunIdentity(for: sessionId)
        if let inFlight = stopTasksBySession[sessionId] {
            if inFlight.runIdentity.canCoalesceStopTask(as: requestedRun) {
                return await inFlight.task.value
            }
            _ = await inFlight.task.value
            if let current = stopTasksBySession[sessionId], current.token != inFlight.token {
                if current.runIdentity.canCoalesceStopTask(as: requestedRun) {
                    return await current.task.value
                }
                return false
            }
            if stopTasksBySession[sessionId]?.token == inFlight.token {
                stopTasksBySession.removeValue(forKey: sessionId)
            }
            // Do not let an old Stop task become a new Stop if the target changed
            // again while this caller was waiting for it to settle.
            guard stopRunIdentity(for: sessionId) == requestedRun else { return false }
        }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performStop(runtimeId: runtimeId, instanceId: instanceId,
                sessionId: sessionId, runIdentity: requestedRun)
        }
        stopTasksBySession[sessionId] = StopTaskEntry(token: token, runIdentity: requestedRun, task: task)
        let result = await task.value
        if stopTasksBySession[sessionId]?.token == token {
            stopTasksBySession.removeValue(forKey: sessionId)
        }
        return result
    }

    private func stopRunIdentity(for sessionId: String) -> StopRunIdentity {
        let session = sessions.first(where: { $0.id == sessionId })
        let activityAt = [
            session?.lastActivityAt,
            session?.lastProgressAt,
            liveRunActivityAtBySession[sessionId],
        ].compactMap { $0 }.max()
        return StopRunIdentity(
            eventRevision: stopEventRevisionsBySession[sessionId, default: 0],
            generationSequence: stopRunStartSequenceBySession[sessionId],
            generationKey: stopRunGenerationKeyBySession[sessionId],
            activityAt: activityAt
        )
    }

    private func laterStopActivity(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (first?, second?): return max(first, second)
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }

    private func stopStatusHasFreshIdleEvidence(
        _ snapshot: RemoteSessionStatusSnapshot,
        requestStartedAt: Date,
        sessionId: String
    ) -> Bool {
        guard snapshot.state == .idle else { return true }
        let liveActivityAt = [
            liveRunActivityAtBySession[sessionId],
            sessions.first(where: { $0.id == sessionId })?.lastActivityAt,
            sessions.first(where: { $0.id == sessionId })?.lastProgressAt,
        ].compactMap { $0 }.max()
        guard let liveActivityAt else { return true }
        let remoteEvidenceAt = [snapshot.lastProgressAt, snapshot.lastActivityAt].compactMap { $0 }.max()
        return liveActivityAt <= requestStartedAt
            && (remoteEvidenceAt.map { $0 >= liveActivityAt } ?? false)
    }

    private func stopOperationCacheKey(runtimeId: String, instanceId: String,
        sessionId: String, machineId: String) -> String {
        "pending.operation.\(machineId).stop.\(runtimeId).\(instanceId).\(sessionId)"
    }

    private func loadPendingStopOperation(cacheKey: String) async -> PendingStopOperation? {
        if let record = try? await cache.get(PendingStopOperation.self, key: cacheKey) {
            return record
        }
        // Read the previous UUID-only representation once so it cannot be replayed
        // against a later run without first checking authoritative session status.
        guard let raw = try? await cache.get(String.self, key: cacheKey),
              let commandId = UUID(uuidString: raw) else { return nil }
        return PendingStopOperation(commandId: commandId, runIdentity: nil)
    }

    private func finishPendingStopOperation(cacheKey: String, expectedCommandId: UUID) async {
        guard let pending = await loadPendingStopOperation(cacheKey: cacheKey),
              pending.commandId == expectedCommandId else { return }
        try? await cache.remove(key: cacheKey)
    }

    private func performStop(runtimeId: String, instanceId: String, sessionId: String,
        runIdentity: StopRunIdentity) async -> Bool {
        guard machine.state == .online else {
            errors[sessionId] = "PC Offline — stop will not be queued blindly."
            return false
        }
        let generation = lifecycleGeneration
        let activeTransport = transport
        let activeMachineId = machine.id
        let cacheKey = stopOperationCacheKey(runtimeId: runtimeId, instanceId: instanceId,
            sessionId: sessionId, machineId: activeMachineId)
        guard stopRunIdentity(for: sessionId) == runIdentity else { return false }
        stopRequestsPending.insert(sessionId)
        defer { stopRequestsPending.remove(sessionId) }

        var commandId = UUID()
        var reusedUnknownOperation = false
        if let pending = await loadPendingStopOperation(cacheKey: cacheKey) {
            guard generation == lifecycleGeneration, transport === activeTransport,
                  machine.id == activeMachineId, !isSuspended,
                  stopRunIdentity(for: sessionId) == runIdentity else { return false }
            // A prior request may have stopped the old generation but lost its ACK.
            // Before any explicit retry, read status and only replay its command ID
            // when the same run is still active. An old cached ACK must never idle a
            // newer generation.
            let statusRequestStartedAt = Date()
            do {
                if !(await activeTransport.isConnected) { try await activeTransport.connect() }
                let snapshot = try await activeTransport.sessionStatus(
                    machineId: activeMachineId, runtimeId: runtimeId,
                    instanceId: instanceId, sessionId: sessionId
                )
                guard generation == lifecycleGeneration, transport === activeTransport,
                      machine.id == activeMachineId, !isSuspended,
                      stopRunIdentity(for: sessionId) == runIdentity else { return false }
                if !stopStatusHasFreshIdleEvidence(snapshot, requestStartedAt: statusRequestStartedAt,
                    sessionId: sessionId) {
                    errors[sessionId] = "Stop delivery is unknown and the status reply may be stale. No Stop was retried."
                    return false
                }
                if snapshot.state == .idle || snapshot.state == .error {
                    await finishPendingStopOperation(cacheKey: cacheKey, expectedCommandId: pending.commandId)
                    guard generation == lifecycleGeneration, transport === activeTransport,
                          machine.id == activeMachineId, !isSuspended,
                          stopRunIdentity(for: sessionId) == runIdentity else { return false }
                    if snapshot.state == .idle {
                        setSessionState(sessionId, .idle)
                        liveRunStatusBySession.removeValue(forKey: sessionId)
                    } else {
                        setSessionState(sessionId, .error)
                    }
                    errors[sessionId] = nil
                    return true
                }
                guard snapshot.state == .busy || snapshot.state == .waiting else {
                    errors[sessionId] = "Stop delivery is unknown; the current session state is not safe to retry."
                    return false
                }
                let remoteEvidenceAt = [snapshot.lastProgressAt, snapshot.lastActivityAt].compactMap { $0 }.max()
                let statusEvidenceAt = remoteEvidenceAt
                var statusBackedIdentity = runIdentity
                if statusBackedIdentity.generationKey == nil,
                   statusBackedIdentity.generationSequence == nil,
                   let statusEvidenceAt {
                    statusBackedIdentity = StopRunIdentity(
                        eventRevision: runIdentity.eventRevision,
                        generationSequence: nil,
                        generationKey: nil,
                        activityAt: max(runIdentity.activityAt ?? .distantPast, statusEvidenceAt)
                    )
                }
                if let pendingIdentity = pending.runIdentity,
                   pendingIdentity.identifiesSameRun(as: statusBackedIdentity) {
                    commandId = pending.commandId
                    reusedUnknownOperation = true
                }
                // UUID-only legacy records and records for a prior generation receive
                // a new ID after this fresh status check.
            } catch {
                guard generation == lifecycleGeneration, transport === activeTransport,
                      machine.id == activeMachineId, !isSuspended else { return false }
                errors[sessionId] = "Stop delivery is unknown. Current status could not be confirmed, so no Stop was retried: \(error.localizedDescription)"
                return false
            }
        }
        guard generation == lifecycleGeneration, transport === activeTransport,
              machine.id == activeMachineId, !isSuspended,
              stopRunIdentity(for: sessionId) == runIdentity else { return false }
        let statusEvidenceAt = [
            sessions.first(where: { $0.id == sessionId })?.lastActivityAt,
            sessions.first(where: { $0.id == sessionId })?.lastProgressAt,
            liveRunActivityAtBySession[sessionId],
        ].compactMap { $0 }.max()
        let persistedIdentity = StopRunIdentity(
            eventRevision: runIdentity.eventRevision,
            generationSequence: runIdentity.generationSequence,
            generationKey: runIdentity.generationKey,
            activityAt: runIdentity.generationSequence == nil && runIdentity.generationKey == nil
                ? laterStopActivity(runIdentity.activityAt, statusEvidenceAt)
                : runIdentity.activityAt
        )
        try? await cache.put(PendingStopOperation(commandId: commandId, runIdentity: persistedIdentity), key: cacheKey)
        guard generation == lifecycleGeneration, transport === activeTransport,
              machine.id == activeMachineId, !isSuspended,
              stopRunIdentity(for: sessionId) == runIdentity else {
            if !reusedUnknownOperation { await finishPendingStopOperation(cacheKey: cacheKey, expectedCommandId: commandId) }
            return false
        }
        let command = RemoteCommand.make(machineId: activeMachineId, runtimeId: runtimeId, instanceId: instanceId, sessionId: sessionId, action: "stopGeneration", commandId: commandId)
        commandStates[command.commandId] = .pending
        do {
            let receipt = try await activeTransport.requestStop(command)
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            commandStates[command.commandId] = receipt.confirmed ? .completed : .acknowledged
            await finishPendingStopOperation(cacheKey: cacheKey, expectedCommandId: commandId)
            guard generation == lifecycleGeneration, transport === activeTransport,
                  machine.id == activeMachineId, !isSuspended else { return false }
            // A successful Relay/Router ACK cannot synthesize a terminal boundary.
            // Never stop a newer generation or clear Running on unconfirmed Stop.
            if !receipt.confirmed {
                if stopRunIdentity(for: sessionId) == runIdentity {
                    errors[sessionId] = receipt.staleGeneration
                        ? "停止命令针对的生成已变化；没有停止新的生成。"
                        : "停止请求已到达执行端，但尚未确认停止；当前状态仍需重新核验。"
                }
                DiagnosticsLog.shared.record("stop_unconfirmed", fields: [
                    "session": sessionId, "settled": String(receipt.settled),
                    "stopped": String(receipt.stopped),
                    "staleGeneration": String(receipt.staleGeneration)
                ], level: "WARN")
                return false
            }
            // Events delivered after the Stop was issued are authoritative. In
            // particular a newer GENERATION_STARTED must not be rolled back by this
            // request's cached/successful acknowledgement.
            if reusedUnknownOperation {
                let statusRequestStartedAt = Date()
                do {
                    let snapshot = try await activeTransport.sessionStatus(
                        machineId: activeMachineId, runtimeId: runtimeId,
                        instanceId: instanceId, sessionId: sessionId
                    )
                    guard generation == lifecycleGeneration, transport === activeTransport,
                          machine.id == activeMachineId, !isSuspended else { return false }
                    guard stopRunIdentity(for: sessionId) == runIdentity else { return true }
                    guard stopStatusHasFreshIdleEvidence(snapshot,
                        requestStartedAt: statusRequestStartedAt, sessionId: sessionId) else {
                        errors[sessionId] = "Stop acknowledgement was replayed, but status evidence may be stale. The current run remains unchanged."
                        return false
                    }
                    switch snapshot.state {
                    case .idle:
                        setSessionState(sessionId, .idle)
                        liveRunStatusBySession.removeValue(forKey: sessionId)
                        errors[sessionId] = nil
                        return true
                    case .error:
                        setSessionState(sessionId, .error)
                        errors[sessionId] = nil
                        return true
                    case .busy, .waiting:
                        errors[sessionId] = "The Stop receipt is complete, but current status still shows this run as active. Tap Stop again to issue a new check."
                        return false
                    default:
                        errors[sessionId] = "The Stop receipt is complete, but current status is not conclusive."
                        return false
                    }
                } catch {
                    guard generation == lifecycleGeneration, transport === activeTransport,
                          machine.id == activeMachineId, !isSuspended else { return false }
                    if stopRunIdentity(for: sessionId) == runIdentity {
                        errors[sessionId] = "Stop acknowledgement could not be reconciled with current status: \(error.localizedDescription)"
                    }
                    return false
                }
            }
            if stopRunIdentity(for: sessionId) == runIdentity {
                if runtimeId == "runtime.web" { terminalWebRuns.insert(sessionId) }
                setSessionState(sessionId, .idle)
                liveRunStatusBySession.removeValue(forKey: sessionId)
                clearLiveRunActivity(sessionId: sessionId)
                errors[sessionId] = nil
            }
            return true
        } catch {
            guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
            commandStates[command.commandId] = isUnknownDelivery(error) ? .unknown : .failed
            if !isUnknownDelivery(error) {
                await finishPendingStopOperation(cacheKey: cacheKey, expectedCommandId: commandId)
                guard generation == lifecycleGeneration, transport === activeTransport,
                      machine.id == activeMachineId, !isSuspended else { return false }
            }
            if stopRunIdentity(for: sessionId) == runIdentity {
                errors[sessionId] = error.localizedDescription
            }
            return false
        }
    }

    func createSession(
        runtime: RuntimeDescriptor,
        instance: InstanceDescriptor,
        title: String,
        model: String = "",
        reasoningEffort: String = "",
        projectAlias: String? = nil,
        codexProjectPath: String? = nil
    ) async -> Bool {
        guard creatingSessions.insert(instance.id).inserted else { return false }
        defer { creatingSessions.remove(instance.id) }
        let generation = lifecycleGeneration
        let effectiveTitle = title.isEmpty ? "New Session" : title
        var payload: [String: JSONValue] = [
            "title": .string(effectiveTitle)
        ]
        if (runtime.kind == .codex || runtime.kind == .antigravity), !model.isEmpty {
            payload["model"] = .string(model)
        }
        if runtime.kind == .antigravity, let projectAlias, !projectAlias.isEmpty {
            payload["projectAlias"] = .string(projectAlias)
        }
        if runtime.kind == .codex {
            if !reasoningEffort.isEmpty { payload["reasoningEffort"] = .string(reasoningEffort) }
            // Explicitly use the existing CLI executor. Codex Desktop cannot
            // create an owner-bound native Thread through its follower IPC.
            payload["createMode"] = .string("cli")
            if let codexProjectPath, !codexProjectPath.isEmpty {
                payload["projectPath"] = .string(codexProjectPath)
            }
        }
        guard machine.state == .online else {
            errors[instance.id] = "PC Offline — new sessions are not queued automatically."
            return false
        }
        let activeTransport = transport
        let activeMachineId = machine.id
        sessionRevisions[instance.id, default: 0] &+= 1
        let operationKey = "createSession.\(runtime.id).\(instance.id).\(effectiveTitle).\(model).\(reasoningEffort).\(projectAlias ?? codexProjectPath ?? "")"
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
                let local = SessionDescriptor(id: UUID().uuidString, instanceId: instance.id, title: title.isEmpty ? (runtime.kind == .web || runtime.kind == .antigravity ? "New Chat" : "New Session") : title, state: .idle, updatedAt: Date())
                sessions.insert(local, at: 0)
                errors[instance.id] = nil
                await persistMetadata()
                return true
            } else {
                guard generation == lifecycleGeneration, transport === activeTransport, machine.id == activeMachineId, !isSuspended else { return false }
                // The command may have reached Windows even if the transport
                // cannot decode a Session. Do not claim success or discard the
                // original idempotency key; an explicit retry must reuse it.
                errors[instance.id] = "Chat creation outcome is unverified. No Chat identity returned; Retry uses the original command ID."
                return false
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
        guard !pairingInProgress else {
            throw TransportError.remote("PAIRING_IN_PROGRESS", "A pairing attempt is already in progress.")
        }
        pairingInProgress = true
        defer { pairingInProgress = false }

        pairingStage = .preparing
        isSuspended = false
        lifecycleGeneration &+= 1
        restartAfterStart = false
        eventTask?.cancel()
        eventTask = nil
        healthTask?.cancel()
        healthTask = nil
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
        assistantStreams.removeAll()
        incompleteAssistantStreams.removeAll()
        streamingBuffers.removeAll()
        syncState = "unknown"
        lastOnlineHeadProbe = .distantPast
        webProjects.removeAll()
        projectConversationsByAlias.removeAll()
        projectNextCursorByAlias.removeAll()
        projectHasMoreByAlias.removeAll()
        webProjectsSnapshotState = nil
        projectConversationSnapshotStateByAlias.removeAll()
        projectConversationLoadingByAlias.removeAll()
        liveRunStatusBySession.removeAll()
        terminalWebRuns.removeAll()
        liveRunActivityAtBySession.removeAll()
        webProviderIssuesBySession.removeAll()
        webProviderSurfaceStateBySession.removeAll()
        webProviderSurfaceObservedAtBySession.removeAll()
        webProviderRecoveryObservedAtBySession.removeAll()
        webProviderStatusReceivedAtBySession.removeAll()
        webBindingDetachedSessions.removeAll()
        webProjectsSnapshotId = nil
        projectConversationSnapshotIds.removeAll()
        lastWebProjectsRefreshAt = nil
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
        for entry in stopTasksBySession.values { entry.task.cancel() }
        stopTasksBySession.removeAll()
        commandSendsInFlight.removeAll()
        metadataRefreshInFlight = false
        metadataRefreshQueued = false
        webProjectsRevision &+= 1
        projectConversationRevisions.removeAll()
        sessionRevisions.removeAll()
        stopEventRevisionsBySession.removeAll()
        stopRunStartSequenceBySession.removeAll()
        stopRunGenerationKeyBySession.removeAll()

        let config = RemoteAIConfig(relayBaseURL: baseURL, machineId: result.machineId)
        config.saveMetadata()
        transport = CloudflareTransport(config: config)
        machine = MachineMetadata(id: result.machineId, name: machine.name, state: .connecting)
        isPaired = true
        errors["connection"] = nil

        // The normal transport may start only after the dedicated pairing socket has
        // completed and returned. Clear the gate before calling start(); otherwise
        // start() intentionally refuses to create a competing same-device websocket.
        pairingInProgress = false
        while startInProgress {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let authenticated = await start { [weak self] stage in
            self?.pairingStage = stage
        }
        guard authenticated else {
            throw TransportError.remote("PAIR_CONNECTED_BUT_OFFLINE", errors["connection"] ?? "Pairing succeeded, but the Windows service did not complete an authenticated connection.")
        }
        if machine.state != .online {
            DiagnosticsLog.shared.record("pairing_authenticated_reconnect_pending", fields: [
                "state": machine.state.rawValue,
                "phase": connectionPhase.rawValue,
            ], level: "WARN")
        }
        pairingStage = .completed
    }

    func draft(sessionId: String) async -> String { (try? await cache.draft(sessionId: sessionId)) ?? "" }
    func saveDraft(_ text: String, sessionId: String) async { try? await cache.saveDraft(text, sessionId: sessionId) }
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

    private static func isUnknownWebSendOutcome(_ error: TransportError, runtimeId: String) -> Bool {
        guard case .remote(let code, let message) = error else { return false }
        if code == "WEB_SEND_DELIVERY_UNKNOWN" { return true }
        // Compatibility with the running pre-fix Windows Agent. Its Chrome async
        // listener can close after the provider accepted Send. The exact Chrome
        // signature is ambiguous, so read-only history reconciliation must win
        // over treating it as a definite failure or automatically replaying Send.
        guard runtimeId == "runtime.web", code == "WEB_SELECTOR_FAILED" else { return false }
        return message.range(of: "A listener indicated an asynchronous response by returning true", options: .caseInsensitive) != nil
            && message.range(of: "message channel closed before a response was received", options: .caseInsensitive) != nil
    }

    private func isUnknownDelivery(_ error: Error) -> Bool {
        guard let transportError = error as? TransportError else { return false }
        if transportError == .disconnected || transportError == .timeout { return true }
        if case .remote(let code, _) = transportError {
            return code == "WEB_SEND_DELIVERY_UNKNOWN" || code == "CREATE_SESSION_RESULT_UNVERIFIED"
        }
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

    private func installHealthConsumer() {
        healthTask?.cancel()
        let sourceTransport = transport
        let generation = lifecycleGeneration
        healthTask = Task { [weak self] in
            guard let self else { return }
            let stream = await sourceTransport.healthStream()
            for await event in stream {
                guard !Task.isCancelled,
                      generation == self.lifecycleGeneration,
                      !self.isSuspended,
                      self.transport === sourceTransport else { break }
                self.applyTransportHealth(event)
            }
        }
    }

    private func startConnectionMonitor() {
        connectionMonitorTask?.cancel()
        let monitoredTransport = transport
        let generation = lifecycleGeneration
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.connectionMonitorIntervalNanoseconds)
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
                        let agentStatus = try await monitoredTransport.agentStatusSnapshot(machineId: self.machine.id)
                        let authenticatedSequence = agentStatus.latestSequence
                        self.applyAgentStatusSnapshot(agentStatus)
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else {
                            await monitoredTransport.disconnect()
                            break
                        }
                        self.machine.state = .online
                        self.connectionPhase = .online
                        self.errors["connection"] = nil
                        self.endTransientConnectionPresentation()
                        DiagnosticsLog.shared.record("connection_online", fields: ["sequence": String(authenticatedSequence), "source": "reconnect"])
                        self.scheduleWebProjectsRefreshAfterConnectivityRecovery(reason: "relay-reconnect")
                        // Reconcile the durable event gap before any catalog refresh. A
                        // reconnect must restore the active chat first; project/runtime
                        // metadata is lower priority and may be comparatively slow.
                        await self.recoverDelta(freshLatestSequence: authenticatedSequence)
                        await self.refreshMetadata()
                    } catch {
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else { break }
                        self.applyConnectionFailure(error)
                        if (error as? TransportError) == .pairingRequired { break }
                    }
                } else if self.machine.state != .online {
                    // The phone can remain connected to Relay while the Windows Agent
                    // reconnects. When Relay announces agent-online, authenticate over
                    // the retained socket instead of needlessly reopening WebSocket.
                    do {
                        self.connectionPhase = .authenticating
                        let agentStatus = try await monitoredTransport.agentStatusSnapshot(machineId: self.machine.id)
                        let authenticatedSequence = agentStatus.latestSequence
                        self.applyAgentStatusSnapshot(agentStatus)
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else { break }
                        self.machine.state = .online
                        self.connectionPhase = .online
                        self.errors["connection"] = nil
                        self.endTransientConnectionPresentation()
                        DiagnosticsLog.shared.record("connection_online", fields: ["sequence": String(authenticatedSequence), "source": "agent-recovered"])
                        self.scheduleWebProjectsRefreshAfterConnectivityRecovery(reason: "agent-recovered")
                        await self.recoverDelta(freshLatestSequence: authenticatedSequence)
                        await self.refreshMetadata()
                    } catch {
                        guard generation == self.lifecycleGeneration,
                              !self.isSuspended,
                              self.transport === monitoredTransport else { break }
                        self.applyConnectionFailure(error)
                        if (error as? TransportError) == .pairingRequired { break }
                    }
                } else if self.machine.state == .online && Date().timeIntervalSince(self.lastOnlineHeadProbe) >= 15 {
                    await self.verifyOnlineSyncHead()
                }
            }
        }
    }

    private func applyConnectionFailure(_ error: Error) {
        syncState = "unknown"
        machine.state = .offline
        DiagnosticsLog.shared.record("connection_failure", fields: Self.diagnosticFields(for: error), level: "ERROR")
        if let transportError = error as? TransportError {
            switch transportError {
            case .pairingRequired:
                endTransientConnectionPresentation()
                isPaired = false
                connectionPhase = .pairingExpired
                errors["connection"] = "Pairing expired / Repair required — scan the current Windows pairing QR code."
                connectionMonitorTask?.cancel()
                connectionMonitorTask = nil
            case .offline:
                desktopAgentConnected = false
                connectionPhase = .windowsOffline
                errors["connection"] = "Windows Agent offline — Relay is reachable but the RemoteAI Agent is not online."
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
            let orderInstances: (InstanceDescriptor, InstanceDescriptor) -> Bool = { lhs, rhs in
                if lhs.runtimeId == rhs.runtimeId { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.runtimeId < rhs.runtimeId
            }
            let currentRows = instances.filter { $0.runtimeId == runtime.id }
            let remoteRows = rows.sorted(by: orderInstances)
            if currentRows != remoteRows {
                var merged = instances.filter { $0.runtimeId != runtime.id }
                merged.append(contentsOf: remoteRows)
                merged.sort(by: orderInstances)
                instances = merged
                await persistMetadata()
            }
            // Instance discovery stays cheap. Session history is loaded only after the
            // user opens one instance, otherwise Codex1...Codex11 would all scan their
            // JSONL stores just to render this list.
            if errors["runtime.\(runtime.id)"] != nil { errors["runtime.\(runtime.id)"] = nil }
        } catch {
            if generation == lifecycleGeneration, !isSuspended { errors["runtime.\(runtime.id)"] = error.localizedDescription }
        }
    }

    private func requestMetadataRefresh() async {
        if deltaRecoveryInFlight {
            metadataRefreshDeferredForDelta = true
            return
        }
        await refreshMetadata()
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
            if !remoteRuntimes.isEmpty, runtimes != remoteRuntimes {
                runtimes = remoteRuntimes
                await persistMetadata()
            }
            // Runtime instance discovery is intentionally lazy. Each RuntimeView
            // refreshes only the selected runtime, which keeps app launch and
            // reconnects from scanning every Codex workspace.
            if errors["sync"] != nil { errors["sync"] = nil }
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

    private func routeForSession(_ sessionId: String) -> (runtimeId: String, instanceId: String)? {
        if let context = contextForSession(sessionId) {
            return (context.runtime.id, context.instance.id)
        }
        guard let hint = sessionRouteHints[sessionId], hint.machineId == machine.id else { return nil }
        return (hint.runtimeId, hint.instanceId)
    }

    private func hydrateSessionDescriptorIfNeeded(
        sessionId: String,
        route: (runtimeId: String, instanceId: String),
        generation: UInt64
    ) async {
        guard !sessions.contains(where: { $0.id == sessionId }),
              machine.state == .online,
              generation == lifecycleGeneration,
              !isSuspended else { return }
        do {
            let remote = try await transport.listSessions(machineId: machine.id, runtimeId: route.runtimeId, instanceId: route.instanceId)
            guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
            if let resolved = remote.first(where: { $0.id == sessionId }),
               !sessions.contains(where: { $0.id == sessionId }) {
                sessions.append(resolved)
                sortSessionsCanonical()
                await persistMetadata()
            }
        } catch {
            // The route hint is still sufficient for a read-only message fetch. Do not
            // fail loadSession merely because the lazy session catalog refresh failed.
        }
    }

    private func ensureSessionDescriptorExists(sessionId: String, instanceId: String, updatedAt: Date) {
        guard !sessions.contains(where: { $0.id == sessionId }) else { return }
        sessions.append(SessionDescriptor(
            id: sessionId,
            instanceId: instanceId,
            title: "ChatGPT Conversation",
            state: .idle,
            updatedAt: updatedAt,
            lastActivityAt: updatedAt
        ))
        sortSessionsCanonical()
    }

    private static func sessionOrdersBefore(_ lhs: SessionDescriptor, _ rhs: SessionDescriptor) -> Bool {
        if lhs.orderingDate != rhs.orderingDate { return lhs.orderingDate > rhs.orderingDate }
        return lhs.id < rhs.id
    }

    private func sortSessionsCanonical() {
        sessions.sort(by: Self.sessionOrdersBefore)
    }

    private func markSessionActivity(_ sessionId: String, at: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if let current = sessions[index].lastActivityAt, current >= at { return }
        var updated = sessions[index]
        updated.lastActivityAt = at
        // Activity can only move this one session toward the front. Usually the
        // streaming session is already first; a full catalog sort adds no value.
        if index == 0 || sessions[index - 1].orderingDate >= updated.orderingDate {
            sessions[index] = updated
        } else {
            var reordered = sessions
            reordered.remove(at: index)
            let destination = reordered.firstIndex { $0.orderingDate < updated.orderingDate } ?? reordered.endIndex
            reordered.insert(updated, at: destination)
            sessions = reordered
        }
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
            // Render the last verified Project list immediately on cold launch. It is
            // still explicitly stale until refreshWebProjects() replaces it with live
            // DOM truth, but the user should never stare at an empty Projects surface
            // while Relay/Browser connectivity is being restored.
            webProjectsSnapshotState = .staleCache
            hasLoadedWebProjects = !value.isEmpty
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
    private func mergeConversationPartialHead(_ incoming: [WebConversationDescriptor], projectAlias: String) -> Bool {
        guard let current = projectConversationsByAlias[projectAlias], !current.isEmpty else { return false }
        let currentAliases = Set(current.compactMap(\.conversationAlias))
        guard !currentAliases.isEmpty else { return false }
        let validIncoming = incoming.filter { sameWebProjectAlias($0.projectAlias, projectAlias) && $0.conversationAlias != nil }
        guard let firstKnownIndex = validIncoming.firstIndex(where: { row in
            row.conversationAlias.map(currentAliases.contains) ?? false
        }), firstKnownIndex > 0 else { return false }

        var seenAliases = currentAliases
        var safeHead: [WebConversationDescriptor] = []
        for row in validIncoming[..<firstKnownIndex] {
            guard let alias = row.conversationAlias, !seenAliases.contains(alias) else { continue }
            seenAliases.insert(alias)
            safeHead.append(row)
        }
        guard !safeHead.isEmpty else { return false }

        let safeAliases = Set(safeHead.compactMap(\.conversationAlias))
        let merged = safeHead + current.filter { row in
            guard let alias = row.conversationAlias else { return true }
            return !safeAliases.contains(alias)
        }
        projectConversationsByAlias[projectAlias] = merged
        return true
    }

    @discardableResult
    private func mergeConversationVerifiedStaleHead(_ incoming: [WebConversationDescriptor], projectAlias: String) -> Bool {
        guard let current = projectConversationsByAlias[projectAlias], !current.isEmpty else { return false }
        let currentAliases = Set(current.compactMap(\.conversationAlias))
        guard !currentAliases.isEmpty else { return false }
        let validIncoming = incoming.filter { sameWebProjectAlias($0.projectAlias, projectAlias) && $0.conversationAlias != nil }
        guard let firstKnownIndex = validIncoming.firstIndex(where: { row in
            row.conversationAlias.map(currentAliases.contains) ?? false
        }), firstKnownIndex > 0 else { return false }

        var seenAliases = currentAliases
        var verifiedHead: [WebConversationDescriptor] = []
        for row in validIncoming[..<firstKnownIndex] {
            guard let alias = row.conversationAlias, !seenAliases.contains(alias) else { continue }
            seenAliases.insert(alias)
            verifiedHead.append(row)
        }
        guard !verifiedHead.isEmpty else { return false }

        let headAliases = Set(verifiedHead.compactMap(\.conversationAlias))
        projectConversationsByAlias[projectAlias] = verifiedHead + current.filter { row in
            guard let alias = row.conversationAlias else { return true }
            return !headAliases.contains(alias)
        }
        return true
    }

    /// Add positive membership evidence from a complete/stable Windows cache without
    /// granting stale data deletion or reorder authority. Existing phone rows keep their
    /// relative order; missing verified rows are inserted beside the closest stale-order
    /// anchor when possible, otherwise appended. Rows without a stable conversation alias
    /// are placeholders and never expand the phone catalog.
    @discardableResult
    private func mergeConversationVerifiedStaleCatalog(_ incoming: [WebConversationDescriptor], projectAlias: String) -> Int {
        guard var current = projectConversationsByAlias[projectAlias], !current.isEmpty else { return 0 }
        let validIncoming = incoming.filter { sameWebProjectAlias($0.projectAlias, projectAlias) && $0.conversationAlias != nil }
        guard !validIncoming.isEmpty else { return 0 }

        var knownAliases = Set(current.compactMap(\.conversationAlias))
        var added = 0

        for incomingIndex in validIncoming.indices {
            let row = validIncoming[incomingIndex]
            guard let alias = row.conversationAlias, !knownAliases.contains(alias) else { continue }

            var insertionIndex: Int?
            if incomingIndex > validIncoming.startIndex {
                var priorIndex = validIncoming.index(before: incomingIndex)
                while true {
                    if let priorAlias = validIncoming[priorIndex].conversationAlias,
                       let currentIndex = current.firstIndex(where: { $0.conversationAlias == priorAlias }) {
                        insertionIndex = current.index(after: currentIndex)
                        break
                    }
                    if priorIndex == validIncoming.startIndex { break }
                    priorIndex = validIncoming.index(before: priorIndex)
                }
            }

            if insertionIndex == nil {
                var nextIndex = validIncoming.index(after: incomingIndex)
                while nextIndex < validIncoming.endIndex {
                    if let nextAlias = validIncoming[nextIndex].conversationAlias,
                       let currentIndex = current.firstIndex(where: { $0.conversationAlias == nextAlias }) {
                        insertionIndex = currentIndex
                        break
                    }
                    nextIndex = validIncoming.index(after: nextIndex)
                }
            }

            current.insert(row, at: insertionIndex ?? current.endIndex)
            knownAliases.insert(alias)
            added += 1
        }

        if added > 0 { projectConversationsByAlias[projectAlias] = current }
        return added
    }

    @discardableResult
    private func mergeConversationTitleHints(_ hints: [WebConversationDescriptor], projectAlias: String) -> Bool {
        guard var current = projectConversationsByAlias[projectAlias], !current.isEmpty else { return false }
        let byAlias = Dictionary(uniqueKeysWithValues: hints.compactMap { hint -> (String, WebConversationDescriptor)? in
            guard let alias = hint.conversationAlias, sameWebProjectAlias(hint.projectAlias, projectAlias) else { return nil }
            return (alias, hint)
        })
        var changed = false
        for index in current.indices {
            guard let alias = current[index].conversationAlias,
                  let hint = byAlias[alias],
                  !isSyntheticConversationTitle(hint.displayTitle, conversationAlias: alias) else { continue }
            let prior = current[index]
            // A verified Windows stale catalog may carry fresher title metadata for the
            // exact same conversation even while its membership/order snapshot cannot
            // safely replace the phone's accepted Project list. Do not freeze an older
            // non-placeholder title (for example "test") across cold starts. Accept a
            // different provider-backed title only when it is at least as recent as the
            // cached row; placeholder titles remain repairable regardless of timestamp.
            let shouldRepairTitle = isSyntheticConversationTitle(prior.displayTitle, conversationAlias: alias)
                || (hint.displayTitle != prior.displayTitle && hint.updatedAt >= prior.updatedAt)
            guard shouldRepairTitle else { continue }
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
            var session = item.session
            // Project discovery itself proves that this conversation belongs to the
            // ChatGPT Web runtime. Instance catalog loading is intentionally lazy, so
            // remember the route here instead of requiring listInstances to have run
            // before status/history reconciliation can recover a desktop-only run.
            sessionRouteHints[session.id] = (machine.id, "runtime.web", session.instanceId)
            if let existing = sessions.first(where: { $0.id == session.id }) {
                // Project discovery is a navigation snapshot, not a run-state authority.
                // Do not let a sidebar refresh erase a live busy/error state or a newer
                // process timestamp that arrived through the event stream.
                session.state = existing.state
                let existingActivity = existing.lastActivityAt ?? existing.updatedAt
                let incomingActivity = session.lastActivityAt ?? session.updatedAt
                session.lastActivityAt = max(existingActivity, incomingActivity)
                if session.lastProgressStatus == nil { session.lastProgressStatus = existing.lastProgressStatus }
                if session.lastProgressAt == nil { session.lastProgressAt = existing.lastProgressAt }
            }
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
        }
        sortSessionsCanonical()
    }

    private func normalizedWebConversationAlias(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // ChatGPT can expose the same transient conversation identity both as
        // "local-chatgpt%3A..." and "local-chatgpt:...". URL/path decoding differs
        // depending on where the identity came from, so string equality alone can
        // render one provider chat multiple times. Decode repeatedly but boundedly,
        // then compare through one canonical case-insensitive identity.
        var value = trimmed
        for _ in 0..<2 {
            guard let decoded = value.removingPercentEncoding, decoded != value else { break }
            value = decoded
        }
        return value.lowercased()
    }

    private func isProvisionalWebConversationAlias(_ raw: String?) -> Bool {
        guard let value = normalizedWebConversationAlias(raw) else { return false }
        return value.hasPrefix("web:") || value.hasPrefix("local-chatgpt:")
    }

    private func webConversationAlias(from canonicalURL: String?) -> String? {
        guard let canonicalURL,
              let url = URL(string: canonicalURL) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let marker = parts.lastIndex(of: "c"),
              parts.indices.contains(marker + 1) else { return nil }
        return normalizedWebConversationAlias(parts[marker + 1])
    }

    private func webProjectBaseId(from alias: String?) -> String? {
        guard let alias else { return nil }
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("g-p-"), value.count >= 36 else { return nil }
        let end = value.index(value.startIndex, offsetBy: 36)
        let prefix = String(value[..<end])
        let hex = prefix.dropFirst(4)
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if value.count > 36 {
            guard value[value.index(value.startIndex, offsetBy: 36)] == "-" else { return nil }
        }
        return String(hex)
    }

    private func sameWebProjectAlias(_ left: String?, _ right: String?) -> Bool {
        if left == right { return true }
        guard let leftBase = webProjectBaseId(from: left),
              let rightBase = webProjectBaseId(from: right) else { return false }
        return leftBase == rightBase
    }

    private func webConversationIdentity(
        localConversationId: String,
        conversationAlias: String?,
        canonicalURL: String?
    ) -> String {
        if let alias = normalizedWebConversationAlias(conversationAlias)
            ?? webConversationAlias(from: canonicalURL) {
            return "alias:\(alias)"
        }
        return "local:\(localConversationId.lowercased())"
    }

    private func webConversationIdentity(_ row: WebConversationDescriptor) -> String {
        webConversationIdentity(
            localConversationId: row.localConversationId,
            conversationAlias: row.conversationAlias,
            canonicalURL: row.canonicalUrl
        )
    }

    /// The complete ChatGPT sidebar snapshot owns membership and pagination, while
    /// durable Windows/phone activity owns the visible recent-activity head. Keep those
    /// authorities separate so reordering never truncates a large Project.
    func displayedProjectConversations(projectAlias: String) -> [WebConversationDescriptor] {
        let providerRows = projectConversationsByAlias[projectAlias, default: []].filter { row in
            let provisional = isProvisionalWebConversationAlias(row.conversationAlias)
                || isProvisionalWebConversationAlias(webConversationAlias(from: row.canonicalUrl))
            guard provisional else { return true }
            // Build 38 caches can contain detached local-chatgpt:/WEB: rows created
            // before provider ID promotion. They are not durable conversations. Keep a
            // provisional row visible only while an exact matching session is actively
            // running; otherwise hide it immediately, even before the live refresh.
            let rowAlias = normalizedWebConversationAlias(row.conversationAlias)
                ?? webConversationAlias(from: row.canonicalUrl)
            return sessions.contains { session in
                guard session.state == .busy || session.state == .waiting else { return false }
                if session.id == row.localConversationId { return true }
                guard sameWebProjectAlias(session.projectAlias, projectAlias), let rowAlias else { return false }
                return webConversationAlias(from: session.canonicalUrl) == rowAlias
            }
        }
        // Do not construct a unique-key Dictionary here. Historical provider snapshots
        // can legitimately contain two local IDs for the same ChatGPT conversation
        // identity during a SPA/local->provider ID transition.
        let providerById = providerRows.reduce(into: [String: WebConversationDescriptor]()) {
            if $0[$1.localConversationId] == nil { $0[$1.localConversationId] = $1 }
        }

        var activityRows: [(descriptor: WebConversationDescriptor, activityAt: Date)] = []
        var promotedIds = Set<String>()
        var promotedAliases = Set<String>()

        for session in sessions where sameWebProjectAlias(session.projectAlias, projectAlias) {
            guard let canonicalURL = session.canonicalUrl, !canonicalURL.isEmpty else { continue }
            let sessionAlias = webConversationAlias(from: canonicalURL)
            let active = session.state == .busy || session.state == .waiting
            if isProvisionalWebConversationAlias(sessionAlias), !active { continue }
            let prior = providerById[session.id]
                ?? providerRows.first(where: {
                    guard let sessionAlias else { return false }
                    return normalizedWebConversationAlias($0.conversationAlias) == sessionAlias
                        || webConversationAlias(from: $0.canonicalUrl) == sessionAlias
                })
            let activityAt = session.lastActivityAt ?? session.updatedAt

            if let prior {
                guard active || activityAt > prior.updatedAt else { continue }
                let title = isSyntheticConversationTitle(prior.displayTitle, conversationAlias: prior.conversationAlias)
                    && !isSyntheticConversationTitle(session.title, conversationAlias: sessionAlias)
                    ? session.title
                    : prior.displayTitle
                let row = WebConversationDescriptor(
                    localConversationId: prior.localConversationId,
                    canonicalUrl: canonicalURL,
                    projectId: prior.projectId,
                    displayTitle: title,
                    projectAlias: prior.projectAlias,
                    conversationAlias: prior.conversationAlias ?? sessionAlias,
                    lastVisited: max(prior.lastVisited ?? prior.updatedAt, activityAt),
                    updatedAt: max(prior.updatedAt, activityAt)
                )
                activityRows.append((row, activityAt))
                promotedIds.insert(prior.localConversationId)
                if let alias = normalizedWebConversationAlias(row.conversationAlias)
                    ?? webConversationAlias(from: row.canonicalUrl) {
                    promotedAliases.insert(alias)
                }
                continue
            }

            // A desktop Chat can start running before ChatGPT lazily mounts its sidebar
            // row. Session identity is enough to show it immediately without changing
            // the complete provider-backed list or its pagination state.
            let row = WebConversationDescriptor(
                localConversationId: session.id,
                canonicalUrl: canonicalURL,
                projectId: webProjects.first(where: { sameWebProjectAlias($0.projectAlias, projectAlias) })?.projectId,
                displayTitle: session.title,
                projectAlias: projectAlias,
                conversationAlias: sessionAlias,
                lastVisited: activityAt,
                updatedAt: activityAt
            )
            activityRows.append((row, activityAt))
            promotedIds.insert(session.id)
            if let alias = sessionAlias { promotedAliases.insert(alias) }
        }

        activityRows.sort { lhs, rhs in
            if lhs.activityAt == rhs.activityAt {
                return lhs.descriptor.localConversationId < rhs.descriptor.localConversationId
            }
            return lhs.activityAt > rhs.activityAt
        }

        let providerTail = providerRows.filter { row in
            if promotedIds.contains(row.localConversationId) { return false }
            if let alias = normalizedWebConversationAlias(row.conversationAlias)
                ?? webConversationAlias(from: row.canonicalUrl),
               promotedAliases.contains(alias) {
                return false
            }
            return true
        }

        // Final presentation-level identity collapse. This intentionally leaves the
        // provider backing snapshot untouched (pagination/order authority), but prevents
        // one chat from rendering several times when Windows and ChatGPT temporarily
        // disagree about localConversationId or percent-encoded conversationAlias.
        var seen = Set<String>()
        return (activityRows.map { $0.descriptor } + providerTail).filter { row in
            seen.insert(webConversationIdentity(row)).inserted
        }
    }

    @discardableResult
    private func reconcileProjectConversationActivityFromSessions(_ remote: [SessionDescriptor]) -> Set<String> {
        let projectSessions = remote.filter {
            $0.projectAlias?.isEmpty == false
                && $0.canonicalUrl?.isEmpty == false
        }
        guard !projectSessions.isEmpty else { return [] }

        var changedAliases = Set<String>()
        let grouped = Dictionary(grouping: projectSessions) { session -> String in
            let rawAlias = session.projectAlias!
            return projectConversationsByAlias.keys.first(where: { sameWebProjectAlias($0, rawAlias) })
                ?? webProjects.first(where: { sameWebProjectAlias($0.projectAlias, rawAlias) })?.projectAlias
                ?? rawAlias
        }

        for (projectAlias, sessionsForProject) in grouped {
            guard projectConversationsByAlias[projectAlias] != nil else { continue }
            var rows = projectConversationsByAlias[projectAlias, default: []]
            var changed = false

            for session in sessionsForProject {
                let sessionAlias = webConversationAlias(from: session.canonicalUrl)
                guard let index = rows.firstIndex(where: { row in
                    row.localConversationId == session.id
                        || (sessionAlias != nil
                            && (normalizedWebConversationAlias(row.conversationAlias) == sessionAlias
                                || webConversationAlias(from: row.canonicalUrl) == sessionAlias))
                }) else {
                    // Missing active rows are exposed by displayedProjectConversations.
                    // Do not mutate the provider-ordered backing snapshot merely because
                    // Agent activity arrived before ChatGPT mounted that sidebar row.
                    continue
                }

                let prior = rows[index]
                let repairedTitle = isSyntheticConversationTitle(prior.displayTitle, conversationAlias: prior.conversationAlias)
                    && !isSyntheticConversationTitle(session.title, conversationAlias: sessionAlias)
                    ? session.title
                    : prior.displayTitle
                let repairedCanonicalURL = session.canonicalUrl ?? prior.canonicalUrl
                let repairedAlias = prior.conversationAlias ?? sessionAlias

                guard repairedTitle != prior.displayTitle
                        || repairedCanonicalURL != prior.canonicalUrl
                        || repairedAlias != prior.conversationAlias else { continue }

                rows[index] = WebConversationDescriptor(
                    localConversationId: prior.localConversationId,
                    canonicalUrl: repairedCanonicalURL,
                    projectId: prior.projectId,
                    displayTitle: repairedTitle,
                    projectAlias: prior.projectAlias,
                    conversationAlias: repairedAlias,
                    lastVisited: prior.lastVisited,
                    updatedAt: prior.updatedAt
                )
                changed = true
            }

            guard changed else { continue }
            // Metadata repair is allowed in place; row position, snapshot identity,
            // pagination and hasMore remain owned by the ChatGPT sidebar snapshot.
            projectConversationsByAlias[projectAlias] = rows
            changedAliases.insert(projectAlias)
        }

        return changedAliases
    }

    private func promoteProjectConversationActivity(sessionId: String, at: Date) {
        // Activity is presented by displayedProjectConversations without mutating the
        // complete provider snapshot. Coalesce live activity into one bounded sidebar
        // refresh so provider membership/title metadata can still converge.
        let projectAlias = sessions.first(where: { $0.id == sessionId })?.projectAlias
            ?? projectConversationsByAlias.first(where: { _, rows in rows.contains(where: { $0.localConversationId == sessionId }) })?.key
        guard let projectAlias else { return }
        if let lastRefresh = projectConversationActivityRefreshLastAt[projectAlias],
           Date().timeIntervalSince(lastRefresh) < Self.projectConversationAutomaticRefreshMinimumInterval {
            return
        }
        guard projectConversationActivityRefreshScheduled.insert(projectAlias).inserted else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            defer { self.projectConversationActivityRefreshScheduled.remove(projectAlias) }
            guard !self.isSuspended, self.machine.state == .online else { return }
            self.projectConversationActivityRefreshLastAt[projectAlias] = Date()
            await self.loadProjectConversations(projectAlias: projectAlias, refresh: true, force: true)
        }
        _ = at
    }

    private func applyWebPageRegistrationEvent(
        _ event: RemoteEvent,
        sessionId: String,
        suppressPresentation: Bool
    ) async {
        guard event.runtimeId == "runtime.web",
              let projectAlias = event.payload["projectAlias"]?.stringValue,
              !projectAlias.isEmpty,
              let canonicalUrl = event.payload["canonicalUrl"]?.stringValue,
              !canonicalUrl.isEmpty else { return }

        let localConversationId = event.payload["localConversationId"]?.stringValue ?? sessionId
        let conversationAlias = event.payload["conversationAlias"]?.stringValue
        let title = event.payload["displayTitle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? sessions.first(where: { $0.id == localConversationId })?.title
            ?? "ChatGPT Conversation"

        if let index = sessions.firstIndex(where: { $0.id == localConversationId }) {
            var session = sessions[index]
            session.title = effectiveTitle
            session.projectAlias = projectAlias
            session.canonicalUrl = canonicalUrl
            // Registration proves identity/binding, not new transcript content. Keep
            // the established ordering timestamp for an already-known conversation.
            sessions[index] = session
        } else {
            sessions.append(SessionDescriptor(
                id: localConversationId,
                instanceId: event.instanceId,
                title: effectiveTitle,
                state: .idle,
                updatedAt: event.createdAt,
                projectAlias: projectAlias,
                canonicalUrl: canonicalUrl,
                lastActivityAt: nil
            ))
            sortSessionsCanonical()
        }

        var rows = projectConversationsByAlias[projectAlias, default: []]
        let existingIndex = rows.firstIndex(where: {
            $0.localConversationId == localConversationId
                || (conversationAlias != nil && $0.conversationAlias == conversationAlias)
        })
        let prior = existingIndex.map { rows[$0] }
        let row = WebConversationDescriptor(
            localConversationId: localConversationId,
            canonicalUrl: canonicalUrl,
            projectId: prior?.projectId,
            displayTitle: effectiveTitle,
            projectAlias: projectAlias,
            conversationAlias: conversationAlias ?? prior?.conversationAlias,
            lastVisited: prior?.lastVisited ?? event.createdAt,
            updatedAt: prior?.updatedAt ?? event.createdAt
        )

        if let existingIndex {
            // Registration of an already-known tab is metadata evidence, not ordering
            // evidence. Keep the exact provider position and repair only row metadata.
            rows[existingIndex] = row
            projectConversationsByAlias[projectAlias] = rows
        } else {
            // Registration proves identity but not the ChatGPT sidebar position. Keep it
            // in the session catalog; once the run becomes Busy/Waiting the Project view
            // overlays it immediately. Ask for a fresh sidebar snapshot so the durable
            // backing array converges to ChatGPT's real order instead of inventing one.
            if projectConversationRefreshes.contains(projectAlias) {
                projectConversationRefreshQueued.insert(projectAlias)
            } else if !suppressPresentation, machine.state == .online {
                Task { @MainActor [weak self] in
                    await self?.loadProjectConversations(projectAlias: projectAlias, refresh: true, force: true)
                }
            }
        }

        if !suppressPresentation {
            if existingIndex != nil {
                try? await cache.put(projectConversationsByAlias[projectAlias] ?? [], key: "web.project.\(projectAlias).conversations")
            }
            await persistMetadata()
        }
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
        let decision = tracker.decision(for: event.sequence)
        if decision.duplicate { return }
        if decision.gap {
            await recoverDelta()
            return
        }
        guard eventReplayGuard.accept(event.eventId.uuidString.lowercased()) else {
            errors["sync"] = TransportError.replayDetected.localizedDescription
            return
        }
        tracker.advanceMonotonically(to: event.sequence)
        await applyEvent(event)
        if let sessionId = event.sessionId,
           ["MESSAGE_ADDED", "MESSAGE_UPDATED", "MESSAGE_REMOVED", "SESSION_DELETED"].contains(event.type) {
            releaseRecoveryDisplaySnapshot(for: sessionId)
        }
        try? await cache.setLastSequence(event.sequence)
    }

    // An open socket proves transport health, not that the final event arrived.
    // Reuse the authenticated status/cursor path even during otherwise quiet periods.
    func verifyOnlineSyncHead() async {
        let generation = lifecycleGeneration
        let activeTransport = transport
        guard !isSuspended, machine.state == .online, !deltaRecoveryInFlight else { return }
        lastOnlineHeadProbe = Date()
        let appliedBeforeProbe = (try? await cache.lastSequence()) ?? 0
        do {
            let head = try await activeTransport.latestSequence(machineId: machine.id)
            guard generation == lifecycleGeneration, transport === activeTransport, !isSuspended else { return }
            let applied = (try? await cache.lastSequence()) ?? 0
            if head > applied || head < appliedBeforeProbe {
                if syncState != "stale" { syncState = "stale" }
                DiagnosticsLog.shared.record("online_sync_gap", fields: ["head": String(head), "applied": String(applied)])
                await recoverDelta(freshLatestSequence: head)
            }
            let current = (try? await cache.lastSequence()) ?? 0
            for event in Array(incompleteAssistantStreams.values) { _ = await restoreAssistantStream(through: event) }
            let nextSyncState = current >= head && errors["sync"] == nil && incompleteAssistantStreams.isEmpty ? "synced" : "stale"
            if syncState != nextSyncState { syncState = nextSyncState }

            // A websocket cursor can be fully caught up even when the browser observer
            // missed one terminal Web event. Reconcile a bounded set of still-Busy Web
            // sessions through the Agent's authoritative bound-tab status probe so a
            // Project row cannot remain BUSY forever after desktop ChatGPT is already idle.
            let busyWebSessions = sessions.filter { session in
                guard session.state == .busy || session.state == .waiting,
                      let route = routeForSession(session.id) else { return false }
                return route.runtimeId == "runtime.web"
            }.prefix(3)
            for session in busyWebSessions {
                guard generation == lifecycleGeneration, transport === activeTransport, !isSuspended else { return }
                _ = await refreshVisibleSessionStatus(session.id)
            }
        } catch {
            guard generation == lifecycleGeneration, transport === activeTransport, !isSuspended else { return }
            if syncState != "stale" { syncState = "stale" }
            applyConnectionFailure(error)
        }
    }

    private func recoverDelta(freshLatestSequence: Int64? = nil) async {
        guard machine.state == .online else { return }
        if freshLatestSequence == nil,
           let retryNotBefore = deltaRecoveryRetryNotBefore,
           Date() < retryNotBefore {
            return
        }
        if deltaRecoveryInFlight {
            // Event ingestion and the reconnect monitor can both notice the same gap
            // while MainActor is suspended in network I/O. Coalesce them instead of
            // creating parallel getChangesAfterCursor loops. One queued pass runs after
            // the active pass so an event that arrived after its final page is not lost.
            deltaRecoveryQueued = true
            return
        }
        deltaRecoveryInFlight = true
        recoveryLivePresentationSessions.removeAll()
        let generation = lifecycleGeneration
        defer {
            deltaRecoveryInFlight = false
            let shouldRunQueuedRecovery = deltaRecoveryQueued
                && generation == lifecycleGeneration
                && machine.state == .online
                && !isSuspended
            if shouldRunQueuedRecovery {
                deltaRecoveryQueued = false
                Task { [weak self] in await self?.recoverDelta() }
            } else {
                deltaRecoveryQueued = false
                if deltaRecoveryDisplayMessagesBySession != nil {
                    deltaRecoveryDisplayMessagesBySession = nil
                }
                recoveryLivePresentationSessions.removeAll()
                if authoritativeResyncAfterDelta,
                   generation == lifecycleGeneration,
                   machine.state == .online,
                   !isSuspended {
                    let aliases = authoritativeResyncProjectAliases
                    authoritativeResyncAfterDelta = false
                    authoritativeResyncProjectAliases.removeAll()
                    metadataRefreshDeferredForDelta = false
                    Task { @MainActor [weak self] in
                        guard let self,
                              generation == self.lifecycleGeneration,
                              self.machine.state == .online,
                              !self.isSuspended else { return }
                        DiagnosticsLog.shared.record("delta_fast_forward_resync_begin", fields: ["projects": String(aliases.count)])
                        await self.refreshMetadata()
                        await self.refreshWebProjects(force: true)
                        for alias in aliases {
                            guard generation == self.lifecycleGeneration,
                                  self.machine.state == .online,
                                  !self.isSuspended else { return }
                            await self.loadProjectConversations(projectAlias: alias, refresh: true, force: true)
                        }
                        DiagnosticsLog.shared.record("delta_fast_forward_resync_ok", fields: ["projects": String(aliases.count)])
                    }
                } else if metadataRefreshDeferredForDelta,
                          generation == lifecycleGeneration,
                          machine.state == .online,
                          !isSuspended {
                    metadataRefreshDeferredForDelta = false
                    Task { [weak self] in await self?.refreshMetadata() }
                } else {
                    authoritativeResyncAfterDelta = false
                    authoritativeResyncProjectAliases.removeAll()
                    metadataRefreshDeferredForDelta = false
                }
            }
        }

        var cursor = (try? await cache.lastSequence()) ?? 0
        do {
            if let freshLatestSequence, cursor > 0 {
                let lag = freshLatestSequence - cursor
                if lag < 0 || lag > Self.maxHistoricalDeltaReplayEvents {
                    let previousCursor = cursor
                    cursor = max(0, freshLatestSequence)
                    try? await cache.setLastSequence(cursor)
                    tracker.advanceMonotonically(to: cursor)
                    deltaRecoveryFailureCount = 0
                    deltaRecoveryRetryNotBefore = nil
                    // Skipping tens of thousands of historical progress events is correct,
                    // but moving the cursor alone leaves cached Projects/sessions stale.
                    // Force a bounded authoritative rebuild after this recovery pass and
                    // let the currently visible ChatView immediately re-read its history.
                    authoritativeResyncAfterDelta = true
                    authoritativeResyncProjectAliases.formUnion(projectConversationsByAlias.keys)
                    visibleSessionSyncAt.removeAll()
                    visibleSessionHistorySyncAt.removeAll()
                    visibleSessionHistoryRemoteRevision.removeAll()
                    metadataRefreshDeferredForDelta = true
                    DiagnosticsLog.shared.record("delta_recovery_fast_forward", fields: [
                        "cursor": String(previousCursor),
                        "latestSequence": String(freshLatestSequence),
                        "skippedEvents": String(max(0, lag)),
                        "resyncProjects": String(authoritativeResyncProjectAliases.count),
                    ], level: "WARN")
                    return
                }
            }
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
                tracker.advanceMonotonically(to: cursor)
                return
            }
            var deferredPresentationDuringRecovery = false
            while true {
                guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
                let requestedCursor = cursor
                let result = try await transport.delta(machineId: machine.id, after: cursor)
                guard generation == lifecycleGeneration, machine.state == .online, !isSuspended else { return }
                let coalesceHistoricalPresentation = result.events.count >= Self.deltaRecoveryPresentationCoalescingThreshold
                var coalescedSessionPresentation: [String: (active: Bool, status: String?, at: Date)] = [:]
                if !result.events.isEmpty {
                    // Freeze only transcripts touched by this recovery page. Copying the
                    // entire messagesBySession dictionary scales with every Chat already
                    // loaded on the phone even though a delta burst usually belongs to
                    // one active conversation.
                    let affectedSessionIds = Set(result.events.compactMap { $0.sessionId })
                    if coalesceHistoricalPresentation && !affectedSessionIds.isEmpty {
                        var displaySnapshot = deltaRecoveryDisplayMessagesBySession ?? [:]
                        var snapshotChanged = deltaRecoveryDisplayMessagesBySession == nil
                        for sessionId in affectedSessionIds where displaySnapshot[sessionId] == nil && !recoveryLivePresentationSessions.contains(sessionId) {
                            displaySnapshot[sessionId] = messagesBySession[sessionId, default: []]
                            snapshotChanged = true
                        }
                        if snapshotChanged { deltaRecoveryDisplayMessagesBySession = displaySnapshot }
                    }
                    DiagnosticsLog.shared.record("delta_recovery_batch", fields: [
                        "cursor": String(requestedCursor),
                        "count": String(result.events.count),
                        "firstSequence": String(result.events.first?.sequence ?? requestedCursor),
                        "lastSequence": String(result.events.last?.sequence ?? requestedCursor),
                        "presentationCoalesced": String(coalesceHistoricalPresentation),
                    ])
                }
                for event in result.events where event.sequence > cursor {
                    try ProtocolSecurity.validate(event, expectedMachineId: machine.id)
                    let replayKey = event.eventId.uuidString.lowercased()
                    if !eventReplayGuard.accept(replayKey) {
                        // A live websocket event can legitimately arrive while an
                        // authenticated delta request containing that same event is in
                        // flight. Skip only when the sequence tracker proves this event
                        // has already been observed live. Reusing an old event id at a
                        // brand-new sequence remains a hard replay failure.
                        guard event.sequence <= tracker.lastSequence else { throw TransportError.replayDetected }
                        DiagnosticsLog.shared.record("delta_recovery_duplicate_skipped", fields: [
                            "sequence": String(event.sequence),
                            "eventId": replayKey,
                        ])
                        cursor = event.sequence
                        try? await cache.setLastSequence(cursor)
                        continue
                    }
                    tracker.advanceMonotonically(to: event.sequence)
                    // Only old replay progress is presentation-coalesced. A current stream
                    // can be caught inside the same large delta page after a short network
                    // gap; those fresh events must remain visibly live instead of waiting
                    // for the whole recovery pass to finish.
                    let eventAge = max(0, Date().timeIntervalSince(event.createdAt))
                    let suppressEventPresentation = coalesceHistoricalPresentation
                        && eventAge >= Self.deltaRecoveryHistoricalPresentationAge
                    if suppressEventPresentation,
                       event.type == "MESSAGE_UPDATED",
                       event.payload["partial"]?.boolValue != false {
                        deferredPresentationDuringRecovery = true
                    }
                    if let sessionId = event.sessionId {
                        if suppressEventPresentation {
                            switch event.type {
                            case "GENERATION_STARTED":
                                coalescedSessionPresentation[sessionId] = (true, generationStartedLabel(runtimeId: event.runtimeId), event.createdAt)
                            case "MESSAGE_UPDATED" where event.payload["partial"]?.boolValue != false:
                                coalescedSessionPresentation[sessionId] = (true, "正在生成回答…", event.createdAt)
                            case "TOOL_STARTED", "TOOL_FINISHED":
                                if coalescedSessionPresentation[sessionId]?.active != false {
                                    coalescedSessionPresentation[sessionId] = (true, generationStartedLabel(runtimeId: event.runtimeId), event.createdAt)
                                }
                            case "MESSAGE_ADDED" where event.payload["role"]?.stringValue == "assistant":
                                coalescedSessionPresentation[sessionId] = (false, nil, event.createdAt)
                            case "GENERATION_STOPPED" where event.payload["ok"]?.boolValue != false:
                                coalescedSessionPresentation[sessionId] = (false, nil, event.createdAt)
                            default:
                                break
                            }
                        } else if ["GENERATION_STARTED", "MESSAGE_UPDATED", "TOOL_STARTED", "TOOL_FINISHED", "MESSAGE_ADDED", "GENERATION_STOPPED"].contains(event.type) {
                            // A fresh event for this session supersedes any older batched
                            // presentation state captured earlier in the same delta page.
                            coalescedSessionPresentation.removeValue(forKey: sessionId)
                        }
                    }
                    // TRANSPORT_STATUS in getChangesAfterCursor is historical replay evidence,
                    // not current connectivity. Re-applying it makes a healthy phone flash
                    // offline/recovered while catching up. Live websocket/health callbacks are
                    // the only authority allowed to mutate current transport presentation.
                    if event.type != "TRANSPORT_STATUS" {
                        await applyEvent(event, suppressTransientPresentation: suppressEventPresentation)
                        // A durable final may already be a few seconds old after a
                        // disconnect. It still supersedes the frozen display copy;
                        // unrelated sessions' historical pages must not hide it.
                        let durableMessageBoundary = event.type == "MESSAGE_ADDED"
                            || (event.type == "MESSAGE_UPDATED" && event.payload["partial"]?.boolValue == false)
                        if (!suppressEventPresentation || durableMessageBoundary),
                           let sessionId = event.sessionId,
                           ["MESSAGE_ADDED", "MESSAGE_UPDATED", "MESSAGE_REMOVED", "SESSION_DELETED"].contains(event.type) {
                            releaseRecoveryDisplaySnapshot(for: sessionId)
                        }
                    }
                    cursor = event.sequence
                    try? await cache.setLastSequence(cursor)
                }
                if coalesceHistoricalPresentation {
                    for (sessionId, presentation) in coalescedSessionPresentation {
                        markSessionActivity(sessionId, at: presentation.at)
                        if presentation.active {
                            markLiveRunActivity(sessionId: sessionId, at: presentation.at)
                            setSessionState(sessionId, .busy)
                            if routeForSession(sessionId)?.runtimeId == "runtime.web" {
                                // Historical catch-up intentionally coalesces old token
                                // frames, but active-run ordering is not presentation
                                // noise. Preserve the same Project-head promotion that a
                                // live run event would have produced.
                                promoteProjectConversationActivity(sessionId: sessionId, at: presentation.at)
                            }
                            if let status = presentation.status, liveRunStatusBySession[sessionId] != status {
                                liveRunStatusBySession[sessionId] = status
                            }
                        } else if sessions.first(where: { $0.id == sessionId })?.state != .error {
                            setSessionState(sessionId, .idle)
                            if liveRunStatusBySession[sessionId] != nil { liveRunStatusBySession.removeValue(forKey: sessionId) }
                            clearLiveRunActivity(sessionId: sessionId)
                        }
                    }
                }
                cursor = max(cursor, result.nextCursor)
                try? await cache.setLastSequence(cursor)
                if !result.hasMore { break }
            }
            if deferredPresentationDuringRecovery {
                // If the catch-up ended mid-generation, publish only the latest assembled
                // stream tail once. A final MESSAGE_ADDED will already have discarded the
                // transient buffer, so this is a no-op for completed historical runs.
                flushAllStreaming()
            }
            tracker.advanceMonotonically(to: cursor)
            deltaRecoveryFailureCount = 0
            deltaRecoveryRetryNotBefore = nil
            if incompleteAssistantStreams.isEmpty {
                if errors["sync"] != nil { errors.removeValue(forKey: "sync") }
            } else {
                let message = "Streaming reconciliation is incomplete."
                if errors["sync"] != message { errors["sync"] = message }
            }
        } catch {
            if generation == lifecycleGeneration, !isSuspended {
                let index = min(deltaRecoveryFailureCount, Self.deltaRecoveryFailureBackoffSeconds.count - 1)
                let delay = Self.deltaRecoveryFailureBackoffSeconds[index]
                deltaRecoveryFailureCount += 1
                deltaRecoveryRetryNotBefore = Date().addingTimeInterval(delay)
                errors["sync"] = error.localizedDescription
                var fields = Self.diagnosticFields(for: error)
                fields["retryAfterSeconds"] = String(Int(delay))
                DiagnosticsLog.shared.record("delta_recovery_failed", fields: fields, level: "ERROR")
            }
        }
    }

    private func releaseRecoveryDisplaySnapshot(for sessionId: String) {
        guard deltaRecoveryInFlight else { return }
        recoveryLivePresentationSessions.insert(sessionId)
        // The canonical messagesBySession has already been updated by applyEvent.
        // Leaving the earlier copy here hides a real reply until every other
        // session's historical delta pages have completed.
        if deltaRecoveryDisplayMessagesBySession?[sessionId] != nil {
            deltaRecoveryDisplayMessagesBySession?.removeValue(forKey: sessionId)
        }
    }

    private func applyEvent(_ event: RemoteEvent, suppressTransientPresentation: Bool = false) async {
        if event.type == "TRANSPORT_STATUS" {
            // Historical delta recovery can contain many old Relay/Browser status
            // transitions. Replaying them into live transport state makes the phone
            // oscillate offline/online even though the current socket is healthy.
            if !suppressTransientPresentation { applyTransportStatusEvent(event) }
            return
        }
        guard let sessionId = event.sessionId else {
            if ["INSTANCE_UPDATED", "RUNTIME_STATUS", "SESSION_CREATED", "SESSION_UPDATED", "SESSION_RENAMED", "SESSION_STATUS", "WEB_PAGE_REGISTERED", "WEB_PAGE_UNREGISTERED"].contains(event.type) {
                await requestMetadataRefresh()
            }
            return
        }

        let runEventTypes = ["MESSAGE_UPDATED", "MESSAGE_ADDED", "TOOL_STARTED", "TOOL_FINISHED", "GENERATION_STARTED", "GENERATION_STOPPED"]
        let sessionCatalogMutatingEventTypes = Set(runEventTypes + [
            "SESSION_CREATED", "SESSION_UPDATED", "SESSION_RENAMED", "SESSION_STATUS", "SESSION_DELETED",
            "WEB_PAGE_REGISTERED", "WEB_PAGE_UNREGISTERED", "WEB_BINDING_CHANGED", "MESSAGE_REMOVED",
        ])
        if sessionCatalogMutatingEventTypes.contains(event.type) {
            // A listSessions request that started before this live event is stale by
            // definition. Without bumping the revision, its late response can delete a
            // newly registered desktop Chat or roll Busy/lastActivityAt back to idle.
            sessionRevisions[event.instanceId, default: 0] &+= 1
            stopEventRevisionsBySession[sessionId, default: 0] &+= 1
            if event.type == "GENERATION_STARTED" {
                stopRunStartSequenceBySession[sessionId] = event.sequence
                if let generationKey = event.payload["generationKey"]?.stringValue,
                   !generationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    stopRunGenerationKeyBySession[sessionId] = generationKey
                } else {
                    stopRunGenerationKeyBySession.removeValue(forKey: sessionId)
                }
            }
        }

        sessionRouteHints[sessionId] = (event.machineId, event.runtimeId, event.instanceId)
        if event.type == "WEB_BINDING_CHANGED"
            || (event.type == "SESSION_STATUS" && event.payload["providerSurface"]?.boolValue == true) {
            // Browser/provider state can arrive before lazy session catalog hydration.
            // Materialize a minimal row so the phone can show the real desktop state
            // immediately instead of dropping the status until a later listSessions.
            ensureSessionDescriptorExists(sessionId: sessionId, instanceId: event.instanceId, updatedAt: event.createdAt)
        }
        let applyBegan = StreamPerformance.now
        let previousStream = assistantStreams[sessionId]
        defer {
            if event.type == "MESSAGE_UPDATED" {
                (assistantStreams[sessionId] ?? previousStream)?.performance.apply.add((StreamPerformance.now - applyBegan) * 1000)
            }
        }
        let isAssistantDelta = event.type == "MESSAGE_UPDATED" && event.payload["contentDelta"]?.stringValue != nil
        let isHistoricalProgressEvent = isAssistantDelta
            || event.type == "TOOL_STARTED"
            || event.type == "TOOL_FINISHED"
            || event.type == "GENERATION_STARTED"
        if runEventTypes.contains(event.type) && !isAssistantDelta && !(suppressTransientPresentation && isHistoricalProgressEvent) {
            DiagnosticsLog.shared.record("event_applied", fields: [
                "type": event.type,
                "sequence": String(event.sequence),
                "session": sessionId,
            ])
        }
        if runEventTypes.contains(event.type) {
            // Live delivery can legitimately beat lazy instance/session catalog loading.
            // Materialize one in-memory row so busy/error/idle transitions are visible
            // immediately; a later authoritative listSessions refresh replaces its
            // generic title rather than losing the run state entirely.
            ensureSessionDescriptorExists(sessionId: sessionId, instanceId: event.instanceId, updatedAt: event.createdAt)
            // Project screens render projectConversationsByAlias rather than sessions.
            // Mirror live desktop activity into that list too, otherwise a conversation
            // can be visibly busy in the session catalog while remaining buried at its
            // old Project position until the next full DOM refresh.
            if event.runtimeId == "runtime.web" && !suppressTransientPresentation {
                promoteProjectConversationActivity(sessionId: sessionId, at: event.createdAt)
            }
            // Begin/final already order the session. Updating this @Published
            // catalog for every delta invalidates all history despite row isolation.
            if !isAssistantDelta && !(suppressTransientPresentation && isHistoricalProgressEvent) {
                markSessionActivity(sessionId, at: event.createdAt)
            }
        }

        switch event.type {
        case "SESSION_DELETED":
            sessions.removeAll { $0.id == sessionId }
            messagesBySession.removeValue(forKey: sessionId)
            liveRunStatusBySession.removeValue(forKey: sessionId)
            stopRunStartSequenceBySession.removeValue(forKey: sessionId)
            stopRunGenerationKeyBySession.removeValue(forKey: sessionId)
            await persistMetadata()
        case "MESSAGE_REMOVED":
            if let messageID = event.payload["messageId"]?.stringValue {
                messagesBySession[sessionId]?.removeAll { $0.id == messageID }
                try? await cache.deleteMessage(id: messageID)
            }
        case "MESSAGE_UPDATED" where event.payload["partial"]?.boolValue != false || event.payload["messageId"]?.stringValue == nil:
            if event.runtimeId == "runtime.web", terminalWebRuns.contains(sessionId) { return }
            let content: String
            if let delta = event.payload["contentDelta"]?.stringValue {
                guard let streamId = event.payload["streamId"]?.stringValue,
                      let base = event.payload["baseRevision"]?.intValue,
                      let revision = event.payload["revision"]?.intValue else { return }
                if assistantStreams[sessionId]?.id == streamId,
                   let appliedRevision = assistantStreams[sessionId]?.revision, appliedRevision >= revision { return }
                let appended = assistantStreams[sessionId]?.append(id: streamId, baseRevision: base, revision: revision, delta: delta) == true
                var restored = appended
                if !restored { restored = await restoreAssistantStream(through: event) }
                if !restored {
                    incompleteAssistantStreams[sessionId] = event
                    syncState = "stale"
                    errors["sync"] = "Streaming revision gap; waiting for canonical reconciliation."
                    DiagnosticsLog.shared.record("stream_revision_gap", fields: ["session": sessionId], level: "WARN")
                    return
                }
                content = assistantStreams[sessionId]!.presentationText
            } else {
                let snapshot = event.payload["content"]?.stringValue ?? ""
                if let streamId = event.payload["streamId"]?.stringValue,
                   let revision = event.payload["revision"]?.intValue {
                    let stream = AssistantStream(id: streamId, revision: revision, text: snapshot)
                    assistantStreams[sessionId]?.performance.stopFrames()
                    assistantStreams[sessionId] = stream
                    incompleteAssistantStreams.removeValue(forKey: sessionId)
                    content = stream.presentationText
                } else {
                    assistantStreams.removeValue(forKey: sessionId)
                    content = snapshot
                }
            }
            let attachments = (try? event.payload["attachments"]?.decode([MessageAttachment].self)) ?? []
            let id = event.payload["messageId"]?.stringValue ?? streamingBuffers[sessionId]?.id ?? "stream-\(sessionId)"
            bufferStreaming(
                sessionId: sessionId,
                id: id,
                content: content,
                attachments: attachments,
                sequence: event.sequence,
                deferPresentation: suppressTransientPresentation
            )
            if event.payload["partial"]?.boolValue != false && !suppressTransientPresentation {
                markLiveRunActivity(sessionId: sessionId, at: event.createdAt)
                // A transient event can arrive even when GENERATION_STARTED was lost in
                // transit. Treat streaming content itself as proof that the run is busy
                // so the progress strip remains visible on the phone.
                setSessionState(sessionId, .busy)
                let status = processStatusLabel(for: content)
                if liveRunStatusBySession[sessionId] != status {
                    liveRunStatusBySession[sessionId] = status
                }
            }
        case "MESSAGE_ADDED", "MESSAGE_UPDATED":
            if let server = try? JSONValue.object(event.payload).decode(ServerMessage.self) {
                var base = server.chatMessage
                if event.runtimeId == "runtime.web" {
                    base = Self.normalizedWebAssistantMessage(base)
                    // Static ChatGPT chrome can occasionally arrive as an assistant
                    // event after accessibility fallback parsing. If normalization
                    // removes the entire body and there is no generated attachment,
                    // ignore it completely: it is neither a final answer nor a valid
                    // terminal boundary for the mobile run.
                    if base.role == .assistant,
                       base.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       (base.attachments ?? []).isEmpty {
                        return
                    }
                }
                if base.role == .assistant {
                    if event.runtimeId == "runtime.web" { terminalWebRuns.insert(sessionId) }
                    if let stream = assistantStreams[sessionId] {
                        let reconciledAt = StreamPerformance.now
                        let canonicalEqual = stream.text == base.text
                        var metrics = stream.performance.summary()
                        metrics["session"] = sessionId
                        metrics["finalBytes"] = String(base.text.utf8.count)
                        metrics["finalChars"] = String(base.text.count)
                        metrics["canonicalEqual"] = String(canonicalEqual)
                        metrics["canonicalCompareMs"] = String(format: "%.3f", (StreamPerformance.now - reconciledAt) * 1000)
                        metrics["finalEventAgeMs"] = String(format: "%.3f", Date().timeIntervalSince(event.createdAt) * 1000)
                        DiagnosticsLog.shared.record("stream_performance", fields: metrics)
                        stream.performance.stopFrames()
                        DiagnosticsLog.shared.record("stream_canonical_reconciled", fields: [
                            "session": sessionId,
                            "canonicalEqual": String(canonicalEqual),
                            "finalBytes": String(base.text.utf8.count),
                            "accumulatedBytes": String(stream.utf8Count),
                        ])
                    }
                    discardStreamingPlaceholder(sessionId: sessionId)
                    // MESSAGE_ADDED is the durable final boundary. Converge the visible
                    // run state even if the following GENERATION_STOPPED event is lost.
                    setSessionState(sessionId, .idle)
                    liveRunStatusBySession.removeValue(forKey: sessionId)
                    clearLiveRunActivity(sessionId: sessionId)
                }
                if base.role == .user { await reconcileOptimisticUserEcho(base, sessionId: sessionId) }
                let message = ChatMessage(id: base.id, sessionId: base.sessionId, sequence: event.sequence, role: base.role, kind: base.kind, text: base.text, toolName: nil, toolStatus: nil, detail: nil, attachments: base.attachments, createdAt: base.createdAt)
                merge([message], into: sessionId)
                // The durable reply is already merged. Unfreeze the visible transcript
                // before the asynchronous cache write can delay the UI update.
                releaseRecoveryDisplaySnapshot(for: sessionId)
                try? await cache.upsertMessages([message])
            }
        case "TOOL_STARTED", "TOOL_FINISHED":
            // Historical catch-up does not need to replay tool animation/status rows one
            // event at a time. The durable assistant message (or the next live event)
            // remains authoritative, while suppressing this UI-only work avoids dozens
            // of ObservableObject invalidations when reconnecting after a short gap.
            if suppressTransientPresentation { return }
            let completed = event.type == "TOOL_FINISHED"
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
            let terminalWebRun = event.runtimeId == "runtime.web" && terminalWebRuns.contains(sessionId)
            if terminalWebRun && (!completed || rawToolName == "ChatGPT Web") {
                await settleRunningToolRows(sessionId: sessionId, toolName: toolName)
                return
            }
            if !terminalWebRun { markLiveRunActivity(sessionId: sessionId, at: event.createdAt) }
            if !completed { setSessionState(sessionId, .busy) }
            let detail = event.payload["summary"]?.stringValue
                ?? toolObject?["summary"]?.stringValue
                ?? event.payload["provider"]?.stringValue
            if rawToolName == "ChatGPT Web" {
                if isNonProcessWebChromeDetail(detail) { return }
                // Browser animation/status noise (Thinking, Reading, Generating...) is a
                // single live line. Substantive execution stages such as Executing tests,
                // Code Tool, DevSpace-style work, etc. remain visible as compact timeline
                // rows so the phone still mirrors real desktop work without flooding chat.
                let displayDetail = completed
                    ? "回答已生成"
                    : detail.map(webProcessStatusLabel) ?? "ChatGPT 正在处理…"
                liveRunStatusBySession[sessionId] = completed
                    ? "回答已生成，正在确认同步…"
                    : displayDetail

                if completed || isTransientWebProcessDetail(detail) {
                    await settleRunningToolRows(sessionId: sessionId, toolName: "ChatGPT Web")
                    return
                }
                if messagesBySession[sessionId, default: []].contains(where: {
                    $0.kind == .toolEvent
                        && $0.toolName == "ChatGPT Web"
                        && $0.toolStatus == "Running"
                        && $0.detail == displayDetail
                }) {
                    return
                }
                await settleRunningToolRows(sessionId: sessionId, toolName: "ChatGPT Web")
                let message = ChatMessage(
                    id: "tool-\(event.eventId.uuidString.lowercased())",
                    sessionId: sessionId,
                    sequence: event.sequence,
                    role: .tool,
                    kind: .toolEvent,
                    text: "",
                    toolName: "ChatGPT Web",
                    toolStatus: "Running",
                    detail: displayDetail,
                    createdAt: event.createdAt
                )
                merge([message], into: sessionId)
                try? await cache.upsertMessages([message])
                return
            }
            let displayDetail = detail
            let stableToolId = toolObject?["id"]?.stringValue
            let messageId = stableToolId.map { "tool-\(sessionId)-\($0)" } ?? event.eventId.uuidString
            let message = ChatMessage(id: messageId, sessionId: sessionId, sequence: event.sequence, role: .tool, kind: .toolEvent, text: "", toolName: toolName, toolStatus: completed ? "Completed" : "Running", detail: displayDetail, createdAt: event.createdAt)
            merge([message], into: sessionId)
            try? await cache.upsertMessages([message])
            if !terminalWebRun {
                liveRunStatusBySession[sessionId] = completed ? "\(toolName) 已完成，继续处理中…" : "正在运行 \(toolName)…"
            }
        case "GENERATION_STARTED":
            if event.runtimeId == "runtime.web" { terminalWebRuns.remove(sessionId) }
            if suppressTransientPresentation { return }
            markLiveRunActivity(sessionId: sessionId, at: event.createdAt)
            setSessionState(sessionId, .busy)
            liveRunStatusBySession[sessionId] = generationStartedLabel(runtimeId: event.runtimeId)
            DiagnosticsLog.shared.record("generation_state_applied", fields: [
                "state": SessionState.busy.rawValue,
                "sequence": String(event.sequence),
            ])
        case "GENERATION_STOPPED":
            if event.runtimeId == "runtime.web" { terminalWebRuns.insert(sessionId) }
            if event.payload["ok"]?.boolValue == false {
                let outcome = generationTerminalOutcome(for: event.payload)
                let isAntigravity = event.runtimeId == "runtime.antigravity"
                if outcome == .failed && !isAntigravity {
                    // Web DOM prefixes are transient and do not represent a durable reply.
                    // Antigravity publishes partial output as a durable MESSAGE_ADDED event.
                    discardStreamingPlaceholder(sessionId: sessionId)
                } else {
                    await preservePartialAssistantOutput(sessionId: sessionId)
                }
                await settleRunningToolRows(sessionId: sessionId, status: "Interrupted")
                let state: SessionState
                switch outcome {
                case .canceled, .interrupted:
                    state = .idle
                case .unknown:
                    state = .unknown
                case .failed:
                    state = .error
                }
                setSessionState(sessionId, state)
                DiagnosticsLog.shared.record("generation_state_applied", fields: [
                    "state": state.rawValue,
                    "sequence": String(event.sequence),
                ])
                liveRunStatusBySession.removeValue(forKey: sessionId)
                clearLiveRunActivity(sessionId: sessionId)
                let code = event.payload["errorCode"]?.stringValue ?? "GENERATION_FAILED"
                let message = event.payload["errorMessage"]?.stringValue
                if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors[sessionId] = message
                } else {
                    switch outcome {
                    case .canceled:
                        errors[sessionId] = "生成已取消；已保留当前可见的部分输出。"
                    case .interrupted:
                        errors[sessionId] = "生成已中断；已保留当前可见的部分输出，请核对原会话后再重试。"
                    case .unknown:
                        errors[sessionId] = "生成结果未知；已保留当前可见的部分输出，请核对原会话后再重试。"
                    case .failed:
                        if code == "PROVIDER_RATE_LIMITED" {
                            errors[sessionId] = "ChatGPT 请求过快，当前会话已被临时限流。本次回答未完成，RemoteAI 没有保存截断内容，请稍后重试。"
                        } else {
                            errors[sessionId] = "本次生成未完成（\(code)）。请核对原会话后再重试。"
                        }
                    }
                }
            } else {
                flushStreaming(sessionId: sessionId)
                setSessionState(sessionId, .idle)
                DiagnosticsLog.shared.record("generation_state_applied", fields: [
                    "state": SessionState.idle.rawValue,
                    "sequence": String(event.sequence),
                ])
                liveRunStatusBySession.removeValue(forKey: sessionId)
                clearLiveRunActivity(sessionId: sessionId)
                errors[sessionId] = nil
            }
        case "SESSION_STATUS":
            if event.payload["providerSurface"]?.boolValue == true {
                let degraded = event.payload["state"]?.stringValue == "degraded"
                let issue: RemoteProviderSurfaceIssue? = degraded ? RemoteProviderSurfaceIssue(
                    code: event.payload["code"]?.stringValue ?? "PROVIDER_UNAVAILABLE",
                    state: event.payload["issueState"]?.stringValue ?? event.payload["providerState"]?.stringValue ?? "degraded",
                    message: event.payload["message"]?.stringValue ?? "ChatGPT 网页当前不可用，RemoteAI 正在等待恢复。",
                    retryable: event.payload["retryable"]?.boolValue == true,
                    at: event.payload["at"]?.stringValue.flatMap(RemoteAIDate.parse),
                    originalMessage: event.payload["originalMessage"]?.stringValue
                ) : nil
                let surfaceState = event.payload["state"]?.stringValue ?? "unknown"
                let eventIssue: RemoteProviderSurfaceIssue?
                if degraded {
                    eventIssue = issue
                } else if surfaceState == "unknown",
                          let code = event.payload["code"]?.stringValue,
                          let message = event.payload["message"]?.stringValue {
                    eventIssue = RemoteProviderSurfaceIssue(
                        code: code,
                        state: event.payload["issueState"]?.stringValue ?? event.payload["providerState"]?.stringValue ?? "degraded",
                        message: message,
                        retryable: event.payload["retryable"]?.boolValue == true,
                        at: event.payload["at"]?.stringValue.flatMap(RemoteAIDate.parse),
                        originalMessage: event.payload["originalMessage"]?.stringValue
                    )
                } else {
                    eventIssue = nil
                }
                applyWebProviderSurfaceIssue(
                    sessionId: sessionId,
                    issue: eventIssue,
                    surfaceState: surfaceState,
                    statusObservedAt: event.payload["statusObservedAt"]?.stringValue.flatMap(RemoteAIDate.parse)
                        ?? event.payload["at"]?.stringValue.flatMap(RemoteAIDate.parse)
                        ?? event.createdAt
                )
                return
            }
            await requestMetadataRefresh()
        case "WEB_BINDING_CHANGED":
            let reason = event.payload["reason"]?.stringValue ?? "unknown"
            let activeTabId = event.payload["activeTabId"]?.intValue
            if activeTabId == nil && ["tabClosed", "conversationContextChanged", "projectContextChanged", "tabReassignedToRegisteredConversation"].contains(reason) {
                webBindingDetachedSessions.insert(sessionId)
                switch reason {
                case "tabClosed":
                    recentSystemNotice = "电脑端对应的 ChatGPT 标签页已关闭；RemoteAI 会在需要时重新打开并绑定该会话。"
                case "conversationContextChanged":
                    recentSystemNotice = "电脑端 ChatGPT 标签页已切换到其他对话；手机当前会话不会跟着串线，RemoteAI 会按原会话身份重新绑定。"
                case "projectContextChanged":
                    recentSystemNotice = "电脑端 ChatGPT 标签页已切换到其他 Project；手机当前 Project/Chat 身份保持不变。"
                default:
                    recentSystemNotice = "电脑端 ChatGPT 标签页绑定发生变化；RemoteAI 正在重新核对当前会话。"
                }
            } else if activeTabId != nil, webBindingDetachedSessions.remove(sessionId) != nil {
                recentSystemNotice = "电脑端 ChatGPT 会话已重新绑定；手机正在补同步最新状态。"
            }
            await requestMetadataRefresh()
        case "WEB_PAGE_REGISTERED":
            // The Windows browser bridge publishes the stable Project/conversation
            // identity as soon as a desktop Chat becomes observable. Apply that exact
            // registration locally so a new in-progress desktop conversation appears
            // on the phone immediately instead of waiting for generation completion or
            // a later Project DOM scan.
            await applyWebPageRegistrationEvent(event, sessionId: sessionId, suppressPresentation: suppressTransientPresentation)
            if event.payload["activeTabId"]?.intValue != nil,
               webBindingDetachedSessions.remove(sessionId) != nil {
                recentSystemNotice = "电脑端 ChatGPT 会话已重新绑定；手机正在补同步最新状态。"
            }
            await requestMetadataRefresh()
        case "SESSION_CREATED", "SESSION_UPDATED", "SESSION_RENAMED", "WEB_PAGE_UNREGISTERED":
            await requestMetadataRefresh()
        case "COMMAND_RESULT", "COMMAND_REJECTED":
            if let raw = event.payload["commandId"]?.stringValue, let commandId = UUID(uuidString: raw) {
                commandStates[commandId] = event.type == "COMMAND_RESULT" ? .completed : .failed
            }
        default:
            break
        }
    }

    private func applyWebProviderSurfaceIssue(
        sessionId: String,
        issue: RemoteProviderSurfaceIssue?,
        surfaceState: String,
        statusObservedAt: Date?,
        requestStartedAt: Date? = nil
    ) {
        if let requestStartedAt,
           let lastReceivedAt = webProviderStatusReceivedAtBySession[sessionId],
           requestStartedAt < lastReceivedAt {
            DiagnosticsLog.shared.record("stale_web_provider_status_ignored", fields: ["session": sessionId], level: "WARN")
            return
        }
        // A delayed Relay event or earlier status RPC must not reintroduce a
        // resolved Try Again / connection error after a newer provider observation.
        // Compare source timestamps for this same Chat, not arrival order on iOS.
        if let statusObservedAt,
           let latest = webProviderSurfaceObservedAtBySession[sessionId],
           statusObservedAt < latest {
            DiagnosticsLog.shared.record("older_web_provider_observation_ignored", fields: ["session": sessionId], level: "WARN")
            return
        }
        webProviderStatusReceivedAtBySession[sessionId] = Date()
        webProviderSurfaceStateBySession[sessionId] = surfaceState
        if let statusObservedAt {
            webProviderSurfaceObservedAtBySession[sessionId] = statusObservedAt
        } else {
            webProviderSurfaceObservedAtBySession.removeValue(forKey: sessionId)
        }

        if surfaceState == "degraded", let issue {
            let message = issue.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ChatGPT 网页当前不可用，RemoteAI 正在等待恢复。"
                : issue.message
            let normalizedIssue = RemoteProviderSurfaceIssue(
                code: issue.code,
                state: issue.state,
                message: message,
                retryable: issue.retryable,
                at: issue.at,
                originalMessage: issue.originalMessage
            )
            let previousIssue = webProviderIssuesBySession[sessionId]
            let previousMessage = previousIssue?.message
            let previousState = previousIssue?.state
            webProviderIssuesBySession[sessionId] = normalizedIssue
            webProviderRecoveryObservedAtBySession.removeValue(forKey: sessionId)
            errors[sessionId] = message

            let currentState = sessions.first(where: { $0.id == sessionId })?.state
            if currentState == .busy || currentState == .waiting {
                liveRunStatusBySession[sessionId] = message
            }
            if previousMessage != message || previousState != issue.state {
                DiagnosticsLog.shared.record("web_provider_surface_issue", fields: [
                    "session": sessionId,
                    "state": issue.state,
                    "code": issue.code,
                    "retryable": String(issue.retryable),
                ], level: "WARN")
            }
            return
        }

        if surfaceState == "unknown" {
            guard let issue else { return }
            let message = issue.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ChatGPT 网页当前状态无法确认；保留最近一次异常信息。"
                : issue.message
            let retainedIssue = RemoteProviderSurfaceIssue(
                code: issue.code,
                state: issue.state,
                message: message,
                retryable: issue.retryable,
                at: issue.at,
                originalMessage: issue.originalMessage
            )
            let previousMessage = webProviderIssuesBySession[sessionId]?.message
            webProviderIssuesBySession[sessionId] = retainedIssue
            if errors[sessionId] == nil || errors[sessionId] == previousMessage {
                errors[sessionId] = message
            }
            return
        }

        guard surfaceState == "online",
              let previousIssue = webProviderIssuesBySession.removeValue(forKey: sessionId) else { return }
        let previousMessage = previousIssue.message
        if let statusObservedAt {
            webProviderRecoveryObservedAtBySession[sessionId] = statusObservedAt
        } else {
            webProviderRecoveryObservedAtBySession.removeValue(forKey: sessionId)
        }
        if errors[sessionId] == previousMessage { errors[sessionId] = nil }
        if liveRunStatusBySession[sessionId] == previousMessage {
            let currentState = sessions.first(where: { $0.id == sessionId })?.state
            if currentState == .busy || currentState == .waiting {
                liveRunStatusBySession[sessionId] = "ChatGPT 网页已恢复，正在继续处理…"
            } else {
                liveRunStatusBySession.removeValue(forKey: sessionId)
            }
        }
        DiagnosticsLog.shared.record("web_provider_surface_recovered", fields: [
            "session": sessionId,
            "previousState": previousIssue.state,
        ])
    }

    func clearRecentSystemNotice() {
        recentSystemNotice = nil
    }

    private func applyTransportHealth(_ event: TransportHealthEvent) {
        desktopStatusUpdatedAt = event.at
        switch event.channel {
        case .relay:
            let wasOnline = desktopRelayConnected == true
            desktopRelayConnected = event.state == .online
            if event.state == .online {
                let recovered = systemTransportOfflineChannels.remove("device-relay") != nil
                if recovered && !wasOnline && !deferringTransientConnectionPresentation {
                    recentSystemNotice = "手机到 Cloudflare Relay 的连接已恢复；正在核对 Windows Agent 和当前会话。"
                }
                return
            }
            if event.state == .connecting { return }
            systemTransportOfflineChannels.insert("device-relay")
            if machine.state == .online && event.state == .offline {
                deferTransientConnectionPresentation(graceNanoseconds: Self.relayPresentationGraceNanoseconds)
            }
            if machine.state == .online || connectionPhase == .online {
                machine.state = .connecting
                connectionPhase = .reconnecting
            }
            if event.state == .offline {
                errors["connection"] = "Cloudflare Relay 连接已断开，RemoteAI 正在重连；已确认的命令和事件游标会保留。"
                // A short 1006 remains in diagnostics; it need not flash a notice.
            } else if connectionPhase == .reconnecting {
                errors["connection"] = "Cloudflare Relay 正在重连；Windows Agent 状态将于 Relay 恢复后重新核对。"
            }

        case .agent:
            switch event.state {
            case .online:
                desktopAgentConnected = true
                let recovered = systemTransportOfflineChannels.remove("windows-agent") != nil
                if machine.state != .online {
                    machine.state = .connecting
                    connectionPhase = .authenticating
                } else {
                    // A short 1006 recovered inside the grace window. The phone never
                    // left the durable Relay path, so restore the normal phase without
                    // forcing a second authentication/reconnect cycle.
                    connectionPhase = .online
                    errors["connection"] = nil
                    endTransientConnectionPresentation()
                }
                if recovered && !deferringTransientConnectionPresentation {
                    recentSystemNotice = "Windows Agent 已重新连上 Relay，正在补同步当前会话。"
                }
                scheduleWebTabsRefreshAfterConnectivityRecovery(reason: "agent-online")
            case .connecting, .reconnecting:
                if machine.state != .online {
                    // During initial connection there is no previously authenticated
                    // command-capable path to preserve, so surface the reconnect state.
                    desktopAgentConnected = false
                    systemTransportOfflineChannels.insert("windows-agent")
                    machine.state = .connecting
                    connectionPhase = .windowsReconnecting
                    errors["connection"] = "Windows Agent 正在重新连接 Relay；手机到 Relay 本身仍保持连接。"
                } else {
                    // The Relay keeps reliable device->Agent commands queued during the
                    // short Windows 1006 grace window, and CloudflareTransport deliberately
                    // keeps agentOnline command-capable until that grace expires. Do not
                    // turn a 1-4 second self-healing reconnect into a visible disconnect
                    // banner or an orange "Agent offline" line in an active chat.
                    desktopAgentConnected = true
                    connectionPhase = .online
                    errors["connection"] = nil
                }
            case .offline:
                endTransientConnectionPresentation()
                desktopAgentConnected = false
                systemTransportOfflineChannels.insert("windows-agent")
                machine.state = .offline
                connectionPhase = .windowsOffline
                errors["connection"] = "Windows Agent 离线 — 手机仍连接 Cloudflare Relay，将在电脑恢复后自动补同步。"
                recentSystemNotice = "Windows Agent 已确认离线；Cloudflare Relay 连接仍会保持，电脑恢复后会自动继续。"
            }
        }
    }

    private func scheduleWebTabsRefreshAfterConnectivityRecovery(reason: String) {
        guard webTabsRefreshNeedsConnectivityRetry else { return }
        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  generation == self.lifecycleGeneration,
                  !self.isSuspended,
                  self.machine.state == .online,
                  self.webTabsRefreshNeedsConnectivityRetry else { return }
            // Claim the one pending read-only recovery before suspending for network IO.
            // Do not create a second polling loop or repeat any provider send.
            self.webTabsRefreshNeedsConnectivityRetry = false
            DiagnosticsLog.shared.record("web_tabs_connectivity_recovery", fields: ["reason": reason])
            await self.refreshOpenWebTabs()
        }
    }

    private func scheduleWebProjectsRefreshAfterConnectivityRecovery(reason: String) {
        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  generation == self.lifecycleGeneration,
                  !self.isSuspended,
                  self.machine.state == .online,
                  self.desktopBrowserConnected != false,
                  self.webProjectsRefreshNeedsConnectivityRetry else { return }
            self.webProjectsRefreshNeedsConnectivityRetry = false
            DiagnosticsLog.shared.record("projects_refresh_connectivity_recovery", fields: [
                "reason": reason,
                "cachedCount": String(self.webProjects.count),
            ])
            await self.refreshWebProjects(force: false)
        }
    }

    private func applyAgentStatusSnapshot(_ snapshot: AgentStatusSnapshot) {
        lastOnlineHeadProbe = Date()
        let previousBrowser = desktopBrowserConnected
        desktopAgentConnected = true
        desktopBrowserConnected = snapshot.browserConnected
        if let relayOnline = snapshot.relayOnline { desktopRelayConnected = relayOnline }
        desktopStatusUpdatedAt = Date()

        if snapshot.browserConnected == false {
            systemTransportOfflineChannels.insert("browser-bridge")
            recentSystemNotice = "电脑端 Agent 已连接，但 Browser Bridge 当前离线；手机仍会保持连接并等待浏览器控制恢复。"
        } else if snapshot.browserConnected == true {
            let hadOfflineMarker = systemTransportOfflineChannels.remove("browser-bridge") != nil
            if previousBrowser == false || hadOfflineMarker {
                recentSystemNotice = "电脑端 Browser Bridge 已恢复，当前会话正在补同步。"
                scheduleWebProjectsRefreshAfterConnectivityRecovery(reason: "browser-status-recovered")
            }
        }
    }

    private func applyTransportStatusEvent(_ event: RemoteEvent) {
        let channel = event.payload["channel"]?.stringValue ?? "relay"
        let state = event.payload["state"]?.stringValue?.lowercased() ?? "unknown"
        let label: String
        switch channel {
        case "browser-bridge": label = "电脑端 Browser Bridge"
        default: label = "电脑端 Relay"
        }
        let time = event.createdAt.formatted(date: .omitted, time: .standard)

        if state == "offline" {
            systemTransportOfflineChannels.insert(channel)
            // Windows Relay status events are durable diagnostics. A brief Agent-side
            // 1006 cannot reach the phone until the Agent is already connected again,
            // while the live Relay health path separately applies a 12-second grace.
            // Recording the historical event as a user-visible banner therefore makes
            // successful self-healing look like a fresh disconnect.
            if channel != "relay" {
                recentSystemNotice = "\(label) 于 \(time) 断开，RemoteAI 正在自动恢复连接。"
            }
            DiagnosticsLog.shared.record("remote_transport_offline", fields: ["channel": channel, "at": time], level: "WARN")
            return
        }
        if state == "online", systemTransportOfflineChannels.remove(channel) != nil {
            if channel != "relay" {
                recentSystemNotice = "\(label) 已于 \(time) 恢复；刚刚发生过一次断连，当前会话正在补同步。"
            }
            DiagnosticsLog.shared.record("remote_transport_recovered", fields: ["channel": channel, "at": time])
            if channel == "browser-bridge" {
                desktopBrowserConnected = true
                scheduleWebProjectsRefreshAfterConnectivityRecovery(reason: "browser-transport-recovered")
            }
        }
    }

    private func processStatusLabel(for content: String) -> String {
        // This is a status label, not an answer classifier. Do not lowercase and
        // repeatedly scan an ever-growing answer on MainActor for every event.
        guard content.utf8.count <= 512 else { return "正在生成回答…" }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "正在生成回答…" }
        let lower = trimmed.lowercased()
        if lower == "thinking" || lower.hasPrefix("thinking ") { return "思考中…" }
        if lower.contains("analyzing image") || lower.contains("analysing image") { return "正在分析图片…" }
        if lower.contains("generated image ready") || lower.contains("image ready") { return "图片已生成，正在同步…" }
        if lower.contains("generating image") || lower.contains("creating image") || lower.contains("drawing image") { return "正在生成图片…" }
        if lower.contains("searching the web") || lower == "searching" { return "正在搜索网页…" }
        if lower.contains("reading") && trimmed.count < 120 { return trimmed }
        if !trimmed.contains("\n"), trimmed.count <= 80 { return trimmed }
        return "正在生成回答…"
    }

    private func generationStartedLabel(runtimeId: String) -> String {
        switch runtimeId {
        case "runtime.codex": return "Codex 正在处理…"
        case "runtime.antigravity": return "Antigravity 正在处理…"
        default: return "ChatGPT 正在处理…"
        }
    }

    func webProcessStatusLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ChatGPT 正在处理…" }
        let lower = trimmed.lowercased()
        if lower == "thinking" || lower == "thinking..." { return "思考中…" }
        // Translate only generic chrome labels. Preserve English stage details like
        // "Searching files and verifying the final reply" verbatim for the phone.
        if lower == "searching" || lower == "searching the web" || lower == "search the web" { return "正在搜索网页…" }
        if lower == "reading" || lower == "browsing" { return "正在读取网页内容…" }
        if lower == "analyzing image" || lower == "analysing image" { return "正在分析图片…" }
        if lower == "generated image ready" || lower == "image ready" { return "图片已生成，正在同步…" }
        if lower == "generating image" || lower == "creating image" || lower == "drawing image" { return "正在生成图片…" }
        if lower == "responding" || lower == "chatgpt is responding" { return "正在生成回答…" }
        if lower == "response complete" || lower == "response completed" || lower == "response finished" { return "回答已生成，正在确认同步…" }
        if lower == "writing" || lower == "generating" || lower == "generating answer" { return "正在生成回答…" }
        return trimmed
    }

    private func isNonProcessWebChromeDetail(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower == "check important info" || lower == "check important info."
            || lower == "check improve info" || lower == "check improve info." { return true }
        let compact = lower.replacingOccurrences(of: "’", with: "'")
        return compact == "can make mistakes"
            || compact == "can make mistakes."
            || compact.hasPrefix("can make mistakes. check important info")
            || compact.hasPrefix("can make mistakes. check improve info")
            || compact == "ai can make mistakes"
            || compact == "ai can make mistakes."
            || compact == "it's ai and can make mistakes"
            || compact == "it's ai and can make mistakes."
            || compact.hasPrefix("ai can make mistakes. check important info")
            || compact.hasPrefix("ai can make mistakes. check improve info")
            || compact.hasPrefix("it's ai and can make mistakes. check important info")
            || compact.hasPrefix("it's ai and can make mistakes. check improve info")
            || compact.hasPrefix("chatgpt can make mistakes. check important info")
            || compact.hasPrefix("chatgpt can make mistakes. check improve info")
    }

    private static func normalizedWebAssistantChromeText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // ChatGPT's accessibility transcript can append static browser chrome after the
        // actual assistant answer. Strip only an exact trailing footer boundary so an
        // answer that quotes the same sentence in its body is preserved.
        let footerPattern = #"(?:^|\r?\n)\s*(?:(?:ChatGPT said|ChatGPT 说)\s*[：:]?\s*(?:\r?\n)\s*)?(?:(?:(?:It['’]?s\s+)?AI|ChatGPT)(?:\s+and)?\s+)?can make mistakes(?:\.\s*Check\s+(?:important|improve)\s+info\.?)?\s*$"#
        guard let range = trimmed.range(
            of: footerPattern,
            options: [.regularExpression, .caseInsensitive]
        ) else { return trimmed }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWebAssistantMessage(_ message: ChatMessage) -> ChatMessage {
        guard message.role == .assistant, message.kind == .text else { return message }
        var normalized = message
        normalized.text = normalizedWebAssistantChromeText(message.text)
        return normalized
    }

    func isTransientWebProcessDetail(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if lower == "thinking" || lower == "thinking..." { return true }
        if lower.hasPrefix("loading older messages") || lower == "stopped thinking" { return true }
        // Do not mistake substantive execution summaries for UI-only chrome.
        if lower == "searching" || lower == "searching the web" || lower == "search the web" { return true }
        if lower == "reading" || lower == "browsing" { return true }
        if lower == "analyzing image" || lower == "analysing image" { return true }
        if lower == "generated image ready" || lower == "image ready" { return true }
        if lower == "generating image" || lower == "creating image" || lower == "drawing image" { return true }
        if lower == "generation finished" || lower == "generation complete" { return true }
        if lower == "response complete" || lower == "response completed" || lower == "response finished" { return true }
        if lower == "chatgpt is responding" || lower == "chatgpt responding" || lower == "responding" { return true }
        if lower == "writing" || lower == "generating" || lower == "generating answer" { return true }
        if trimmed.hasPrefix("思考中")
            || trimmed.hasPrefix("正在搜索网页")
            || trimmed.hasPrefix("正在读取网页内容")
            || trimmed.hasPrefix("正在分析图片")
            || trimmed.hasPrefix("图片已生成，正在同步")
            || trimmed.hasPrefix("正在生成图片")
            || trimmed.hasPrefix("正在生成回答")
            || trimmed.hasPrefix("ChatGPT 正在处理")
            || trimmed.hasPrefix("回答已生成") {
            return true
        }
        return false
    }

    private func generationTerminalOutcome(for payload: [String: JSONValue]) -> GenerationTerminalOutcome {
        let reason = payload["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let delivery = payload["delivery"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let code = payload["errorCode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""

        if delivery == "unknown" || reason.contains("unknown") { return .unknown }
        if ["canceled", "cancelled"].contains(reason)
            || code == "GENERATION_CANCELED"
            || payload["stopped"]?.boolValue == true {
            return .canceled
        }
        if reason == "interrupted" || code == "GENERATION_INTERRUPTED" { return .interrupted }
        if ["failed", "error", "provider-error"].contains(reason) || !code.isEmpty {
            return .failed
        }
        // A negative terminal event without a classified provider outcome is not
        // proof of failure or cancellation. Keep the transcript recoverable.
        return .unknown
    }

    private func preservePartialAssistantOutput(sessionId: String) async {
        let streamedText = assistantStreams[sessionId]?.text
        flushStreaming(sessionId: sessionId)
        if let stream = assistantStreams[sessionId] {
            stream.performance.stopFrames()
            assistantStreams.removeValue(forKey: sessionId)
        }
        incompleteAssistantStreams.removeValue(forKey: sessionId)
        if incompleteAssistantStreams.isEmpty, errors["sync"]?.hasPrefix("Streaming") == true {
            errors.removeValue(forKey: "sync")
        }
        streamingBuffers.removeValue(forKey: sessionId)

        guard var local = messagesBySession[sessionId] else { return }
        var changed: [ChatMessage] = []
        for index in local.indices where local[index].role == .assistant
            && local[index].kind == .text
            && local[index].toolStatus == "Streaming" {
            if let streamedText { local[index].text = streamedText }
            local[index].toolStatus = nil
            changed.append(local[index])
        }
        if !changed.isEmpty {
            messagesBySession[sessionId] = local
            try? await cache.upsertMessages(changed)
        }
    }

    private func setSessionState(_ sessionId: String, _ state: SessionState) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }), sessions[index].state != state {
            let webTerminal = sessions[index].instanceId == "web.chatgpt"
                && state != .busy && state != .waiting
            sessions[index].state = state
            if webTerminal {
                // The caller clears its live progress marker after setting the
                // terminal state; reconcile on the next MainActor turn.
                Task { @MainActor [weak self] in
                    self?.resumeDeferredWebProjectsRefreshIfIdle()
                }
            }
        }
    }

    private func markLiveRunActivity(sessionId: String, at: Date) {
        if let current = liveRunActivityAtBySession[sessionId], current >= at { return }
        liveRunActivityAtBySession[sessionId] = at
    }

    private func clearLiveRunActivity(sessionId: String) {
        liveRunActivityAtBySession.removeValue(forKey: sessionId)
    }

    private func bufferStreaming(sessionId: String, id: String, content: String, attachments: [MessageAttachment], sequence: Int64, deferPresentation: Bool = false) {
        streamingBuffers[sessionId] = (id, content, sequence, attachments)
        if deferPresentation { return }
        if flushTask == nil {
            let byteCount = assistantStreams[sessionId]?.utf8Count ?? content.utf8.count
            let delay = Self.streamingFlushDelayNanoseconds(forByteCount: byteCount)
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                self?.flushAllStreaming()
            }
        }
    }

    private func flushStreaming(sessionId: String) {
        guard let item = streamingBuffers.removeValue(forKey: sessionId) else { return }
        let stream = assistantStreams[sessionId]
        stream?.flushPresentation()
        // Incremental streams publish through their own row, without copying the
        // message array or invalidating the ChatView on every presentation tick.
        if stream != nil,
           let existing = messagesBySession[sessionId]?.first(where: { $0.id == item.id }),
           existing.attachments == item.attachments { return }
        var list = messagesBySession[sessionId, default: []]
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            guard list[index].text != item.text || list[index].attachments != item.attachments else { return }
            list[index].text = item.text
            list[index].attachments = item.attachments
            // Text/attachments do not change the established sort key.
            messagesBySession[sessionId] = list
        } else {
            list.append(ChatMessage(id: item.id, sessionId: sessionId, sequence: item.sequence, role: .assistant, kind: .text, text: item.text, toolName: nil, toolStatus: "Streaming", detail: nil, attachments: item.attachments, createdAt: Date()))
            messagesBySession[sessionId] = sortedMessages(list)
        }
    }

    private func flushAllStreaming() {
        for sessionId in Array(streamingBuffers.keys) { flushStreaming(sessionId: sessionId) }
        flushTask = nil
    }

    private func normalizedWebTranscriptUserText(_ value: String) -> String {
        var text = value.replacingOccurrences(
            of: #"\r?\n(?:Worked|Thought)\s+for\s+[^\r\n]+\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return text }

        let processPattern = #"^(?:thinking|reasoning|deep thinking|investigat(?:ing|ed)\b|inspect(?:ing|ed)\b|clarif(?:ying|ied)\b|repair(?:ing|ed)\b|fix(?:ing|ed)\b|continu(?:ing|ed)\b|resum(?:ing|ed)\b|analy[sz](?:ing|ed)\b|review(?:ing|ed)\b|search(?:ing|ed)\b|read(?:ing)?\b|edit(?:ing|ed)\b|patch(?:ing|ed)\b|test(?:ing|ed)\b|verif(?:ying|ied)\b|validat(?:ing|ed)\b|build(?:ing|t)\b|packag(?:ing|ed)\b|explor(?:ing|ed)\b|assess(?:ing|ed)\b|using tool\b|tool call\b|web search\b|思考|深度思考|分析|检查|调查|澄清|修复|搜索|读取|编辑|测试|验证|构建|打包)(?:\s|$)"#
        var cut = lines.count
        for index in 1..<lines.count {
            let current = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty { continue }
            let next = index + 1 < lines.count
                ? lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let previousBlank = lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let repeatedStatus = !next.isEmpty && current.compare(next, options: .caseInsensitive) == .orderedSame
            let processLine = current.range(of: processPattern, options: [.regularExpression, .caseInsensitive]) != nil
            let networkError = current.range(
                of: #"^(?:A network error occurred\. Please check your connection and try again\.?|Our systems are thinking a bit more about this request before responding\.?|Resume stream unavailable|Stopped thinking|Loading older messages[.…]*|(?:Worked|Thought)\s+for\s+[.…]+)$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            if (processLine && (repeatedStatus || previousBlank)) || networkError {
                cut = index
                break
            }
        }
        if cut < lines.count {
            text = lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func collapseWebTranscriptArtifacts(sessionId: String) async {
        guard var list = messagesBySession[sessionId], !list.isEmpty else { return }
        var removeIDs = Self.adjacentExactWebAssistantDuplicateIDs(list)

        // Accessibility-only ChatGPT transcripts can append reasoning duration and
        // live process labels underneath the user body. Normalize the first contaminated
        // copy in place, then remove only adjacent duplicates created by the same chrome.
        // Exact repeated user prompts without any chrome are intentionally preserved.
        var changedUsers: [ChatMessage] = []
        var lastKeptUserIndex: Int?
        var contaminatedUserIDs = Set<String>()
        for index in list.indices {
            guard list[index].role == .user else {
                lastKeptUserIndex = nil
                continue
            }
            let raw = list[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedWebTranscriptUserText(raw)
            let contaminated = !normalized.isEmpty && normalized != raw
            if contaminated {
                list[index].text = normalized
                contaminatedUserIDs.insert(list[index].id)
                changedUsers.append(list[index])
            }
            if let previousIndex = lastKeptUserIndex {
                let previous = list[previousIndex]
                let previousNormalized = normalizedWebTranscriptUserText(previous.text)
                if !normalized.isEmpty,
                   previousNormalized == normalized,
                   (previous.attachments ?? []).isEmpty,
                   (list[index].attachments ?? []).isEmpty,
                   (contaminated || contaminatedUserIDs.contains(previous.id)) {
                    removeIDs.insert(list[index].id)
                    continue
                }
            }
            lastKeptUserIndex = index
        }

        // A stale accessibility fallback could also surface another chat's short title
        // as a second adjacent assistant bubble. Restrict cleanup to a title that is
        // already known in the local session catalog and follows a substantial answer.
        let otherSessionTitles = Set(sessions
            .filter { $0.id != sessionId }
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 80 })
        if list.count > 1 {
            for index in 1..<list.count {
                let previous = list[index - 1]
                let current = list[index]
                guard previous.role == .assistant,
                      current.role == .assistant,
                      previous.kind == .text,
                      current.kind == .text,
                      previous.toolStatus != "Streaming",
                      current.toolStatus != "Streaming" else { continue }
                let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentText = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if currentText.count <= 80,
                   previousText.count >= 160,
                   otherSessionTitles.contains(currentText) {
                    removeIDs.insert(current.id)
                    continue
                }
                // Canonical DOM reconciliation can arrive as a longer adjacent row.
                // Keep only the complete version inside one assistant-only run window.
                if currentText.count > previousText.count, currentText.hasPrefix(previousText) {
                    removeIDs.insert(previous.id)
                } else if previousText.count > currentText.count, previousText.hasPrefix(currentText) {
                    removeIDs.insert(current.id)
                }
            }
        }

        let persistedUserChanges = changedUsers.filter { !removeIDs.contains($0.id) }
        if !removeIDs.isEmpty {
            list.removeAll { removeIDs.contains($0.id) }
        }
        guard !removeIDs.isEmpty || !persistedUserChanges.isEmpty else { return }
        messagesBySession[sessionId] = list
        if !persistedUserChanges.isEmpty {
            try? await cache.upsertMessages(persistedUserChanges)
        }
        for messageID in removeIDs {
            try? await cache.deleteMessage(id: messageID)
        }
        DiagnosticsLog.shared.record("web_transcript_artifacts_collapsed", fields: [
            "session": sessionId,
            "removed": String(removeIDs.count),
            "normalizedUsers": String(persistedUserChanges.count),
        ])
    }

    private func discardStreamingPlaceholder(sessionId: String) {
        if let stream = assistantStreams[sessionId] {
            stream.performance.stopFrames()
            assistantStreams.removeValue(forKey: sessionId)
        }
        incompleteAssistantStreams.removeValue(forKey: sessionId)
        if incompleteAssistantStreams.isEmpty, errors["sync"]?.hasPrefix("Streaming") == true {
            errors.removeValue(forKey: "sync")
        }
        streamingBuffers.removeValue(forKey: sessionId)
        if let current = messagesBySession[sessionId],
           current.contains(where: { $0.role == .assistant && ($0.toolStatus == "Streaming" || $0.id == "stream-\(sessionId)") }) {
            var updated = current
            updated.removeAll { $0.role == .assistant && ($0.toolStatus == "Streaming" || $0.id == "stream-\(sessionId)") }
            messagesBySession[sessionId] = updated
        }
    }

    func streamingFullText(sessionId: String, fallback: String) -> String {
        assistantStreams[sessionId]?.text ?? fallback
    }

    // After a process restart the durable global cursor can outlive a transient
    // stream. Replay that one object from its reset using the existing events-since
    // API; never rewind the global cursor or reapply historical side effects.
    private func restoreAssistantStream(through target: RemoteEvent) async -> Bool {
        guard let sessionId = target.sessionId,
              let streamId = target.payload["streamId"]?.stringValue,
              let targetRevision = target.payload["revision"]?.intValue,
              let start = target.payload["streamStartSequence"]?.intValue,
              start > 0, start <= target.sequence else { return false }
        let generation = lifecycleGeneration
        let activeTransport = transport
        var cursor = start - 1
        var restored: AssistantStream?
        do {
            // Bound work even for a malicious/stale pointer. A canonical final or
            // later full reset can always replace this transient state.
            for _ in 0..<100 {
                let page = try await activeTransport.delta(machineId: machine.id, after: cursor)
                guard generation == lifecycleGeneration, transport === activeTransport, !isSuspended else { return false }
                for event in page.events where event.sequence <= target.sequence && event.sessionId == sessionId && event.type == "MESSAGE_UPDATED" {
                    guard event.payload["streamId"]?.stringValue == streamId,
                          let revision = event.payload["revision"]?.intValue else { continue }
                    if let snapshot = event.payload["content"]?.stringValue {
                        restored = AssistantStream(id: streamId, revision: revision, text: snapshot)
                    } else if let delta = event.payload["contentDelta"]?.stringValue,
                              let base = event.payload["baseRevision"]?.intValue {
                        guard restored?.append(id: streamId, baseRevision: base, revision: revision, delta: delta) == true else { return false }
                    }
                }
                if let restored, restored.revision == targetRevision {
                    if assistantStreams[sessionId]?.id != streamId || (assistantStreams[sessionId]?.revision ?? 0) < targetRevision {
                        assistantStreams[sessionId] = restored
                    }
                    incompleteAssistantStreams.removeValue(forKey: sessionId)
                    if incompleteAssistantStreams.isEmpty, errors["sync"]?.hasPrefix("Streaming") == true { errors["sync"] = nil }
                    let attachments = (try? target.payload["attachments"]?.decode([MessageAttachment].self)) ?? []
                    bufferStreaming(sessionId: sessionId, id: "stream-\(sessionId)", content: restored.presentationText, attachments: attachments, sequence: target.sequence)
                    DiagnosticsLog.shared.record("stream_revision_recovered", fields: ["session": sessionId, "revision": String(targetRevision)])
                    return true
                }
                guard page.hasMore, page.nextCursor > cursor, page.nextCursor < target.sequence else { return false }
                cursor = page.nextCursor
            }
        } catch {
            DiagnosticsLog.shared.record("stream_revision_recovery_failed", fields: Self.diagnosticFields(for: error), level: "WARN")
        }
        return false
    }

    private func settleRunStateIfAuthoritativeFinalExists(_ remote: [ChatMessage], sessionId: String) async {
        guard let latestUserIndex = remote.lastIndex(where: { $0.role == .user }) else { return }
        let suffixStart = remote.index(after: latestUserIndex)
        guard suffixStart < remote.endIndex else { return }
        let authoritativeFinal = remote[suffixStart...]
            .filter { $0.role == .assistant && $0.kind == .text && $0.toolStatus != "Streaming" }
            .max(by: { $0.createdAt < $1.createdAt })
        guard let authoritativeFinal else { return }

        if let liveActivityAt = liveRunActivityAtBySession[sessionId], authoritativeFinal.createdAt < liveActivityAt {
            DiagnosticsLog.shared.record("stale_final_ignored", fields: [
                "session": sessionId,
                "finalAt": authoritativeFinal.createdAt.ISO8601Format(),
                "liveActivityAt": liveActivityAt.ISO8601Format(),
            ], level: "WARN")
            return
        }

        discardStreamingPlaceholder(sessionId: sessionId)
        terminalWebRuns.insert(sessionId)
        if liveRunStatusBySession[sessionId] != nil { liveRunStatusBySession.removeValue(forKey: sessionId) }
        clearLiveRunActivity(sessionId: sessionId)
        setSessionState(sessionId, .idle)
        if errors[sessionId] != nil { errors.removeValue(forKey: sessionId) }

        await settleRunningToolRows(sessionId: sessionId)
    }

    private func settleRunningToolRows(sessionId: String, toolName: String? = nil, status: String = "Completed") async {
        var changed: [ChatMessage] = []
        if var local = messagesBySession[sessionId] {
            for index in local.indices where local[index].kind == .toolEvent
                && local[index].toolStatus == "Running"
                && (toolName == nil || local[index].toolName == toolName) {
                local[index].toolStatus = status
                changed.append(local[index])
            }
            if !changed.isEmpty { messagesBySession[sessionId] = local }
        }
        if !changed.isEmpty { try? await cache.upsertMessages(changed) }
    }

    private func reconcilePendingUnknownCommands(with remote: [ChatMessage], sessionId: String) async {
        let generation = lifecycleGeneration
        let activeTransport = transport
        let machineId = machine.id
        func isCurrent() -> Bool {
            generation == lifecycleGeneration
                && transport === activeTransport
                && machine.id == machineId
                && machine.state == .online
                && !isSuspended
        }

        guard isCurrent() else { return }
        let remoteUsers = remote.filter { $0.role == .user && $0.sessionId == sessionId }
        guard !remoteUsers.isEmpty else { return }
        let unknownIds = commandStates.compactMap { $0.value == .unknown ? $0.key : nil }
        guard !unknownIds.isEmpty else { return }

        var candidates: [(id: UUID, text: String, createdAt: Date)] = []
        for id in unknownIds {
            guard isCurrent() else { return }
            let command = try? await cache.get(RemoteCommand.self,
                key: Self.pendingCommandKey(id, machineId: machineId))
            guard isCurrent() else { return }
            guard let command,
                  command.machineId == machineId,
                  command.action == "sendMessage",
                  command.sessionId == sessionId else { continue }
            candidates.append((id: id, text: command.payload["text"]?.stringValue ?? "",
                               createdAt: command.createdAt))
        }

        guard isCurrent(), !candidates.isEmpty else { return }

        func identifies(_ value: String?, commandId: UUID) -> Bool {
            value?.caseInsensitiveCompare(commandId.uuidString) == .orderedSame
        }

        // Exact provider/command identity is stronger evidence than matching prompt
        // text. Treat both the local message ID and the historical providerMessageId
        // alias as identity fields, and reserve every row that proves an exact match
        // so it cannot also complete another same-text command.
        var resolvedIds = Set<UUID>()
        var exactMessageIndexes = Set<Int>()
        var exactIndexesByCommand: [UUID: Set<Int>] = [:]
        // Reserve exact rows for every known operation state, including commands
        // already resolved on an earlier bounded history page. Otherwise a later
        // retry could reuse that row as text-only evidence for another pending send.
        for (index, message) in remoteUsers.enumerated() {
            for commandId in commandStates.keys
            where identifies(message.id, commandId: commandId)
                || identifies(message.providerMessageId, commandId: commandId) {
                exactMessageIndexes.insert(index)
                exactIndexesByCommand[commandId, default: []].insert(index)
            }
        }
        for candidate in candidates {
            if let exactIndexes = exactIndexesByCommand[candidate.id], !exactIndexes.isEmpty {
                resolvedIds.insert(candidate.id)
            }
        }

        // Text/time matching is only useful if the evidence is one-to-one across
        // every pending command and provider user turn in this session. If a single
        // provider turn could belong to two same-text sends, leave both unknown.
        var candidateMessageIndexes: [UUID: Set<Int>] = [:]
        var messageCandidateIds: [Int: Set<UUID>] = [:]
        for candidate in candidates where !resolvedIds.contains(candidate.id) && !candidate.text.isEmpty {
            for (index, message) in remoteUsers.enumerated() where !exactMessageIndexes.contains(index) {
                guard message.text == candidate.text else { continue }
                // Preserve protection against an earlier identical prompt while
                // allowing a small cross-device clock skew for the current turn.
                let elapsed = message.createdAt.timeIntervalSince(candidate.createdAt)
                guard elapsed >= -5, elapsed < 300 else { continue }
                candidateMessageIndexes[candidate.id, default: []].insert(index)
                messageCandidateIds[index, default: []].insert(candidate.id)
            }
        }

        for candidate in candidates where !resolvedIds.contains(candidate.id) {
            guard let matches = candidateMessageIndexes[candidate.id],
                  matches.count == 1,
                  let messageIndex = matches.first,
                  messageCandidateIds[messageIndex]?.count == 1 else { continue }
            resolvedIds.insert(candidate.id)
        }

        for candidate in candidates where resolvedIds.contains(candidate.id) {
            guard isCurrent() else { return }
            guard commandStates[candidate.id] == .unknown else { continue }
            commandStates[candidate.id] = .completed
            try? await cache.remove(key: Self.pendingCommandKey(candidate.id, machineId: machineId))
            guard isCurrent() else { return }
        }
    }

    private func reconcileOptimisticUserEcho(_ serverMessage: ChatMessage, sessionId: String) async {
        if routeForSession(sessionId)?.runtimeId == "runtime.codex",
           let providerId = serverMessage.providerMessageId, providerId != serverMessage.id {
            // An authoritative native turn maps the old API ID to the original
            // client ID. Remove only that exact alias, never another equal prompt.
            messagesBySession[sessionId]?.removeAll { $0.id == providerId && $0.role == .user }
            try? await cache.deleteMessage(id: providerId)
        }
        guard let optimistic = messagesBySession[sessionId, default: []].last(where: {
            guard $0.role == .user, $0.sequence == nil,
                  UUID(uuidString: $0.id) != nil,
                  $0.text == serverMessage.text else { return false }
            // Never erase a newer optimistic Send because an older, identical
            // provider turn appeared during history reconciliation.
            let elapsed = serverMessage.createdAt.timeIntervalSince($0.createdAt)
            return elapsed >= -5 && elapsed < 180
        }) else { return }
        messagesBySession[sessionId]?.removeAll { $0.id == optimistic.id }
        try? await cache.deleteMessage(id: optimistic.id)
    }

    static func adjacentExactWebAssistantDuplicateIDs(_ messages: [ChatMessage]) -> Set<String> {
        guard messages.count > 1 else { return [] }
        var removeIDs = Set<String>()
        for index in 1..<messages.count {
            let previous = messages[index - 1]
            let current = messages[index]
            guard previous.role == .assistant,
                  current.role == .assistant,
                  previous.kind == .text,
                  current.kind == .text,
                  previous.toolStatus != "Streaming",
                  current.toolStatus != "Streaming" else { continue }
            let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentText = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !previousText.isEmpty,
                  previousText == currentText,
                  (previous.attachments ?? []) == (current.attachments ?? []) else { continue }
            // The provider can re-materialize the same final answer under a new DOM
            // message id after reconnect/history reconciliation. Keep the newest
            // canonical row; a real repeated answer would have a user turn between it.
            removeIDs.insert(previous.id)
        }
        return removeIDs
    }

    static func staleAntigravityAssistantIDs(local: [ChatMessage], authoritative: [ChatMessage]) -> Set<String> {
        let authoritativeAssistants = authoritative.filter { $0.role == .assistant && $0.kind == .text }
        guard !authoritativeAssistants.isEmpty,
              let lower = authoritative.map(\.createdAt).min(),
              let upper = authoritative.map(\.createdAt).max() else { return [] }
        let authoritativeIDs = Set(authoritativeAssistants.map(\.id))
        // Live RemoteAI builds before the canonical transcript fix could persist an
        // intermediate Antigravity planner response under a random local message id.
        // Once the provider is idle, recent history is the authoritative transcript.
        // Limit pruning to assistant rows inside that exact recent-history time window;
        // user/optimistic rows and older paginated history are intentionally untouched.
        let paddedLower = lower.addingTimeInterval(-2)
        let paddedUpper = upper.addingTimeInterval(2)
        return Set(local.compactMap { message in
            guard message.role == .assistant,
                  message.kind == .text,
                  message.createdAt >= paddedLower,
                  message.createdAt <= paddedUpper,
                  !authoritativeIDs.contains(message.id) else { return nil }
            return message.id
        })
    }

    func reconcileAntigravityAuthoritativeAssistantWindow(_ authoritative: [ChatMessage], sessionId: String) async {
        let local = messagesBySession[sessionId, default: []]
        let staleIDs = Self.staleAntigravityAssistantIDs(local: local, authoritative: authoritative)
        guard !staleIDs.isEmpty else { return }
        // Publish the replacement transcript as one list update. Removing legacy
        // planner rows before awaiting cache deletion lets the visible LazyVStack
        // lay out a temporary, shorter history before canonical rows are merged.
        merge(authoritative, into: sessionId, removing: staleIDs)
        for id in staleIDs { try? await cache.deleteMessage(id: id) }
        DiagnosticsLog.shared.record("antigravity_history_reconciled", fields: [
            "session": sessionId,
            "removedAssistantRows": String(staleIDs.count),
        ])
    }

    private func merge(_ incoming: [ChatMessage], into sessionId: String, removing removedIDs: Set<String> = []) {
        let current = messagesBySession[sessionId, default: []]
        let visibleExisting = current.filter {
            !removedIDs.contains($0.id)
                && !($0.kind == .toolEvent
                && $0.toolName == "ChatGPT Web"
                && isTransientWebProcessDetail($0.detail))
        }
        let visibleIncoming = incoming.filter {
            !($0.kind == .toolEvent
                && $0.toolName == "ChatGPT Web"
                && isTransientWebProcessDetail($0.detail))
        }
        var map = Dictionary(uniqueKeysWithValues: visibleExisting.map { ($0.id, $0) })
        if visibleExisting.count == current.count,
           removedIDs.isEmpty,
           visibleIncoming.allSatisfy({ map[$0.id] == $0 }) {
            return
        }
        for message in visibleIncoming { map[message.id] = message }
        let merged = sortedMessages(Array(map.values))
        if current != merged { messagesBySession[sessionId] = merged }
    }

    private func sortedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }
}
