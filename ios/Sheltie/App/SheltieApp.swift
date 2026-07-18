import SwiftUI

@main
struct SheltieApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .preferredColorScheme(.light)
                .onAppear { store.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        store.applicationDidBecomeActive()
                    case .background:
                        store.applicationDidEnterBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .commands {
            SheltieCommands(store: store)
        }
    }
}
