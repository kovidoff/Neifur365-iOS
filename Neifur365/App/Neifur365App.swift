import SwiftUI

@main
struct Neifur365App: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.prefs)
                .environmentObject(container.account)
                .environmentObject(container.lists)
                .preferredColorScheme(.dark)
                .tint(Nf.violet)
        }
    }
}
