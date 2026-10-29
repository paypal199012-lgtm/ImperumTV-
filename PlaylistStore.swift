import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    // Eingaben im Anmeldebildschirm
    @Published var serverInput = ""
    @Published var username = ""
    @Published var password = ""
    @Published var userAgent = "" {
        didSet { UserDefaults.standard.set(userAgent, forKey: "userAgent") }
    }

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var movies: [Channel] = []
    @Published private(set) var seriesList: [SeriesItem] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var moviesLoading = false
    @Published private(set) var seriesLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var sectionError: String?
    @Published private(set) var infoMessage: String?
    @Published private(set) var expiry: Date?
    @Published private(set) var kind = ""
    @Published var showSetup = false

    // Website: MAC-Adresse, Geräte-Schlüssel, Wiedergabelisten, Testphase
    let deviceMAC: String
    let deviceKey: String
    @Published private(set) var remoteLists: [RemotePlaylist]?
    @Published private(set) var remoteError: String?
    @Published private(set) var registered = false
    @Published private(set) var license: LicenseState?
    @Published private(set) var started = false
    @Published private(set) var connectingId: String?
    @Published private(set) var playlistId: String?
    private var watcher: Task<Void, Never>?

    private var epgCache: [Int: [EPGEntry]] = [:]
    /// Ausführliches Programm für das EPG-Raster (10 Minuten zwischengespeichert)
    var fullEPGCache: [Int: (at: Date, list: [EPGEntry])] = [:]
    /// „Weiterschauen“: gespeicherte Stände von Filmen und Serien
    @Published var resumeList: [ResumeEntry] = []
    let defaults = UserDefaults.standard
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("channels.json")

        let identity = DeviceIdentity.load()
        deviceMAC = identity.mac
        deviceKey = identity.key
        Parental.shared.deviceMAC = identity.mac
        Parental.shared.deviceKey = identity.key
        license = LicenseState.loadSaved()
        playlistId = defaults.string(forKey: "playlistId")

        serverInput = defaults.string(forKey: "server") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        password = Keychain.load("password") ?? ""
        userAgent = defaults.string(forKey: "userAgent") ?? ""
        favorites = Set(defaults.stringArray(forKey: "favorites") ?? [])
        infoMessage = defaults.string(forKey: "info")
        kind = defaults.string(forKey: "kind") ?? ""
        let exp = defaults.double(forKey: "expiry")
        expiry = exp > 0 ? Date(timeIntervalSince1970: exp) : nil

        if let data = defaults.data(forKey: "resume"),
           let list = try? JSONDecoder().decode([ResumeEntry].self, from: data) {
            resumeList = list
        }

        Task { await restoreCache() }
    }

    // MARK: - Abgeleitete Werte

    var isXtream: Bool { kind == "xtream" }

    var userAgentValue: String {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "IPTVPlayer/3.0" : trimmed
    }

    var expiryText: String? {
        guard let expiry = expiry else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: expiry)
    }

    var currentAPI: XtreamAPI? {
        guard isXtream, !serverInput.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
        return XtreamAPI(
            account: Account(server: serverInput, username: username, password: password),
            userAgent: userAgentValue
        )
    }

    static func nameMap(_ categories: [CategoryDTO]) -> [String: String] {
        Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    static func url(_ s: String?) -> URL? {
        guard let s = s, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // MARK: - Website: Gerät, Wiedergabelisten, Testphase

    var macText: String { deviceMAC.lowercased() }

    /// Link für den QR-Code und „Website öffnen“ (MAC-Adresse und Schlüssel sind schon ausgefüllt)
    var deviceLink: URL? {
        URL(string: RemoteConfig.website + "?mac=\(macText)&key=\(deviceKey)")
    }

    var websiteURL: URL? { URL(string: RemoteConfig.website) }

    /// Noch nie geprüft (z. B. neues Gerät ohne Internet) zählt als aktiv
    var isLicenseActive: Bool { license?.isActive ?? true }

    var isTrial: Bool { license?.isTrial ?? false }

    var licenseText: String {
        if let license = license { return license.text }
        if registered { return "Dein Gerät ist angemeldet." }
        return remoteError == nil ? "Gerät wird angemeldet …" : "Gerät noch nicht verbunden."
    }

    /// Lädt Testphase und Wiedergabelisten von der Website
    @discardableResult
    func loadRemote() async -> Bool {
        let wasActive = isLicenseActive
        do {
            if !registered {
                do {
                    try await RemoteAPI.register(mac: deviceMAC, key: deviceKey)
                    registered = true
                } catch {
                    // Wird beim nächsten Mal erneut versucht
                }
            }
            if let state = try await RemoteAPI.status(mac: deviceMAC, key: deviceKey) {
                license = state
                state.save()
                Parental.shared.onStatus(state.parentalReset)
            }
            let lists = try await RemoteAPI.playlists(mac: deviceMAC, key: deviceKey)
            if lists != remoteLists { remoteLists = lists }
            remoteError = nil
            if !wasActive && isLicenseActive {
                // Gerade bezahlt oder freigeschaltet: mit der letzten Liste weitermachen
                Task { await self.resumeAfterActivation() }
            }
            return true
        } catch {
            remoteError = error.localizedDescription
            if remoteLists == nil { remoteLists = [] }
            return false
        }
    }

    /// Mit einer Wiedergabeliste von der Website verbinden
    func connect(_ playlist: RemotePlaylist) async {
        guard isLicenseActive else { return }
        guard let account = playlist.account else {
            errorMessage = "Diese Wiedergabeliste wird nicht unterstützt. Nötig sind Server, Benutzername und Passwort oder ein Link mit get.php?username=…&password=…"
            return
        }
        let previous = (serverInput, username, password)
        serverInput = account.server
        username = account.username
        password = account.password
        connectingId = playlist.id
        await login()
        connectingId = nil
        if errorMessage == nil {
            playlistId = playlist.id
            defaults.set(playlist.id, forKey: "playlistId")
        } else {
            (serverInput, username, password) = previous
        }
    }

    private var storedAccount: Account {
        Account(server: serverInput, username: username, password: password)
    }

    /// Beim Start: Website fragen, dann die zuletzt genutzte Liste öffnen
    func startup() async {
        guard !started else { return }
        let online = await loadRemote()
        if online && isLicenseActive {
            let lists = remoteLists ?? []
            if let id = playlistId, let playlist = lists.first(where: { $0.id == id }), let account = playlist.account {
                if channels.isEmpty || account != storedAccount || !isXtream {
                    await connect(playlist)
                }
            } else if playlistId != nil && !lists.isEmpty {
                errorMessage = "Die zuletzt genutzte Wiedergabeliste gibt es nicht mehr. Bitte wähle eine aus."
                showSetup = true
            } else if playlistId == nil {
                // Noch keine Liste von der Website gewählt (auch nach dem Update von der alten Version)
                showSetup = true
            }
        }
        started = true

        // Läuft die Testphase während der Nutzung ab: alle 10 Minuten nachsehen
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await self.loadRemote()
            }
        }
    }

    private func resumeAfterActivation() async {
        guard let id = playlistId, let playlist = (remoteLists ?? []).first(where: { $0.id == id }) else {
            showSetup = true
            return
        }
        if channels.isEmpty { await connect(playlist) }
    }

    // MARK: - Favoriten

    func isFavorite(_ channel: Channel) -> Bool {
        favorites.contains(channel.key)
    }

    func toggleFavorite(_ channel: Channel) {
        if favorites.contains(channel.key) {
            favorites.remove(channel.key)
        } else {
            favorites.insert(channel.key)
        }
        defaults.set(Array(favorites), forKey: "favorites")
    }

    func isFavoriteSeries(_ series: SeriesItem) -> Bool {
        favorites.contains("series:\(series.id)")
    }

    func toggleFavoriteSeries(_ series: SeriesItem) {
        let key = "series:\(series.id)"
        if favorites.contains(key) {
            favorites.remove(key)
        } else {
            favorites.insert(key)
        }
        defaults.set(Array(favorites), forKey: "favorites")
    }

    // MARK: - Anmeldung und Live-TV

    /// Anmeldung per Xtream-Zugangsdaten (oder kompletter Anbieter-Link)
    func login() async {
        let account: Account
        if let parsed = Account.parse(link: serverInput) {
            account = parsed
        } else {
            account = Account(
                server: Account.normalizeServer(serverInput),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard !account.server.isEmpty, URL(string: account.server)?.host != nil else {
            errorMessage = "Bitte Server oder kompletten Link eingeben."
            return
        }
        guard !account.username.isEmpty, !account.password.isEmpty else {
            errorMessage = "Bitte Benutzername und Passwort eingeben."
            return
        }

        serverInput = account.server
        username = account.username
        password = account.password

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let api = XtreamAPI(account: account, userAgent: userAgentValue)
            let auth = try await api.authenticate()
            let names = Self.nameMap(try await api.categories("get_live_categories"))
            let streams = try await api.liveStreams()

            let list = streams.compactMap { s -> Channel? in
                guard let url = api.streamURL(id: s.streamId) else { return nil }
                return Channel(
                    id: s.streamId,
                    name: s.name.isEmpty ? "Sender \(s.streamId)" : s.name,
                    url: url,
                    logo: Self.url(s.icon),
                    group: s.categoryId.flatMap { names[$0] }
                )
            }

            if list.isEmpty {
                errorMessage = "Anmeldung klappt, aber der Server liefert keine Live-Sender."
                return
            }

            defaults.set(account.server, forKey: "server")
            defaults.set(account.username, forKey: "username")
            defaults.set("xtream", forKey: "kind")
            defaults.set("Status: \(auth.status)", forKey: "info")
            defaults.set(auth.expiry?.timeIntervalSince1970 ?? 0, forKey: "expiry")
            Keychain.save(account.password, for: "password")

            kind = "xtream"
            expiry = auth.expiry
            infoMessage = "Status: \(auth.status)"
            movies = []
            seriesList = []
            epgCache = [:]
            apply(list)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Einfachen M3U-Link laden (ohne Xtream-Anmeldung)
    func loadM3U(link: String) async {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = "Bitte einen gültigen Link mit http:// oder https:// eingeben."
            return
        }
        let ua = userAgentValue
        await loadM3UText(kind: "m3u", link: trimmed) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.http(http.statusCode, XtreamAPI.snippet(data))
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func loadFile(_ fileURL: URL) async {
        await loadM3UText(kind: "file", link: "") {
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func loadM3UText(kind newKind: String, link: String, fetch: () async throws -> String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let text = try await fetch()
            let parsed = await Task.detached(priority: .userInitiated) {
                M3UParser.parse(text)
            }.value

            if parsed.isEmpty {
                errorMessage = "Keine Kanäle gefunden. Ist das eine gültige M3U-Playlist?"
                return
            }
            defaults.set(newKind, forKey: "kind")
            defaults.set(link, forKey: "m3uLink")
            defaults.removeObject(forKey: "info")
            defaults.removeObject(forKey: "expiry")
            kind = newKind
            infoMessage = nil
            expiry = nil
            movies = []
            seriesList = []
            apply(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        epgCache = [:]
        if kind == "m3u", let link = defaults.string(forKey: "m3uLink") {
            await loadM3U(link: link)
        } else if isXtream {
            await login()
        }
    }

    func logout() {
        channels = []
        movies = []
        seriesList = []
        epgCache = [:]
        infoMessage = nil
        errorMessage = nil
        expiry = nil
        kind = ""
        password = ""
        Keychain.save("", for: "password")
        for key in ["server", "username", "kind", "m3uLink", "info", "expiry"] {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: cacheURL)
        showSetup = false
    }

    // MARK: - Filme und Serien

    func loadMoviesIfNeeded(force: Bool = false) async {
        guard let api = currentAPI, !moviesLoading, force || movies.isEmpty else { return }
        moviesLoading = true
        sectionError = nil
        defer { moviesLoading = false }

        do {
            let names = Self.nameMap(try await api.categories("get_vod_categories"))
            let streams = try await api.vodStreams()
            movies = streams.compactMap { s -> Channel? in
                guard let url = api.movieURL(id: s.streamId, ext: s.ext) else { return nil }
                return Channel(
                    id: s.streamId,
                    name: s.name.isEmpty ? "Film \(s.streamId)" : s.name,
                    url: url,
                    logo: Self.url(s.icon),
                    group: s.categoryId.flatMap { names[$0] },
                    year: s.year,
                    added: s.added
                )
            }
            if movies.isEmpty { sectionError = "Dein Anbieter liefert keine Filme." }
        } catch {
            sectionError = error.localizedDescription
        }
    }

    func loadSeriesIfNeeded(force: Bool = false) async {
        guard let api = currentAPI, !seriesLoading, force || seriesList.isEmpty else { return }
        seriesLoading = true
        sectionError = nil
        defer { seriesLoading = false }

        do {
            let names = Self.nameMap(try await api.categories("get_series_categories"))
            let list = try await api.series()
            seriesList = list.map { s in
                SeriesItem(
                    id: s.seriesId,
                    name: s.name.isEmpty ? "Serie \(s.seriesId)" : s.name,
                    cover: Self.url(s.cover),
                    group: s.categoryId.flatMap { names[$0] },
                    added: s.added
                )
            }
            if seriesList.isEmpty { sectionError = "Dein Anbieter liefert keine Serien." }
        } catch {
            sectionError = error.localizedDescription
        }
    }

    func seriesDetails(_ seriesId: Int) async throws -> (episodes: [Episode], info: MediaInfo) {
        guard let api = currentAPI else { throw APIError.unexpected("") }
        return try await api.seriesDetails(seriesId: seriesId)
    }

    func movieInfo(_ vodId: Int) async -> MediaInfo? {
        guard let api = currentAPI else { return nil }
        return try? await api.vodInfo(vodId: vodId)
    }

    func seriesEpisodes(_ seriesId: Int) async throws -> [Episode] {
        guard let api = currentAPI else { throw APIError.unexpected("") }
        return try await api.seriesEpisodes(seriesId: seriesId)
    }

    /// Aktuelle und nächste Sendungen eines Live-Senders (zwischengespeichert)
    func shortEPG(streamId: Int) async -> [EPGEntry] {
        if let cached = epgCache[streamId] { return cached }
        guard let api = currentAPI else { return [] }
        let list = (try? await api.shortEPG(streamId: streamId)) ?? []
        let now = Date()
        let upcoming = list.filter { ($0.end ?? .distantFuture) > now }
        epgCache[streamId] = upcoming
        return upcoming
    }

    // MARK: - Zwischenspeicher

    private func apply(_ list: [Channel]) {
        channels = list
        showSetup = false
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Zuletzt geladene Senderliste sofort wieder anzeigen
    private func restoreCache() async {
        let url = cacheURL
        let cached: [Channel] = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([Channel].self, from: data) else { return [] }
            return list
        }.value
        if channels.isEmpty { channels = cached }
    }
}
