import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
final class EpisodeAlertsManager {
    static let taskIdentifier = "app.neifur365.ios.alerts"

    private let api: Anime365Client
    private let account: AccountStore
    private let prefs: Prefs
    private var isRegistered = false

    init(api: Anime365Client, account: AccountStore, prefs: Prefs) {
        self.api = api
        self.account = account
        self.prefs = prefs
    }

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

    /// Checks airing titles in "Смотрю" (and optionally "Запланировано") in parallel batches of 3.
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
            let myStudioOnly = prefs.alertsMyStudio
            let preferredKind = prefs.preferredKind
            let favKeys = prefs.favouriteStudioKeys

            for batchStart in stride(from: 0, to: airingIds.count, by: 3) {
                guard !Task.isCancelled else { break }
                let slice = Array(airingIds[batchStart..<min(batchStart + 3, airingIds.count)])
                let fetched: [Series] = await withTaskGroup(of: Series?.self) { group in
                    for sid in slice {
                        group.addTask { try? await self.api.series(id: sid, force: true) }
                    }
                    var list: [Series] = []
                    for await s in group { if let s { list.append(s) } }
                    return list
                }

                for full in fetched {
                    let episodes = full.playable
                    guard let latestEp = episodes.max(by: { $0.number < $1.number }), latestEp.number > 0 else { continue }

                    var effectiveLatest = latestEp.number
                    if myStudioOnly, let pick = prefs.pick(animeId: full.id) ?? favKeys.first {
                        // Wait until the chosen studio releases the latest episode; check translations of newest episodes.
                        let recentIds = Array(episodes.suffix(2).map(\.id))
                        if let trs = try? await api.translations(episodeIds: recentIds) {
                            let matchedNums = trs.filter { $0.shown && $0.pickKey == pick }.compactMap { tr in
                                episodes.first(where: { $0.id == tr.episodeId })?.number
                            }
                            if let maxMatched = matchedNums.max() {
                                effectiveLatest = maxMatched
                            } else {
                                // Studio hasn't released yet — do not advance watermark beyond previous
                                continue
                            }
                        }
                    } else if myStudioOnly {
                        let recentIds = Array(episodes.suffix(2).map(\.id))
                        if let trs = try? await api.translations(episodeIds: recentIds) {
                            let matchedNums = trs.filter { $0.shown && $0.kind == preferredKind }.compactMap { tr in
                                episodes.first(where: { $0.id == tr.episodeId })?.number
                            }
                            if let maxMatched = matchedNums.max() {
                                effectiveLatest = maxMatched
                            } else {
                                continue
                            }
                        }
                    }

                    let prev = seen[full.id]
                    seen[full.id] = max(prev ?? 0, effectiveLatest)

                    if !silentBaseline && hadBaseline, let prev, effectiveLatest > prev {
                        await postNotification(series: full, episodeNumber: effectiveLatest)
                    }
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
        content.userInfo = ["seriesId": series.id]

        let req = UNNotificationRequest(
            identifier: "neifur-ep-\(series.id)-\(episodeNumber)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}
