import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var items: [Series] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pageError: String?

    private let pageSize = 30
    private var searchTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var nextOffset = 0

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reload(using api: Anime365Client, debounce: Bool) {
        searchTask?.cancel()
        pageTask?.cancel()
        loadingMore = false
        errorMessage = nil
        pageError = nil

        let q = trimmedQuery
        guard !q.isEmpty else {
            loading = false
            items = []
            hasMore = false
            nextOffset = 0
            return
        }

        loading = true
        hasMore = false
        searchTask = Task {
            defer { loading = false }
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            do {
                let page = try await api.catalog(
                    query: q,
                    offset: 0,
                    limit: pageSize
                )
                if Task.isCancelled { return }
                var ids = Set<Int64>()
                items = page.filter { ids.insert($0.id).inserted }
                nextOffset = page.count
                hasMore = page.count >= pageSize
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.userMessage
            }
        }
    }

    func loadMoreIfNeeded(currentItem: Series, using api: Anime365Client) {
        guard pageError == nil else { return }
        let thresholdIndex = max(0, items.count - 6)
        guard let idx = items.firstIndex(where: { $0.id == currentItem.id }), idx >= thresholdIndex else { return }
        loadMore(using: api)
    }

    func loadMore(using api: Anime365Client) {
        let q = trimmedQuery
        guard !q.isEmpty, !loading, !loadingMore, hasMore else { return }
        pageError = nil
        loadingMore = true
        let offset = nextOffset

        pageTask = Task {
            defer { loadingMore = false }
            do {
                let page = try await api.catalog(
                    query: q,
                    offset: offset,
                    limit: pageSize
                )
                guard !Task.isCancelled else { return }
                var existing = Set(items.map(\.id))
                let fresh = page.filter { existing.insert($0.id).inserted }
                items.append(contentsOf: fresh)
                nextOffset += page.count
                hasMore = page.count >= pageSize && !fresh.isEmpty
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                pageError = error.userMessage
            }
        }
    }
}

struct SearchScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs

    @StateObject private var vm = SearchViewModel()
    @State private var path = NavigationPath()
    @State private var showRandom = false
    @State private var showSignIn = false
    @State private var editingSeries: Series?

    private var featuredGenres: [A365Genre] {
        let popularTitles = [
            "Экшен", "Комедия", "Драма", "Фэнтези", "Романтика",
            "Приключения", "Исекай", "Сёнен", "Повседневность", "Триллер",
            "Детектив", "Спорт"
        ]
        let byTitle = Dictionary(uniqueKeysWithValues: A365Genre.all.map { ($0.title.lowercased(), $0) })
        let matched = popularTitles.compactMap { byTitle[$0.lowercased()] }
        return matched.isEmpty ? Array(A365Genre.all.prefix(12)) : matched
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vm.trimmedQuery.isEmpty {
                    discoverView
                } else if vm.loading && vm.items.isEmpty {
                    skeletonGrid
                } else if let err = vm.errorMessage {
                    errorView(err)
                } else if vm.items.isEmpty {
                    emptyResultsView
                } else {
                    resultsGrid
                }
            }
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $vm.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Название аниме…"
            )
            .onSubmit(of: .search) {
                prefs.addRecentSearch(vm.query)
                vm.reload(using: app.a365, debounce: false)
            }
            .onChange(of: vm.query) { _ in
                vm.reload(using: app.a365, debounce: true)
            }
            .navigationDestination(for: AnimeRoute.self) { route in
                AnimePreviewScreen(route: route)
            }
            .navigationDestination(for: CatalogFilterPreset.self) { preset in
                CatalogFilteredScreen(preset: preset)
            }
            .sheet(isPresented: $showRandom) {
                RandomAnimeSheet { series in
                    path.append(AnimeRoute(series: series))
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .sheet(item: $editingSeries) { s in
                ListEditorSheet(seriesId: s.id, title: s.title, series: s, current: lists.get(s.id))
            }
        }
    }

    private var discoverView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button {
                    showRandom = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "dice.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Nf.violet)
                            .frame(width: 42, height: 42)
                            .background(Nf.violet.opacity(0.14), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Случайное аниме")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Nf.text)
                            Text("Подберём тайтл, если не знаете, что посмотреть")
                                .font(.caption)
                                .foregroundColor(Nf.textDim)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Nf.textMute)
                    }
                    .padding(14)
                    .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Nf.violet.opacity(0.28), lineWidth: 0.8)
                    )
                }
                .buttonStyle(NfPressableStyle())

                if !prefs.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Недавние запросы")
                                .font(.title3.weight(.bold))
                                .foregroundColor(Nf.text)
                            Spacer()
                            Button("Очистить") {
                                prefs.clearRecentSearches()
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Nf.violet)
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(prefs.recentSearches.enumerated()), id: \.element) { idx, recent in
                                HStack(spacing: 10) {
                                    Button {
                                        vm.query = recent
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.subheadline)
                                                .foregroundColor(Nf.textMute)
                                            Text(recent)
                                                .font(.subheadline)
                                                .foregroundColor(Nf.text)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        prefs.removeRecentSearch(recent)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(Nf.textMute)
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Удалить запрос")
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)

                                if idx < prefs.recentSearches.count - 1 {
                                    Divider().background(Nf.line).padding(.leading, 40)
                                }
                            }
                        }
                        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Nf.line, lineWidth: 0.7)
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Популярные жанры")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Nf.text)

                    let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 10)]
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(featuredGenres) { genre in
                            NavigationLink(value: CatalogFilterPreset(title: genre.title, genre: genre)) {
                                HStack {
                                    Text(genre.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(Nf.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(Nf.textMute)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Nf.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Nf.line, lineWidth: 0.7)
                                )
                            }
                            .buttonStyle(NfPressableStyle())
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 32)
        }
    }

    private var skeletonGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 105, maximum: 150), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<12, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(cornerRadius: 12)
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        SkeletonBlock(cornerRadius: 6)
                            .frame(height: 14)
                        SkeletonBlock(cornerRadius: 6)
                            .frame(width: 72, height: 11)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func errorView(_ err: String) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 80)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 36))
                    .foregroundColor(Nf.textMute)
                Text("Не удалось выполнить поиск")
                    .font(.headline)
                    .foregroundColor(Nf.text)
                Text(err)
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Button("Повторить") {
                    vm.reload(using: app.a365, debounce: false)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyResultsView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Spacer(minLength: 90)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 38))
                    .foregroundColor(Nf.textMute)
                Text("По запросу «\(vm.trimmedQuery)» ничего не найдено")
                    .font(.headline)
                    .foregroundColor(Nf.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Text("Попробуйте другое название или откройте каталог с фильтрами.")
                    .font(.subheadline)
                    .foregroundColor(Nf.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var resultsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 105, maximum: 150), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vm.items) { series in
                    NavigationLink(value: AnimeRoute(series: series)) {
                        CatalogGridCard(
                            series: series,
                            listStatus: lists.get(series.id)?.status
                        )
                    }
                    .buttonStyle(NfPressableStyle())
                    .contextMenu { quickMenu(for: series) }
                    .onAppear {
                        vm.loadMoreIfNeeded(currentItem: series, using: app.a365)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if vm.loadingMore {
                ProgressView()
                    .padding(.vertical, 18)
            } else if let error = vm.pageError {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Загрузить ещё") { vm.loadMore(using: app.a365) }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 12)
            } else if vm.hasMore && !vm.loading {
                Button("Показать ещё") { vm.loadMore(using: app.a365) }
                    .buttonStyle(.bordered)
                    .padding(.vertical, 12)
            }
        }
        .refreshable {
            vm.reload(using: app.a365, debounce: false)
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
