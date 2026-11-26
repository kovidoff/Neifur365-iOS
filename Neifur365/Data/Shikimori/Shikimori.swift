import Foundation

struct ShikiPoster: Codable, Hashable {
    var originalUrl: String?
    var mainUrl: String?
    var main2xUrl: String?

    var card: String? { main2xUrl ?? mainUrl ?? originalUrl }
    var full: String? { originalUrl ?? main2xUrl ?? mainUrl }
}

struct ShikiScoreStat: Codable, Hashable, Identifiable {
    var score: Int
    var count: Int
    var id: Int { score }
}

struct ShikiStatusStat: Codable, Hashable {
    var status: String
    var count: Int
}

struct ShikiVideo: Codable, Hashable, Identifiable {
    var kind: String?
    var name: String?
    var url: String?
    var imageUrl: String?

    var id: String { url ?? (name ?? UUID().uuidString) }
}

struct ShikiCharacterRef: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var russian: String?
    var poster: ShikiPoster?

    var label: String {
        if let ru = russian, !ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ru }
        return name
    }
}

struct ShikiCharacterRole: Codable, Hashable, Identifiable {
    var rolesRu: [String]?
    var rolesEn: [String]?
    var character: ShikiCharacterRef?

    var id: String { character?.id ?? UUID().uuidString }

    var isMain: Bool {
        (rolesEn ?? []).contains { $0.caseInsensitiveCompare("Main") == .orderedSame } ||
        (rolesRu ?? []).contains { $0.caseInsensitiveCompare("Main") == .orderedSame || $0.hasPrefix("Главн") }
    }
}

struct ShikiPersonRef: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var russian: String?

    var label: String {
        if let ru = russian, !ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ru }
        return name
    }
}

struct ShikiPersonRole: Codable, Hashable {
    var rolesRu: [String]?
    var rolesEn: [String]?
    var person: ShikiPersonRef?
}

struct ShikiCast: Hashable {
    let characters: [ShikiCharacterRole]
    let staff: [ShikiPersonRole]
}

struct ShikiIncDate: Codable, Hashable {
    var year: Int?
    var month: Int?
    var day: Int?

    func formatted() -> String? {
        guard let y = year else { return nil }
        let genitive = ["янв.", "февр.", "марта", "апр.", "мая", "июня", "июля", "авг.", "сент.", "окт.", "нояб.", "дек."]
        let nominative = ["янв.", "февр.", "март", "апр.", "май", "июнь", "июль", "авг.", "сент.", "окт.", "нояб.", "дек."]
        if let m = month, (1...12).contains(m) {
            if let d = day { return "\(d) \(genitive[m - 1]) \(y)" }
            return "\(nominative[m - 1]) \(y)"
        }
        return "\(y)"
    }
}

struct ShikiGenre: Codable, Hashable, Identifiable {
    var id: String
    var russian: String?
    var name: String?
    var kind: String?

    var label: String { russian ?? name ?? "" }
}

struct ShikiStudio: Codable, Hashable, Identifiable {
    var id: String?
    var name: String

    var stableId: String { id ?? name }
}

struct ShikiScreenshot: Codable, Hashable, Identifiable {
    var originalUrl: String?
    var x332Url: String?

    var id: String { originalUrl ?? x332Url ?? UUID().uuidString }
    var preview: String? { x332Url ?? originalUrl }
    var full: String? { originalUrl ?? x332Url }
}

struct ShikiRelatedRef: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var russian: String?
    var kind: String?
    var score: Double?
    var status: String?
    var episodes: Int?
    var episodesAired: Int?
    var airedOn: ShikiIncDate?
    var poster: ShikiPoster?

    var title: String {
        if let ru = russian, !ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ru }
        return name ?? "Без названия"
    }

    var malId: Int64? { Int64(id) }
}

struct ShikiRelated: Codable, Hashable, Identifiable {
    var relationKind: String?
    var relationText: String?
    var anime: ShikiRelatedRef?

    var id: String { "\(relationKind ?? "")-\(anime?.id ?? UUID().uuidString)" }
}

struct ShikiAnime: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var russian: String?
    var english: String?
    var japanese: String?
    var synonyms: [String]?
    var kind: String?
    var rating: String?
    var score: Double?
    var status: String?
    var episodes: Int?
    var episodesAired: Int?
    var duration: Int?
    var airedOn: ShikiIncDate?
    var releasedOn: ShikiIncDate?
    var nextEpisodeAt: String?
    var poster: ShikiPoster?
    var genres: [ShikiGenre]?
    var studios: [ShikiStudio]?
    var franchise: String?
    var description: String?
    var related: [ShikiRelated]?
    var screenshots: [ShikiScreenshot]?
    var origin: String?
    var scoresStats: [ShikiScoreStat]?
    var statusesStats: [ShikiStatusStat]?
    var videos: [ShikiVideo]?

    var title: String {
        if let ru = russian, !ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ru }
        return name ?? "Без названия"
    }

    var year: Int? { airedOn?.year }
    var malId: Int64? { Int64(id) }
}

func shikiKindLabel(_ kind: String?) -> String {
    switch kind {
    case "tv": return "TV сериал"
    case "movie": return "Фильм"
    case "ova": return "OVA"
    case "ona": return "ONA"
    case "special": return "Спешл"
    case "tv_special": return "TV спешл"
    case "music": return "Клип"
    case "pv": return "Промо"
    case "cm": return "Реклама"
    case .none: return ""
    case .some(let other): return other.uppercased()
    }
}

func shikiRatingLabel(_ rating: String?) -> String? {
    switch rating {
    case "g": return "0+"
    case "pg": return "7+"
    case "pg_13": return "13+"
    case "r": return "17+"
    case "r_plus": return "18+"
    case "rx": return "18+"
    default: return nil
    }
}

func cleanShikiDescription(_ raw: String?) -> String {
    guard var text = raw, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    text = text.replacingOccurrences(of: #"\[\[(.*?)\]\]"#, with: "$1", options: .regularExpression)
    if let spoilerRx = try? NSRegularExpression(pattern: #"\[spoiler[^\]]*\].*?\[/spoiler\]"#, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
        text = spoilerRx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
    text = text.replacingOccurrences(of: #"\[/?[a-zA-Z_*]+(?:=[^\]]*)?\]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private let franchiseSkipKinds: Set<String> = ["music", "cm", "pv"]

func sortFranchiseEntries(_ raw: [ShikiRelatedRef]) -> [ShikiRelatedRef] {
    var seen = Set<String>()
    return raw
        .filter { !franchiseSkipKinds.contains($0.kind ?? "") }
        .filter { seen.insert($0.id).inserted }
        .sorted { a, b in
            let ya = a.airedOn?.year ?? Int.max
            let yb = b.airedOn?.year ?? Int.max
            if ya != yb { return ya < yb }
            let ma = a.airedOn?.month ?? Int.max
            let mb = b.airedOn?.month ?? Int.max
            if ma != mb { return ma < mb }
            let da = a.airedOn?.day ?? Int.max
            let db = b.airedOn?.day ?? Int.max
            if da != db { return da < db }
            return (Int64(a.id) ?? Int64.max) < (Int64(b.id) ?? Int64.max)
        }
}

actor ShikimoriClient {
    private let endpoint = URL(string: "https://shikimori.io/api/graphql")!
    private let userAgent = "Neifur365/1.0 (iOS)"
    private let session: URLSession
    private let offlineCache: OfflineCache?
    private var lastCall: Date = .distantPast
    private var detailCache: [Int64: (Date, ShikiAnime)] = [:]
    private var castCache: [Int64: (Date, ShikiCast)] = [:]
    private var franchiseCache: [String: (Date, [ShikiRelatedRef])] = [:]
    private var studioCache: [String: (Date, [ShikiAnime])] = [:]
    private var scheduleCache: (savedAt: Date, wanted: Set<Int64>, animes: [ShikiAnime])?

    init(offlineCache: OfflineCache? = nil) {
        self.offlineCache = offlineCache
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 18
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    private func query(_ gql: String) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: ["query": gql])
        var attempt = 0

        while true {
            let elapsed = Date().timeIntervalSince(lastCall)
            if elapsed < 0.23 {
                try? await Task.sleep(nanoseconds: UInt64((0.23 - elapsed) * 1_000_000_000))
            }
            lastCall = Date()

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = payload

            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 && attempt < 3 {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(900_000_000 * attempt))
                continue
            }
            guard (200...299).contains(code) else {
                let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
                throw HttpError(code: code, bodySnippet: snippet)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ApiError("Shikimori ответил некорректно")
            }
            if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
                let msg = first["message"] as? String ?? "ошибка запроса"
                throw ApiError("Shikimori: \(msg)")
            }
            guard let dataObj = root["data"] as? [String: Any] else {
                throw ApiError("Пустой ответ Shikimori")
            }
            return dataObj
        }
    }

    private func decodeField<T: Decodable>(_ raw: Any?, as type: T.Type) throws -> T {
        guard let raw else { throw ApiError("Пустые данные Shikimori") }
        let jsonData = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(T.self, from: jsonData)
    }

    func detail(malId: Int64) async throws -> ShikiAnime {
        if let hit = detailCache[malId], Date().timeIntervalSince(hit.0) < 300 {
            return hit.1
        }
        let data = try await query("""
        { animes(ids: "\(malId)", limit: 1, censored: false) {
            id name russian english japanese synonyms kind rating score status episodes episodesAired duration
            airedOn { year month day } releasedOn { year month day } nextEpisodeAt franchise description origin
            scoresStats { score count } statusesStats { status count }
            videos { kind name url imageUrl }
            poster { originalUrl mainUrl main2xUrl }
            genres { id russian kind } studios { id name }
            screenshots { originalUrl x332Url }
            related { relationKind relationText anime { id name russian kind score status episodes episodesAired
              airedOn { year } poster { originalUrl mainUrl main2xUrl } } }
        } }
        """)
        let list = try decodeField(data["animes"], as: [ShikiAnime].self)
        guard let first = list.first else { throw ApiError("Тайтл не найден на Shikimori") }
        if detailCache.count >= 64 { detailCache.removeAll() }
        detailCache[malId] = (Date(), first)
        return first
    }

    func cast(malId: Int64) async throws -> ShikiCast {
        if let hit = castCache[malId], Date().timeIntervalSince(hit.0) < 300 {
            return hit.1
        }
        let data = try await query("""
        { animes(ids: "\(malId)", limit: 1, censored: false) {
            characterRoles { rolesRu rolesEn character { id name russian poster { mainUrl main2xUrl } } }
            personRoles { rolesRu rolesEn person { id name russian } }
        } }
        """)
        guard let arr = data["animes"] as? [[String: Any]], let first = arr.first else {
            return ShikiCast(characters: [], staff: [])
        }
        let rawChars = (try? decodeField(first["characterRoles"], as: [ShikiCharacterRole].self)) ?? []
        let chars = Array(rawChars.filter { $0.character != nil }.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return false
        }.prefix(24))
        let rawStaff = (try? decodeField(first["personRoles"], as: [ShikiPersonRole].self)) ?? []
        let staff = rawStaff.filter { $0.person != nil }
        let cast = ShikiCast(characters: chars, staff: staff)
        if castCache.count >= 64 { castCache.removeAll() }
        castCache[malId] = (Date(), cast)
        return cast
    }

    func franchise(name: String) async throws -> [ShikiRelatedRef] {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
        guard !clean.isEmpty else { return [] }
        if let hit = franchiseCache[clean], Date().timeIntervalSince(hit.0) < 600 {
            return hit.1
        }
        let data = try await query("""
        { animes(franchise: "\(clean)", limit: 30, censored: false) {
            id name russian kind score status episodes episodesAired
            airedOn { year month day } poster { originalUrl mainUrl main2xUrl }
        } }
        """)
        let raw = (try? decodeField(data["animes"], as: [ShikiRelatedRef].self)) ?? []
        let sorted = sortFranchiseEntries(raw)
        if franchiseCache.count >= 64 { franchiseCache.removeAll() }
        franchiseCache[clean] = (Date(), sorted)
        return sorted
    }

    func byStudio(studioId: String, limit: Int = 40) async throws -> [ShikiAnime] {
        let clean = studioId.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
        guard !clean.isEmpty else { return [] }
        if let hit = studioCache[clean], Date().timeIntervalSince(hit.0) < 600 {
            return hit.1
        }
        let data = try await query("""
        { animes(studio: "\(clean)", order: popularity, limit: \(limit), censored: false) {
            id name russian kind score status episodes episodesAired
            airedOn { year } poster { originalUrl mainUrl main2xUrl }
        } }
        """)
        let raw = (try? decodeField(data["animes"], as: [ShikiAnime].self)) ?? []
        var seen = Set<String>()
        let filtered = raw
            .filter { !franchiseSkipKinds.contains($0.kind ?? "") }
            .filter { seen.insert($0.id).inserted }
        if studioCache.count >= 64 { studioCache.removeAll() }
        studioCache[clean] = (Date(), filtered)
        return filtered
    }

    func cachedSchedule() -> [ShikiAnime]? {
        scheduleCache?.animes ?? offlineCache?.readSchedule()?.animes
    }

    func ongoingSchedule(extraMalIds: [Int64] = [], forceRefresh: Bool = false) async throws -> [ShikiAnime] {
        let wanted = Set(extraMalIds.filter { $0 > 0 })
        if !forceRefresh, let hit = scheduleCache,
           Date().timeIntervalSince(hit.savedAt) < 900,
           wanted.isSubset(of: hit.wanted) {
            return hit.animes
        }

        let fields = """
            id name russian kind score status episodes episodesAired nextEpisodeAt
            airedOn { year } poster { originalUrl mainUrl main2xUrl }
        """
        do {
            let popData = try await query("""
            { animes(status: "ongoing", order: popularity, limit: 50, censored: false) { \(fields) } }
            """)
            let popular = try decodeField(popData["animes"], as: [ShikiAnime].self)
            let have = Set(popular.map(\.id))
            let missing = Array(Set(extraMalIds.filter { $0 > 0 && !have.contains(String($0)) }).prefix(50))

            var extra: [ShikiAnime] = []
            if !missing.isEmpty {
                let ids = missing.map(String.init).joined(separator: ",")
                if let extraData = try? await query("""
                { animes(ids: "\(ids)", limit: \(missing.count), censored: false) { \(fields) } }
                """),
                   let decoded = try? decodeField(extraData["animes"], as: [ShikiAnime].self) {
                    extra = decoded
                }
            }

            var seen = Set<String>()
            let merged = (popular + extra).filter { seen.insert($0.id).inserted }
            scheduleCache = (Date(), wanted, merged)
            offlineCache?.writeSchedule(animes: merged)
            return merged
        } catch {
            if let cached = offlineCache?.readSchedule()?.animes, !cached.isEmpty {
                return cached
            }
            throw error
        }
    }
}
