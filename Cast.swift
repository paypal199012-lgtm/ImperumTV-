import SwiftUI

// MARK: - Besetzung mit Fotos (kostenlos von Wikipedia)

enum People {
    /// Namen aus "A, B, C" (ohne Doppelte, höchstens max)
    static func names(_ text: String, max: Int = 12) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;\n/|"))
        for raw in parts {
            var n = raw.replacingOccurrences(of: #"\(.*?\)"#, with: " ", options: .regularExpression)
            n = n.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = n.lowercased()
            guard n.count >= 3, n.count <= 40, !seen.contains(lower) else { continue }
            seen.insert(lower)
            out.append(n)
            if out.count >= max { break }
        }
        return out
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first.map { String($0.prefix(1)) } ?? ""
        let last = parts.count > 1 ? String(parts[parts.count - 1].prefix(1)) : ""
        return (first + last).uppercased()
    }
}

/// Sucht Fotos von Schauspielern und merkt sie sich
actor PeoplePhotos {
    static let shared = PeoplePhotos()

    private var cache: [String: String] = (UserDefaults.standard.dictionary(forKey: "peoplePhotos") as? [String: String]) ?? [:]
    private var running: [String: Task<String?, Never>] = [:]

    /// Foto-Adresse oder nil
    func photo(for name: String) async -> URL? {
        if let hit = cache[name] { return hit.isEmpty ? nil : URL(string: hit) }
        let task: Task<String?, Never>
        if let existing = running[name] {
            task = existing
        } else {
            task = Task { await PeoplePhotos.find(name) }
            running[name] = task
        }
        let result = await task.value
        running[name] = nil
        guard let found = result else { return nil }   // Netzwerkfehler: nächstes Mal neu versuchen
        cache[name] = found
        if cache.count > 800 { cache = [:] }
        UserDefaults.standard.set(cache, forKey: "peoplePhotos")
        return found.isEmpty ? nil : URL(string: found)
    }

    /// "" = Person ohne Foto, nil = Fehler
    private static func find(_ name: String) async -> String? {
        let german = await lookup(name, lang: "de")
        if let g = german, !g.isEmpty { return g }
        let english = await lookup(name, lang: "en")
        if let e = english { return e }
        return german
    }

    private struct Summary: Decodable {
        struct Thumb: Decodable { let source: String }
        let type: String?
        let description: String?
        let extract: String?
        let thumbnail: Thumb?
    }

    private static let jobs = "schauspiel|darsteller|actor|actress|regisseur|director|komiker|comedian|moderator|presenter|sänger|singer|rapper|musiker|musician|model|synchronsprecher|voice|filmemacher|filmmaker|drehbuch|screenwriter|wrestler|sportler|fußball|boxer|kabarettist|entertainer|tänzer|dancer|youtuber|influencer|autor|writer"

    private static func lookup(_ name: String, lang: String) async -> String? {
        let path = name.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return "" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("ImperumTV/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 { return "" }
            guard http.statusCode == 200 else { return nil }
            guard let s = try? JSONDecoder().decode(Summary.self, from: data), s.type == "standard" else { return "" }
            let text = (s.description ?? "") + " " + String((s.extract ?? "").prefix(200))
            guard text.range(of: jobs, options: [.regularExpression, .caseInsensitive]) != nil else { return "" }
            return s.thumbnail?.source ?? ""
        } catch {
            return nil
        }
    }
}

/// Runder Kopf mit Foto (oder Anfangsbuchstaben) und Name
struct ActorBubble: View {
    let name: String
    var size: CGFloat = 70

    @State private var photo: URL?

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                Text(People.initials(name))
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(Theme.gold)
                if let photo = photo {
                    AsyncImage(url: photo) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.gold.opacity(0.45), lineWidth: 1.5))

            Text(name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: size + 18)
        }
        .task(id: name) {
            photo = await PeoplePhotos.shared.photo(for: name)
        }
    }
}

/// „Besetzung“ als waagerechte Reihe zum Wischen
struct CastSection: View {
    let names: [String]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Besetzung")
                .font((compact ? Font.caption : Font.subheadline).weight(.semibold))
                .foregroundStyle(Theme.goldLight)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: compact ? 8 : 12) {
                    ForEach(names, id: \.self) { name in
                        ActorBubble(name: name, size: compact ? 52 : 72)
                    }
                }
            }
        }
    }
}
