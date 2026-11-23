import SwiftUI

struct AnimeRoute: Hashable {
    let id: Int64
    let title: String
    let posterUrl: String?
    let series: Series?

    init(series: Series) {
        self.id = series.id
        self.title = series.title
        self.posterUrl = series.bestPosterUrl
        self.series = series
    }

    init(listed: ListedTitle) {
        self.id = listed.entry.seriesId
        self.title = listed.displayTitle
        self.posterUrl = listed.posterUrl
        self.series = listed.series
    }
}

struct AnimePreviewScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore

    let route: AnimeRoute

    @State private var fullSeries: Series?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showListEditor = false
    @State private var showSignIn = false
    @State private var showAllEpisodes = false
    @State private var expandDescription = false
    @State private var playerNoticeEpisode: Episode?

    private var currentSeries: Series? { fullSeries ?? route.series }
    private var listed: ListedTitle? { lists.get(route.id) }
    private var episodes: [Episode] { fullSeries?.playable ?? [] }
    private var watchedCount: Int { listed?.entry.watched ?? 0 }

    private var nextEpisode: Episode? {
        guard !episodes.isEmpty else { return nil }
        if watchedCount > 0 {
            return episodes.first { $0.number > watchedCount } ?? episodes.last
        }
        return episodes.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroHeader

                VStack(alignment: .leading, spacing: 20) {
                    actionsBlock
                }
                .padding(.horizontal, 16)

                if let genres = currentSeries?.genres, !genres.isEmpty {
                    genresRow(genres)
                }

                VStack(alignment: .leading, spacing: 20) {
                    if let desc = currentSeries?.descriptionText, !desc.isEmpty {
                        descriptionBlock(desc)
                    }
                    episodesBlock
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 40)
        }
        .background(Nf.ink.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
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
        .task {
            await loadFull()
        }
        .refreshable {
            await loadFull(force: true)
        }
        .sheet(isPresented: $showListEditor) {
            ListEditorSheet(
                seriesId: route.id,
                title: currentSeries?.title ?? route.title,
                series: currentSeries,
                current: listed
            )
        }
        .sheet(isPresented: $showSignIn) {
            SignInSheet()
        }
        .sheet(isPresented: $showAllEpisodes) {
            AllEpisodesSheet(
                title: currentSeries?.title ?? route.title,
                episodes: episodes,
                watchedCount: watchedCount,
                nextEpisodeId: nextEpisode?.id
            ) { ep in
                showAllEpisodes = false
                playerNoticeEpisode = ep
            }
        }
        .alert("Плеер скоро появится", isPresented: Binding(
            get: { playerNoticeEpisode != nil },
            set: { if !$0 { playerNoticeEpisode = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            if let ep = playerNoticeEpisode {
                Text("Воспроизведение «\(ep.label)» через libmpv с .ass-субтитрами, выбором озвучки и PiP подключим на следующем этапе.")
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .top) {
            // Ambient blurred backdrop
            PosterView(urlString: currentSeries?.bestPosterUrl ?? route.posterUrl, cornerRadius: 0, alignment: .top)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .blur(radius: 34)
                .opacity(0.48)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: Nf.ink.opacity(0.25), location: 0.0),
                            .init(color: Nf.ink.opacity(0.45), location: 0.45),
                            .init(color: Nf.ink.opacity(0.92), location: 0.82),
                            .init(color: Nf.ink, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            VStack(spacing: 16) {
                PosterView(urlString: currentSeries?.bestPosterUrl ?? route.posterUrl, cornerRadius: 18, alignment: .top)
                    .frame(width: 158, height: 234)
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
            .padding(.top, 98)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if let score = currentSeries?.score {
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
                dotSeparator
                Text(String(y))
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
            }

            if let t = currentSeries?.typeTitle, !t.isEmpty {
                dotSeparator
                Text(t)
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
            }

            if let epInfo = episodesSummary {
                dotSeparator
                Text(epInfo)
                    .font(.subheadline.weight(currentSeries?.airing == true ? .semibold : .regular))
                    .foregroundColor(currentSeries?.airing == true ? Nf.mint : Nf.textDim)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var dotSeparator: some View {
        Text("·")
            .foregroundColor(Nf.textMute)
    }

    private var episodesSummary: String? {
        guard let s = currentSeries else { return nil }
        let aired = s.playable.count
        if s.airing {
            if aired > 0 && s.numberOfEpisodes > 0 {
                return "\(aired)/\(s.numberOfEpisodes) эп."
            }
            if aired > 0 { return "\(aired) эп." }
            return "Онгоинг"
        }
        if s.isMovie { return "Фильм" }
        if s.numberOfEpisodes > 0 { return "\(s.numberOfEpisodes) эп." }
        return nil
    }

    // MARK: - Actions

    private var actionsBlock: some View {
        VStack(spacing: 10) {
            if let target = nextEpisode {
                Button {
                    playerNoticeEpisode = target
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(watchedCount > 0 ? "Продолжить · \(target.label)" : "Смотреть · \(target.label)")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundColor(Nf.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
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

                if let listed, listed.status == .watching {
                    Button {
                        Task { _ = await lists.bump(seriesId: route.id) }
                    } label: {
                        Text("+1")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Nf.ink)
                            .frame(width: 58, height: 46)
                            .background(Nf.mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(NfPressableStyle())
                    .accessibilityLabel("Отметить следующую серию")
                }
            }
        }
    }

    private var listButtonTitle: String {
        guard let listed, let st = listed.status else { return "Добавить в список" }
        if listed.entry.watched > 0 {
            if let total = listed.total {
                return "\(st.title) · \(listed.entry.watched)/\(total)"
            }
            return "\(st.title) · \(listed.entry.watched)"
        }
        return st.title
    }

    // MARK: - Genres (Edge-to-Edge)

    private func genresRow(_ genres: [SeriesGenre]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres) { g in
                    Text(g.title)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(Nf.textDim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Nf.surface, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.7))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Description

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

    // MARK: - Episodes (Native Grouped Section)

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

                if loading {
                    ProgressView().scaleEffect(0.85)
                } else if episodes.count > 8 {
                    Button("Все серии") {
                        showAllEpisodes = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Nf.violet)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(Nf.red)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if !episodes.isEmpty {
                let preview = previewEpisodes()
                VStack(spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.element.id) { idx, ep in
                        EpisodeRowView(
                            episode: ep,
                            isWatched: ep.number > 0 && ep.number <= watchedCount,
                            isNext: ep.id == nextEpisode?.id
                        ) {
                            playerNoticeEpisode = ep
                        }
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
            } else if !loading {
                Text("Нет доступных серий")
                    .font(.subheadline)
                    .foregroundColor(Nf.textMute)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func previewEpisodes() -> [Episode] {
        guard episodes.count > 8 else { return episodes }
        if let next = nextEpisode, let idx = episodes.firstIndex(where: { $0.id == next.id }) {
            let start = max(0, min(idx - 1, episodes.count - 8))
            return Array(episodes[start..<min(start + 8, episodes.count)])
        }
        return Array(episodes.prefix(8))
    }

    private func loadFull(force: Bool = false) async {
        loading = true
        errorMessage = nil
        do {
            fullSeries = try await app.a365.series(id: route.id, force: force)
        } catch {
            errorMessage = error.userMessage
        }
        loading = false
    }
}

private struct EpisodeRowView: View {
    let episode: Episode
    let isWatched: Bool
    let isNext: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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

                Spacer(minLength: 8)

                if isNext {
                    Text("Далее")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Nf.violet)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Nf.violet.opacity(0.16), in: Capsule())
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Nf.textMute.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var badgeBackground: Color {
        if isWatched { return Nf.mint.opacity(0.15) }
        if isNext { return Nf.violet }
        return Nf.surfaceHi
    }
}

private struct AllEpisodesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let episodes: [Episode]
    let watchedCount: Int
    let nextEpisodeId: Int64?
    let onSelect: (Episode) -> Void

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
                            isNext: ep.id == nextEpisodeId
                        ) {
                            onSelect(ep)
                        }
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
