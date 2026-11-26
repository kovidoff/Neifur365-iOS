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
    @Published var todayItems: [ScheduleItem] = []
    @Published var loading = false
    @Published var errorMessage: String?

    func load(
        using api: Anime365Client,
        shikimori: ShikimoriClient,
        lists: ListsStore,
        force: Bool = false
    ) async {
        guard !loading, force || feed == nil else { return }
        loading = true
        defer { loading = false }
        errorMessage = nil

        if let cached = await shikimori.cachedSchedule(), todayItems.isEmpty {
            todayItems = buildTodayItems(ongoing: cached, lists: lists)
        }

        do {
            let year = Calendar.current.component(.year, from: Date())
            async let ongoing = api.catalog(limit: 30, airing: true)
            async let popular = api.catalog(limit: 24)
            async let thisYear = api.catalog(limit: 24, year: year)
            async let movies = api.catalog(limit: 24, type: "movie")

            let extraMalIds = lists.titles.values.compactMap { item -> Int64? in
                guard item.airing, item.status == .watching || item.status == .planned else { return nil }
                return item.series?.myAnimeListId
            }.filter { $0 > 0 }
            async let shikiSchedule = try? shikimori.ongoingSchedule(extraMalIds: extraMalIds, forceRefresh: force)

            let (o, p, y, m) = try await (ongoing, popular, thisYear, movies)
            guard !Task.isCancelled else { return }
            feed = HomeFeed(
                ongoing: o,
                popular: p,
                thisYear: y.filter { !$0.airing },
                movies: m
            )

            if let shikiOngoing = await shikiSchedule, !Task.isCancelled {
                todayItems = buildTodayItems(ongoing: shikiOngoing, lists: lists)
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.userMessage
        }
    }

    private func buildTodayItems(ongoing: [ShikiAnime], lists: ListsStore) -> [ScheduleItem] {
        var byMalId: [Int64: ListedTitle] = [:]
        for item in lists.titles.values {
            if let mal = item.series?.myAnimeListId, mal > 0 {
                byMalId[mal] = item
            }
        }
        let days = ScheduleBuilder.buildWeekly(animes: ongoing, byMalId: byMalId)
        return Array((days.first?.items ?? []).prefix(12))
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var downloads: DownloadManager

    @StateObject private var vm = HomeViewModel()
    @State private var heroIndex = 0
    @State private var showProfileSettings = false
    @State private var showSignIn = false
    @State private var editingSeries: Series?
    @State private var offlinePlayerRequest: PlayerLaunchRequest?
    @ScaledMetric(relativeTo: .title3) private var heroHeight = 204.0

    private var freshWatching: [ListedTitle] {
        lists.watching(history: prefs.history).filter { $0.behind > 0 && $0.series != nil }
    }

    private var continueItems: [WatchEntry] {
        var seen = Set<String>()
        return prefs.history.filter { entry in
            guard seen.insert(entry.animeId).inserted else { return false }
            if let sid = Int64(entry.animeId), let st = lists.get(sid)?.status {
                return st != .completed && st != .dropped
            }
            return true
        }.prefix(12).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let feed = vm.feed {
                    feedScroll(feed)
                } else if vm.loading {
                    loadingSkeleton
                } else if let err = vm.errorMessage {
                    offlineOrErrorView(err)
                }
            }
            .navigationTitle("Neifur 365")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(value: ScheduleRoute()) {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Расписание онгоингов")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        DownloadsScreen()
                    } label: {
                        HomeDownloadsIcon()
                    }
                    .accessibilityLabel("Загрузки")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showProfileSettings = true
                    } label: {
                        if let avatar = account.profile?.avatarUrl {
                            AvatarView(urlString: avatar, size: 30)
                        } else {
                            Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                                .font(.system(size: 20))
                        }
                    }
                    .accessibilityLabel("Профиль и настройки")
                }
            }
            .navigationDestination(for: AnimeRoute.self) { route in
                AnimePreviewScreen(route: route)
            }
            .navigationDestination(for: ScheduleRoute.self) { _ in
                ScheduleScreen()
            }
            .navigationDestination(for: CatalogFilterPreset.self) { preset in
                CatalogFilteredScreen(preset: preset)
            }
            .sheet(isPresented: $showProfileSettings) {
                SettingsScreen(embeddedInSheet: true)
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .sheet(item: $editingSeries) { s in
                ListEditorSheet(seriesId: s.id, title: s.title, series: s, current: lists.get(s.id))
            }
            .fullScreenCover(item: $offlinePlayerRequest) { req in
                PlayerScreen(request: req, app: app)
            }
            .task {
                await vm.load(using: app.a365, shikimori: app.shikimori, lists: lists)
            }
            .onAppear {
                if account.isSignedIn {
                    lists.refreshIfStale()
                }
            }
        }
    }

    private var loadingSkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SkeletonBlock(cornerRadius: 22)
                    .frame(height: heroHeight)
                    .padding(.horizontal, 16)

                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(cornerRadius: 8)
                            .frame(width: 160, height: 22)
                            .padding(.horizontal, 16)

                        HStack(spacing: 12) {
                            ForEach(0..<3, id: \.self) { _ in
                                SkeletonBlock(cornerRadius: 14)
                                    .frame(width: 124, height: 186)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 10)
        }
        .background(Nf.ink.ignoresSafeArea())
    }

    @ViewBuilder
    private func offlineOrErrorView(_ err: String) -> some View {
        let offlineGroups = downloads.byAnime.filter { $0.readyCount > 0 }
        if offlineGroups.isEmpty && continueItems.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 38))
                    .foregroundColor(Nf.textMute)
                Text("Не получилось загрузить каталог")
                    .font(.headline)
                    .foregroundColor(Nf.text)
                Text(err)
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Button("Повторить") {
                    Task { await vm.load(using: app.a365, shikimori: app.shikimori, lists: lists, force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Nf.ink.ignoresSafeArea())
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .foregroundColor(Nf.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Нет связи с Anime 365")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Nf.text)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(Nf.textDim)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Повторить") {
                            Task { await vm.load(using: app.a365, shikimori: app.shikimori, lists: lists, force: true) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)

                    if !offlineGroups.isEmpty {
                        offlineSection(offlineGroups)
                    }

                    if !continueItems.isEmpty {
                        continueSection
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            .background(Nf.ink.ignoresSafeArea())
        }
    }

    private func feedScroll(_ feed: HomeFeed) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let error = vm.errorMessage {
                    Label(error, systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if !account.isSignedIn && account.state != .unknown {
                    signInBanner
                }

                let heroItems = Array(feed.ongoing.prefix(6))
                if !heroItems.isEmpty {
                    heroCarousel(heroItems)
                }

                if !continueItems.isEmpty {
                    continueSection
                }

                if !freshWatching.isEmpty {
                    freshSection
                }

                if !vm.todayItems.isEmpty {
                    todayScheduleSection
                }

                let offlineGroups = downloads.byAnime.filter { $0.readyCount > 0 }
                if !offlineGroups.isEmpty {
                    offlineSection(offlineGroups)
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
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Nf.ink.ignoresSafeArea())
        .refreshable {
            await vm.load(using: app.a365, shikimori: app.shikimori, lists: lists, force: true)
            if account.isSignedIn {
                await lists.refreshAsync()
            }
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Продолжить просмотр")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(continueItems) { entry in
                        if let sid = Int64(entry.animeId) {
                            NavigationLink(value: AnimeRoute(id: sid, title: entry.title, posterUrl: entry.poster)) {
                                HStack(spacing: 12) {
                                    PosterView(urlString: entry.poster, cornerRadius: 10, alignment: .top)
                                        .frame(width: 54, height: 78)

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(Nf.text)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)

                                        Text("Серия \(entry.episode)")
                                            .font(.caption.weight(.medium))
                                            .foregroundColor(Nf.violet)

                                        ProgressView(value: entry.progress)
                                            .tint(entry.finished ? Nf.mint : Nf.violet)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .frame(width: 248)
                                .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.07), lineWidth: 0.7)
                                )
                            }
                            .buttonStyle(NfPressableStyle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    prefs.removeFromHistory(animeId: entry.animeId)
                                } label: {
                                    Label("Убрать из истории", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var todayScheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Сегодня выходит")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Nf.text)
                Spacer()
                NavigationLink(value: ScheduleRoute()) {
                    HStack(spacing: 4) {
                        Text("Всё расписание")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Nf.violet)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(vm.todayItems) { item in
                        let rel = ScheduleBuilder.formatRelativeAir(airAt: item.airAt)
                        NavigationLink(value: item.route) {
                            HStack(spacing: 10) {
                                PosterView(urlString: item.poster, cornerRadius: 10, alignment: .top)
                                    .frame(width: 48, height: 70)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(Nf.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: 5) {
                                        Text("Серия \(item.nextEpisode)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(rel.aired ? Nf.mint : Nf.violet)
                                        Text("· \(rel.text)")
                                            .font(.caption)
                                            .foregroundColor(Nf.textDim)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .frame(width: 244)
                            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(item.isMine ? Nf.violet.opacity(0.35) : Nf.line, lineWidth: 0.7)
                            )
                        }
                        .buttonStyle(NfPressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func offlineSection(_ groups: [DownloadedAnime]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Доступно офлайн")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Nf.text)
                Spacer()
                NavigationLink {
                    DownloadsScreen()
                } label: {
                    HStack(spacing: 4) {
                        Text("Все загрузки")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Nf.mint)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(groups) { group in
                        Button {
                            let ready = group.episodes.filter(\.isReady)
                            guard !ready.isEmpty else { return }
                            let resumeIdx: Int = {
                                let idStr = String(group.animeId)
                                if let last = prefs.history.first(where: { $0.animeId == idStr && !$0.finished }),
                                   let hit = ready.firstIndex(where: { $0.episodeNumber == last.episode }) {
                                    return hit
                                }
                                return 0
                            }()
                            let malId = lists.get(group.animeId)?.series?.myAnimeListId ?? 0
                            offlinePlayerRequest = PlayerLaunchRequest(
                                seriesId: group.animeId,
                                malId: malId,
                                animeTitle: group.title,
                                posterUrl: group.posterUrl,
                                episodes: ready.map { $0.toEpisode() },
                                startIndex: resumeIdx,
                                initialPickKey: nil
                            )
                        } label: {
                            HStack(spacing: 12) {
                                PosterView(urlString: group.posterUrl, cornerRadius: 10, alignment: .top)
                                    .frame(width: 52, height: 74)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(Nf.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(group.readyCount) \(ListProgress.plural(group.readyCount)) · \(formatBytes(group.totalBytes))")
                                        .font(.caption)
                                        .foregroundColor(Nf.mint)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(Nf.mint)
                            }
                            .padding(10)
                            .frame(width: 264)
                            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Nf.mint.opacity(0.28), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(NfPressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var signInBanner: some View {
        Button {
            showSignIn = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 24))
                    .foregroundColor(Nf.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.expired ? "Сессия истекла — войдите снова" : "Войдите в Anime 365")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Nf.text)
                    Text("Синхронизация списков, новых серий и просмотр видео")
                        .font(.caption)
                        .foregroundColor(Nf.textDim)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Nf.textMute)
            }
            .padding(14)
            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Nf.violet.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(NfPressableStyle())
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func heroCarousel(_ items: [Series]) -> some View {
        if #available(iOS 17.0, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { series in
                        NavigationLink(value: AnimeRoute(series: series)) {
                            HeroCard(series: series, listStatus: lists.get(series.id)?.status)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    max(280, width - 32)
                                }
                                .frame(height: heroHeight)
                        }
                        .buttonStyle(NfPressableStyle(pressedScale: 0.985))
                        .contextMenu { quickMenu(for: series) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        } else {
            VStack(spacing: 12) {
                TabView(selection: $heroIndex) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, series in
                        NavigationLink(value: AnimeRoute(series: series)) {
                            HeroCard(series: series, listStatus: lists.get(series.id)?.status)
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(NfPressableStyle(pressedScale: 0.985))
                        .contextMenu { quickMenu(for: series) }
                        .tag(idx)
                    }
                }
                .frame(height: heroHeight)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: items.map(\.id)) { ids in
                    if !ids.indices.contains(heroIndex) { heroIndex = 0 }
                }

                HStack(spacing: 6) {
                    ForEach(0..<items.count, id: \.self) { i in
                        Capsule()
                            .fill(i == heroIndex ? Nf.text : Color.white.opacity(0.24))
                            .frame(width: i == heroIndex ? 22 : 6, height: 5)
                            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: heroIndex)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
    }

    private var freshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Новые серии")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Nf.text)
                Spacer()
                Text("\(freshWatching.count)")
                    .font(.caption.weight(.bold))
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
                                    badgeColor: Nf.mint
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { series in
                        NavigationLink(value: AnimeRoute(series: series)) {
                            AnimePosterCard(
                                series: series,
                                listStatus: lists.get(series.id)?.status
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
                Task {
                    _ = await lists.set(
                        seriesId: series.id,
                        status: .watching,
                        watched: lists.get(series.id)?.entry.watched ?? 0,
                        score: lists.get(series.id)?.entry.score,
                        series: series
                    )
                }
            } label: {
                Label("В «Смотрю»", systemImage: ListStatus.watching.systemImage)
            }
            Button {
                Task {
                    _ = await lists.set(
                        seriesId: series.id,
                        status: .planned,
                        watched: lists.get(series.id)?.entry.watched ?? 0,
                        score: lists.get(series.id)?.entry.score,
                        series: series
                    )
                }
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

private struct HomeDownloadsIcon: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
            if downloads.activeCount > 0 {
                Circle()
                    .fill(Nf.mint)
                    .frame(width: 8, height: 8)
                    .offset(x: 3, y: -2)
            }
        }
    }
}

private struct HeroCard: View {
    let series: Series
    let listStatus: ListStatus?

    var body: some View {
        ZStack {
            PosterView(
                urlString: series.bestPosterUrl, cornerRadius: 22,
                alignment: .center, contentMode: .fill
            )
            .blur(radius: 26)
            .opacity(0.28)
            .clipped()

            HStack(spacing: 14) {
                PosterView(
                    urlString: series.bestPosterUrl, cornerRadius: 12,
                    alignment: .top, contentMode: .fill
                )
                .frame(width: 112, height: 168)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("СЕЙЧАС ВЫХОДИТ")
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(Nf.mint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Nf.mint.opacity(0.14), in: Capsule())

                    Text(series.title)
                        .font(.headline)
                        .foregroundStyle(Nf.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.footnote)
                            .foregroundStyle(Nf.textDim)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    if let listStatus {
                        Label(listStatus.title, systemImage: listStatus.systemImage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(listStatus.tintColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        var parts: [String] = []
        if series.year > 0 { parts.append(String(series.year)) }
        if let score = series.score, score > 0 { parts.append(String(format: "★ %.1f", score)) }
        parts += (series.genres ?? []).prefix(2).map(\.title)
        return parts.joined(separator: " · ")
    }
}
