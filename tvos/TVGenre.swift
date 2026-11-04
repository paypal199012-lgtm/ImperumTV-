import Foundation
import SwiftUI

// MARK: - Genres (wie Android): Angabe des Anbieters + Name der Kategorie + was in den Details stand

enum GenreMask {
    /// Reihenfolge = Bit-Nummer (wie auf Android, damit es überall gleich ist)
    static let names = ["Action", "Abenteuer", "Animation", "Komödie", "Krimi", "Dokumentation", "Drama", "Familie & Kinder", "Fantasy", "Geschichte",
                        "Horror", "Musik", "Mystery", "Liebesfilm", "Science-Fiction", "Thriller", "Krieg", "Western", "Sport"]
    static let horrorBit = 1 << 10

    private static let patterns: [NSRegularExpression] = [
        "[^a-z](action)[^a-z]", "[^a-z](adventure|abenteuer|aventure|avventura)", "[^a-z](animation|animiert|zeichentrick|cartoon|anime|animat)",
        "[^a-z](comedy|komodie|komoedie|comedie|commedia|comedia|komedi)", "[^a-z](crime|krimi|kriminal|polar|policier)",
        "[^a-z](documentar|dokumentar|doku|documentaire|docu)", "[^a-z](drama|drame)[^a-z]", "[^a-z](family|familie|famille|kids|kinder|children|enfant)",
        "[^a-z](fantasy|fantastique|fantasie)", "[^a-z](history|historie|geschicht|historisch|histoire|historical)", "[^a-z](horror|horreur|terror)[^a-z]",
        "[^a-z](music|musik|musical|musique)", "[^a-z](mystery|mystere|mysterium)", "[^a-z](romance|romantik|romantisch|liebe|love|romantic|romant)",
        "[^a-z](science.?fiction|sci.?fi|scifi|s\\.f\\.)|[^a-z]sf[^a-z]", "[^a-z](thriller)", "[^a-z](war|krieg|kriegsfilm|guerre|guerra)[^a-z]",
        "[^a-z](western)", "[^a-z](sport)"
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Horror steht bei Serien fast nie im Genre: an der Beschreibung erkennen
    private static let horrorPlot = try! NSRegularExpression(
        pattern: "(zombie|vampir|werw[oö]lf|werewol|d[äa]mon|demon|exorz|exorcis|spuk|besessen|possess|untote|undead|poltergeist|okkult|occult|haunt|horror)",
        options: [.caseInsensitive])

    static func mask(_ text: String?) -> Int {
        guard let text = text, !text.isEmpty else { return 0 }
        var t = " " + text.lowercased() + " "
        for (a, b) in [("à", "a"), ("á", "a"), ("â", "a"), ("è", "e"), ("é", "e"), ("ê", "e"), ("ö", "o"), ("ü", "u"), ("ä", "a")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        let r = NSRange(t.startIndex..., in: t)
        var m = 0
        for (i, re) in patterns.enumerated() where re.firstMatch(in: t, range: r) != nil { m |= 1 << i }
        return m
    }

    static func horror(_ plot: String?) -> Bool {
        guard let p = plot, !p.isEmpty else { return false }
        return horrorPlot.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil
    }

    /// Genre-Text + Horror aus der Beschreibung
    static func mask(_ genre: String?, plot: String?) -> Int { mask(genre) | (horror(plot) ? horrorBit : 0) }
}

/// Gelernte Genres je Wiedergabeliste und „Genres sammeln“ im Hintergrund (eine Abfrage pro Sekunde, nur Filme)
@MainActor
final class GenreBook: ObservableObject {
    static let shared = GenreBook()

    /// zählt hoch, wenn sich die Genres sichtbar geändert haben (höchstens alle 30 s – spart Neuzeichnen)
    @Published private(set) var version = 0
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private var learned: [String: Int] = [:]
    private var learnedFor = ""
    private var catCache: [String: Int] = [:]
    private var dirty = 0
    private var lastPublish = Date.distantPast
    private var saveTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var pos = -1
    private var listCount = -1
    private var countAt = Date.distantPast
    private var fails = 0
    private var failId = -1
    private var failCount = 0
    private var pauseUntil = Date.distantPast
    private var reported = false
    private var countMemo: (key: String, counts: [Int])?

    var on: Bool {
        get { UserDefaults.standard.object(forKey: "tv.genreScan") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.genreScan"); objectWillChange.send() }
    }

    // MARK: Speicher (Caches – auf dem Apple TV ist UserDefaults klein; geht der Cache verloren, wird neu gesammelt)

    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }
    private func file(_ key: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("genres-" + key + ".json")
    }

    func use(_ source: String) {
        let k = Self.stableHash(source)
        guard k != learnedFor else { return }
        flush()
        learnedFor = k
        catCache = [:]
        countMemo = nil
        pos = -1; listCount = -1
        learned = [:]
        if let f = file(k), let d = try? Data(contentsOf: f), let l = try? JSONDecoder().decode([String: Int].self, from: d) { learned = l }
        version += 1
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard dirty > 0, !learnedFor.isEmpty, let f = file(learnedFor), let d = try? JSONEncoder().encode(learned) else { return }
        dirty = 0
        try? d.write(to: f, options: .atomic)
    }

    private func save() {
        dirty += 1
        if dirty >= 300 { flush(); return }
        if saveTask == nil {
            saveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                self?.saveTask = nil
                self?.flush()
            }
        }
    }

    private func idKey(_ kind: MediaKind, _ id: Int) -> String { (kind == .movie ? "m" : "s") + String(id) }
    func known(_ kind: MediaKind, _ id: Int) -> Bool { learned[idKey(kind, id)] != nil }

    /// Aus den Details gelernt (Film- oder Serienseite, „Genres sammeln“)
    func learn(_ kind: MediaKind, _ id: Int, genre: String?, plot: String?, quiet: Bool = false) {
        let m = GenreMask.mask(genre, plot: plot)
        let k = idKey(kind, id)
        if learned[k] == m { return }
        learned[k] = m
        countMemo = nil
        save()
        // sichtbar machen: sofort auf der Detailseite, beim Sammeln höchstens alle 30 s
        if !quiet || Date().timeIntervalSince(lastPublish) > 30 { lastPublish = Date(); version += 1 }
    }

    // MARK: Genres eines Eintrags

    func mask(_ it: TVItem, _ kind: MediaKind, _ store: TVStore) -> Int {
        let ck = kind.rawValue + "|" + it.cat
        let cm: Int
        if let c = catCache[ck] { cm = c } else { cm = GenreMask.mask(store.catName(kind, it.cat)); catCache[ck] = cm }
        return it.g | cm | (learned[idKey(kind, it.id)] ?? 0)
    }

    /// Anzahl je Genre (für die linke Spalte)
    func counts(_ kind: MediaKind, _ items: [TVItem], _ store: TVStore) -> [Int] {
        let key = "\(kind.rawValue)|\(learnedFor)|\(items.count)|\(items.first?.id ?? 0)|\(version)"
        if let m = countMemo, m.key == key { return m.counts }
        var c = Array(repeating: 0, count: GenreMask.names.count)
        for it in items {
            let m = mask(it, kind, store)
            if m == 0 { continue }
            for i in 0..<c.count where m & (1 << i) != 0 { c[i] += 1 }
        }
        countMemo = (key, c)
        return c
    }

    // MARK: Genres sammeln

    /// „wird ergänzt 34 %“ – leer, wenn fertig oder aus
    var progressText: String {
        guard on, total > 0, done < total else { return "" }
        return "\(done * 100 / total) %"
    }

    var status: String {
        if !on { return "Aus" }
        if total == 0 { return "An · wartet auf die Listen" }
        if done >= total { return "An · fertig" }
        return "An · \(done * 100 / total) %" + (Date() < pauseUntil ? " · Pause" : "")
    }

    private func count(_ list: [TVItem]) {
        var todo = 0
        for it in list where learned[idKey(.movie, it.id)] == nil { todo += 1 }
        total = list.count
        done = list.count - todo
    }

    /// Nächster Film ohne Genre-Prüfung (läuft rückwärts durch die Liste, die neuesten stehen meist hinten)
    private func next(_ list: [TVItem]) -> Int? {
        if list.isEmpty { total = 0; return nil }
        if listCount != list.count { listCount = list.count; pos = list.count - 1; countAt = .distantPast }
        if Date().timeIntervalSince(countAt) > 30 { count(list); countAt = Date() }
        for _ in 0..<list.count {
            if pos < 0 { pos = list.count - 1 }
            let it = list[pos]; pos -= 1
            if learned[idKey(.movie, it.id)] == nil { return it.id }
        }
        done = total
        return nil
    }

    func start(_ store: TVStore) {
        guard scanTask == nil, !TVStore.testMode else { return }
        scanTask = Task { [weak self, weak store] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, let store = store else { return }
                guard self.on, Date() >= self.pauseUntil, case .xtream(let acc, _) = store.source, !store.loading else { continue }
                self.use(store.sourceName)
                guard let id = self.next(store.vod) else {
                    self.flush()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continue
                }
                do {
                    let info = try await XtreamAPI(account: acc, userAgent: TVStore.userAgent).vodInfo(vodId: id)
                    self.fails = 0
                    self.learn(.movie, id, genre: info.genre, plot: info.plot, quiet: true)
                    self.done = min(self.total, self.done + 1)
                } catch {
                    // derselbe Film 3× kaputt → überspringen; 5 Fehler hintereinander → 10 Minuten Pause
                    self.failCount = self.failId == id ? self.failCount + 1 : 1
                    self.failId = id
                    if self.failCount >= 3 { self.learn(.movie, id, genre: nil, plot: nil, quiet: true) }
                    self.fails += 1
                    if self.fails >= 5 {
                        self.fails = 0
                        self.pauseUntil = Date().addingTimeInterval(600)
                        if !self.reported {
                            self.reported = true
                            Report.send("fehler", "Genres sammeln (Apple TV): 5 Fehler hintereinander (\(error.localizedDescription)) – 10 Minuten Pause")
                        }
                    } else {
                        self.pauseUntil = Date().addingTimeInterval(15)
                    }
                }
            }
        }
    }
}
