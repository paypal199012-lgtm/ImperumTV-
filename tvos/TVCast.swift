import SwiftUI

// MARK: - Besetzung mit Fotos (wie in der Android-App; Fotos kostenlos von Wikipedia)

enum CastNames {
    /// Namen aus „A, B, C“ (ohne Klammern, ohne Doppelte)
    static func parse(_ text: String?, max: Int = 8) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }
        var seen = Set<String>(), out: [String] = []
        for part in text.components(separatedBy: CharacterSet(charactersIn: ",;\n/|")) {
            var n = part.replacingOccurrences(of: "\\s*\\(.*?\\)\\s*", with: " ", options: .regularExpression)
            n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let k = n.lowercased()
            if n.count < 3 || n.count > 40 || seen.contains(k) { continue }
            seen.insert(k); out.append(n)
            if out.count >= max { break }
        }
        return out
    }

    static func initials(_ n: String) -> String {
        let p = n.split(separator: " ")
        let a = p.first.map { String($0.prefix(1)) } ?? ""
        let b = p.count > 1 ? String(p.last!.prefix(1)) : ""
        return (a + b).uppercased()
    }
}

/// Fotos der Personen: erst deutsche, dann englische Wikipedia. Gemerkt wird auch „kein Foto“ (leerer Text).
@MainActor
final class PeoplePhotos: ObservableObject {
    static let shared = PeoplePhotos()
    @Published private(set) var urls: [String: String]
    private var busy = Set<String>()
    private static let job = "schauspiel|darsteller|actor|actress|regisseur|director|komiker|comedian|moderator|presenter|sänger|singer|rapper|musiker|musician|model|synchronsprecher|voice|filmemacher|filmmaker|drehbuch|screenwriter|wrestler|sportler|kabarettist|entertainer|tänzer|dancer|autor|writer"

    private init() {
        urls = (UserDefaults.standard.dictionary(forKey: "tv.people") as? [String: String]) ?? [:]
    }

    func load(_ name: String) async {
        if urls[name] != nil || busy.contains(name) { return }
        busy.insert(name)
        var found: String?? = nil
        for lang in ["de", "en"] {
            let r = await Self.lookup(name, lang)
            if case .some(let v) = r { found = .some(v); break }
        }
        busy.remove(name)
        guard case .some(let v) = found else { urls[name] = ""; save(); return }
        urls[name] = v ?? ""
        save()
    }

    private func save() {
        if urls.count > 600 { urls = Dictionary(uniqueKeysWithValues: urls.suffix(400).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(urls, forKey: "tv.people")
    }

    /// nil = nicht gefunden · .some(nil) = Person ohne Foto · .some(url) = Foto
    private static func lookup(_ name: String, _ lang: String) async -> String?? {
        let title = name.replacingOccurrences(of: " ", with: "_")
        guard let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(enc)") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (j["type"] as? String) == "standard" else { return nil }
        let desc = ((j["description"] as? String) ?? "") + " " + String(((j["extract"] as? String) ?? "").prefix(200))
        guard desc.range(of: job, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let thumb = (j["thumbnail"] as? [String: Any])?["source"] as? String
        return .some(thumb)
    }
}

/// Reihe „Besetzung“ mit runden Fotos und Namen
struct CastRow: View {
    let names: [String]
    var photo: CGFloat = 84
    @ObservedObject private var photos = PeoplePhotos.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Besetzung").font(UI.font(24, .bold)).foregroundColor(UI.gold)
            HStack(alignment: .top, spacing: 16) {
                ForEach(names, id: \.self) { n in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Color(rgb: 0x2a2f38))
                            Text(CastNames.initials(n)).font(UI.font(photo * 0.33, .bold)).foregroundColor(UI.gold2)
                            if let u = photos.urls[n], !u.isEmpty, let url = URL(string: u) {
                                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
                            }
                        }
                        .frame(width: photo, height: photo)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(UI.tan(0.4), lineWidth: 2))
                        Text(n).font(UI.font(18)).foregroundColor(UI.text).lineLimit(2)
                            .multilineTextAlignment(.center).frame(width: photo + 44)
                    }
                }
            }
        }
        .task(id: names) { for n in names { await photos.load(n) } }
    }
}
