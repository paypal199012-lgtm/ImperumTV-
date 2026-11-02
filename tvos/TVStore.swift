import Foundation
import SwiftUI

// MARK: - Daten für die Oberfläche

struct TVCat: Identifiable, Hashable {
    let id: String
    let name: String
}

enum Art: Hashable {
    case none
    case url(URL)
    case demo(String, UInt32)

    static func from(_ s: String?) -> Art {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              s.lowercased().hasPrefix("http"), let u = URL(string: s) else { return .none }
        return .url(u)
    }
}

enum MediaKind: String, Hashable { case live, movie, series }

struct TVItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let cat: String
    let art: Art
    var rating: Double = 0
    var year: Int? = nil
    var ext: String = "mp4"
    var added: Int = 0
}

// MARK: - Demo (freie Testvideos, wie auf Android)

enum DemoData {
    static let films = "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/"
    static let liveCats = [TVCat(id: "1", name: "Demo Live"), TVCat(id: "2", name: "Demo Kino")]
    static let live: [TVItem] = [
        TVItem(id: 1, name: "Demo 1 · Big Buck Bunny", cat: "1", art: .demo("Big Buck Bunny", 0x3f7d3a)),
        TVItem(id: 2, name: "Demo 2 · Testbild", cat: "1", art: .demo("Testbild", 0x2f5f9e)),
        TVItem(id: 3, name: "Demo 3 · Tears of Steel", cat: "2", art: .demo("Tears of Steel", 0x8a3b3b))
    ]
    static let liveURLs: [Int: String] = [
        1: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
        2: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
        3: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8"
    ]
    static let vodCats = [TVCat(id: "10", name: "Blender Open Movies")]
    static let vod: [TVItem] = [
        TVItem(id: 101, name: "Big Buck Bunny (2008)", cat: "10", art: .demo("Big Buck Bunny", 0x5b8c2a), rating: 7.5, year: 2008),
        TVItem(id: 102, name: "Elephants Dream (2006)", cat: "10", art: .demo("Elephants Dream", 0x6b4a8a), rating: 6.6, year: 2006),
        TVItem(id: 103, name: "Sintel (2010)", cat: "10", art: .demo("Sintel", 0x9a5a2a), rating: 7.4, year: 2010),
        TVItem(id: 104, name: "Tears of Steel (2012)", cat: "10", art: .demo("Tears of Steel", 0x3a5f7a), rating: 6.0, year: 2012)
    ]
    static let vodFiles: [Int: String] = [101: "BigBuckBunny.mp4", 102: "ElephantsDream.mp4", 103: "Sintel.mp4", 104: "TearsOfSteel.mp4"]
    static let seriesCats = [TVCat(id: "20", name: "Demo-Serien")]
    static let series: [TVItem] = [
        TVItem(id: 201, name: "Blender Open Movies", cat: "20", art: .demo("Blender Open Movies", 0x7a5a1a), rating: 7.2)
    ]

    static func episodes() -> [Episode] {
        vod.enumerated().compactMap { i, m in
            guard let file = vodFiles[m.id], let u = URL(string: films + file) else { return nil }
            let title = m.name.replacingOccurrences(of: #"\s*\(\d{4}\)"#, with: "", options: .regularExpression)
            return Episode(id: String(301 + i), season: 1, number: i + 1, title: title, url: u, image: nil)
        }
    }

    static func epg() -> [EPGEntry] {
        let now = Date().timeIntervalSince1970
        let start = floor(now / 1800) * 1800
        return (0..<8).map { i in
            EPGEntry(title: "Demo-Programm \(i + 1)",
                     start: Date(timeIntervalSince1970: start + Double(i) * 1800),
                     end: Date(timeIntervalSince1970: start + Double(i + 1) * 1800),
                     desc: "Freies Testvideo zum Ausprobieren von ImperumTV.")
        }
    }
}

// MARK: - Wiedergabelisten, Sender, Filme, Serien

@MainActor
final class TVStore: ObservableObject {
    enum Source: Equatable {
        case none
        case demo
        case xtream(Account, String)
    }

    @Published var source: Source = .none
    @Published var liveCats: [TVCat] = []
    @Published var live: [TVItem] = []
    @Published var vodCats: [TVCat] = []
    @Published var vod: [TVItem] = []
    @Published var seriesCats: [TVCat] = []
    @Published var series: [TVItem] = []
    @Published var loading = false
    @Published var loadingText = ""
    @Published var message: String?
    @Published var lists: [RemotePlaylist] = []
    @Published var listsLoaded = false
    @Published var favorites: Set<String>
    @Published var expiry: Date?

    let device: (mac: String, key: String)
    static let userAgent = "ImperumTV/1.0 (AppleTV)"
    static let env = ProcessInfo.processInfo.environment
    static var testMode: Bool { env["IMPTV_TEST"] == "1" }

    init() {
        device = DeviceIdentity.load()
        favorites = Set(UserDefaults.standard.stringArray(forKey: "tv.favs") ?? [])
    }

    var hasSource: Bool { source != .none }

    var sourceName: String {
        switch source {
        case .none: return ""
        case .demo: return "Demo"
        case .xtream(_, let n): return n
        }
    }

    var savedId: String { UserDefaults.standard.string(forKey: "tv.playlist") ?? "" }

    /// Beim Start: Gerät anmelden, Wiedergabelisten holen, zuletzt benutzte öffnen
    func start() async {
        if Self.testMode { useDemo(); return }
        await refreshLists()
        let saved = savedId
        if saved == "demo" { useDemo(); return }
        if let l = lists.first(where: { $0.id == saved }) ?? (lists.count == 1 ? lists.first : nil) {
            await use(l)
        }
    }

    func refreshLists() async {
        try? await RemoteAPI.register(mac: device.mac, key: device.key)
        if let l = try? await RemoteAPI.playlists(mac: device.mac, key: device.key) { lists = l }
        listsLoaded = true
    }

    func useDemo() {
        UserDefaults.standard.set("demo", forKey: "tv.playlist")
        source = .demo
        message = nil
        liveCats = DemoData.liveCats; live = DemoData.live
        vodCats = DemoData.vodCats; vod = DemoData.vod
        seriesCats = DemoData.seriesCats; series = DemoData.series
        expiry = nil
    }

    func use(_ l: RemotePlaylist) async {
        guard let acc = l.account else {
            message = "Diese Wiedergabeliste ist ein reiner M3U-Link. Auf dem Apple TV gehen bisher nur Xtream-Zugänge (Server, Benutzer, Passwort)."
            return
        }
        UserDefaults.standard.set(l.id, forKey: "tv.playlist")
        source = .xtream(acc, l.name)
        await load(acc)
    }

    func reload() async {
        switch source {
        case .demo: useDemo()
        case .xtream(let acc, _): await load(acc)
        case .none: await refreshLists()
        }
    }

    private func client(_ acc: Account) -> XtreamAPI { XtreamAPI(account: acc, userAgent: Self.userAgent) }

    func load(_ acc: Account) async {
        loading = true
        loadingText = "Sender werden geladen …"
        message = nil
        defer { loading = false }
        let api = client(acc)
        do {
            let auth = try await api.authenticate()
            expiry = auth.expiry
            let cats = try await api.categories("get_live_categories")
            let streams = try await api.liveStreams()
            liveCats = cats.map { TVCat(id: $0.id, name: $0.name) }
            live = streams.map { TVItem(id: $0.streamId, name: $0.name, cat: $0.categoryId ?? "", art: Art.from($0.icon)) }
        } catch {
            message = "Die Wiedergabeliste konnte nicht geladen werden: \(error.localizedDescription)"
            return
        }
        loadingText = "Filme und Serien werden geladen …"
        let tVc = Task { try? await api.categories("get_vod_categories") }
        let tVs = Task { try? await api.vodStreams() }
        let tSc = Task { try? await api.categories("get_series_categories") }
        let tSs = Task { try? await api.series() }
        let vc = await tVc.value ?? [], vs = await tVs.value ?? []
        let sc = await tSc.value ?? [], ss = await tSs.value ?? []
        vodCats = vc.map { TVCat(id: $0.id, name: $0.name) }
        vod = vs.map { TVItem(id: $0.streamId, name: $0.name, cat: $0.categoryId ?? "", art: Art.from($0.icon),
                              rating: $0.rating, year: $0.year, ext: $0.ext, added: $0.added) }
        seriesCats = sc.map { TVCat(id: $0.id, name: $0.name) }
        series = ss.map { TVItem(id: $0.seriesId, name: $0.name, cat: $0.categoryId ?? "", art: Art.from($0.cover),
                                 rating: $0.rating, year: $0.year, added: $0.added) }
    }

    // MARK: Adressen und Programm

    func url(_ item: TVItem, _ kind: MediaKind) -> URL? {
        switch source {
        case .demo:
            if kind == .live { return DemoData.liveURLs[item.id].flatMap { URL(string: $0) } }
            return DemoData.vodFiles[item.id].flatMap { URL(string: DemoData.films + $0) }
        case .xtream(let acc, _):
            let a = client(acc)
            switch kind {
            case .live: return a.streamURL(id: item.id)
            case .movie: return a.movieURL(id: item.id, ext: item.ext)
            case .series: return nil
            }
        case .none:
            return nil
        }
    }

    private var epgCache: [Int: (Date, [EPGEntry])] = [:]

    func epg(_ item: TVItem) async -> [EPGEntry] {
        switch source {
        case .demo: return DemoData.epg()
        case .xtream(let acc, _):
            if let c = epgCache[item.id], Date().timeIntervalSince(c.0) < 600 { return c.1 }
            let list = (try? await client(acc).shortEPG(streamId: item.id, limit: 6)) ?? []
            epgCache[item.id] = (Date(), list)
            return list
        case .none: return []
        }
    }

    func episodes(_ s: TVItem) async -> [Episode] {
        switch source {
        case .demo: return DemoData.episodes()
        case .xtream(let acc, _): return (try? await client(acc).seriesEpisodes(seriesId: s.id)) ?? []
        case .none: return []
        }
    }

    // MARK: Favoriten

    func favKey(_ item: TVItem, _ kind: MediaKind) -> String { "\(sourceName)|\(kind.rawValue):\(item.id)" }
    func isFav(_ item: TVItem, _ kind: MediaKind) -> Bool { favorites.contains(favKey(item, kind)) }
    func toggleFav(_ item: TVItem, _ kind: MediaKind) {
        let k = favKey(item, kind)
        if favorites.contains(k) { favorites.remove(k) } else { favorites.insert(k) }
        UserDefaults.standard.set(Array(favorites), forKey: "tv.favs")
    }

    func items(_ kind: MediaKind) -> [TVItem] {
        switch kind { case .live: return live; case .movie: return vod; case .series: return series }
    }
    func cats(_ kind: MediaKind) -> [TVCat] {
        switch kind { case .live: return liveCats; case .movie: return vodCats; case .series: return seriesCats }
    }
}
