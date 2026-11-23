import XCTest
@testable import Neifur365

final class ShikimoriScheduleTests: XCTestCase {
    func testCleanShikiDescriptionRemovesBBCodeAndSpoilers() {
        let raw = "[character=1]Фрирен[/character] — эльф из [[Отряд героя]]. [spoiler=Сюжет]Секрет[/spoiler]\r\n\r\n\r\n[i]Конец[/i]"
        let cleaned = cleanShikiDescription(raw)
        XCTAssertEqual(cleaned, "Фрирен — эльф из Отряд героя. \n\nКонец")
    }

    func testStudiosBuildAndCoverageRanges() {
        let eps = (1...6).map { Episode(id: Int64(100 + $0), episodeFull: "Серия \($0)", episodeInt: Double($0)) }
        let trs = [
            Translation(id: 1, authorsSummary: "AniLibria [ТВ]", type: "voiceRu", qualityType: "tv", height: 1080, priority: 100, episodeId: 101),
            Translation(id: 2, authorsSummary: "AniLibria (BD)", type: "voiceRu", qualityType: "bd", height: 1080, priority: 110, episodeId: 102),
            Translation(id: 3, authorsSummary: "AniLibria [ТВ]", type: "voiceRu", qualityType: "tv", height: 1080, priority: 100, episodeId: 103),
            Translation(id: 4, authorsSummary: "AniLibria [ТВ]", type: "voiceRu", qualityType: "tv", height: 1080, priority: 100, episodeId: 105),
            Translation(id: 5, authorsSummary: "AniLibria [ТВ]", type: "voiceRu", qualityType: "tv", height: 1080, priority: 100, episodeId: 106),
        ]
        let studios = Studios.build(trs)
        XCTAssertEqual(studios.count, 1)
        XCTAssertEqual(studios[0].author, "AniLibria")
        XCTAssertEqual(studios[0].qualityLabel, "1080p · BD")
        XCTAssertEqual(studios[0].coverage(in: eps), 5)
        XCTAssertEqual(Studios.coverageText(studio: studios[0], episodes: eps), "5 из 6 · нет 4")
        XCTAssertEqual(Studios.ranges([eps[0], eps[1], eps[2], eps[4], eps[5]]), "1–3, 5–6")
    }

    func testWeeklyScheduleGroupsAndSorts() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ScheduleBuilder.parseISO("2026-11-23T08:00:00Z")!

        let a1 = ShikiAnime(id: "500", russian: "Позже", episodes: 12, episodesAired: 5, nextEpisodeAt: "2026-11-23T18:00:00Z")
        let a2 = ShikiAnime(id: "501", russian: "Раньше", episodes: 24, episodesAired: 10, nextEpisodeAt: "2026-11-23T12:30:00Z")
        let a3 = ShikiAnime(id: "502", russian: "Завтра", episodes: 12, episodesAired: 1, nextEpisodeAt: "2026-11-24T15:00:00Z")

        let week = ScheduleBuilder.buildWeekly(animes: [a1, a2, a3], byMalId: [:], calendar: cal, today: now)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week[0].items.map(\.title), ["Раньше", "Позже"])
        XCTAssertEqual(week[0].items[0].nextEpisode, 11)
        XCTAssertEqual(week[1].items.map(\.title), ["Завтра"])
    }

    func testFormatRelativeAir() {
        let now = ScheduleBuilder.parseISO("2026-11-23T12:00:00Z")!
        let in2h = ScheduleBuilder.parseISO("2026-11-23T14:15:00Z")!
        let ago30m = ScheduleBuilder.parseISO("2026-11-23T11:30:00Z")!

        let future = ScheduleBuilder.formatRelativeAir(airAt: in2h, now: now)
        XCTAssertEqual(future.text, "через 2 ч 15 мин")
        XCTAssertFalse(future.aired)

        let past = ScheduleBuilder.formatRelativeAir(airAt: ago30m, now: now)
        XCTAssertEqual(past.text, "вышла 30 мин назад")
        XCTAssertTrue(past.aired)
    }

    func testGenresNonEmpty() {
        XCTAssertGreaterThan(A365Genre.all.count, 70)
    }
}
