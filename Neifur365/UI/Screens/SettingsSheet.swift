import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    @State private var showSignIn = false
    @State private var showLogoutConfirm = false
    @State private var mirrorStatuses: [MirrorStatus] = []
    @State private var probing = false
    @State private var customMirrorInput = ""

    var body: some View {
        NavigationStack {
            Form {
                accountSection
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
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Аккаунт Anime 365") {
            if let profile = account.profile {
                HStack(spacing: 12) {
                    AvatarView(urlString: profile.avatarUrl, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(NfType.title)
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
                        .font(NfType.title)
                        .foregroundColor(Nf.text)
                    Text("Войдите, чтобы видеть списки и смотреть аниме.")
                        .font(NfType.caption)
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
                Text("Подписка до \(until)")
                    .font(NfType.caption)
                    .foregroundColor(Nf.mint)
            } else {
                Text("Подписка активна")
                    .font(NfType.caption)
                    .foregroundColor(Nf.mint)
            }
        } else if profile.subscribed == false {
            Text("Подписка не оплачена")
                .font(NfType.caption)
                .foregroundColor(Nf.amber)
        } else {
            Text("ID \(profile.id)")
                .font(NfType.caption)
                .foregroundColor(Nf.textMute)
        }
    }

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

            if probing && mirrorStatuses.isEmpty {
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
                                .font(NfType.caption)
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

            HStack {
                TextField("Добавить своё зеркало (домен)", text: $customMirrorInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Добавить") {
                    if let added = app.a365.addCustomMirror(customMirrorInput) {
                        customMirrorInput = ""
                        app.a365.pickMirror(added)
                        Task { await probeMirrors() }
                    }
                }
                .disabled(customMirrorInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                Task { await probeMirrors() }
            } label: {
                HStack {
                    Label("Проверить доступность", systemImage: "arrow.clockwise")
                    Spacer()
                    if probing { ProgressView() }
                }
            }
            .disabled(probing)
        } header: {
            Text("Зеркала Anime 365")
        } footer: {
            Text("Сессия общая для всех зеркал — переключение не разлогинивает аккаунт.")
        }
    }

    private var aboutSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
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
        }
    }

    private func probeMirrors() async {
        probing = true
        mirrorStatuses = await app.a365.probeAll()
        probing = false
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
