import Foundation

enum MirrorHealth: Equatable {
    case ok, slow, blocked, down
}

enum MirrorOrigin: Equatable {
    case builtin, custom
}

struct MirrorStatus: Identifiable, Equatable {
    let host: String
    let health: MirrorHealth
    let millis: Int
    var active: Bool = false
    var origin: MirrorOrigin = .builtin

    var id: String { host }
    var ok: Bool { health == .ok || health == .slow }
}

private final class MirrorCookieDelegate: NSObject, URLSessionTaskDelegate {
    private let cookies: SessionCookies
    private let isSiteHost: (String?) -> Bool
    private let userAgent: String

    init(cookies: SessionCookies, userAgent: String, isSiteHost: @escaping (String?) -> Bool) {
        self.cookies = cookies
        self.userAgent = userAgent
        self.isSiteHost = isSiteHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let respURL = response.url, isSiteHost(respURL.host) {
            cookies.save(from: response, url: respURL)
        }
        var next = request
        next.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let nextHost = next.url?.host, isSiteHost(nextHost) {
            let hdr = cookies.header()
            if !hdr.isEmpty {
                next.setValue(hdr, forHTTPHeaderField: "Cookie")
            }
        }
        completionHandler(next)
    }
}

final class Anime365Client {
    static let builtinMirrors = [
        "smotret-anime.app",
        "smotret-anime.co",
        "smotretanime.co",
        "smotret-anime.com",
        "smotret-anime.org"
    ]

    static let cardFields = "id,myAnimeListId,myAnimeListScore,numberOfEpisodes,season,year,type,typeTitle,isAiring,titles,posterUrl,posterUrlSmall,genres"

    /// Standard Mobile Safari UA matching WKWebView on iOS so site-adopted sessions look identical.
    let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let cookies = SessionCookies()
    private let prefs: Prefs
    private let decoder = JSONDecoder()

    private lazy var delegate = MirrorCookieDelegate(cookies: cookies, userAgent: userAgent) { [weak self] host in
        self?.isSiteHost(host) ?? false
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 40
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }()

    private lazy var probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 9
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private let cacheLock = NSLock()
    private var seriesCache: [Int64: (Date, Series)] = [:]
    private var resolveTask: Task<String, Error>?
    private let resolveLock = NSLock()

    var onSessionLost: (() -> Void)?

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    func isSiteHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let custom = prefs.customMirrors.map { $0.lowercased() }
        if custom.contains(host) { return true }
        return Self.builtinMirrors.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    // MARK: - Mirrors

    func mirrorList() -> [(String, MirrorOrigin)] {
        let custom = prefs.customMirrors.filter { !Self.builtinMirrors.contains($0) }
        return Self.builtinMirrors.map { ($0, .builtin) } + custom.map { ($0, .custom) }
    }

    func probe(host: String, origin: MirrorOrigin = .builtin) async -> MirrorStatus {
        let start = CFAbsoluteTimeGetCurrent()
        guard let url = URL(string: "https://\(host)/api/series?limit=1&fields=id") else {
            return MirrorStatus(host: host, health: .down, millis: 0, origin: origin)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await probeSession.data(for: req)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            let health: MirrorHealth
            if body.contains("Just a moment") || body.contains("cf-chl") {
                health = .blocked
            } else if (200...299).contains(code) && body.hasPrefix("{\"data\"") {
                health = ms > 2500 ? .slow : .ok
            } else {
                health = .down
            }
            return MirrorStatus(host: host, health: health, millis: ms, origin: origin)
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return MirrorStatus(host: host, health: .down, millis: ms, origin: origin)
        }
    }

    func probeAll() async -> [MirrorStatus] {
        let current = await MainActor.run { prefs.mirror }
        let mirrors = mirrorList()
        return await withTaskGroup(of: (Int, MirrorStatus).self) { group in
            for (idx, item) in mirrors.enumerated() {
                group.addTask {
                    var status = await self.probe(host: item.0, origin: item.1)
                    status.active = (status.host == current)
                    return (idx, status)
                }
            }
            var results = [(Int, MirrorStatus)]()
            for await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func host() async throws -> String {
        if let saved = await MainActor.run(body: { prefs.mirror }), !saved.isEmpty {
            return saved
        }
        return try await resolveMirror()
    }

    func baseUrl() async throws -> String {
        "https://\(try await host())"
    }

    func resolveMirror(exclude: String? = nil) async throws -> String {
        if let saved = await MainActor.run(body: { prefs.mirror }), !saved.isEmpty, saved != exclude {
            return saved
        }

        let task: Task<String, Error> = resolveLock.withLock {
            if let existing = resolveTask, exclude == nil {
                return existing
            }
            let created = Task<String, Error> {
                defer {
                    self.resolveLock.withLock {
                        self.resolveTask = nil
                    }
                }
                let statuses = await self.probeAll()
                let live = statuses.filter { $0.ok && $0.host != exclude }
                let saved = await MainActor.run { self.prefs.mirror }
                let manual = await MainActor.run { !self.prefs.mirrorAuto }

                let pick = live.first(where: { manual && $0.host == saved })
                    ?? live.filter({ $0.health == .ok }).min(by: { $0.millis < $1.millis })
                    ?? live.min(by: { $0.millis < $1.millis })

                guard let chosen = pick else {
                    throw ApiError("Не удалось связаться с Anime 365. Проверьте интернет или VPN")
                }
                await MainActor.run { self.prefs.mirror = chosen.host }
                return chosen.host
            }
            resolveTask = created
            return created
        }

        return try await task.value
    }

    @MainActor
    func pickMirror(_ host: String) {
        prefs.mirrorAuto = false
        prefs.mirror = host
    }

    @MainActor
    func enableAutoMirror() {
        prefs.mirrorAuto = true
        prefs.mirror = nil
    }

    @MainActor
    func addCustomMirror(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init)?
            .lowercased() ?? ""
        guard !cleaned.isEmpty, cleaned.contains(".") else { return nil }
        if !Self.builtinMirrors.contains(cleaned) && !prefs.customMirrors.contains(cleaned) {
            prefs.customMirrors.append(cleaned)
        }
        return cleaned
    }

    @MainActor
    func removeCustomMirror(_ host: String) {
        prefs.customMirrors.removeAll { $0 == host }
        if prefs.mirror == host { prefs.mirror = nil }
    }

    private func mirrored<T>(_ block: (String) async throws -> T) async throws -> T {
        let first = try await host()
        do {
            return try await block("https://\(first)")
        } catch {
            let mirrorDown: Bool
            if let http = error as? HttpError {
                mirrorDown = http.code >= 500
            } else if error is URLError {
                mirrorDown = true
            } else {
                mirrorDown = false
            }
            guard mirrorDown else { throw error }

            if let retry = try? await block("https://\(first)") {
                return retry
            }
            let next = try await resolveMirror(exclude: first)
            return try await block("https://\(next)")
        }
    }

    // MARK: - Transport

    private func makeRequest(url: URL, method: String = "GET", acceptJSON: Bool = false) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if acceptJSON {
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if isSiteHost(url.host) {
            let hdr = cookies.header()
            if !hdr.isEmpty {
                req.setValue(hdr, forHTTPHeaderField: "Cookie")
            }
        }
        return req
    }

    private func fetchText(_ req: URLRequest) async throws -> String {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ApiError("Некорректный ответ сервера")
        }
        if let url = http.url, isSiteHost(url.host) {
            cookies.save(from: http, url: url)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if !(200...299).contains(http.statusCode) && http.statusCode != 403 {
            throw HttpError(code: http.statusCode, bodySnippet: String(body.prefix(300)))
        }
        return body
    }

    private func api<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await mirrored { base in
            guard let url = URL(string: "\(base)/api\(path)") else {
                throw ApiError("Некорректный адрес запроса")
            }
            let raw = try await fetchText(makeRequest(url: url, acceptJSON: true))
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ApiError("Anime 365 ответил что-то непонятное")
            }
            if let err = obj["error"] as? [String: Any] {
                let code = err["code"] as? Int ?? 0
                let msg = err["message"] as? String ?? ""
                if code == 403 && msg.localizedCaseInsensitiveContains("login") {
                    throw triggerSessionLost()
                }
                if msg.localizedCaseInsensitiveContains("subscription") {
                    throw SubscriptionRequiredError()
                }
                if code == 404 {
                    throw ApiError("Не найдено на Anime 365")
                }
                throw ApiError(msg.isEmpty ? "Ошибка Anime 365 (\(code))" : msg)
            }
            guard let payload = obj["data"] else {
                throw ApiError("Пустой ответ Anime 365")
            }
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            return try decoder.decode(T.self, from: payloadData)
        }
    }

    private func page(_ path: String) async throws -> String {
        try await mirrored { base in
            guard let url = URL(string: base + path) else {
                throw ApiError("Некорректный адрес страницы")
            }
            return try await fetchText(makeRequest(url: url))
        }
    }

    private func post(_ path: String, form: [String: String]) async throws -> String {
        try await mirrored { base in
            func send() async throws -> String {
                if cookies["csrf"] == nil, let loginUrl = URL(string: "\(base)/users/login") {
                    _ = try await fetchText(makeRequest(url: loginUrl))
                }
                guard let rawCsrf = cookies["csrf"] else {
                    throw ApiError("Anime 365 не выдал ключ формы, попробуйте вход через сайт")
                }
                let csrf = rawCsrf.removingPercentEncoding ?? rawCsrf
                var fullForm = form
                fullForm["csrf"] = csrf

                guard let url = URL(string: base + path) else {
                    throw ApiError("Некорректный адрес формы")
                }
                var req = makeRequest(url: url, method: "POST")
                req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                req.httpBody = formEncode(fullForm).data(using: .utf8)
                return try await fetchText(req)
            }

            do {
                return try await send()
            } catch let err as HttpError where err.code == 400 {
                cookies["csrf"] = nil
                return try await send()
            }
        }
    }

    private func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private func queryEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Catalog

    func catalog(
        query: String = "",
        offset: Int = 0,
        limit: Int = 30,
        type: String? = nil,
        airing: Bool = false,
        year: Int? = nil,
        genre: Int? = nil
    ) async throws -> [Series] {
        var parts = [
            "fields=\(Self.cardFields)",
            "limit=\(limit)",
            "offset=\(offset)"
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append("query=\(queryEncode(trimmed))")
        }
        if let type { parts.append("type=\(type)") }
        if airing { parts.append("isAiring=1") }
        if let year { parts.append("year=\(year)") }
        if let genre { parts.append("chips=\(queryEncode("genre=\(genre)"))") }

        return try await api("/series?\(parts.joined(separator: "&"))", as: [Series].self)
    }

    func series(id: Int64, force: Bool = false) async throws -> Series {
        if !force {
            let hit = cacheLock.withLock { seriesCache[id] }
            if let hit, Date().timeIntervalSince(hit.0) < 300 {
                return hit.1
            }
        }
        let fetched = try await api("/series/\(id)", as: Series.self)
        cacheLock.withLock {
            seriesCache[id] = (Date(), fetched)
        }
        return fetched
    }

    func cards(ids: [Int64]) async throws -> [Series] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        let chunks = stride(from: 0, to: unique.count, by: 40).map {
            Array(unique[$0..<min($0 + 40, unique.count)])
        }
        return try await withThrowingTaskGroup(of: [Series].self) { group in
            for chunk in chunks {
                group.addTask {
                    let idParams = chunk.map { "id[]=\($0)" }.joined(separator: "&")
                    return try await self.api("/series?fields=\(Self.cardFields)&limit=\(chunk.count)&\(idParams)", as: [Series].self)
                }
            }
            var out: [Series] = []
            for try await batch in group { out.append(contentsOf: batch) }
            return out
        }
    }

    func byMyAnimeList(_ malId: Int64) async throws -> Series? {
        let list = try await api("/series?myAnimeListId=\(malId)&fields=\(Self.cardFields)&limit=1", as: [Series].self)
        return list.first
    }

    func translations(episodeIds: [Int64]) async throws -> [Translation] {
        let unique = Array(Set(episodeIds))
        guard !unique.isEmpty else { return [] }
        let fields = "id,episodeId,type,typeKind,typeLang,authorsSummary,height,priority,isActive,qualityType"
        let chunks = stride(from: 0, to: unique.count, by: 20).map {
            Array(unique[$0..<min($0 + 20, unique.count)])
        }
        var all: [Translation] = []
        for batchStart in stride(from: 0, to: chunks.count, by: 3) {
            let batch = chunks[batchStart..<min(batchStart + 3, chunks.count)]
            let batchResult = try await withThrowingTaskGroup(of: [Translation].self) { group in
                for chunk in batch {
                    group.addTask {
                        let idParams = chunk.map { "episodeId[]=\($0)" }.joined(separator: "&")
                        var out: [Translation] = []
                        var offset = 0
                        while true {
                            let page = try await self.api(
                                "/translations?limit=1000&offset=\(offset)&fields=\(fields)&\(idParams)",
                                as: [Translation].self
                            )
                            out.append(contentsOf: page)
                            if page.count < 1000 { break }
                            offset += page.count
                        }
                        return out
                    }
                }
                var combined: [Translation] = []
                for try await items in group { combined.append(contentsOf: items) }
                return combined
            }
            all.append(contentsOf: batchResult)
        }
        return all
    }

    func episode(id: Int64) async throws -> Episode {
        try await api("/episodes/\(id)", as: Episode.self)
    }

    func embed(translationId: Int64) async throws -> Embed {
        try await api("/translations/embed/\(translationId)", as: Embed.self)
    }

    func subtitles(url: String) async throws -> String {
        try await mirrored { base in
            let resolved = SitePages.resolve(base: base, url: url)
            guard let target = URL(string: resolved) else {
                throw ApiError("Некорректная ссылка на субтитры")
            }
            return try await fetchText(makeRequest(url: target))
        }
    }

    // MARK: - Account & Lists

    func login(email: String, password: String) async throws -> Profile {
        let html = try await post("/users/login", form: [
            "LoginForm[username]": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "LoginForm[password]": password,
            "dynpage": "1",
            "yt0": ""
        ])
        if SitePages.loginFailed(html) {
            throw InvalidCredentialsError()
        }
        guard let profile = try await profile() else {
            throw ApiError("Не получилось войти. Попробуйте вход через сайт")
        }
        return profile
    }

    func profile() async throws -> Profile? {
        guard !cookies.isEmpty else { return nil }
        return try await mirrored { base in
            guard let url = URL(string: "\(base)/users/profile?dynpage=1") else { return nil }
            let html = try await fetchText(makeRequest(url: url))
            return SitePages.profile(html: html, base: base)
        }
    }

    func logout() {
        cookies.clear()
    }

    private func triggerSessionLost() -> SignInRequiredError {
        if !cookies.isEmpty {
            onSessionLost?()
        }
        return SignInRequiredError()
    }

    func allLists(userId: Int64) async throws -> [ListEntry] {
        let html = try await page("/users/\(userId)/list?dynpage=1")
        if SitePages.isSignedOut(html) { throw triggerSessionLost() }
        return SitePages.list(html)
    }

    func listRecord(seriesId: Int64) async throws -> ListRecord {
        let html = try await page("/animelist/edit/\(seriesId)?mode=mini")
        if SitePages.isSignedOut(html) { throw triggerSessionLost() }
        return SitePages.listRecord(html)
    }

    func setListRecord(seriesId: Int64, status: ListStatus?, watched: Int, score: Int?) async throws {
        _ = try await post("/animelist/edit/\(seriesId)?mode=mini", form: [
            "UsersRates[score]": String(score ?? 0),
            "UsersRates[episodes]": String(watched),
            "UsersRates[status]": String(status?.rawValue ?? 99),
            "UsersRates[comment]": ""
        ])
    }

    func markWatched(translationId: Int64) async throws {
        _ = try await post("/translations/watched/\(translationId)", form: [:])
    }

    // MARK: - Video Channels

    func channels() async throws -> ChannelSetup {
        let html = try await page("/diagnostic")
        guard let setup = ChannelPage.parse(html) else {
            throw ApiError("Не получилось узнать каналы Anime 365")
        }
        return setup
    }

    func setChannel(id: Int) async throws {
        let raw = try await post("/diagnostic/setChannel", form: ["channel": String(id)])
        let ok: Bool = {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            if let b = obj["ok"] as? Bool { return b }
            if let s = obj["ok"] as? String { return s == "true" }
            return false
        }()
        if !ok {
            throw ApiError("Anime 365 не переключил канал")
        }
    }

    /// Measures download throughput of a video channel using a 2 MB ranged probe.
    func measure(channel: VideoChannel, maxBytes: Int64 = 2_097_152) async -> ChannelSpeed {
        func measureUrl(_ rawUrl: String) async -> Double {
            let sep = rawUrl.contains("?") ? "&" : "?"
            let busted = "\(rawUrl)\(sep)_=\(Int(Date().timeIntervalSince1970 * 1000))"
            guard let url = URL(string: busted) else { return 0 }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 7

            let start = CFAbsoluteTimeGetCurrent()
            do {
                let (data, resp) = try await probeSession.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code) else { return 0 }
                let elapsed = max(CFAbsoluteTimeGetCurrent() - start, 0.05)
                return Double(data.count) / elapsed
            } catch {
                return 0
            }
        }

        let primary = await measureUrl(channel.testUrl)
        if primary < ChannelSpeed.worksThreshold, let fallback = channel.fallbackUrl {
            let fb = await measureUrl(fallback)
            return ChannelSpeed(bytesPerSec: max(primary, fb))
        }
        return ChannelSpeed(bytesPerSec: primary)
    }
}
