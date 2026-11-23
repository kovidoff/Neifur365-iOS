import SwiftUI
import UIKit

enum RootTab: String, CaseIterable, Identifiable {
    case home
    case library
    case catalog
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .library: return "Списки"
        case .catalog: return "Каталог"
        case .downloads: return "Загрузки"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "bookmark.fill"
        case .catalog: return "square.grid.2x2.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }
}

struct RootView: View {
    @State private var selectedTab: RootTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            Nf.ink.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerCard
                    stageStatusCard
                    palettePreviewCard
                    roadmapCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 104)
            }

            bottomBar
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Nf.mint)
                    .frame(width: 8, height: 8)
                Text("NEIFUR 365 · iOS")
                    .font(NfType.overline)
                    .tracking(1.6)
                    .foregroundColor(Nf.mint)
            }

            Text("Привет, iPhone!")
                .font(NfType.hero)
                .foregroundColor(Nf.text)

            Text("Этап 1 собран и запущен. Шрифты Unbounded и Manrope, тёмная палитра и пайплайн сборки IPA работают.")
                .font(NfType.body)
                .foregroundColor(Nf.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Nf.surfaceHi, Nf.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Nf.line, lineWidth: 1)
        )
    }

    private var stageStatusCard: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let osVersion = UIDevice.current.systemVersion
        let deviceName = UIDevice.current.model

        return VStack(alignment: .leading, spacing: 12) {
            Text("Окружение")
                .font(NfType.section)
                .foregroundColor(Nf.text)

            infoRow(label: "Версия сборки", value: "v\(version) (\(build))")
            Divider().background(Nf.line)
            infoRow(label: "Устройство", value: "\(deviceName) · iOS \(osVersion)")
            Divider().background(Nf.line)
            infoRow(label: "Активная вкладка", value: selectedTab.title)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Nf.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Nf.line, lineWidth: 1)
        )
    }

    private var palettePreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Палитра Neifur")
                .font(NfType.section)
                .foregroundColor(Nf.text)

            HStack(spacing: 10) {
                swatch("Violet", Nf.violet)
                swatch("Mint", Nf.mint)
                swatch("Amber", Nf.amber)
                swatch("Pink", Nf.pink)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Nf.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Nf.line, lineWidth: 1)
        )
    }

    private var roadmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Дальше по плану")
                .font(NfType.section)
                .foregroundColor(Nf.text)

            stepRow(done: true, title: "Каркас SwiftUI и сборка IPA в GitHub Actions")
            stepRow(done: false, title: "Вход в Anime 365, зеркала, главная и списки")
            stepRow(done: false, title: "Каталог, карточка аниме и расписание Shikimori")
            stepRow(done: false, title: "Плеер с libmpv, .ass-субтитрами, жестами и PiP")
            stepRow(done: false, title: "Офлайн-загрузки и уведомления о новых сериях")
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Nf.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Nf.line, lineWidth: 1)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            ForEach(RootTab.allCases) { tab in
                let active = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        Text(tab.title)
                            .font(NfType.caption)
                    }
                    .foregroundColor(active ? Nf.violet : Nf.textMute)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(active ? Nf.violet.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(NfPressableStyle())
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Nf.surface.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Nf.line, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(NfType.label)
                .foregroundColor(Nf.textDim)
            Spacer()
            Text(value)
                .font(NfType.label)
                .foregroundColor(Nf.text)
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .frame(height: 36)
            Text(name)
                .font(NfType.caption)
                .foregroundColor(Nf.textDim)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepRow(done: Bool, title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(done ? Nf.mint : Nf.textMute)
                .padding(.top, 2)
            Text(title)
                .font(NfType.body)
                .foregroundColor(done ? Nf.text : Nf.textDim)
        }
    }
}
