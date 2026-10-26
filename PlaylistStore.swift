import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    // Eingaben im Anmeldebildschirm
    @Published var serverInput = ""
    @Published var username = ""
    @Published var password = ""
    @Published var userAgent = ""

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var infoMessage: String?
    @Published var showSetup = false

    private let defaults = UserDefaults.standard
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("channels.json")

        serverInput = defaults.string(forKey: "server") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        password = Keychain.load("password") ?? ""
        userAgent = defaults.string(forKey: "userAgent") ?? ""
        favorites = Set(defaults.stringArray(forKey: "favorites") ?? [])
        infoMessage = defaults.string(forKey: "info")

        Task { await restoreCache() }
    }

    // MARK: - Abgeleitete Werte

    var userAgentValue: String {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "IPTVPlayer/2.0" : trimmed
    }

    var groups: [String] {
        Array(Set(channels.compactMap(\.group))).sorted()
    }

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

    // MARK: - Laden

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
            let info = try await api.authenticate()
            let categories = try await api.liveCategories()
            let streams = try await api.liveStreams()

            let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let list: [Channel] = streams.compactMap { s in
                guard let url = api.streamURL(id: s.streamId) else { return nil }
                let logo = s.icon.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                return Channel(
                    id: s.streamId,
                    name: s.name.isEmpty ? "Sender \(s.streamId)" : s.name,
                    url: url,
                    logo: logo,
                    group: s.categoryId.flatMap { names[$0] }
                )
            }

            if list.isEmpty {
                errorMessage = "Anmeldung klappt, aber der Server liefert keine Live-Sender."
                return
            }

            defaults.set(account.server, forKey: "server")
            defaults.set(account.username, forKey: "username")
            defaults.set(userAgent, forKey: "userAgent")
            defaults.set("xtream", forKey: "kind")
            defaults.set(info, forKey: "info")
            Keychain.save(account.password, for: "password")
            infoMessage = info
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

    private func loadM3UText(kind: String, link: String, fetch: () async throws -> String) async {
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
            defaults.set(kind, forKey: "kind")
            defaults.set(link, forKey: "m3uLink")
            defaults.set(userAgent, forKey: "userAgent")
            defaults.removeObject(forKey: "info")
            infoMessage = nil
            apply(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        if defaults.string(forKey: "kind") == "m3u", let link = defaults.string(forKey: "m3uLink") {
            await loadM3U(link: link)
        } else {
            await login()
        }
    }

    func logout() {
        channels = []
        infoMessage = nil
        errorMessage = nil
        password = ""
        Keychain.save("", for: "password")
        for key in ["server", "username", "kind", "m3uLink", "info"] {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: cacheURL)
        showSetup = false
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
