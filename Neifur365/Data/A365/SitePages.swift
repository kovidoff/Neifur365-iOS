import Foundation
import SwiftSoup

/// Pure HTML parsers for Anime 365 pages that have no JSON counterpart.
enum SitePages {
    static func isSignedOut(_ html: String) -> Bool {
        html.contains("Вход по паролю") ||
        html.contains("Вход или регистрация") ||
        html.contains("Вход - Anime 365")
    }

    static func loginFailed(_ html: String) -> Bool {
        html.contains("Неверный E-mail или пароль")
    }

    static func profile(html: String, base: String) -> Profile? {
        guard !isSignedOut(html) else { return nil }
        guard let idStr = firstCapture(#"ID аккаунта:\s*(\d+)"#, in: html),
              let id = Int64(idStr) else {
            return nil
        }

        guard let doc = try? SwiftSoup.parse(html, base) else {
            return Profile(id: id, name: "Профиль", avatarUrl: nil, subscribed: nil, subscribedUntil: nil)
        }

        let name: String = {
            if let t = try? doc.select("content .m-small-title").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                return t
            }
            if let t = try? doc.select(".m-small-title").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                return t
            }
            return "Профиль"
        }()

        let avatar: String? = {
            let img = (try? doc.select("content .card-image.hide-on-small-and-down img").first())
                ?? (try? doc.select(".card-image img").first())
            guard let src = try? img?.absUrl("src"), !src.isEmpty else { return nil }
            return src
        }()

        let subCard: String? = {
            guard let headings = try? doc.select("h2").array() else { return nil }
            for h in headings {
                if (try? h.text().trimmingCharacters(in: .whitespacesAndNewlines)) == "Подписка" {
                    return try? h.parent()?.text()
                }
            }
            return nil
        }()

        let subscribed = subCard.map { !$0.localizedCaseInsensitiveContains("Не оплачена") }
        let subscribedUntil = (subscribed == true) ? subCard.flatMap { parseSubscriptionUntil($0) } : nil

        return Profile(id: id, name: name, avatarUrl: avatar, subscribed: subscribed, subscribedUntil: subscribedUntil)
    }

    private static let ruMonths: [String: Int] = [
        "янв": 1, "фев": 2, "мар": 3, "апр": 4, "май": 5, "мая": 5, "июн": 6,
        "июл": 7, "авг": 8, "сен": 9, "окт": 10, "ноя": 11, "дек": 12
    ]

    /// Extracts subscription expiration date and normalizes to ISO `yyyy-MM-dd`.
    static func parseSubscriptionUntil(_ text: String) -> String? {
        if let m = captures(#"(\d{1,2})\.(\d{1,2})\.(\d{4})"#, in: text), m.count == 3,
           let d = Int(m[0]), let mo = Int(m[1]), let y = Int(m[2]) {
            return formatISODate(year: y, month: mo, day: d)
        }
        if let m = captures(#"(\d{4})-(\d{2})-(\d{2})"#, in: text), m.count == 3,
           let y = Int(m[0]), let mo = Int(m[1]), let d = Int(m[2]) {
            return formatISODate(year: y, month: mo, day: d)
        }
        if let m = captures(#"(\d{1,2})\s+([а-яА-ЯёЁ]{3,})\.?\s+(\d{4})"#, in: text), m.count == 3,
           let d = Int(m[0]), let y = Int(m[2]) {
            let prefix = String(m[1].lowercased().prefix(3))
            if let mo = ruMonths[prefix] {
                return formatISODate(year: y, month: mo, day: d)
            }
        }
        return nil
    }

    static func seriesId(from href: String) -> Int64? {
        let clean = href.split(separator: "?").first.map(String.init) ?? href
        let noHash = clean.split(separator: "#").first.map(String.init) ?? clean
        let parts = noHash.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "catalog"), parts.indices.contains(i + 1) else { return nil }
        guard let last = parts[i + 1].split(separator: "-").last else { return nil }
        return Int64(last)
    }

    static func ids(from href: String) -> (Int64, Int64)? {
        let clean = href.split(separator: "?").first.map(String.init) ?? href
        let noHash = clean.split(separator: "#").first.map(String.init) ?? clean
        let parts = noHash.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "catalog"), parts.indices.contains(i + 2) else { return nil }
        guard let sStr = parts[i + 1].split(separator: "-").last, let s = Int64(sStr),
              let eStr = parts[i + 2].split(separator: "-").last, let e = Int64(eStr) else {
            return nil
        }
        return (s, e)
    }

    static func list(_ html: String) -> [ListEntry] {
        guard let doc = try? SwiftSoup.parse(html),
              let rows = try? doc.select("tr.m-animelist-item").array() else {
            return []
        }

        return rows.compactMap { row in
            guard let idStr = try? row.attr("data-id"), let id = Int64(idStr) else { return nil }

            var status: ListStatus?
            var parent = row.parent()
            while let p = parent {
                if p.hasAttr("data-status"), let raw = try? p.attr("data-status"), let sId = Int(raw) {
                    status = ListStatus.of(sId)
                    break
                }
                parent = p.parent()
            }

            let title = (try? row.select("a[href]").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            let epsText = (try? row.select("td[data-name=episodes]").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            let eps = epsText.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let watched = eps.first.flatMap(Int.init) ?? 0
            let total = eps.count > 1 ? Int(eps[1]) : nil

            let scoreText = (try? row.select("td[data-name=score]").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            let score = Int(scoreText).flatMap { $0 > 0 ? $0 : nil }

            return ListEntry(seriesId: id, title: title, watched: watched, total: total, score: score, status: status)
        }
    }

    static func listRecord(_ html: String) -> ListRecord {
        if html.contains("Добавить в список") {
            return ListRecord(status: nil, watched: 0, score: nil)
        }
        guard let doc = try? SwiftSoup.parse(html) else {
            return ListRecord(status: nil, watched: 0, score: nil)
        }
        let watched = (try? doc.select("input#UsersRates_episodes").first()?.attr("value")).flatMap(Int.init) ?? 0
        let status = (try? doc.select("select#UsersRates_status option[selected]").first()?.attr("value"))
            .flatMap(Int.init)
            .flatMap(ListStatus.of)
        let score = (try? doc.select("#UsersRates_score option[selected]").first()?.attr("value"))
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        return ListRecord(status: status, watched: watched, score: score)
    }

    static func resolve(base: String, url: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:\(url)" }
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        let u = url.hasPrefix("/") ? String(url.dropFirst()) : url
        return "\(b)/\(u)"
    }

    // MARK: - Helpers

    private static func formatISODate(year: Int, month: Int, day: Int) -> String? {
        var comp = DateComponents()
        comp.calendar = Calendar(identifier: .gregorian)
        comp.year = year
        comp.month = month
        comp.day = day
        guard comp.isValidDate else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { idx in
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }
    }
}
