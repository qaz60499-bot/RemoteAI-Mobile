import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

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

struct DiagnosticsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var copied = false

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
                    Button("清空") { log.clear() }
                    Button(copied ? "已复制" : "复制") {
                        log.copyToPasteboard()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
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
                    Button { Task { _ = await store.createWebConversation() } } label: {
                        Label("新建普通 ChatGPT 对话", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("普通对话与 Projects 分开显示，不会混在一起。")
                }
                Section("普通聊天") {
                    ForEach(store.sessions.filter { $0.instanceId == instance.id && $0.projectAlias == nil }.sorted { $0.updatedAt > $1.updatedAt }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                    }
                }
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
            } else {
                Section {
                    Button { newSession = true } label: {
                        Label("新建会话", systemImage: "plus.circle.fill")
                    }
                }
                Section("历史会话") {
                    ForEach(store.sessions.filter { $0.instanceId == instance.id }.sorted { $0.updatedAt > $1.updatedAt }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                    }
                }
            }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle(instance.name).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $newSession) { NewSessionView(runtime: runtime, instance: instance).environmentObject(store) }
        .sheet(isPresented: $newProject) { NewWebProjectView().environmentObject(store) }
        .task {
            if isChatGPTWeb {
                // Projects are the primary navigation surface here. Refresh them first
                // instead of waiting for the ordinary-chat history request to finish.
                await store.refreshWebProjects(force: false)
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
                FixedTimestamp(date: session.updatedAt)
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

    private var rows: [WebConversationDescriptor] { store.projectConversationsByAlias[project.projectAlias, default: []] }

    var body: some View {
        List {
            Section("最近对话") {
                if store.projectConversationLoadingByAlias[project.projectAlias] == true && rows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载这个 Project 的最新对话…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(rows) { conversation in
                    NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: conversation.session)) {
                        SessionRow(session: conversation.session)
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
            Section { Button { Task { _ = await store.createWebConversation(projectAlias: project.projectAlias) } } label: { Label("在此 Project 新建对话", systemImage: "plus.circle.fill") } }
            if let error = store.errors["web.project.\(project.projectAlias)"] { Section { ErrorBanner(text: error) { store.clearError(sessionId: "web.project.\(project.projectAlias)") } } }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle(project.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadProjectConversations(projectAlias: project.projectAlias) }
        .onChange(of: store.machine.state) { state in
            guard state == .online, rows.isEmpty else { return }
            Task { await store.loadProjectConversations(projectAlias: project.projectAlias) }
        }
        .refreshable { await store.loadProjectConversations(projectAlias: project.projectAlias) }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    let session: SessionDescriptor
    @State private var input = ""
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
    @StateObject private var speechInput = SpeechInputController()
    @FocusState private var focused: Bool

    var messages: [ChatMessage] { store.messagesBySession[session.id, default: []] }
    private var codexModels: [CodexModelOption] { instance.codexCatalog?.models ?? [] }
    private var currentSessionState: SessionState {
        store.sessions.first(where: { $0.id == session.id })?.state ?? session.state
    }
    private var isGenerating: Bool {
        currentSessionState == .busy
            || currentSessionState == .waiting
            || store.liveRunStatusBySession[session.id] != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.errors[session.id] { ErrorBanner(text: error) { store.clearError(sessionId: session.id) } }
            if let attachmentError { ErrorBanner(text: attachmentError) { self.attachmentError = nil } }
            if let voiceError = speechInput.errorMessage { ErrorBanner(text: voiceError) { speechInput.dismissError() } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Color.clear.frame(height: 1).id("top").onAppear { guard !loadingOlder, store.hasMoreBySession[session.id] != false, let anchor = messages.first?.id else { return }; loadingOlder = true; Task { await store.loadOlder(session.id); await MainActor.run { proxy.scrollTo(anchor, anchor: .top); loadingOlder = false } } }
                        if loadingOlder { ProgressView().padding(.vertical, 6) }
                        ForEach(messages) { message in
                            let commandState = UUID(uuidString: message.id).flatMap { store.commandStates[$0] }
                            // Definite failures restore the composer and use a new operation.
                            // Only unknown delivery is replayed with the original command ID.
                            let retryable = message.kind == .error || commandState == .unknown
                            MessageRow(message: message, commandState: commandState, retry: retryable ? { Task { await store.retry(message: message, runtimeId: runtime.id, instanceId: instance.id, model: runtime.kind == .codex ? selectedCodexModel : "") } } : nil).id(message.id)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: messages.last?.id) { _ in if !loadingOlder, let id = messages.last?.id { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) } } }
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
                            Text(store.liveRunStatusBySession[session.id] ?? "正在处理…")
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            Text("可以直接输入新的指令并发送来纠正方向；也可以先停止。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
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
                    text: $input,
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
            if phase != .active { speechInput.stop() }
        }
        .task {
            if runtime.kind == .codex, selectedCodexModel.isEmpty {
                selectedCodexModel = instance.configuredModel
                    ?? instance.codexCatalog?.defaultModel
                    ?? codexModels.first?.id
                    ?? ""
            }
            await store.loadSession(session.id)
            if input.isEmpty { input = await store.draft(sessionId: session.id) }
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

struct Composer: View {
    @Binding var text: String
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

                TextEditor(text: $text)
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

struct MessageRow: View {
    let message: ChatMessage
    let commandState: CommandState?
    let retry: (() -> Void)?
    @State private var toolExpanded = true
    var body: some View {
        if message.kind == .toolEvent {
            DisclosureGroup(isExpanded: $toolExpanded) {
                if let detail = message.detail {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
            } label: {
                HStack { Image(systemName: message.toolStatus == "Completed" ? "checkmark.circle.fill" : "gearshape.2"); VStack(alignment: .leading, spacing: 2) { Text(message.toolName ?? "Tool").font(.subheadline.weight(.semibold)); Text(message.toolStatus ?? "Running").font(.caption).foregroundColor(.secondary) }; Spacer() }
            }.padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        } else {
            HStack(alignment: .bottom) {
                if message.role == .user { Spacer(minLength: 44) }
                VStack(alignment: .leading, spacing: 6) {
                    if message.text.contains("```") { ScrollView(.horizontal, showsIndicators: false) { Text(message.text.replacingOccurrences(of: "```", with: "")).font(.system(.body, design: .monospaced)).textSelection(.enabled) } }
                    else { Text(message.text).textSelection(.enabled) }
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
}

struct ErrorBanner: View { let text: String; let dismiss: () -> Void; var body: some View { HStack { Image(systemName: "exclamationmark.triangle"); Text(text).font(.caption); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") } }.padding(10).background(Color.red.opacity(0.12)) } }
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
