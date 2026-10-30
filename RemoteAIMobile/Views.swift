import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import QuickLook

private enum MobileLayout {
    static let extraTopBreathingRoom: CGFloat = 8
}

private extension View {
    /// Native navigation already respects the notch/Dynamic Island. Keep a small
    /// additional non-interactive gap below it so content never feels pinned to
    /// the system chrome on compact iPhones.
    func remoteAITopBreathingRoom() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: MobileLayout.extraTopBreathingRoom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var showingPair = false
    @State private var showingDiagnostics = false
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.machine.name).font(.headline)
                            StatusLabel(text: store.displayedMachineState.rawValue, active: store.displayedMachineState == .online)
                            if !store.deferringTransientConnectionPresentation && store.connectionPhase != .online {
                                Text(store.connectionPhase.displayName).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }.padding(.vertical, 8)
                }
                if !store.isPaired {
                    Section {
                        Button { showingPair = true } label: {
                            Label("Pair with Windows to load real Projects", systemImage: "qrcode.viewfinder")
                        }
                        if let error = store.errors["connection"] {
                            Text(error).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
                Section("Runtimes") {
                    ForEach(store.runtimes) { runtime in
                        NavigationLink(destination: RuntimeView(runtime: runtime)) {
                            Label(runtime.name, systemImage: runtimeIcon(runtime.kind)).padding(.vertical, 5)
                        }
                    }
                }
                if store.machine.state == .offline && !store.deferringTransientConnectionPresentation && store.isPaired {
                    Section {
                        Label("Cached workspaces remain available while the PC is offline.", systemImage: "wifi.slash").font(.footnote).foregroundColor(.secondary)
                        if let error = store.errors["connection"] { Text(error).font(.footnote).foregroundColor(.secondary) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .remoteAITopBreathingRoom()
            .navigationTitle("Remote AI")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showingDiagnostics = true } label: { Image(systemName: "doc.text.magnifyingglass") }.accessibilityLabel("Diagnostics Log")
                    Button { showingPair = true } label: { Image(systemName: store.isPaired ? "checkmark.shield" : "qrcode.viewfinder") }.accessibilityLabel("Pair Device")
                }
            }
            .sheet(isPresented: $showingPair) { PairingView().environmentObject(store) }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView().environmentObject(store) }
        }.navigationViewStyle(.stack)
    }
    private func runtimeIcon(_ kind: RuntimeKind) -> String { switch kind { case .web: return "globe"; case .codex: return "terminal"; case .antigravity: return "sparkles" } }
}

private struct DiagnosticExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct DiagnosticsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var copied = false
    @State private var exporting = false
    @State private var exportItem: DiagnosticExportItem?
    @State private var exportError: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label(store.machine.state.rawValue, systemImage: store.machine.state == .online ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(store.connectionPhase.displayName)
                    Spacer()
                }
                .font(.caption)
                .padding()
                Divider()
                ScrollView {
                    Text(log.text)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            }
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(exporting ? "导出中…" : "导出 ZIP") {
                        guard !exporting else { return }
                        exporting = true
                        exportError = nil
                        Task {
                            do {
                                let url = try await store.exportDiagnosticsBundle()
                                exportItem = DiagnosticExportItem(url: url)
                            } catch {
                                exportError = String(describing: error)
                            }
                            exporting = false
                        }
                    }
                    .disabled(exporting)
                    Button("清空") { log.clear() }
                    Button(copied ? "已复制" : "复制") {
                        log.copyToPasteboard()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
            }
            .sheet(item: $exportItem) { item in
                SystemActivitySheet(url: item.url)
            }
            .alert("诊断包导出失败", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("好", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "未知错误")
            }
        }
    }
}

struct RuntimeView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    var body: some View {
        List {
            ForEach(store.instances.filter { $0.runtimeId == runtime.id }) { instance in
                NavigationLink(destination: InstanceView(runtime: runtime, instance: instance)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(instance.name).font(.body.weight(.medium))
                        if let subtitle = instance.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle(runtime.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshRuntime(runtime) }
        .refreshable { await store.refreshRuntime(runtime) }
    }
}

struct InstanceView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    @State private var newSession = false
    @State private var newProject = false
    @State private var projectSearch = ""
    @State private var creatingWebChat = false
    @State private var createdWebSession: SessionDescriptor?
    @State private var openCreatedWebSession = false
    @State private var deleteCandidate: SessionDescriptor?
    @State private var showingDeleteConfirmation = false
    @State private var closingWebTab: OpenWebTab?
    @State private var showingCloseWebTabConfirmation = false
    private var isChatGPTWeb: Bool { runtime.id == "runtime.web" && instance.id == "web.chatgpt" }
    private var isAntigravity: Bool { runtime.id == "runtime.antigravity" }
    private var supportsProjects: Bool { isChatGPTWeb || isAntigravity }
    private func webTabStatus(_ tab: OpenWebTab) -> String {
        if tab.busy { return "Agent 正在生成回复 · 禁止重载与关闭" }
        if let report = store.webTabDiagnosesById[tab.id] {
            switch report.state {
            case "ready": return "网页可操作：已检测到输入框（不代表消息发送成功）"
            case "generating": return "网页正在生成回复"
            case "loading": return "Chrome 正在加载网页，尚未确认完成"
            case "provider-error": return "ChatGPT 网页报告错误"
            case "retry-visible": return "网页出现 Try Again，回复可能加载失败"
            case "not-ready": return "Chrome 已加载，但输入框或主要页面尚未就绪"
            case "unresponsive": return "标签仍存在，但页面脚本未响应"
            case "closed": return "标签已被关闭或不存在"
            case "navigated": return "标签已跳转，不再是原页面"
            default: return "状态未明确：\(report.state)"
            }
        }
        return tab.loading ? "Chrome 加载中，网页健康状态未检测" : "Chrome 标签存在 · 网页健康状态未检测"
    }
    private var visibleProjects: [WebProjectDescriptor] {
        // Cache contains only previously accepted Project snapshots. Render it
        // immediately while the live DOM refresh runs so opening Web never starts with
        // a blank list on a slow account. Legacy/mock rows are purged by WorkspaceStore.
        if isChatGPTWeb {
            return store.webProjects
        }
        if isAntigravity {
            if store.hasLoadedAntigravityProjects { return store.antigravityProjects }
            var map: [String: (count: Int, lastOpened: Date?)] = [:]
            for s in store.sessions where s.instanceId == instance.id {
                if let alias = s.projectAlias, !alias.isEmpty {
                    let current = map[alias] ?? (count: 0, lastOpened: nil)
                    let date = s.orderingDate
                    let maxDate = current.lastOpened.map { max($0, date) } ?? date
                    map[alias] = (count: current.count + 1, lastOpened: maxDate)
                }
            }
            if map["googleac"] == nil {
                map["googleac"] = (count: 0, lastOpened: Date())
            }
            return map.map { (alias, info) in
                WebProjectDescriptor(
                    projectAlias: alias,
                    projectId: alias,
                    displayName: alias,
                    canonicalUrl: "antigravity://project/\(alias)",
                    lastSeenAt: info.lastOpened,
                    lastOpenedAt: info.lastOpened,
                    // active project
                )
            }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        }
        return []
    }
    private var filteredProjects: [WebProjectDescriptor] {
        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleProjects }
        return visibleProjects.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.projectAlias.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if isChatGPTWeb {
                Section {
                    if !store.hasLoadedOpenWebTabs {
                        if store.errors["web.tabs"] != nil {
                            Label("尚未验证 Chrome 标签列表；可在连接恢复后重新读取。", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("正在读取电脑 Chrome 当前打开的 ChatGPT 标签页…")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } else if store.openWebTabs.isEmpty {
                        Text("电脑 Chrome 当前没有打开 ChatGPT 标签页。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(store.openWebTabs) { tab in
                        HStack(spacing: 10) {
                            Image(systemName: tab.isChat ? "bubble.left.and.bubble.right" : "folder")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tab.title).font(.subheadline).lineLimit(2)
                                Text(tab.busy ? "正在生成 · 不可关闭/刷新" : (tab.loading ? "网页加载中" : (tab.active ? "电脑当前标签页" : "后台标签页")))
                                    .font(.caption2).foregroundColor(.secondary)
                                Text(webTabStatus(tab))
                                    .font(.caption2).foregroundColor(.secondary)
                                Text("执行：\(tab.executionState ?? "Unknown") · Agent 最近记录")
                                    .font(.caption2).foregroundColor(.secondary)
                                if let value = tab.lastActivityAt, let date = RemoteAIDate.parse(value) {
                                    FixedTimestamp(date: date, prefix: "最后活动")
                                }
                                if let value = tab.lastProgressAt, let date = RemoteAIDate.parse(value) {
                                    FixedTimestamp(date: date, prefix: "最近实际进展")
                                }
                                if let action = tab.lastProgressSummary {
                                    Text("最近事件：\(action)").font(.caption2).foregroundColor(.secondary)
                                }
                                if let diagnosis = store.webTabDiagnosesById[tab.id],
                                   diagnosis.draftPresent == true || diagnosis.pendingUploads == true {
                                    Text("Blocked · 草稿或上传尚未完成，禁止关闭与刷新")
                                        .font(.caption2).foregroundColor(.orange)
                                }
                                if let diagnosis = store.webTabDiagnosesById[tab.id] {
                                    if let issue = diagnosis.issueMessage, !issue.isEmpty {
                                        Text("原因：\(issue)").font(.caption2).foregroundColor(.secondary)
                                    }
                                    if let code = diagnosis.issueCode, !code.isEmpty {
                                        Text("错误代码：\(code)").font(.caption2).foregroundColor(.secondary)
                                    }
                                    if let observed = diagnosis.observedAt.flatMap(RemoteAIDate.parse) {
                                        FixedTimestamp(date: observed, prefix: "最后检测")
                                    }
                                }
                                if let note = store.webTabActionNotesById[tab.id] {
                                    Text("最近操作：\(note)").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Menu {
                                Button {
                                    Task { await store.inspectOpenWebTab(tab) }
                                } label: {
                                    Label("检测网页实际状态", systemImage: "stethoscope")
                                }
                                Button {
                                    Task { await store.manageOpenWebTab(tab, operation: "hardReload") }
                                } label: {
                                    Label("强制重载（绕过缓存）", systemImage: "arrow.triangle.2.circlepath")
                                }
                                Button {
                                    Task { await store.manageOpenWebTab(tab, operation: "reopen") }
                                } label: {
                                    Label("重新打开此网页（复用标签）", systemImage: "arrow.up.forward.app")
                                }
                                Button {
                                    Task { await store.manageOpenWebTab(tab, operation: "reload") }
                                } label: {
                                    Label("刷新此标签页", systemImage: "arrow.clockwise")
                                }
                                Button(role: .destructive) {
                                    closingWebTab = tab
                                    showingCloseWebTabConfirmation = true
                                } label: {
                                    Label("关闭此标签页", systemImage: "xmark.circle")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.title3)
                            }
                            .disabled(tab.busy || store.machine.state != .online || store.managingWebTabIds.contains(tab.id))
                        }
                        .padding(.vertical, 3)
                    }
                    Button {
                        DiagnosticsLog.shared.record("web_tabs_refresh_tapped")
                        Task { await store.refreshOpenWebTabs() }
                    } label: {
                        Label("更新实际打开的标签页列表", systemImage: "arrow.clockwise")
                    }
                    if let checkedAt = store.openWebTabsLastVerifiedAt {
                        FixedTimestamp(date: checkedAt, prefix: "Chrome 标签列表最后成功验证")
                    }
                    ForEach(store.recentWebTabNotices, id: \.self) { notice in
                        Text(notice).font(.caption2).foregroundColor(.secondary)
                    }
                    if let error = store.errors["web.tabs"] {
                        ErrorBanner(text: error) { store.clearError(sessionId: "web.tabs") }
                    }
                } header: {
                    if store.machine.state == .online && !store.openWebTabsInventoryUnverified {
                        Text("已验证打开 Web Chat \(store.openWebTabs.filter { $0.isChat }.count) · 网页标签 \(store.openWebTabs.count)")
                    } else {
                        Text("当前网页数量未知 · 上次记录 Chat \(store.openWebTabs.filter { $0.isChat }.count) · 标签 \(store.openWebTabs.count)")
                    }
                } footer: {
                    Text("仅 Chrome 列表成功读取时显示当前数量；断连或读取失败时保留缓存但标记数量未知。网页健康状态须单独检测。关闭只关闭标签页，不删除历史。")
                }
            }
            if supportsProjects {
                Section {
                    if isChatGPTWeb { Button { newProject = true } label: { Label("新建 ChatGPT Project", systemImage: "folder.badge.plus") } }
                    TextField("搜索 Project", text: $projectSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    if isChatGPTWeb, !store.webProjects.isEmpty,
                       store.webProjectsSnapshotState != .authoritativeLiveDOM {
                        Label("当前显示上次已验证的 Projects，电脑端最新列表尚未确认；这里的项目可能已变更。", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if filteredProjects.isEmpty {
                        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                        let projectStatus: String = {
                            if isAntigravity {
                                if store.errors["antigravity.projects"] != nil { return "Antigravity Projects 读取失败 — 下拉刷新重试" }
                                if store.hasLoadedAntigravityProjects { return query.isEmpty ? "当前没有找到 Antigravity Projects" : "没有匹配的 Antigravity Project" }
                                return "正在读取 Antigravity Projects…"
                            }
                            if store.errors["web.projects"] != nil { return "Projects 读取失败 — 下拉刷新重试" }
                            if !query.isEmpty, store.hasLoadedWebProjects { return "没有匹配的 ChatGPT Project" }
                            if store.hasLoadedWebProjects { return "当前没有找到 ChatGPT Projects" }
                            return store.machine.state == .online ? "正在读取当前 ChatGPT Projects…" : "离线 — 显示缓存 Projects"
                        }()
                        Text(projectStatus)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(filteredProjects) { project in
                        NavigationLink(destination: WebProjectView(runtime: runtime, instance: instance, project: project)) {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.displayName).font(.body.weight(.medium))
                                    HStack(spacing: 5) {
                                        Text("Project").font(.caption2.weight(.semibold))
                                        if let date = project.lastOpenedAt ?? project.lastSeenAt { FixedTimestamp(date: date, prefix: "最近访问") }
                                    }
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text(isChatGPTWeb ? "ChatGPT Projects" : "Antigravity Projects")
                } footer: {
                    Text("点进某个 Project 后才加载该 Project 的历史对话；不会启动时遍历全部历史。")
                }
                if let error = store.errors[isAntigravity ? "antigravity.projects" : "web.projects"] {
                    Section { ErrorBanner(text: error) { store.clearError(sessionId: isAntigravity ? "antigravity.projects" : "web.projects") } }
                }
                Section {
                    if isChatGPTWeb { Button {
                        guard !creatingWebChat else { return }
                        creatingWebChat = true
                        Task {
                            let created = await store.createWebConversation()
                            creatingWebChat = false
                            if let created {
                                createdWebSession = created
                                openCreatedWebSession = true
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if creatingWebChat { ProgressView().controlSize(.small) }
                            Label(creatingWebChat ? "正在新建对话…" : "新建普通 ChatGPT 对话", systemImage: "plus.circle.fill")
                        }
                    }
                    .disabled(creatingWebChat || store.machine.state != .online) } else { Button { newSession = true } label: { Label("新建普通 Antigravity 对话", systemImage: "plus.circle.fill") } }
                    ForEach(store.sessions.filter { $0.instanceId == instance.id && $0.projectAlias == nil }.sorted { $0.orderingDate > $1.orderingDate }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if isChatGPTWeb {
                                    Button("重开网页") {
                                        Task { await store.reopenClosedWebConversation(sessionId: session.id) }
                                    }.tint(.accentColor)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if isAntigravity {
                                    Button("删除", role: .destructive) { deleteCandidate = session; showingDeleteConfirmation = true }
                                }
                            }
                    }
                } header: {
                    Text("Chats")
                } footer: {
                    Text("Projects 固定显示在 Chats 上方。若原网页已关闭，可向右滑动 Chat 行选择‘重开网页’，沿用旧会话，不新建对话。")
                }
            } else if runtime.kind == .codex {
                Section {
                    Button { newSession = true } label: { Label("新建 CLI Chat", systemImage: "plus.circle.fill") }
                    Text("使用已有 Codex CLI 通道；首条消息发送后才建立真实 Thread，不等同于 Desktop 原生新建。")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("搜索 Projects / Chats", text: $projectSearch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                }
                Section {
                    ForEach(CodexDirectoryGroup.make(store.sessions.filter { $0.instanceId == instance.id }).filter {
                        projectSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(projectSearch)
                            || $0.sessions.contains { $0.title.localizedCaseInsensitiveContains(projectSearch) }
                    }) { group in
                        NavigationLink(destination: CodexDirectoryChatsView(runtime: runtime, instance: instance,
                                                                            directoryKey: group.id, path: group.path)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(group.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? group.path,
                                      systemImage: "folder.fill")
                                Text(group.path).font(.caption).foregroundColor(.secondary).lineLimit(2)
                                Text("\(group.sessions.count) Chats").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                } header: { Text("Projects · 本地工作目录") } footer: {
                    Text("根据 Codex 记录的真实工作目录分组；这是 RemoteAI 本地分组。仅加载当前实例最近一页，更多历史按需读取。")
                }
                Section("Chats") {
                    ForEach(store.sessions.filter {
                        $0.instanceId == instance.id && $0.codexDirectoryKey == nil
                            && (projectSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(projectSearch))
                    }.sorted { $0.orderingDate > $1.orderingDate }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("归档", role: .destructive) { deleteCandidate = session; showingDeleteConfirmation = true }
                            }
                    }
                }
                if store.codexSessionsMayHaveMore[instance.id] == true {
                    Section {
                        Button("加载更多历史 Chats / 工作目录") {
                            Task { await store.loadMoreCodexSessions(runtime: runtime, instance: instance) }
                        }
                    }
                }
            } else {
                Section {
                    Button { newSession = true } label: {
                        Label("新建会话", systemImage: "plus.circle.fill")
                    }
                }
                Section("历史会话") {
                    ForEach(store.sessions.filter { $0.instanceId == instance.id }.sorted { $0.orderingDate > $1.orderingDate }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if runtime.kind == .codex {
                                    Button("归档", role: .destructive) { deleteCandidate = session; showingDeleteConfirmation = true }
                                }
                            }
                    }
                }
            }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle(instance.name).navigationBarTitleDisplayMode(.inline)
        .background(
            Group {
                if let createdWebSession {
                    NavigationLink(
                        destination: ChatView(runtime: runtime, instance: instance, session: createdWebSession),
                        isActive: $openCreatedWebSession
                    ) { EmptyView() }
                    .hidden()
                }
            }
        )
        .sheet(isPresented: $newSession) { NewSessionView(runtime: runtime, instance: instance).environmentObject(store) }
        .alert(runtime.kind == .codex ? "将此 Codex Chat 归档？" : "删除电脑和手机上的 Antigravity 对话？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) { deleteCandidate = nil }
            Button(runtime.kind == .codex ? "归档对话" : "删除对话", role: .destructive) {
                if let session = deleteCandidate { Task { _ = await store.deleteSession(runtime: runtime, instance: instance, session: session) } }
                deleteCandidate = nil
            }
        } message: {
            Text(runtime.kind == .codex
                ? "将使用 Codex 原生归档接口，使此 Chat 从电脑和手机的活动会话列表移除；可在 Codex 归档中恢复。"
                : "这将请求 Windows 上的 Antigravity 删除原始对话，操作不可撤销。")
        }
        .confirmationDialog("关闭这个 Chrome 标签页？", isPresented: $showingCloseWebTabConfirmation) {
            Button("取消", role: .cancel) { closingWebTab = nil }
            Button("仅关闭标签页", role: .destructive) {
                if let tab = closingWebTab {
                    Task { await store.manageOpenWebTab(tab, operation: "close") }
                }
                closingWebTab = nil
            }
        } message: {
            Text("不会删除 ChatGPT 历史记录或 RemoteAI 会话数据。关闭之前会再次核对实际网页地址，防止误关其他 Chat。")
        }
        .sheet(isPresented: $newProject) { NewWebProjectView().environmentObject(store) }
        .task {
            if isChatGPTWeb {
                // Projects are the primary navigation surface here. Show the last
                // verified Windows/iOS cache first, then let WorkspaceStore schedule
                // the authoritative DOM refresh without blocking initial navigation.
                await store.refreshOpenWebTabs()
                await store.refreshWebProjects(force: false)
                await store.refreshSessions(runtime: runtime, instance: instance)
            } else {
                await store.refreshSessions(runtime: runtime, instance: instance)
                if isAntigravity { await store.refreshAntigravityProjects() }
            }
            // Reconcile desktop-created/archived chats while this catalog is visible.
            // Web discovery is more expensive, so poll its project catalog less often.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: isChatGPTWeb ? 45_000_000_000 : 15_000_000_000) }
                catch { break }
                guard !Task.isCancelled else { break }
                if scenePhase == .active, store.machine.state == .online {
                    if isChatGPTWeb {
                        await store.refreshOpenWebTabs()
                        await store.refreshWebProjects(force: false)
                    }
                    await store.refreshSessions(runtime: runtime, instance: instance)
                    if isAntigravity { await store.refreshAntigravityProjects() }
                }
            }
        }
        .onChange(of: store.machine.state) { state in
            // When the Web catalog was opened while offline, do not wait for
            // its 45-second periodic refresh to discover that Agent is back.
            guard state == .online, scenePhase == .active, isChatGPTWeb else { return }
            Task { await store.refreshOpenWebTabs() }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, store.machine.state == .online else { return }
            Task {
                if isChatGPTWeb {
                    await store.refreshOpenWebTabs()
                    await store.refreshWebProjects(force: false)
                }
                await store.refreshSessions(runtime: runtime, instance: instance)
                if isAntigravity { await store.refreshAntigravityProjects() }
            }
        }
        .refreshable {
            if isChatGPTWeb {
                await store.refreshOpenWebTabs()
                await store.refreshWebProjects(force: true)
                await store.refreshSessions(runtime: runtime, instance: instance)
            } else {
                await store.refreshSessions(runtime: runtime, instance: instance)
                if isAntigravity { await store.refreshAntigravityProjects() }
            }
        }
    }
}

struct FixedTimestamp: View {
    let date: Date
    var prefix: String = "最后更新"
    var body: some View {
        Text("\(prefix) \(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

struct CodexDirectoryChatsView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let directoryKey: String
    let path: String
    @State private var newSession = false
    @State private var search = ""
    @State private var archiveCandidate: SessionDescriptor?
    @State private var showArchive = false

    private var rows: [SessionDescriptor] {
        store.sessions.filter {
            $0.instanceId == instance.id && $0.codexDirectoryKey == directoryKey
                && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }.sorted { $0.orderingDate == $1.orderingDate ? $0.id < $1.id : $0.orderingDate > $1.orderingDate }
    }

    var body: some View {
        List {
            Section {
                Text(path).font(.caption).foregroundColor(.secondary)
                Button { newSession = true } label: { Label("在此目录新建 CLI Chat", systemImage: "plus.circle.fill") }
                    .disabled(store.machine.state != .online)
            } footer: {
                Text("使用 Codex CLI 建立此工作目录的新 Thread（首条消息发送后持久化）；并非 Desktop 原生 owner-bound 新建。")
            }
            Section("Chats") {
                ForEach(rows) { session in
                    NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("归档", role: .destructive) { archiveCandidate = session; showArchive = true }
                    }
                }
            }
            if store.codexSessionsMayHaveMore[instance.id] == true {
                Button("加载更多历史 Chats") {
                    Task { await store.loadMoreCodexSessions(runtime: runtime, instance: instance) }
                }
            }
        }
        .navigationTitle("Chats").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索 Chat")
        .sheet(isPresented: $newSession) {
            NewSessionView(runtime: runtime, instance: instance, codexProjectPath: path).environmentObject(store)
        }
        .refreshable { await store.refreshSessions(runtime: runtime, instance: instance) }
        .alert("将此 Codex Chat 归档？", isPresented: $showArchive) {
            Button("取消", role: .cancel) { archiveCandidate = nil }
            Button("归档", role: .destructive) {
                if let session = archiveCandidate {
                    Task { _ = await store.deleteSession(runtime: runtime, instance: instance, session: session) }
                }
                archiveCandidate = nil
            }
        } message: { Text("使用 Codex 原生归档接口；可在 Codex 归档中恢复。") }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    let session: SessionDescriptor
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                FixedTimestamp(date: session.updatedAt, prefix: "最后更新")
                FixedTimestamp(date: session.lastActivityAt ?? session.updatedAt, prefix: "最后进行")
                if session.instanceId == "antigravity.desktop" {
                    BackgroundTaskStatusView(
                        snapshot: session.backgroundTaskStatus,
                        receivedAt: session.backgroundTaskStatusReceivedAt,
                        machineOnline: store.machine.state == .online,
                        sceneActive: scenePhase == .active,
                        compact: true
                    )
                }
                if session.instanceId == "antigravity.desktop",
                   session.state == .busy || session.state == .waiting,
                   let progress = session.lastProgressStatus, !progress.isEmpty {
                    Text("对话进度：\(progress)").font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(session.instanceId == "antigravity.desktop" && (session.state == .busy || session.state == .waiting)
                ? "对话处理中" : session.state.rawValue)
                .font(.caption)
                .foregroundColor(session.state == .error ? .red : .secondary)
        }
    }
}

private struct BackgroundTaskStatusView: View {
    let snapshot: BackgroundTaskStatusSnapshot?
    let receivedAt: Date?
    let machineOnline: Bool
    let sceneActive: Bool
    var compact = false

    private var isCurrent: Bool {
        guard let snapshot, let receivedAt, snapshot.state == .available, machineOnline, sceneActive else { return false }
        let age = Date().timeIntervalSince(receivedAt)
        return age >= -60 && age <= 45
    }

    private var prioritizedTasks: [BackgroundTaskDescriptor] {
        (snapshot?.tasks ?? []).enumerated().sorted { left, right in
            let leftRank = Self.rank(left.element.status)
            let rightRank = Self.rank(right.element.status)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map { $0.element }
    }

    private var summary: String {
        guard let snapshot else { return "状态未知 · 待同步" }
        guard snapshot.state == .available else { return "状态未知 · 待核对" }
        let running = snapshot.tasks.filter { $0.status == .running }.count
        if running > 0 { return "运行中 · \(running) 项" }
        let waiting = snapshot.tasks.filter { $0.status == .waiting || $0.status == .queued }.count
        if waiting > 0 { return "等待中 · \(waiting) 项" }
        if snapshot.tasks.contains(where: { $0.status == .unknown }) { return "状态未知" }
        return "当前无运行任务"
    }

    private var displayedSummary: String {
        guard !isCurrent, snapshot != nil else { return summary }
        return "最后记录：\(summary) · 待核对"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            Text("后台任务：\(displayedSummary)")
                .font(compact ? .caption2 : .caption.weight(.medium))
                .foregroundColor(isCurrent && snapshot?.tasks.contains(where: { $0.status == .running }) == true ? .green : .secondary)
                .lineLimit(2)

            if let snapshot, !compact {
                if isCurrent, let receivedAt {
                    Text("状态已核对 · \(receivedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if let receivedAt {
                    Text("最后同步 \(receivedAt.formatted(date: .omitted, time: .standard))；连接恢复并刷新后核对")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else {
                    Text("等待同步；刷新后核对任务状态")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                ForEach(Array(prioritizedTasks.prefix(3))) { task in
                    HStack(alignment: .top, spacing: 6) {
                        Text(task.title.isEmpty ? task.id : task.title)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.label(for: task.status))
                            .foregroundColor(task.status == .running && isCurrent ? .green : .secondary)
                    }
                    .font(.caption2)
                    if let progress = task.progress?.trimmingCharacters(in: .whitespacesAndNewlines), !progress.isEmpty {
                        Text(progress)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            } else if compact,
                      let progress = prioritizedTasks.first(where: { $0.status == .running })?.progress,
                      !progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(progress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private static func rank(_ status: BackgroundTaskState) -> Int {
        switch status {
        case .running: return 0
        case .waiting: return 1
        case .queued: return 2
        case .unknown: return 3
        case .completed, .canceled, .failed: return 4
        }
    }

    private static func label(for status: BackgroundTaskState) -> String {
        switch status {
        case .running: return "运行中"
        case .waiting: return "等待中"
        case .queued: return "排队中"
        case .completed: return "已结束"
        case .canceled: return "已取消"
        case .failed: return "失败"
        case .unknown: return "未知"
        }
    }
}

struct WebProjectView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let project: WebProjectDescriptor
    @State private var loadingMore = false
    @State private var creatingChat = false
    @State private var createdSession: SessionDescriptor?
    @State private var openCreatedSession = false
    @State private var newAntigravitySession = false
    @State private var deleteCandidate: SessionDescriptor?
    @State private var showingDeleteConfirmation = false

    private var isAntigravity: Bool { runtime.kind == .antigravity }
    private var rows: [WebConversationDescriptor] { store.displayedProjectConversations(projectAlias: project.projectAlias) }
    private var antigravitySessions: [SessionDescriptor] {
        store.sessions.filter { session in
            guard session.instanceId == instance.id else { return false }
            let alias = session.projectAlias ?? ""
            return alias.caseInsensitiveCompare(project.projectAlias) == .orderedSame
                || (project.projectAlias.caseInsensitiveCompare("googleac") == .orderedSame && alias.isEmpty)
        }.sorted { $0.orderingDate > $1.orderingDate }
    }

    private func refreshProjectContext(force: Bool) async {
        // Session status comes from the Windows Agent and does not require opening or
        // navigating a browser tab. Refresh it first so a desktop-only Busy/Waiting Chat
        // becomes visible even when its Project sidebar row has not mounted yet.
        await store.refreshSessions(runtime: runtime, instance: instance)
        // Antigravity chats are native Agent sessions, not ChatGPT browser conversations.
        // Never fetch them through the Web-only project cache/transport path.
        if !isAntigravity {
            await store.loadProjectConversations(projectAlias: project.projectAlias, force: force)
        }
    }

    var body: some View {
        List {
            Section {
                if isAntigravity {
                    Button { newAntigravitySession = true } label: {
                        Label("在此 Project 新建对话", systemImage: "plus.circle.fill")
                    }.disabled(store.machine.state != .online)
                } else {
                    Button {
                        guard !creatingChat else { return }
                        creatingChat = true
                        Task {
                            let created = await store.createWebConversation(projectAlias: project.projectAlias)
                            creatingChat = false
                            if let created {
                                createdSession = created
                                openCreatedSession = true
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if creatingChat { ProgressView().controlSize(.small) }
                            Label(creatingChat ? "正在新建对话…" : "在此 Project 新建对话", systemImage: "plus.circle.fill")
                        }
                    }
                    .disabled(creatingChat || store.machine.state != .online)
                }
            }
            Section("最近对话") {
                if isAntigravity {
                    ForEach(antigravitySessions) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) {
                            SessionRow(session: session)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { deleteCandidate = session; showingDeleteConfirmation = true }
                        }
                    }
                } else {
                if store.projectConversationLoadingByAlias[project.projectAlias] == true {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(rows.isEmpty ? "正在加载这个 Project 的最新对话…" : "正在后台刷新，当前列表仍可使用…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if !rows.isEmpty,
                   store.projectConversationSnapshotStateByAlias[project.projectAlias] != .authoritativeLiveDOM {
                    Label("当前使用上次已验证的 Chats；电脑端最新列表还未确认，新建、删除和排序可能暂时不同步。", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(rows) { conversation in
                    let resolvedSession = store.sessions.first(where: { $0.id == conversation.localConversationId }) ?? conversation.session
                    NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: resolvedSession)) {
                        SessionRow(session: resolvedSession)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button("重开网页") {
                            Task { await store.reopenClosedWebConversation(sessionId: resolvedSession.id) }
                        }.tint(.accentColor)
                    }
                }
                if store.projectHasMoreByAlias[project.projectAlias] == true {

[Showing lines 1-942 of 3006 (50.0KB limit). Use offset=943 to continue.]