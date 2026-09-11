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
                            StatusLabel(text: store.machine.state.rawValue, active: store.machine.state == .online)
                            if store.connectionPhase != .online {
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
                if store.machine.state == .offline && store.isPaired {
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
    private func runtimeIcon(_ kind: RuntimeKind) -> String { switch kind { case .web: return "globe"; case .codex: return "terminal" } }
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
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    @State private var newSession = false
    @State private var newProject = false
    @State private var projectSearch = ""
    @State private var creatingWebChat = false
    @State private var createdWebSession: SessionDescriptor?
    @State private var openCreatedWebSession = false
    private var isChatGPTWeb: Bool { runtime.id == "runtime.web" && instance.id == "web.chatgpt" }
    private var visibleProjects: [WebProjectDescriptor] {
        // Cache contains only previously accepted Project snapshots. Render it
        // immediately while the live DOM refresh runs so opening Web never starts with
        // a blank list on a slow account. Legacy/mock rows are purged by WorkspaceStore.
        store.webProjects
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
                    Button { newProject = true } label: { Label("新建 ChatGPT Project", systemImage: "folder.badge.plus") }
                    TextField("搜索 Project", text: $projectSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    if filteredProjects.isEmpty {
                        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                        let projectStatus: String = {
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
                    Text("ChatGPT Projects")
                } footer: {
                    Text("点进某个 Project 后才加载该 Project 的历史对话；不会启动时遍历全部历史。")
                }
                if let error = store.errors["web.projects"] { Section { ErrorBanner(text: error) { store.clearError(sessionId: "web.projects") } } }
                Section {
                    Button {
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
                    .disabled(creatingWebChat || store.machine.state != .online)
                    ForEach(store.sessions.filter { $0.instanceId == instance.id && $0.projectAlias == nil }.sorted { $0.orderingDate > $1.orderingDate }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                    }
                } header: {
                    Text("Chats")
                } footer: {
                    Text("Projects 固定显示在 Chats 上方；普通对话与 Project 对话不会混在一起。")
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
        .sheet(isPresented: $newProject) { NewWebProjectView().environmentObject(store) }
        .task {
            if isChatGPTWeb {
                // Projects are the primary navigation surface here. Refresh them first
                // instead of waiting for the ordinary-chat history request to finish.
                await store.refreshWebProjects(force: true)
                await store.refreshSessions(runtime: runtime, instance: instance)
            } else {
                await store.refreshSessions(runtime: runtime, instance: instance)
            }
        }
        .refreshable {
            if isChatGPTWeb {
                await store.refreshWebProjects(force: true)
                await store.refreshSessions(runtime: runtime, instance: instance)
            } else {
                await store.refreshSessions(runtime: runtime, instance: instance)
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

struct SessionRow: View {
    let session: SessionDescriptor
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                FixedTimestamp(date: session.updatedAt, prefix: "最后更新")
                FixedTimestamp(date: session.lastActivityAt ?? session.updatedAt, prefix: "最后进行")
            }
            Spacer()
            Text(session.state.rawValue).font(.caption).foregroundColor(session.state == .error ? .red : .secondary)
        }
    }
}

struct WebProjectView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let project: WebProjectDescriptor
    @State private var loadingMore = false
    @State private var creatingChat = false
    @State private var createdSession: SessionDescriptor?
    @State private var openCreatedSession = false

    private var rows: [WebConversationDescriptor] { store.projectConversationsByAlias[project.projectAlias, default: []] }

    var body: some View {
        List {
            Section {
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
            Section("最近对话") {
                if store.projectConversationLoadingByAlias[project.projectAlias] == true {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(rows.isEmpty ? "正在加载这个 Project 的最新对话…" : "正在后台刷新，当前列表仍可使用…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if store.projectConversationSnapshotStateByAlias[project.projectAlias] == .partialDOM && !rows.isEmpty {
                    Label("当前显示 Windows 已验证的对话列表，ChatGPT 页面仍在后台补全。", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(rows) { conversation in
                    let resolvedSession = store.sessions.first(where: { $0.id == conversation.localConversationId }) ?? conversation.session
                    NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: resolvedSession)) {
                        SessionRow(session: resolvedSession)
                    }
                }
                if store.projectHasMoreByAlias[project.projectAlias] == true {
                    Button(loadingMore ? "加载中…" : "加载更多") {
                        guard !loadingMore else { return }
                        loadingMore = true
                        Task { await store.loadMoreProjectConversations(projectAlias: project.projectAlias); loadingMore = false }
                    }.disabled(loadingMore)
                }
            }
            if let error = store.errors["web.project.\(project.projectAlias)"] { Section { ErrorBanner(text: error) { store.clearError(sessionId: "web.project.\(project.projectAlias)") } } }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle(project.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(
            Group {
                if let createdSession {
                    NavigationLink(
                        destination: ChatView(runtime: runtime, instance: instance, session: createdSession),
                        isActive: $openCreatedSession
                    ) { EmptyView() }
                    .hidden()
                }
            }
        )
        .task { await store.loadProjectConversations(projectAlias: project.projectAlias, force: true) }
        .onChange(of: store.machine.state) { state in
            guard state == .online, rows.isEmpty else { return }
            Task { await store.loadProjectConversations(projectAlias: project.projectAlias, force: false) }
        }
        .refreshable { await store.loadProjectConversations(projectAlias: project.projectAlias, force: true) }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let session: SessionDescriptor
    // The composer alone observes keystrokes. ChatView keeps the reference but
    // does not invalidate the history/scroll tree for every text edit.
    @State private var draft = ComposerDraft()
    private var input: String {
        get { draft.text }
        nonmutating set { draft.text = newValue }
    }
    @State private var loadingOlder = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var attachmentError: String?
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?
    @State private var composerCommandId: UUID?
    @State private var selectedCodexModel = ""
    @State private var voiceBaseText = ""
    @State private var isAtBottom = true
    @State private var didInitialScrollToBottom = false
    @State private var userBrowsingHistory = false
    @StateObject private var speechInput = SpeechInputController()
    @FocusState private var focused: Bool

    var messages: [ChatMessage] {
        store.deltaRecoveryDisplayMessagesBySession?[session.id]
            ?? store.messagesBySession[session.id, default: []]
    }
    private var codexModels: [CodexModelOption] { instance.codexCatalog?.models ?? [] }
    private var currentSession: SessionDescriptor {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }
    private var currentSessionState: SessionState { currentSession.state }
    private var generationStatusText: String {
        store.liveRunStatusBySession[session.id]
            ?? currentSession.lastProgressStatus
            ?? (runtime.kind == .web ? "电脑端 ChatGPT 正在处理…" : "电脑端任务正在处理…")
    }
    private var generationProgressAt: Date? {
        currentSession.lastProgressAt ?? currentSession.lastActivityAt
    }
    private var isGenerating: Bool {
        currentSessionState == .busy
            || currentSessionState == .waiting
            || store.liveRunStatusBySession[session.id] != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if store.machine.state != .online || store.connectionPhase != .online {
                StatusBanner(
                    text: store.errors["connection"] ?? store.connectionPhase.displayName,
                    systemImage: "wifi.exclamationmark"
                )
            }
            if let syncError = store.errors["sync"] {
                StatusBanner(text: "同步异常：\(syncError)", systemImage: "arrow.triangle.2.circlepath")
            }
            if let notice = store.recentSystemNotice {
                StatusBanner(
                    text: notice,
                    systemImage: "desktopcomputer.and.arrow.down",
                    dismiss: { store.clearRecentSystemNotice() }
                )
            }
            if let error = store.errors[session.id] { ErrorBanner(text: error) { store.clearError(sessionId: session.id) } }
            if let attachmentError { ErrorBanner(text: attachmentError) { self.attachmentError = nil } }
            if let voiceError = speechInput.errorMessage { ErrorBanner(text: voiceError) { speechInput.dismissError() } }
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            Color.clear.frame(height: 1).id("top").onAppear { guard didInitialScrollToBottom, userBrowsingHistory, !loadingOlder, store.hasMoreBySession[session.id] != false, let anchor = messages.first?.id else { return }; loadingOlder = true; Task { await store.loadOlder(session.id); await MainActor.run { proxy.scrollTo(anchor, anchor: .top); loadingOlder = false } } }
                            if loadingOlder { ProgressView().padding(.vertical, 6) }
                            ForEach(messages) { message in
                                let commandState = UUID(uuidString: message.id).flatMap { store.commandStates[$0] }
                                // Definite failures restore the composer and use a new operation.
                                // Only unknown delivery is replayed with the original command ID.
                                let retryable = message.kind == .error || commandState == .unknown
                                if message.toolStatus == "Streaming", let stream = store.assistantStreams[message.sessionId] {
                                    AssistantStreamRow(stream: stream, message: message, followTail: {
                                        guard !userBrowsingHistory else { return }
                                        proxy.scrollTo("bottom", anchor: .bottom)
                                    }).id(message.id)
                                } else {
                                    MessageRow(message: message, commandState: commandState, retry: retryable ? { Task { await store.retry(message: message, runtimeId: runtime.id, instanceId: instance.id, model: runtime.kind == .codex ? selectedCodexModel : "") } } : nil, retryContextKey: selectedCodexModel).equatable().id(message.id)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .onAppear {
                                    isAtBottom = true
                                    userBrowsingHistory = false
                                }
                                .onDisappear { isAtBottom = false }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .background(Color(.systemGroupedBackground))
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { _ in userBrowsingHistory = true }
                    )
                    .onAppear {
                        guard !didInitialScrollToBottom, !messages.isEmpty else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo("bottom", anchor: .bottom)
                            didInitialScrollToBottom = true
                        }
                    }
                    .onChange(of: messages.last?.id) { _ in
                        guard !loadingOlder, !messages.isEmpty else { return }
                        if !didInitialScrollToBottom {
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                                didInitialScrollToBottom = true
                            }
                        } else if !userBrowsingHistory {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }

                    if didInitialScrollToBottom, !isAtBottom, !messages.isEmpty {
                        Button {
                            userBrowsingHistory = false
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                                .shadow(radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("回到最新消息")
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .remoteAITopBreathingRoom()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { VStack(spacing: 1) { Text(instance.name).font(.subheadline.weight(.semibold)); Text(session.title).font(.caption2).foregroundColor(.secondary); Text(store.machine.state.rawValue).font(.caption2).foregroundColor(store.machine.state == .online ? .green : .secondary) } }
            ToolbarItem(placement: .navigationBarTrailing) { if store.machine.state == .online { Button("Stop") { Task { await store.stop(runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id) } }.font(.caption) } }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if runtime.kind == .codex, !codexModels.isEmpty {
                    HStack(spacing: 8) {
                        Label("Model", systemImage: "cpu")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Picker("Model", selection: $selectedCodexModel) {
                            ForEach(codexModels) { option in Text(option.label).tag(option.id) }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                }
                if isGenerating {
                    HStack(spacing: 9) {
                        ProgressView()
                            .scaleEffect(0.8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(generationStatusText)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            if store.desktopAgentConnected == false {
                                Text("Windows Agent 当前未在线；手机仍会保留 Relay 连接并等待电脑恢复。")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else if store.desktopBrowserConnected == false, runtime.kind == .web {
                                Text("电脑端 Browser Bridge 已断开，正在等待恢复；当前进度可能暂停。")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else if let progressAt = generationProgressAt {
                                Text("电脑端进度更新：\(progressAt.formatted(date: .omitted, time: .standard)) · 可直接发送新指令纠正方向")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("可直接发送新指令纠正方向；也可以先停止。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            Task { await store.stop(runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id) }
                        } label: {
                            Image(systemName: "stop.circle.fill").font(.title3)
                        }
                        .accessibilityLabel("Stop generation")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                }
                if let transfer = store.attachmentTransferBySession[session.id] {
                    HStack(spacing: 10) {
                        ProgressView(value: transfer.fraction)
                            .frame(maxWidth: 110)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上传附件 \(min(transfer.completed + 1, transfer.total))/\(transfer.total)")
                                .font(.caption.weight(.medium))
                            Text(transfer.name).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("取消") { sendTask?.cancel() }
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                }
                Composer(
                    draft: draft,
                    attachments: $pendingAttachments,
                    enabled: store.machine.state == .online && !sending,
                    isGenerating: isGenerating,
                    isRecording: speechInput.isRecording,
                    addPhoto: { showPhotoPicker = true },
                    addFile: { showFilePicker = true },
                    toggleVoice: { toggleVoiceInput() },
                    stop: { Task { await store.stop(runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id) } },
                    send: {
                        if speechInput.isRecording { speechInput.stop() }
                        let text = input
                        let attachments = pendingAttachments
                        let commandId = composerCommandId ?? UUID()
                        let correctingActiveRun = isGenerating
                        focused = false
                        input = ""
                        pendingAttachments.removeAll()
                        sending = true
                        sendTask = Task {
                            if correctingActiveRun {
                                let stopped = await store.stop(runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id)
                                if !stopped {
                                    await MainActor.run {
                                        sending = false
                                        sendTask = nil
                                        if input.isEmpty { input = text }
                                        if pendingAttachments.isEmpty { pendingAttachments = attachments }
                                    }
                                    return
                                }
                            }
                            let sent = await store.send(text: text, runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id, attachments: attachments, model: runtime.kind == .codex ? selectedCodexModel : "", commandId: commandId)
                            await MainActor.run {
                                sending = false
                                sendTask = nil
                                if sent {
                                    composerCommandId = nil
                                    return
                                }
                                let state = store.commandStates[commandId]
                                let hasOptimisticMessage = store.messagesBySession[session.id, default: []].contains { $0.id.caseInsensitiveCompare(commandId.uuidString) == .orderedSame }
                                if state == .unknown && hasOptimisticMessage {
                                    // The final send may already have happened remotely. Keep the
                                    // composer empty; the message-row Retry replays exactly once.
                                    composerCommandId = nil
                                    return
                                }
                                if input.isEmpty { input = text }
                                if pendingAttachments.isEmpty { pendingAttachments = attachments }
                                // If only attachment transfer was interrupted, there is no remote
                                // message yet. Reusing this ID also reuses deterministic upload IDs.
                                composerCommandId = state == .unknown ? commandId : nil
                            }
                        }
                    }
                ).focused($focused)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryAttachmentPicker(maxSelection: max(1, 8 - pendingAttachments.count)) { result in
                appendAttachments(result)
                showPhotoPicker = false
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): appendFileURLs(urls)
            case .failure(let error): attachmentError = error.localizedDescription
            }
        }
        .onDisappear { speechInput.stop() }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                speechInput.stop()
            } else {
                Task { await store.synchronizeVisibleSession(session.id, force: true) }
            }
        }
        .task {
            if runtime.kind == .codex, selectedCodexModel.isEmpty {
                selectedCodexModel = instance.configuredModel
                    ?? instance.codexCatalog?.defaultModel
                    ?? codexModels.first?.id
                    ?? ""
            }
            await store.loadSession(session.id)
            if let mock = store.transport as? MockTransport {
                await mock.runStressIfRequested(sessionId: session.id)
            }
            if input.isEmpty { input = await store.draft(sessionId: session.id) }

            // Push remains the primary path, but a logically-connected websocket can
            // still miss one event around SPA/document replacement. Reconcile only the
            // currently visible conversation at a bounded cadence so the final reply,
            // process state, or provider failure appears without leaving/reopening it.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { break }
                if scenePhase == .active {
                    await store.synchronizeVisibleSession(session.id)
                }
            }
        }
    }

    private func toggleVoiceInput() {
        if speechInput.isRecording {
            speechInput.stop()
            return
        }
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceBaseText = existing
        speechInput.toggle { transcript in
            let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            input = voiceBaseText.isEmpty ? spoken : "\(voiceBaseText) \(spoken)"
        }
    }

    private func appendAttachments(_ incoming: [PendingAttachment]) {
        var merged = pendingAttachments
        for attachment in incoming {
            guard merged.count < 8 else { attachmentError = "一次最多添加 8 个附件。"; break }
            guard attachment.sizeBytes > 0 && attachment.sizeBytes <= 20 * 1024 * 1024 else {
                attachmentError = "附件 \(attachment.name) 超过 20MB，未添加。"
                continue
            }
            merged.append(attachment)
        }
        pendingAttachments = merged
    }

    private func appendFileURLs(_ urls: [URL]) {
        var loaded: [PendingAttachment] = []
        for url in urls.prefix(max(0, 8 - pendingAttachments.count)) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
                if let size = values.fileSize, size > 20 * 1024 * 1024 {
                    attachmentError = "附件 \(values.name ?? url.lastPathComponent) 超过 20MB，未添加。"
                    continue
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let type = values.contentType?.preferredMIMEType
                    ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                loaded.append(PendingAttachment(name: values.name ?? url.lastPathComponent, contentType: type, data: data))
            } catch {
                attachmentError = "读取文件失败：\(url.lastPathComponent)"
            }
        }
        appendAttachments(loaded)
    }
}

final class ComposerDraft: ObservableObject {
    @Published var text = ""
}

struct Composer: View {
    @ObservedObject var draft: ComposerDraft
    private var text: String { draft.text }
    @Binding var attachments: [PendingAttachment]
    let enabled: Bool
    let isGenerating: Bool
    let isRecording: Bool
    let addPhoto: () -> Void
    let addFile: () -> Void
    let toggleVoice: () -> Void
    let stop: () -> Void
    let send: () -> Void

    private var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var shouldShowStop: Bool { isGenerating && !hasDraft }

    private var canSend: Bool {
        enabled && hasDraft
    }

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: attachment.contentType.hasPrefix("image/") ? "photo" : "doc")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(attachment.name).font(.caption).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(attachment.name)")
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button(action: addPhoto) { Label("从照片选择", systemImage: "photo.on.rectangle") }
                    Button(action: addFile) { Label("选择文件", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus.circle").font(.title2).frame(width: 44, height: 44)
                }
                .disabled(attachments.count >= 8)
                .accessibilityLabel("Attachments")

                Button(action: toggleVoice) {
                    Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle")
                        .font(.title2)
                        .frame(width: 38, height: 44)
                        .foregroundColor(isRecording ? .accentColor : .secondary)
                }
                .disabled(!enabled)
                .accessibilityLabel(isRecording ? "Stop voice input" : "Voice input")

                TextEditor(text: $draft.text)
                    .frame(minHeight: 36, maxHeight: 92)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(.separator), lineWidth: 0.5))
                    .accessibilityIdentifier("MessageComposer")

                Button(action: shouldShowStop ? stop : send) {
                    Image(systemName: shouldShowStop ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                        .foregroundColor((shouldShowStop && enabled) || canSend ? .accentColor : .secondary)
                }
                .disabled(shouldShowStop ? !enabled : !canSend)
                .accessibilityLabel(shouldShowStop ? "Stop generation" : (isGenerating ? "Send correction" : "Send"))
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct PhotoLibraryAttachmentPicker: UIViewControllerRepresentable {
    let maxSelection: Int
    let onComplete: ([PendingAttachment]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = max(1, min(maxSelection, 8))
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PendingAttachment]) -> Void
        init(onComplete: @escaping ([PendingAttachment]) -> Void) { self.onComplete = onComplete }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { onComplete([]); return }
            let group = DispatchGroup()
            let lock = NSLock()
            var attachments: [PendingAttachment] = []
            for result in results.prefix(8) {
                let provider = result.itemProvider
                let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
                    ?? UTType.image.identifier
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    defer { group.leave() }
                    guard let data, !data.isEmpty else { return }
                    let type = UTType(typeIdentifier)
                    let name = provider.suggestedName
                        ?? "Photo-\(UUID().uuidString.prefix(8)).\(type?.preferredFilenameExtension ?? "jpg")"
                    let attachment = PendingAttachment(
                        name: name,
                        contentType: type?.preferredMIMEType ?? "image/jpeg",
                        data: data
                    )
                    lock.lock(); attachments.append(attachment); lock.unlock()
                }
            }
            group.notify(queue: .main) { self.onComplete(attachments) }
        }
    }
}

enum MessageRenderingPolicy {
    static let inlineByteLimit = 12 * 1024
    static let inlineCharacterLimit = 2_000

    static func isLarge(_ value: String) -> Bool {
        value.utf8.count > inlineByteLimit
    }

    static func inlineText(_ value: String) -> String {
        guard isLarge(value) else { return value }
        let preview = String(value.prefix(inlineCharacterLimit))
        return preview + "\n\n…（长消息已折叠，点击下方“查看全文”读取完整内容）"
    }
}

struct MessageContentSegment: Identifiable, Equatable {
    private static let editBlockMarker = "__REMOTEAI_EDIT_BLOCK__"

    let id: Int
    let text: String
    let isCode: Bool
    let language: String?

    var isEditBlock: Bool { !isCode && language == Self.editBlockMarker }

    static func parse(_ value: String) -> [MessageContentSegment] {
        var result: [MessageContentSegment] = []
        let nsValue = value as NSString
        let pattern = #"(^|\r?\n[ \t]*\r?\n)[ \t]*Edit[ \t]*\r?\n[ \t]*\r?\n"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
        let allMatches = regex?.matches(in: value, range: NSRange(location: 0, length: nsValue.length)) ?? []
        var fenceCursor = 0
        var insideFence = false
        let matches = allMatches.filter { match in
            // Scan each interval once; rebuilding every preceding prefix made
            // repeated Edit blocks quadratic in the size of the input.
            while fenceCursor < match.range.location {
                let fence = nsValue.range(of: "```", options: [], range: NSRange(location: fenceCursor, length: match.range.location - fenceCursor))
                guard fence.location != NSNotFound else { break }
                insideFence.toggle()
                fenceCursor = NSMaxRange(fence)
            }
            fenceCursor = match.range.location
            return !insideFence
        }

        if !matches.isEmpty {
            var cursor = 0
            for (index, match) in matches.enumerated() {
                if match.range.location > cursor {
                    appendMarkdownSegments(nsValue.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &result)
                }
                let bodyStart = NSMaxRange(match.range)
                let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsValue.length
                if bodyEnd > bodyStart {
                    let body = nsValue.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        result.append(MessageContentSegment(id: result.count, text: body, isCode: false, language: editBlockMarker))
                    }
                }
                cursor = bodyEnd
            }
            if cursor < nsValue.length {
                appendMarkdownSegments(nsValue.substring(from: cursor), to: &result)
            }
            if !result.isEmpty { return result }
        }

        appendMarkdownSegments(value, to: &result)
        return result.isEmpty ? [MessageContentSegment(id: 0, text: value, isCode: false, language: nil)] : result
    }

    private static func appendMarkdownSegments(_ value: String, to result: inout [MessageContentSegment]) {
        let parts = value.components(separatedBy: "```")
        if parts.count == 1 {
            if !value.isEmpty {
                result.append(MessageContentSegment(id: result.count, text: value, isCode: false, language: nil))
            }
            return
        }
        for (index, rawPart) in parts.enumerated() where !rawPart.isEmpty {
            let isCode = index % 2 == 1
            var text = rawPart
            var language: String? = nil
            if isCode, let newline = text.firstIndex(of: "\n") {
                let firstLine = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !firstLine.isEmpty,
                   firstLine.count <= 24,
                   firstLine.range(of: "^[A-Za-z0-9_+.-]+$", options: .regularExpression) != nil {
                    language = firstLine
                    text = String(text[text.index(after: newline)...])
                }
            }
            let cleaned = isCode ? text.trimmingCharacters(in: .newlines) : text
            if !cleaned.isEmpty {
                result.append(MessageContentSegment(id: result.count, text: cleaned, isCode: isCode, language: language))
            }
        }
    }
}

struct SelectableTextEditor: UIViewRepresentable {
    let text: String
    var monospaced = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        configure(view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: UITextView) {
        if view.text != text { view.text = text }
        if monospaced {
            let size = UIFont.preferredFont(forTextStyle: .body).pointSize
            view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            view.font = UIFont.preferredFont(forTextStyle: .body)
        }
        view.textColor = .label
    }
}

private struct TextSelectionRequest: Identifiable {
    let id = UUID()
    let text: String
    let monospaced: Bool
}

struct TextSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let monospaced: Bool

    var body: some View {
        NavigationView {
            SelectableTextEditor(text: text, monospaced: monospaced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .navigationTitle("选择文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("全部复制") { UIPasteboard.general.string = text }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

// Cache prepared content, not SwiftUI views or selection sheets. A streaming
// replacement invalidates only its own entry; unrelated store publications do
// not repeat attachment regexes, preview copies and segment parsing.
final class MessageRenderContent: NSObject {
    let sourceText: String
    let sourceAttachments: [MessageAttachment]?
    let sourceDetail: String?
    let displayText: String
    let attachments: [MessageAttachment]
    let isLarge: Bool
    let segments: [MessageContentSegment]
    let inlineDetail: String?

    init(message: ChatMessage) {
        sourceText = message.text
        sourceAttachments = message.attachments
        sourceDetail = message.detail
        displayText = message.displayText
        attachments = message.resolvedAttachments
        isLarge = MessageRenderingPolicy.isLarge(displayText)
        segments = MessageContentSegment.parse(MessageRenderingPolicy.inlineText(displayText))
        inlineDetail = message.detail.map { MessageRenderingPolicy.inlineText($0) }
    }

    func matches(_ message: ChatMessage) -> Bool {
        sourceText == message.text && sourceAttachments == message.attachments && sourceDetail == message.detail
    }
}

final class MessageRenderCache {
    static let shared = MessageRenderCache()
    private let entries = NSCache<NSString, MessageRenderContent>()

    init() {
        entries.countLimit = 128
        entries.totalCostLimit = 4 * 1024 * 1024
    }

    func content(for message: ChatMessage) -> MessageRenderContent {
        let key = "\(message.sessionId.utf8.count):\(message.sessionId)\(message.id)" as NSString
        if let cached = entries.object(forKey: key), cached.matches(message) { return cached }
        let content = MessageRenderContent(message: message)
        let cost = message.text.utf8.count + content.displayText.utf8.count
            + (message.detail?.utf8.count ?? 0) + content.segments.reduce(0) { $0 + $1.text.utf8.count }
        entries.setObject(content, forKey: key, cost: cost)
        return content
    }
}

struct AssistantStreamRow: View {
    @ObservedObject var stream: AssistantStream
    @Environment(\.scenePhase) private var scenePhase
    let message: ChatMessage
    var followTail: () -> Void = {}
    @State private var followTask: Task<Void, Never>?

    var body: some View {
        let began = StreamPerformance.now
        let _ = stream.performance.rowUpdated(bytes: stream.visibleBytes)
        var visible = message
        visible.text = stream.visibleText
        let _ = MessageRenderCache.shared.content(for: visible)
        let _ = stream.performance.preparation.add((StreamPerformance.now - began) * 1000)
        return VStack(alignment: .leading, spacing: 4) {
            MessageRow(message: visible, commandState: nil, retry: nil, fullStreamingText: { stream.text })
            Text("已接收 \(stream.visibleBytes) 字节 · 显示最新内容")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("assistant-stream-progress")
        }
        .onAppear { stream.performance.startFrames() }
        .onDisappear {
            stream.performance.stopFrames()
            followTask?.cancel()
            followTask = nil
        }
        .onChange(of: stream.visibleBytes) { _ in
            // Coalesce presentation ticks, without postponing indefinitely while
            // deltas keep arriving. The callback rechecks browsing at execution.
            guard followTask == nil else { return }
            followTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
                followTail()
                followTask = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { stream.performance.startFrames() }
            else { stream.performance.stopFrames() }
        }
    }
}

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let commandState: CommandState?
    let retry: (() -> Void)?
    var retryContextKey: String = ""
    var fullStreamingText: (() -> String)? = nil

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.commandState == rhs.commandState
            && (lhs.retry == nil) == (rhs.retry == nil) && lhs.retryContextKey == rhs.retryContextKey
    }
    @State private var toolExpanded = true
    @State private var selectionRequest: TextSelectionRequest?
    private var renderContent: MessageRenderContent { MessageRenderCache.shared.content(for: message) }
    private var displayText: String { renderContent.displayText }
    private var displayAttachments: [MessageAttachment] { renderContent.attachments }
    private var isLargeDisplayText: Bool { renderContent.isLarge || (fullStreamingText != nil && message.text.count >= 2001) }
    private var contentSegments: [MessageContentSegment] { renderContent.segments }
    private var selectionText: String { fullStreamingText?() ?? displayText }

    var body: some View {
        Group {
            if message.kind == .toolEvent {
                DisclosureGroup(isExpanded: $toolExpanded) {
                    if let detail = message.detail {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(renderContent.inlineDetail ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            HStack(spacing: 12) {
                                if MessageRenderingPolicy.isLarge(detail) {
                                    Button("查看全文") {
                                        selectionRequest = TextSelectionRequest(text: detail, monospaced: true)
                                    }
                                }
                                Button("选择部分") {
                                    selectionRequest = TextSelectionRequest(text: detail, monospaced: true)
                                }
                                Button("复制整块") { UIPasteboard.general.string = message.toolCardCopyText }
                                Button("选择整块") {
                                    selectionRequest = TextSelectionRequest(text: message.toolCardCopyText, monospaced: true)
                                }
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        }
                        .padding(.top, 6)
                    }
                } label: {
                    HStack { Image(systemName: message.toolStatus == "Completed" ? "checkmark.circle.fill" : "gearshape.2"); VStack(alignment: .leading, spacing: 2) { Text(message.toolName ?? "Tool").font(.subheadline.weight(.semibold)); Text(message.toolStatus ?? "Running").font(.caption).foregroundColor(.secondary) }; Spacer() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.toolCardCopyText
                    } label: {
                        Label("复制整块", systemImage: "doc.on.doc")
                    }
                    Button {
                        selectionRequest = TextSelectionRequest(text: message.toolCardCopyText, monospaced: true)
                    } label: {
                        Label("选择整块", systemImage: "text.cursor")
                    }
                }
            } else {
                HStack(alignment: .bottom) {
                    if message.role == .user { Spacer(minLength: 44) }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(contentSegments) { segment in
                            if segment.isEditBlock {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Label("Edit", systemImage: "square.and.pencil")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = segment.text
                                        } label: {
                                            Label("复制整块", systemImage: "doc.on.doc")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.borderless)
                                        Button("选择部分") {
                                            selectionRequest = TextSelectionRequest(text: segment.text, monospaced: false)
                                        }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                    }
                                    Text(segment.text)
                                        .textSelection(.enabled)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = segment.text
                                    } label: {
                                        Label("复制整块", systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        selectionRequest = TextSelectionRequest(text: segment.text, monospaced: false)
                                    } label: {
                                        Label("选择部分", systemImage: "text.cursor")
                                    }
                                }
                            } else if segment.isCode {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(segment.language?.isEmpty == false ? segment.language! : "EDIT / Code")
                                            .font(.caption2.weight(.medium))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button("选择部分") {
                                            selectionRequest = TextSelectionRequest(text: segment.text, monospaced: true)
                                        }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                        Button {
                                            UIPasteboard.general.string = segment.text
                                        } label: {
                                            Label("复制", systemImage: "doc.on.doc")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    Text(segment.text)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .padding(9)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                            } else {
                                if fullStreamingText != nil {
                                    // Live text changes continuously; native selection
                                    // bookkeeping is reserved for the full-text sheet.
                                    Text(segment.text)
                                } else {
                                    Text(segment.text).textSelection(.enabled)
                                }
                            }
                        }
                        if isLargeDisplayText {
                            Button {
                                selectionRequest = TextSelectionRequest(text: selectionText, monospaced: false)
                            } label: {
                                Label(fullStreamingText != nil ? "查看全文（生成中）" : "查看全文（约 \(max(1, displayText.utf8.count / 1024)) KB）", systemImage: "doc.text.magnifyingglass")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                            Text(fullStreamingText != nil ? "正在显示最新生成的内容，可查看或复制当前全文。" : "长消息已折叠，可查看或复制全文。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if !displayAttachments.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(displayAttachments) { attachment in
                                    MessageAttachmentView(sessionId: message.sessionId, attachment: attachment)
                                }
                            }
                        }
                        if !displayText.isEmpty {
                            HStack(spacing: 12) {
                                Button {
                                    UIPasteboard.general.string = selectionText
                                } label: {
                                    Label("复制全文", systemImage: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                Button {
                                    selectionRequest = TextSelectionRequest(text: selectionText, monospaced: false)
                                } label: {
                                    Label("选择部分", systemImage: "text.cursor")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if message.toolStatus == "Streaming" { ProgressView().scaleEffect(0.7) }
                        if message.role == .user, let commandState {
                            Text(commandState.rawValue).font(.caption2).foregroundColor(commandState == .failed || commandState == .unknown ? .red : .secondary)
                        }
                        if let retry { Button("Retry", action: retry).font(.caption) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16).fill(message.role == .user ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground)))
                    if message.role != .user { Spacer(minLength: 44) }
                }
            }
        }
        .sheet(item: $selectionRequest) { request in
            TextSelectionSheet(text: request.text, monospaced: request.monospaced)
        }
    }
}

private struct AttachmentPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SystemActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

enum AttachmentPreviewPolicy {
    static func shouldDismiss(translation: CGSize, predictedEndTranslation: CGSize) -> Bool {
        let vertical = translation.height
        let horizontal = abs(translation.width)
        return vertical > 110
            && vertical > horizontal * 1.35
            && predictedEndTranslation.height > 150
    }
}

private struct AttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: AttachmentPreviewItem
    @State private var showingShare = false
    @State private var showingExport = false

    var body: some View {
        NavigationView {
            QuickLookPreview(url: item.url)
                .navigationTitle(item.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("关闭预览")
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showingExport = true } label: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .accessibilityLabel("下载到文件")
                        Button { showingShare = true } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享附件")
                    }
                }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if AttachmentPreviewPolicy.shouldDismiss(
                        translation: value.translation,
                        predictedEndTranslation: value.predictedEndTranslation
                    ) {
                        dismiss()
                    }
                }
        )
        .interactiveDismissDisabled(false)
        .sheet(isPresented: $showingExport) {
            DocumentExportPicker(url: item.url)
        }
        .sheet(isPresented: $showingShare) {
            SystemActivitySheet(url: item.url)
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }
}

private struct MessageAttachmentView: View {
    @EnvironmentObject var store: WorkspaceStore
    let sessionId: String
    let attachment: MessageAttachment
    @State private var cachedImage: UIImage?
    @State private var cacheLoadFinished = false
    @State private var previewItem: AttachmentPreviewItem?
    @State private var previewError: String?
    @State private var isOpeningPreview = false

    private var canOpenFromAgent: Bool {
        attachment.attachmentId?.hasPrefix("webasset-") == true
    }

    private var targetURL: URL? {
        if let downloadURL = attachment.downloadURL, let url = URL(string: downloadURL) { return url }
        if let previewURL = attachment.previewURL, let url = URL(string: previewURL) { return url }
        return nil
    }

    private var metadataText: String {
        var parts: [String] = []
        if let contentType = attachment.contentType, !contentType.isEmpty { parts.append(contentType) }
        if let sizeBytes = attachment.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        return parts.isEmpty ? (attachment.isImage ? "图片" : "文件") : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if canOpenFromAgent {
                Button(action: openFromAgent) { cardContent }
                    .buttonStyle(.plain)
                    .disabled(isOpeningPreview)
            } else if let targetURL {
                Link(destination: targetURL) { cardContent }
                    .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
        .sheet(item: $previewItem) { item in
            AttachmentPreviewSheet(item: item)
        }
        .alert("无法打开附件", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("确定", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "附件暂时不可用。")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("附件 \(attachment.name)")
        .accessibilityHint(canOpenFromAgent ? "双击预览附件" : "")
    }

    private var cardContent: some View {
        HStack(spacing: 10) {
            if attachment.isImage, attachment.attachmentId?.hasPrefix("webasset-") == true {
                Group {
                    if let cachedImage {
                        Image(uiImage: cachedImage).resizable().scaledToFill()
                    } else if cacheLoadFinished {
                        Image(systemName: "photo").font(.title3).foregroundColor(.secondary)
                    } else {
                        ProgressView().scaleEffect(0.75)
                    }
                }
                .frame(width: 58, height: 58)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .task(id: attachment.id) {
                    guard cachedImage == nil, !cacheLoadFinished else { return }
                    if let data = await store.loadMessageAttachmentData(sessionId: sessionId, attachment: attachment) {
                        cachedImage = UIImage(data: data)
                    }
                    cacheLoadFinished = true
                }
            } else if attachment.isImage, let previewURL = attachment.previewURL, let url = URL(string: previewURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: ProgressView().scaleEffect(0.75)
                    default: Image(systemName: "photo").font(.title3).foregroundColor(.secondary)
                    }
                }
                .frame(width: 58, height: 58)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc.fill")
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemGroupedBackground)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(metadataText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if isOpeningPreview {
                ProgressView().scaleEffect(0.7)
            } else if canOpenFromAgent {
                Image(systemName: "doc.text.magnifyingglass").font(.caption).foregroundColor(.secondary)
            } else if targetURL != nil {
                Image(systemName: "arrow.up.right.square").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground).opacity(0.7)))
    }

    private func openFromAgent() {
        guard !isOpeningPreview else { return }
        isOpeningPreview = true
        Task { @MainActor in
            defer { isOpeningPreview = false }
            guard let data = await store.loadMessageAttachmentData(sessionId: sessionId, attachment: attachment) else {
                previewError = "无法从当前网页会话读取这个附件。请确认电脑端 ChatGPT 页面仍能访问该文件。"
                return
            }
            do {
                let safeName = preferredPreviewFilename(data: data)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteAI-Previews", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
                try data.write(to: url, options: .atomic)
                previewItem = AttachmentPreviewItem(url: url)
            } catch {
                previewError = "附件已下载，但无法创建本地预览文件。"
            }
        }
    }

    private func preferredPreviewFilename(data: Data) -> String {
        let raw = URL(fileURLWithPath: attachment.name).lastPathComponent
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let sanitized = raw
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        var name = sanitized.isEmpty ? "attachment" : String(sanitized.prefix(180))
        guard (name as NSString).pathExtension.isEmpty else { return name }

        let sourceExtension = [attachment.downloadURL, attachment.previewURL]
            .compactMap { $0 }
            .compactMap { URL(string: $0) }
            .map { $0.pathExtension }
            .first { !$0.isEmpty }
        if let sourceExtension {
            return name + "." + sourceExtension
        }

        if let contentType = attachment.contentType,
           !contentType.contains("*"),
           let type = UTType(mimeType: contentType),
           let fileExtension = type.preferredFilenameExtension,
           !fileExtension.isEmpty {
            return name + "." + fileExtension
        }

        let bytes = [UInt8](data.prefix(12))
        let inferred: String?
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            inferred = "png"
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            inferred = "jpg"
        } else if bytes.starts(with: Array("GIF8".utf8)) {
            inferred = "gif"
        } else if bytes.count >= 12,
                  Array(bytes[0..<4]) == Array("RIFF".utf8),
                  Array(bytes[8..<12]) == Array("WEBP".utf8) {
            inferred = "webp"
        } else if bytes.starts(with: Array("%PDF".utf8)) {
            inferred = "pdf"
        } else if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            inferred = "zip"
        } else {
            inferred = nil
        }
        if let inferred { name += "." + inferred }
        return name
    }
}

struct ErrorBanner: View { let text: String; let dismiss: () -> Void; var body: some View { HStack { Image(systemName: "exclamationmark.triangle"); Text(text).font(.caption); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") } }.padding(10).background(Color.red.opacity(0.12)) } }
struct StatusBanner: View {
    let text: String
    let systemImage: String
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
struct StatusLabel: View { let text: String; let active: Bool; var body: some View { HStack(spacing: 5) { Circle().fill(active ? Color.green : Color.secondary).frame(width: 7, height: 7); Text(text).font(.caption).foregroundColor(.secondary) } } }

struct NewWebProjectView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var creating = false

    var body: some View {
        NavigationView {
            Form {
                Section("ChatGPT Project") {
                    TextField("Project 名称", text: $name)
                    Text("Windows 会在你当前已登录的 ChatGPT 页面里真实创建 Project。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let error = store.errors["web.projects"] {
                    Section {
                        ErrorBanner(text: error) { store.clearError(sessionId: "web.projects") }
                    }
                }
            }
            .remoteAITopBreathingRoom()
            .navigationTitle("新建 Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Creating…" : "Create") {
                        creating = true
                        Task {
                            let created = await store.createWebProject(name: name)
                            creating = false
                            if created != nil { dismiss() }
                        }
                    }
                    .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct NewSessionView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor

    @State private var title = ""
    @State private var model = ""
    @State private var creating = false

    private var codexCatalog: CodexCatalog {
        instance.codexCatalog ?? CodexCatalog(models: [], defaultModel: instance.configuredModel)
    }

    private var canCreate: Bool {
        if runtime.kind == .codex {
            return !model.isEmpty && codexCatalog.models.contains(where: { $0.id == model })
        }
        return true
    }

    var body: some View {
        NavigationView {
            Form {
                Section("工作区") {
                    Text(instance.name).font(.headline)
                    if let subtitle = instance.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    }
                    TextField("会话名称", text: $title)
                }

                if let error = store.errors[instance.id] {
                    Section { ErrorBanner(text: error) { store.clearError(sessionId: instance.id) } }
                }

                if runtime.kind == .codex {
                    Section("模型") {
                        if codexCatalog.models.isEmpty {
                            Text("Windows 尚未提供此 Codex 实例的模型目录。")
                                .font(.caption).foregroundColor(.orange)
                        } else {
                            Picker("Model", selection: $model) {
                                ForEach(codexCatalog.models) { option in
                                    Text(option.label).tag(option.id)
                                }
                            }
                        }
                    }
                }
            }
            .remoteAITopBreathingRoom()
            .navigationTitle(runtime.kind == .web ? "New Chat" : "New Session")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if runtime.kind == .codex {
                    model = instance.configuredModel
                        ?? codexCatalog.defaultModel
                        ?? codexCatalog.models.first?.id
                        ?? ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Creating…" : "Create") {
                        creating = true
                        Task {
                            let created = await store.createSession(
                                runtime: runtime,
                                instance: instance,
                                title: title,
                                model: model
                            )
                            creating = false
                            if created { dismiss() }
                        }
                    }
                    .disabled(creating || !canCreate)
                }
            }
        }
    }
}

struct PairingView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var relay = RemoteAIConfig.loadMetadata().relayBaseURL.absoluteString
    @State private var machineId = RemoteAIConfig.loadMetadata().machineId
    @State private var code = ""
    @State private var scanner = false
    @State private var error: String?
    @State private var pairing = false

    var body: some View {
        NavigationView { Form {
            Section("Windows Relay") {
                TextField("https://relay.example.com", text: $relay).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                TextField("Machine ID", text: $machineId).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                TextField("8-digit pairing code", text: $code).keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                Button { scanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
            }
            Section {
                Text("Pairing uses X25519 + HKDF-SHA256. Device private/shared keys are ThisDeviceOnly Keychain items; Cloudflare only routes AES-256-GCM encrypted payloads.").font(.caption).foregroundColor(.secondary)
            }
            if pairing {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.pairingStage?.title ?? "Preparing secure pairing…").font(.subheadline.weight(.medium))
                            Text(pairingDetail).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            if let error { Section("Pairing error") { Text(error).foregroundColor(.red).font(.caption) } }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle("Pair Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(pairing) }
            ToolbarItem(placement: .confirmationAction) {
                Button(pairing ? "Pairing…" : "Pair") {
                    beginPairing()
                }
                .disabled(pairing)
            }
        }
        .sheet(isPresented: $scanner) {
            QRScannerView { value in
                let complete = applyScannedPairing(value)
                scanner = false
                if complete { beginPairing() }
            }
        } }
    }

    private var pairingDetail: String {
        switch store.pairingStage {
        case .connectingRelay: return "Opening the secure Cloudflare Relay connection."
        case .relayConnected: return "Relay accepted this iPhone and Windows is online."
        case .sendingRequest: return "Sending this iPhone's ephemeral public key to Windows."
        case .waitingChallenge: return "Waiting for the Windows pairing challenge."
        case .challengeReceived, .verifyingWindowsKey: return "Validating the Windows X25519 identity before proving the code."
        case .sendingProof, .waitingApproval: return "Completing the code proof with Windows."
        case .secureKeySaved: return "The derived shared key is stored in ThisDeviceOnly Keychain."
        case .connectingRemoteAI: return "Reconnecting with the newly paired key."
        case .loadingRuntimes: return "Loading Web and Codex from Windows."
        case .completed: return "Pairing completed successfully."
        default: return "Every network step is time-limited; the Pair button will recover on failure."
        }
    }

    private func beginPairing() {
        guard !pairing else { return }
        guard let url = URL(string: relay), !machineId.isEmpty, ProtocolSecurity.validatePairingCode(code) else {
            error = "Enter an HTTPS relay URL, Machine ID, and 8-digit code."
            return
        }
        pairing = true
        store.pairingStage = .preparing
        error = nil
        Task {
            do {
                try await store.savePairing(baseURL: url, machineId: machineId, code: code)
                pairing = false
                dismiss()
            } catch {
                pairing = false
                self.error = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func applyScannedPairing(_ value: String) -> Bool {
        guard let payload = PairingScanPayload.parse(value) else {
            error = "The QR code does not contain RemoteAI pairing information."
            return false
        }
        if let url = payload.relayBaseURL { relay = url.absoluteString }
        if let value = payload.machineId { machineId = value }
        if let value = payload.pairingCode { code = value }
        error = payload.isComplete ? nil : "QR read successfully. Complete any missing pairing fields, then tap Pair."
        return payload.isComplete
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerController { let vc = QRScannerController(); vc.onCode = onCode; return vc }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input); let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }; session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; preview.frame = view.bounds; view.layer.addSublayer(preview); session.startRunning()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); (view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) { guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }; session.stopRunning(); onCode?(value) }
}
