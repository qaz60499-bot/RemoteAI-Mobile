import SwiftUI
import UIKit

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

    var canEdit: Bool { source == "remoteai" && editable == true }
    var canRemove: Bool { removable == true && (source == "remoteai" || source == "discovered") }
}

extension InstanceDescriptor {
    var cliUpstreams: [CLIUpstream] { (try? config["upstreamCatalog"]?.decode([CLIUpstream].self)) ?? [] }
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
}

struct CLIRuntimeView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    @State private var search = ""
    @State private var activeSheet: CLIRuntimeSheet?
    private var instances: [InstanceDescriptor] { store.instances.filter { $0.runtimeId == runtime.id && $0.config["cliMobile"]?.boolValue == true } }
    var body: some View {
        List {
            Section {
                Text("桌面会话先按原身份观察；旧进程退出后可恢复同一会话。RemoteAI 托管会话支持指令、审批和停止。")
                    .font(.footnote).foregroundColor(.secondary)
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
            }
            ForEach(instances) { instance in
                Section(instance.name) {
                    if let error = store.errors["instance.\(instance.id)"] {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                    ForEach(CodexDirectoryGroup.make(store.sessions.filter { $0.instanceId == instance.id })) { group in
                        DisclosureGroup(group.path) {
                            ForEach(group.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || group.path.localizedCaseInsensitiveContains(search) }) { session in
                                NavigationLink(destination: CLIConversationView(runtime: runtime, instance: instance, session: session)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.title)
                                        if let pid = session.cliMetadata?["pid"]?.intValue {
                                            Text("PID \(pid) · \(session.threadId.map { String($0.prefix(8)) } ?? "原生身份待确认")").font(.caption2).foregroundColor(.secondary)
                                        }
                                        Text("\(session.cliMetadata?["controlMode"]?.stringValue == "managed" ? "可控制" : "只读") · \(CLIStateLabel.text(session.cliMetadata?["cliState"]?.stringValue))")
                                            .font(.caption).foregroundColor(.secondary)
                                        if let model = session.modelId { Text(model).font(.caption2) }
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            if let error = store.errors["runtime.\(runtime.id)"] { Text(error).foregroundColor(.red) }
        }
        .navigationTitle(runtime.kind.displayName)
        .searchable(text: $search, prompt: "搜索会话或工作目录")
        .refreshable { await refresh() }
        .task { await refresh() }
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
    private func refresh() async {
        await store.refreshRuntime(runtime)
        for instance in instances { await store.refreshSessions(runtime: runtime, instance: instance) }
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
                    Toggle("授权此项目文件修改与测试", isOn: $allowProjectWrites)
                    Text("授权仅作用于所选项目；工具审批仍保留。Windows 会检查项目是否在已授权范围内。").font(.caption)
                }
                Section("模型 API 中转站") {
                    Picker("使用电脑现有配置", selection: $upstreamId) {
                        Text("请选择").tag("")
                        ForEach(instance.cliUpstreams.filter(\.credentialAvailable)) { item in Text("\(item.label) · \(item.host)").tag(item.id) }
                    }
                    if let selected {
                        Text("凭据保留在 Windows · \(selected.health == "unknown" ? "连接尚未验证" : selected.health)").font(.caption)
                        Picker("模型", selection: $model) { ForEach(selected.models, id: \.self) { Text($0).tag($0) } }
                    }
                    if !instance.cliUpstreams.contains(where: \.credentialAvailable) {
                        Text(instance.cliUpstreams.first(where: { !$0.credentialAvailable })?.availabilityReason
                             ?? "此 Windows 配置没有可复用于新会话的凭据。请在 Windows 添加可复用的模型 API 凭据后重试。")
                            .font(.caption).foregroundColor(.secondary)
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
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var showEditor = false
    @State private var editingUpstream: CLIUpstream?
    @State private var deleteCandidate: CLIUpstream?
    @State private var confirmDelete = false
    @State private var deleteRetryTarget: CLIUpstream?
    @State private var deleteOperationId: UUID?

    var body: some View {
        List {
            Section {
                Text("这些中转站配置仅供此电脑上的 RemoteAI CLI 使用。Windows 保管 API Key；Cloudflare Relay 只负责加密传输，与模型 API 中转站独立。")
                    .font(.footnote).foregroundColor(.secondary)
                Text("删除自定义中转站会删除此处的 RemoteAI 配置。隐藏导入中转站只会在此处隐藏，不会更改 Windows 中的来源配置。")
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
                        Text(item.label).font(.headline)
                        Text(item.host).font(.caption).textSelection(.enabled)
                        Text("\(item.sourceLabel) · \(credentialStatus(for: item))")
                            .font(.caption2).foregroundColor(.secondary)
                        if !item.credentialAvailable, let availabilityReason = item.availabilityReason, !availabilityReason.isEmpty {
                            Text(availabilityReason).font(.caption2).foregroundColor(.secondary)
                        }
                        if !item.models.isEmpty {
                            Text("模型：\(item.models.joined(separator: ", "))").font(.caption2).foregroundColor(.secondary)
                        }
                        if let defaultModel = item.defaultModel, !defaultModel.isEmpty {
                            Text("默认模型：\(defaultModel)").font(.caption2).foregroundColor(.secondary)
                        }
                        if item.health != "unknown" {
                            Text("连接状态：\(item.health)").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        if item.canEdit {
                            Button("编辑") {
                                editingUpstream = item
                                showEditor = true
                            }.disabled(deleting || deleteRetryTarget != nil || store.machine.state != .online)
                        }
                        if item.canRemove {
                            Button(item.source == "discovered" ? "隐藏" : "删除", role: .destructive) {
                                deleteCandidate = item
                                confirmDelete = true
                            }.disabled(deleting || deleteRetryTarget != nil || store.machine.state != .online)
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
        .sheet(isPresented: $showEditor, onDismiss: { Task { await loadCatalog() } }) {
            let savedMessage = editingUpstream == nil ? "已添加自定义中转站。" : "已更新自定义中转站。"
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
                 : "从此电脑的 RemoteAI 配置中删除此自定义中转站。")
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var deleteConfirmationTitle: String {
        deleteCandidate?.source == "discovered" ? "隐藏此导入中转站？" : "删除此自定义中转站？"
    }

    private func credentialStatus(for item: CLIUpstream) -> String {
        if item.credentialAvailable { return "凭据由 Windows 保管" }
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
    private func remove(_ item: CLIUpstream, operationId: UUID) async {
        guard item.canRemove else {
            errorMessage = "此中转站不允许从手机管理。"
            return
        }
        deleting = true
        errorMessage = nil
        statusMessage = nil
        defer { deleting = false }
        let outcome = await store.cliUpstreamAction(
            runtime: runtime,
            instance: instance,
            action: "deleteCLIUpstream",
            payload: ["id": .string(item.id)],
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
    @State private var defaultModel: String
    @State private var busy = false
    @State private var retrySamePayload = false
    @State private var operationId: UUID?
    @State private var errorMessage: String?

    init(runtime: RuntimeDescriptor, instance: InstanceDescriptor, upstream: CLIUpstream?, onSaved: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.instance = instance
        self.upstream = upstream
        self.onSaved = onSaved
        _label = State(initialValue: upstream?.label ?? "")
        _modelsText = State(initialValue: upstream?.models.joined(separator: ", ") ?? "")
        _defaultModel = State(initialValue: upstream?.defaultModel ?? upstream?.models.first ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("RemoteAI 自定义中转站") {
                    TextField("名称", text: $label)
                    TextField("服务端 URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(upstream == nil
                         ? "请输入 API Base URL。Windows 不会把 API Key 或完整 URL 回传到手机。"
                         : "Windows 不会把完整 URL 回传到手机；编辑时请重新填写 API Base URL。留空 API Key 会保留 Windows 中当前密钥。")
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
            .navigationTitle(upstream == nil ? "添加中转站" : "编辑中转站")
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

    @MainActor
    private func save() async {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlIsValid: Bool
        if let url = URL(string: cleanURL), let scheme = url.scheme?.lowercased() {
            urlIsValid = (scheme == "https" || scheme == "http") && url.host != nil && url.user == nil && url.password == nil
        } else {
            urlIsValid = false
        }
        let models = modelsText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else { errorMessage = "请输入中转站名称。"; return }
        guard urlIsValid else { errorMessage = "请输入有效的 HTTP 或 HTTPS 服务端 URL。"; return }
        guard !models.isEmpty else { errorMessage = "至少填写一个模型 ID。"; return }
        guard models.contains(cleanDefaultModel) else { errorMessage = "默认模型必须出现在模型列表中。"; return }
        guard upstream != nil || !apiKey.isEmpty else { errorMessage = "添加自定义中转站时必须填写 API Key。"; return }

        var payload: [String: JSONValue] = [
            "label": .string(cleanLabel),
            "baseURL": .string(cleanURL),
            "models": .array(models.map { .string($0) }),
            "defaultModel": .string(cleanDefaultModel),
        ]
        if let upstream { payload["id"] = .string(upstream.id) }
        if !apiKey.isEmpty { payload["apiKey"] = .string(apiKey) }

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
    @State private var userAnswer = ""
    private var snapshot: [String: JSONValue] { store.cliStatus[session.id] ?? session.cliMetadata ?? [:] }
    private var managedRuntime: Bool {
        (instance.id == "cloudcode.remoteai" && instance.runtimeId == runtime.id && runtime.kind == .cloudcode)
            || (instance.id == "codex.remoteai" && instance.runtimeId == runtime.id && runtime.kind == .codex)
    }
    private var controllable: Bool { managedRuntime && snapshot["controlMode"]?.stringValue == "managed" }
    private var active: Bool { ["initializing", "running", "calling_tool", "waiting_approval", "waiting_user"].contains(snapshot["cliState"]?.stringValue ?? "") }
    private var approvals: [CLIApproval] { (try? snapshot["pendingApprovals"]?.decode([CLIApproval].self)) ?? [] }
    private var messages: [ChatMessage] { (store.messagesBySession[session.id] ?? []).filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot["sessionTitle"]?.stringValue ?? session.title).font(.headline).lineLimit(2).textSelection(.enabled)
                Text("\(controllable ? "可控制" : "只读") · \(CLIStateLabel.text(snapshot["cliState"]?.stringValue))").font(.headline)
                Text(session.workingDirectory ?? "工作目录未知").font(.caption).textSelection(.enabled)
                Text("模型：\(snapshot["effectiveModel"]?.stringValue ?? snapshot["model"]?.stringValue ?? "待确认") · \(snapshot["upstreamHost"]?.stringValue ?? "Windows CLI 配置")").font(.caption2)
                if let at = snapshot["lastObservedAt"]?.stringValue { Text("Windows 观测 UTC：\(at)").font(.caption2).foregroundColor(.secondary) }
                if snapshot["stale"]?.boolValue == true || store.machine.state != .online { Text("观测已过期，等待重新连接；保留已有输出。").font(.caption).foregroundColor(.orange) }
                if !controllable { Text(snapshot["controlReason"]?.stringValue ?? "现有进程未开放安全控制接口。").font(.caption).foregroundColor(.secondary) }
                if let reason = snapshot["unknownReason"]?.stringValue { Text(reason).font(.caption).foregroundColor(.orange) }
                if !controllable {
                    Button(snapshot["interruptedManaged"]?.boolValue == true ? "验证旧进程退出并恢复连接" : "旧进程退出后恢复此会话") {
                        if snapshot["interruptedManaged"]?.boolValue == true { confirmRecovery = true } else { showNativeRecovery = true }
                    }.disabled(store.machine.state != .online || recoveryBusy)
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
                if let error = snapshot["providerError"]?.objectValue {
                    DisclosureGroup("错误 \(error["code"]?.stringValue ?? "")") { Text(error["message"]?.stringValue ?? "").textSelection(.enabled); Text(error["at"]?.stringValue ?? "").font(.caption2) }.foregroundColor(.red)
                }
                if let history = snapshot["errorHistory"]?.arrayValue, !history.isEmpty {
                    DisclosureGroup("错误历史（\(history.count)）") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, item in
                            if let error = item.objectValue {
                                VStack(alignment: .leading) {
                                    Text("\(error["code"]?.stringValue ?? "") · \(error["at"]?.stringValue ?? "")").font(.caption2)
                                    Text(error["message"]?.stringValue ?? "").font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
            List {
                Button("加载更早记录") { Task { await store.loadOlder(session.id) } }
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(message.role.rawValue) · \(message.createdAt.formatted(.iso8601))").font(.caption2).foregroundColor(.secondary)
                        if message.kind == .toolEvent {
                            DisclosureGroup(message.toolName ?? "工具调用") { Text(message.toolCardCopyText).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        } else { Text(message.text).textSelection(.enabled) }
                    }.contextMenu { Button("复制") { UIPasteboard.general.string = message.kind == .toolEvent ? message.toolCardCopyText : message.text } }
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
            if let receipt = store.cliReceipts[session.id] { Text(receipt).font(.caption).padding(6) }
            if let error = store.errors[session.id] { Text(error).font(.caption).foregroundColor(.red).padding(6) }
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
        .alert("允许当前会话执行这次工具调用？", isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })) {
            Button("取消", role: .cancel) { approval = nil }
            Button("允许一次") { if let item = approval { Task { await respond(item, decision: "allow") } }; approval = nil }
        } message: { Text(approval?.summary ?? "") }
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
