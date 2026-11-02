import SwiftUI

// MARK: - Weiterschauen (Filme und Serien merken sich die Stelle, wie auf Android)

struct TVResumeEntry: Codable, Identifiable, Hashable {
    var key: String            // „Liste|movie:101“ bzw. „Liste|series:201“
    var kind: String           // movie / series
    var itemId: Int
    var name: String
    var cat: String
    var art: String?           // Bildadresse
    var demoTitle: String?
    var demoColor: UInt32?
    var episode: Int?          // Folge (Index in der sortierten Folgenliste)
    var episodeTitle: String?
    var pos: Double
    var dur: Double
    var at: Double
    var id: String { key }

    var part: Double { dur > 0 ? min(max(pos / dur, 0), 1) : 0 }

    var item: TVItem {
        let a: Art = art.flatMap { URL(string: $0) }.map { .url($0) }
            ?? (demoTitle.map { .demo($0, demoColor ?? 0x444444) } ?? .none)
        return TVItem(id: itemId, name: name, cat: cat, art: a)
    }

    var subtitle: String {
        let left = max(1, Int(((dur - pos) / 60).rounded()))
        if let t = episodeTitle { return "\(t) · noch \(left) Min." }
        return "Noch \(left) Min."
    }
}

@MainActor
final class ResumeBook: ObservableObject {
    @Published private(set) var entries: [TVResumeEntry] = []
    /// Gesehene Filme und Folgen („Liste|movie:101“, „Liste|ep:301“)
    @Published private(set) var seen: Set<String> = []
    /// Profil (jedes Profil hat eigene Stände)
    private var profile = ""
    private var storeKey: String { "tv.resume" + profile }
    private var seenKey: String { "tv.seen" + profile }

    init() { setProfile(Profiles.currentId) }

    func setProfile(_ p: String) {
        profile = p == "p0" ? "" : "." + p
        entries = []
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let l = try? JSONDecoder().decode([TVResumeEntry].self, from: d) { entries = l }
        seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }

    func isSeen(_ source: String, movie id: Int) -> Bool { seen.contains("\(source)|movie:\(id)") }
    func isSeen(_ source: String, episode id: String) -> Bool { seen.contains("\(source)|ep:\(id)") }
    func toggleSeen(_ source: String, movie id: Int) {
        let k = "\(source)|movie:\(id)"
        if seen.contains(k) { seen.remove(k) } else { seen.insert(k); entries.removeAll { $0.key == "\(source)|movie:\(id)" } }
        persist()
    }
    func clearAll() { entries = []; seen = []; persist() }

    func list(source: String) -> [TVResumeEntry] {
        entries.filter { $0.key.hasPrefix(source + "|") }.sorted { $0.at > $1.at }
    }

    func entry(_ source: String, _ kind: MediaKind, _ id: Int) -> TVResumeEntry? {
        entries.first { $0.key == "\(source)|\(kind.rawValue):\(id)" }
    }

    /// Stand speichern (unter 30 s nichts; fast zu Ende = gesehen, Eintrag weg – bei Serien zur nächsten Folge)
    func save(source: String, kind: MediaKind, item: TVItem, pos: Double, dur: Double, episode: Int? = nil,
              episodeTitle: String? = nil, episodeCount: Int = 0, episodeId: String? = nil) {
        guard kind != .live, dur > 60 else { return }
        if pos / dur > 0.9 {
            seen.insert(kind == .series ? "\(source)|ep:\(episodeId ?? "")" : "\(source)|movie:\(item.id)")
        }
        let key = "\(source)|\(kind.rawValue):\(item.id)"
        entries.removeAll { $0.key == key }
        var e = TVResumeEntry(key: key, kind: kind.rawValue, itemId: item.id, name: item.name, cat: item.cat,
                              art: nil, demoTitle: nil, demoColor: nil, episode: episode, episodeTitle: episodeTitle,
                              pos: pos, dur: dur, at: Date().timeIntervalSince1970)
        switch item.art {
        case .url(let u): e.art = u.absoluteString
        case .demo(let t, let c): e.demoTitle = t; e.demoColor = c
        case .none: break
        }
        if pos / dur > 0.95 {
            // fertig geschaut: bei Serien die nächste Folge vormerken
            guard kind == .series, let ep = episode, ep + 1 < episodeCount else { persist(); return }
            e.episode = ep + 1; e.episodeTitle = "Nächste Folge"; e.pos = 0
        } else if pos < 30 && kind == .movie {
            persist(); return
        }
        entries.insert(e, at: 0)
        if entries.count > 60 { entries.removeLast(entries.count - 60) }
        persist()
    }

    func remove(_ e: TVResumeEntry) {
        entries.removeAll { $0.key == e.key }
        persist()
    }
}

/// Weiterschauen: alle angefangenen Filme und Serien
struct ContinueScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook

    var body: some View {
        let list = resume.list(source: store.sourceName)
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Weiterschauen")
            Text("OK: weiterschauen · lange drücken: entfernen").font(UI.font(24)).foregroundColor(UI.muted)
                .place(1100, 44, 570, 34, alignment: .topTrailing)
            ScrollView(.vertical, showsIndicators: false) {
                if list.isEmpty {
                    Text("Noch nichts angefangen.").font(UI.font(28)).foregroundColor(UI.muted).padding(40)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(400), spacing: 34), count: 4), alignment: .leading, spacing: 30) {
                    ForEach(list) { e in
                        Button { open(e) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ArtView(art: e.item.art, poster: true)
                                    .frame(width: 380, height: 214).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .bottom) {
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                Rectangle().fill(.white.opacity(0.25))
                                                Rectangle().fill(UI.gold2).frame(width: g.size.width * e.part)
                                            }
                                        }
                                        .frame(height: 6)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(e.name).font(UI.font(26, .semibold)).lineLimit(1)
                                Text(e.subtitle).font(UI.font(21)).foregroundColor(UI.muted).lineLimit(1)
                            }
                            .padding(10)
                        }
                        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 14)), scale: 1.04))
                        .contextMenu { Button("Aus Weiterschauen entfernen") { resume.remove(e) } }
                    }
                }
                .padding(30)
            }
            .place(40, 110, 1840, 970)
        }
        .frame(width: 1920, height: 1080)
    }

    private func open(_ e: TVResumeEntry) {
        if e.kind == "series" { nav.push(.seriesDetail(e.item)); return }
        if let it = store.vod.first(where: { $0.id == e.itemId }) { nav.push(.movieDetail(it)) }
        else { nav.push(.movieDetail(e.item)) }
    }
}
