import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let prefs: Prefs
    let a365: Anime365Client
    let shikimori: ShikimoriClient
    let account: AccountStore
    let lists: ListsStore
    let downloads: DownloadManager
    let alerts: EpisodeAlertsManager

    init() {
        let prefs = Prefs()
        let a365 = Anime365Client(prefs: prefs)
        let shikimori = ShikimoriClient()
        let account = AccountStore(api: a365, prefs: prefs)
        let lists = ListsStore(api: a365, account: account)
        let downloads = DownloadManager(api: a365, prefs: prefs)
        let alerts = EpisodeAlertsManager(api: a365, account: account, prefs: prefs)

        self.prefs = prefs
        self.a365 = a365
        self.shikimori = shikimori
        self.account = account
        self.lists = lists
        self.downloads = downloads
        self.alerts = alerts
        alerts.registerBackgroundTask()
    }
}
