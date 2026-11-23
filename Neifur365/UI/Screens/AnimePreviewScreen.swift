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
    @State private var expandDescription = false

    private var currentSeries: Series? { fullSeries ?? route.series }
    private var listed: ListedTitle? { lists.get(route.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock
                actionRow
                if let genres = currentSeries?.genres, !genres.isEmpty {
                    genresRow(genres)
                }
                if let desc = currentSeries?.descriptionText, !desc.isEmpty {
                    descriptionBlock(desc)
                }
                episodesBlock
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Nf.ink.ignoresSafeArea())
        .navigationTitle(currentSeries?.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterView(urlString: currentSeries?.bestPosterUrl ?? route.posterUrl, cornerRadius: 16)
                .frame(width: 118, height: 174)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Nf.line, lineWidth: 0.7)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(currentSeries?.title ?? route.title)
                    .font(NfType.display)
                    .foregroundColor(Nf.text)
                    .fixedSize(horizontal: false, vertical: true)

                if let orig = currentSeries?.original {
                    Text(orig)
                        .font(NfType.caption)
                        .foregroundColor(Nf.textMute)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let score = currentSeries?.score {
                        Label(String(format: "%.2f", score), systemImage: "star.fill")
                            .font(NfType.label)
                            .foregroundColor(Nf.amber)
                    }
                    if let y = currentSeries?.year, y > 0 {
                        Text(String(y))
                            .font(NfType.label)
                            .foregroundColor(Nf.textDim)
                    }
                    if let t = currentSeries?.typeTitle, !t.isEmpty {
                        Text(t)
                            .font(NfType.caption)
                            .foregroundColor(Nf.textDim)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Nf.surfaceHi, in: Capsule())
                    }
                }

                if let s = currentSeries {
                    let epCount = s.playable.count
                    let totalText: String = {
                        if s.airing && epCount > 0 {
                            return s.numberOfEpisodes > 0 ? "Вышло \(epCount) из \(s.numberOfEpisodes)" : "Вышло \(epCount) серий"
                        }
                        if s.numberOfEpisodes > 0 {
                            return "\(s.numberOfEpisodes) \(ListProgress.plural(s.numberOfEpisodes))"
                        }
                        return s.airing ? "Онгоинг" : ""
                    }()
                    if !totalText.isEmpty {
                        Text(totalText)
                            .font(NfType.caption)
                            .foregroundColor(s.airing ? Nf.mint : Nf.textDim)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionRow: some View {
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
                    Text(listed?.status?.title ?? "Добавить в список")
                        .font(NfType.label)
                    if let w = listed?.entry.watched, listed?.status != nil {
                        Text("· \(w)")
                            .font(NfType.caption)
                            .opacity(0.8)
                    }
                }
                .foregroundColor(listed?.status != nil ? (listed?.status?.tintColor ?? Nf.violet) : Nf.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Nf.surfaceHi, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(listed?.status?.tintColor.opacity(0.45) ?? Nf.line, lineWidth: 1)
                )
            }
            .buttonStyle(NfPressableStyle())

            if let listed, listed.status == .watching {
                Button {
                    Task { _ = await lists.bump(seriesId: route.id) }
                } label: {
                    Text("+1")
                        .font(NfType.title)
                        .foregroundColor(Nf.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Nf.mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(NfPressableStyle())
            }
        }
    }

    private func genresRow(_ genres: [SeriesGenre]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres) { g in
                    Text(g.title)
                        .font(NfType.caption)
                        .foregroundColor(Nf.textDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Nf.surface, in: Capsule())
                        .overlay(Capsule().stroke(Nf.line, lineWidth: 0.7))
                }
            }
        }
    }

    private func descriptionBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Описание")
                .font(NfType.section)
                .foregroundColor(Nf.text)
            Text(text)
                .font(NfType.body)
                .foregroundColor(Nf.textDim)
                .lineLimit(expandDescription ? nil : 4)
            Button(expandDescription ? "Свернуть" : "Читать полностью") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandDescription.toggle()
                }
            }
            .font(NfType.label)
            .foregroundColor(Nf.violet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var episodesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Серии")
                    .font(NfType.section)
                    .foregroundColor(Nf.text)
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.85)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(NfType.caption)
                    .foregroundColor(Nf.red)
            } else if let episodes = fullSeries?.playable, !episodes.isEmpty {
                let watched = listed?.entry.watched ?? 0
                VStack(spacing: 8) {
                    ForEach(episodes.prefix(30)) { ep in
                        let isWatched = ep.number > 0 && ep.number <= watched
                        HStack(spacing: 12) {
                            Image(systemName: isWatched ? "checkmark.circle.fill" : "play.circle")
                                .font(.system(size: 20))
                                .foregroundColor(isWatched ? Nf.mint : Nf.violet)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.label)
                                    .font(NfType.label)
                                    .foregroundColor(Nf.text)
                                if let t = ep.episodeTitle, !t.isEmpty {
                                    Text(t)
                                        .font(NfType.caption)
                                        .foregroundColor(Nf.textDim)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("Этап 4")
                                .font(NfType.caption)
                                .foregroundColor(Nf.textMute)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if episodes.count > 30 {
                        Text("Ещё \(episodes.count - 30) серий — полный список и плеер появятся на следующих этапах.")
                            .font(NfType.caption)
                            .foregroundColor(Nf.textMute)
                            .padding(.top, 4)
                    }
                }
            } else if !loading {
                Text("Нет доступных серий")
                    .font(NfType.body)
                    .foregroundColor(Nf.textMute)
            }
        }
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
