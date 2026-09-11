import SwiftUI

@main
struct RemoteAIMobileApp: App {
    @StateObject private var store = WorkspaceStore.makeDefault()
    @Environment(\.scenePhase) private var scenePhase
    private var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestMockMode")
            && ProcessInfo.processInfo.environment["REMOTEAI_UI_TEST_MOCK"] == "1"
    }
    private var directStress: Bool { isUITest && ProcessInfo.processInfo.environment["REMOTEAI_UI_STRESS_DIRECT"] == "1" }
    var body: some Scene {
        WindowGroup {
            Group {
                if isUITest && ProcessInfo.processInfo.environment["REMOTEAI_UI_DIAGNOSTICS"] == "1" {
                    DiagnosticsView()
                } else if directStress {
                    NavigationView {
                        if let runtime = store.runtimes.first(where: { $0.id == "runtime.web" }),
                           let instance = store.instances.first(where: { $0.id == "photo" }),
                           let session = store.sessions.first(where: { $0.id == "photo-upload" }) {
                            ChatView(runtime: runtime, instance: instance, session: session)
                        } else { ProgressView("Preparing device test") }
                    }
                } else { RootView() }
            }
            .environmentObject(store)
            .task {
                await store.start()
                if directStress, let runtime = store.runtimes.first(where: { $0.id == "runtime.web" }) {
                    await store.refreshRuntime(runtime)
                    if let instance = store.instances.first(where: { $0.id == "photo" }) {
                        await store.refreshSessions(runtime: runtime, instance: instance)
                    }
                }
            }
        }
            .onChange(of: scenePhase) { phase in
                Task { if phase == .active { await store.resumeFromForeground() } else if phase == .background { await store.suspend() } }
            }
    }
}
