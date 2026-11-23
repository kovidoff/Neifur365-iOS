import Foundation

struct Studio: Identifiable, Hashable {
    let key: String
    let kind: TranslationKind
    let author: String
    let details: String
    let byEpisode: [Int64: [Translation]]
    let bestHeight: Int
    let hasBd: Bool
    let priority: Int64

    var id: String { key }

    func has(episodeId: Int64) -> Bool {
        byEpisode[episodeId] != nil
    }

    func coverage(in episodes: [Episode]) -> Int {
        episodes.reduce(0) { $0 + (has(episodeId: $1.id) ? 1 : 0) }
    }

    var qualityLabel: String {
        var parts: [String] = []
        if bestHeight > 0 { parts.append("\(min(bestHeight, maxStreamHeight))p") }
        if hasBd { parts.append("BD") }
        return parts.joined(separator: " · ")
    }
}

enum Studios {
    static func build(_ translations: [Translation]) -> [Studio] {
        let grouped = Dictionary(grouping: translations.filter(\.shown), by: \.pickKey)
        return grouped.compactMap { key, list in
            guard let first = list.max(by: { $0.priority < $1.priority }) else { return nil }
            let detailCounts = list.map(\.details).filter { !$0.isEmpty }.reduce(into: [String: Int]()) { acc, d in
                acc[d, default: 0] += 1
            }
            let commonDetails = detailCounts.max(by: { $0.value < $1.value })?.key ?? ""
            return Studio(
                key: key,
                kind: first.kind,
                author: first.author,
                details: commonDetails,
                byEpisode: Dictionary(grouping: list, by: \.episodeId),
                bestHeight: list.map(\.height).max() ?? 0,
                hasBd: list.contains { $0.qualityType == "bd" },
                priority: list.map(\.priority).max() ?? 0
            )
        }
    }

    static func grouped(_ studios: [Studio], episodes: [Episode]) -> [(TranslationKind, [Studio])] {
        let byKind = Dictionary(grouping: studios, by: \.kind)
        return byKind
            .map { kind, list in
                let sorted = list.sorted { a, b in
                    let ca = a.coverage(in: episodes)
                    let cb = b.coverage(in: episodes)
                    if ca != cb { return ca > cb }
                    return a.priority > b.priority
                }
                return (kind, sorted)
            }
            .sorted { $0.0 < $1.0 }
    }

    static func choose(
        studios: [Studio],
        pick: String?,
        preferred: TranslationKind,
        favourites: [String],
        episodes: [Episode],
        from: Int
    ) -> Studio? {
        guard !studios.isEmpty else { return nil }
        if let pick, let hit = studios.first(where: { $0.key == pick }) { return hit }

        let dropCount = max(from, 0)
        let ahead = dropCount < episodes.count ? Array(episodes.dropFirst(dropCount)) : episodes

        let sortedFavs = favourites.sorted { a, b in
            a.hasPrefix(preferred.rawValue + "|") && !b.hasPrefix(preferred.rawValue + "|")
        }
        for fav in sortedFavs {
            if let hit = studios.first(where: { $0.key == fav && $0.coverage(in: ahead) > 0 }) {
                return hit
            }
        }

        let order = [preferred] + TranslationKind.shown.filter { $0 != preferred }
        for kind in order {
            let ofKind = studios.filter { $0.kind == kind }
            if let best = ofKind.max(by: { a, b in
                let ca = a.coverage(in: ahead)
                let cb = b.coverage(in: ahead)
                if ca != cb { return ca < cb }
                return a.priority < b.priority
            }) {
                return best
            }
        }
        return nil
    }

    static func coverageText(studio: Studio, episodes: [Episode]) -> String {
        let total = episodes.count
        guard total > 0 else { return "" }
        let have = episodes.filter { studio.has(episodeId: $0.id) }
        if have.count == total {
            return total == 1 ? "есть" : "все \(total) \(ListProgress.plural(total))"
        }
        if have.isEmpty { return "серий пока нет" }
        let missing = episodes.filter { !studio.has(episodeId: $0.id) }
        if missing.count <= 3 {
            return "\(have.count) из \(total) · нет \(ranges(missing))"
        }
        return "есть \(ranges(have)) из \(total)"
    }

    static func ranges(_ episodes: [Episode]) -> String {
        let nums = Array(Set(episodes.map(\.number).filter { $0 > 0 })).sorted()
        guard let first = nums.first else { return "\(episodes.count)" }
        var out: [String] = []
        var start = first
        var prev = first
        for n in nums.dropFirst() {
            if n == prev + 1 {
                prev = n
            } else {
                out.append(start == prev ? "\(start)" : "\(start)–\(prev)")
                start = n
                prev = n
            }
        }
        out.append(start == prev ? "\(start)" : "\(start)–\(prev)")
        if out.count > 4 {
            return out.prefix(3).joined(separator: ", ") + "…"
        }
        return out.joined(separator: ", ")
    }
}
