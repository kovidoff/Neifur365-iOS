import SwiftUI

struct LibraryScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs

    @State private var selectedStatus: ListStatus = .watching
    @State private var searchQuery = ""
    @State private var sort: ListSort = .default
    @State private var editingTitle: ListedTitle?
    @State private var showSignIn = false
    @State private var showStats = false
    @State private var toastState: UndoToast?

    private struct UndoToast: Equatable {
        let message: String
        let seriesId: Int64
        let prevStatus: ListStatus?
        let prevWatched: Int
        let prevScore: Int?
        let prevSeries: Series?

        static func == (lhs: UndoToast, rhs: UndoToast) -> Bool {
            lhs.message == rhs.message && lhs.seriesId == rhs.seriesId && lhs.prevStatus == rhs.prevStatus && lhs.prevWatched == rhs.prevWatched
        }
    }

    private var displayedItems: [ListedTitle] {
        lists.display(status: selectedStatus, history: prefs.history, query: searchQuery, sort: sort)
    }

    private var otherMatches: [(ListStatus, Int)] {
        guard displayedItems.isEmpty && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return lists.matchesInOtherTabs(current: selectedStatus, query: searchQuery)
    }

    var body: some View {
        NavigationStack {
            Group {
                if account.state == .unknown {
                    ProgressView("Проверяем вход…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Nf.ink.ignoresSafeArea())
                } else if !account.isSignedIn {
                    signedOutState
                } else if !lists.loaded && lists.error == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка списков…")
                            .font(.subheadline)
                            .foregroundColor(Nf.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Nf.ink.ignoresSafeArea())
                } else if let err = lists.error, !lists.loaded {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(Nf.amber)
                        Text("Не удалось загрузить списки")
                            .font(.headline)
                            .foregroundColor(Nf.text)
                        Text(err)
                            .font(.subheadline)
                            .foregroundColor(Nf.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        Button("Повторить") {
                            Task { await lists.refreshAsync() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Nf.ink.ignoresSafeArea())
                } else {
                    signedInContent
                        .searchable(
                            text: $searchQuery,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Поиск в списке"
                        )
                }
            }
            .navigationTitle("Списки")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if account.isSignedIn {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showStats = true
                        } label: {
                            Image(systemName: "chart.bar.xaxis")
                        }
                        .accessibilityLabel("Статистика")
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Picker("Сортировка", selection: $sort) {
                                ForEach(ListSort.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: sort == .default ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                        }
                        .accessibilityLabel("Сортировка")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        DownloadsScreen()
                    } label: {
                        LibraryDownloadsIcon()
                    }
                    .accessibilityLabel("Загрузки")
                }
            }
            .navigationDestination(for: AnimeRoute.self) { route in
                AnimePreviewScreen(route: route)
            }
            .navigationDestination(for: CatalogFilterPreset.self) { preset in
                CatalogFilteredScreen(preset: preset)
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .sheet(isPresented: $showStats) {
                WatchStatsSheet()
            }
            .sheet(item: $editingTitle) { item in
                ListEditorSheet(seriesId: item.entry.seriesId, title: item.displayTitle, series: item.series, current: item)
            }
            .overlay(alignment: .bottom) {
                if let toast = toastState {
                    HStack(spacing: 12) {
                        Text(toast.message)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Nf.text)
                        if toast.seriesId > 0 {
                            Button("Отменить") {
                                restoreUndo(toast)
                            }
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Nf.violet)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .nfGlassCapsule()
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                if account.isSignedIn {
                    lists.refreshIfStale()
                }
            }
            .onChange(of: account.isSignedIn) { signedIn in
                if signedIn {
                    lists.refreshIfStale(maxAge: 0)
                }
            }
        }
    }

    private var signedOutState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bookmark.circle")
                .font(.system(size: 52))
                .foregroundColor(Nf.violet)
            Text(account.expired ? "Сессия истекла" : "Ваши списки Anime 365")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
            Text("Войдите в аккаунт Anime 365, чтобы видеть «Смотрю», «Запланировано», отметки серий и новые выпуски онгоингов.")
                .font(.subheadline)
                .foregroundColor(Nf.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showSignIn = true
            } label: {
                Text("Войти в Anime 365")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Nf.ink.ignoresSafeArea())
    }

    private var signedInContent: some View {
        VStack(spacing: 0) {
            statusBar

            if displayedItems.isEmpty {
                emptyListView
            } else if selectedStatus == .planned || selectedStatus == .completed {
                posterGridView
            } else {
                progressListView
            }
        }
        .background(Nf.ink.ignoresSafeArea())
    }

    private var statusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ListStatus.allCases) { st in
                    let active = selectedStatus == st
                    let count = lists.count(st)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            selectedStatus = st
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(st.title)
                                .font(.subheadline.weight(.semibold))
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(active ? Nf.ink.opacity(0.78) : Nf.textMute)
                                    .monospacedDigit()
                            }
                        }
                        .foregroundColor(active ? Nf.ink : Nf.textDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(active ? st.tintColor : Nf.surfaceHi, in: Capsule())
                    }
                    .buttonStyle(NfPressableStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var progressListView: some View {
        List {
            ForEach(displayedItems) { item in
                HStack(spacing: 10) {
                    NavigationLink(value: AnimeRoute(listed: item)) {
                        ListedProgressRowContent(item: item)
                    }

                    if item.status == .watching {
                        Button {
                            bumpItem(item)
                        } label: {
                            Text("+1")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Nf.mint)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(Nf.mint.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Отметить ещё одну серию")
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Nf.surface)
                .listRowSeparatorTint(Nf.line)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if item.status != .completed {
                        Button {
                            markCompleted(item)
                        } label: {
                            Label("Просмотрено", systemImage: "checkmark.circle.fill")
                        }
                        .tint(Nf.mint)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        removeItem(item)
                    } label: {
                        Label("Убрать", systemImage: "trash")
                    }
                    Button {
                        editingTitle = item
                    } label: {
                        Label("Изменить", systemImage: "slider.horizontal.3")
                    }
                    .tint(Nf.violet)
                }
                .contextMenu { itemContextMenu(item) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable {
            await lists.refreshAsync()
        }
    }

    private var posterGridView: some View {
        let columns = [GridItem(.adaptive(minimum: 105, maximum: 150), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(displayedItems) { item in
                    NavigationLink(value: AnimeRoute(listed: item)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Color.clear
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .overlay {
                                    PosterView(urlString: item.posterUrl, cornerRadius: 12, alignment: .top)
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                                )
                                .overlay(alignment: .topLeading) {
                                    if let score = item.entry.score {
                                        HStack(spacing: 2) {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8.5))
                                                .foregroundColor(Nf.amber)
                                            Text("\(score)")
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

                            Text(item.displayTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Nf.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            let progress = ListProgress.line(item)
                            if !progress.isEmpty {
                                Text(progress)
                                    .font(.caption2)
                                    .foregroundColor(Nf.textMute)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(NfPressableStyle())
                    .contextMenu { itemContextMenu(item) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await lists.refreshAsync()
        }
    }

    private var emptyListView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Spacer(minLength: 90)
                Image(systemName: searchQuery.isEmpty ? selectedStatus.systemImage : "magnifyingglass")
                    .font(.system(size: 38))
                    .foregroundColor(Nf.textMute)
                Text(searchQuery.isEmpty ? "В разделе «\(selectedStatus.title)» пока пусто" : "Ничего не найдено")
                    .font(.headline)
                    .foregroundColor(Nf.text)

                if searchQuery.isEmpty {
                    Text("Потяните вниз, чтобы обновить списки с сайта.")
                        .font(.caption)
                        .foregroundColor(Nf.textMute)
                }

                if !otherMatches.isEmpty {
                    VStack(spacing: 8) {
                        Text("Найдено в других разделах:")
                            .font(.caption)
                            .foregroundColor(Nf.textDim)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(otherMatches, id: \.0) { st, count in
                                    Button("\(st.title) (\(count))") {
                                        selectedStatus = st
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await lists.refreshAsync()
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: ListedTitle) -> some View {
        Button {
            editingTitle = item
        } label: {
            Label("Редактировать", systemImage: "slider.horizontal.3")
        }
        if item.status == .watching {
            Button {
                bumpItem(item)
            } label: {
                Label("+1 серия", systemImage: "plus.circle")
            }
        }
        if item.status != .completed {
            Button {
                markCompleted(item)
            } label: {
                Label("В «Просмотрено»", systemImage: "checkmark.circle")
            }
        }
        Button(role: .destructive) {
            removeItem(item)
        } label: {
            Label("Убрать из списка", systemImage: "trash")
        }
    }

    private func bumpItem(_ item: ListedTitle) {
        Task {
            let res = await lists.bump(seriesId: item.entry.seriesId)
            if case .failure(let err) = res { showToast(err.userMessage) }
        }
    }

    private func markCompleted(_ item: ListedTitle) {
        let prev = item
        Task {
            let nextWatched = item.total ?? item.aired ?? item.entry.watched
            let res = await lists.set(
                seriesId: item.entry.seriesId,
                status: .completed,
                watched: nextWatched,
                score: item.entry.score,
                series: item.series
            )
            switch res {
            case .success:
                showToast(
                    UndoToast(
                        message: "Перенесено в «Просмотрено»",
                        seriesId: prev.entry.seriesId,
                        prevStatus: prev.status,
                        prevWatched: prev.entry.watched,
                        prevScore: prev.entry.score,
                        prevSeries: prev.series
                    )
                )
            case .failure(let err):
                showToast(err.userMessage)
            }
        }
    }

    private func removeItem(_ item: ListedTitle) {
        let prev = item
        Task {
            let res = await lists.set(seriesId: item.entry.seriesId, status: nil, watched: 0, score: nil)
            switch res {
            case .success:
                showToast(
                    UndoToast(
                        message: "Убрано из списка",
                        seriesId: prev.entry.seriesId,
                        prevStatus: prev.status,
                        prevWatched: prev.entry.watched,
                        prevScore: prev.entry.score,
                        prevSeries: prev.series
                    )
                )
            case .failure(let err):
                showToast(err.userMessage)
            }
        }
    }

    private func restoreUndo(_ toast: UndoToast) {
        withAnimation { toastState = nil }
        Task {
            _ = await lists.set(
                seriesId: toast.seriesId,
                status: toast.prevStatus,
                watched: toast.prevWatched,
                score: toast.prevScore,
                series: toast.prevSeries
            )
        }
    }

    private func showToast(_ text: String) {
        showToast(UndoToast(message: text, seriesId: 0, prevStatus: nil, prevWatched: 0, prevScore: nil, prevSeries: nil))
    }

    private func showToast(_ toast: UndoToast) {
        withAnimation { toastState = toast }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if toastState == toast {
                withAnimation { toastState = nil }
            }
        }
    }
}

private struct LibraryDownloadsIcon: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "arrow.down.circle")
            if downloads.activeCount > 0 {
                Circle()
                    .fill(Nf.mint)
                    .frame(width: 8, height: 8)
                    .offset(x: 3, y: -2)
            }
        }
    }
}

private struct ListedProgressRowContent: View {
    let item: ListedTitle

    var body: some View {
        HStack(spacing: 12) {
            PosterView(urlString: item.posterUrl, cornerRadius: 10, alignment: .top)
                .frame(width: 54, height: 80)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Nf.text)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if item.behind > 0 {
                        Text("+\(item.behind)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Nf.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Nf.mint, in: Capsule())
                    }
                }

                Text(ListProgress.line(item))
                    .font(.caption)
                    .foregroundColor(Nf.textDim)
                    .lineLimit(1)

                if let frac = ListProgress.fraction(item) {
                    ProgressView(value: frac)
                        .tint(item.behind > 0 ? Nf.mint : Nf.violet)
                }
            }
        }
    }
}
