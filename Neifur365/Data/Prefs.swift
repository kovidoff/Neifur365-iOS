import Foundation

struct FavouriteStudio: Codable, Hashable, Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

final class Prefs: ObservableObject {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        static let mirror = "nf_mirror"
        static let customMirrors = "nf_custom_mirrors"
        static let mirrorAuto = "nf_mirror_auto"
        static let savedProfile = "nf_saved_profile"
        static let history = "nf_history"
        static let quality = "nf_quality"
        static let preferredKind = "nf_preferred_kind"
        static let picks = "nf_translation_picks"
        static let favouriteStudios = "nf_favourite_studios_v2"
        static let subScale = "nf_sub_scale"
        static let seekStep = "nf_seek_step"
        static let holdBoost = "nf_hold_boost"
        static let sideGestures = "nf_side_gestures"
        static let downloadQuality = "nf_download_quality"
        static let autoDeleteDownloaded = "nf_auto_delete_dl"
        static let alertsEnabled = "nf_alerts_enabled"
        static let alertsPlanned = "nf_alerts_planned"
        static let alertsSeen = "nf_alerts_seen"
        static let alertsCheckedAt = "nf_alerts_checked_at"
    }

    @Published var mirror: String? {
        didSet {
            if let mirror { defaults.set(mirror, forKey: Key.mirror) }
            else { defaults.removeObject(forKey: Key.mirror) }
        }
    }
    @Published var customMirrors: [String] { didSet { defaults.set(customMirrors, forKey: Key.customMirrors) } }
    @Published var mirrorAuto: Bool { didSet { defaults.set(mirrorAuto, forKey: Key.mirrorAuto) } }
    @Published var history: [WatchEntry] {
        didSet { if let data = try? encoder.encode(history) { defaults.set(data, forKey: Key.history) } }
    }
    @Published var quality: Int { didSet { defaults.set(min(quality, maxStreamHeight), forKey: Key.quality) } }
    @Published var preferredKind: TranslationKind { didSet { defaults.set(preferredKind.rawValue, forKey: Key.preferredKind) } }
    @Published var favouriteStudios: [FavouriteStudio] {
        didSet { if let data = try? encoder.encode(favouriteStudios) { defaults.set(data, forKey: Key.favouriteStudios) } }
    }
    @Published var subScale: Double { didSet { defaults.set(subScale, forKey: Key.subScale) } }
    @Published var seekStep: Int { didSet { defaults.set(seekStep, forKey: Key.seekStep) } }
    @Published var holdBoost: Bool { didSet { defaults.set(holdBoost, forKey: Key.holdBoost) } }
    @Published var sideGestures: Bool { didSet { defaults.set(sideGestures, forKey: Key.sideGestures) } }
    @Published var downloadQuality: Int { didSet { defaults.set(min(downloadQuality, maxStreamHeight), forKey: Key.downloadQuality) } }
    @Published var autoDeleteDownloaded: Bool { didSet { defaults.set(autoDeleteDownloaded, forKey: Key.autoDeleteDownloaded) } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) } }
    @Published var alertsPlanned: Bool { didSet { defaults.set(alertsPlanned, forKey: Key.alertsPlanned) } }
    @Published var alertsCheckedAt: Date? {
        didSet {
            if let alertsCheckedAt { defaults.set(alertsCheckedAt.timeIntervalSince1970, forKey: Key.alertsCheckedAt) }
            else { defaults.removeObject(forKey: Key.alertsCheckedAt) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mirror = defaults.string(forKey: Key.mirror)
        self.customMirrors = defaults.stringArray(forKey: Key.customMirrors) ?? []
        self.mirrorAuto = defaults.object(forKey: Key.mirrorAuto) as? Bool ?? true

        if let data = defaults.data(forKey: Key.history),
           let decoded = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            self.history = decoded
        } else {
            self.history = []
        }

        let storedQ = defaults.integer(forKey: Key.quality)
        self.quality = storedQ > 0 ? min(storedQ, maxStreamHeight) : maxStreamHeight

        if let rawKind = defaults.string(forKey: Key.preferredKind), let kind = TranslationKind(rawValue: rawKind) {
            self.preferredKind = kind
        } else {
            self.preferredKind = .voiceRu
        }

        if let data = defaults.data(forKey: Key.favouriteStudios),
           let decoded = try? JSONDecoder().decode([FavouriteStudio].self, from: data) {
            self.favouriteStudios = decoded
        } else {
            self.favouriteStudios = []
        }

        let storedSub = defaults.double(forKey: Key.subScale)
        self.subScale = storedSub > 0.4 ? storedSub : 1.0
        let storedSeek = defaults.integer(forKey: Key.seekStep)
        self.seekStep = storedSeek > 0 ? storedSeek : 10
        self.holdBoost = defaults.object(forKey: Key.holdBoost) as? Bool ?? true
        self.sideGestures = defaults.object(forKey: Key.sideGestures) as? Bool ?? true

        let storedDlQ = defaults.integer(forKey: Key.downloadQuality)
        self.downloadQuality = storedDlQ > 0 ? min(storedDlQ, maxStreamHeight) : 720
        self.autoDeleteDownloaded = defaults.object(forKey: Key.autoDeleteDownloaded) as? Bool ?? false
        self.alertsEnabled = defaults.object(forKey: Key.alertsEnabled) as? Bool ?? false
        self.alertsPlanned = defaults.object(forKey: Key.alertsPlanned) as? Bool ?? false

        let checkedTs = defaults.double(forKey: Key.alertsCheckedAt)
        self.alertsCheckedAt = checkedTs > 0 ? Date(timeIntervalSince1970: checkedTs) : nil
    }

    func savedProfile() -> Profile? {
        guard let data = defaults.data(forKey: Key.savedProfile) else { return nil }
        return try? decoder.decode(Profile.self, from: data)
    }

    func saveProfile(_ profile: Profile?) {
        if let profile, let data = try? encoder.encode(profile) {
            defaults.set(data, forKey: Key.savedProfile)
        } else {
            defaults.removeObject(forKey: Key.savedProfile)
        }
    }

    func recordProgress(animeId: Int64, title: String, poster: String?, episode: Int, positionSec: Double, durationSec: Double) {
        let idStr = String(animeId)
        let entry = WatchEntry(
            animeId: idStr, title: title, poster: poster, episode: episode,
            positionSec: positionSec, durationSec: durationSec,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        var copy = history
        copy.removeAll { $0.animeId == idStr && $0.episode == episode }
        copy.insert(entry, at: 0)
        if copy.count > 200 { copy = Array(copy.prefix(200)) }
        history = copy
    }

    func savedPosition(animeId: Int64, episode: Int) -> Double {
        let idStr = String(animeId)
        guard let hit = history.first(where: { $0.animeId == idStr && $0.episode == episode }) else { return 0 }
        return hit.finished ? 0 : hit.positionSec
    }

    func removeFromHistory(animeId: String) {
        history.removeAll { $0.animeId == animeId }
    }

    func pick(animeId: Int64) -> String? {
        (defaults.dictionary(forKey: Key.picks) as? [String: String])?[String(animeId)]
    }

    func setPick(animeId: Int64, key: String) {
        var map = defaults.dictionary(forKey: Key.picks) as? [String: String] ?? [:]
        map[String(animeId)] = key
        defaults.set(map, forKey: Key.picks)
    }

    func clearPicks() { defaults.removeObject(forKey: Key.picks) }
    var pickCount: Int { (defaults.dictionary(forKey: Key.picks) as? [String: String])?.count ?? 0 }
    var favouriteStudioKeys: [String] { favouriteStudios.map(\.key) }

    func isFavouriteStudio(_ key: String) -> Bool {
        favouriteStudios.contains { $0.key == key }
    }

    func toggleFavouriteStudio(key: String, name: String) {
        if favouriteStudios.contains(where: { $0.key == key }) {
            favouriteStudios.removeAll { $0.key == key }
        } else {
            favouriteStudios.insert(FavouriteStudio(key: key, name: name), at: 0)
            if favouriteStudios.count > 30 { favouriteStudios = Array(favouriteStudios.prefix(30)) }
        }
    }

    func alertsSeen() -> [Int64: Int] {
        guard let dict = defaults.dictionary(forKey: Key.alertsSeen) as? [String: Int] else { return [:] }
        var out: [Int64: Int] = [:]
        for (k, v) in dict { if let id = Int64(k) { out[id] = v } }
        return out
    }

    func saveAlertsSeen(_ seen: [Int64: Int]) {
        var dict: [String: Int] = [:]
        for (k, v) in seen { dict[String(k)] = v }
        defaults.set(dict, forKey: Key.alertsSeen)
        alertsCheckedAt = Date()
    }
}
