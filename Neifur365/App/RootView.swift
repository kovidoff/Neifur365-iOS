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
    @EnvironmentObject private var downloads: DownloadManager
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

            CatalogScreen()
                .tabItem {
                    Label(RootTab.catalog.title, systemImage: RootTab.catalog.icon)
                }
                .tag(RootTab.catalog)

            DownloadsScreen()
                .tabItem {
                    Label(RootTab.downloads.title, systemImage: RootTab.downloads.icon)
                }
                .badge(downloads.activeCount)
                .tag(RootTab.downloads)
        }
        .tint(Nf.violet)
    }
}
