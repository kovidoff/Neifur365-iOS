import Foundation

struct FavouriteStudio: Codable, Hashable, Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

struct PendingWatch: Codable, Hashable, Identifiable {
    let seriesId: Int64
    let episodeNumber: Int
    let translationId: Int64
    let queuedAt: Date
    var id: String { "\(seriesId)-\(episodeNumber)-\(translationId)" }
}

final class Prefs: ObservableObject {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        static let mirror = "nf_mirror"
        static let customMirrors = "nf_custom_mirrors"
        static let mirrorAuto = "nf_mirror_auto"
        static let channelAuto = "nf_channel_auto"
        static let channelCheckedAt = "nf_channel_checked_at"
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
        static let rememberBrightness = "nf_remember_brightness"
        static let savedBrightness = "nf_saved_brightness"
        static let aniskipEnabled = "nf_aniskip_enabled"
        static let normalizeAudio = "nf_normalize_audio"
        static let downloadQuality = "nf_download_quality"
        static let wifiOnlyDownloads = "nf_wifi_only_dl"
        static let autoDeleteDownloaded = "nf_auto_delete_dl"
        static let alertsEnabled = "nf_alerts_enabled"
        static let alertsMyStudio = "nf_alerts_my_studio"
        static let alertsPlanned = "nf_alerts_planned"
        static let alertsSeen = "nf_alerts_seen"
        static let alertsCheckedAt = "nf_alerts_checked_at"
        static let recentSearches = "nf_recent_searches"
        static let onboarded = "nf_onboarded"
        static let pendingWatches = "nf_pending_watches"
        static let owner = "nf_owner_id"
        static let stash = "nf_account_stash"
    }

    private struct AccountStash: Codable {
        var history: [WatchEntry]
        var picks: [String: String]
        var alertsSeen: [String: Int]
        var alertsCheckedAt: TimeInterval
        var channelCheckedAt: TimeInterval
        var pendingWatches: [PendingWatch]
    }

    @Published var mirror: String? {
        didSet {
            if let mirror { defaults.set(mirror, forKey: Key.mirror) }
            else { defaults.removeObject(forKey: Key.mirror) }
        }
    }
    @Published var customMirrors: [String] { didSet { defaults.set(customMirrors, forKey: Key.customMirrors) } }
    @Published var mirrorAuto: Bool { didSet { defaults.set(mirrorAuto, forKey: Key.mirrorAuto) } }
    @Published var channelAuto: Bool { didSet { defaults.set(channelAuto, forKey: Key.channelAuto) } }
    @Published var channelCheckedAt: Date? {
        didSet {
            if let channelCheckedAt { defaults.set(channelCheckedAt.timeIntervalSince1970, forKey: Key.channelCheckedAt) }
            else { defaults.removeObject(forKey: Key.channelCheckedAt) }
        }
    }

    @Published var history: [WatchEntry] {
        didSet { if let data = try? encoder.encode(history) { defaults.set(data, forKey: Key.history) } }
    }
    @Published var quality: Int { didSet { defaults.set(min(quality, maxStreamHeight), forKey: Key.quality) } }
    @Published var preferredKind: TranslationKind { didSet { defaults.set(preferredKind.rawValue, forKey: Key.preferredKind) } }
    @Published var favouriteStudios: [FavouriteStudio] {
        didSet { if let data = try? encoder.encode(favouriteStudios) { defaults.set(data, forKey: Key.favouriteStudios) } }
    }
    @Published private(set) var pickCount: Int = 0

    @Published var subScale: Double { didSet { defaults.set(subScale, forKey: Key.subScale) } }
    @Published var seekStep: Int { didSet { defaults.set(seekStep, forKey: Key.seekStep) } }
    @Published var holdBoost: Bool { didSet { defaults.set(holdBoost, forKey: Key.holdBoost) } }
    @Published var sideGestures: Bool { didSet { defaults.set(sideGestures, forKey: Key.sideGestures) } }
    @Published var rememberBrightness: Bool { didSet { defaults.set(rememberBrightness, forKey: Key.rememberBrightness) } }
    @Published var savedBrightness: Double { didSet { defaults.set(savedBrightness, forKey: Key.savedBrightness) } }
    @Published var aniskipEnabled: Bool { didSet { defaults.set(aniskipEnabled, forKey: Key.aniskipEnabled) } }
    @Published var normalizeAudio: Bool { didSet { defaults.set(normalizeAudio, forKey: Key.normalizeAudio) } }

    @Published var downloadQuality: Int { didSet { defaults.set(min(downloadQuality, maxStreamHeight), forKey: Key.downloadQuality) } }
    @Published var wifiOnlyDownloads: Bool { didSet { defaults.set(wifiOnlyDownloads, forKey: Key.wifiOnlyDownloads) } }
    @Published var autoDeleteDownloaded: Bool { didSet { defaults.set(autoDeleteDownloaded, forKey: Key.autoDeleteDownloaded) } }

    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) } }
    @Published var alertsMyStudio: Bool { didSet { defaults.set(alertsMyStudio, forKey: Key.alertsMyStudio) } }
    @Published var alertsPlanned: Bool { didSet { defaults.set(alertsPlanned, forKey: Key.alertsPlanned) } }
    @Published var alertsCheckedAt: Date? {
        didSet {
            if let alertsCheckedAt { defaults.set(alertsCheckedAt.timeIntervalSince1970, forKey: Key.alertsCheckedAt) }
            else { defaults.removeObject(forKey: Key.alertsCheckedAt) }
        }
    }

    @Published var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Key.recentSearches) } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Key.onboarded) } }
    @Published var pendingWatches: [PendingWatch] {
        didSet { if let data = try? encoder.encode(pendingWatches) { defaults.set(data, forKey: Key.pendingWatches) } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mirror = defaults.string(forKey: Key.mirror)
        self.customMirrors = defaults.stringArray(forKey: Key.customMirrors) ?? []
        self.mirrorAuto = defaults.object(forKey: Key.mirrorAuto) as? Bool ?? true
        self.channelAuto = defaults.object(forKey: Key.channelAuto) as? Bool ?? true
        let chTs = defaults.double(forKey: Key.channelCheckedAt)
        self.channelCheckedAt = chTs > 0 ? Date(timeIntervalSince1970: chTs) : nil

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

        self.pickCount = (defaults.dictionary(forKey: Key.picks) as? [String: String])?.count ?? 0

        let storedSub = defaults.double(forKey: Key.subScale)
        self.subScale = storedSub > 0.4 ? storedSub : 1.0
        let storedSeek = defaults.integer(forKey: Key.seekStep)
        self.seekStep = storedSeek > 0 ? storedSeek : 10
        self.holdBoost = defaults.object(forKey: Key.holdBoost) as? Bool ?? true
        self.sideGestures = defaults.object(forKey: Key.sideGestures) as? Bool ?? true
        self.rememberBrightness = defaults.object(forKey: Key.rememberBrightness) as? Bool ?? false
        self.savedBrightness = defaults.object(forKey: Key.savedBrightness) as? Double ?? -1
        self.aniskipEnabled = defaults.object(forKey: Key.aniskipEnabled) as? Bool ?? true
        self.normalizeAudio = defaults.object(forKey: Key.normalizeAudio) as? Bool ?? false

        let storedDlQ = defaults.integer(forKey: Key.downloadQuality)
        self.downloadQuality = storedDlQ > 0 ? min(storedDlQ, maxStreamHeight) : 720
        self.wifiOnlyDownloads = defaults.object(forKey: Key.wifiOnlyDownloads) as? Bool ?? false
        self.autoDeleteDownloaded = defaults.object(forKey: Key.autoDeleteDownloaded) as? Bool ?? false

        self.alertsEnabled = defaults.object(forKey: Key.alertsEnabled) as? Bool ?? false
        self.alertsMyStudio = defaults.object(forKey: Key.alertsMyStudio) as? Bool ?? false
        self.alertsPlanned = defaults.object(forKey: Key.alertsPlanned) as? Bool ?? false

        let checkedTs = defaults.double(forKey: Key.alertsCheckedAt)
        self.alertsCheckedAt = checkedTs > 0 ? Date(timeIntervalSince1970: checkedTs) : nil

        self.recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        self.onboarded = defaults.object(forKey: Key.onboarded) as? Bool ?? false

        if let data = defaults.data(forKey: Key.pendingWatches),
           let decoded = try? JSONDecoder().decode([PendingWatch].self, from: data) {
            self.pendingWatches = decoded
        } else {
            self.pendingWatches = []
        }
    }

    // MARK: - Profile & Multi-Account Stash

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

    /// Isolates per-account data (history, studio picks, alert watermarks, pending watch marks) across up to 4 accounts.
    @discardableResult
    func claimFor(userId: Int64) -> Bool {
        let me = String(userId)
        let before = defaults.string(forKey: Key.owner)
        if before == me { return false }
        defaults.set(me, forKey: Key.owner)
        guard let before else { return false }

        var stashes: [String: AccountStash] = {
            guard let data = defaults.data(forKey: Key.stash),
                  let decoded = try? decoder.decode([String: AccountStash].self, from: data) else { return [:] }
            return decoded
        }()

        stashes[before] = AccountStash(
            history: history,
            picks: allPicks(),
            alertsSeen: defaults.dictionary(forKey: Key.alertsSeen) as? [String: Int] ?? [:],
            alertsCheckedAt: alertsCheckedAt?.timeIntervalSince1970 ?? 0,
            channelCheckedAt: channelCheckedAt?.timeIntervalSince1970 ?? 0,
            pendingWatches: pendingWatches
        )

        if let mine = stashes.removeValue(forKey: me) {
            history = mine.history
            setAllPicks(mine.picks)
            defaults.set(mine.alertsSeen, forKey: Key.alertsSeen)
            alertsCheckedAt = mine.alertsCheckedAt > 0 ? Date(timeIntervalSince1970: mine.alertsCheckedAt) : nil
            channelCheckedAt = mine.channelCheckedAt > 0 ? Date(timeIntervalSince1970: mine.channelCheckedAt) : nil
            pendingWatches = mine.pendingWatches
        } else {
            history = []
            clearPicks()
            defaults.removeObject(forKey: Key.alertsSeen)
            alertsCheckedAt = nil
            channelCheckedAt = nil
            pendingWatches = []
        }

        // Keep at most 4 stashed accounts
        if stashes.count > 4 {
            let trimmedKeys = Array(stashes.keys.prefix(stashes.count - 4))
            for k in trimmedKeys { stashes.removeValue(forKey: k) }
        }
        if let data = try? encoder.encode(stashes) {
            defaults.set(data, forKey: Key.stash)
        }
        return true
    }

    // MARK: - Watch History & Pending Outbox

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

    func clearHistory() {
        history = []
    }

    func queuePendingWatch(seriesId: Int64, episodeNumber: Int, translationId: Int64) {
        let item = PendingWatch(seriesId: seriesId, episodeNumber: episodeNumber, translationId: translationId, queuedAt: Date())
        if !pendingWatches.contains(where: { $0.translationId == translationId }) {
            pendingWatches.append(item)
        }
    }

    func removePendingWatch(translationId: Int64) {
        pendingWatches.removeAll { $0.translationId == translationId }
    }

    // MARK: - Studio Picks & Favourites

    func allPicks() -> [String: String] {
        defaults.dictionary(forKey: Key.picks) as? [String: String] ?? [:]
    }

    func setAllPicks(_ map: [String: String]) {
        defaults.set(map, forKey: Key.picks)
        pickCount = map.count
    }

    func pick(animeId: Int64) -> String? {
        allPicks()[String(animeId)]
    }

    func setPick(animeId: Int64, key: String) {
        var map = allPicks()
        map[String(animeId)] = key
        setAllPicks(map)
    }

    func clearPicks() {
        defaults.removeObject(forKey: Key.picks)
        pickCount = 0
    }

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

    // MARK: - Recent Searches

    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        var copy = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        copy.insert(trimmed, at: 0)
        if copy.count > 8 { copy = Array(copy.prefix(8)) }
        recentSearches = copy
    }

    func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
    }

    func clearRecentSearches() {
        recentSearches = []
    }

    // MARK: - Alerts Watermarks

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
