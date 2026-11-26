import Combine
import Foundation

struct ListedTitle: Identifiable, Hashable, Codable {
    var entry: ListEntry
    var series: Series?
    var aired: Int?

    var id: Int64 { entry.seriesId }
    var status: ListStatus? { entry.status }
    var airing: Bool { series?.airing == true }
    var total: Int? { entry.total ?? series.flatMap { $0.numberOfEpisodes > 0 ? $0.numberOfEpisodes : nil } }
    var behind: Int { max((aired ?? 0) - entry.watched, 0) }
    var displayTitle: String { series?.title ?? entry.title }
    var posterUrl: String? { series?.bestPosterUrl }
}

enum ListSort: String, CaseIterable, Identifiable {
    case `default` = "По умолчанию"
    case newEpisodes = "Сначала новые серии"
    case score = "По оценке"
    case year = "По году (сначала новые)"
    case title = "По названию (А–Я)"
    case progress = "По просмотренным сериям"

    var id: String { rawValue }
}

enum ListProgress {
    static func line(_ t: ListedTitle) -> String {
        let w = t.entry.watched
        let total = t.total
        let aired = t.aired
        let isMovie = t.series?.isMovie == true || total == 1

        switch t.status {
        case .planned:
            if isMovie { return "Фильм" }
            if t.airing, let aired { return "Вышло \(aired) из \(total.map(String.init) ?? "?")" }
            if t.airing { return "Выходит" + (total.map { " · \($0) \(plural($0))" } ?? "") }
            if let total { return "\(total) \(plural(total))" }
            return ""
        case .completed:
            if isMovie { return "Фильм" }
            if let total { return "\(total) \(plural(total))" }
            return "\(w) \(plural(w))"
        case .onHold, .dropped:
            return isMovie ? "Не досмотрен" : "Остановились на \(w) из \(total.map(String.init) ?? "?")"
        default:
            if isMovie { return w > 0 ? "Просмотрен" : "Фильм" }
            if t.airing, let aired {
                let tail = (total != nil && total != aired) ? " · всего \(total!)" : " · выходит"
                return "Просмотрено \(w) из \(aired)\(tail)"
            }
            return "Просмотрено \(w) из \(total.map(String.init) ?? "?")"
        }
    }

    static func fraction(_ t: ListedTitle) -> Double? {
        if t.status == .planned || t.status == .completed { return nil }
        guard let of = (t.airing ? t.aired : nil) ?? t.total, of > 0 else { return nil }
        return min(max(Double(t.entry.watched) / Double(of), 0), 1)
    }

    static func plural(_ n: Int) -> String {
        let m10 = n % 10
        let m100 = n % 100
        if m10 == 1 && m100 != 11 { return "серия" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "серии" }
        return "серий"
    }
}

@MainActor
final class ListsStore: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var titles: [Int64: ListedTitle] = [:]
    @Published private(set) var updatedAt: Date?

    private let api: Anime365Client
    private let account: AccountStore
    private let offlineCache: OfflineCache
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(api: Anime365Client, account: AccountStore, offlineCache: OfflineCache) {
        self.api = api
        self.account = account
        self.offlineCache = offlineCache

        account.$state
            .removeDuplicates()
            .sink { [weak self] st in
                guard let self else { return }
                switch st {
                case .signedIn(let profile):
                    if !self.loaded, let cached = self.offlineCache.readLists(userId: profile.id) {
                        var map: [Int64: ListedTitle] = [:]
                        for item in cached.titles { map[item.entry.seriesId] = item }
                        self.titles = map
                        self.loaded = !map.isEmpty
                    }
                    self.refresh(userId: profile.id)
                case .signedOut:
                    self.refreshTask?.cancel()
                    self.loading = false
                    self.loaded = false
                    self.error = nil
                    self.titles = [:]
                    self.updatedAt = nil
                case .unknown:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func of(_ status: ListStatus) -> [ListedTitle] {
        titles.values.filter { $0.status == status }
    }

    func count(_ status: ListStatus) -> Int {
        titles.values.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }

    func get(_ seriesId: Int64) -> ListedTitle? {
        titles[seriesId]
    }

    func watching(history: [WatchEntry]) -> [ListedTitle] {
        var last: [Int64: Int64] = [:]
        for e in history {
            if let id = Int64(e.animeId), e.updatedAt > (last[id] ?? 0) {
                last[id] = e.updatedAt
            }
        }
        return of(.watching).sorted { a, b in
            let la = last[a.entry.seriesId] ?? 0
            let lb = last[b.entry.seriesId] ?? 0
            if la != lb { return la > lb }
            if (a.behind > 0) != (b.behind > 0) { return a.behind > 0 }
            if a.airing != b.airing { return a.airing }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }

    func matches(_ t: ListedTitle, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if t.entry.title.localizedCaseInsensitiveContains(q) { return true }
        if let s = t.series {
            if s.title.localizedCaseInsensitiveContains(q) { return true }
            if s.titles.romaji?.localizedCaseInsensitiveContains(q) == true { return true }
            if s.titles.en?.localizedCaseInsensitiveContains(q) == true { return true }
        }
        return false
    }

    func display(status: ListStatus, history: [WatchEntry], query: String = "", sort: ListSort = .default) -> [ListedTitle] {
        let base = status == .watching ? watching(history: history) : of(status).sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        let filtered = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? base
            : base.filter { matches($0, query: query) }

        switch sort {
        case .default:
            return filtered
        case .newEpisodes:
            return filtered.sorted { a, b in
                if a.behind != b.behind { return a.behind > b.behind }
                if a.airing != b.airing { return a.airing }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            }
        case .score:
            return filtered.sorted { a, b in
                let sa = a.entry.score ?? 0
                let sb = b.entry.score ?? 0
                if sa != sb { return sa > sb }
                return (a.series?.score ?? 0) > (b.series?.score ?? 0)
            }
        case .year:
            return filtered.sorted { ($0.series?.year ?? 0) > ($1.series?.year ?? 0) }
        case .title:
            return filtered.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .progress:
            return filtered.sorted { a, b in
                if a.entry.watched != b.entry.watched { return a.entry.watched > b.entry.watched }
                return a.behind > b.behind
            }
        }
    }

    func matchesInOtherTabs(current: ListStatus, query: String) -> [(ListStatus, Int)] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return ListStatus.allCases.compactMap { s in
            guard s != current else { return nil }
            let n = of(s).filter { matches($0, query: query) }.count
            return n > 0 ? (s, n) : nil
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 120) {
        guard !loading else { return }
        if let updatedAt, Date().timeIntervalSince(updatedAt) <= maxAge { return }
        refresh()
    }

    func refresh(userId explicitUserId: Int64? = nil) {
        guard let userId = explicitUserId ?? account.profile?.id else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            await performRefresh(userId: userId)
        }
    }

    func refreshAsync(userId explicitUserId: Int64? = nil) async {
        guard let userId = explicitUserId ?? account.profile?.id else { return }
        refreshTask?.cancel()
        let task = Task {
            await performRefresh(userId: userId)
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(userId: Int64) async {
        loading = true
        error = nil

        do {
            let entries = try await api.allLists(userId: userId)
            let cards = (try? await api.cards(ids: entries.map(\.seriesId))) ?? []
            let cardsById = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            let known = self.titles

            var map: [Int64: ListedTitle] = [:]
            for e in entries {
                map[e.seriesId] = ListedTitle(entry: e, series: cardsById[e.seriesId], aired: known[e.seriesId]?.aired)
            }

            if Task.isCancelled { loading = false; return }
            self.titles = map
            self.loaded = true
            self.loading = false
            self.updatedAt = Date()
            self.offlineCache.writeLists(userId: userId, titles: Array(map.values))

            let airingWatching = map.values.filter { $0.airing && $0.status == .watching }
            await self.countAired(Array(airingWatching), userId: userId)
            let airingPlanned = map.values.filter { $0.airing && $0.status == .planned }
            await self.countAired(Array(airingPlanned), userId: userId)
        } catch {
            if Task.isCancelled { loading = false; return }
            self.loading = false
            self.error = error.userMessage
        }
    }

    private func countAired(_ list: [ListedTitle], userId: Int64) async {
        guard !list.isEmpty else { return }
        for batch in stride(from: 0, to: list.count, by: 3) {
            if Task.isCancelled { return }
            let slice = Array(list[batch..<min(batch + 3, list.count)])
            await withTaskGroup(of: (Int64, Int?).self) { group in
                for item in slice {
                    group.addTask {
                        let count = try? await self.api.series(id: item.entry.seriesId).playable.count
                        return (item.entry.seriesId, count)
                    }
                }
                for await (id, aired) in group {
                    if let aired, var cur = self.titles[id] {
                        cur.aired = aired
                        self.titles[id] = cur
                    }
                }
            }
        }
        offlineCache.writeLists(userId: userId, titles: Array(titles.values))
    }

    @discardableResult
    func set(
        seriesId: Int64,
        status: ListStatus?,
        watched: Int,
        score: Int?,
        series: Series? = nil,
        title: String = ""
    ) async -> Result<Void, Error> {
        let before = titles[seriesId]

        if let status {
            let prev = titles[seriesId]
            let baseEntry = prev?.entry ?? ListEntry(
                seriesId: seriesId,
                title: series?.title ?? title,
                watched: 0,
                total: series.flatMap { $0.numberOfEpisodes > 0 ? $0.numberOfEpisodes : nil },
                score: nil,
                status: status
            )
            let updatedEntry = ListEntry(
                seriesId: baseEntry.seriesId,
                title: baseEntry.title,
                watched: watched,
                total: baseEntry.total,
                score: score,
                status: status
            )
            titles[seriesId] = ListedTitle(entry: updatedEntry, series: prev?.series ?? series, aired: prev?.aired)
        } else {
            titles.removeValue(forKey: seriesId)
        }

        do {
            try await api.setListRecord(seriesId: seriesId, status: status, watched: watched, score: score)
            if let uid = account.profile?.id {
                offlineCache.writeLists(userId: uid, titles: Array(titles.values))
            }
            return .success(())
        } catch {
            if let before {
                titles[seriesId] = before
            } else {
                titles.removeValue(forKey: seriesId)
            }
            return .failure(error)
        }
    }

    @discardableResult
    func bump(seriesId: Int64) async -> Result<Void, Error> {
        guard let t = get(seriesId) else {
            return .failure(ApiError("Тайтл не в списке"))
        }
        let next = t.entry.watched + 1
        let total = t.total
        let done = total != nil && !t.airing && next >= total!
        let clamped = total.map { min(next, $0) } ?? next
        return await set(
            seriesId: seriesId,
            status: done ? .completed : (t.status ?? .watching),
            watched: clamped,
            score: t.entry.score
        )
    }
}
