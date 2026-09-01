import SwiftUI

@main
struct RemoteAIMobileApp: App {
    @StateObject private var store = WorkspaceStore.makeDefault()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).task { await store.start() } }
            .onChange(of: scenePhase) { phase in
                Task { if phase == .active { await store.resumeFromForeground() } else if phase == .background { await store.suspend() } }
            }
    }
}
