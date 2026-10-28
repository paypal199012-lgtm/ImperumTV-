import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if !store.isLicenseActive {
                LockView()
            } else if !store.started && store.channels.isEmpty {
                StartingView()
            } else if store.channels.isEmpty || store.showSetup {
                PlaylistsView()
            } else {
                NavigationStack {
                    HomeView()
                        .navigationDestination(for: Route.self) { route in
                            destination(route)
                        }
                        .navigationDestination(for: SeriesItem.self) { series in
                            SeriesDetailView(series: series)
                        }
                        .navigationDestination(for: Channel.self) { movie in
                            MovieDetailView(movie: movie)
                        }
                }
            }
        }
        .tint(Theme.gold)
        .task { await store.startup() }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .live:
            LiveTVView()
        case .multi:
            MultiView()
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

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                landscapeLayout(geo.size)
            } else {
                portraitLayout(geo.size)
            }
        }
        .background(GoldBackground())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Hochformat

    private func portraitLayout(_ size: CGSize) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                header(compact: false)

                Spacer(minLength: 24)

                VStack(spacing: 28) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 2), spacing: 18) {
                        bigTile(.live, "Live TV", "tv")
                        bigTile(.epg, "EPG", "list.bullet.rectangle")
                        bigTile(.vod, "Filme", "film")
                        bigTile(.series, "Serien", "play.rectangle.on.rectangle")
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 8) {
                        smallTile(.favorites, "Favoriten", "star.fill")
                        smallTile(.multi, "Multi", "square.grid.2x2")
                        smallTile(.search, "Suche", "magnifyingglass")
                        smallTile(.account, "Konto", "person.crop.circle")
                        smallTile(.settings, "Einstellungen", "gearshape.fill")
                        listsTile()
                    }

                    expiryLabel
                }
                .frame(maxWidth: min(size.width - 40, 440))

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minHeight: size.height)
        }
    }

    // MARK: Querformat (wie das Fernseher-Menü)

    @ViewBuilder
    private func landscapeLayout(_ size: CGSize) -> some View {
        let spacing: CGFloat = 18
        let smallHeight: CGFloat = 50
        // Kreise so groß wie möglich, aber alles muss ohne Scrollen passen
        let byHeight = size.height - 34 - 14 - smallHeight - 10 - 20 - 20 - (store.isTrial ? 18 : 0)
        let byWidth = (size.width * 0.86 - spacing * 3) / 4
        let diameter = max(80, min(byHeight, byWidth))

        VStack(spacing: 0) {
            header(compact: true)

            Spacer(minLength: 4)

            HStack(spacing: spacing) {
                bigTile(.live, "Live TV", "tv").frame(width: diameter)
                bigTile(.epg, "EPG", "list.bullet.rectangle").frame(width: diameter)
                bigTile(.vod, "Filme", "film").frame(width: diameter)
                bigTile(.series, "Serien", "play.rectangle.on.rectangle").frame(width: diameter)
            }

            HStack(spacing: 8) {
                smallTile(.favorites, "Favoriten", "star.fill", height: smallHeight).frame(width: 78)
                smallTile(.multi, "Multi", "square.grid.2x2", height: smallHeight).frame(width: 78)
                smallTile(.search, "Suche", "magnifyingglass", height: smallHeight).frame(width: 78)
                smallTile(.account, "Konto", "person.crop.circle", height: smallHeight).frame(width: 78)
                smallTile(.settings, "Einstellungen", "gearshape.fill", height: smallHeight).frame(width: 78)
                listsTile(height: smallHeight).frame(width: 78)
            }
            .padding(.top, 14)

            expiryLabel
                .padding(.top, 10)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(width: size.width, height: size.height)
    }

    // MARK: Bausteine

    @ViewBuilder
    private var expiryLabel: some View {
        VStack(spacing: 4) {
            if let exp = store.expiryText {
                Text("Läuft ab: \(exp)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4)
            }
            if store.isTrial, let link = store.deviceLink {
                Link(destination: link) {
                    Text("\(store.licenseText) · danach \(RemoteConfig.price) einmalig aktivieren")
                        .font(.caption)
                        .foregroundStyle(Theme.goldLight)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
            }
        }
    }

    private var title: some View {
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
    }

    private var headerButtons: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.search) {
                headerIcon("magnifyingglass")
            }
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isLoading {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    headerIcon("arrow.clockwise")
                }
            }
        }
    }

    /// Im Querformat steht der Titel mittig, die Knöpfe rechts
    @ViewBuilder
    private func header(compact: Bool) -> some View {
        if compact {
            ZStack {
                title
                HStack {
                    Spacer()
                    headerButtons
                }
            }
            .frame(height: 34)
        } else {
            HStack {
                title
                Spacer()
                headerButtons
            }
        }
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.black.opacity(0.4)))
    }

    private func bigTile(_ route: Route, _ title: String, _ icon: String) -> some View {
        NavigationLink(value: route) {
            CircleTile(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    /// Kachel „Listen“: zurück zu den Wiedergabelisten (andere Liste wählen)
    private func listsTile(height: CGFloat = 74) -> some View {
        Button {
            store.showSetup = true
        } label: {
            SquareTile(title: "Listen", icon: "list.bullet.rectangle.portrait", height: height)
        }
        .buttonStyle(.plain)
    }

    private func smallTile(_ route: Route, _ title: String, _ icon: String, height: CGFloat = 74) -> some View {
        NavigationLink(value: route) {
            SquareTile(title: title, icon: icon, height: height)
        }
        .buttonStyle(.plain)
    }
}
