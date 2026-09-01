import SwiftUI
import AVFoundation
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
                Section("Runtimes") {
                    ForEach(store.runtimes) { runtime in
                        NavigationLink(destination: RuntimeView(runtime: runtime)) {
                            Label(runtime.name, systemImage: runtimeIcon(runtime.kind)).padding(.vertical, 5)
                        }
                    }
                }
                if store.machine.state == .offline {
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
            ForEach(store.instances.filter { $0.runtimeId == runtime.id }) { instance in
                NavigationLink(destination: InstanceView(runtime: runtime, instance: instance)) {
                    VStack(alignment: .leading, spacing: 4) { Text(instance.name).font(.body.weight(.medium)); if let subtitle = instance.subtitle { Text(subtitle).font(.caption).foregroundColor(.secondary) } }
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
    private var isChatGPTWeb: Bool { runtime.id == "runtime.web" && instance.id == "web.chatgpt" }

    var body: some View {
        List {
            if isChatGPTWeb {
                Section("普通聊天") {
                    ForEach(store.sessions.filter { $0.instanceId == instance.id && $0.projectAlias == nil }.sorted { $0.updatedAt > $1.updatedAt }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                    }
                    Button { Task { _ = await store.createWebConversation() } } label: { Label("新建普通对话", systemImage: "plus.circle.fill") }
                }
                Section("Projects") {
                    Button { newProject = true } label: { Label("新建 Project", systemImage: "folder.badge.plus") }
                    if store.webProjects.isEmpty { Text(store.machine.state == .online ? "正在读取 Projects…" : "离线 — 显示缓存 Project").font(.caption).foregroundColor(.secondary) }
                    ForEach(store.webProjects) { project in
                        NavigationLink(destination: WebProjectView(runtime: runtime, instance: instance, project: project)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.displayName).font(.body.weight(.medium))
                                if let date = project.lastOpenedAt ?? project.lastSeenAt { Text(date, style: .relative).font(.caption).foregroundColor(.secondary) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if let error = store.errors["web.projects"] { Section { ErrorBanner(text: error) { store.clearError(sessionId: "web.projects") } } }
            } else {
                Section("Sessions / Conversations") {
                    ForEach(store.sessions.filter { $0.instanceId == instance.id }.sorted { $0.updatedAt > $1.updatedAt }) { session in
                        NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) { SessionRow(session: session) }
                    }
                }
                Section { Button { newSession = true } label: { Label(runtime.kind == .web ? "New Chat" : "New Session", systemImage: "plus.circle.fill") } }
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

struct SessionRow: View {
    let session: SessionDescriptor
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(session.title); Text(session.updatedAt, style: .relative).font(.caption).foregroundColor(.secondary) }
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
    @FocusState private var focused: Bool

    var messages: [ChatMessage] { store.messagesBySession[session.id, default: []] }
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.errors[session.id] { ErrorBanner(text: error) { store.clearError(sessionId: session.id) } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Color.clear.frame(height: 1).id("top").onAppear { guard !loadingOlder, store.hasMoreBySession[session.id] != false, let anchor = messages.first?.id else { return }; loadingOlder = true; Task { await store.loadOlder(session.id); await MainActor.run { proxy.scrollTo(anchor, anchor: .top); loadingOlder = false } } }
                        if loadingOlder { ProgressView().padding(.vertical, 6) }
                        ForEach(messages) { message in
                            let commandState = UUID(uuidString: message.id).flatMap { store.commandStates[$0] }
                            let retryable = message.kind == .error || commandState == .failed || commandState == .unknown
                            MessageRow(message: message, commandState: commandState, retry: retryable ? { Task { await store.retry(message: message, runtimeId: runtime.id, instanceId: instance.id) } } : nil).id(message.id)
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
        .safeAreaInset(edge: .bottom) { Composer(text: $input, enabled: store.machine.state == .online) { let text = input; input = ""; focused = false; Task { await store.send(text: text, runtimeId: runtime.id, instanceId: instance.id, sessionId: session.id) } }.focused($focused) }
        .task { await store.loadSession(session.id); if input.isEmpty { input = await store.draft(sessionId: session.id) } }
    }
}

struct Composer: View {
    @Binding var text: String
    let enabled: Bool
    let send: () -> Void
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: {}) { Image(systemName: "plus.circle").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("Attachments")
            TextEditor(text: $text).frame(minHeight: 36, maxHeight: 92).padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground))).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(.separator), lineWidth: 0.5)).accessibilityIdentifier("MessageComposer")
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44).foregroundColor(enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .accentColor : .secondary) }.disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send")
        }.padding(.horizontal, 10).padding(.vertical, 8).background(.ultraThinMaterial)
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
    @State private var model = "default"
    @State private var customModel = ""
    @State private var credentialProfileId = ""
    @State private var newCredentialProfileId = ""
    @State private var apiKey = ""
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

    private var modelOptions: [String] {
        let models = selectedProvider?.models ?? []
        return models.isEmpty ? ["__custom__"] : models + ["__custom__"]
    }

    private var finalModel: String {
        model == "__custom__" ? customModel.trimmingCharacters(in: .whitespacesAndNewlines) : model
    }

    private var canCreate: Bool {
        if runtime.kind != .cloudCode { return true }
        if providerId == "custom" && providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if model == "__custom__" && customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if credentialProfileId == "__new__" {
            return !newCredentialProfileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && apiKey.count >= 8
        }
        return true
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Project") {
                    Text(instance.name)
                    TextField("Session title", text: $title)
                }

                if runtime.kind == .cloudCode {
                    Section("厂商") {
                        Picker("Provider", selection: $providerId) {
                            ForEach(catalog.providers) { option in Text(option.label).tag(option.id) }
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
                            Text("使用 Cloud Code 当前登录 / 环境").tag("")
                            ForEach(catalog.credentialProfiles) { option in Text(option.label).tag(option.id) }
                            if catalog.supportsNewCredential { Text("新增 Key…").tag("__new__") }
                        }
                        if credentialProfileId == "__new__" {
                            TextField("Key 名称", text: $newCredentialProfileId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                            SecureField("API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                        Text("已有 Key 只显示 Windows 上的 Profile 名称；真实 Key 不会从 Windows 回传。新增 Key 通过已配对的加密通道提交一次并存入 Windows DPAPI。")
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
                }
            }
            .remoteAITopBreathingRoom()
            .navigationTitle(runtime.kind == .web ? "New Chat" : "New Session")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let defaultProvider = catalog.defaultProviderId { providerId = defaultProvider }
                if let defaultCredential = catalog.defaultCredentialProfileId { credentialProfileId = defaultCredential }
                if let provider = catalog.providers.first(where: { $0.id == providerId }), let defaultModel = provider.defaultModel { model = defaultModel }
            }
            .onChange(of: providerId) { newValue in
                if let provider = catalog.providers.first(where: { $0.id == newValue }) {
                    model = provider.defaultModel ?? (provider.models.first ?? "__custom__")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Creating…" : "Create") {
                        creating = true
                        let selectedCredential = credentialProfileId == "__new__" ? "" : credentialProfileId
                        Task {
                            await store.createSession(
                                runtime: runtime,
                                instance: instance,
                                title: title,
                                providerId: providerId,
                                providerBaseURL: providerBaseURL,
                                model: finalModel,
                                credentialProfileId: selectedCredential,
                                newCredentialProfileId: credentialProfileId == "__new__" ? newCredentialProfileId : "",
                                apiKey: credentialProfileId == "__new__" ? apiKey : ""
                            )
                            apiKey = ""
                            creating = false
                            dismiss()
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
            if let error { Section { Text(error).foregroundColor(.red).font(.caption) } }
        }
        .remoteAITopBreathingRoom()
        .navigationTitle("Pair Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair") {
                    Task {
                        guard let url = URL(string: relay), !machineId.isEmpty, code.count == 8 else { error = "Enter an HTTPS relay URL, Machine ID, and 8-digit code."; return }
                        do { try await store.savePairing(baseURL: url, machineId: machineId, code: code); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $scanner) {
            QRScannerView { value in
                applyScannedPairing(value)
                scanner = false
            }
        } }
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
