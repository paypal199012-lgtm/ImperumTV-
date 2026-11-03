import SwiftUI

enum TVRoute: Hashable {
    case home, live, epg, movies, series, seriesDetail(TVItem), movieDetail(TVItem), continueWatching, player, playlists, settings, favorites, search, football, profiles, nettest, lockCats
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
    @StateObject private var resume = ResumeBook()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(nav)
                .environmentObject(engine)
                .environmentObject(resume)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook
    @AppStorage("tv.theme") private var theme = "gold"
    @State private var started = false
    @ObservedObject private var help = RemoteHelp.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if nav.top != .player { AppBackground() }
            screen
            if nav.top != .player {
                ClockView().place(1400, 24, 480, 70, alignment: .topTrailing)
            }
            HelpBanner().place(460, 14, 1000, 56, alignment: .top)
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
        .id(theme)                    // Farbthema gewechselt: alles neu zeichnen
        .ignoresSafeArea()
        .onExitCommand(perform: nav.stack.count > 1 ? { leave() } : nil)
        .alert("Fernhilfe starten?", isPresented: $help.asking) {
            Button("Erlauben") { help.start() }
            Button("Nein, danke", role: .cancel) {}
        } message: {
            Text("Der Support von ImperumTV sieht dann ein Bild von ImperumTV auf deinem Bildschirm und kann die App mit einfachen Befehlen bedienen (z. B. Zurück, Live TV öffnen, Pause). Andere Apps bleiben unberührt. Die Fernhilfe endet nach spätestens 60 Minuten – oder wenn du sie beendest.")
        }
        .alert("Fernhilfe läuft", isPresented: $help.askingStop) {
            Button("Fernhilfe beenden", role: .destructive) { help.stop(tell: true) }
            Button("Weiter laufen lassen", role: .cancel) {}
        } message: {
            Text("Dein Code: \(help.codeText)" + (help.viewer ? "\nDer Support sieht gerade deinen Bildschirm." : ""))
        }
        .alert(help.message ?? "", isPresented: Binding(get: { help.message != nil }, set: { if !$0 { help.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task {
            guard !started else { return }
            started = true
            // Player: Ersatzsender, Adressen, Hänger melden, Schlaf-Timer
            engine.altProvider = { [weak store] it in store?.alternatives(it) ?? [] }
            engine.urlProvider = { [weak store] it in store?.url(it, .live) }
            engine.onStall = { it, what in Report.stall(it.name, what) }
            engine.onSleep = { [weak nav] in nav?.reset(.home) }
            help.nav = nav; help.engine = engine; help.store = store
            if !TVStore.testMode { help.resume() }
            await store.start()
            // Neue Folgen bei Favoriten und angefangenen Serien
            let src = store.sourceName
            let favIds = store.series.filter { store.isFav($0, .series) }.map(\.id)
            let resIds = resume.list(source: src).filter { $0.kind == "series" }.map(\.itemId)
            Task { await store.checkNewEpisodes(Array(Set(favIds + resIds))) }
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
        case .football: FootballScreen()
        case .movieDetail(let m): MovieDetailScreen(movie: m)
        case .continueWatching: ContinueScreen()
        case .profiles: ProfilesScreen()
        case .nettest: NetTestScreen()
        case .lockCats: LockCatsScreen()
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
        case "player", "player2", "player3", "player4":
            nav.reset(.home); nav.push(.movies)
            let n = s == "player" ? 0 : (Int(s.dropFirst(6)) ?? 1) - 1
            if store.vod.indices.contains(n), case let it = store.vod[n], let u = store.url(it, .movie) {
                engine.play(u, item: it, kind: .movie, fallback: store.altURL(it))
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
        case "football": nav.reset(.home); nav.push(.football)
        case "profiles": nav.reset(.home); nav.push(.profiles)
        case "moviedetail": if let m = store.vod.first { nav.reset(.home); nav.push(.movies); nav.push(.movieDetail(m)) }
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
