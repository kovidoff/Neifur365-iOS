import Foundation

/// Highest picture height Anime 365 streams (catalog can list 2160p source files, streams cap at 1080p).
let maxStreamHeight = 1080

struct Titles: Codable, Hashable {
    var ru: String?
    var romaji: String?
    var en: String?
    var ja: String?

    init(ru: String? = nil, romaji: String? = nil, en: String? = nil, ja: String? = nil) {
        self.ru = ru
        self.romaji = romaji
        self.en = en
        self.ja = ja
    }
}

struct SeriesGenre: Codable, Hashable, Identifiable {
    var id: Int
    var title: String

    init(id: Int = 0, title: String = "") {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeLossyInt(forKey: .id)
        title = c.decodeLossyString(forKey: .title)
    }
}

struct SeriesDescription: Codable, Hashable {
    var source: String?
    var value: String?
}

struct Series: Codable, Hashable, Identifiable {
    var id: Int64
    var myAnimeListId: Int64
    var myAnimeListScore: Double?
    var numberOfEpisodes: Int
    var season: String?
    var year: Int
    var type: String?
    var typeTitle: String?
    var isAiring: Int
    var titles: Titles
    var posterUrl: String?
    var posterUrlSmall: String?
    var genres: [SeriesGenre]?
    var descriptions: [SeriesDescription]?
    var episodes: [Episode]?

    init(
        id: Int64,
        myAnimeListId: Int64 = 0,
        myAnimeListScore: Double? = nil,
        numberOfEpisodes: Int = 0,
        season: String? = nil,
        year: Int = 0,
        type: String? = nil,
        typeTitle: String? = nil,
        isAiring: Int = 0,
        titles: Titles = Titles(),
        posterUrl: String? = nil,
        posterUrlSmall: String? = nil,
        genres: [SeriesGenre]? = nil,
        descriptions: [SeriesDescription]? = nil,
        episodes: [Episode]? = nil
    ) {
        self.id = id
        self.myAnimeListId = myAnimeListId
        self.myAnimeListScore = myAnimeListScore
        self.numberOfEpisodes = numberOfEpisodes
        self.season = season
        self.year = year
        self.type = type
        self.typeTitle = typeTitle
        self.isAiring = isAiring
        self.titles = titles
        self.posterUrl = posterUrl
        self.posterUrlSmall = posterUrlSmall
        self.genres = genres
        self.descriptions = descriptions
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeLossyInt64(forKey: .id)
        myAnimeListId = c.decodeLossyInt64(forKey: .myAnimeListId)
        myAnimeListScore = c.decodeLossyDoubleIfPresent(forKey: .myAnimeListScore)
        numberOfEpisodes = c.decodeLossyInt(forKey: .numberOfEpisodes)
        season = try? c.decodeIfPresent(String.self, forKey: .season)
        year = c.decodeLossyInt(forKey: .year)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        typeTitle = try? c.decodeIfPresent(String.self, forKey: .typeTitle)
        isAiring = c.decodeLossyInt(forKey: .isAiring)
        titles = (try? c.decodeIfPresent(Titles.self, forKey: .titles)) ?? Titles()
        posterUrl = try? c.decodeIfPresent(String.self, forKey: .posterUrl)
        posterUrlSmall = try? c.decodeIfPresent(String.self, forKey: .posterUrlSmall)
        genres = try? c.decodeIfPresent([SeriesGenre].self, forKey: .genres)
        descriptions = try? c.decodeIfPresent([SeriesDescription].self, forKey: .descriptions)
        episodes = try? c.decodeIfPresent([Episode].self, forKey: .episodes)
    }

    var title: String {
        if let ru = titles.ru, !ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ru }
        if let romaji = titles.romaji, !romaji.isEmpty { return romaji }
        if let en = titles.en, !en.isEmpty { return en }
        return "Без названия"
    }

    var original: String? {
        guard let romaji = titles.romaji, !romaji.isEmpty, romaji != title else { return nil }
        return romaji
    }

    var score: Double? {
        guard let s = myAnimeListScore, s > 0 else { return nil }
        return s
    }

    var airing: Bool { isAiring == 1 }
    var isMovie: Bool { type == "movie" }

    var bestPosterUrl: String? { posterUrl ?? posterUrlSmall }

    var descriptionText: String? {
        (descriptions ?? [])
            .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count })
    }

    var playable: [Episode] {
        (episodes ?? [])
            .filter { $0.isActive == 1 && $0.episodeType != "preview" }
            .sorted { a, b in
                if a.number != b.number { return a.number < b.number }
                return a.id < b.id
            }
    }
}

struct Episode: Codable, Hashable, Identifiable {
    var id: Int64
    var episodeFull: String
    var episodeInt: Double?
    var episodeTitle: String?
    var episodeType: String?
    var firstUploadedDateTime: String?
    var isActive: Int
    var seriesId: Int64
    var translations: [Translation]?

    init(
        id: Int64,
        episodeFull: String = "",
        episodeInt: Double? = nil,
        episodeTitle: String? = nil,
        episodeType: String? = nil,
        firstUploadedDateTime: String? = nil,
        isActive: Int = 1,
        seriesId: Int64 = 0,
        translations: [Translation]? = nil
    ) {
        self.id = id
        self.episodeFull = episodeFull
        self.episodeInt = episodeInt
        self.episodeTitle = episodeTitle
        self.episodeType = episodeType
        self.firstUploadedDateTime = firstUploadedDateTime
        self.isActive = isActive
        self.seriesId = seriesId
        self.translations = translations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeLossyInt64(forKey: .id)
        episodeFull = c.decodeLossyString(forKey: .episodeFull)
        episodeInt = c.decodeLossyDoubleIfPresent(forKey: .episodeInt)
        episodeTitle = try? c.decodeIfPresent(String.self, forKey: .episodeTitle)
        episodeType = try? c.decodeIfPresent(String.self, forKey: .episodeType)
        firstUploadedDateTime = try? c.decodeIfPresent(String.self, forKey: .firstUploadedDateTime)
        isActive = c.decodeLossyInt(forKey: .isActive, default: 1)
        seriesId = c.decodeLossyInt64(forKey: .seriesId)
        translations = try? c.decodeIfPresent([Translation].self, forKey: .translations)
    }

    var number: Int { Int(episodeInt ?? 0) }

    var label: String {
        if let n = episodeInt, n > 0, episodeFull.localizedCaseInsensitiveContains("сери") {
            return "Серия \(number)"
        }
        return episodeFull.isEmpty ? "Серия \(number)" : episodeFull
    }
}

enum TranslationKind: String, CaseIterable, Codable, Hashable, Comparable {
    case voiceRu = "VoiceRu"
    case subRu = "SubRu"
    case raw = "Raw"
    case voiceEn = "VoiceEn"
    case subEn = "SubEn"
    case voiceUk = "VoiceUk"
    case subUk = "SubUk"
    case subJa = "SubJa"
    case hidden = "Hidden"

    var orderIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 99
    }

    static func < (lhs: TranslationKind, rhs: TranslationKind) -> Bool {
        lhs.orderIndex < rhs.orderIndex
    }

    static var shown: [TranslationKind] {
        allCases.filter { $0 != .hidden }
    }

    var title: String {
        switch self {
        case .voiceRu: return "Озвучка"
        case .subRu: return "Русские субтитры"
        case .raw: return "RAW"
        case .voiceEn: return "Английская озвучка"
        case .subEn: return "Английские субтитры"
        case .voiceUk: return "Украинская озвучка"
        case .subUk: return "Украинские субтитры"
        case .subJa: return "Японские субтитры"
        case .hidden: return ""
        }
    }

    var short: String {
        switch self {
        case .voiceRu: return "Озвучка"
        case .subRu: return "Субтитры"
        case .raw: return "RAW"
        case .voiceEn: return "EN озвучка"
        case .subEn: return "EN субтитры"
        case .voiceUk: return "UA озвучка"
        case .subUk: return "UA субтитры"
        case .subJa: return "JP субтитры"
        case .hidden: return ""
        }
    }

    var inline: String {
        switch self {
        case .voiceRu: return "озвучка"
        case .subRu: return "русские субтитры"
        case .raw: return "RAW, без перевода"
        case .voiceEn: return "англ. озвучка"
        case .subEn: return "англ. субтитры"
        case .voiceUk: return "укр. озвучка"
        case .subUk: return "укр. субтитры"
        case .subJa: return "япон. субтитры"
        case .hidden: return ""
        }
    }

    var isSubs: Bool {
        switch self {
        case .subRu, .subEn, .subUk, .subJa: return true
        default: return false
        }
    }

    static func of(type: String, kind: String, lang: String) -> TranslationKind {
        switch type {
        case "voiceRu": return .voiceRu
        case "subRu": return .subRu
        case "raw": return .raw
        case "voiceEn": return .voiceEn
        case "subEn": return .subEn
        case "voiceUk", "voiceUa": return .voiceUk
        case "subUk", "subUa": return .subUk
        case "subJa": return .subJa
        case "":
            if kind == "raw" { return .raw }
            if kind == "voice" && lang == "ru" { return .voiceRu }
            if kind == "sub" && lang == "ru" { return .subRu }
            return .hidden
        default:
            return .hidden
        }
    }
}

struct Translation: Codable, Hashable, Identifiable {
    var id: Int64
    var authorsSummary: String
    var authorsList: [String]
    var type: String
    var typeKind: String
    var typeLang: String
    var qualityType: String
    var height: Int
    var priority: Int64
    var isActive: Int
    var episodeId: Int64
    var duration: Double

    init(
        id: Int64,
        authorsSummary: String = "",
        authorsList: [String] = [],
        type: String = "",
        typeKind: String = "",
        typeLang: String = "",
        qualityType: String = "",
        height: Int = 0,
        priority: Int64 = 0,
        isActive: Int = 1,
        episodeId: Int64 = 0,
        duration: Double = 0
    ) {
        self.id = id
        self.authorsSummary = authorsSummary
        self.authorsList = authorsList
        self.type = type
        self.typeKind = typeKind
        self.typeLang = typeLang
        self.qualityType = qualityType
        self.height = height
        self.priority = priority
        self.isActive = isActive
        self.episodeId = episodeId
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeLossyInt64(forKey: .id)
        authorsSummary = c.decodeLossyString(forKey: .authorsSummary)
        authorsList = (try? c.decodeIfPresent([String].self, forKey: .authorsList)) ?? []
        type = c.decodeLossyString(forKey: .type)
        typeKind = c.decodeLossyString(forKey: .typeKind)
        typeLang = c.decodeLossyString(forKey: .typeLang)
        qualityType = c.decodeLossyString(forKey: .qualityType)
        height = c.decodeLossyInt(forKey: .height)
        priority = c.decodeLossyInt64(forKey: .priority)
        isActive = c.decodeLossyInt(forKey: .isActive, default: 1)
        episodeId = c.decodeLossyInt64(forKey: .episodeId)
        duration = c.decodeLossyDoubleIfPresent(forKey: .duration) ?? 0
    }

    var kind: TranslationKind { TranslationKind.of(type: type, kind: typeKind, lang: typeLang) }
    var shown: Bool { isActive == 1 && kind != .hidden }

    var author: String {
        let stripped = authorsSummary.replacingOccurrences(
            of: #"\s*[\[(][^\])]*[\])]"#,
            with: "",
            options: .regularExpression
        )
        let trimSet = CharacterSet(charactersIn: "-–—· \t\n")
        let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: trimSet)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        let fallback = authorsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Без названия" : fallback
    }

    var details: String {
        guard let regex = try? NSRegularExpression(pattern: #"[\[(]([^\])]*)[\])]"#) else { return "" }
        let range = NSRange(authorsSummary.startIndex..., in: authorsSummary)
        var seen = Set<String>()
        var parts: [String] = []
        for match in regex.matches(in: authorsSummary, range: range) {
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: authorsSummary) else { continue }
            let val = authorsSummary[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty && seen.insert(val).inserted {
                parts.append(val)
            }
        }
        return parts.joined(separator: " · ")
    }

    var pickKey: String { "\(kind.rawValue)|\(author.lowercased())" }
    var streamHeight: Int { min(height, maxStreamHeight) }

    var qualityLabel: String {
        var out = height > 0 ? "\(streamHeight)p" : ""
        if qualityType == "bd" {
            out += out.isEmpty ? "BD" : " · BD"
        } else if qualityType == "dvd" {
            out += out.isEmpty ? "DVD" : " · DVD"
        }
        return out
    }
}

struct EmbedStream: Codable, Hashable {
    var height: Int
    var urls: [String]

    init(height: Int = 0, urls: [String] = []) {
        self.height = height
        self.urls = urls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        height = c.decodeLossyInt(forKey: .height)
        urls = (try? c.decodeIfPresent([String].self, forKey: .urls)) ?? []
    }
}

struct Embed: Codable, Hashable {
    var stream: [EmbedStream]
    var subtitlesUrl: String?
    var subtitlesVttUrl: String?

    init(stream: [EmbedStream] = [], subtitlesUrl: String? = nil, subtitlesVttUrl: String? = nil) {
        self.stream = stream
        self.subtitlesUrl = subtitlesUrl
        self.subtitlesVttUrl = subtitlesVttUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream = (try? c.decodeIfPresent([EmbedStream].self, forKey: .stream)) ?? []
        subtitlesUrl = try? c.decodeIfPresent(String.self, forKey: .subtitlesUrl)
        subtitlesVttUrl = try? c.decodeIfPresent(String.self, forKey: .subtitlesVttUrl)
    }
}

struct EpisodeSubtitles {
    let data: Data
    let fileExtension: String

    init?(text: String) {
        let header = text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if header.hasPrefix("WEBVTT") {
            fileExtension = "vtt"
        } else if header.hasPrefix("[Script Info]") ||
                    (header.hasPrefix("[V4") && header.contains("[Events]")) {
            fileExtension = "ass"
        } else {
            return nil
        }
        data = Data(text.utf8)
    }
}

// MARK: - Site Pages Models

struct Profile: Codable, Hashable, Identifiable {
    var id: Int64
    var name: String
    var avatarUrl: String?
    var subscribed: Bool?
    var subscribedUntil: String?
}

enum ListStatus: Int, CaseIterable, Codable, Hashable, Identifiable {
    case watching = 1
    case planned = 0
    case completed = 2
    case onHold = 3
    case dropped = 4

    var id: Int { rawValue }

    var path: String {
        switch self {
        case .watching: return "watching"
        case .planned: return "planned"
        case .completed: return "completed"
        case .onHold: return "onhold"
        case .dropped: return "dropped"
        }
    }

    var title: String {
        switch self {
        case .watching: return "Смотрю"
        case .planned: return "Запланировано"
        case .completed: return "Просмотрено"
        case .onHold: return "Отложено"
        case .dropped: return "Брошено"
        }
    }

    var systemImage: String {
        switch self {
        case .watching: return "play.circle.fill"
        case .planned: return "bookmark.fill"
        case .completed: return "checkmark.circle.fill"
        case .onHold: return "pause.circle.fill"
        case .dropped: return "xmark.circle.fill"
        }
    }

    static func of(_ id: Int) -> ListStatus? {
        allCases.first { $0.rawValue == id }
    }
}

func scoreLabel(_ score: Int) -> String {
    switch score {
    case 10: return "Шедевр"
    case 9: return "Великолепно"
    case 8: return "Очень хорошо"
    case 7: return "Хорошо"
    case 6: return "Неплохо"
    case 5: return "Средне"
    case 4: return "Плохо"
    case 3: return "Очень плохо"
    case 2: return "Ужасно"
    case 1: return "Отвратительно"
    default: return "Без оценки"
    }
}

struct ListEntry: Codable, Hashable, Identifiable {
    var seriesId: Int64
    var title: String
    var watched: Int
    var total: Int?
    var score: Int?
    var status: ListStatus?

    var id: Int64 { seriesId }
}

struct ListRecord: Codable, Hashable {
    var status: ListStatus?
    var watched: Int
    var score: Int?
}

struct WatchEntry: Codable, Hashable, Identifiable {
    var animeId: String
    var title: String
    var poster: String?
    var episode: Int
    var positionSec: Double
    var durationSec: Double
    var updatedAt: Int64

    var id: String { "\(animeId)-\(episode)" }

    var progress: Double {
        guard durationSec > 0 else { return 0 }
        return min(max(positionSec / durationSec, 0), 1)
    }

    var finished: Bool {
        durationSec > 0 && positionSec / durationSec > 0.92
    }
}
