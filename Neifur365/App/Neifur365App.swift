import SwiftUI
import UIKit

@MainActor
final class NeifurAppDelegate: NSObject, UIApplicationDelegate {
    let container = AppContainer()

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        container.downloads.handleBackgroundEvents(completionHandler: completionHandler)
    }
}

@main
struct Neifur365App: App {
    @UIApplicationDelegateAdaptor(NeifurAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        let container = appDelegate.container
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.prefs)
                .environmentObject(container.account)
                .environmentObject(container.lists)
                .environmentObject(container.downloads)
                .preferredColorScheme(.dark)
                .tint(Nf.violet)
                .onAppear {
                    container.downloads.restoreTasks()
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                container.alerts.scheduleNextCheck()
            }
        }
    }
}
