import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.channels.isEmpty || store.showSetup {
                SetupView()
            } else {
                NavigationStack {
                    HomeView()
                        .navigationDestination(for: Route.self) { route in
                            destination(route)
                        }
                        .navigationDestination(for: SeriesItem.self) { series in
                            SeriesDetailView(series: series)
                        }
                }
            }
        }
        .tint(Theme.gold)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .live:
            ChannelListView(title: "Live-TV", items: store.channels, isLive: true)
        case .epg:
            EPGListView()
        case .vod:
            MovieGridView()
        case .series:
            SeriesGridView()
        case .favorites:
            FavoritesView()
        case .search:
            SearchView()
        case .account:
            AccountView()
        case .settings:
            SettingsView()
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var tileColumns: [GridItem] {
        let count = verticalSizeClass == .compact ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 18), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                LazyVGrid(columns: tileColumns, spacing: 18) {
                    bigTile(.live, "Live TV", "tv")
                    bigTile(.epg, "EPG", "list.bullet.rectangle")
                    bigTile(.vod, "Filme", "film")
                    bigTile(.series, "Serien", "play.rectangle.on.rectangle")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                    smallTile(.favorites, "Favoriten", "star.fill")
                    smallTile(.search, "Suche", "magnifyingglass")
                    smallTile(.account, "Konto", "person.crop.circle")
                    smallTile(.settings, "Einstellungen", "gearshape.fill")
                }

                if let exp = store.expiryText {
                    Text("Läuft ab: \(exp)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
            }
            .padding(20)
        }
        .background(GoldBackground())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(Theme.gold)
                Text("ImperumTV")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.goldLight, Theme.gold],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
            }
            Spacer()
            HStack(spacing: 12) {
                NavigationLink(value: Route.search) {
                    headerIcon("magnifyingglass")
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isLoading {
                        ProgressView()
                            .frame(width: 38, height: 38)
                    } else {
                        headerIcon("arrow.clockwise")
                    }
                }
            }
        }
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.black.opacity(0.4)))
    }

    private func bigTile(_ route: Route, _ title: String, _ icon: String) -> some View {
        NavigationLink(value: route) {
            CircleTile(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func smallTile(_ route: Route, _ title: String, _ icon: String) -> some View {
        NavigationLink(value: route) {
            SquareTile(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }
}
