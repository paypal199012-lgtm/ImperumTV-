import Foundation

struct Channel: Identifiable, Hashable {
    let id: Int
    let name: String
    let url: URL
    let logo: URL?
    let group: String?
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
