import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
final class EpisodeAlertsManager {
    static let taskIdentifier = "app.neifur365.ios.alerts"

    private let api: Anime365Client
    private let account: AccountStore
    private let prefs: Prefs

    init(api: Anime365Client, account: AccountStore, prefs: Prefs) {
        self.api = api
        self.account = account
        self.prefs = prefs
    }

    private var isRegistered = false

    func registerBackgroundTask() {
        guard !isRegistered else { return }
        isRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self?.handleBackgroundRefresh(refreshTask)
            }
        }
    }

    func requestPermissionAndEnable(_ enable: Bool) async -> Bool {
        if !enable {
            prefs.alertsEnabled = false
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        prefs.alertsEnabled = granted
        if granted {
            scheduleNextCheck()
            Task { _ = await checkNow(silentBaseline: true) }
        }
        return granted
    }

    func scheduleNextCheck() {
        guard prefs.alertsEnabled else { return }
        let req = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) async {
        scheduleNextCheck()
        let work = Task { await checkNow(silentBaseline: false) }
        task.expirationHandler = { work.cancel() }
        let ok = await work.value
        task.setTaskCompleted(success: ok)
    }

    /// Checks airing titles in "Смотрю" (and optionally "Запланировано") for newly uploaded episodes.
    func checkNow(silentBaseline: Bool = false) async -> Bool {
        guard prefs.alertsEnabled, let user = account.profile else { return false }
        do {
            let entries = try await api.allLists(userId: user.id)
            let allowedStatuses: Set<ListStatus> = prefs.alertsPlanned ? [.watching, .planned] : [.watching]
            let tracked = entries.filter { entry in
                guard let st = entry.status else { return false }
                return allowedStatuses.contains(st)
            }
            let cards = try await api.cards(ids: tracked.map(\.seriesId))
            let airingIds = cards.filter(\.airing).map(\.id)

            var seen = prefs.alertsSeen()
            let hadBaseline = !seen.isEmpty

            for sid in airingIds {
                guard !Task.isCancelled else { break }
                guard let full = try? await api.series(id: sid, force: true) else { continue }
                let latest = full.playable.map(\.number).max() ?? 0
                guard latest > 0 else { continue }
                let prev = seen[sid]
                seen[sid] = max(prev ?? 0, latest)

                if !silentBaseline && hadBaseline, let prev, latest > prev {
                    await postNotification(series: full, episodeNumber: latest)
                }
            }

            prefs.saveAlertsSeen(seen)
            return true
        } catch {
            return false
        }
    }

    private func postNotification(series: Series, episodeNumber: Int) async {
        let content = UNMutableNotificationContent()
        content.title = series.title
        content.body = "Вышла \(episodeNumber) серия"
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "neifur-ep-\(series.id)-\(episodeNumber)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}
