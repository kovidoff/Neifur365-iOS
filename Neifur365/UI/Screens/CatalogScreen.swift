import SwiftUI

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

    @Published private(set) var items: [Series] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?

    private let pageSize = 30
    private var loadTask: Task<Void, Never>?

    var hasActiveFilters: Bool {
        airingOnly || selectedType != nil || selectedYear != nil || selectedGenre != nil
    }

    func resetFilters(using api: Anime365Client) {
        airingOnly = false
        selectedType = nil
        selectedYear = nil
        selectedGenre = nil
        reload(using: api, debounce: false)
    }

    func reload(using api: Anime365Client, debounce: Bool) {
        loadTask?.cancel()
        loadTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
            loading = true
            errorMessage = nil
            hasMore = true
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
                items = page
                hasMore = page.count >= pageSize
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.userMessage
            }
            loading = false
        }
    }

    func loadMoreIfNeeded(currentItem: Series, using api: Anime365Client) {
        guard !loading, !loadingMore, hasMore else { return }
        let thresholdIndex = max(0, items.count - 6)
        guard let idx = items.firstIndex(where: { $0.id == currentItem.id }), idx >= thresholdIndex else { return }

        loadingMore = true
        let offset = items.count
        let q = query
        let t = selectedType?.rawValue
        let airing = airingOnly
        let year = selectedYear
        let genre = selectedGenre?.id

        Task {
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
                let existing = Set(items.map(\.id))
                let fresh = page.filter { !existing.contains($0.id) }
                items.append(contentsOf: fresh)
                hasMore = page.count >= pageSize && !fresh.isEmpty
            } catch {
                hasMore = false
            }
            loadingMore = false
        }
    }
}

struct CatalogScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore

    @StateObject private var vm = CatalogViewModel()
    @State private var showGenrePicker = false
    @State private var showSignIn = false
    @State private var editingSeries: Series?

    private var yearsList: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1985...current).reversed())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar

                if vm.loading && vm.items.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка каталога…")
                            .font(.subheadline)
                            .foregroundColor(Nf.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = vm.errorMessage, vm.items.isEmpty {
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
                            vm.reload(using: app.a365, debounce: false)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 38))
                            .foregroundColor(Nf.textMute)
                        Text("Ничего не найдено")
                            .font(.headline)
                            .foregroundColor(Nf.text)
                        if vm.hasActiveFilters {
                            Button("Сбросить фильтры") {
                                vm.resetFilters(using: app.a365)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    catalogGrid
                }
            }
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle("Каталог")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $vm.query, prompt: "Поиск аниме…")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: ScheduleRoute()) {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Расписание онгоингов")
                }
            }
            .navigationDestination(for: AnimeRoute.self) { route in
                AnimePreviewScreen(route: route)
            }
            .navigationDestination(for: ScheduleRoute.self) { _ in
                ScheduleScreen()
            }
            .sheet(isPresented: $showGenrePicker) {
                GenrePickerSheet(selected: $vm.selectedGenre)
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .sheet(item: $editingSeries) { s in
                ListEditorSheet(seriesId: s.id, title: s.title, series: s, current: lists.get(s.id))
            }
            .task {
                if vm.items.isEmpty {
                    vm.reload(using: app.a365, debounce: false)
                }
            }
            .onChange(of: vm.query) { _ in vm.reload(using: app.a365, debounce: true) }
            .onChange(of: vm.airingOnly) { _ in vm.reload(using: app.a365, debounce: false) }
            .onChange(of: vm.selectedType) { _ in vm.reload(using: app.a365, debounce: false) }
            .onChange(of: vm.selectedYear) { _ in vm.reload(using: app.a365, debounce: false) }
            .onChange(of: vm.selectedGenre) { _ in vm.reload(using: app.a365, debounce: false) }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Airing toggle
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

                // Type menu
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

                // Genre sheet trigger
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

                // Year menu
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
                        vm.resetFilters(using: app.a365)
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
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
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

private struct CatalogGridCard: View {
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
