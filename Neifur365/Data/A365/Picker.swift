import Foundation

enum TranslationPicker {
    static func best(_ variants: [Translation], quality: Int) -> Translation? {
        variants.max { a, b in
            let aFit = (1...quality).contains(a.height) ? 1 : 0
            let bFit = (1...quality).contains(b.height) ? 1 : 0
            if aFit != bFit { return aFit < bFit }

            let aH = a.height <= quality ? a.height : -a.height
            let bH = b.height <= quality ? b.height : -b.height
            if aH != bH { return aH < bH }

            let aBd = a.qualityType == "bd" ? 1 : 0
            let bBd = b.qualityType == "bd" ? 1 : 0
            if aBd != bBd { return aBd < bBd }

            return a.priority < b.priority
        }
    }

    static func choose(
        all: [Translation],
        pick: String?,
        preferred: TranslationKind,
        favourites: [String],
        quality: Int
    ) -> Translation? {
        let active = all.filter { $0.shown }
        guard !active.isEmpty else { return nil }

        let byKey = Dictionary(grouping: active, by: \.pickKey)
        if let pick, let variants = byKey[pick] {
            return best(variants, quality: quality)
        }

        let sortedFavs = favourites.sorted { a, b in
            let aPref = a.hasPrefix(preferred.rawValue + "|")
            let bPref = b.hasPrefix(preferred.rawValue + "|")
            return aPref && !bPref
        }
        for fav in sortedFavs {
            if let variants = byKey[fav] {
                return best(variants, quality: quality)
            }
        }

        let order = [preferred] + TranslationKind.shown.filter { $0 != preferred }
        for kind in order {
            let ofKind = active.filter { $0.kind == kind }
            guard let top = ofKind.max(by: { $0.priority < $1.priority }),
                  let variants = byKey[top.pickKey] else { continue }
            return best(variants, quality: quality)
        }
        return nil
    }

    static func options(_ all: [Translation], quality: Int) -> [(TranslationKind, [Translation])] {
        let byKey = Dictionary(grouping: all.filter { $0.shown }, by: \.pickKey)
        let winners = byKey.values.compactMap { best($0, quality: quality) }
        let grouped = Dictionary(grouping: winners, by: \.kind)
        return grouped
            .map { (kind, list) in (kind, list.sorted { $0.priority > $1.priority }) }
            .sorted { $0.0 < $1.0 }
    }
}
