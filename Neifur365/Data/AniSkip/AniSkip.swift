import Foundation

enum ChapterKind: String, Codable, Hashable {
    case opening
    case ending
    case recap
    case preview
    case other

    var isSkippable: Bool {
        self == .opening || self == .ending || self == .recap
    }
}

struct PlayerChapter: Hashable, Identifiable {
    let start: Double
    let title: String
    let kind: ChapterKind

    var id: String { "\(kind.rawValue)-\(Int(start * 10))" }

    static func classify(title: String) -> ChapterKind {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return .other }
        if lower.contains("opening") || lower.contains("опенинг") || lower == "op"
            || lower.hasPrefix("op ") || lower.contains("intro") || lower.contains("заставка") {
            return .opening
        }
        if lower.contains("ending") || lower.contains("эндинг") || lower == "ed"
            || lower.hasPrefix("ed ") || lower.contains("outro") || lower.contains("титры") {
            return .ending
        }
        if lower.contains("recap") || lower.contains("рекап") || lower.contains("ранее") {
            return .recap
        }
        if lower.contains("preview") || lower.contains("превью") || lower.contains("анонс") {
            return .preview
        }
        return .other
    }
}

struct SkipSegment: Equatable, Hashable {
    let start: Double
    let end: Double
    let kind: ChapterKind
    let label: String
}

private struct AniSkipInterval: Decodable {
    let startTime: Double
    let endTime: Double

    enum CodingKeys: String, CodingKey { case startTime, endTime }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTime = c.decodeLossyDoubleIfPresent(forKey: .startTime) ?? 0
        endTime = c.decodeLossyDoubleIfPresent(forKey: .endTime) ?? 0
    }
}

private struct AniSkipResult: Decodable {
    let interval: AniSkipInterval
    let skipType: String
    let episodeLength: Double

    enum CodingKeys: String, CodingKey { case interval, skipType, episodeLength }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = try c.decode(AniSkipInterval.self, forKey: .interval)
        skipType = c.decodeLossyString(forKey: .skipType)
        episodeLength = c.decodeLossyDoubleIfPresent(forKey: .episodeLength) ?? 0
    }
}

private struct AniSkipResponse: Decodable {
    let found: Bool
    let results: [AniSkipResult]

    enum CodingKeys: String, CodingKey { case found, results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = (try? c.decode(Bool.self, forKey: .found)) ?? false
        results = (try? c.decode([AniSkipResult].self, forKey: .results)) ?? []
    }
}

enum AniSkipParser {
    /// Maximum runtime difference (seconds) between stream and AniSkip's reference episodeLength.
    static let lengthToleranceSeconds: Double = 2.5

    static func parseAndFilterSkipTimes(data: Data, videoDuration: Double) -> [SkipSegment] {
        guard videoDuration > 60.0 else { return [] }
        guard let parsed = try? JSONDecoder().decode(AniSkipResponse.self, from: data),
              parsed.found, !parsed.results.isEmpty else {
            return []
        }

        let priority: [String: Int] = ["op": 0, "mixed-op": 1, "ed": 0, "mixed-ed": 1, "recap": 0]
        var bestByKind: [ChapterKind: (prio: Int, seg: SkipSegment)] = [:]

        for r in parsed.results {
            guard r.episodeLength > 60.0 else { continue }
            guard abs(videoDuration - r.episodeLength) <= lengthToleranceSeconds else { continue }

            let start = r.interval.startTime
            let end = r.interval.endTime
            let span = end - start
            guard start >= 0.0, span >= 5.0, span <= 240.0, end <= videoDuration + 1.5 else { continue }

            let kind: ChapterKind
            let label: String
            switch r.skipType {
            case "op", "mixed-op":
                kind = .opening
                label = "Опенинг"
            case "ed", "mixed-ed":
                kind = .ending
                label = "Эндинг"
            case "recap":
                kind = .recap
                label = "Рекап"
            default:
                continue
            }

            let prio = priority[r.skipType] ?? 2
            let seg = SkipSegment(start: start, end: min(end, videoDuration), kind: kind, label: label)
            if let existing = bestByKind[kind], existing.prio <= prio {
                continue
            }
            bestByKind[kind] = (prio, seg)
        }

        return bestByKind.values.map(\.seg).sorted { $0.start < $1.start }
    }

    static func skipSegmentsToChapters(_ segments: [SkipSegment], duration: Double) -> [PlayerChapter] {
        guard !segments.isEmpty, duration > 0 else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [PlayerChapter] = []
        var cursor: Double = 0

        for seg in sorted {
            let s = min(max(seg.start, cursor), duration)
            let e = min(max(seg.end, s), duration)
            guard e - s >= 2.0 else { continue }
            if s > cursor + 1.0 && out.isEmpty {
                out.append(PlayerChapter(start: 0.0, title: "", kind: .other))
            }
            out.append(PlayerChapter(start: s, title: seg.label, kind: seg.kind))
            if e < duration - 1.5 {
                out.append(PlayerChapter(start: e, title: "", kind: .other))
            }
            cursor = e
        }
        return out
    }
}

actor AniSkipClient {
    private let session: URLSession
    private var cache: [String: [SkipSegment]] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 6
        self.session = URLSession(configuration: cfg)
    }

    func skipTimes(malId: Int64, episodeNumber: Int, videoDurationSec: Double) async -> [SkipSegment] {
        guard malId > 0, episodeNumber > 0, videoDurationSec > 60.0 else { return [] }
        let key = "\(malId):\(episodeNumber):\(Int(videoDurationSec))"
        if let hit = cache[key] { return hit }

        let len = String(format: "%.3f", videoDurationSec)
        let urlStr = "https://api.aniskip.com/v2/skip-times/\(malId)/\(episodeNumber)?types=op&types=ed&types=mixed-op&types=mixed-ed&types=recap&episodeLength=\(len)"
        guard let url = URL(string: urlStr) else { return [] }

        let result: [SkipSegment] = await {
            do {
                let (data, resp) = try await session.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return []
                }
                return AniSkipParser.parseAndFilterSkipTimes(data: data, videoDuration: videoDurationSec)
            } catch {
                return []
            }
        }()

        if cache.count >= 64 { cache.removeAll() }
        cache[key] = result
        return result
    }
}
