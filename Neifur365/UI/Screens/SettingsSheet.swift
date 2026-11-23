import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    @State private var showSignIn = false
    @State private var showLogoutConfirm = false

    @State private var mirrorStatuses: [MirrorStatus] = []
    @State private var probingMirrors = false
    @State private var customMirrorInput = ""

    @State private var channelSetup: ChannelSetup?
    @State private var channelSpeeds: [Int: ChannelSpeed] = [:]
    @State private var loadingChannels = false
    @State private var testingChannels = false
    @State private var switchingChannelId: Int?
    @State private var channelError: String?

    @State private var checkingAlerts = false

    var body: some View {
        NavigationStack {
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
                aboutSection
            }
            .navigationTitle("Профиль и настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .confirmationDialog("Выйти из аккаунта Anime 365?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    account.logout()
                }
                Button("Отмена", role: .cancel) {}
            }
            .task {
                if mirrorStatuses.isEmpty {
                    await probeMirrors()
                }
                if account.isSignedIn && channelSetup == nil {
                    await loadChannels()
                }
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        Section("Аккаунт Anime 365") {
            if let profile = account.profile {
                HStack(spacing: 12) {
                    AvatarView(urlString: profile.avatarUrl, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.headline)
                            .foregroundColor(Nf.text)
                        subscriptionSubtitle(profile)
                    }
                }
                .padding(.vertical, 4)

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
                    Text("Войдите, чтобы видеть списки и смотреть аниме.")
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
    }

    @ViewBuilder
    private func subscriptionSubtitle(_ profile: Profile) -> some View {
        if profile.subscribed == true {
            if let until = profile.subscribedUntil {
                Text("Подписка до \(formatRussianDate(until))")
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
        Section("Плеер и озвучка") {
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

            Toggle("Ускорение 2× удержанием", isOn: $prefs.holdBoost)
            Toggle("Жесты яркости и громкости", isOn: $prefs.sideGestures)

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
    }

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
        }
    }

    // MARK: - Downloads

    private var downloadsSection: some View {
        Section("Офлайн-загрузки") {
            Picker("Качество для скачивания", selection: $prefs.downloadQuality) {
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("360p").tag(360)
            }

            Toggle("Автоудаление просмотренных", isOn: $prefs.autoDeleteDownloaded)
        }
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
                            Text(formatTime(checked))
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
    }

    // MARK: - Video Channels

    private var channelsSection: some View {
        Section {
            if loadingChannels && channelSetup == nil {
                HStack {
                    ProgressView()
                    Text("Загрузка каналов…")
                        .foregroundColor(Nf.textDim)
                }
            } else if let setup = channelSetup {
                ForEach(setup.channels) { ch in
                    Button {
                        switchChannel(ch.id)
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
                            if let speed = channelSpeeds[ch.id] {
                                Text(speed.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(speed.works ? Nf.mint : Nf.red)
                                    .monospacedDigit()
                            }
                            if switchingChannelId == ch.id {
                                ProgressView().scaleEffect(0.8)
                            } else if setup.current == ch.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Nf.violet)
                            }
                        }
                    }
                    .disabled(switchingChannelId != nil)
                }

                Button {
                    Task { await measureAllChannels() }
                } label: {
                    HStack {
                        Label("Измерить скорость каналов", systemImage: "speedometer")
                        Spacer()
                        if testingChannels { ProgressView() }
                    }
                }
                .disabled(testingChannels)
            } else if let channelError {
                Text(channelError)
                    .font(.caption)
                    .foregroundColor(Nf.red)
                Button("Повторить загрузку каналов") {
                    Task { await loadChannels() }
                }
            }
        } header: {
            Text("Видеоканалы Anime 365")
        } footer: {
            Text("Если видео долго буферизуется или не запускается — выберите другой CDN-канал.")
        }
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
    }

    // MARK: - Helpers

    private func probeMirrors() async {
        probingMirrors = true
        mirrorStatuses = await app.a365.probeAll()
        probingMirrors = false
    }

    private func loadChannels() async {
        loadingChannels = true
        channelError = nil
        do {
            channelSetup = try await app.a365.channels()
        } catch {
            channelError = error.userMessage
        }
        loadingChannels = false
    }

    private func switchChannel(_ id: Int) {
        switchingChannelId = id
        Task {
            do {
                try await app.a365.setChannel(id: id)
                if let cur = channelSetup {
                    channelSetup = ChannelSetup(channels: cur.channels, current: id, fromRussia: cur.fromRussia)
                }
            } catch {
                channelError = error.userMessage
            }
            switchingChannelId = nil
        }
    }

    private func measureAllChannels() async {
        guard let channels = channelSetup?.channels else { return }
        testingChannels = true
        for ch in channels {
            let speed = await app.a365.measure(channel: ch)
            channelSpeeds[ch.id] = speed
        }
        testingChannels = false
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

    private func formatRussianDate(_ iso: String) -> String {
        let inFmt = DateFormatter()
        inFmt.calendar = Calendar(identifier: .gregorian)
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let date = inFmt.date(from: iso) else { return iso }
        let outFmt = DateFormatter()
        outFmt.locale = Locale(identifier: "ru_RU")
        outFmt.dateStyle = .long
        outFmt.timeStyle = .none
        return outFmt.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
