import Charts
import SwiftUI

struct AnimeRoute: Hashable {
    let id: Int64?
    let malId: Int64?
    let title: String
    let posterUrl: String?
    let series: Series?

    init(id: Int64?, malId: Int64? = nil, title: String, posterUrl: String?, series: Series? = nil) {
        self.id = id
        self.malId = malId
        self.title = title
        self.posterUrl = posterUrl
        self.series = series
    }

    init(series: Series) {
        self.id = series.id
        self.malId = series.myAnimeListId > 0 ? series.myAnimeListId : nil
        self.title = series.title
        self.posterUrl = series.bestPosterUrl
        self.series = series
    }

    init(listed: ListedTitle) {
        self.id = listed.entry.seriesId
        self.malId = listed.series.flatMap { $0.myAnimeListId > 0 ? $0.myAnimeListId : nil }
        self.title = listed.displayTitle
        self.posterUrl = listed.posterUrl
        self.series = listed.series
    }
}

private struct HeroTitleMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AnimePreviewScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var downloads: DownloadManager

    let route: AnimeRoute

    @State private var resolvedSeriesId: Int64?
    @State private var fullSeries: Series?
    @State private var shiki: ShikiAnime?
    @State private var cast: ShikiCast?
    @State private var franchiseItems: [ShikiRelatedRef] = []
    @State private var groupedStudios: [(TranslationKind, [Studio])] = []
    @State private var selectedStudio: Studio?
    @State private var loading = false
    @State private var loadingStudios = false
    @State private var errorMessage: String?

    @State private var showNavTitle = false
    @State private var showListEditor = false
    @State private var showSignIn = false
    @State private var showAllEpisodes = false
    @State private var showStudioPicker = false
    @State private var expandDescription = false
    @State private var playerRequest: PlayerLaunchRequest?
    @State private var episodeToPlay: Episode?
    @State private var viewerScreenshotIndex: Int?
    @State private var toastMessage: String?

    private var activeSeriesId: Int64? { resolvedSeriesId ?? route.id }
    private var activeMalId: Int64 { fullSeries?.myAnimeListId ?? route.malId ?? 0 }
    private var currentSeries: Series? { fullSeries ?? route.series }
    private var listed: ListedTitle? { activeSeriesId.flatMap { lists.get($0) } }
    private var episodes: [Episode] { fullSeries?.playable ?? [] }
    private var watchedCount: Int { listed?.entry.watched ?? 0 }

    private var nextEpisodeIndex: Int? {
        guard !episodes.isEmpty else { return nil }
        var finishedThrough = watchedCount
        if let sid = activeSeriesId {
            let sidStr = String(sid)
            if let last = prefs.history.first(where: { $0.animeId == sidStr }) {
                if !last.finished, let idx = episodes.firstIndex(where: { $0.number == last.episode }) {
                    return idx
                }
                if last.finished {
                    finishedThrough = max(finishedThrough, last.episode)
                }
            }
        }
        if finishedThrough == 0 { return 0 }
        return episodes.firstIndex(where: { $0.number > finishedThrough })
    }

    private var nextEpisode: Episode? {
        guard let nextEpisodeIndex, episodes.indices.contains(nextEpisodeIndex) else { return nil }
        return episodes[nextEpisodeIndex]
    }

    private var bestDescription: String? {
        let a365Desc = currentSeries?.descriptionText ?? ""
        let shikiDesc = cleanShikiDescription(shiki?.description)
        if shikiDesc.count > a365Desc.count { return shikiDesc }
        return a365Desc.isEmpty ? (shikiDesc.isEmpty ? nil : shikiDesc) : a365Desc
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroHeader

                VStack(alignment: .leading, spacing: 14) {
                    if let nextAir = nextEpisodeAirInfo {
                        nextAirBanner(nextAir)
                    }
                    actionsBlock
                    if !episodes.isEmpty {
                        studioSelectorCard
                    }
                }
                .padding(.horizontal, 16)

                if let genres = currentSeries?.genres, !genres.isEmpty {
                    genresRow(genres)
                }

                VStack(alignment: .leading, spacing: 20) {
                    if let desc = bestDescription {
                        descriptionBlock(desc)
                    }
                    if let shiki, hasFacts(shiki) {
                        factsBlock(shiki)
                    }
                    if let stats = shiki?.scoresStats?.filter({ $0.count > 0 }), !stats.isEmpty {
                        scoresDistributionBlock(stats)
                    }
                    episodesBlock
                }
                .padding(.horizontal, 16)

                if !franchiseItems.isEmpty {
                    franchiseRow(franchiseItems)
                }

                if let shots = shiki?.screenshots, !shots.isEmpty {
                    screenshotsRow(shots)
                }

                if let chars = cast?.characters, !chars.isEmpty {
                    charactersRow(chars)
                }

                if let videos = shiki?.videos?.filter({ $0.url != nil }), !videos.isEmpty {
                    trailersRow(videos)
                }

                if let related = shiki?.related?.filter({ $0.anime != nil }), !related.isEmpty {
                    relatedRow(related)
                }
            }
            .padding(.bottom, 44)
        }
        .coordinateSpace(name: "previewScroll")
        .onPreferenceChange(HeroTitleMinYKey.self) { y in
            let next = y < 24
            if next != showNavTitle {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showNavTitle = next
                }
            }
        }
        .background(Nf.ink.ignoresSafeArea())
        .navigationTitle(showNavTitle ? (currentSeries?.title ?? route.title) : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let sid = activeSeriesId,
               let shareUrl = URL(string: "https://\(prefs.mirror ?? "smotret-anime.com")/catalog/\(sid)") {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: shareUrl) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Поделиться")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if account.isSignedIn {
                        showListEditor = true
                    } else {
                        showSignIn = true
                    }
                } label: {
                    Image(systemName: listed?.status?.systemImage ?? "bookmark")
                        .foregroundColor(listed?.status?.tintColor ?? Nf.text)
                }
                .accessibilityLabel("Список")
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Nf.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .nfGlassCapsule()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await loadAll()
        }
        .refreshable {
            await loadAll(force: true)
        }
        .fullScreenCover(item: $playerRequest) { req in
            PlayerScreen(request: req, app: app)
        }
        .sheet(isPresented: $showListEditor) {
            if let sid = activeSeriesId {
                ListEditorSheet(
                    seriesId: sid,
                    title: currentSeries?.title ?? route.title,
                    series: currentSeries,
                    current: listed
                )
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInSheet()
        }
        .sheet(isPresented: $showStudioPicker) {
            DetailStudioPickerSheet(
                groupedStudios: groupedStudios,
                episodes: episodes,
                selectedStudio: selectedStudio
            ) { studio in
                selectedStudio = studio
                if let sid = activeSeriesId {
                    prefs.setPick(animeId: sid, key: studio.key)
                }
            }
        }
        .sheet(isPresented: $showAllEpisodes, onDismiss: {
            if let episodeToPlay {
                self.episodeToPlay = nil
                launchPlayer(episode: episodeToPlay)
            }
        }) {
            AllEpisodesSheet(
                title: currentSeries?.title ?? route.title,
                episodes: episodes,
                watchedCount: watchedCount,
                nextEpisodeId: nextEpisode?.id,
                downloads: downloads,
                onPlay: { ep in
                    episodeToPlay = ep
                    showAllEpisodes = false
                },
                onDownload: { ep in
                    queueSingleDownload(ep)
                }
            )
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewerScreenshotIndex != nil },
            set: { if !$0 { viewerScreenshotIndex = nil } }
        )) {
            if let idx = viewerScreenshotIndex, let shots = shiki?.screenshots {
                let urls = shots.compactMap(\.full)
                if !urls.isEmpty {
                    ScreenshotViewer(urls: urls, initialIndex: idx) {
                        viewerScreenshotIndex = nil
                    }
                }
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 16) {
            PosterView(
                urlString: currentSeries?.bestPosterUrl ?? route.posterUrl, cornerRadius: 18,
                alignment: .top, contentMode: .fill
            )
            .frame(width: 152, height: 228)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.55), radius: 22, y: 12)

            VStack(spacing: 6) {
                Text(currentSeries?.title ?? route.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(Nf.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: HeroTitleMinYKey.self,
                                value: geo.frame(in: .named("previewScroll")).maxY
                            )
                        }
                    }

                if let orig = currentSeries?.original {
                    Text(orig)
                        .font(.footnote)
                        .foregroundColor(Nf.textMute)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                metaLine
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            PosterView(urlString: currentSeries?.bestPosterUrl ?? route.posterUrl, cornerRadius: 0, alignment: .top)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .blur(radius: 34)
                .opacity(0.45)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: Nf.ink.opacity(0.2), location: 0.0),
                            .init(color: Nf.ink.opacity(0.45), location: 0.45),
                            .init(color: Nf.ink.opacity(0.92), location: 0.82),
                            .init(color: Nf.ink, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if let score = currentSeries?.score ?? shiki?.score, score > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Nf.amber)
                    Text(String(format: "%.2f", score))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Nf.text)
                        .monospacedDigit()
                }
            }

            if let y = currentSeries?.year, y > 0 {
                Text("·").foregroundColor(Nf.textMute)
                Text(String(y))
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
            }

            if let t = currentSeries?.typeTitle, !t.isEmpty {
                Text("·").foregroundColor(Nf.textMute)
                Text(t)
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
            }

            if let epInfo = episodesSummary {
                Text("·").foregroundColor(Nf.textMute)
                Text(epInfo)
                    .font(.subheadline.weight(currentSeries?.airing == true ? .semibold : .regular))
                    .foregroundColor(currentSeries?.airing == true ? Nf.mint : Nf.textDim)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var episodesSummary: String? {
        guard let s = currentSeries else { return nil }
        let aired = s.playable.count
        if s.airing {
            if aired > 0 && s.numberOfEpisodes > 0 { return "\(aired)/\(s.numberOfEpisodes) эп." }
            if aired > 0 { return "\(aired) эп." }
            return "Онгоинг"
        }
        if s.isMovie { return "Фильм" }
        if s.numberOfEpisodes > 0 { return "\(s.numberOfEpisodes) эп." }
        return nil
    }

    // MARK: - Next Episode Banner

    private var nextEpisodeAirInfo: (number: Int, dateText: String, relText: String)? {
        guard currentSeries?.airing == true,
              let iso = shiki?.nextEpisodeAt,
              let date = ScheduleBuilder.parseISO(iso),
              date > Date().addingTimeInterval(-3600) else { return nil }
        let nextNum = max((shiki?.episodesAired ?? episodes.count) + 1, episodes.count + 1)
        let rel = ScheduleBuilder.formatRelativeAir(airAt: date)
        return (nextNum, Self.nextAirFormatter.string(from: date), rel.text)
    }

    private static let nextAirFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = "d MMM, HH:mm"
        return fmt
    }()

    private func nextAirBanner(_ info: (number: Int, dateText: String, relText: String)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundColor(Nf.mint)
                .font(.system(size: 16, weight: .semibold))
            Text("Серия \(info.number) · \(info.dateText)")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Nf.text)
            Spacer()
            Text(info.relText)
                .font(.caption.weight(.bold))
                .foregroundColor(Nf.mint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Nf.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Nf.mint.opacity(0.28), lineWidth: 0.8)
        )
    }

    // MARK: - Actions & Studio Card

    private var actionsBlock: some View {
        VStack(spacing: 10) {
            if let target = nextEpisode ?? episodes.first {
                Button {
                    launchPlayer(episode: target)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(nextEpisode == nil ? "Смотреть сначала" : "Смотреть · \(target.label)")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundColor(Nf.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .frame(minHeight: 50)
                    .background(Nf.violet, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(NfPressableStyle())
            }

            HStack(spacing: 10) {
                Button {
                    if account.isSignedIn {
                        showListEditor = true
                    } else {
                        showSignIn = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: listed?.status?.systemImage ?? "bookmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text(listButtonTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(listed?.status?.tintColor ?? Nf.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Nf.surfaceHi, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(listed?.status?.tintColor.opacity(0.35) ?? Color.white.opacity(0.08), lineWidth: 0.9)
                    )
                }
                .buttonStyle(NfPressableStyle())

                if let listed, listed.status == .watching, let sid = activeSeriesId {
                    Button {
                        Task { _ = await lists.bump(seriesId: sid) }
                    } label: {
                        Text("+1")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Nf.ink)
                            .frame(width: 52, height: 46)
                            .background(Nf.mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("Отметить ещё одну серию просмотренной")
                    .buttonStyle(NfPressableStyle())
                }

                if !episodes.isEmpty {
                    Menu {
                        if let next = nextEpisode {
                            Button {
                                queueSingleDownload(next)
                            } label: {
                                Label("Скачать \(next.label)", systemImage: "arrow.down.circle")
                            }
                        }
                        if nextEpisode != nil {
                            Button {
                                queueBatchDownload(count: 3)
                            } label: {
                                Label("Скачать следующие 3 серии", systemImage: "arrow.down.circle.fill")
                            }
                        } else if let first = episodes.first {
                            Button {
                                queueSingleDownload(first)
                            } label: {
                                Label("Скачать \(first.label)", systemImage: "arrow.down.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Nf.text)
                            .frame(width: 48, height: 46)
                            .background(Nf.surfaceHi, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.9)
                            )
                    }
                    .accessibilityLabel("Скачать серии")
                }
            }
        }
    }

    private var studioSelectorCard: some View {
        Button {
            showStudioPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Nf.violet)
                    .frame(width: 34, height: 34)
                    .background(Nf.violet.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedStudio?.author ?? (loadingStudios ? "Загрузка озвучек…" : "Выбрать озвучку или субтитры"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Nf.text)
                        .lineLimit(1)
                    if let studio = selectedStudio {
                        let cov = Studios.coverageText(studio: studio, episodes: episodes)
                        let line = [studio.kind.inline, studio.qualityLabel, cov].filter { !$0.isEmpty }.joined(separator: " · ")
                        Text(line)
                            .font(.caption)
                            .foregroundColor(Nf.textDim)
                            .lineLimit(1)
                    } else if !groupedStudios.isEmpty {
                        let summary = groupedStudios.prefix(2).map { "\($0.0.short): \($0.1.count)" }.joined(separator: " · ")
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(Nf.textDim)
                    }
                }

                Spacer()

                if loadingStudios && playerRequest == nil {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Nf.textMute)
                }
            }
            .padding(12)
            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.7)
            )
        }
        .buttonStyle(NfPressableStyle())
        .disabled(groupedStudios.isEmpty)
    }

    private var listButtonTitle: String {
        guard let listed, let st = listed.status else { return "В список" }
        if listed.entry.watched > 0 {
            if let total = listed.total { return "\(st.title) · \(listed.entry.watched)/\(total)" }
            return "\(st.title) · \(listed.entry.watched)"
        }
        return st.title
    }

    // MARK: - Genres, Description, Facts & Scores

    private func genresRow(_ genres: [SeriesGenre]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres) { g in
                    if let matched = A365Genre.all.first(where: { $0.id == g.id || $0.title.caseInsensitiveCompare(g.title) == .orderedSame }) {
                        NavigationLink(value: CatalogFilterPreset(title: g.title, genre: matched)) {
                            genreChipLabel(g.title)
                        }
                        .buttonStyle(NfPressableStyle())
                    } else {
                        genreChipLabel(g.title)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func genreChipLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundColor(Nf.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Nf.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.7))
    }

    private func descriptionBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Описание")
                .font(.headline)
                .foregroundColor(Nf.text)

            Text(text)
                .font(.subheadline)
                .foregroundColor(Nf.textDim)
                .lineSpacing(4)
                .lineLimit(expandDescription ? nil : 4)

            Button(expandDescription ? "Свернуть" : "Читать полностью") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandDescription.toggle()
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Nf.violet)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.7)
        )
    }

    private func hasFacts(_ s: ShikiAnime) -> Bool {
        !(s.studios ?? []).isEmpty || (s.duration ?? 0) > 0 || shikiRatingLabel(s.rating) != nil || s.airedOn?.formatted() != nil
    }

    private func factsBlock(_ s: ShikiAnime) -> some View {
        let studios = (s.studios ?? []).filter { !$0.name.isEmpty }
        let rows = factRows(s)
        return VStack(spacing: 0) {
            if !studios.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Text("Студия")
                        .font(.subheadline)
                        .foregroundColor(Nf.textDim)
                    Spacer()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(studios, id: \.stableId) { studio in
                                if let sid = studio.id, !sid.isEmpty {
                                    NavigationLink(value: CatalogFilterPreset(title: studio.name, studioId: sid, studioName: studio.name)) {
                                        HStack(spacing: 4) {
                                            Text(studio.name)
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.weight(.bold))
                                        }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(Nf.violet)
                                    }
                                } else {
                                    Text(studio.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(Nf.text)
                                }
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                if !rows.isEmpty {
                    Divider().background(Nf.line).padding(.leading, 16)
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack {
                    Text(row.0)
                        .font(.subheadline)
                        .foregroundColor(Nf.textDim)
                    Spacer()
                    Text(row.1)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Nf.text)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                if idx < rows.count - 1 {
                    Divider().background(Nf.line).padding(.leading, 16)
                }
            }
        }
        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.7)
        )
    }

    private func factRows(_ s: ShikiAnime) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let dur = s.duration, dur > 0 { rows.append(("Длительность", "\(dur) мин")) }
        if let rating = shikiRatingLabel(s.rating) { rows.append(("Возраст", rating)) }
        if let aired = s.airedOn?.formatted() { rows.append(("Выход", aired)) }
        return rows
    }

    private func scoresDistributionBlock(_ stats: [ShikiScoreStat]) -> some View {
        let byScore = Dictionary(uniqueKeysWithValues: stats.map { ($0.score, $0.count) })
        let full = (1...10).map { ShikiScoreStat(score: $0, count: byScore[$0, default: 0]) }
        let total = max(full.reduce(0) { $0 + $1.count }, 1)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Оценки зрителей")
                    .font(.headline)
                    .foregroundColor(Nf.text)
                Spacer()
                Text("\(total)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(Nf.textMute)
                    .monospacedDigit()
            }

            Chart(full) { item in
                BarMark(
                    x: .value("Оценка", String(item.score)),
                    y: .value("Голосов", item.count)
                )
                .foregroundStyle(item.score >= 8 ? Nf.mint : (item.score >= 5 ? Nf.violet : Nf.amber))
                .cornerRadius(4)
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
        }
        .padding(16)
        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.7)
        )
    }

    // MARK: - Episodes

    private var episodesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Серии")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Nf.text)

                if !episodes.isEmpty {
                    Text("\(episodes.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Nf.textMute)
                        .monospacedDigit()
                }

                Spacer()

                if loading && episodes.isEmpty && playerRequest == nil {
                    ProgressView().scaleEffect(0.85)
                }
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Повторить") { Task { await loadAll(force: true) } }
                        .buttonStyle(.bordered)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            if !episodes.isEmpty {
                let preview = previewEpisodes()
                VStack(spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.element.id) { idx, ep in
                        EpisodeRowView(
                            episode: ep,
                            isWatched: ep.number > 0 && ep.number <= watchedCount,
                            isNext: ep.id == nextEpisode?.id,
                            download: downloads.item(forEpisodeId: ep.id),
                            onPlay: { launchPlayer(episode: ep) },
                            onDownload: { queueSingleDownload(ep) }
                        )
                        if idx < preview.count - 1 {
                            Divider()
                                .background(Nf.line)
                                .padding(.leading, 56)
                        }
                    }

                    if episodes.count > preview.count {
                        Divider().background(Nf.line)
                        Button {
                            showAllEpisodes = true
                        } label: {
                            HStack {
                                Text("Показать все \(episodes.count) \(ListProgress.plural(episodes.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Nf.violet)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Nf.textMute)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }
                }
                .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.7)
                )
            } else if !loading && errorMessage == nil {
                Text("Нет доступных серий")
                    .font(.subheadline)
                    .foregroundColor(Nf.textMute)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: - Franchise & Shikimori Media Sections

    private func franchiseRow(_ items: [ShikiRelatedRef]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Хронология франшизы")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        if let malId = item.malId {
                            let isCurrent = malId == activeMalId
                            NavigationLink(value: AnimeRoute(id: isCurrent ? activeSeriesId : nil, malId: malId, title: item.title, posterUrl: item.poster?.card)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .topLeading) {
                                        PosterView(urlString: item.poster?.card, cornerRadius: 12, alignment: .top)
                                            .frame(width: 118, height: 174)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(isCurrent ? Nf.violet : Color.white.opacity(0.08), lineWidth: isCurrent ? 2 : 0.6)
                                            )

                                        Text(isCurrent ? "Сейчас" : "#\(idx + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundColor(isCurrent ? Nf.ink : .white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(isCurrent ? AnyShapeStyle(Nf.violet) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                                            .padding(6)
                                    }

                                    Text(item.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(isCurrent ? Nf.violet : Nf.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    if let y = item.airedOn?.year {
                                        Text("\(y)\(item.kind.map { " · \(shikiKindLabel($0))" } ?? "")")
                                            .font(.caption2)
                                            .foregroundColor(Nf.textMute)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 118, alignment: .topLeading)
                            }
                            .buttonStyle(NfPressableStyle())
                            .disabled(isCurrent)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func screenshotsRow(_ shots: [ShikiScreenshot]) -> some View {
        let items = Array(shots.prefix(12))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Кадры")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, shot in
                        Button {
                            viewerScreenshotIndex = idx
                        } label: {
                            PosterView(urlString: shot.preview, cornerRadius: 14, alignment: .center)
                                .frame(width: 220, height: 124)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                                )
                        }
                        .buttonStyle(NfPressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func charactersRow(_ roles: [ShikiCharacterRole]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Персонажи")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(roles.prefix(16)) { role in
                        if let ch = role.character {
                            VStack(spacing: 6) {
                                PosterView(urlString: ch.poster?.card, cornerRadius: 14, alignment: .top)
                                    .frame(width: 82, height: 112)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                                    )
                                Text(ch.label)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(Nf.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 82)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func trailersRow(_ videos: [ShikiVideo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Видео и трейлеры")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(videos.prefix(8)) { vid in
                        if let raw = vid.url, let url = URL(string: raw) {
                            Link(destination: url) {
                                ZStack(alignment: .bottomLeading) {
                                    PosterView(urlString: vid.imageUrl, cornerRadius: 14, alignment: .center)
                                        .frame(width: 210, height: 118)
                                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.circle.fill")
                                            .foregroundColor(.white)
                                        Text(vid.name ?? "Трейлер")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                    }
                                    .padding(10)
                                }
                                .frame(width: 210, height: 118)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func relatedRow(_ related: [ShikiRelated]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Связанное")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(related.prefix(16)) { rel in
                        if let ref = rel.anime, let malId = ref.malId {
                            NavigationLink(value: AnimeRoute(id: nil, malId: malId, title: ref.title, posterUrl: ref.poster?.card)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    PosterView(urlString: ref.poster?.card, cornerRadius: 12, alignment: .top)
                                        .frame(width: 118, height: 174)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                                        )
                                    if let relText = rel.relationText, !relText.isEmpty {
                                        Text(relText)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(Nf.violet)
                                            .lineLimit(1)
                                    }
                                    Text(ref.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(Nf.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(width: 118, alignment: .topLeading)
                            }
                            .buttonStyle(NfPressableStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Loading & Actions Logic

    private func previewEpisodes() -> [Episode] {
        guard episodes.count > 8 else { return episodes }
        let focus = nextEpisodeIndex ?? episodes.count
        let start = max(0, min(focus - 1, episodes.count - 8))
        return Array(episodes[start..<min(start + 8, episodes.count)])
    }

    private func launchPlayer(episode: Episode) {
        let isOfflineReady = downloads.item(forEpisodeId: episode.id)?.isReady == true
        if !isOfflineReady && !account.isSignedIn {
            showSignIn = true
            return
        }
        guard let sid = activeSeriesId,
              let idx = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        playerRequest = PlayerLaunchRequest(
            seriesId: sid,
            malId: activeMalId,
            animeTitle: currentSeries?.title ?? route.title,
            posterUrl: currentSeries?.bestPosterUrl ?? route.posterUrl,
            episodes: episodes,
            startIndex: idx,
            initialPickKey: selectedStudio?.key ?? prefs.pick(animeId: sid)
        )
    }

    private func queueSingleDownload(_ ep: Episode) {
        guard account.isSignedIn else {
            showSignIn = true
            return
        }
        guard let series = currentSeries else { return }
        Task {
            do {
                let started = try await downloads.enqueue(series: series, episode: ep, studio: selectedStudio)
                if started {
                    showToast("Скачивается \(ep.label)")
                }
            } catch {
                showToast(error.userMessage)
            }
        }
    }

    private func queueBatchDownload(count: Int) {
        guard account.isSignedIn else {
            showSignIn = true
            return
        }
        guard let series = currentSeries, let nextEpisodeIndex else { return }
        let slice = Array(episodes[nextEpisodeIndex..<episodes.count])
        Task {
            let started = await downloads.enqueueBatch(series: series, episodes: slice, studio: selectedStudio, count: count)
            if started > 0 {
                showToast("Добавлено в загрузки: \(started) \(ListProgress.plural(started))")
            } else {
                showToast("Нет новых загрузок. Проверьте состояние серий в карточке.")
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toastMessage = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toastMessage == text {
                withAnimation { toastMessage = nil }
            }
        }
    }

    private func loadAll(force: Bool = false) async {
        guard !loading, !loadingStudios else { return }
        loading = true
        defer { loading = false }
        errorMessage = nil

        do {
            let sid: Int64
            if let existing = activeSeriesId {
                sid = existing
            } else if let malId = route.malId, let found = try await app.a365.byMyAnimeList(malId) {
                sid = found.id
                resolvedSeriesId = sid
            } else {
                throw ApiError("Этого тайтла нет на Anime 365")
            }

            let fetched = try await app.a365.series(id: sid, force: force)
            try Task.checkCancellation()
            fullSeries = fetched
            resolvedSeriesId = fetched.id
            let malId = fetched.myAnimeListId > 0 ? fetched.myAnimeListId : (route.malId ?? 0)
            if malId > 0 {
                async let detail = try? app.shikimori.detail(malId: malId)
                async let characters = try? app.shikimori.cast(malId: malId)
                await loadStudios(for: fetched)
                let (updatedDetail, updatedCast) = await (detail, characters)
                if let updatedDetail, !Task.isCancelled {
                    shiki = updatedDetail
                    if let franchise = updatedDetail.franchise, !franchise.isEmpty {
                        if let list = try? await app.shikimori.franchise(name: franchise), !Task.isCancelled, list.count > 1 {
                            franchiseItems = list
                        }
                    }
                }
                if let updatedCast, !Task.isCancelled { cast = updatedCast }
            } else {
                await loadStudios(for: fetched)
            }
        } catch {
            if Task.isCancelled { return }
            if let sid = activeSeriesId,
               let offline = downloads.byAnime.first(where: { $0.animeId == sid && $0.readyCount > 0 }) {
                let offlineEps = offline.episodes.filter(\.isReady).map { $0.toEpisode() }
                if var base = lists.get(sid)?.series {
                    if base.playable.isEmpty { base.episodes = offlineEps }
                    fullSeries = base
                } else {
                    fullSeries = Series(
                        id: sid,
                        myAnimeListId: route.malId ?? 0,
                        titles: Titles(ru: offline.title),
                        posterUrl: offline.posterUrl,
                        episodes: offlineEps
                    )
                }
                errorMessage = "Офлайн-режим: показаны скачанные серии"
            } else {
                errorMessage = error.userMessage
            }
        }
    }

    private func loadStudios(for series: Series) async {
        let eps = series.playable
        guard !eps.isEmpty else { return }
        loadingStudios = true
        defer { loadingStudios = false }
        let focus = nextEpisodeIndex ?? max(0, eps.count - 1)
        let scope = eps.count <= 60 ? eps : Array(eps[max(0, focus - 10)..<min(eps.count, focus + 40)])
        if let trs = try? await app.a365.translations(episodeIds: scope.map(\.id)), !Task.isCancelled {
            let built = Studios.build(trs)
            groupedStudios = Studios.grouped(built, episodes: scope)
            let chosen = Studios.choose(
                studios: built,
                pick: prefs.pick(animeId: series.id),
                preferred: prefs.preferredKind,
                favourites: prefs.favouriteStudioKeys,
                episodes: scope,
                from: 0
            )
            selectedStudio = chosen
        }
    }
}

// MARK: - Subviews & Sheets

private struct EpisodeRowView: View {
    let episode: Episode
    let isWatched: Bool
    let isNext: Bool
    let download: DownloadedEpisode?
    let onPlay: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(badgeBackground)
                            .frame(width: 32, height: 32)
                        if isWatched {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Nf.mint)
                        } else if episode.number > 0 {
                            Text("\(episode.number)")
                                .font(.caption.weight(.bold))
                                .foregroundColor(isNext ? Nf.ink : Nf.textDim)
                                .monospacedDigit()
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundColor(isNext ? Nf.ink : Nf.textDim)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.label)
                            .font(.subheadline.weight(isNext ? .semibold : .medium))
                            .foregroundColor(isWatched ? Nf.textDim : Nf.text)
                        if let title = episode.episodeTitle, !title.isEmpty {
                            Text(title)
                                .font(.caption)
                                .foregroundColor(Nf.textMute)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    if isNext {
                        Text("Далее")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Nf.violet)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Nf.violet.opacity(0.16), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Group {
                if let dl = download {
                    if dl.isReady {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(Nf.mint)
                    } else if dl.status == .downloading || dl.status == .queued {
                        ProgressView(value: dl.progress)
                            .progressViewStyle(.circular)
                            .scaleEffect(0.75)
                    } else if dl.status == .waitingWifi {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 16))
                            .foregroundColor(Nf.amber)
                    } else {
                        Button(action: onDownload) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 18))
                                .foregroundColor(Nf.amber)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Nf.textMute.opacity(0.8))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    private var badgeBackground: Color {
        if isWatched { return Nf.mint.opacity(0.15) }
        if isNext { return Nf.violet }
        return Nf.surfaceHi
    }
}

private struct DetailStudioPickerSheet: View {
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    let groupedStudios: [(TranslationKind, [Studio])]
    let episodes: [Episode]
    let selectedStudio: Studio?
    let onSelect: (Studio) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedStudios, id: \.0) { kind, list in
                    Section(kind.title) {
                        ForEach(list) { studio in
                            let active = selectedStudio?.key == studio.key
                            let isFav = prefs.isFavouriteStudio(studio.key)
                            HStack(spacing: 8) {
                                Button {
                                    onSelect(studio)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(studio.author)
                                                .font(.subheadline.weight(active ? .bold : .medium))
                                                .foregroundColor(active ? Nf.violet : Nf.text)
                                            let cov = Studios.coverageText(studio: studio, episodes: episodes)
                                            let sub = [studio.qualityLabel, cov, studio.details].filter { !$0.isEmpty }.joined(separator: " · ")
                                            if !sub.isEmpty {
                                                Text(sub)
                                                    .font(.caption)
                                                    .foregroundColor(Nf.textMute)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if active {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(Nf.violet)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    prefs.toggleFavouriteStudio(key: studio.key, name: studio.author)
                                } label: {
                                    Image(systemName: isFav ? "star.fill" : "star")
                                        .foregroundColor(isFav ? Nf.amber : Nf.textMute)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Озвучка и субтитры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct AllEpisodesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let episodes: [Episode]
    let watchedCount: Int
    let nextEpisodeId: Int64?
    @ObservedObject var downloads: DownloadManager
    let onPlay: (Episode) -> Void
    let onDownload: (Episode) -> Void

    @State private var selectedChunk = 0
    private let chunkSize = 50

    private var chunkCount: Int {
        max(1, (episodes.count + chunkSize - 1) / chunkSize)
    }

    private var visibleEpisodes: [Episode] {
        let start = selectedChunk * chunkSize
        guard start < episodes.count else { return [] }
        return Array(episodes[start..<min(start + chunkSize, episodes.count)])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if chunkCount > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0..<chunkCount, id: \.self) { idx in
                                let from = idx * chunkSize + 1
                                let to = min((idx + 1) * chunkSize, episodes.count)
                                let active = selectedChunk == idx
                                Button("\(from)–\(to)") {
                                    selectedChunk = idx
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(active ? Nf.ink : Nf.textDim)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(active ? Nf.violet : Nf.surfaceHi, in: Capsule())
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }

                List {
                    ForEach(visibleEpisodes) { ep in
                        EpisodeRowView(
                            episode: ep,
                            isWatched: ep.number > 0 && ep.number <= watchedCount,
                            isNext: ep.id == nextEpisodeId,
                            download: downloads.item(forEpisodeId: ep.id),
                            onPlay: { onPlay(ep) },
                            onDownload: { onDownload(ep) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Nf.surface)
                        .listRowSeparatorTint(Nf.line)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle("Серии · \(episodes.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
