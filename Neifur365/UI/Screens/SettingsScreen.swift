import Nuke
import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var channelPilot: ChannelPilot

    var embeddedInSheet = false
    @Environment(\.dismiss) private var dismiss

    @State private var showSignIn = false
    @State private var showStats = false
    @State private var showLogoutConfirm = false
    @State private var showClearDownloadsConfirm = false

    @State private var mirrorStatuses: [MirrorStatus] = []
    @State private var probingMirrors = false
    @State private var customMirrorInput = ""

    @State private var checkingAlerts = false

    @State private var exportDocument: BackupFileDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupToast: String?

    var body: some View {
        Group {
            if embeddedInSheet {
                NavigationStack {
                    settingsForm
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Готово") { dismiss() }
                            }
                        }
                }
            } else {
                NavigationStack {
                    settingsForm
                        .navigationDestination(for: AnimeRoute.self) { route in
                            AnimePreviewScreen(route: route)
                        }
                        .navigationDestination(for: CatalogFilterPreset.self) { preset in
                            CatalogFilteredScreen(preset: preset)
                        }
                }
            }
        }
    }

    private var settingsForm: some View {
        Form {
            accountSection
            playerSection
            favouriteStudiosSection
            downloadsSection
            alertsSection
            if account.isSignedIn {
                channelsSection
            }
            mirrorsSection
            backupAndCacheSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Nf.ink.ignoresSafeArea())
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(embeddedInSheet ? .inline : .large)
        .sheet(isPresented: $showSignIn) {
            SignInSheet()
        }
        .sheet(isPresented: $showStats) {
            WatchStatsSheet()
        }
        .confirmationDialog("Выйти из аккаунта Anime 365?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                account.logout()
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить все скачанные серии?", isPresented: $showClearDownloadsConfirm, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) {
                downloads.clearAll()
            }
            Button("Отмена", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "neifur365-settings.json"
        ) { result in
            switch result {
            case .success:
                showToast("Резервная копия сохранена")
            case .failure(let err):
                showToast(err.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .overlay(alignment: .bottom) {
            if let backupToast {
                Text(backupToast)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Nf.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .nfGlassCapsule()
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            if mirrorStatuses.isEmpty {
                await probeMirrors()
            }
            if account.isSignedIn && channelPilot.state.setup == nil {
                _ = await channelPilot.load()
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        Section("Аккаунт Anime 365") {
            if let profile = account.profile {
                HStack(spacing: 12) {
                    AvatarView(urlString: profile.avatarUrl, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.headline)
                            .foregroundColor(Nf.text)
                        subscriptionSubtitle(profile)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    showStats = true
                } label: {
                    Label("Статистика просмотра", systemImage: "chart.bar.xaxis")
                }

                Button("Обновить профиль") {
                    account.refresh()
                }

                Button("Выйти из аккаунта", role: .destructive) {
                    showLogoutConfirm = true
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.expired ? "Сессия истекла" : "Вы не вошли")
                        .font(.headline)
                        .foregroundColor(Nf.text)
                    Text("Войдите, чтобы синхронизировать списки и смотреть аниме.")
                        .font(.caption)
                        .foregroundColor(Nf.textDim)
                }
                .padding(.vertical, 4)

                Button {
                    showSignIn = true
                } label: {
                    Label("Войти в Anime 365", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
        }
        .listRowBackground(Nf.surface)
    }

    @ViewBuilder
    private func subscriptionSubtitle(_ profile: Profile) -> some View {
        if profile.subscribed == true {
            if let until = profile.subscribedUntil {
                Text("Подписка до \(AppFormatters.formatRussianDate(until))")
                    .font(.caption)
                    .foregroundColor(Nf.mint)
            } else {
                Text("Подписка активна")
                    .font(.caption)
                    .foregroundColor(Nf.mint)
            }
        } else if profile.subscribed == false {
            Text("Подписка не оплачена")
                .font(.caption)
                .foregroundColor(Nf.amber)
        } else {
            Text("ID \(profile.id)")
                .font(.caption)
                .foregroundColor(Nf.textMute)
        }
    }

    // MARK: - Player & Subtitles

    private var playerSection: some View {
        Section("Плеер и воспроизведение") {
            Picker("Качество по умолчанию", selection: $prefs.quality) {
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("360p").tag(360)
            }

            Picker("Предпочитаемый перевод", selection: $prefs.preferredKind) {
                ForEach(TranslationKind.shown, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }

            Picker("Перемотка двойным тапом", selection: $prefs.seekStep) {
                Text("5 сек").tag(5)
                Text("10 сек").tag(10)
                Text("15 сек").tag(15)
                Text("30 сек").tag(30)
            }

            Toggle("Пропуск опенингов и эндингов (AniSkip)", isOn: $prefs.aniskipEnabled)
            Toggle("Нормализация громкости", isOn: $prefs.normalizeAudio)
            Toggle("Ускорение 2× удержанием", isOn: $prefs.holdBoost)
            Toggle("Жесты яркости и громкости", isOn: $prefs.sideGestures)
            Toggle("Запоминать яркость в плеере", isOn: $prefs.rememberBrightness)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Размер субтитров")
                    Spacer()
                    Text("\(Int(round(prefs.subScale * 100)))%")
                        .foregroundColor(Nf.textDim)
                        .monospacedDigit()
                }
                Slider(value: $prefs.subScale, in: 0.7...1.5, step: 0.05)
            }
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - Favourite Studios

    @ViewBuilder
    private var favouriteStudiosSection: some View {
        if !prefs.favouriteStudios.isEmpty || prefs.pickCount > 0 {
            Section {
                ForEach(prefs.favouriteStudios) { studio in
                    HStack {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(Nf.amber)
                        Text(studio.name)
                            .foregroundColor(Nf.text)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            prefs.toggleFavouriteStudio(key: studio.key, name: studio.name)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }

                if prefs.pickCount > 0 {
                    Button("Сбросить выбор студий по тайтлам (\(prefs.pickCount))") {
                        prefs.clearPicks()
                    }
                    .foregroundColor(Nf.amber)
                }
            } header: {
                Text("Любимые студии")
            } footer: {
                Text("Отмечайте студии звёздочкой ★ в списке озвучек — новые тайтлы будут запускаться в них автоматически.")
            }
            .listRowBackground(Nf.surface)
        }
    }

    // MARK: - Downloads

    private var downloadsSection: some View {
        Section {
            Picker("Качество для скачивания", selection: $prefs.downloadQuality) {
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("360p").tag(360)
            }

            Toggle("Скачивать только по Wi‑Fi", isOn: $prefs.wifiOnlyDownloads)
                .onChange(of: prefs.wifiOnlyDownloads) { _ in
                    downloads.onNetworkPolicyChanged()
                }

            Toggle("Автоудаление просмотренных", isOn: $prefs.autoDeleteDownloaded)

            NavigationLink {
                DownloadsScreen()
            } label: {
                HStack {
                    Label("Управление загрузками", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(AppFormatters.formatBytes(downloads.totalStorageBytes))
                        .font(.caption)
                        .foregroundColor(Nf.textDim)
                        .monospacedDigit()
                }
            }

            if downloads.totalStorageBytes > 0 {
                Button("Удалить все скачанные серии", role: .destructive) {
                    showClearDownloadsConfirm = true
                }
            }
        } header: {
            Text("Офлайн-загрузки")
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        Section {
            Toggle("Уведомления о новых сериях", isOn: Binding(
                get: { prefs.alertsEnabled },
                set: { wantOn in
                    Task { _ = await app.alerts.requestPermissionAndEnable(wantOn) }
                }
            ))

            if prefs.alertsEnabled {
                Toggle("Только моя озвучка", isOn: $prefs.alertsMyStudio)
                Toggle("Также из «Запланировано»", isOn: $prefs.alertsPlanned)

                Button {
                    Task {
                        checkingAlerts = true
                        _ = await app.alerts.checkNow(silentBaseline: false)
                        checkingAlerts = false
                    }
                } label: {
                    HStack {
                        Label("Проверить сейчас", systemImage: "bell.badge")
                        Spacer()
                        if checkingAlerts {
                            ProgressView()
                        } else if let checked = prefs.alertsCheckedAt {
                            Text(AppFormatters.timeHHMM.string(from: checked))
                                .font(.caption)
                                .foregroundColor(Nf.textMute)
                        }
                    }
                }
                .disabled(checkingAlerts)
            }
        } header: {
            Text("Уведомления")
        } footer: {
            Text("iOS проверяет новые серии в фоне автоматически по системному расписанию.")
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - Video Channels

    private var channelsSection: some View {
        let chState = channelPilot.state
        return Section {
            Toggle("Автоподбор рабочего канала", isOn: $prefs.channelAuto)

            if let note = chState.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(chState.pickedByApp ? Nf.mint : Nf.textDim)
            }

            if let setup = chState.setup {
                ForEach(setup.channels) { ch in
                    Button {
                        channelPilot.selectChannel(ch)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.label)
                                    .foregroundColor(Nf.text)
                                if !ch.name.isEmpty && ch.name != ch.label {
                                    Text(ch.name)
                                        .font(.caption)
                                        .foregroundColor(Nf.textMute)
                                }
                            }
                            Spacer()
                            if chState.measuring.contains(ch.id) {
                                ProgressView().scaleEffect(0.8)
                            } else if let speed = chState.speeds[ch.id] {
                                Text(speed.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(speed.works ? Nf.mint : Nf.red)
                                    .monospacedDigit()
                            }
                            if chState.switchingId == ch.id {
                                ProgressView().scaleEffect(0.8)
                            } else if setup.current == ch.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Nf.violet)
                            }
                        }
                    }
                    .disabled(chState.switchingId != nil)
                }

                Button {
                    if chState.isTesting {
                        channelPilot.cancelMeasure()
                    } else {
                        channelPilot.measureAll()
                    }
                } label: {
                    HStack {
                        Label(
                            chState.isTesting ? "Остановить замер" : "Измерить скорость каналов",
                            systemImage: chState.isTesting ? "stop.circle" : "speedometer"
                        )
                        Spacer()
                        if chState.isTesting { ProgressView() }
                    }
                }
            } else if let err = chState.loadError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Nf.red)
                Button("Повторить загрузку каналов") {
                    Task { _ = await channelPilot.load() }
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Загрузка каналов…")
                        .foregroundColor(Nf.textDim)
                }
            }
        } header: {
            Text("Видеоканалы Anime 365")
        } footer: {
            Text("Если поток буферизуется или не запускается, приложение автоматически подберёт рабочий CDN-канал.")
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - Mirrors

    private var mirrorsSection: some View {
        Section {
            Toggle("Автоподбор зеркала", isOn: Binding(
                get: { prefs.mirrorAuto },
                set: { auto in
                    if auto {
                        app.a365.enableAutoMirror()
                        Task {
                            _ = try? await app.a365.resolveMirror()
                            await probeMirrors()
                        }
                    } else {
                        prefs.mirrorAuto = false
                    }
                }
            ))

            if probingMirrors && mirrorStatuses.isEmpty {
                HStack {
                    ProgressView()
                    Text("Проверка зеркал…")
                        .foregroundColor(Nf.textDim)
                }
            } else {
                ForEach(mirrorStatuses) { st in
                    Button {
                        app.a365.pickMirror(st.host)
                        mirrorStatuses = mirrorStatuses.map { item in
                            var copy = item
                            copy.active = (item.host == st.host)
                            return copy
                        }
                    } label: {
                        HStack {
                            Circle()
                                .fill(healthColor(st.health))
                                .frame(width: 9, height: 9)
                            Text(st.host)
                                .foregroundColor(Nf.text)
                            Spacer()
                            Text(healthText(st))
                                .font(.caption)
                                .foregroundColor(Nf.textDim)
                                .monospacedDigit()
                            if prefs.mirror == st.host {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Nf.violet)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if st.origin == .custom {
                            Button(role: .destructive) {
                                app.a365.removeCustomMirror(st.host)
                                mirrorStatuses.removeAll { $0.host == st.host }
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Своё зеркало (домен)", text: $customMirrorInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    if let added = app.a365.addCustomMirror(customMirrorInput) {
                        customMirrorInput = ""
                        app.a365.pickMirror(added)
                        Task { await probeMirrors() }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                }
                .disabled(customMirrorInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                Task { await probeMirrors() }
            } label: {
                HStack {
                    Label("Проверить доступность", systemImage: "arrow.clockwise")
                    Spacer()
                    if probingMirrors { ProgressView() }
                }
            }
            .disabled(probingMirrors)
        } header: {
            Text("Зеркала Anime 365")
        } footer: {
            Text("Сессия общая для всех зеркал — переключение не разлогинивает аккаунт.")
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - Backup & Cache

    private var backupAndCacheSection: some View {
        Section {
            Button {
                do {
                    let data = try SettingsBackup.exportJSON(from: prefs)
                    exportDocument = BackupFileDocument(data: data)
                    showExporter = true
                } catch {
                    showToast(error.localizedDescription)
                }
            } label: {
                Label("Экспорт настроек в JSON", systemImage: "square.and.arrow.up")
            }

            Button {
                showImporter = true
            } label: {
                Label("Импорт настроек из JSON", systemImage: "square.and.arrow.down")
            }

            Button {
                URLCache.shared.removeAllCachedResponses()
                ImagePipeline.shared.cache.removeAll()
                showToast("Кеш изображений и запросов очищен")
            } label: {
                Label("Очистить кеш постеров", systemImage: "sparkles.rectangle.stack")
            }
        } header: {
            Text("Данные и резервная копия")
        } footer: {
            Text("Резервная копия сохраняет настройки плеера, фильтры, любимые студии и зеркала без учётных данных.")
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - About

    private var aboutSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return Section("О приложении") {
            HStack {
                Text("Версия")
                Spacer()
                Text("v\(version) (\(build))")
                    .foregroundColor(Nf.textDim)
            }
            HStack {
                Text("Активное зеркало")
                Spacer()
                Text(prefs.mirror ?? "авто")
                    .foregroundColor(Nf.textDim)
            }
            HStack {
                Text("Плеер")
                Spacer()
                Text("libmpv + Metal / VideoToolbox")
                    .foregroundColor(Nf.textDim)
            }
        }
        .listRowBackground(Nf.surface)
    }

    // MARK: - Helpers

    private func probeMirrors() async {
        probingMirrors = true
        mirrorStatuses = await app.a365.probeAll()
        probingMirrors = false
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            showToast(err.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try SettingsBackup.importJSON(data, into: prefs)
                showToast("Настройки импортированы")
            } catch {
                showToast("Неверный файл настроек")
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { backupToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if backupToast == text {
                withAnimation { backupToast = nil }
            }
        }
    }

    private func healthColor(_ h: MirrorHealth) -> Color {
        switch h {
        case .ok: return Nf.mint
        case .slow: return Nf.amber
        case .blocked: return Nf.pink
        case .down: return Nf.red
        }
    }

    private func healthText(_ st: MirrorStatus) -> String {
        switch st.health {
        case .ok, .slow: return "\(st.millis) мс"
        case .blocked: return "Cloudflare"
        case .down: return "недоступно"
        }
    }
}
