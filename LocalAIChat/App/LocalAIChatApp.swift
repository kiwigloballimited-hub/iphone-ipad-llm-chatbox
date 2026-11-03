import SwiftUI

@main
struct LocalAIChatApp: App {
    @State private var store = AppStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { url in
                    // 小组件、实时活动的跳转链接
                    store.handleDeepLink(url)
                }
                .task {
                    store.refreshAppShortcuts()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.saveNow()
            }
        }
    }
}
