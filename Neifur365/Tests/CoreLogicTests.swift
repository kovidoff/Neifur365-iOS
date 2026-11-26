import XCTest
@testable import Neifur365

final class CoreLogicTests: XCTestCase {
    func testAniSkipParsesValidOpeningAndEndingAndFiltersWrongLength() throws {
        let json = """
        {
          "found": true,
          "results": [
            { "interval": { "startTime": 84.5, "endTime": 174.5 }, "skipType": "op", "episodeLength": 1420.0 },
            { "interval": { "startTime": 1290.0, "endTime": 1380.0 }, "skipType": "ed", "episodeLength": 1420.0 },
            { "interval": { "startTime": 10.0, "endTime": 90.0 }, "skipType": "mixed-op", "episodeLength": 900.0 }
          ]
        }
        """.data(using: .utf8)!

        let segments = AniSkipParser.parseAndFilterSkipTimes(data: json, videoDuration: 1421.0)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].kind, .opening)
        XCTAssertEqual(segments[0].start, 84.5, accuracy: 0.01)
        XCTAssertEqual(segments[0].end, 174.5, accuracy: 0.01)
        XCTAssertEqual(segments[1].kind, .ending)
    }

    func testTrackNamesDescribesJapaneseAndSigns() {
        let ja = MpvTrack(
            id: 1,
            type: "audio",
            lang: "jpn",
            title: "Original [FLAC]",
            codec: "flac",
            isForced: false,
            isExternal: false,
            isSelected: true
        )
        XCTAssertEqual(ja.info.name, "Японский")

        let signs = MpvTrack(
            id: 2,
            type: "sub",
            lang: "rus",
            title: "Надписи (ASS)",
            codec: "ass",
            isForced: true,
            isExternal: true,
            isSelected: false
        )
        XCTAssertEqual(signs.info.kind, .signs)
        XCTAssertEqual(signs.info.name, "Русский")
    }

    func testPickBetterChannelLeavesBrokenChannel() {
        let broken = VideoChannel(id: 1, name: "cdn1", desc: "CDN 1", testUrl: "", fallbackUrl: nil)
        let fast = VideoChannel(id: 2, name: "cdn2", desc: "CDN 2", testUrl: "", fallbackUrl: nil)

        let pick = pickBetterChannel(
            currentId: broken.id,
            currentSpeed: ChannelSpeed(bytesPerSec: 100 * 1024),
            best: fast,
            bestSpeed: ChannelSpeed(bytesPerSec: 4 * 1024 * 1024),
            preferSwitch: false
        )
        XCTAssertEqual(pick?.id, fast.id)

        let keepWorking = pickBetterChannel(
            currentId: broken.id,
            currentSpeed: ChannelSpeed(bytesPerSec: 2 * 1024 * 1024),
            best: fast,
            bestSpeed: ChannelSpeed(bytesPerSec: 2.2 * 1024 * 1024),
            preferSwitch: true
        )
        XCTAssertNil(keepWorking)
    }

    func testComputeWatchStatsAggregatesEpisodesTimeAndGenres() {
        let s1 = Series(
            id: 1,
            type: "tv",
            titles: Titles(ru: "TV Show"),
            genres: [SeriesGenre(id: 1, title: "Экшен"), SeriesGenre(id: 2, title: "Драма")]
        )
        let s2 = Series(
            id: 2,
            type: "movie",
            titles: Titles(ru: "Movie"),
            genres: [SeriesGenre(id: 1, title: "Экшен")]
        )
        let items = [
            ListedTitle(entry: ListEntry(seriesId: 1, title: "TV Show", watched: 10, total: 12, score: 9, status: .watching), series: s1, aired: 12),
            ListedTitle(entry: ListEntry(seriesId: 2, title: "Movie", watched: 1, total: 1, score: 7, status: .completed), series: s2, aired: 1)
        ]

        let stats = computeWatchStats(items: items)
        XCTAssertEqual(stats.totalTitles, 2)
        XCTAssertEqual(stats.episodesWatched, 11)
        XCTAssertEqual(stats.totalMinutes, 10 * 24 + 95)
        XCTAssertEqual(stats.meanScore ?? 0, 8.0, accuracy: 0.01)
        XCTAssertEqual(stats.topGenres.first?.name, "Экшен")
        XCTAssertEqual(stats.topGenres.first?.count, 2)
        XCTAssertEqual(formatWatchTime(minutes: 150), "2 ч 30 мин")
    }

    @MainActor
    func testSettingsBackupRoundTrip() throws {
        let suiteName = "app.neifur365.tests.backup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let src = Prefs(defaults: defaults)
        src.quality = 720
        src.seekStep = 15
        src.aniskipEnabled = false
        src.normalizeAudio = true
        src.wifiOnlyDownloads = true
        src.toggleFavouriteStudio(key: "anilibria", name: "AniLibria")
        src.setPick(animeId: 42, key: "anilibria")

        let data = try SettingsBackup.exportJSON(from: src)

        let dstSuite = "app.neifur365.tests.backup.dst.\(UUID().uuidString)"
        let dstDefaults = UserDefaults(suiteName: dstSuite)!
        defer { dstDefaults.removePersistentDomain(forName: dstSuite) }

        let dst = Prefs(defaults: dstDefaults)
        try SettingsBackup.importJSON(data, into: dst)

        XCTAssertEqual(dst.quality, 720)
        XCTAssertEqual(dst.seekStep, 15)
        XCTAssertFalse(dst.aniskipEnabled)
        XCTAssertTrue(dst.normalizeAudio)
        XCTAssertTrue(dst.wifiOnlyDownloads)
        XCTAssertTrue(dst.isFavouriteStudio("anilibria"))
        XCTAssertEqual(dst.pick(animeId: 42), "anilibria")
    }
}
