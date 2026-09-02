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
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.title2)
                        VStack(alignment: .leading, spacing: 3) { Text(store.machine.name).font(.headline); StatusLabel(text: store.machine.state.rawValue, active: store.machine.state == .online) }
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
                    Section { Label("Cached workspaces remain available while the PC is offline.", systemImage: "wifi.slash").font(.footnote).foregroundColor(.secondary) }
                }
            }
            .listStyle(.insetGrouped)
            .remoteAITopBreathingRoom()
            .navigationTitle("Remote AI")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showingPair = true } label: { Image(systemName: store.isPaired ? "checkmark.shield" : "qrcode.viewfinder") }.accessibilityLabel("Pair Device") } }
            .sheet(isPresented: $showingPair) { PairingView().environmentObject(store) }
        }.navigationViewStyle(.stack)
    }
    private func runtimeIcon(_ kind: RuntimeKind) -> String { switch kind { case .web: return "globe"; case .cloudCode: return "cloud"; case .codex: return "terminal" } }
}

struct RuntimeView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    var body: some View {
        List {
            if runtime.kind == .cloudCode {
                Section {
                    Text("先选择 Windows 工作区；进入后点“新建 Cloud Code 会话”，可选择厂商、Key Profile 和模型。历史会话只作为次要入口。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
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
    private var filteredProjects: [WebProjectDescriptor] {
        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.webProjects }
        return store.webProjects.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.projectAlias.localizedCaseInsensitiveContains(query) }
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
                    if store.webProjects.isEmpty {
                        let projectStatus: String = {
                            if store.errors["web.projects"] != nil { return "Projects 读取失败 — 下拉刷新重试" }
                            if store.hasLoadedWebProjects { return "当前没有找到 ChatGPT Projects" }
                            return store.machine.state == .online ? "正在读取 ChatGPT Projects…" : "离线 — 显示缓存 Projects"
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
                        Label(runtime.kind == .cloudCode ? "新建 Cloud Code 会话" : "新建会话", systemImage: "plus.circle.fill")
                    }
                    if runtime.kind == .cloudCode {
                        Text("新建时可选择厂商、Key Profile 和模型。")
                            .font(.caption).foregroundColor(.secondary)
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
                await store.refreshSessions(runtime: runtime, instance: instance)
                await store.refreshWebProjects()
            } else {
                await store.refreshSessions(runtime: runtime, instance: instance)
            }
        }
        .refreshable {
            if isChatGPTWeb {
                await store.refreshSessions(runtime: runtime, instance: instance)
                await store.refreshWebProjects()
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
        .refreshable { await store.loadProjectConversations(projectAlias: project.projectAlias) }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: WorkspaceStore
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
    @State private var selectedCodexModel = ""
    @FocusState private var focused: Bool

    var messages: [ChatMessage] { store.messagesBySession[session.id, default: []] }
    private var codexModels: [CodexModelOption] { instance.codexCatalog?.models ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.errors[session.id] { ErrorBanner(text: error) { store.clearError(sessionId: session.id) } }
            if let attachmentError { ErrorBanner(text: attachmentError) { self.attachmentError = nil } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Color.clear.frame(height: 1).id("top").onAppear { guard !loadingOlder, store.hasMoreBySession[session.id] != false, let anchor = messages.first?.id else { return }; loadingOlder = true; Task { await store.loadOlder(session.id); await MainActor.run { proxy.scrollTo(anchor, anchor: .top); loadingOlder = false } } }
                        if loadingOlder { ProgressView().padding(.vertical, 6) }
                        ForEach(messages) { message in
                            let commandState = UUID(uuidString: message.id).flatMap { store.commandStates[$0] }
                            let retryable = message.kind == .error || commandState == .failed || commandState == .unknown
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
                    addPhoto: { showPhotoPicker = true },
                    addFile: { showFilePicker = true },
                    send: {
                        let text = input
                        let attachments = pendingAttachments
                        focused = false
                        input = ""
                        pendingAttachments.removeAll()
                        sending = true
                        sendTask = Task {
                            let sent = await store.send(text: text, runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id, attachments: attachments, model: runtime.kind == .codex ? selectedCodexModel : "")
                            await MainActor.run {
                                sending = false
                                sendTask = nil
                                guard !sent else { return }
                                if input.isEmpty { input = text }
                                if pendingAttachments.isEmpty { pendingAttachments = attachments }
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
    let addPhoto: () -> Void
    let addFile: () -> Void
    let send: () -> Void

    private var canSend: Bool {
        enabled && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
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

                TextEditor(text: $text)
                    .frame(minHeight: 36, maxHeight: 92)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(.separator), lineWidth: 0.5))
                    .accessibilityIdentifier("MessageComposer")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44)
                        .foregroundColor(canSend ? .accentColor : .secondary)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
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
    var body: some View {
        if message.kind == .toolEvent {
            DisclosureGroup { if let detail = message.detail { Text(detail).font(.caption).foregroundColor(.secondary).padding(.top, 4) } } label: {
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
    @State private var providerId = "current"
    @State private var providerBaseURL = ""
    @State private var model = ""
    @State private var customModel = ""
    @State private var credentialProfileId = ""
    @State private var creating = false

    private var catalog: CloudCodeCatalog {
        instance.cloudCodeCatalog ?? CloudCodeCatalog(
            providers: [
                CloudCodeProviderOption(id: "current", label: "当前 Cloud Code 配置", models: ["default", "sonnet", "opus", "haiku"], defaultModel: "default", custom: false, requiresApiKey: false),
                CloudCodeProviderOption(id: "anthropic", label: "Anthropic", models: ["sonnet", "opus", "haiku"], defaultModel: "sonnet", custom: false, requiresApiKey: true),
                CloudCodeProviderOption(id: "custom", label: "自定义 Anthropic-compatible 厂商", models: [], defaultModel: nil, custom: true, requiresApiKey: true)
            ],
            credentialProfiles: [],
            defaultProviderId: "current",
            defaultCredentialProfileId: nil,
            supportsNewCredential: true
        )
    }

    private var selectedProvider: CloudCodeProviderOption? {
        catalog.providers.first { $0.id == providerId }
    }

    private var codexCatalog: CodexCatalog {
        instance.codexCatalog ?? CodexCatalog(models: [], defaultModel: instance.configuredModel)
    }

    private var credentialOptions: [CloudCodeCredentialOption] {
        let exact = catalog.credentialProfiles.filter { $0.providerId == providerId }
        if !exact.isEmpty { return exact }
        if providerId == "current" { return [] }
        return catalog.credentialProfiles.filter { $0.providerId == nil }
    }

    private var modelOptions: [String] {
        let models = selectedProvider?.models ?? []
        return models.isEmpty ? ["__custom__"] : models + ["__custom__"]
    }

    private var finalModel: String {
        model == "__custom__" ? customModel.trimmingCharacters(in: .whitespacesAndNewlines) : model
    }

    private var canCreate: Bool {
        if runtime.kind == .codex {
            return !model.isEmpty && codexCatalog.models.contains(where: { $0.id == model })
        }
        if runtime.kind != .cloudCode { return true }
        guard let provider = selectedProvider, provider.isSelectableOnMobile else { return false }
        if providerId == "custom" && providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if model == "__custom__" && customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if provider.credentialMode == "local-relay-slot" {
            return !credentialProfileId.isEmpty && credentialOptions.contains(where: { $0.id == credentialProfileId })
        }
        if provider.requiresApiKey && providerId != "current" {
            return !credentialProfileId.isEmpty && credentialOptions.contains(where: { $0.id == credentialProfileId })
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

                if runtime.kind == .cloudCode {
                    Section("厂商") {
                        Picker("Provider", selection: $providerId) {
                            ForEach(catalog.providers) { option in
                                Text(option.label + (option.isSelectableOnMobile ? "" : " · 未配置"))
                                    .tag(option.id)
                                    .disabled(!option.isSelectableOnMobile)
                            }
                        }
                        if providerId == "custom" {
                            TextField("https://api.example.com", text: $providerBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                        }
                    }

                    Section("Key") {
                        Picker("Credential", selection: $credentialProfileId) {
                            if providerId == "current" {
                                Text("使用 Windows 当前 Claude 配置").tag("")
                            }
                            ForEach(credentialOptions) { option in Text(option.label).tag(option.id) }
                        }
                        if providerId != "current" && credentialOptions.isEmpty {
                            Text("Windows 未配置此 Provider 的可用 Key；请先在 Windows 端配置。")
                                .font(.caption).foregroundColor(.orange)
                        }
                        Text("手机只接收 Provider、Key Slot/Profile 和 Model 元数据；真实 API Key 始终保留在 Windows，不在手机端显示或录入。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Section("模型") {
                        Picker("Model", selection: $model) {
                            ForEach(modelOptions, id: \.self) { value in
                                Text(value == "__custom__" ? "自定义模型…" : (value == "default" ? "默认" : value)).tag(value)
                            }
                        }
                        if model == "__custom__" {
                            TextField("模型 ID", text: $customModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                    }
                } else if runtime.kind == .codex {
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
                if runtime.kind == .cloudCode {
                    if let defaultProvider = catalog.defaultProviderId { providerId = defaultProvider }
                    if let defaultCredential = catalog.defaultCredentialProfileId { credentialProfileId = defaultCredential }
                    if let provider = catalog.providers.first(where: { $0.id == providerId }) {
                        if let defaultModel = provider.defaultModel { model = defaultModel }
                        if provider.credentialMode == "local-relay-slot" && credentialProfileId.isEmpty {
                            credentialProfileId = credentialOptions.first?.id ?? ""
                        }
                    }
                } else if runtime.kind == .codex {
                    model = instance.configuredModel
                        ?? codexCatalog.defaultModel
                        ?? codexCatalog.models.first?.id
                        ?? ""
                }
            }
            .onChange(of: providerId) { newValue in
                guard runtime.kind == .cloudCode else { return }
                if let provider = catalog.providers.first(where: { $0.id == newValue }) {
                    model = provider.defaultModel ?? (provider.models.first ?? "__custom__")
                    credentialProfileId = provider.credentialMode == "local-relay-slot" ? (credentialOptions.first?.id ?? "") : ""
                } else {
                    credentialProfileId = ""
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
                                providerId: providerId,
                                providerBaseURL: providerBaseURL,
                                model: finalModel,
                                credentialProfileId: credentialProfileId
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
                    guard !pairing else { return }
                    guard let url = URL(string: relay), !machineId.isEmpty, code.count == 8 else {
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
                .disabled(pairing)
            }
        }
        .sheet(isPresented: $scanner) {
            QRScannerView { value in
                applyScannedPairing(value)
                scanner = false
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
        case .loadingRuntimes: return "Loading Web, Cloud Code, and Codex from Windows."
        case .completed: return "Pairing completed successfully."
        default: return "Every network step is time-limited; the Pair button will recover on failure."
        }
    }

    private func applyScannedPairing(_ value: String) {
        if value.count == 8, value.allSatisfy({ $0.isNumber }) { code = value; return }
        if let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            if let v = object["relayBaseURL"] ?? object["relay"] { relay = v }
            if let v = object["machineId"] { machineId = v }
            if let v = object["pairingCode"] ?? object["code"] { code = v }
            return
        }
        if let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
            if let v = values["relay"] { relay = v }
            if let v = values["machineId"] { machineId = v }
            if let v = values["code"] { code = v }
        }
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
