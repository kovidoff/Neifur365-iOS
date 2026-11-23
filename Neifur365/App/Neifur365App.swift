import SwiftUI

@main
struct Neifur365App: App {
    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.prefs)
                .environmentObject(container.account)
                .environmentObject(container.lists)
                .environmentObject(container.downloads)
                .preferredColorScheme(.dark)
                .tint(Nf.violet)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                container.alerts.scheduleNextCheck()
            }
        }
    }
}
