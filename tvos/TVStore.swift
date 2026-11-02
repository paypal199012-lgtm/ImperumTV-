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
    /// Zweite Quelle, falls der Google-Speicher ablehnt (z. B. 403 über VPN)
    static let alt: [Int: String] = [
        101: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
        102: "https://archive.org/download/ElephantsDream/ed_1024_512kb.mp4",
        103: "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8",
        104: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8"
    ]
    static let seriesCats = [TVCat(id: "20", name: "Demo-Serien")]
    static let series: [TVItem] = [
        TVItem(id: 201, name: "Blender Open Movies", cat: "20", art: .demo("Blender Open Movies", 0x7a5a1a), rating: 7.2)
    ]

    static let info: [Int: (plot: String, genre: String, min: Int, dir: String)] = [
        101: ("Ein freundliches Riesenkaninchen nimmt es mit drei frechen Nagern auf. Kurzfilm der Blender Foundation (CC BY 3.0).", "Animation · Komödie", 10, "Sacha Goedegebure"),
        102: ("Zwei Männer erkunden eine seltsame, mechanische Welt. Der erste offene Film der Blender Foundation (CC BY 2.5).", "Animation · Sci-Fi", 11, "Bassam Kurdali"),
        103: ("Eine junge Frau sucht ihren kleinen Drachen. Kurzfilm der Blender Foundation (CC BY 3.0).", "Animation · Fantasy", 15, "Colin Levy"),
        104: ("Eine Gruppe von Wissenschaftlern versucht in Amsterdam, die Welt vor Robotern zu retten. Blender Foundation (CC BY 3.0).", "Sci-Fi", 12, "Ian Hubert")
    ]

    static func episodes() -> [Episode] {
        vod.enumerated().compactMap { i, m in
            guard let file = vodFiles[m.id], let u = URL(string: alt[m.id] ?? films + file) else { return nil }
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
        case m3u(String, String)          // Name, Adresse
    }

    /// M3U: Adressen und Serienfolgen (die Liste liefert sie direkt)
    private var m3uURLs: [Int: URL] = [:]
    private var m3uEpisodes: [Int: [Episode]] = [:]

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
    nonisolated static let userAgent = "ImperumTV/1.0 (AppleTV)"
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static var testMode: Bool { env["IMPTV_TEST"] == "1" }

    /// Serien mit neuen Folgen (seit dem letzten Öffnen)
    @Published var newEpisodes: Set<Int> = []
    /// ändert sich beim Entsperren der Kindersicherung (Listen neu zeichnen)
    @Published var unlockTick = 0
    private var favKeyName: String { Profiles.currentId == "p0" ? "tv.favs" : "tv.favs." + Profiles.currentId }

    init() {
        device = DeviceIdentity.load()
        favorites = []
        favorites = Set(UserDefaults.standard.stringArray(forKey: favKeyName) ?? [])
    }

    func setProfile(_ id: String) {
        favorites = Set(UserDefaults.standard.stringArray(forKey: favKeyName) ?? [])
        unlockTick += 1
    }

    func clearFavorites() {
        favorites = []
        UserDefaults.standard.set([String](), forKey: favKeyName)
    }

    /// Adresse für den Verbindungstest (Server der Wiedergabeliste)
    var serverTestURL: URL? {
        switch source {
        case .xtream(let acc, _): return XtreamAPI(account: acc, userAgent: Self.userAgent).accountURL
        case .m3u(_, let link): return URL(string: link)
        default: return nil
        }
    }

    // MARK: Live-Format (HLS oder TS), ausgeblendete Sender

    var liveExt: String {
        get { UserDefaults.standard.string(forKey: "tv.liveExt") ?? "m3u8" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.liveExt"); objectWillChange.send() }
    }

    private var hiddenKey: String { Profiles.currentId == "p0" ? "tv.hidden" : "tv.hidden." + Profiles.currentId }
    var hidden: Set<String> { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
    func isHidden(_ it: TVItem) -> Bool { hidden.contains("\(sourceName)|\(it.id)") }
    func hide(_ it: TVItem) {
        var h = hidden; h.insert("\(sourceName)|\(it.id)")
        UserDefaults.standard.set(Array(h), forKey: hiddenKey); unlockTick += 1
    }
    func unhideAll() { UserDefaults.standard.set([String](), forKey: hiddenKey); unlockTick += 1 }

    // MARK: Kindersicherung

    func catName(_ kind: MediaKind, _ id: String) -> String { cats(kind).first { $0.id == id }?.name ?? "" }
    func catLocked(_ kind: MediaKind, _ id: String) -> Bool { Parental.enabled && Parental.locked(kind, catName(kind, id)) }
    func catHidden(_ kind: MediaKind, _ id: String) -> Bool { Profiles.isKids && Parental.protected(kind, catName(kind, id)) }

    /// Kategorien ohne die im Kinderprofil versteckten
    func visibleCats(_ kind: MediaKind) -> [TVCat] {
        guard Parental.enabled else { return cats(kind) }
        return cats(kind).filter { !Profiles.isKids || !Parental.protected(kind, $0.name) }
    }

    /// Einträge ohne gesperrte Kategorien
    func visible(_ kind: MediaKind) -> [TVItem] {
        if kind == .live {
            let h = hidden
            if !h.isEmpty {
                let src = sourceName
                let base = Parental.enabled ? visibleLocked(kind) : items(kind)
                return base.filter { !h.contains("\(src)|\($0.id)") }
            }
        }
        return visibleLocked(kind)
    }

    private func visibleLocked(_ kind: MediaKind) -> [TVItem] {
        guard Parental.enabled else { return items(kind) }
        let blocked = Set(cats(kind).filter { Parental.locked(kind, $0.name) }.map(\.id))
        if blocked.isEmpty { return items(kind) }
        return items(kind).filter { !blocked.contains($0.cat) }
    }

    func unlock() {
        Parental.unlockedUntil = Date().addingTimeInterval(3600)
        unlockTick += 1
    }

    // MARK: Neue Folgen (Favoriten und angefangene Serien)

    private func epCountKey(_ id: Int) -> String { "tv.epc.\(sourceName).\(id)" }

    /// Beim Öffnen einer Serie: aktuelle Folgenanzahl merken
    func markSeriesOpened(_ s: TVItem, count: Int) {
        UserDefaults.standard.set(count, forKey: epCountKey(s.id))
        newEpisodes.remove(s.id)
    }

    func checkNewEpisodes(_ ids: [Int]) async {
        var out: Set<Int> = []
        for id in ids.prefix(25) {
            guard let s = series.first(where: { $0.id == id }) else { continue }
            let known = UserDefaults.standard.integer(forKey: epCountKey(id))
            let n = await episodes(s).count
            if known == 0 { UserDefaults.standard.set(n, forKey: epCountKey(id)) }
            else if n > known { out.insert(id) }
        }
        newEpisodes = out
    }

    var hasSource: Bool { source != .none }

    var sourceName: String {
        switch source {
        case .none: return ""
        case .demo: return "Demo"
        case .xtream(_, let n): return n
        case .m3u(let n, _): return n
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
            let link = (l.m3u.isEmpty ? l.server : l.m3u).trimmingCharacters(in: .whitespaces)
            guard !link.isEmpty else { message = "Diese Wiedergabeliste hat keine Adresse."; return }
            UserDefaults.standard.set(l.id, forKey: "tv.playlist")
            source = .m3u(l.name, link)
            await loadM3U(link)
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
        case .m3u(_, let link): await loadM3U(link)
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

    // MARK: M3U-Liste (ohne Xtream-Zugang)

    func loadM3U(_ link: String) async {
        loading = true
        loadingText = "Wiedergabeliste wird geladen …"
        message = nil
        defer { loading = false }
        guard let u = URL(string: link) else { message = "Die Adresse der Wiedergabeliste ist ungültig."; return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 90
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let text: String
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            if let h = r as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                message = "Der Server der Wiedergabeliste antwortet mit Fehler \(h.statusCode)."; return
            }
            text = String(decoding: d, as: UTF8.self)
        } catch {
            message = "Die Wiedergabeliste konnte nicht geladen werden: \(error.localizedDescription)"; return
        }
        loadingText = "Sender werden sortiert …"
        let parsed = await Task.detached { M3UParser.parse(text) }.value
        if parsed.isEmpty { message = "In der Wiedergabeliste wurden keine Sender gefunden."; return }

        var lCats: [String: String] = [:], vCats: [String: String] = [:], sCats: [String: String] = [:]
        var lOrder: [String] = [], vOrder: [String] = [], sOrder: [String] = []
        var l: [TVItem] = [], v: [TVItem] = [], ser: [TVItem] = []
        var urls: [Int: URL] = [:]
        var eps: [Int: [Episode]] = [:]
        var seriesIds: [String: Int] = [:]
        let epRe = try! NSRegularExpression(pattern: #"^(.*?)[\s._-]*S(\d{1,2})[\s._-]*E(\d{1,3})"#, options: [.caseInsensitive])
        func catId(_ g: String, _ map: inout [String: String], _ order: inout [String]) -> String {
            if let id = map[g] { return id }
            let id = String(map.count + 1); map[g] = id; order.append(g); return id
        }
        var nextId = 1
        for ch in parsed {
            let path = ch.url.path.lowercased()
            let ext = ch.url.pathExtension.lowercased()
            let group = ch.group ?? "Ohne Kategorie"
            let art = ch.logo.map { Art.url($0) } ?? .none
            let isSeries = path.contains("/series/")
            let isMovie = path.contains("/movie/") || (!isSeries && ["mp4", "mkv", "avi", "mov", "m4v", "wmv"].contains(ext))
            if isSeries {
                let ns = ch.name as NSString
                var title = ch.name, season = 1, number = 1
                if let m = epRe.firstMatch(in: ch.name, range: NSRange(location: 0, length: ns.length)) {
                    title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    season = Int(ns.substring(with: m.range(at: 2))) ?? 1
                    number = Int(ns.substring(with: m.range(at: 3))) ?? 1
                }
                if title.isEmpty { title = ch.name }
                let sid: Int
                if let e = seriesIds[title] { sid = e } else {
                    sid = nextId; nextId += 1; seriesIds[title] = sid
                    ser.append(TVItem(id: sid, name: title, cat: catId(group, &sCats, &sOrder), art: art))
                }
                eps[sid, default: []].append(Episode(id: String(nextId), season: season, number: number,
                                                     title: ch.name, url: ch.url, image: ch.logo))
                nextId += 1
            } else if isMovie {
                let id = nextId; nextId += 1
                urls[id] = ch.url
                v.append(TVItem(id: id, name: ch.name, cat: catId(group, &vCats, &vOrder), art: art,
                                year: VodStreamDTO.yearFromName(ch.name), ext: ext.isEmpty ? "mp4" : ext))
            } else {
                let id = nextId; nextId += 1
                urls[id] = ch.url
                l.append(TVItem(id: id, name: ch.name, cat: catId(group, &lCats, &lOrder), art: art))
            }
        }
        m3uURLs = urls
        m3uEpisodes = eps
        liveCats = lOrder.map { TVCat(id: lCats[$0]!, name: $0) }
        vodCats = vOrder.map { TVCat(id: vCats[$0]!, name: $0) }
        seriesCats = sOrder.map { TVCat(id: sCats[$0]!, name: $0) }
        live = l; vod = v; series = ser
        expiry = nil
    }

    // MARK: Adressen und Programm

    /// Ersatzadresse (nur Demo-Filme)
    func altURL(_ item: TVItem) -> URL? {
        source == .demo ? DemoData.vodFiles[item.id].flatMap { URL(string: DemoData.films + $0) } : nil
    }

    func url(_ item: TVItem, _ kind: MediaKind) -> URL? {
        switch source {
        case .demo:
            if kind == .live { return DemoData.liveURLs[item.id].flatMap { URL(string: $0) } }
            if let a = DemoData.alt[item.id] { return URL(string: a) }
            return DemoData.vodFiles[item.id].flatMap { URL(string: DemoData.films + $0) }
        case .xtream(let acc, _):
            let a = client(acc)
            switch kind {
            case .live:
                guard let u = a.streamURL(id: item.id) else { return nil }
                return liveExt == "ts" ? u.deletingPathExtension().appendingPathExtension("ts") : u
            case .movie: return a.movieURL(id: item.id, ext: item.ext)
            case .series: return nil
            }
        case .m3u:
            return m3uURLs[item.id]
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
        case .m3u, .none: return []
        }
    }

    private var infoCache: [Int: MediaInfo] = [:]

    func clearCache() {
        epgCache = [:]; infoCache = [:]
        URLCache.shared.removeAllCachedResponses()
    }

    func movieInfo(_ m: TVItem) async -> MediaInfo? {
        switch source {
        case .demo:
            guard let d = DemoData.info[m.id] else { return nil }
            var i = MediaInfo()
            i.plot = d.plot; i.genre = d.genre; i.duration = "\(d.min) Min."; i.director = d.dir
            i.year = m.year.map { String($0) }; i.score = m.rating
            return i
        case .xtream(let acc, _):
            if let c = infoCache[m.id] { return c }
            let i = try? await client(acc).vodInfo(vodId: m.id)
            if let i = i { infoCache[m.id] = i }
            return i
        case .m3u, .none: return nil
        }
    }

    /// Folgen und Beschreibung einer Serie
    func seriesDetails(_ s: TVItem) async -> (episodes: [Episode], info: MediaInfo?) {
        switch source {
        case .demo:
            var i = MediaInfo()
            i.plot = "Die freien Kurzfilme der Blender Foundation als Serie – zum Testen von Staffeln, Folgen und „Nächste Folge“."
            i.genre = "Animation"; i.year = "2006"
            return (DemoData.episodes(), i)
        case .xtream(let acc, _):
            if let r = try? await client(acc).seriesDetails(seriesId: s.id) { return (r.episodes, r.info) }
            return ([], nil)
        case .m3u: return (m3uEpisodes[s.id] ?? [], nil)
        case .none: return ([], nil)
        }
    }

    /// Länge einer Demo-Folge in Minuten (echte Listen liefern das nicht immer)
    func episodeMinutes(_ e: Episode) -> Int? {
        guard source == .demo, let n = Int(e.id) else { return nil }
        return DemoData.info[DemoData.vod[(n - 301) % DemoData.vod.count].id]?.min
    }

    func episodes(_ s: TVItem) async -> [Episode] {
        switch source {
        case .demo: return DemoData.episodes()
        case .xtream(let acc, _): return (try? await client(acc).seriesEpisodes(seriesId: s.id)) ?? []
        case .m3u: return m3uEpisodes[s.id] ?? []
        case .none: return []
        }
    }

    // MARK: Ersatzsender (wie Android: derselbe Sender in einer anderen Variante, nur dasselbe Land)

    private static let qualityWords: Set<String> = ["hd", "fhd", "uhd", "4k", "8k", "sd", "hq", "raw", "hevc", "h265", "h264", "x265",
        "50fps", "60fps", "fps", "backup", "bkp", "alt", "multi", "audio", "1080p", "720p", "1080", "720", "plus", "+", "vip", "premium", "orig"]
    private static let weakWords: Set<String> = ["mobile", "low", "lq", "sd"]

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" }).map(String.init)
    }

    /// Land aus dem Namen („DE: …“, „DE | …“) oder der Kategorie
    private func country(_ it: TVItem) -> String {
        let n = it.name.trimmingCharacters(in: .whitespaces)
        if let r = n.range(of: #"^[A-Za-z]{2,3}\s*[:|]"#, options: .regularExpression) {
            return n[r].filter { $0.isLetter }.uppercased()
        }
        let c = liveCats.first { $0.id == it.cat }?.name ?? ""
        if let r = c.range(of: #"^[A-Za-z]{2,3}(?=\s*[:|\-]|\s)"#, options: .regularExpression) { return String(c[r]).uppercased() }
        return ""
    }

    /// Name ohne Land und Qualitätsangaben: „DE: DAZN 1 FHD“ → „dazn 1“
    private func baseKey(_ it: TVItem) -> String {
        var n = it.name
        if let r = n.range(of: #"^[A-Za-z]{2,3}\s*[:|]"#, options: .regularExpression) { n.removeSubrange(r) }
        return Self.words(n).filter { !Self.qualityWords.contains($0) && !Self.weakWords.contains($0) }.joined(separator: " ")
    }

    func alternatives(_ it: TVItem) -> [TVItem] {
        let key = baseKey(it)
        guard key.count >= 2 else { return [] }
        let land = country(it)
        return live.filter { o in
            o.id != it.id && baseKey(o) == key && country(o) == land
                && !Self.words(o.name).contains(where: { Self.weakWords.contains($0) })
        }
    }

    // MARK: Favoriten

    func favKey(_ item: TVItem, _ kind: MediaKind) -> String { "\(sourceName)|\(kind.rawValue):\(item.id)" }
    func isFav(_ item: TVItem, _ kind: MediaKind) -> Bool { favorites.contains(favKey(item, kind)) }
    func toggleFav(_ item: TVItem, _ kind: MediaKind) {
        let k = favKey(item, kind)
        if favorites.contains(k) { favorites.remove(k) } else { favorites.insert(k) }
        UserDefaults.standard.set(Array(favorites), forKey: favKeyName)
    }

    func items(_ kind: MediaKind) -> [TVItem] {
        switch kind { case .live: return live; case .movie: return vod; case .series: return series }
    }
    func cats(_ kind: MediaKind) -> [TVCat] {
        switch kind { case .live: return liveCats; case .movie: return vodCats; case .series: return seriesCats }
    }
}
