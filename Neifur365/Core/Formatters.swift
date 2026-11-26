import Foundation

/// Cached formatters to avoid per-render allocations in SwiftUI views.
enum AppFormatters {
    static let byteCount: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useKB]
        return f
    }()

    static let timeHHMM: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let ruLongDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    static let ruShortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    static let ruWeekdayDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoInternet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: max(bytes, 0))
    }

    static func formatRussianDate(_ iso: String) -> String {
        guard let date = isoDateOnly.date(from: iso) else { return iso }
        return ruLongDate.string(from: date)
    }

    static func daysUntilISO(_ iso: String, now: Date = Date()) -> Int? {
        guard let target = isoDateOnly.date(from: iso) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let startNow = cal.startOfDay(for: now)
        let startTarget = cal.startOfDay(for: target)
        return cal.dateComponents([.day], from: startNow, to: startTarget).day
    }

    static func formatClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, r)
        }
        return String(format: "%02d:%02d", m, r)
    }
}
