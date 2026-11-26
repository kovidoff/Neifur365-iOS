import SwiftUI

struct CatalogFilterPreset: Hashable {
    var title: String?
    var query: String?
    var genre: A365Genre?
    var studioId: String?
    var studioName: String?
    var airingOnly: Bool = false
}

enum CatalogTypeFilter: String, CaseIterable, Identifiable {
    case tv = "tv"
    case movie = "movie"
    case ova = "ova"
    case ona = "ona"
    case special = "special"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tv: return "TV сериал"
        case .movie: return "Фильм"
        case .ova: return "OVA"
        case .ona: return "ONA"
        case .special: return "Спешл"
        }
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var query = ""
    @Published var airingOnly = false
    @Published var selectedType: CatalogTypeFilter? = nil
    @Published var selectedYear: Int? = nil
    @Published var selectedGenre: A365Genre? = nil
    @Published var studioFilter: (id: String, name: String)? = nil

    @Published private(set) var items: [Series] = []
    @Published private(set) var studioItems: [ShikiAnime] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var pageError: String?

    var isBulkResetting = false
    private let pageSize = 30
    private var loadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var nextOffset = 0

    var hasActiveFilters: Bool {
        airingOnly || selectedType != nil || selectedYear != nil || selectedGenre != nil || studioFilter != nil
    }

    func applyPreset(_ preset: CatalogFilterPreset) {
        isBulkResetting = true
        query = preset.query ?? ""
        airingOnly = preset.airingOnly
        selectedType = nil
        selectedYear = nil
        selectedGenre = preset.genre
        if let sid = preset.studioId, let sname = preset.studioName {
            studioFilter = (sid, sname)
        } else {
            studioFilter = nil
        }
        isBulkResetting = false
    }

    func resetFilters(using api: Anime365Client, shikimori: ShikimoriClient) {
        isBulkResetting = true
        airingOnly = false
        selectedType = nil
        selectedYear = nil
        selectedGenre = nil
        studioFilter = nil
        isBulkResetting = false
        reload(using: api, shikimori: shikimori, debounce: false)
    }

    @discardableResult
    func reload(using api: Anime365Client, shikimori: ShikimoriClient, debounce: Bool) -> Task<Void, Never> {
        loadTask?.cancel()
        pageTask?.cancel()
        loadingMore = false
        loading = true
        errorMessage = nil
        pageError = nil
        hasMore = false

        let task = Task {
            defer { loading = false }
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }

            if let studio = studioFilter {
                do {
                    let list = try await shikimori.byStudio(studioId: studio.id, limit: 40)
                    if Task.isCancelled { return }
                    studioItems = list
                    items = []
                    hasMore = false
                } catch {
                    if Task.isCancelled { return }
                    errorMessage = error.userMessage
                }
                return
            }

            studioItems = []
            do {
                let page = try await api.catalog(
                    query: query,
                    offset: 0,
                    limit: pageSize,
                    type: selectedType?.rawValue,
                    airing: airingOnly,
                    year: selectedYear,
                    genre: selectedGenre?.id
                )
                if Task.isCancelled { return }
                var ids = Set<Int64>()
                items = page.filter { ids.insert($0.id).inserted }
                nextOffset = page.count
                hasMore = page.count >= pageSize
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.userMessage
            }
        }
        loadTask = task
        return task
    }

    func loadMoreIfNeeded(currentItem: Series, using api: Anime365Client) {
        guard pageError == nil, studioFilter == nil else { return }
        let thresholdIndex = max(0, items.count - 6)
        guard let idx = items.firstIndex(where: { $0.id == currentItem.id }), idx >= thresholdIndex else { return }
        loadMore(using: api)
    }

    func loadMore(using api: Anime365Client) {
        guard !loading, !loadingMore, hasMore, studioFilter == nil else { return }
        pageError = nil
        loadingMore = true
        let offset = nextOffset
        let q = query
        let t = selectedType?.rawValue
        let airing = airingOnly
        let year = selectedYear
        let genre = selectedGenre?.id

        pageTask = Task {
            defer { loadingMore = false }
            do {
                let page = try await api.catalog(
                    query: q,
                    offset: offset,
                    limit: pageSize,
                    type: t,
                    airing: airing,
                    year: year,
                    genre: genre
                )
                guard !Task.isCancelled else { return }
                var existing = Set(items.map(\.id))
                let fresh = page.filter { existing.insert($0.id).inserted }
                items.append(contentsOf: fresh)
                nextOffset += page.count
                hasMore = page.count >= pageSize && !fresh.isEmpty
            } catch {
                guard !Task.isCancelled else { return }
                pageError = error.userMessage
            }
        }
    }
}

struct CatalogScreen: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            CatalogContentView(preset: nil, path: $path)
                .navigationDestination(for: AnimeRoute.self) { route in
                    AnimePreviewScreen(route: route)
                }
                .navigationDestination(for: ScheduleRoute.self) { _ in
                    ScheduleScreen()
                }
                .navigationDestination(for: CatalogFilterPreset.self) { preset in
                    CatalogFilteredScreen(preset: preset)
                }
        }
    }
}

struct CatalogFilteredScreen: View {
    let preset: CatalogFilterPreset
    @State private var dummyPath = NavigationPath()

    var body: some View {
        CatalogContentView(preset: preset, path: $dummyPath)
            .toolbar(.hidden, for: .tabBar)
    }
}

private struct CatalogContentView: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs

    let preset: CatalogFilterPreset?
    @Binding var path: NavigationPath

    @StateObject private var vm = CatalogViewModel()
    @State private var showGenrePicker = false
    @State private var showRandom = false
    @State private var showSignIn = false
    @State private var editingSeries: Series?

    private var yearsList: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1985...current).reversed())
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.studioFilter == nil {
                filterBar
            } else if let studio = vm.studioFilter {
                studioBanner(studio.name)
            }

            if vm.loading && vm.items.isEmpty && vm.studioItems.isEmpty {
                skeletonGrid
            } else if let err = vm.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 36))
                        .foregroundColor(Nf.textMute)
                    Text("Не удалось загрузить каталог")
                        .font(.headline)
                        .foregroundColor(Nf.text)
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(Nf.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Button("Повторить") {
                        vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty && vm.studioItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 38))
                        .foregroundColor(Nf.textMute)
                    Text("Ничего не найдено")
                        .font(.headline)
                        .foregroundColor(Nf.text)
                    if vm.hasActiveFilters {
                        Button("Сбросить фильтры") {
                            vm.resetFilters(using: app.a365, shikimori: app.shikimori)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.studioFilter != nil {
                studioGrid
            } else {
                catalogGrid
            }
        }
        .background(Nf.ink.ignoresSafeArea())
        .navigationTitle(preset?.title ?? "Каталог")
        .navigationBarTitleDisplayMode(preset == nil ? .large : .inline)
        .searchable(
            text: $vm.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Поиск аниме…"
        ) {
            if !prefs.recentSearches.isEmpty && vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Недавние запросы") {
                    ForEach(prefs.recentSearches, id: \.self) { recent in
                        Button {
                            vm.query = recent
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
        }
        .onSubmit(of: .search) {
            prefs.addRecentSearch(vm.query)
            vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
        }
        .toolbar {
            if preset == nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showRandom = true
                    } label: {
                        Image(systemName: "dice")
                    }
                    .accessibilityLabel("Случайное аниме")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: ScheduleRoute()) {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Расписание онгоингов")
                }
            }
        }
        .sheet(isPresented: $showGenrePicker) {
            GenrePickerSheet(selected: $vm.selectedGenre)
        }
        .sheet(isPresented: $showRandom) {
            RandomAnimeSheet(initialGenre: vm.selectedGenre) { series in
                path.append(AnimeRoute(series: series))
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInSheet()
        }
        .sheet(item: $editingSeries) { s in
            ListEditorSheet(seriesId: s.id, title: s.title, series: s, current: lists.get(s.id))
        }
        .task {
            if vm.items.isEmpty && vm.studioItems.isEmpty {
                if let preset {
                    vm.applyPreset(preset)
                }
                vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
            }
        }
        .onChange(of: vm.query) { q in
            guard !vm.isBulkResetting else { return }
            if !q.trimmingCharacters(in: .whitespaces).isEmpty && vm.studioFilter != nil {
                vm.studioFilter = nil
            }
            vm.reload(using: app.a365, shikimori: app.shikimori, debounce: true)
        }
        .onChange(of: vm.airingOnly) { _ in
            guard !vm.isBulkResetting else { return }
            vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
        }
        .onChange(of: vm.selectedType) { _ in
            guard !vm.isBulkResetting else { return }
            vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
        }
        .onChange(of: vm.selectedYear) { _ in
            guard !vm.isBulkResetting else { return }
            vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
        }
        .onChange(of: vm.selectedGenre) { _ in
            guard !vm.isBulkResetting else { return }
            vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false)
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

    private func studioBanner(_ name: String) -> some View {
        HStack {
            Label("Студия: \(name)", systemImage: "film.stack")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Nf.violet)
            Spacer()
            Button("Сбросить") {
                vm.resetFilters(using: app.a365, shikimori: app.shikimori)
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(Nf.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Nf.surface)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        vm.airingOnly.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if vm.airingOnly {
                            Circle().fill(Nf.ink).frame(width: 6, height: 6)
                        }
                        Text("Онгоинги")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(vm.airingOnly ? Nf.ink : Nf.textDim)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(vm.airingOnly ? Nf.mint : Nf.surfaceHi, in: Capsule())
                }
                .buttonStyle(NfPressableStyle())

                Menu {
                    Button {
                        vm.selectedType = nil
                    } label: {
                        if vm.selectedType == nil {
                            Label("Все типы", systemImage: "checkmark")
                        } else {
                            Text("Все типы")
                        }
                    }
                    ForEach(CatalogTypeFilter.allCases) { t in
                        Button {
                            vm.selectedType = t
                        } label: {
                            if vm.selectedType == t {
                                Label(t.title, systemImage: "checkmark")
                            } else {
                                Text(t.title)
                            }
                        }
                    }
                } label: {
                    filterChipLabel(
                        title: vm.selectedType?.title ?? "Тип",
                        active: vm.selectedType != nil,
                        chevron: true
                    )
                }

                Button {
                    showGenrePicker = true
                } label: {
                    filterChipLabel(
                        title: vm.selectedGenre?.title ?? "Жанр",
                        active: vm.selectedGenre != nil,
                        chevron: true
                    )
                }
                .buttonStyle(NfPressableStyle())

                Menu {
                    Button {
                        vm.selectedYear = nil
                    } label: {
                        if vm.selectedYear == nil {
                            Label("Любой год", systemImage: "checkmark")
                        } else {
                            Text("Любой год")
                        }
                    }
                    ForEach(yearsList, id: \.self) { year in
                        Button {
                            vm.selectedYear = year
                        } label: {
                            if vm.selectedYear == year {
                                Label(String(year), systemImage: "checkmark")
                            } else {
                                Text(String(year))
                            }
                        }
                    }
                } label: {
                    filterChipLabel(
                        title: vm.selectedYear.map(String.init) ?? "Год",
                        active: vm.selectedYear != nil,
                        chevron: true
                    )
                }

                if vm.hasActiveFilters {
                    Button {
                        vm.resetFilters(using: app.a365, shikimori: app.shikimori)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("Сбросить")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundColor(Nf.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Nf.red.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(NfPressableStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func filterChipLabel(title: String, active: Bool, chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.75)
            }
        }
        .foregroundColor(active ? Nf.ink : Nf.textDim)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(active ? Nf.violet : Nf.surfaceHi, in: Capsule())
    }

    private var catalogGrid: some View {
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
            await vm.reload(using: app.a365, shikimori: app.shikimori, debounce: false).value
        }
    }

    private var studioGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 105, maximum: 150), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vm.studioItems) { anime in
                    if let malId = anime.malId {
                        NavigationLink(value: AnimeRoute(id: nil, malId: malId, title: anime.title, posterUrl: anime.poster?.card)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Color.clear
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    .overlay {
                                        PosterView(urlString: anime.poster?.card, cornerRadius: 12, alignment: .top)
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                                    )
                                    .overlay(alignment: .topLeading) {
                                        if let score = anime.score, score > 0 {
                                            HStack(spacing: 2) {
                                                Image(systemName: "star.fill")
                                                    .font(.system(size: 8.5))
                                                    .foregroundColor(Nf.amber)
                                                Text(String(format: "%.1f", score))
                                                    .font(.system(size: 10.5, weight: .bold))
                                                    .foregroundColor(.white)
                                                    .monospacedDigit()
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .padding(6)
                                        }
                                    }

                                Text(anime.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(Nf.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                if let year = anime.year {
                                    Text(String(year))
                                        .font(.caption2)
                                        .foregroundColor(Nf.textMute)
                                }
                            }
                        }
                        .buttonStyle(NfPressableStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

struct CatalogGridCard: View {
    let series: Series
    let listStatus: ListStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    PosterView(urlString: series.bestPosterUrl, cornerRadius: 12, alignment: .top)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
                .overlay(alignment: .top) {
                    HStack {
                        if let score = series.score {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8.5))
                                    .foregroundColor(Nf.amber)
                                Text(String(format: "%.1f", score))
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer(minLength: 2)
                        if let listStatus {
                            Image(systemName: listStatus.systemImage)
                                .font(.system(size: 12))
                                .foregroundColor(listStatus.tintColor)
                                .padding(3.5)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding(6)
                }

            Text(series.title)
                .font(.caption.weight(.semibold))
                .foregroundColor(Nf.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let sub = subtitle {
                Text(sub)
                    .font(.caption2)
                    .foregroundColor(Nf.textMute)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if series.year > 0 { parts.append(String(series.year)) }
        if series.airing { parts.append("онгоинг") }
        else if series.isMovie { parts.append("фильм") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct GenrePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: A365Genre?
    @State private var filterText = ""

    private var filtered: [A365Genre] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return A365Genre.all }
        return A365Genre.all.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selected = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("Все жанры")
                            .foregroundColor(Nf.text)
                        Spacer()
                        if selected == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(Nf.violet)
                        }
                    }
                }

                ForEach(filtered) { genre in
                    Button {
                        selected = genre
                        dismiss()
                    } label: {
                        HStack {
                            Text(genre.title)
                                .foregroundColor(Nf.text)
                            Spacer()
                            if selected == genre {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Nf.violet)
                            }
                        }
                    }
                }
            }
            .searchable(text: $filterText, prompt: "Найти жанр")
            .navigationTitle("Жанры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}
