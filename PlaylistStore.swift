import Foundation

@MainActor
final class PlaylistStore: ObservableObject {
    @Published var playlistURL: String
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var showSetup = false

    private let cacheURL: URL

    init() {
        playlistURL = UserDefaults.standard.string(forKey: "url") ?? ""

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("playlist.m3u")

        Task { await restoreCache() }
    }

    /// Zuletzt geladene Playlist sofort wieder anzeigen
    private func restoreCache() async {
        let url = cacheURL
        let parsed: [Channel] = await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return M3UParser.parse(text)
        }.value
        if channels.isEmpty { channels = parsed }
    }

    func loadFromURL() async {
        let trimmed = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = "Bitte eine gültige URL mit http:// oder https:// eingeben."
            return
        }
        UserDefaults.standard.set(trimmed, forKey: "url")

        await load {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 IPTVPlayer/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PlaylistError.http(http.statusCode)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func loadFromFile(_ fileURL: URL) async {
        await load {
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func load(_ fetch: () async throws -> String) async {
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
            try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
            channels = parsed
            showSetup = false
        } catch {
            errorMessage = "Laden fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

enum PlaylistError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        }
    }
}
