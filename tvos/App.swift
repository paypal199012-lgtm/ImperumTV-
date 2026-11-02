import SwiftUI

enum TVRoute: Hashable {
    case home, live, epg, movies, series, seriesDetail(TVItem), player, playlists, settings, favorites, search
}

/// Bildschirm-Stapel wie auf Android: Menü-Taste der Fernbedienung = Zurück
@MainActor
final class Nav: ObservableObject {
    @Published var stack: [TVRoute] = [.home]
    var top: TVRoute { stack.last ?? .home }
    /// zuletzt fokussierte Elemente je Bildschirm (damit Zurück an derselben Stelle landet)
    var lastFocus: [String: String] = [:]

    func push(_ r: TVRoute) { stack.append(r) }
    func pop() { if stack.count > 1 { stack.removeLast() } }
    func reset(_ r: TVRoute) { stack = [r] }
}

@main
struct ImperumTVApp: App {
    @StateObject private var store = TVStore()
    @StateObject private var nav = Nav()
    @StateObject private var engine = PlayerEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(nav)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @State private var started = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if nav.top != .player { AppBackground() }
            screen
            if nav.top != .player {
                ClockView().place(1400, 24, 480, 70, alignment: .topTrailing)
            }
            if store.loading {
                VStack(spacing: 24) {
                    ProgressView().scaleEffect(2).tint(UI.gold)
                    Text(store.loadingText).font(UI.font(30, .bold)).foregroundColor(UI.gold)
                }
                .place(0, 0, 1920, 1080, alignment: .center)
                .background(Color.black.opacity(0.6))
            }
        }
        .frame(width: 1920, height: 1080)
        .foregroundColor(UI.text)
        .ignoresSafeArea()
        .onExitCommand(perform: nav.stack.count > 1 ? { leave() } : nil)
        .task {
            guard !started else { return }
            started = true
            await store.start()
            if !store.hasSource { nav.reset(.playlists) }
            testSetup()
        }
    }

    @ViewBuilder private var screen: some View {
        switch nav.top {
        case .home: HomeScreen()
        case .live: LiveScreen()
        case .epg: EpgScreen()
        case .movies: VodScreen(kind: .movie)
        case .series: VodScreen(kind: .series)
        case .seriesDetail(let s): SeriesScreen(series: s)
        case .player: PlayerScreen()
        case .playlists: PlaylistsScreen()
        case .settings: SettingsScreen()
        case .favorites: FavoritesScreen()
        case .search: SearchScreen()
        }
    }

    private func leave() {
        // Aus Live TV zurück zur Startseite: Vorschau anhalten
        if nav.top == .live || nav.top == .epg { engine.stop() }
        nav.pop()
    }

    /// Simulator-Test: direkt einen Bildschirm öffnen (IMPTV_SCREEN), damit GitHub Bildschirmfotos machen kann
    private func testSetup() {
        guard TVStore.testMode, let s = TVStore.env["IMPTV_SCREEN"] else { return }
        switch s {
        case "live":
            nav.reset(.home); nav.push(.live)
            if let it = store.live.first, let u = store.url(it, .live) {
                engine.items = store.live; engine.index = 0
                engine.play(u, item: it, kind: .live)
            }
        case "player":
            nav.reset(.home); nav.push(.movies)
            if let it = store.vod.first, let u = store.url(it, .movie) {
                engine.play(u, item: it, kind: .movie)
                nav.push(.player)
            }
        case "movies": nav.reset(.home); nav.push(.movies)
        case "series": nav.reset(.home); nav.push(.series)
        case "seriesdetail": if let s = store.series.first { nav.reset(.home); nav.push(.series); nav.push(.seriesDetail(s)) }
        case "epg": nav.reset(.home); nav.push(.epg)
        case "playlists": nav.reset(.playlists)
        case "settings": nav.reset(.home); nav.push(.settings)
        case "search": nav.reset(.home); nav.push(.search)
        case "favorites": nav.reset(.home); nav.push(.favorites)
        default: nav.reset(.home)
        }
    }
}

/// Bildschirmtitel oben links (gold)
struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(text).font(UI.font(40, .bold)).foregroundColor(UI.gold).place(70, 34, 900, 56)
    }
}
