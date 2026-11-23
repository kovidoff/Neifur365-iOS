import SwiftUI

struct HomeFeed {
    let ongoing: [Series]
    let popular: [Series]
    let thisYear: [Series]
    let movies: [Series]
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var feed: HomeFeed?
    @Published var loading = false
    @Published var errorMessage: String?

    func load(using api: Anime365Client, force: Bool = false) async {
        if !force && feed != nil { return }
        loading = true
        errorMessage = nil
        do {
            let year = Calendar.current.component(.year, from: Date())
            async let ongoing = api.catalog(limit: 30, airing: true)
            async let popular = api.catalog(limit: 24)
            async let thisYear = api.catalog(limit: 24, year: year)
            async let movies = api.catalog(limit: 24, type: "movie")

            let (o, p, y, m) = try await (ongoing, popular, thisYear, movies)
            feed = HomeFeed(
                ongoing: o,
                popular: p,
                thisYear: y.filter { !$0.airing },
                movies: m
            )
        } catch {
            errorMessage = error.userMessage
        }
        loading = false
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs

    @StateObject private var vm = HomeViewModel()
    @State private var showSettings = false
    @State private var showSignIn = false
    @State private var editingSeries: Series?

    private var freshWatching: [ListedTitle] {
        lists.watching(history: prefs.history).filter { $0.behind > 0 && $0.series != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let feed = vm.feed {
                    feedScroll(feed)
                } else if vm.loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка каталога…")
                            .font(NfType.caption)
                            .foregroundColor(Nf.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Nf.ink.ignoresSafeArea())
                } else if let err = vm.errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 38))
                            .foregroundColor(Nf.textMute)
                        Text("Не получилось загрузить каталог")
                            .font(NfType.title)
                            .foregroundColor(Nf.text)
                        Text(err)
                            .font(NfType.body)
                            .foregroundColor(Nf.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Повторить") {
                            Task { await vm.load(using: app.a365, force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Nf.ink.ignoresSafeArea())
                }
            }
            .navigationTitle("Neifur 365")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        if let avatar = account.profile?.avatarUrl {
                            AvatarView(urlString: avatar, size: 28)
                        } else {
                            Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        }
                    }
                    .accessibilityLabel("Профиль и настройки")
                }
            }
            .navigationDestination(for: AnimeRoute.self) { route in
                AnimePreviewScreen(route: route)
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .sheet(item: $editingSeries) { s in
                ListEditorSheet(seriesId: s.id, title: s.title, series: s, current: lists.get(s.id))
            }
            .task {
                await vm.load(using: app.a365)
            }
            .onAppear {
                if account.isSignedIn {
                    lists.refreshIfStale()
                }
            }
        }
    }

    private func feedScroll(_ feed: HomeFeed) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !account.isSignedIn && account.state != .unknown {
                    signInBanner
                }

                if !feed.ongoing.isEmpty {
                    heroCarousel(Array(feed.ongoing.prefix(6)))
                }

                if !freshWatching.isEmpty {
                    freshSection
                }

                let restOngoing = Array(feed.ongoing.dropFirst(6))
                if !restOngoing.isEmpty {
                    animeRow(title: "Сейчас выходит", items: restOngoing)
                }
                if !feed.thisYear.isEmpty {
                    animeRow(title: "Новинки года", items: feed.thisYear)
                }
                if !feed.popular.isEmpty {
                    animeRow(title: "Самое популярное", items: feed.popular)
                }
                if !feed.movies.isEmpty {
                    animeRow(title: "Полнометражные", items: feed.movies)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(Nf.ink.ignoresSafeArea())
        .refreshable {
            await vm.load(using: app.a365, force: true)
            if account.isSignedIn {
                lists.refresh()
            }
        }
    }

    private var signInBanner: some View {
        Button {
            showSignIn = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 26))
                    .foregroundColor(Nf.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.expired ? "Сессия истекла — войдите снова" : "Войдите в Anime 365")
                        .font(NfType.title)
                        .foregroundColor(Nf.text)
                    Text("Синхронизация списков, новых серий и просмотр видео")
                        .font(NfType.caption)
                        .foregroundColor(Nf.textDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Nf.textMute)
            }
            .padding(14)
            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Nf.violet.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(NfPressableStyle())
        .padding(.horizontal, 16)
    }

    private func heroCarousel(_ items: [Series]) -> some View {
        TabView {
            ForEach(items) { series in
                NavigationLink(value: AnimeRoute(series: series)) {
                    ZStack(alignment: .bottomLeading) {
                        PosterView(urlString: series.bestPosterUrl, cornerRadius: 22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        LinearGradient(
                            colors: [.clear, Nf.ink.opacity(0.45), Nf.ink.opacity(0.95)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("ОНГОИНГ")
                                    .font(NfType.overline)
                                    .foregroundColor(Nf.ink)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Nf.mint, in: Capsule())

                                if let score = series.score {
                                    Label(String(format: "%.1f", score), systemImage: "star.fill")
                                        .font(NfType.caption)
                                        .foregroundColor(Nf.amber)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                            }

                            Text(series.title)
                                .font(NfType.display)
                                .foregroundColor(Nf.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if let genres = series.genres, !genres.isEmpty {
                                Text(genres.prefix(3).map(\.title).joined(separator: " · "))
                                    .font(NfType.caption)
                                    .foregroundColor(Nf.textDim)
                                    .lineLimit(1)
                            }
                        }
                        .padding(18)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Nf.line.opacity(0.7), lineWidth: 0.8)
                    )
                    .padding(.horizontal, 16)
                }
                .buttonStyle(NfPressableStyle(pressedScale: 0.985))
                .contextMenu { quickMenu(for: series) }
            }
        }
        .frame(height: 230)
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }

    private var freshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Новые серии")
                    .font(NfType.section)
                    .foregroundColor(Nf.text)
                Spacer()
                Text("\(freshWatching.count)")
                    .font(NfType.caption)
                    .foregroundColor(Nf.mint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Nf.mint.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(freshWatching) { item in
                        if let series = item.series {
                            NavigationLink(value: AnimeRoute(listed: item)) {
                                AnimePosterCard(
                                    series: series,
                                    listStatus: item.status,
                                    badgeText: "+\(item.behind) нов.",
                                    badgeColor: Nf.mint,
                                    width: 132
                                )
                            }
                            .buttonStyle(NfPressableStyle())
                            .contextMenu { quickMenu(for: series) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func animeRow(title: String, items: [Series]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(NfType.section)
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { series in
                        NavigationLink(value: AnimeRoute(series: series)) {
                            AnimePosterCard(
                                series: series,
                                listStatus: lists.get(series.id)?.status,
                                width: 132
                            )
                        }
                        .buttonStyle(NfPressableStyle())
                        .contextMenu { quickMenu(for: series) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func quickMenu(for series: Series) -> some View {
        if account.isSignedIn {
            Button {
                editingSeries = series
            } label: {
                Label("Редактировать в списке", systemImage: "slider.horizontal.3")
            }
            Button {
                Task { _ = await lists.set(seriesId: series.id, status: .watching, watched: lists.get(series.id)?.entry.watched ?? 0, score: lists.get(series.id)?.entry.score, series: series) }
            } label: {
                Label("В «Смотрю»", systemImage: ListStatus.watching.systemImage)
            }
            Button {
                Task { _ = await lists.set(seriesId: series.id, status: .planned, watched: lists.get(series.id)?.entry.watched ?? 0, score: lists.get(series.id)?.entry.score, series: series) }
            } label: {
                Label("В «Запланировано»", systemImage: ListStatus.planned.systemImage)
            }
        } else {
            Button {
                showSignIn = true
            } label: {
                Label("Войти, чтобы добавить в список", systemImage: "person.crop.circle")
            }
        }
    }
}
