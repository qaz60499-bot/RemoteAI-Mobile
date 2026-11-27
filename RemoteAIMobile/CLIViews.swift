import SwiftUI
import UIKit

struct CLIModelDetail: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String?
    let source: String?
    let isDefault: Bool?
    let available: Bool?
    let hidden: Bool?
}

struct CLIUpstream: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let host: String
    let models: [String]
    let defaultModel: String?
    let credentialAvailable: Bool
    let health: String
    let source: String?
    let editable: Bool?
    let removable: Bool?
    let availabilityReason: String?
    var cliKind: String? = nil
    var compatibleProtocols: [String]? = nil
    var enabled: Bool? = nil
    var keySet: Bool? = nil
    var keyHint: String? = nil
    var secretRef: String? = nil
    var healthDetail: String? = nil
    var lastCheckedAt: String? = nil
    var modelsUpdatedAt: String? = nil
    var customModels: [String]? = nil
    var hiddenModels: [String]? = nil
    var fetchedModels: [String]? = nil
    var modelDetails: [CLIModelDetail]? = nil
    var revision: Int? = nil
    var inUseByActiveSession: Bool? = nil
    var readOnlyReason: String? = nil
    var canTest: Bool? = nil
    var canRefreshModels: Bool? = nil
    var canManageModels: Bool? = nil
    var canToggleEnabled: Bool? = nil

    var isEnabled: Bool { enabled ?? true }
    var canEdit: Bool { source == "remoteai" && editable == true }
    var canEditSettings: Bool { canManageModels == true || canEdit }
    var canRemove: Bool { removable == true && (source == "remoteai" || source == "discovered") }
}

extension InstanceDescriptor {
    var cliUpstreams: [CLIUpstream] { (try? config["upstreamCatalog"]?.decode([CLIUpstream].self)) ?? [] }
    var cliRecentDirectories: [String] { (try? config["recentDirectories"]?.decode([String].self)) ?? [] }
    var cliUpstreamRevision: Int { config["upstreamCatalogRevision"]?.intValue.map(Int.init) ?? 0 }
    var isManagedCLI: Bool { id == "cloudcode.remoteai" || id == "codex.remoteai" }
}

struct CLIApproval: Decodable, Identifiable {
    let requestId: String
    let kind: String
    let summary: String
    let at: String
    var id: String { requestId }
}

enum CLIStateLabel {
    static func text(_ state: String?) -> String {
        switch state {
        case "initializing": return "正在初始化"
        case "running": return "执行中"
        case "calling_tool": return "正在调用工具"
        case "stopped": return "已停止"
        case "process_exited": return "CLI 进程已退出"
        case "recovery_pending": return "等待新指令验证恢复"
        case "delivery_unknown": return "发送回执未知，禁止重复提交"
        case "waiting_approval": return "等待审批"
        case "waiting_user": return "等待指令"
        case "idle": return "空闲"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "rate_limited": return "请求限流"
        case "disconnected": return "连接中断"
        default: return "状态未知"
        }
    }

    static func taskText(_ state: String?) -> String {
        switch state {
        case "initializing": return "正在初始化"
        case "running": return "执行中"
        case "calling_tool": return "正在调用工具"
        case "waiting_approval": return "等待审批"
        case "waiting_user": return "等待用户输入"
        case "idle": return "空闲"
        case "completed": return "已完成"
        case "stopped": return "已停止"
        case "process_exited": return "CLI 进程已退出"
        case "failed": return "执行失败"
        case "rate_limited": return "暂停（请求限流）"
        case "disconnected": return "连接中断（待核对）"
        case "recovery_pending": return "等待恢复确认"
        case "delivery_unknown": return "等待回执确认"
        default: return "状态未知"
        }
    }

    static func connectionText(_ state: String) -> String {
        switch state {
        case "Connecting": return "正在连接"
        case "Connected": return "已连接"
        case "Reconnecting": return "重连中"
        case "Disconnected": return "已断开"
        case "Offline": return "离线"
        default: return state
        }
    }

    static func syncText(_ state: String) -> String {
        switch state {
        case "Synchronizing": return "同步中"
        case "Rate Limited": return "请求限流"
        case "Retrying": return "重试中"
        case "Recovery Pending": return "等待恢复确认"
        case "Delivery Unknown": return "发送回执未知"
        case "Stale": return "状态已过期"
        case "Synced": return "已同步"
        default: return state
        }
    }

    static func connectionDimension(
        machineState: MachineConnectionState,
        phase: ConnectionDiagnosticPhase,
        agentConnected: Bool?,
        relayConnected: Bool?
    ) -> (code: String, label: String, detail: String, isOnline: Bool) {
        let code: String
        switch (machineState, phase) {
        case (.online, .online), (.online, .loadingRuntimes):
            code = "Connected"
        case (_, .reconnecting), (_, .windowsReconnecting):
            code = "Reconnecting"
        case (.connecting, _):
            code = "Connecting"
        case (_, .relayError), (_, .timedOut):
            code = "Disconnected"
        case (.offline, _):
            code = "Offline"
        default:
            code = "Connected"
        }
        let pcStatus = agentConnected == true ? "电脑 Agent 在线" : (agentConnected == false ? "电脑 Agent 离线" : "电脑 Agent 待核对")
        let relayStatus = relayConnected == true ? "Relay 在线" : (relayConnected == false ? "Relay 断开" : "Relay 待核对")
        return (code, connectionText(code), "\(pcStatus) · \(relayStatus)", code == "Connected")
    }

    static func syncDimension(
        cliState: String?,
        stale: Bool,
        machineOnline: Bool,
        automaticRetry: Bool,
        synchronizing: Bool
    ) -> (code: String, label: String, isWarning: Bool) {
        let code: String
        if cliState == "delivery_unknown" { code = "Delivery Unknown" }
        else if cliState == "rate_limited" { code = "Rate Limited" }
        else if cliState == "recovery_pending" { code = "Recovery Pending" }
        else if automaticRetry { code = "Retrying" }
        else if stale || !machineOnline { code = "Stale" }
        else if synchronizing { code = "Synchronizing" }
        else { code = "Synced" }
        let warn = ["Delivery Unknown", "Rate Limited", "Recovery Pending", "Retrying", "Stale"].contains(code)
        return (code, syncText(code), warn)
    }
}

enum CLIConversationFormatter {
    enum DisplayEntry: Identifiable, Equatable {
        case message(ChatMessage)
        case toolGroup(id: String, items: [ChatMessage])

        var id: String {
            switch self {
            case .message(let m): return "msg-\(m.id)"
            case .toolGroup(let id, _): return id
            }
        }
    }

    static func groupMessages(_ rows: [ChatMessage], search: String, showTechnicalLogs: Bool) -> [DisplayEntry] {
        var dedupedTools = Set<String>()
        let filtered = rows.filter { row in
            if row.kind == .toolEvent {
                let toolKey = "\(row.id)|\(row.toolName ?? "")|\(row.toolStatus ?? "")|\(row.detail ?? "")"
                if !dedupedTools.insert(toolKey).inserted { return false }
            }
            if search.isEmpty { return true }
            return row.text.localizedCaseInsensitiveContains(search)
                || row.detail?.localizedCaseInsensitiveContains(search) == true
                || row.toolName?.localizedCaseInsensitiveContains(search) == true
        }
        var entries: [DisplayEntry] = []
        var toolBuffer: [ChatMessage] = []
        func flushTools() {
            guard !toolBuffer.isEmpty else { return }
            if showTechnicalLogs {
                for item in toolBuffer { entries.append(.message(item)) }
            } else {
                let groupId = "tool-group-\(toolBuffer.first!.id)-\(toolBuffer.count)"
                entries.append(.toolGroup(id: groupId, items: toolBuffer))
            }
            toolBuffer.removeAll(keepingCapacity: true)
        }
        for row in filtered {
            if row.kind == .toolEvent {
                toolBuffer.append(row)
            } else {
                flushTools()
                entries.append(.message(row))
            }
        }
        flushTools()
        return entries
    }

    static func roleDisplayName(_ role: MessageRole, runtimeKind: RuntimeKind) -> String {
        switch role {
        case .user: return "你"
        case .assistant: return runtimeKind.displayName
        case .system: return "系统"
        case .tool: return "技术日志"
        }
    }

    static func readableTime(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func readableISOTime(_ raw: String?) -> String? {
        guard let raw, let parsed = RemoteAIDate.parse(raw) else { return raw }
        return readableTime(parsed)
    }

    static func cleanNaturalText(_ raw: String) -> String {
        CLIErrorRecord.redactSensitiveText(raw.strippingANSIControlSequences())
    }
}

enum CLISessionSection: String, CaseIterable {
    case current = "当前电脑 CLI"
    case subtask = "原生子任务"
    case related = "同进程关联会话（当前身份待确认）"
    case history = "历史与待恢复会话"
}

enum CLISessionDirectory {
    static func needsLiveRefresh(_ config: [String: JSONValue], managed: Bool) -> Bool {
        config["cliMobile"]?.boolValue == true && (managed || (config["activeProcessCount"]?.intValue ?? 1) > 0)
    }
    static func section(_ meta: [String: JSONValue]) -> CLISessionSection {
        if meta["sessionScope"]?.stringValue == "history" || meta["processAlive"]?.boolValue == false || meta["cliState"]?.stringValue == "process_exited" { return .history }
        if meta["nativeRole"]?.stringValue == "subtask" || meta["sessionScope"]?.stringValue == "subtask" { return .subtask }
        if meta["sessionScope"]?.stringValue == "related" { return .related }
        if meta["pid"]?.intValue != nil && meta["stale"]?.boolValue != true { return .current }
        return .history
    }
}

struct CLIRuntimeView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    let runtime: RuntimeDescriptor
    @State private var search = ""
    @State private var activeSheet: CLIRuntimeSheet?
    @State private var visible = false
    private var instances: [InstanceDescriptor] { store.instances.filter { $0.runtimeId == runtime.id && $0.config["cliMobile"]?.boolValue == true } }
    private var connectionSummary: (code: String, label: String, detail: String, isOnline: Bool) {
        CLIStateLabel.connectionDimension(
            machineState: store.machine.state,
            phase: store.connectionPhase,
            agentConnected: store.desktopAgentConnected,
            relayConnected: store.desktopRelayConnected
        )
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接：\(connectionSummary.label)（\(connectionSummary.code)）")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(connectionSummary.isOnline ? .green : .orange)
                    Text(connectionSummary.detail)
                        .font(.caption).foregroundColor(.secondary)
                    Text("桌面会话先按原身份观察；旧进程退出后可恢复同一会话。RemoteAI 托管会话支持指令、审批和停止。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                ForEach(instances.filter(\.isManagedCLI)) { instance in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { activeSheet = .create(instance) } label: { Label("新建 \(runtime.kind.displayName) 会话", systemImage: "plus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("cli-create-session")
                            .disabled(store.machine.state != .online)
                        Button { activeSheet = .manage(instance) } label: { Label("管理模型 API 中转站", systemImage: "server.rack") }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("cli-manage-upstreams")
                            .disabled(store.machine.state != .online)
                    }
                }
                Button("加载或刷新历史会话") { Task { await refresh(includeHistory: true) } }
            }
            ForEach(CLISessionSection.allCases, id: \.self) { category in
                let rows = sessions(in: category)
                if !rows.isEmpty {
                    Section("\(category.rawValue) · \(rows.count)") {
                        if category == .current {
                            sessionLinks(rows)
                        } else {
                            DisclosureGroup("查看\(category.rawValue)") { sessionLinks(rows) }
                        }
                    }
                }
            }
            if let error = store.errors["runtime.\(runtime.id)"] { Text(error).foregroundColor(.red) }
        }
        .navigationTitle(runtime.kind.displayName)
        .searchable(text: $search, prompt: "搜索会话或工作目录")
        .refreshable { await refresh() }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: visible && scenePhase == .active && store.machine.state == .online) {
            guard visible && scenePhase == .active && store.machine.state == .online else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create(let instance):
                CLICreateView(runtime: runtime, instance: instance).environmentObject(store)
            case .manage(let instance):
                NavigationView {
                    CLIUpstreamManagementView(runtime: runtime, instance: instance).environmentObject(store)
                }
            }
        }
    }
    private func refresh(includeHistory: Bool = false) async {
        await store.refreshRuntime(runtime)
        let live = instances.filter { CLISessionDirectory.needsLiveRefresh($0.config, managed: $0.isManagedCLI) }
        for instance in live { await store.refreshSessions(runtime: runtime, instance: instance) }
        if includeHistory {
            for instance in instances where !live.contains(where: { $0.id == instance.id }) {
                guard !Task.isCancelled else { return }
                await store.refreshSessions(runtime: runtime, instance: instance)
            }
        }
    }
    private func sessions(in category: CLISessionSection) -> [SessionDescriptor] {
        let ids = Set(instances.map(\.id))
        return store.sessions.filter { session in
            ids.contains(session.instanceId) && CLISessionDirectory.section(store.cliStatus[session.id] ?? session.cliMetadata ?? [:]) == category
                && (search.isEmpty || session.title.localizedCaseInsensitiveContains(search) || (session.workingDirectory ?? "").localizedCaseInsensitiveContains(search))
        }.sorted { $0.orderingDate > $1.orderingDate }
    }
    @ViewBuilder private func sessionLinks(_ rows: [SessionDescriptor]) -> some View {
        ForEach(rows) { session in
            if let instance = instances.first(where: { $0.id == session.instanceId }) {
                NavigationLink(destination: CLIConversationView(runtime: runtime, instance: instance, session: session)) {
                    CLISessionRowView(session: session, store: store)
                }
            }
        }
    }
}

struct CLISessionRowView: View {
    let session: SessionDescriptor
    @ObservedObject var store: WorkspaceStore

    private var meta: [String: JSONValue] { store.cliStatus[session.id] ?? session.cliMetadata ?? [:] }
    private var cliState: String? { meta["cliState"]?.stringValue }
    private var stale: Bool { meta["stale"]?.boolValue == true || store.machine.state != .online }
    private var syncInfo: (code: String, label: String, isWarning: Bool) {
        CLIStateLabel.syncDimension(
            cliState: cliState,
            stale: stale,
            machineOnline: store.machine.state == .online,
            automaticRetry: meta["automaticProviderRetry"]?.boolValue == true,
            synchronizing: false
        )
    }
    private var unrecoveredErrorCount: Int {
        (store.cliErrorHistoryBySession[session.id] ?? []).filter { !$0.recovered }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title).lineLimit(2)
                Spacer()
                if unrecoveredErrorCount > 0 {
                    Text("异常 \(unrecoveredErrorCount)")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15)).foregroundColor(.red).cornerRadius(6)
                }
            }
            if let pid = meta["pid"]?.intValue {
                Text("PID \(pid) · \(session.threadId.map { String($0.prefix(8)) } ?? "原生身份待确认")")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text("\(meta["controlMode"]?.stringValue == "managed" ? "可控制" : "只读") · 任务：\(CLIStateLabel.taskText(cliState)) · 同步：\(syncInfo.label)")
                .font(.caption)
                .foregroundColor(syncInfo.isWarning ? .orange : .secondary)
            if let stage = meta["progressStage"]?.stringValue, !stage.isEmpty {
                Text("阶段：\(stage)").font(.caption2).foregroundColor(.secondary)
            }
            if let cwd = session.workingDirectory { Text(cwd).font(.caption2).foregroundColor(.secondary).lineLimit(1) }
            if let instruction = meta["latestUserInstruction"]?.stringValue, !instruction.isEmpty {
                Text("指令：\(instruction)").font(.caption).lineLimit(2)
            }
            if let output = meta["latestAssistantOutput"]?.stringValue, !output.isEmpty {
                Text(output).font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
            if let parent = meta["parentNativeSessionId"]?.stringValue {
                Text("所属会话：\(parent.prefix(8))").font(.caption2).foregroundColor(.secondary)
            }
            let modelText = meta["effectiveModel"]?.stringValue ?? meta["model"]?.stringValue ?? session.modelId
            let hostText = meta["upstreamLabel"]?.stringValue ?? meta["upstreamHost"]?.stringValue
            if modelText != nil || hostText != nil {
                Text([modelText, hostText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let timeText = CLIConversationFormatter.readableISOTime(meta["lastProgressAt"]?.stringValue ?? meta["lastObservedAt"]?.stringValue) {
                Text(stale ? "最后更新：\(timeText)（状态可能过期）" : "最新输出：\(timeText)")
                    .font(.caption2).foregroundColor(stale ? .orange : .secondary)
            }
        }.padding(.vertical, 4)
    }
}

private enum CLIRuntimeSheet: Identifiable {
    case create(InstanceDescriptor)
    case manage(InstanceDescriptor)

    var id: String {
        switch self {
        case .create(let instance): return "create.\(instance.id)"
        case .manage(let instance): return "manage.\(instance.id)"
        }
    }
}

struct CLICreateView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) var dismiss
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    @State private var upstreamId = ""
    @State private var model = ""
    @State private var title = ""
    @State private var busy = false
    @State private var projectPath = ""
    @State private var allowProjectWrites = false
    private var selected: CLIUpstream? { instance.cliUpstreams.first { $0.id == upstreamId } }
    var body: some View {
        NavigationView {
            Form {
                Section("Windows 会话") {
                    TextField("会话名称", text: $title)
                    TextField("项目完整路径", text: $projectPath).autocapitalization(.none).disableAutocorrection(true)
                    if !instance.cliRecentDirectories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(instance.cliRecentDirectories, id: \.self) { dir in
                                    Button(dir.split(separator: "\\").last.map(String.init) ?? dir) {
                                        projectPath = dir
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    Toggle("授权此项目文件修改与测试", isOn: $allowProjectWrites)
                    Text("授权仅作用于所选项目；工具审批仍保留。Windows 会检查项目是否在已授权范围内。").font(.caption)
                }
                Section("模型 API 中转站") {
                    Picker("使用电脑现有配置", selection: $upstreamId) {
                        Text("请选择").tag("")
                        ForEach(instance.cliUpstreams.filter(\.credentialAvailable)) { item in Text("\(item.label) · \(item.host)").tag(item.id) }
                    }
                    if let selected {
                        Text("凭据保留在 Windows（\(selected.keyHint ?? "受保护")） · \(selected.health == "unknown" ? "连接尚未验证" : selected.health)").font(.caption)
                        if let detail = selected.healthDetail, !detail.isEmpty {
                            Text(detail).font(.caption2).foregroundColor(.secondary)
                        }
                        Picker("模型", selection: $model) { ForEach(selected.models, id: \.self) { Text($0).tag($0) } }
                    }
                    let unavailable = instance.cliUpstreams.filter { !$0.credentialAvailable }
                    if !instance.cliUpstreams.contains(where: \.credentialAvailable) {
                        Text(unavailable.first?.availabilityReason
                             ?? "此 Windows 配置没有可复用于新会话的凭据。请在 Windows 添加可复用的模型 API 凭据后重试。")
                            .font(.caption).foregroundColor(.secondary)
                    } else if !unavailable.isEmpty {
                        Text("另有 \(unavailable.count) 个已停用或不可用配置，可在“管理模型 API 中转站”中查看原因。")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Text("仅用于此会话的新调用。Cloudflare RemoteAI Relay 负责加密传输，与这里的模型 API 中转站独立。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if let error = store.errors[instance.id] { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("新建 CLI 会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "创建中…" : "创建") {
                        busy = true
                        Task {
                            if await store.createSession(runtime: runtime, instance: instance, title: title, model: model, codexProjectPath: projectPath, upstreamId: upstreamId, cliPermissionMode: allowProjectWrites ? "workspace-write" : "read-only") { dismiss() }
                            busy = false
                        }
                    }.disabled(busy || selected == nil || model.isEmpty)
                }
            }
            .onChange(of: upstreamId) { _ in model = selected?.defaultModel ?? selected?.models.first ?? "" }
            .onAppear { upstreamId = instance.cliUpstreams.first(where: \.credentialAvailable)?.id ?? ""; model = selected?.defaultModel ?? selected?.models.first ?? ""; projectPath = instance.config["projectPath"]?.stringValue ?? "" }
        }
    }
}

struct CLIUpstreamManagementView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    @State private var catalog: [CLIUpstream] = []
    @State private var loading = false
    @State private var deleting = false
    @State private var actionBusyId: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var showEditor = false
    @State private var editingUpstream: CLIUpstream?
    @State private var deleteCandidate: CLIUpstream?
    @State private var confirmDelete = false
    @State private var deleteRetryTarget: CLIUpstream?
    @State private var deleteOperationId: UUID?

    private var currentRevision: Int {
        store.instances.first(where: { $0.id == instance.id })?.cliUpstreamRevision ?? instance.cliUpstreamRevision
    }

    var body: some View {
        List {
            Section {
                Text(store.machine.state == .online
                     ? "Windows 权威配置在线 · 双向实时同步 · 版本 r\(currentRevision)"
                     : "Windows 当前离线，等待重连；离线期间不可修改 Windows API 配置。")
                    .font(.caption)
                    .foregroundColor(store.machine.state == .online ? .green : .orange)
                Text("手机与电脑共用同一套 Windows 权威配置，API Key 仅由 Windows DPAPI 保管，不回传明文。")
                    .font(.footnote).foregroundColor(.secondary)
                Text("删除自定义配置会从 Windows 移除；隐藏外部导入配置仅在 RemoteAI 隐藏，不改动原配置。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            if loading {
                Section { ProgressView("正在读取中转站列表") }
            }
            if deleting {
                Section { ProgressView("正在移除中转站") }
            }
            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundColor(.red) }
            }
            if let statusMessage {
                Section { Text(statusMessage).font(.caption).foregroundColor(.secondary) }
            }
            if !loading && catalog.isEmpty && errorMessage == nil {
                Section { Text("尚未配置模型 API 中转站。添加自定义中转站，或在 Windows 中配置后刷新。")
                    .font(.footnote).foregroundColor(.secondary) }
            }
            ForEach(catalog) { item in
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.label).font(.headline)
                            Spacer()
                            Text(item.isEnabled ? "已启用" : "已停用")
                                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background((item.isEnabled ? Color.green : Color.orange).opacity(0.15))
                                .foregroundColor(item.isEnabled ? .green : .orange)
                                .cornerRadius(6)
                            if item.inUseByActiveSession == true {
                                Text("任务使用中")
                                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15)).foregroundColor(.blue).cornerRadius(6)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(item.host).font(.caption).textSelection(.enabled)
                            if let protocols = item.compatibleProtocols, !protocols.isEmpty {
                                Text("· \(protocols.joined(separator: ", "))")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Text("\(item.sourceLabel) · \(credentialStatus(for: item))")
                            .font(.caption2).foregroundColor(.secondary)
                        if item.keyHint != nil || item.secretRef != nil {
                            let hintPart = item.keyHint.map { "Key 掩码：\($0)" }
                            let refPart = item.secretRef.map { "引用：\(String($0.prefix(24)))" }
                            Text([hintPart, refPart].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        if !item.credentialAvailable, let availabilityReason = item.availabilityReason, !availabilityReason.isEmpty {
                            Text(availabilityReason).font(.caption2).foregroundColor(.orange)
                        }
                        if let readOnlyReason = item.readOnlyReason, !readOnlyReason.isEmpty {
                            Text(readOnlyReason).font(.caption2).foregroundColor(.secondary)
                        }
                        if !item.models.isEmpty {
                            Text("可用模型（\(item.models.count)）：\(item.models.joined(separator: ", "))").font(.caption2).foregroundColor(.secondary)
                        }
                        if let custom = item.customModels, !custom.isEmpty {
                            Text("自定义模型：\(custom.joined(separator: ", "))").font(.caption2).foregroundColor(.secondary)
                        }
                        if let defaultModel = item.defaultModel, !defaultModel.isEmpty {
                            Text("默认模型：\(defaultModel)").font(.caption2).foregroundColor(.secondary)
                        }
                        if let updated = CLIConversationFormatter.readableISOTime(item.modelsUpdatedAt) {
                            Text("模型目录更新：\(updated)").font(.caption2).foregroundColor(.secondary)
                        }
                        if item.health != "unknown" || (item.healthDetail != nil && !item.healthDetail!.isEmpty) {
                            Text("检测状态：\(item.health)\(item.healthDetail.map { " · \($0)" } ?? "")")
                                .font(.caption2)
                                .foregroundColor(item.health == "verified" ? .green : (item.health == "failed" || item.health == "upstream-policy-rejected" ? .red : .secondary))
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            if item.canTest != false {
                                Button(actionBusyId == item.id ? "处理中…" : "测试") {
                                    Task { await probeUpstream(action: "testCLIUpstream", item: item) }
                                }.disabled(actionBusyId != nil || deleting || store.machine.state != .online)
                            }
                            if item.canRefreshModels == true {
                                Button("刷新模型") {
                                    Task { await probeUpstream(action: "refreshCLIUpstreamModels", item: item) }
                                }.disabled(actionBusyId != nil || deleting || store.machine.state != .online)
                            }
                            if item.canToggleEnabled != false {
                                Button(item.isEnabled ? "停用" : "启用") {
                                    Task { await toggleEnabled(item) }
                                }.disabled(actionBusyId != nil || deleting || store.machine.state != .online)
                            }
                            if item.canEditSettings {
                                Button(item.canEdit ? "编辑" : "模型设置") {
                                    editingUpstream = item
                                    showEditor = true
                                }.disabled(actionBusyId != nil || deleting || deleteRetryTarget != nil || store.machine.state != .online)
                            }
                            if item.canRemove {
                                Button(item.source == "discovered" ? "隐藏" : "删除", role: .destructive) {
                                    deleteCandidate = item
                                    confirmDelete = true
                                }.disabled(actionBusyId != nil || deleting || deleteRetryTarget != nil || store.machine.state != .online)
                            }
                        }
                    }
                }
            }
            if let deleteRetryTarget, let deleteOperationId, !deleting {
                Section {
                    Button("使用相同操作重试 \(deleteRetryTarget.label)") {
                        Task { await remove(deleteRetryTarget, operationId: deleteOperationId) }
                    }.disabled(store.machine.state != .online)
                }
            }
        }
        .navigationTitle("模型 API 中转站")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editingUpstream = nil; showEditor = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加自定义中转站")
                    .disabled(deleting || deleteRetryTarget != nil || store.machine.state != .online)
            }
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismissSheet() } }
        }
        .refreshable { await loadCatalog() }
        .task { await loadCatalog() }
        .onChange(of: store.upstreamCatalogRevision) { _ in
            if let latest = store.instances.first(where: { $0.id == instance.id })?.cliUpstreams, !latest.isEmpty {
                catalog = latest
            }
        }
        .sheet(isPresented: $showEditor, onDismiss: { Task { await loadCatalog() } }) {
            let savedMessage = editingUpstream == nil ? "已添加自定义中转站。" : "已更新中转站配置。"
            CLIUpstreamEditorView(runtime: runtime, instance: instance, upstream: editingUpstream) {
                statusMessage = savedMessage
            }
                .environmentObject(store)
        }
        .confirmationDialog(deleteConfirmationTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteCandidate?.source == "discovered" ? "隐藏导入中转站" : "删除自定义中转站", role: .destructive) {
                guard let item = deleteCandidate else { return }
                let operationId = UUID()
                deleteRetryTarget = item
                deleteOperationId = operationId
                Task { await remove(item, operationId: operationId) }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(deleteCandidate?.source == "discovered"
                 ? "仅在此电脑的 RemoteAI 配置中隐藏此导入中转站；Windows 的来源配置不会更改。"
                 : "从此电脑的 RemoteAI 配置中删除此自定义中转站，并清理不再使用的 DPAPI 凭据。")
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var deleteConfirmationTitle: String {
        deleteCandidate?.source == "discovered" ? "隐藏此导入中转站？" : "删除此自定义中转站？"
    }

    private func credentialStatus(for item: CLIUpstream) -> String {
        if item.keySet == true || item.credentialAvailable { return "凭据由 Windows 保管" }
        return item.availabilityReason == nil ? "没有可复用凭据" : "现有凭据不可复用"
    }

    private func dismissSheet() {
        dismiss()
    }

    @MainActor
    private func loadCatalog() async {
        loading = true
        defer { loading = false }
        let outcome = await store.cliUpstreamAction(runtime: runtime, instance: instance, action: "listCLIUpstreams")
        guard outcome.succeeded else {
            errorMessage = outcome.errorMessage ?? "读取中转站列表失败。"
            return
        }
        guard let result = outcome.result, let rows = try? result.decode([CLIUpstream].self) else {
            errorMessage = "Windows Agent 返回的中转站列表无法识别。"
            return
        }
        catalog = rows
        errorMessage = nil
    }

    @MainActor
    private func probeUpstream(action: String, item: CLIUpstream) async {
        actionBusyId = item.id
        errorMessage = nil
        statusMessage = nil
        defer { actionBusyId = nil }
        let outcome = await store.cliUpstreamAction(
            runtime: runtime,
            instance: instance,
            action: action,
            payload: ["id": .string(item.id)]
        )
        guard outcome.succeeded else {
            errorMessage = outcome.errorMessage ?? "检测失败。"
            return
        }
        if let rows = outcome.result?.objectValue?["upstreams"], let decoded = try? rows.decode([CLIUpstream].self) {
            catalog = decoded
        }
        if action == "testCLIUpstream" {
            let ok = outcome.result?.objectValue?["ok"]?.boolValue == true
            let detail = outcome.result?.objectValue?["detail"]?.stringValue ?? ""
            statusMessage = ok ? "检测可用：\(detail)" : "检测异常：\(detail)"
        } else {
            let refreshed = outcome.result?.objectValue?["refreshed"]?.boolValue == true
            let count = outcome.result?.objectValue?["modelsCount"]?.intValue ?? 0
            let msg = outcome.result?.objectValue?["message"]?.stringValue
            statusMessage = refreshed ? "已同步 \(count) 个模型。" : (msg ?? "模型列表未更新。")
        }
    }

    @MainActor
    private func toggleEnabled(_ item: CLIUpstream) async {
        actionBusyId = item.id
        errorMessage = nil
        statusMessage = nil
        defer { actionBusyId = nil }
        var payload: [String: JSONValue] = [
            "id": .string(item.id),
            "enabled": .bool(!item.isEnabled),
        ]
        if let rev = item.revision {
            payload["expectedRevision"] = .number(Double(rev))
        }
        let outcome = await store.cliUpstreamAction(
            runtime: runtime,
            instance: instance,
            action: "saveCLIUpstream",
            payload: payload,
            operationId: UUID()
        )
        guard outcome.succeeded else {
            errorMessage = outcome.errorMessage ?? "切换启用状态失败。"
            return
        }
        if let rows = outcome.result?.objectValue?["upstreams"], let decoded = try? rows.decode([CLIUpstream].self) {
            catalog = decoded
        } else {
            await loadCatalog()
        }
        statusMessage = !item.isEnabled ? "已启用 \(item.label)。" : "已停用 \(item.label)（不影响正在运行的任务）。"
    }

    @MainActor
    private func remove(_ item: CLIUpstream, operationId: UUID) async {
        guard item.canRemove else {
            errorMessage = "此中转站不允许从手机管理。"
            return
        }
        deleting = true
        errorMessage = nil
        statusMessage = nil
        defer { deleting = false }
        var payload: [String: JSONValue] = ["id": .string(item.id)]
        if let rev = item.revision { payload["expectedRevision"] = .number(Double(rev)) }
        let outcome = await store.cliUpstreamAction(
            runtime: runtime,
            instance: instance,
            action: "deleteCLIUpstream",
            payload: payload,
            operationId: operationId
        )
        guard outcome.succeeded else {
            errorMessage = outcome.errorMessage ?? "移除中转站失败。"
            if !outcome.deliveryUnknown {
                deleteRetryTarget = nil
                deleteOperationId = nil
            }
            return
        }
        if let rows = outcome.result?.objectValue?["upstreams"], let decoded = try? rows.decode([CLIUpstream].self) {
            catalog = decoded
        } else {
            await loadCatalog()
        }
        let hidden = outcome.result?.objectValue?["hidden"]?.boolValue == true
        statusMessage = hidden ? "已隐藏导入中转站；Windows 来源配置保持不变。" : "已从此电脑的 RemoteAI 配置中删除自定义中转站。"
        deleteRetryTarget = nil
        deleteOperationId = nil
        deleteCandidate = nil
        errorMessage = nil
    }
}

private extension CLIUpstream {
    var sourceLabel: String {
        switch source {
        case .some("nativecloud"): return "Cloud Code 原有路由与会话授权"
        case .some("remoteai"): return "RemoteAI 自定义配置"
        case .some("discovered"): return "Windows 导入配置"
        default: return "Windows 现有配置"
        }
    }
}

struct CLIUpstreamEditorView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let upstream: CLIUpstream?
    let onSaved: () -> Void
    @State private var label: String
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelsText: String
    @State private var customModelsText: String
    @State private var hiddenModelsText: String
    @State private var defaultModel: String
    @State private var enabled: Bool
    @State private var busy = false
    @State private var retrySamePayload = false
    @State private var operationId: UUID?
    @State private var errorMessage: String?

    private var isCustomStation: Bool { upstream == nil || upstream?.canEdit == true }

    init(runtime: RuntimeDescriptor, instance: InstanceDescriptor, upstream: CLIUpstream?, onSaved: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.instance = instance
        self.upstream = upstream
        self.onSaved = onSaved
        _label = State(initialValue: upstream?.label ?? "")
        _modelsText = State(initialValue: upstream?.models.joined(separator: ", ") ?? "")
        _customModelsText = State(initialValue: upstream?.customModels?.joined(separator: ", ") ?? "")
        _hiddenModelsText = State(initialValue: upstream?.hiddenModels?.joined(separator: ", ") ?? "")
        _defaultModel = State(initialValue: upstream?.defaultModel ?? upstream?.models.first ?? "")
        _enabled = State(initialValue: upstream?.enabled ?? true)
    }

    var body: some View {
        NavigationView {
            Form {
                if isCustomStation {
                    Section("RemoteAI 自定义中转站") {
                        TextField("名称", text: $label)
                        TextField(upstream == nil ? "服务端 URL" : "服务端 URL（留空保留现有地址）", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(upstream == nil
                             ? "请输入 API Base URL。Windows 不会把 API Key 或完整 URL 回传到手机。"
                             : "当前主机：\(upstream?.host ?? "")。留空 URL 和 API Key 将保留 Windows 中的当前配置。")
                            .font(.caption).foregroundColor(.secondary)
                        SecureField(upstream == nil ? "API Key（必填）" : "API Key（留空以保留现有密钥）", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("模型 ID（以逗号分隔）", text: $modelsText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("默认模型", text: $defaultModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("启用此中转站", isOn: $enabled)
                    }
                } else if let upstream {
                    Section("外部配置设置（只读源）") {
                        Text(upstream.label).font(.headline)
                        Text(upstream.host).font(.caption).foregroundColor(.secondary)
                        Text(upstream.readOnlyReason ?? "外部来源配置为只读，无法修改地址或密钥；可在 RemoteAI 内控制启用状态和模型列表。")
                            .font(.caption).foregroundColor(.orange)
                        Toggle("允许在 RemoteAI 新建会话中使用", isOn: $enabled)
                        TextField("自定义补充模型（以逗号分隔）", text: $customModelsText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("本地隐藏模型（以逗号分隔，不改上游）", text: $hiddenModelsText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("默认模型", text: $defaultModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section {
                    Text("API Key 仅在本次加密请求中发送给 Windows；手机不保存它，也不会写入操作回执或诊断日志。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.caption).foregroundColor(.red) }
                }
            }
            .disabled(busy || retrySamePayload)
            .navigationTitle(upstream == nil ? "添加中转站" : (isCustomStation ? "编辑中转站" : "模型与启用设置"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        Task { await save() }
                    }.disabled(busy)
                }
            }
            .onDisappear { apiKey = "" }
        }
    }

    private var saveTitle: String {
        if busy { return "保存中…" }
        return retrySamePayload ? "使用相同内容重试" : "保存"
    }

    private func splitModels(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func save() async {
        var payload: [String: JSONValue] = ["enabled": .bool(enabled)]
        if let upstream {
            payload["id"] = .string(upstream.id)
            if let rev = upstream.revision { payload["expectedRevision"] = .number(Double(rev)) }
        }

        if isCustomStation {
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if upstream == nil || !cleanURL.isEmpty {
                let urlIsValid: Bool
                if let url = URL(string: cleanURL), let scheme = url.scheme?.lowercased() {
                    urlIsValid = (scheme == "https" || scheme == "http") && url.host != nil && url.user == nil && url.password == nil
                } else {
                    urlIsValid = false
                }
                guard urlIsValid else { errorMessage = "请输入有效的 HTTP 或 HTTPS 服务端 URL。"; return }
                payload["baseURL"] = .string(cleanURL)
            }
            let models = splitModels(modelsText)
            let cleanDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLabel.isEmpty else { errorMessage = "请输入中转站名称。"; return }
            guard !models.isEmpty else { errorMessage = "至少填写一个模型 ID。"; return }
            guard models.contains(cleanDefaultModel) else { errorMessage = "默认模型必须出现在模型列表中。"; return }
            guard upstream != nil || !apiKey.isEmpty else { errorMessage = "添加自定义中转站时必须填写 API Key。"; return }

            payload["label"] = .string(cleanLabel)
            payload["models"] = .array(models.map { .string($0) })
            payload["defaultModel"] = .string(cleanDefaultModel)
            if !apiKey.isEmpty { payload["apiKey"] = .string(apiKey) }
        } else {
            let customModels = splitModels(customModelsText)
            let hiddenModels = splitModels(hiddenModelsText)
            let cleanDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
            payload["customModels"] = .array(customModels.map { .string($0) })
            payload["hiddenModels"] = .array(hiddenModels.map { .string($0) })
            if !cleanDefaultModel.isEmpty {
                payload["defaultModel"] = .string(cleanDefaultModel)
            }
        }

        let stableOperationId = operationId ?? UUID()
        operationId = stableOperationId
        busy = true
        errorMessage = nil
        defer { busy = false }
        let outcome = await store.cliUpstreamAction(
            runtime: runtime,
            instance: instance,
            action: "saveCLIUpstream",
            payload: payload,
            operationId: stableOperationId
        )
        if outcome.succeeded {
            apiKey = ""
            onSaved()
            dismiss()
            return
        }
        errorMessage = outcome.errorMessage ?? "保存中转站失败。"
        retrySamePayload = outcome.deliveryUnknown
        if !outcome.deliveryUnknown { operationId = nil }
    }
}

struct CLINativeRecoveryView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) var dismiss
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let session: SessionDescriptor
    @State private var upstreamId = ""
    @State private var model = ""
    @State private var originalStopped = false
    @State private var allowWrites = false
    @State private var busy = false
    private var managed: InstanceDescriptor? { store.instances.first { $0.runtimeId == runtime.id && $0.isManagedCLI } }
    private var upstreams: [CLIUpstream] { managed?.cliUpstreams.filter(\.credentialAvailable) ?? [] }
    private var selected: CLIUpstream? { upstreams.first { $0.id == upstreamId } }
    var body: some View {
        NavigationView {
            Form {
                Section("原会话") {
                    Text(session.title)
                    Text(session.workingDirectory ?? "项目目录未知").font(.caption)
                    Toggle("我已在电脑端结束原任务", isOn: $originalStopped)
                    Text("Windows 会再次验证原进程、会话身份和项目占用。历史导入独立的受控会话，随后使用 CLI 原生恢复接口；不会自动重发旧指令。").font(.caption)
                }
                Section("恢复配置") {
                    Picker("中转站", selection: $upstreamId) {
                        Text("请选择").tag("")
                        ForEach(upstreams) { Text("\($0.label) · \($0.host)").tag($0.id) }
                    }
                    if let selected { Picker("模型", selection: $model) { ForEach(selected.models, id: \.self) { Text($0).tag($0) } } }
                    Toggle("授权此项目文件修改与测试", isOn: $allowWrites)
                }
                if let error = store.errors[session.id] { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("恢复桌面会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "验证中…" : "准备恢复") {
                        busy = true
                        Task {
                            let ok = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "recoverCLISession", payload: ["confirmOriginalStopped": .bool(true), "upstreamId": .string(upstreamId), "model": .string(model), "permissionMode": .string(allowWrites ? "workspace-write" : "read-only")])
                            if ok { await store.refreshRuntime(runtime); dismiss() }
                            busy = false
                        }
                    }.disabled(busy || !originalStopped || selected == nil || model.isEmpty)
                }
            }
            .onChange(of: upstreamId) { _ in model = selected?.defaultModel ?? selected?.models.first ?? "" }
            .task { await store.refreshRuntime(runtime) }
        }
    }
}

struct CLINextCallView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) var dismiss
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let session: SessionDescriptor
    @State private var upstreamId = ""
    @State private var model = ""
    @State private var busy = false
    private var selected: CLIUpstream? { instance.cliUpstreams.first { $0.id == upstreamId } }
    var body: some View {
        NavigationView {
            Form {
                Picker("中转站", selection: $upstreamId) {
                    ForEach(instance.cliUpstreams.filter(\.credentialAvailable)) { Text("\($0.label) · \($0.host)").tag($0.id) }
                }
                if let selected { Picker("模型", selection: $model) { ForEach(selected.models, id: \.self) { Text($0).tag($0) } } }
                Text("设置用于此会话的下一次调用。切换中转站或 Claude 模型前，请先在会话菜单重置已停止的连接。历史与错误会保留，成功调用后才能确认配置可用。").font(.caption)
                if let error = store.errors[session.id] { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("下一次调用")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "保存中…" : "应用") {
                        busy = true
                        Task {
                            if await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "configureSession", payload: ["upstreamId": .string(upstreamId), "model": .string(model)]) { dismiss() }
                            busy = false
                        }
                    }.disabled(busy || selected == nil || model.isEmpty)
                }
            }
            .onAppear { upstreamId = session.cliMetadata?["upstreamId"]?.stringValue ?? ""; model = session.cliMetadata?["model"]?.stringValue ?? "" }
            .onChange(of: upstreamId) { _ in model = selected?.defaultModel ?? selected?.models.first ?? "" }
        }
    }
}

struct CLIConversationView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let session: SessionDescriptor
    @State private var text = ""
    @State private var search = ""
    @State private var confirmStop = false
    @State private var confirmRecovery = false
    @State private var approval: CLIApproval?
    @State private var busy = false
    @State private var recoveryBusy = false
    @State private var showProcessDetails = false
    @State private var showNativeRecovery = false
    @State private var showNextCall = false
    @State private var showTechnicalLogs = false
    @State private var showErrorSheet = false
    @State private var expandedToolGroups = Set<String>()
    @State private var userAnswer = ""
    @State private var followsLatest = true
    private var snapshot: [String: JSONValue] { store.cliStatus[session.id] ?? session.cliMetadata ?? [:] }
    private var managedRuntime: Bool {
        (instance.id == "cloudcode.remoteai" && instance.runtimeId == runtime.id && runtime.kind == .cloudcode)
            || (instance.id == "codex.remoteai" && instance.runtimeId == runtime.id && runtime.kind == .codex)
    }
    private var controllable: Bool { managedRuntime && snapshot["controlMode"]?.stringValue == "managed" }
    private var cliState: String? { snapshot["cliState"]?.stringValue }
    private var active: Bool { ["initializing", "running", "calling_tool", "waiting_approval", "waiting_user"].contains(cliState ?? "") }
    private var approvals: [CLIApproval] { (try? snapshot["pendingApprovals"]?.decode([CLIApproval].self)) ?? [] }
    private var isStale: Bool { snapshot["stale"]?.boolValue == true || store.machine.state != .online }
    private var connectionInfo: (code: String, label: String, detail: String, isOnline: Bool) {
        CLIStateLabel.connectionDimension(
            machineState: store.machine.state,
            phase: store.connectionPhase,
            agentConnected: store.desktopAgentConnected,
            relayConnected: store.desktopRelayConnected
        )
    }
    private var syncInfo: (code: String, label: String, isWarning: Bool) {
        CLIStateLabel.syncDimension(
            cliState: cliState,
            stale: isStale,
            machineOnline: store.machine.state == .online,
            automaticRetry: snapshot["automaticProviderRetry"]?.boolValue == true,
            synchronizing: false
        )
    }
    private var combinedErrors: [CLIErrorRecord] {
        var rows = store.cliErrorHistoryBySession[session.id] ?? []
        if let rawHistory = snapshot["errorHistory"]?.arrayValue {
            let fallbackModel = snapshot["effectiveModel"]?.stringValue ?? snapshot["model"]?.stringValue
            let fallbackHost = snapshot["upstreamHost"]?.stringValue
            let fallbackLabel = snapshot["upstreamLabel"]?.stringValue
            for item in rawHistory {
                guard let obj = item.objectValue else { continue }
                let rec = CLIErrorRecord.fromJSON(obj, fallbackSessionId: session.id, fallbackModel: fallbackModel, fallbackHost: fallbackHost, fallbackLabel: fallbackLabel)
                if !rows.contains(where: { $0.id == rec.id }) { rows.append(rec) }
            }
        }
        if let errObj = snapshot["providerError"]?.objectValue {
            let rec = CLIErrorRecord.fromJSON(
                errObj,
                fallbackSessionId: session.id,
                fallbackModel: snapshot["effectiveModel"]?.stringValue ?? snapshot["model"]?.stringValue,
                fallbackHost: snapshot["upstreamHost"]?.stringValue,
                fallbackLabel: snapshot["upstreamLabel"]?.stringValue
            )
            if !rows.contains(where: { $0.id == rec.id }) { rows.append(rec) }
        }
        for globalErr in store.globalTransportErrors {
            if !rows.contains(where: { $0.id == globalErr.id }) { rows.append(globalErr) }
        }
        return rows.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }
    private var activeErrors: [CLIErrorRecord] { combinedErrors.filter { !$0.recovered } }
    private var rawMessages: [ChatMessage] {
        let rows = store.messagesBySession[session.id] ?? []
        let canonicalTools = Set(rows.filter { $0.id.hasPrefix("cli-tool-") }.map { "tool-\(session.id)-\($0.id)" })
        return rows.filter { !canonicalTools.contains($0.id) }.map { row in
            if row.role == .tool, row.id.hasPrefix("cli-tool-"), row.kind != .toolEvent {
                return ServerMessage(messageId: row.id, sessionId: row.sessionId, role: "tool", content: row.text, externalId: nil, createdAt: row.createdAt).chatMessage
            }
            return row
        }
    }
    private var displayEntries: [CLIConversationFormatter.DisplayEntry] {
        CLIConversationFormatter.groupMessages(rawMessages, search: search, showTechnicalLogs: showTechnicalLogs)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    Text(snapshot["sessionTitle"]?.stringValue ?? session.title).font(.headline).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(controllable ? "可控制" : "只读")
                        .font(.caption2).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(controllable ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.15))
                        .foregroundColor(controllable ? .blue : .secondary)
                        .cornerRadius(6)
                }
                Text("连接：\(connectionInfo.label)（\(connectionInfo.detail)）")
                    .font(.caption).foregroundColor(connectionInfo.isOnline ? .green : .orange)
                HStack(spacing: 6) {
                    Text("任务：\(CLIStateLabel.taskText(cliState))")
                        .font(.subheadline).fontWeight(.semibold)
                    if let stage = snapshot["progressStage"]?.stringValue, !stage.isEmpty {
                        Text("· \(stage)").font(.caption).foregroundColor(.secondary)
                    }
                }
                Text("同步：\(syncInfo.label)（\(syncInfo.code)）")
                    .font(.caption).foregroundColor(syncInfo.isWarning ? .orange : .secondary)
                if let progressTime = CLIConversationFormatter.readableISOTime(snapshot["lastProgressAt"]?.stringValue) {
                    Text("最新输出时间：\(progressTime)").font(.caption2).foregroundColor(.secondary)
                }
                if let observedTime = CLIConversationFormatter.readableISOTime(snapshot["lastObservedAt"]?.stringValue) {
                    Text(isStale ? "状态已过期 · 最后更新：\(observedTime)" : "最近观测：\(observedTime)")
                        .font(.caption2).foregroundColor(isStale ? .orange : .secondary)
                }
                Text(session.workingDirectory ?? "工作目录未知").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text("模型：\(snapshot["effectiveModel"]?.stringValue ?? snapshot["model"]?.stringValue ?? "待确认") · \(snapshot["upstreamLabel"]?.stringValue ?? snapshot["upstreamHost"]?.stringValue ?? "Windows CLI 配置")").font(.caption2)
                if let configuration = snapshot["configurationLabel"]?.stringValue {
                    Text("配置：\(configuration) · 额度：未知").font(.caption2).foregroundColor(.secondary)
                }
                if isStale {
                    Text(snapshot["staleReason"]?.stringValue ?? "观测已过期，等待重新连接；保留已有输出与错误历史。").font(.caption).foregroundColor(.orange)
                }
                if !controllable { Text(snapshot["controlReason"]?.stringValue ?? "现有进程未开放安全控制接口。").font(.caption).foregroundColor(.secondary) }
                if let reason = snapshot["unknownReason"]?.stringValue { Text(reason).font(.caption).foregroundColor(.orange) }
                if !controllable {
                    Button(snapshot["interruptedManaged"]?.boolValue == true ? "验证旧进程退出并恢复连接" : "旧进程退出后恢复此会话") {
                        if snapshot["interruptedManaged"]?.boolValue == true { confirmRecovery = true } else { showNativeRecovery = true }
                    }.disabled(store.machine.state != .online || recoveryBusy)
                }
                HStack {
                    Toggle("展开技术日志", isOn: $showTechnicalLogs).font(.caption)
                    Spacer()
                    if !combinedErrors.isEmpty {
                        Button("错误记录（\(combinedErrors.count)）") { showErrorSheet = true }
                            .font(.caption)
                            .foregroundColor(activeErrors.isEmpty ? .secondary : .red)
                    }
                }
                if let latestActive = activeErrors.first {
                    CLIErrorCard(error: latestActive, compact: true)
                        .onTapGesture { showErrorSheet = true }
                }
                DisclosureGroup("进程详细信息", isExpanded: $showProcessDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        processRow("会话标题", key: "sessionTitle", fallback: session.title)
                        processRow("原生 Session ID", key: "nativeSessionId", fallback: session.threadId)
                        processRow("PID", key: "pid")
                        if snapshot["controllerPid"] != nil { processRow("控制入口 PID", key: "controllerPid") }
                        processRow("进程启动时间", key: "processStartedAt")
                        processRow("可执行文件", key: "executable")
                        processRow("父进程 PID", key: "parentPid")
                        processRow("父进程名称", key: "parentName")
                        processRow("所有者", key: "owner")
                        processRow("工作目录", key: "cwd", fallback: session.workingDirectory)
                        processRow("最近进度时间", key: "lastProgressAt")
                        processRow("最近观测时间", key: "lastObservedAt")
                        HStack { Text("观测是否过期"); Spacer(); Text(staleDescription).multilineTextAlignment(.trailing) }
                        processRow("控制原因", key: "controlReason")
                        Text("这些值来自 Windows 最近一次 CLI 观测；PID 本身不能证明进程仍在运行。")
                            .font(.caption2).foregroundColor(.secondary)
                    }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
            ScrollViewReader { proxy in
            List {
                if store.hasMoreBySession[session.id] != false {
                    Button("加载更早记录") { followsLatest = false; Task { await store.loadOlder(session.id) } }
                }
                ForEach(displayEntries) { entry in
                    switch entry {
                    case .toolGroup(let groupId, let items):
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedToolGroups.contains(groupId) },
                                set: { if $0 { expandedToolGroups.insert(groupId) } else { expandedToolGroups.remove(groupId) } }
                            )
                        ) {
                            ForEach(items) { toolItem in
                                DisclosureGroup("\(toolItem.toolName ?? "工具记录") · \(CLIConversationFormatter.readableTime(toolItem.createdAt))") {
                                    Text(CLIConversationFormatter.cleanNaturalText(toolItem.toolCardCopyText))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        } label: {
                            let summaryNames = Array(Set(items.compactMap(\.toolName))).prefix(3).joined(separator: "、")
                            Text("技术日志（\(items.count) 条：\(summaryNames.isEmpty ? "工具执行" : summaryNames)）")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .id(entry.id)
                    case .message(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(CLIConversationFormatter.roleDisplayName(message.role, runtimeKind: runtime.kind)) · \(CLIConversationFormatter.readableTime(message.createdAt))")
                                .font(.caption2).foregroundColor(.secondary)
                            if message.kind == .toolEvent {
                                DisclosureGroup("\(message.toolName ?? "工具记录") · \(message.toolStatus ?? "Recorded")") {
                                    Text(CLIConversationFormatter.cleanNaturalText(message.toolCardCopyText))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            } else {
                                Text(CLIConversationFormatter.cleanNaturalText(message.text)).textSelection(.enabled)
                            }
                        }.id(entry.id).contextMenu {
                            Button("复制") {
                                UIPasteboard.general.string = message.kind == .toolEvent
                                    ? CLIConversationFormatter.cleanNaturalText(message.toolCardCopyText)
                                    : CLIConversationFormatter.cleanNaturalText(message.text)
                            }
                        }
                    }
                }
                if controllable {
                    ForEach(approvals) { item in
                        VStack(alignment: .leading) {
                            Text("等待审批：\(item.kind)").font(.headline)
                            Text(item.summary).font(.caption).textSelection(.enabled)
                            if item.kind == "item/tool/requestUserInput" {
                                TextField("输入给此请求的回答", text: $userAnswer)
                                Button("提交回答") {
                                    Task { _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "respondApproval", payload: ["requestId": .string(item.requestId), "decision": .string("allow"), "answer": .string(userAnswer)]); userAnswer = ""; await refresh() }
                                }.disabled(userAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            } else { HStack {
                                Button("允许一次") { approval = item }.buttonStyle(.borderedProminent)
                                Button("拒绝", role: .destructive) { Task { await respond(item, decision: "deny") } }.buttonStyle(.bordered)
                            } }
                        }
                        .padding(.vertical, 5)
                    }
                } else if !approvals.isEmpty {
                    ForEach(approvals) { item in
                        VStack(alignment: .leading) {
                            Text("只读会话中的待审批请求").font(.headline)
                            Text(item.summary).font(.caption).textSelection(.enabled)
                            Text("此会话未开放远程控制。").font(.caption2).foregroundColor(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }.listStyle(.plain)
                .simultaneousGesture(DragGesture().onChanged { _ in followsLatest = false })
                .onAppear {
                    if followsLatest, let id = displayEntries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: displayEntries.last?.id) { id in
                    if followsLatest, search.isEmpty, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest && search.isEmpty {
                        Button("最新输出") {
                            followsLatest = true
                            if let id = displayEntries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                        }.buttonStyle(.bordered).padding(8)
                    }
                }
            }
            if let receipt = store.cliReceipts[session.id] { Text(receipt).font(.caption).padding(6) }
            if let error = store.errors[session.id] { Text(CLIErrorRecord.redactSensitiveText(error)).font(.caption).foregroundColor(.red).padding(6) }
            if controllable {
                HStack(alignment: .bottom) {
                    TextEditor(text: $text).frame(minHeight: 44, maxHeight: 100)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("发送到当前会话")
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 5)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("发送到当前会话")
                    Button("发送") {
                        busy = true
                        Task {
                            if await store.send(text: text, runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id) { text = "" }
                            busy = false
                        }
                    }.frame(minWidth: 48, minHeight: 44).disabled(busy || active || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.machine.state != .online)
                }.padding()
            }
        }
        .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索当前输出")
        .toolbar {
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
            if controllable && !active { Button("模型与中转站") { showNextCall = true } }
            if controllable { Button("停止", role: .destructive) { confirmStop = true }.disabled(!active || store.machine.state != .online) }
            if controllable && !active {
                Button("重置受控连接", role: .destructive) { confirmRecovery = true }
                    .disabled(recoveryBusy || store.machine.state != .online)
            }
        }
        .confirmationDialog("停止当前会话已授权的任务？", isPresented: $confirmStop) {
            Button("停止此任务", role: .destructive) { Task { _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "stopGeneration"); await refresh() } }
        }
        .confirmationDialog("重置此 RemoteAI 托管连接？", isPresented: $confirmRecovery) {
            Button("重置受控连接", role: .destructive) {
                recoveryBusy = true
                Task {
                    _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "recoverCLISession")
                    recoveryBusy = false
                    await refresh()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅重置此 RemoteAI 管理的非活跃 CLI 连接，保留会话历史和 Provider 标识；不会调用模型或重发指令。下次发送由你明确触发。")
        }
        .sheet(isPresented: $showNativeRecovery) {
            CLINativeRecoveryView(runtime: runtime, instance: instance, session: session).environmentObject(store)
        }
        .sheet(isPresented: $showNextCall) { CLINextCallView(runtime: runtime, instance: instance, session: session).environmentObject(store) }
        .sheet(isPresented: $showErrorSheet) { CLIErrorHistorySheet(sessionTitle: snapshot["sessionTitle"]?.stringValue ?? session.title, errors: combinedErrors) }
        .alert("允许当前会话执行这次工具调用？", isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })) {
            Button("取消", role: .cancel) { approval = nil }
            Button("允许一次") { if let item = approval { Task { await respond(item, decision: "allow") } }; approval = nil }
        } message: { Text(approval?.summary ?? "") }
        .onChange(of: store.machine.state) { newState in
            if newState == .online {
                Task {
                    await refresh()
                    await store.loadSession(session.id, preferCache: false)
                }
            }
        }
        .task {
            await store.loadSession(session.id)
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    private func refresh() async { _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "getSessionStatus") }
    private var staleDescription: String {
        guard let stale = snapshot["stale"]?.boolValue else { return "未提供" }
        return stale ? "已过期" : "当前观测"
    }
    private func processRow(_ title: String, key: String, fallback: String? = nil) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 12)
            Text(metadataText(key) ?? fallback ?? "未提供")
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
    private func metadataText(_ key: String) -> String? {
        guard let value = snapshot[key] else { return nil }
        if let text = value.stringValue { return text }
        if let number = value.intValue { return String(number) }
        return nil
    }
    private func respond(_ item: CLIApproval, decision: String) async {
        _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "respondApproval", payload: ["requestId": .string(item.requestId), "decision": .string(decision)])
        await refresh()
    }
}

struct CLIErrorCard: View {
    let error: CLIErrorRecord
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(error.code).font(.caption).fontWeight(.semibold).foregroundColor(error.recovered ? .secondary : .red)
                Text("来源：\(error.sourceDisplayName)")
                    .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14)).cornerRadius(4)
                Spacer()
                if error.recovered {
                    Text("已恢复").font(.caption2).foregroundColor(.green)
                } else if error.retrying {
                    Text("正在重试").font(.caption2).foregroundColor(.orange)
                } else if error.needsManualAction {
                    Text("需人工处理").font(.caption2).foregroundColor(.red)
                }
            }
            Text(error.message)
                .font(.caption)
                .lineLimit(compact ? 2 : nil)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let time = CLIConversationFormatter.readableISOTime(error.atString) {
                    Text("时间：\(time)")
                }
                if let wait = error.retryAfterSeconds {
                    Text("等待重试：\(wait) 秒")
                }
            }
            .font(.caption2).foregroundColor(.secondary)
            if !compact {
                let modelText = [error.model, error.upstreamLabel ?? error.upstreamHost].compactMap { $0 }.joined(separator: " · ")
                if !modelText.isEmpty {
                    Text("模型/中转站：\(modelText)").font(.caption2).foregroundColor(.secondary)
                }
                if let sid = error.sessionId {
                    Text("会话：\(sid)").font(.caption2).foregroundColor(.secondary)
                }
                if let recoveredAt = error.recoveredAt, let time = CLIConversationFormatter.readableISOTime(recoveredAt) {
                    Text("恢复时间：\(time)").font(.caption2).foregroundColor(.green)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((error.recovered ? Color.secondary : Color.red).opacity(0.08))
        .cornerRadius(8)
    }
}

struct CLIErrorHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let sessionTitle: String
    let errors: [CLIErrorRecord]

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("真实错误独立保留，不会因折叠技术日志而隐藏，恢复与重进后仍可查看。").font(.caption).foregroundColor(.secondary)
                }
                ForEach(errors) { item in
                    CLIErrorCard(error: item, compact: false)
                }
            }
            .navigationTitle("错误记录 · \(sessionTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
