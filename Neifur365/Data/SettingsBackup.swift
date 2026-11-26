import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Portable settings backup (strictly excludes session cookies, credentials, and profile data).
struct SettingsBackup: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()

    var quality: Int
    var preferredKind: String
    var favouriteStudios: [FavouriteStudio]
    var translationPicks: [String: String]

    var subScale: Double
    var seekStep: Int
    var holdBoost: Bool
    var sideGestures: Bool
    var rememberBrightness: Bool
    var aniskipEnabled: Bool
    var normalizeAudio: Bool

    var downloadQuality: Int
    var wifiOnlyDownloads: Bool
    var autoDeleteDownloaded: Bool

    var mirrorAuto: Bool
    var customMirrors: [String]
    var channelAuto: Bool

    var alertsEnabled: Bool
    var alertsMyStudio: Bool
    var alertsPlanned: Bool

    @MainActor
    static func exportJSON(from prefs: Prefs) throws -> Data {
        let backup = SettingsBackup(
            quality: prefs.quality,
            preferredKind: prefs.preferredKind.rawValue,
            favouriteStudios: prefs.favouriteStudios,
            translationPicks: prefs.allPicks(),
            subScale: prefs.subScale,
            seekStep: prefs.seekStep,
            holdBoost: prefs.holdBoost,
            sideGestures: prefs.sideGestures,
            rememberBrightness: prefs.rememberBrightness,
            aniskipEnabled: prefs.aniskipEnabled,
            normalizeAudio: prefs.normalizeAudio,
            downloadQuality: prefs.downloadQuality,
            wifiOnlyDownloads: prefs.wifiOnlyDownloads,
            autoDeleteDownloaded: prefs.autoDeleteDownloaded,
            mirrorAuto: prefs.mirrorAuto,
            customMirrors: prefs.customMirrors,
            channelAuto: prefs.channelAuto,
            alertsEnabled: prefs.alertsEnabled,
            alertsMyStudio: prefs.alertsMyStudio,
            alertsPlanned: prefs.alertsPlanned
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    @MainActor
    static func importJSON(_ data: Data, into prefs: Prefs) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(SettingsBackup.self, from: data)

        prefs.quality = min(max(backup.quality, 360), maxStreamHeight)
        if let kind = TranslationKind(rawValue: backup.preferredKind) {
            prefs.preferredKind = kind
        }
        prefs.favouriteStudios = Array(backup.favouriteStudios.prefix(30))
        prefs.setAllPicks(backup.translationPicks)

        prefs.subScale = min(max(backup.subScale, 0.7), 1.5)
        prefs.seekStep = [5, 10, 15, 30].contains(backup.seekStep) ? backup.seekStep : 10
        prefs.holdBoost = backup.holdBoost
        prefs.sideGestures = backup.sideGestures
        prefs.rememberBrightness = backup.rememberBrightness
        prefs.aniskipEnabled = backup.aniskipEnabled
        prefs.normalizeAudio = backup.normalizeAudio

        prefs.downloadQuality = min(max(backup.downloadQuality, 360), maxStreamHeight)
        prefs.wifiOnlyDownloads = backup.wifiOnlyDownloads
        prefs.autoDeleteDownloaded = backup.autoDeleteDownloaded

        prefs.mirrorAuto = backup.mirrorAuto
        prefs.customMirrors = backup.customMirrors
        prefs.channelAuto = backup.channelAuto

        prefs.alertsMyStudio = backup.alertsMyStudio
        prefs.alertsPlanned = backup.alertsPlanned
    }
}

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
