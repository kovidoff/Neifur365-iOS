import SwiftUI

enum RootTab: String, CaseIterable, Identifiable {
    case home
    case library
    case catalog
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .library: return "Списки"
        case .catalog: return "Каталог"
        case .settings: return "Настройки"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .library: return "bookmark"
        case .catalog: return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }
}

private struct DeepLinkRoute: Identifiable {
    let seriesId: Int64
    var id: Int64 { seriesId }
}

struct RootView: View {
    @EnvironmentObject private var prefs: Prefs
    @Binding var pendingDeepLinkSeriesId: Int64?

    @State private var selectedTab: RootTab = .home
    @State private var showWelcome = false
    @State private var showSignIn = false
    @State private var deepLinkRoute: DeepLinkRoute?

    var body: some View {
        tabContent
            .tint(Nf.violet)
            .onAppear {
                if !prefs.onboarded {
                    showWelcome = true
                }
                consumePendingDeepLink()
            }
            .onChange(of: pendingDeepLinkSeriesId) { _ in
                consumePendingDeepLink()
            }
            .sheet(isPresented: $showWelcome) {
                WelcomeSheet {
                    showSignIn = true
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet()
            }
            .sheet(item: $deepLinkRoute) { route in
                NavigationStack {
                    AnimePreviewScreen(route: AnimeRoute(id: route.seriesId, title: "Аниме", posterUrl: nil))
                        .navigationDestination(for: AnimeRoute.self) { next in
                            AnimePreviewScreen(route: next)
                        }
                        .navigationDestination(for: CatalogFilterPreset.self) { preset in
                            CatalogFilteredScreen(preset: preset)
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { deepLinkRoute = nil }
                            }
                        }
                }
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selectedTab) {
                Tab(RootTab.home.title, systemImage: RootTab.home.icon, value: .home) {
                    HomeScreen()
                }
                Tab(RootTab.library.title, systemImage: RootTab.library.icon, value: .library) {
                    LibraryScreen()
                }
                Tab(RootTab.catalog.title, systemImage: RootTab.catalog.icon, value: .catalog) {
                    CatalogScreen()
                }
                Tab(RootTab.settings.title, systemImage: RootTab.settings.icon, value: .settings) {
                    SettingsScreen()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
        } else {
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

                SettingsScreen()
                    .tabItem {
                        Label(RootTab.settings.title, systemImage: RootTab.settings.icon)
                    }
                    .tag(RootTab.settings)
            }
        }
    }

    private func consumePendingDeepLink() {
        guard let sid = pendingDeepLinkSeriesId else { return }
        pendingDeepLinkSeriesId = nil
        deepLinkRoute = DeepLinkRoute(seriesId: sid)
    }
}
