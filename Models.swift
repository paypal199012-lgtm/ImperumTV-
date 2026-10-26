import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let url: URL
    let logo: URL?
    let group: String?

    /// Eindeutiger Schlüssel für Favoriten
    var key: String { url.absoluteString }
}

struct SeriesItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let cover: URL?
    let group: String?
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
    case live, epg, vod, series, favorites, search, account, settings, multi
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
