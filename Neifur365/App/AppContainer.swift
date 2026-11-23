import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let prefs: Prefs
    let a365: Anime365Client
    let account: AccountStore
    let lists: ListsStore

    init() {
        let prefs = Prefs()
        let a365 = Anime365Client(prefs: prefs)
        let account = AccountStore(api: a365, prefs: prefs)
        let lists = ListsStore(api: a365, account: account)

        self.prefs = prefs
        self.a365 = a365
        self.account = account
        self.lists = lists
    }
}
