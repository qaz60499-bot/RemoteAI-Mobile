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
        case "running": return "执行中"
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
    @State private var createIn: InstanceDescriptor?
    private var instances: [InstanceDescriptor] { store.instances.filter { $0.runtimeId == runtime.id && $0.config["cliMobile"]?.boolValue == true } }
    var body: some View {
        List {
            Section {
                Text("现有 Windows CLI 会话只读；新建 RemoteAI 会话后可发送指令、审批和停止自己的任务。")
                    .font(.footnote).foregroundColor(.secondary)
                ForEach(instances.filter(\.isManagedCLI)) { instance in
                    Button { createIn = instance } label: { Label("新建 \(runtime.kind.displayName) 会话", systemImage: "plus.circle") }
                        .disabled(store.machine.state != .online)
                }
            }
            ForEach(instances) { instance in
                Section(instance.name) {
                    ForEach(CodexDirectoryGroup.make(store.sessions.filter { $0.instanceId == instance.id })) { group in
                        DisclosureGroup(group.path) {
                            ForEach(group.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || group.path.localizedCaseInsensitiveContains(search) }) { session in
                                NavigationLink(destination: CLIConversationView(runtime: runtime, instance: instance, session: session)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.title)
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
        .sheet(item: $createIn) { instance in CLICreateView(runtime: runtime, instance: instance).environmentObject(store) }
    }
    private func refresh() async {
        await store.refreshRuntime(runtime)
        for instance in instances { await store.refreshSessions(runtime: runtime, instance: instance) }
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
    private var selected: CLIUpstream? { instance.cliUpstreams.first { $0.id == upstreamId } }
    var body: some View {
        NavigationView {
            Form {
                Section("Windows 会话") {
                    TextField("会话名称", text: $title)
                    Text(instance.config["projectPath"]?.stringValue ?? "工作目录待确认").font(.caption).textSelection(.enabled)
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
                            if await store.createSession(runtime: runtime, instance: instance, title: title, model: model, upstreamId: upstreamId) { dismiss() }
                            busy = false
                        }
                    }.disabled(busy || selected == nil || model.isEmpty)
                }
            }
            .onChange(of: upstreamId) { _ in model = selected?.defaultModel ?? selected?.models.first ?? "" }
            .onAppear { upstreamId = instance.cliUpstreams.first(where: \.credentialAvailable)?.id ?? ""; model = selected?.defaultModel ?? selected?.models.first ?? "" }
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
    @State private var approval: CLIApproval?
    @State private var busy = false
    private var snapshot: [String: JSONValue] { store.cliStatus[session.id] ?? session.cliMetadata ?? [:] }
    private var controllable: Bool { snapshot["controlMode"]?.stringValue == "managed" }
    private var active: Bool { ["running", "waiting_approval", "waiting_user"].contains(snapshot["cliState"]?.stringValue ?? "") }
    private var approvals: [CLIApproval] { (try? snapshot["pendingApprovals"]?.decode([CLIApproval].self)) ?? [] }
    private var messages: [ChatMessage] { (store.messagesBySession[session.id] ?? []).filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(controllable ? "可控制" : "只读") · \(CLIStateLabel.text(snapshot["cliState"]?.stringValue))").font(.headline)
                Text(session.workingDirectory ?? "工作目录未知").font(.caption).textSelection(.enabled)
                Text("模型：\(snapshot["effectiveModel"]?.stringValue ?? snapshot["model"]?.stringValue ?? "待确认") · \(snapshot["upstreamHost"]?.stringValue ?? "Windows CLI 配置")").font(.caption2)
                if let at = snapshot["lastObservedAt"]?.stringValue { Text("Windows 观测 UTC：\(at)").font(.caption2).foregroundColor(.secondary) }
                if snapshot["stale"]?.boolValue == true || store.machine.state != .online { Text("观测已过期，等待重新连接；保留已有输出。").font(.caption).foregroundColor(.orange) }
                if !controllable { Text(snapshot["controlReason"]?.stringValue ?? "现有进程未开放安全控制接口。").font(.caption).foregroundColor(.secondary) }
                if let error = snapshot["providerError"]?.objectValue {
                    DisclosureGroup("错误 \(error["code"]?.stringValue ?? "")") { Text(error["message"]?.stringValue ?? "").textSelection(.enabled); Text(error["at"]?.stringValue ?? "").font(.caption2) }.foregroundColor(.red)
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
                ForEach(approvals) { item in
                    VStack(alignment: .leading) {
                        Text("等待审批：\(item.kind)").font(.headline)
                        Text(item.summary).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("允许一次") { approval = item }.buttonStyle(.borderedProminent)
                            Button("拒绝", role: .destructive) { Task { await respond(item, decision: "deny") } }.buttonStyle(.bordered)
                        }
                    }.padding(.vertical, 5)
                }
            }.listStyle(.plain)
            if let receipt = store.cliReceipts[session.id] { Text(receipt).font(.caption).padding(6) }
            if let error = store.errors[session.id] { Text(error).font(.caption).foregroundColor(.red).padding(6) }
            if controllable {
                HStack(alignment: .bottom) {
                    TextField("发送到当前会话", text: $text, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
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
            if controllable { Button("停止", role: .destructive) { confirmStop = true }.disabled(!active || store.machine.state != .online) }
        }
        .confirmationDialog("停止当前会话已授权的任务？", isPresented: $confirmStop) {
            Button("停止此任务", role: .destructive) { Task { _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "stopGeneration"); await refresh() } }
        }
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
    private func respond(_ item: CLIApproval, decision: String) async {
        _ = await store.cliAction(runtime: runtime, instance: instance, sessionId: session.id, action: "respondApproval", payload: ["requestId": .string(item.requestId), "decision": .string(decision)])
        await refresh()
    }
}
