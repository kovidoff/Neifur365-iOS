import XCTest
@testable import Neifur365

final class SitePagesTests: XCTestCase {
    func testSubtitlesPreserveASSStylesAndPositioning() throws {
        let script = """
        \u{FEFF}[Script Info]
        PlayResX: 1920
        PlayResY: 1080
        [V4+ Styles]
        Style: Sign,Manrope,54,&H0000FFFF
        [Events]
        Dialogue: 0,0:00:00.00,0:00:04.00,Sign,,0,0,0,,{\\pos(1420,160)}Надпись
        """
        let subtitles = try XCTUnwrap(EpisodeSubtitles(text: script))
        XCTAssertEqual(subtitles.fileExtension, "ass")
        XCTAssertEqual(subtitles.data, Data(script.utf8))
    }

    func testSubtitlesRecognizeWebVTTAndRejectHTML() {
        XCTAssertEqual(EpisodeSubtitles(text: "WEBVTT\n\n00:00.000 --> 00:01.000\nТекст")?.fileExtension, "vtt")
        XCTAssertNil(EpisodeSubtitles(text: "<html><title>403</title></html>"))
    }

    func testAvatarRequestsPreferActiveMirrorAfterOriginal() throws {
        let requests = Anime365Client.avatarRequests(
            urlString: "https://smotret-anime.org/avatars/42.jpg?v=7",
            activeMirror: "smotret-anime.co"
        )
        XCTAssertEqual(requests.prefix(2).compactMap { $0.url?.host }, ["smotret-anime.org", "smotret-anime.co"])
        let fallback = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertEqual(fallback.url?.absoluteString, "https://smotret-anime.co/avatars/42.jpg?v=7")
        XCTAssertTrue(requests.allSatisfy { !$0.httpShouldHandleCookies })
    }

    func testAvatarRequestsDoNotRewriteExternalHost() {
        let url = "https://images.example.org/profile.jpg"
        let requests = Anime365Client.avatarRequests(urlString: url, activeMirror: "smotret-anime.co")
        XCTAssertEqual(requests.compactMap { $0.url?.absoluteString }, [url])
    }

    func testProfileParsingWithActiveSubscription() {
        let html = """
        <html><body>
          <content>
            <div class="m-small-title">Kovidoff</div>
            <div class="card-image hide-on-small-and-down"><img src="/avatars/42.jpg" /></div>
            <p>ID аккаунта: 123456</p>
            <div><h2>Подписка</h2><p>Оплачена до 01.03.2027.</p></div>
          </content>
        </body></html>
        """
        let profile = SitePages.profile(html: html, base: "https://smotret-anime.app")
        XCTAssertEqual(profile?.id, 123456)
        XCTAssertEqual(profile?.name, "Kovidoff")
        XCTAssertEqual(profile?.avatarUrl, "https://smotret-anime.app/avatars/42.jpg")
        XCTAssertEqual(profile?.subscribed, true)
        XCTAssertEqual(profile?.subscribedUntil, "2027-03-01")
    }

    func testSubscriptionDateFormats() {
        XCTAssertEqual(SitePages.parseSubscriptionUntil("Оплачена до 5.09.2026"), "2026-09-05")
        XCTAssertEqual(SitePages.parseSubscriptionUntil("До 2027-11-23"), "2027-11-23")
        XCTAssertEqual(SitePages.parseSubscriptionUntil("Оплачена до 14 мая 2027"), "2027-05-14")
    }

    func testListParsing() {
        let html = """
        <div data-status="1">
          <table>
            <tr class="m-animelist-item" data-id="9001">
              <td><a href="/catalog/frieren-9001">Фрирен</a></td>
              <td data-name="episodes">12 / 28</td>
              <td data-name="score">10</td>
            </tr>
          </table>
        </div>
        <div data-status="0">
          <table>
            <tr class="m-animelist-item" data-id="9002">
              <td><a href="/catalog/dandadan-9002">Дандадан</a></td>
              <td data-name="episodes">0 / ?</td>
              <td data-name="score">-</td>
            </tr>
          </table>
        </div>
        """
        let entries = SitePages.list(html)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].seriesId, 9001)
        XCTAssertEqual(entries[0].status, .watching)
        XCTAssertEqual(entries[0].watched, 12)
        XCTAssertEqual(entries[0].total, 28)
        XCTAssertEqual(entries[0].score, 10)

        XCTAssertEqual(entries[1].seriesId, 9002)
        XCTAssertEqual(entries[1].status, .planned)
        XCTAssertNil(entries[1].total)
        XCTAssertNil(entries[1].score)
    }

    func testHrefIds() {
        XCTAssertEqual(SitePages.seriesId(from: "/catalog/sousou-no-frieren-54321?foo=1"), 54321)
        let pair = SitePages.ids(from: "https://smotret-anime.app/catalog/frieren-54321/1-seriya-998877#top")
        XCTAssertEqual(pair?.0, 54321)
        XCTAssertEqual(pair?.1, 998877)
    }

    func testTranslationPickerPrefersPickAndQuality() {
        let t720 = Translation(id: 1, authorsSummary: "AniLibria [ТВ]", type: "voiceRu", qualityType: "tv", height: 720, priority: 100)
        let t1080 = Translation(id: 2, authorsSummary: "AniLibria (BD)", type: "voiceRu", qualityType: "bd", height: 1080, priority: 90)
        let tOther = Translation(id: 3, authorsSummary: "SHIZA Project", type: "voiceRu", qualityType: "tv", height: 1080, priority: 200)

        let chosen1080 = TranslationPicker.choose(
            all: [t720, t1080, tOther],
            pick: t720.pickKey,
            preferred: .voiceRu,
            favourites: [],
            quality: 1080
        )
        XCTAssertEqual(chosen1080?.id, 2)

        let chosen720 = TranslationPicker.choose(
            all: [t720, t1080, tOther],
            pick: t720.pickKey,
            preferred: .voiceRu,
            favourites: [],
            quality: 720
        )
        XCTAssertEqual(chosen720?.id, 1)
    }

    func testChannelPageParse() {
        let html = """
        <script>var DIAG = {"currentChannel":2,"isRu":true,"targets":[{"id":1,"name":"Канал 1","desc":"(CDN Cloudflare)","url":"https://cf.example/test"},{"id":2,"name":"Канал 2","desc":"(РФ)","url":"https://rf.example/test"},{"id":99,"reference":true,"name":"Ref","desc":"","url":"https://ref.example"}]};</script>
        """
        let setup = ChannelPage.parse(html)
        XCTAssertEqual(setup?.current, 2)
        XCTAssertEqual(setup?.fromRussia, true)
        XCTAssertEqual(setup?.channels.count, 2)
        XCTAssertEqual(setup?.channels[0].label, "Cloudflare")
    }

    func testSeriesLossyDecoding() throws {
        let json = """
        {"id":"42","myAnimeListScore":"8.75","numberOfEpisodes":"24","year":"2024","isAiring":"1","titles":{"ru":"Тест"}}
        """
        let decoded = try JSONDecoder().decode(Series.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.score ?? 0, 8.75, accuracy: 0.001)
        XCTAssertEqual(decoded.numberOfEpisodes, 24)
        XCTAssertEqual(decoded.year, 2024)
        XCTAssertTrue(decoded.airing)
        XCTAssertEqual(decoded.title, "Тест")
    }
}
