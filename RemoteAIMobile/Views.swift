import SwiftUI
import AVFoundation
import UIKit

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
        }.navigationTitle(runtime.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct InstanceView: View {
    @EnvironmentObject var store: WorkspaceStore
    let runtime: RuntimeDescriptor
    let instance: InstanceDescriptor
    @State private var newSession = false
    var body: some View {
        List {
            Section("Sessions / Conversations") {
                ForEach(store.sessions.filter { $0.instanceId == instance.id }.sorted { $0.updatedAt > $1.updatedAt }) { session in
                    NavigationLink(destination: ChatView(runtime: runtime, instance: instance, session: session)) {
                        HStack { VStack(alignment: .leading, spacing: 4) { Text(session.title); Text(session.updatedAt, style: .relative).font(.caption).foregroundColor(.secondary) }; Spacer(); Text(session.state.rawValue).font(.caption).foregroundColor(session.state == .error ? .red : .secondary) }
                    }
                }
            }
            Section { Button { newSession = true } label: { Label(runtime.kind == .web ? "New Chat" : "New Session", systemImage: "plus.circle.fill") } }
        }
        .navigationTitle(instance.name).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $newSession) { NewSessionView(runtime: runtime, instance: instance).environmentObject(store) }
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
                        ForEach(messages) { message in MessageRow(message: message, retry: message.kind == .error ? { Task { await store.retry(message: message, runtimeId: runtime.id, instanceId: instance.id) } } : nil).id(message.id) }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: messages.last?.id) { _ in if !loadingOlder, let id = messages.last?.id { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) } } }
            }
        }
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
            Button(action: {}) { Image(systemName: "plus.circle").font(.title2) }.accessibilityLabel("Attachments")
            TextEditor(text: $text).frame(minHeight: 36, maxHeight: 92).padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground))).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(.separator), lineWidth: 0.5))
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title).foregroundColor(enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .accentColor : .secondary) }.disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send")
        }.padding(.horizontal, 10).padding(.vertical, 8).background(.ultraThinMaterial)
    }
}

struct MessageRow: View {
    let message: ChatMessage
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

struct NewSessionView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let runtime: RuntimeDescriptor; let instance: InstanceDescriptor
    @State private var title = ""; @State private var provider = ""; @State private var model = ""; @State private var credential = ""
    var body: some View {
        NavigationView { Form {
            Section("Project") { Text(instance.name); TextField("Session title", text: $title) }
            if runtime.kind == .cloudCode { Section("Runtime") { TextField("Provider", text: $provider); TextField("Model", text: $model); TextField("Credential Profile ID", text: $credential).textInputAutocapitalization(.never).autocorrectionDisabled(true); Text("Only credentialProfileId is stored on the phone. Real API keys never leave Windows.").font(.caption).foregroundColor(.secondary) } }
        }.navigationTitle(runtime.kind == .web ? "New Chat" : "New Session").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await store.createSession(runtime: runtime, instance: instance, title: title, provider: provider, model: model, credentialProfileId: credential); dismiss() } } } } }
    }
}

struct PairingView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var relay = "https://relay.example.invalid"; @State private var code = ""; @State private var scanner = false; @State private var error: String?
    var body: some View {
        NavigationView { Form {
            Section("Windows Relay") { TextField("https://relay.example.com", text: $relay).textInputAutocapitalization(.never).autocorrectionDisabled(true); TextField("Pairing code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled(true); Button { scanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") } }
            Section { Text("The pairing secret is stored only in iOS Keychain. Relay URLs may be cached, but secrets are never written to UserDefaults or SQLite.").font(.caption).foregroundColor(.secondary) }
            if let error { Section { Text(error).foregroundColor(.red).font(.caption) } }
        }.navigationTitle("Pair Device").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Pair") { Task { guard let url = URL(string: relay), !code.isEmpty else { error = "Enter a valid relay URL and code."; return }; do { try await store.savePairing(baseURL: url, code: code); dismiss() } catch { self.error = error.localizedDescription } } } } }.sheet(isPresented: $scanner) { QRScannerView { value in code = value; scanner = false } } }
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
