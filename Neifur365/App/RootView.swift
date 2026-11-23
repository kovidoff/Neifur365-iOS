import SwiftUI

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
        TabView(selection: $selectedTab) {
            HomeScreen()
                .tabItem {
                    Label(RootTab.home.title, systemImage: RootTab.home.icon)
                }
                .tag(RootTab.home)

            LibraryScreen()
                .tabItem {
                    Label(RootTab.library.title, systemImage: RootTab.library.icon)
                }
                .tag(RootTab.library)

            StagePlaceholderTab(
                title: "Каталог",
                icon: "square.grid.2x2",
                stageLabel: "Этап 3",
                description: "Фильтры по типу, статусу, жанрам, году и расписание онгоингов Shikimori появятся на следующем этапе."
            )
            .tabItem {
                Label(RootTab.catalog.title, systemImage: RootTab.catalog.icon)
            }
            .tag(RootTab.catalog)

            StagePlaceholderTab(
                title: "Загрузки",
                icon: "arrow.down.circle",
                stageLabel: "Этап 5",
                description: "Фоновое скачивание серий вместе с .ass-субтитрами для просмотра офлайн."
            )
            .tabItem {
                Label(RootTab.downloads.title, systemImage: RootTab.downloads.icon)
            }
            .tag(RootTab.downloads)
        }
        .tint(Nf.violet)
    }
}

private struct StagePlaceholderTab: View {
    let title: String
    let icon: String
    let stageLabel: String
    let description: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 46))
                    .foregroundColor(Nf.violet)
                Text(stageLabel)
                    .font(NfType.overline)
                    .foregroundColor(Nf.mint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Nf.mint.opacity(0.14), in: Capsule())
                Text(description)
                    .font(NfType.body)
                    .foregroundColor(Nf.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
