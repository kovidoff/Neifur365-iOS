import Foundation

/// Lightweight local preferences stored in `UserDefaults`.
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
        static let favouriteStudios = "nf_favourite_studios"
    }

    @Published var mirror: String? {
        didSet {
            if let mirror { defaults.set(mirror, forKey: Key.mirror) }
            else { defaults.removeObject(forKey: Key.mirror) }
        }
    }

    @Published var customMirrors: [String] {
        didSet { defaults.set(customMirrors, forKey: Key.customMirrors) }
    }

    @Published var mirrorAuto: Bool {
        didSet { defaults.set(mirrorAuto, forKey: Key.mirrorAuto) }
    }

    @Published var history: [WatchEntry] {
        didSet {
            if let data = try? encoder.encode(history) {
                defaults.set(data, forKey: Key.history)
            }
        }
    }

    @Published var quality: Int {
        didSet { defaults.set(min(quality, maxStreamHeight), forKey: Key.quality) }
    }

    @Published var preferredKind: TranslationKind {
        didSet { defaults.set(preferredKind.rawValue, forKey: Key.preferredKind) }
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

        if let rawKind = defaults.string(forKey: Key.preferredKind),
           let kind = TranslationKind(rawValue: rawKind) {
            self.preferredKind = kind
        } else {
            self.preferredKind = .voiceRu
        }
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

    func removeFromHistory(animeId: String) {
        history.removeAll { $0.animeId == animeId }
    }

    func pick(animeId: String) -> String? {
        let map = defaults.dictionary(forKey: Key.picks) as? [String: String] ?? [:]
        return map[animeId]
    }

    func setPick(animeId: String, key: String) {
        var map = defaults.dictionary(forKey: Key.picks) as? [String: String] ?? [:]
        map[animeId] = key
        defaults.set(map, forKey: Key.picks)
    }
}
