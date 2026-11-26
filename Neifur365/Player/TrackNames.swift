import Foundation

enum SubKind: Int, Hashable {
    case full = 0
    case signs = 1
    case captions = 2
}

struct MpvTrack: Identifiable, Hashable {
    let id: Int
    let type: String // "audio" or "sub"
    let lang: String?
    let title: String?
    let codec: String?
    let isForced: Bool
    let isExternal: Bool
    let isSelected: Bool

    var info: TrackInfo { TrackNames.describe(self) }
}

struct TrackInfo: Hashable {
    let lang: String?
    let name: String
    let region: String?
    let source: String?
    let note: String?
    let kind: SubKind

    var detail: String? {
        let joined = [region, source, note].compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }
}

enum TrackNames {
    private static let langNames: [String: String] = [
        "ja": "Японский", "en": "Английский", "ru": "Русский", "uk": "Украинский",
        "zh": "Китайский", "ko": "Корейский", "es": "Испанский", "pt": "Португальский",
        "fr": "Французский", "de": "Немецкий", "it": "Итальянский", "ar": "Арабский",
        "pl": "Польский", "tr": "Турецкий", "id": "Индонезийский", "ms": "Малайский",
        "th": "Тайский", "vi": "Вьетнамский", "hi": "Хинди", "fil": "Филиппинский",
        "nl": "Нидерландский", "sv": "Шведский", "cs": "Чешский", "hu": "Венгерский",
        "ro": "Румынский", "el": "Греческий", "he": "Иврит", "fi": "Финский",
        "da": "Датский", "no": "Норвежский", "ca": "Каталанский", "ta": "Тамильский",
        "te": "Телугу", "bn": "Бенгальский"
    ]

    private static let isoMap: [String: String] = [
        "ja": "ja", "jpn": "ja", "jp": "ja",
        "en": "en", "eng": "en",
        "ru": "ru", "rus": "ru",
        "uk": "uk", "ukr": "uk",
        "zh": "zh", "chi": "zh", "zho": "zh", "chs": "zh", "cht": "zh", "cmn": "zh", "yue": "zh",
        "ko": "ko", "kor": "ko",
        "es": "es", "spa": "es",
        "pt": "pt", "por": "pt",
        "fr": "fr", "fre": "fr", "fra": "fr",
        "de": "de", "ger": "de", "deu": "de",
        "it": "it", "ita": "it",
        "ar": "ar", "ara": "ar",
        "pl": "pl", "pol": "pl",
        "tr": "tr", "tur": "tr",
        "id": "id", "ind": "id",
        "ms": "ms", "may": "ms", "msa": "ms",
        "th": "th", "tha": "th",
        "vi": "vi", "vie": "vi",
        "hi": "hi", "hin": "hi",
        "fil": "fil", "tl": "fil", "tgl": "fil",
        "nl": "nl", "dut": "nl", "nld": "nl",
        "sv": "sv", "swe": "sv",
        "cs": "cs", "cze": "cs", "ces": "cs",
        "hu": "hu", "hun": "hu",
        "ro": "ro", "rum": "ro", "ron": "ro",
        "el": "el", "gre": "el", "ell": "el",
        "he": "he", "heb": "he",
        "fi": "fi", "fin": "fi",
        "da": "da", "dan": "da",
        "no": "no", "nor": "no", "nob": "no",
        "ca": "ca", "cat": "ca",
        "ta": "ta", "tam": "ta",
        "te": "te", "tel": "te",
        "bn": "bn", "ben": "bn"
    ]

    private static let regionTag: [String: String] = [
        "br": "Бразилия", "pt": "Португалия", "419": "Латинская Америка", "es": "Испания", "mx": "Мексика",
        "la": "Латинская Америка", "fr": "Франция", "ca": "Канада", "us": "США", "gb": "Великобритания",
        "hans": "упрощённый", "hant": "традиционный", "cn": "материковый", "tw": "Тайвань", "hk": "Гонконг",
        "sa": "Саудовская Аравия", "de": "Германия", "it": "Италия"
    ]

    private static let regionWords: [(String, String)] = [
        (#"(?i)latin[\s_-]*america(?:n)?|latino|latam"#, "Латинская Америка"),
        (#"(?i)\bbrazil(?:ian)?\b|\(brazil\)"#, "Бразилия"),
        (#"(?i)\b(?:spain|castilian|castellano|european spanish)\b"#, "Испания"),
        (#"(?i)\bportugal\b"#, "Португалия"),
        (#"(?i)\bsaudi[\s_-]*arabia\b"#, "Саудовская Аравия"),
        (#"(?i)\bsimplified\b|简体|簡體|\bchs\b|\bsc\b"#, "упрощённый"),
        (#"(?i)\btraditional\b|繁體|繁体|\bcht\b|\btc\b"#, "традиционный"),
        (#"(?i)\bcanad(?:a|ian)\b"#, "Канада")
    ]

    private static let sources: [(String, String)] = [
        (#"(?i)(?<![a-z])(?:cr|crunchyroll)(?![a-z])"#, "Crunchyroll"),
        (#"(?i)(?<![a-z])(?:amzn|amazon)(?![a-z])"#, "Amazon"),
        (#"(?i)(?<![a-z])(?:nf|netflix)(?![a-z])"#, "Netflix"),
        (#"(?i)(?<![a-z])(?:dsnp|disney\+?)(?![a-z])"#, "Disney+"),
        (#"(?i)(?<![a-z])hidive(?![a-z])"#, "HIDIVE"),
        (#"(?i)(?<![a-z])(?:b-?global|bilibili|bili)(?![a-z])"#, "Bilibili"),
        (#"(?i)(?<![a-z])adn(?![a-z])"#, "ADN"),
        (#"(?i)(?<![a-z])abema(?![a-z])"#, "ABEMA")
    ]

    private static let titleLangHints: [(String, String)] = [
        (#"(?i)\b(?:japanese|jpn|日本語)\b"#, "ja"),
        (#"(?i)\b(?:russian|русский|rus)\b"#, "ru"),
        (#"(?i)\b(?:english|eng)\b"#, "en"),
        (#"(?i)\b(?:ukrainian|українськ|ukr)\b"#, "uk"),
        (#"(?i)\b(?:spanish|español|spa)\b"#, "es"),
        (#"(?i)\b(?:portuguese|português|por|brazilian|brasil)\b"#, "pt"),
        (#"(?i)\b(?:french|français|fre|fra)\b"#, "fr"),
        (#"(?i)\b(?:german|deutsch|ger|deu)\b"#, "de"),
        (#"(?i)\b(?:italian|italiano|ita)\b"#, "it"),
        (#"(?i)\b(?:arabic|ara)\b"#, "ar"),
        (#"(?i)\b(?:chinese|chi|zho)\b"#, "zh"),
        (#"(?i)\b(?:korean|kor)\b"#, "ko")
    ]

    private static let signsPattern = #"(?i)\b(?:signs?|songs?|forced|надписи|караоке|karaoke)\b"#
    private static let ccPattern = #"(?i)(?<![a-z])(?:cc|sdh|hearing[\s_-]*impaired)(?![a-z])"#
    private static let fullPattern = #"(?i)\b(?:full(?:[\s_-]*subtitles?)?|dialogue|dialog|полные)\b"#
    private static let noisePattern = #"(?i)\[[^\]]*\]|\b(?:aac|flac|opus|e?-?ac-?3|ddp?|dts(?:-?hd)?|truehd|pcm|mp3|ass|ssa|srt|pgs|sup|vobsub|subrip|subtitles?|subs?|audio|track|stereo|mono|\d\.\d|\d{2,3}\s?kbps|default|main)\b"#

    static func describe(_ track: MpvTrack) -> TrackInfo {
        let tag = track.lang?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let baseTag = tag?.split(separator: "-").first.map(String.init)
        var code = baseTag.flatMap { isoMap[$0] }

        var region: String? = nil
        if let tag, let dash = tag.firstIndex(of: "-") {
            let suffix = tag[tag.index(after: dash)...]
            for part in suffix.split(separator: "-") {
                if let hit = regionTag[String(part)] {
                    region = hit
                    break
                }
            }
        }

        let title = (track.title ?? "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if code == nil {
            for (pattern, langCode) in titleLangHints {
                if title.range(of: pattern, options: .regularExpression) != nil {
                    code = langCode
                    break
                }
            }
        }

        if region == nil {
            for (pattern, regName) in regionWords {
                if title.range(of: pattern, options: .regularExpression) != nil {
                    region = regName
                    break
                }
            }
        }

        var source: String? = nil
        for (pattern, srcName) in sources {
            if title.range(of: pattern, options: .regularExpression) != nil {
                source = srcName
                break
            }
        }

        let hasSigns = title.range(of: signsPattern, options: .regularExpression) != nil
        let hasFull = title.range(of: fullPattern, options: .regularExpression) != nil
        let hasCC = title.range(of: ccPattern, options: .regularExpression) != nil

        let kind: SubKind
        if track.isForced || (hasSigns && !hasFull) {
            kind = .signs
        } else if hasCC {
            kind = .captions
        } else {
            kind = .full
        }

        var rest = title
        rest = rest.replacingOccurrences(of: noisePattern, with: " ", options: .regularExpression)
        for (pattern, _) in regionWords { rest = rest.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        for (pattern, _) in sources { rest = rest.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        for (pattern, _) in titleLangHints { rest = rest.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        rest = rest.replacingOccurrences(of: signsPattern, with: " ", options: .regularExpression)
        rest = rest.replacingOccurrences(of: ccPattern, with: " ", options: .regularExpression)
        rest = rest.replacingOccurrences(of: fullPattern, with: " ", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"[()\-–—|/:,.+]+"#, with: " ", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let note: String?
        if (3...28).contains(rest.count),
           rest.contains(where: \.isLetter),
           source.map({ rest.caseInsensitiveCompare($0) != .orderedSame }) ?? true {
            note = rest
        } else {
            note = nil
        }

        let name: String
        if let code, let ruName = langNames[code] {
            name = ruName
        } else if tag == nil || tag == "und" || tag == "mul" || tag == "zxx" {
            name = track.type == "audio" ? "Дорожка \(track.id)" : "Субтитры \(track.id)"
        } else {
            name = tag!.uppercased()
        }

        return TrackInfo(lang: code, name: name, region: region, source: source, note: note, kind: kind)
    }

    static func sortKey(_ track: MpvTrack) -> String {
        let info = track.info
        let order = track.type == "audio" ? ["ja", "ru", "en", "uk"] : ["ru", "en", "ja", "uk"]
        let rank: Int
        if let lang = info.lang, let idx = order.firstIndex(of: lang) {
            rank = idx
        } else {
            rank = info.lang == nil ? 90 : 50
        }
        return String(format: "%02d|%@|%@|%d|%05d", rank, info.name, info.region ?? "", info.kind.rawValue, track.id)
    }
}
