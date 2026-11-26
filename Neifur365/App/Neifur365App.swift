import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class NeifurAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let container = AppContainer()
    @Published var pendingDeepLinkSeriesId: Int64?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.allowedMask
    }

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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo["seriesId"] as? NSNumber {
            let sid = raw.int64Value
            await MainActor.run {
                self.pendingDeepLinkSeriesId = sid
            }
        }
    }
}

@main
struct Neifur365App: App {
    @UIApplicationDelegateAdaptor(NeifurAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        let container = appDelegate.container
        WindowGroup {
            RootView(pendingDeepLinkSeriesId: $appDelegate.pendingDeepLinkSeriesId)
                .environmentObject(container)
                .environmentObject(container.prefs)
                .environmentObject(container.account)
                .environmentObject(container.lists)
                .environmentObject(container.downloads)
                .environmentObject(container.channelPilot)
                .environmentObject(container.network)
                .preferredColorScheme(.dark)
                .tint(Nf.violet)
                .onAppear {
                    container.downloads.restoreTasks()
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                container.alerts.scheduleNextCheck()
            } else if phase == .active {
                Task { await container.account.flushPendingWatches() }
            }
        }
    }
}
