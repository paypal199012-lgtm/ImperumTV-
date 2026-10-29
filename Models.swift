import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let url: URL
    let logo: URL?
    let group: String?
    /// Erscheinungsjahr (nur bei Filmen, falls bekannt)
    var year: Int? = nil
    /// Wann der Anbieter den Film hinzugefügt hat (für „Zuletzt hinzugefügt“)
    var added: Int? = nil

    /// Eindeutiger Schlüssel für Favoriten
    var key: String { url.absoluteString }
}

struct SeriesItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let cover: URL?
    let group: String?
    var added: Int = 0
}

struct Episode: Identifiable, Hashable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let url: URL
    let image: URL?

    var asChannel: Channel {
        Channel(id: Int(id) ?? number, name: title, url: url, logo: image, group: nil)
    }
}

struct EPGEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let start: Date?
    let end: Date?
    var desc: String? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var timeRange: String {
        guard let start = start else { return "" }
        let s = Self.timeFormatter.string(from: start)
        guard let end = end else { return s }
        return "\(s)–\(Self.timeFormatter.string(from: end))"
    }

    var progress: Double {
        guard let s = start, let e = end, e > s else { return 0 }
        return min(max(Date().timeIntervalSince(s) / e.timeIntervalSince(s), 0), 1)
    }
}

/// Zusatzinfos zu Filmen und Serien
struct MediaInfo {
    var plot: String?
    var genre: String?
    var year: String?
    var rating: String?
    var duration: String?
    var cast: String?
    var director: String?
    var backdrop: URL?
    var cover: URL?

    var metaLine: String {
        [year, duration, genre].compactMap { $0 }.joined(separator: " · ")
    }
}

enum Route: Hashable {
    case live, epg, epgList, vod, series, favorites, search, account, settings, resume
}

/// Was gerade abgespielt wird, damit sich Filme und Folgen den Stand merken
struct ResumeInfo: Hashable {
    enum Kind: String { case movie, episode }
    let kind: Kind
    /// Film-ID bzw. Folgen-ID
    let itemId: String
    var seriesId: Int? = nil
    var seriesName: String? = nil
    var seriesCover: URL? = nil
    var season: Int? = nil
    var number: Int? = nil

    static func movie(_ movie: Channel) -> ResumeInfo {
        ResumeInfo(kind: .movie, itemId: String(movie.id))
    }

    static func episode(_ ep: Episode, series: SeriesItem) -> ResumeInfo {
        ResumeInfo(kind: .episode, itemId: ep.id, seriesId: series.id, seriesName: series.name,
                   seriesCover: series.cover, season: ep.season, number: ep.number)
    }

    /// Schlüssel: pro Film bzw. pro Serie ein Eintrag
    var key: String {
        if kind == .episode, let sid = seriesId { return "series:\(sid)" }
        return "\(kind.rawValue):\(itemId)"
    }
}

/// Gespeicherter Stand „Weiterschauen“
struct ResumeEntry: Codable, Identifiable, Hashable {
    var acc: String
    var key: String
    var kind: String
    var itemId: String
    var name: String
    var logo: String?
    var url: String
    var pos: Double
    var dur: Double
    var at: Double
    var next: Bool
    var seriesId: Int?
    var seriesName: String?
    var season: Int?
    var number: Int?

    var id: String { key }
    var isEpisode: Bool { kind == "episode" }

    /// Fortschritt 0 … 1
    var part: Double { dur > 0 ? min(max(pos / dur, 0), 1) : 0 }

    var leftText: String {
        if next { return "Nächste Folge" }
        let minutes = max(1, Int(((dur - pos) / 60).rounded()))
        return "Noch \(minutes) Min."
    }

    var title: String {
        guard isEpisode else { return name }
        return "\(seriesName ?? name) · S\(season ?? 1) F\(number ?? 0)"
    }

    var channel: Channel? {
        guard let u = URL(string: url) else { return nil }
        return Channel(id: Int(itemId) ?? 0, name: name, url: u, logo: logo.flatMap { URL(string: $0) }, group: nil)
    }

    var info: ResumeInfo {
        ResumeInfo(kind: isEpisode ? .episode : .movie, itemId: itemId, seriesId: seriesId, seriesName: seriesName,
                   seriesCover: logo.flatMap { URL(string: $0) }, season: season, number: number)
    }
}

/// "1:05:09" bzw. "5:09"
func timeText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

struct Account: Equatable {
    var server: String
    var username: String
    var password: String

    static func normalizeServer(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Erkennt einen kompletten Anbieter-Link (…/get.php?username=…&password=…)
    static func parse(link: String) -> Account? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let host = comps.host,
              let user = comps.queryItems?.first(where: { $0.name == "username" })?.value,
              let pass = comps.queryItems?.first(where: { $0.name == "password" })?.value,
              !user.isEmpty, !pass.isEmpty else { return nil }

        var server = "\(comps.scheme ?? "http")://\(host)"
        if let port = comps.port { server += ":\(port)" }
        let basePath = comps.path.replacingOccurrences(of: "/get.php", with: "")
        if basePath != "/" { server += basePath }
        while server.hasSuffix("/") { server.removeLast() }
        return Account(server: server, username: user, password: pass)
    }
}

/// Liest M3U/M3U8-Playlists im Format #EXTINF:-1 tvg-logo="..." group-title="...",Name
enum M3UParser {
    static func parse(_ text: String) -> [Channel] {
        let attrRegex = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)
        var result: [Channel] = []
        var name: String?
        var logo: URL?
        var group: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                var attrs: [String: String] = [:]
                let ns = line as NSString
                for match in attrRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    attrs[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: match.range(at: 2))
                }
                if let l = attrs["tvg-logo"], !l.isEmpty { logo = URL(string: l) } else { logo = nil }
                if let g = attrs["group-title"], !g.isEmpty { group = g } else { group = nil }

                var title = ""
                if let comma = line.lastIndex(of: ",") {
                    title = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                }
                if title.isEmpty { title = attrs["tvg-name"] ?? "" }
                name = title.isEmpty ? nil : title
            } else if !line.hasPrefix("#") {
                if let url = URL(string: line) {
                    result.append(Channel(
                        id: result.count,
                        name: name ?? url.lastPathComponent,
                        url: url,
                        logo: logo,
                        group: group
                    ))
                }
                name = nil
                logo = nil
                group = nil
            }
        }
        return result
    }
}
