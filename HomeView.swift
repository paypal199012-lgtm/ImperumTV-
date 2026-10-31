import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var pip = PiPCenter.shared
    @ObservedObject private var profiles = Profiles.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if !store.isLicenseActive {
                LockView()
            } else if profiles.needsChoice {
                WhoView()
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
        .overlay {
            if let info = store.sync {
                SyncView(info: info)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.sync == nil)
        // „Neue Folgen bei …“ kurz unten zeigen
        .overlay(alignment: .bottom) {
            if let note = store.newEpisodesNote, store.sync == nil {
                NoteBanner(text: note)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { store.newEpisodesNote = nil }
                    .task {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        store.newEpisodesNote = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.newEpisodesNote)
        // Aus Bild-in-Bild zurückgeholt: Player wieder groß
        .fullScreenCover(item: $pip.restore) { session in
            PlayerScreen(channels: session.channels, startIndex: session.index, isLive: session.isLive,
                         resume: session.resume, handoff: session.model, stopOnClose: true)
                .environmentObject(store)
        }
        .tint(Theme.gold)
        .task { await store.startup() }
        .onChange(of: scenePhase) { phase in
            // App im Hintergrund: Kindersicherung wieder zu
            if phase == .background { Parental.shared.lock() }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .live:
            LiveTVView()
        case .epg:
            EPGGridView()
        case .epgList:
            EPGListView()
        case .resume:
            ResumeView()
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
        case .football:
            FootballView()
        case .settings:
            SettingsView()
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var profiles = Profiles.shared
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
        .overlay(alignment: .top) {
            if let note = store.refreshNote {
                Text(note)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.goldLight)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .overlay(Capsule().stroke(Theme.gold.opacity(0.5)))
                    .padding(.top, 10)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
                    .task(id: note) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if store.refreshNote == note { store.refreshNote = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.refreshNote)
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
                        if !store.resumeEntries.isEmpty {
                            smallTile(.resume, "Weiter", "play.circle")
                        }
                        smallTile(.favorites, "Favoriten", "star.fill")
                        smallTile(.search, "Suche", "magnifyingglass")
                        if !profiles.isKids {           // Kinder-Profil: keine Einstellungen, keine Listen
                            smallTile(.football, "Fußball", "soccerball")
                            smallTile(.settings, "Einstellungen", "gearshape.fill")
                            listsTile()
                        }
                    }
                }
                .frame(maxWidth: min(size.width - 40, 440))

                Spacer(minLength: 16)

                // „Läuft ab“ ganz unten am Bildschirmrand
                expiryLabel
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
        let byHeight = size.height - 36 - 14 - smallHeight - 10 - 20 - 20 - (store.isTrial ? 18 : 0)
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
                if !store.resumeEntries.isEmpty {
                    smallTile(.resume, "Weiter", "play.circle", height: smallHeight).frame(width: 78)
                }
                smallTile(.favorites, "Favoriten", "star.fill", height: smallHeight).frame(width: 78)
                smallTile(.search, "Suche", "magnifyingglass", height: smallHeight).frame(width: 78)
                if !profiles.isKids {
                    smallTile(.football, "Fußball", "soccerball", height: smallHeight).frame(width: 78)
                    smallTile(.settings, "Einstellungen", "gearshape.fill", height: smallHeight).frame(width: 78)
                    listsTile(height: smallHeight).frame(width: 78)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 4)

            // „Läuft ab“ ganz unten am Bildschirmrand
            expiryLabel
                .padding(.bottom, 2)
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

    /// Freigestelltes Logo (ohne Hintergrund), schwebt über der Startseite
    private var title: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(height: 34)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
            .accessibilityLabel("ImperumTV")
    }

    private var headerButtons: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.search) {
                headerIcon("magnifyingglass")
            }
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isLoading || store.moviesLoading || store.seriesLoading {
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
                    ProfileChip()
                    Spacer()
                    headerButtons
                }
            }
            .frame(height: 36)
        } else {
            HStack {
                title
                Spacer()
                ProfileChip()
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
                .overlay(alignment: .topTrailing) {
                    // Serien: roter Zähler für neue Folgen
                    if route == .series {
                        let count = store.seriesWithNewEpisodes.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 26, minHeight: 26)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(Color.red))
                                .overlay(Capsule().stroke(Color.black, lineWidth: 2))
                                .offset(x: -6, y: 6)
                        }
                    }
                }
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
