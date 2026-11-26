import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let prefs: Prefs
    let network: NetworkMonitor
    let offlineCache: OfflineCache
    let a365: Anime365Client
    let shikimori: ShikimoriClient
    let aniSkip: AniSkipClient
    let account: AccountStore
    let channelPilot: ChannelPilot
    let lists: ListsStore
    let downloads: DownloadManager
    let alerts: EpisodeAlertsManager

    init() {
        let prefs = Prefs()
        let network = NetworkMonitor()
        let offlineCache = OfflineCache()
        let a365 = Anime365Client(prefs: prefs)
        let shikimori = ShikimoriClient(offlineCache: offlineCache)
        let aniSkip = AniSkipClient()
        let account = AccountStore(api: a365, prefs: prefs)
        let channelPilot = ChannelPilot(api: a365, prefs: prefs, account: account, network: network)
        let lists = ListsStore(api: a365, account: account, offlineCache: offlineCache)
        let downloads = DownloadManager(api: a365, prefs: prefs, network: network)
        let alerts = EpisodeAlertsManager(api: a365, account: account, prefs: prefs)

        self.prefs = prefs
        self.network = network
        self.offlineCache = offlineCache
        self.a365 = a365
        self.shikimori = shikimori
        self.aniSkip = aniSkip
        self.account = account
        self.channelPilot = channelPilot
        self.lists = lists
        self.downloads = downloads
        self.alerts = alerts

        alerts.registerBackgroundTask()

        network.onNetworkRestoredOrChanged = { [weak self] _ in
            guard let self else { return }
            Task {
                await self.a365.ensureMirrorWorking()
                self.channelPilot.onNetworkChanged()
                self.downloads.onNetworkPolicyChanged()
                await self.account.flushPendingWatches()
                if self.account.unconfirmed {
                    self.account.refresh()
                }
            }
        }
    }
}
