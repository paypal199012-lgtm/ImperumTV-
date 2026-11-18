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
    // Für den Abgleich mit anderen Geräten (Format wie app.js): Dateiendung, Folgen-Nummer beim Anbieter, Staffel/Folge
    var ext: String? = nil
    var epId: String? = nil
    var season: Int? = nil
    var num: Int? = nil
    var epName: String? = nil
    var next: Bool? = nil
    var id: String { key }

    /// Folge in der sortierten Folgenliste: über die Folgen-Nummer (auch von anderen Geräten), sonst gemerkte Stelle
    func episodeIndex(in all: [Episode]) -> Int? {
        if let id = epId, let i = all.firstIndex(where: { $0.id == id }) { return i }
        if let e = episode, e < all.count { return e }
        return nil
    }

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
    /// Abgleich mit anderen Geräten: liefert (Zugangsdaten-Kennung, Listenname) der aktuellen Liste – nur Xtream-Listen
    var syncHost: (() -> (acc: String, source: String)?)?
    private var syncBusy = false
    private var syncLast = Date.distantPast
    private var syncTask: Task<Void, Never>?
    /// Wann etwas als gesehen markiert wurde (ms), entfernte Einträge („gelöscht um“), Stand je Liste
    private var seenAt: [String: Double] = [:]
    private var rdel: [String: Double] = [:]
    private var sdel: [String: Double] = [:]
    private var syncRev: [String: Int] = [:]
    private var syncDirty: [String: Bool] = [:]
    private var storeKey: String { "tv.resume" + profile }
    private var seenKey: String { "tv.seen" + profile }

    init() { setProfile(Profiles.currentId) }

    func setProfile(_ p: String) {
        profile = p == "p0" ? "" : "." + p
        entries = []
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let l = try? JSONDecoder().decode([TVResumeEntry].self, from: d) { entries = l }
        seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        loadSyncMeta()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }

    func isSeen(_ source: String, movie id: Int) -> Bool { seen.contains("\(source)|movie:\(id)") }
    func isSeen(_ source: String, episode id: String) -> Bool { seen.contains("\(source)|ep:\(id)") }
    func toggleSeen(_ source: String, movie id: Int) {
        let k = "\(source)|movie:\(id)"
        let now = Date().timeIntervalSince1970 * 1000
        if seen.contains(k) {
            seen.remove(k); seenAt[k] = nil; sdel[k] = now
        } else {
            seen.insert(k); seenAt[k] = now; sdel[k] = nil
            if entries.contains(where: { $0.key == k }) { rdel[k] = now }
            entries.removeAll { $0.key == k }
        }
        persist()
        markDirty(source)
    }
    func clearAll() {
        let now = Date().timeIntervalSince1970 * 1000
        for e in entries { rdel[e.key] = now }
        for k in seen { sdel[k] = now }
        let sources = Set(entries.map { $0.key.components(separatedBy: "|").first ?? "" } + seen.map { $0.components(separatedBy: "|").first ?? "" })
        entries = []; seen = []; seenAt = [:]
        persist()
        for s in sources where !s.isEmpty { markDirty(s) }
    }

    func list(source: String) -> [TVResumeEntry] {
        entries.filter { $0.key.hasPrefix(source + "|") }.sorted { $0.at > $1.at }
    }

    func entry(_ source: String, _ kind: MediaKind, _ id: Int) -> TVResumeEntry? {
        entries.first { $0.key == "\(source)|\(kind.rawValue):\(id)" }
    }

    /// Stand speichern (unter 30 s nichts; fast zu Ende = gesehen, Eintrag weg – bei Serien zur nächsten Folge)
    func save(source: String, kind: MediaKind, item: TVItem, pos: Double, dur: Double, episode: Int? = nil,
              episodeTitle: String? = nil, episodeCount: Int = 0, episodeId: String? = nil,
              season: Int? = nil, num: Int? = nil, epName: String? = nil,
              nextEp: (id: String, season: Int, num: Int, title: String)? = nil) {
        guard kind != .live, dur > 60 else { return }
        defer { markDirty(source) }
        if pos / dur > 0.9 {
            let sk = kind == .series ? "\(source)|ep:\(episodeId ?? "")" : "\(source)|movie:\(item.id)"
            if !seen.contains(sk) { seenAt[sk] = Date().timeIntervalSince1970 * 1000 }
            seen.insert(sk); sdel[sk] = nil
        }
        let key = "\(source)|\(kind.rawValue):\(item.id)"
        entries.removeAll { $0.key == key }
        var e = TVResumeEntry(key: key, kind: kind.rawValue, itemId: item.id, name: item.name, cat: item.cat,
                              art: nil, demoTitle: nil, demoColor: nil, episode: episode, episodeTitle: episodeTitle,
                              pos: pos, dur: dur, at: Date().timeIntervalSince1970)
        e.ext = item.ext
        if kind == .series { e.epId = episodeId; e.season = season; e.num = num; e.epName = epName; e.next = false }
        rdel[key] = nil
        switch item.art {
        case .url(let u): e.art = u.absoluteString
        case .demo(let t, let c): e.demoTitle = t; e.demoColor = c
        case .none: break
        }
        if pos / dur > 0.95 {
            // fertig geschaut: bei Serien die nächste Folge vormerken
            guard kind == .series, let ep = episode, ep + 1 < episodeCount else {
                if entries.contains(where: { $0.key == key }) { rdel[key] = Date().timeIntervalSince1970 * 1000 }
                persist(); return
            }
            e.episode = ep + 1; e.episodeTitle = "Nächste Folge"; e.pos = 0; e.next = true
            if let n = nextEp { e.epId = n.id; e.season = n.season; e.num = n.num; e.epName = n.title }
        } else if pos < 30 && kind == .movie {
            persist(); return
        }
        entries.insert(e, at: 0)
        if entries.count > 60 { entries.removeLast(entries.count - 60) }
        persist()
    }

    func remove(_ e: TVResumeEntry) {
        entries.removeAll { $0.key == e.key }
        rdel[e.key] = Date().timeIntervalSince1970 * 1000
        persist()
        markDirty(e.key.components(separatedBy: "|").first ?? "")
    }
}

// MARK: - Abgleich mit allen anderen Geräten (Fire TV, Android, iPhone, Windows, Samsung, LG)
// Gleiches Format und gleiche Regeln wie StateSync in app.js: { res, rdel, seen, sdel } je Zugangsdaten,
// neuerer Stand gewinnt, „gelöscht um …“ verhindert, dass Entferntes zurückkommt. Nur das Hauptprofil.

extension ResumeBook {
    private static let metaKey = "tv.sync.meta"

    fileprivate func loadSyncMeta() {
        guard profile.isEmpty else { seenAt = [:]; rdel = [:]; sdel = [:]; return }
        let m = UserDefaults.standard.dictionary(forKey: Self.metaKey) ?? [:]
        func dd(_ k: String) -> [String: Double] {
            var out: [String: Double] = [:]
            for (a, b) in (m[k] as? [String: Any]) ?? [:] { if let n = b as? NSNumber { out[a] = n.doubleValue } }
            return out
        }
        seenAt = dd("seenAt"); rdel = dd("rdel"); sdel = dd("sdel")
        syncRev = (m["rev"] as? [String: Int]) ?? [:]
        syncDirty = (m["dirty"] as? [String: Bool]) ?? [:]
        // Ältere „Gesehen“-Einträge ohne Zeit: ganz alt markieren (bleiben gesehen, verlieren gegen jede neue Änderung)
        for k in seen where seenAt[k] == nil { seenAt[k] = 1 }
    }

    private func saveSyncMeta() {
        guard profile.isEmpty else { return }
        UserDefaults.standard.set(["seenAt": seenAt, "rdel": rdel, "sdel": sdel, "rev": syncRev, "dirty": syncDirty], forKey: Self.metaKey)
    }

    fileprivate func markDirty(_ source: String) {
        guard profile.isEmpty, !source.isEmpty, source != "Demo" else { saveSyncMeta(); return }
        syncDirty[source] = true
        saveSyncMeta()
        syncSoon(force: true, delay: 20)          // während der Wiedergabe wird alle 10 s gespeichert: erst danach abgleichen
    }

    /// Abgleich anstoßen (Start, Startseite, App wieder vorn). Ohne force höchstens einmal pro Minute.
    func syncSoon(force: Bool = false, delay: Double = 1.5) {
        guard profile.isEmpty, syncHost != nil else { return }
        if !force && Date().timeIntervalSince(syncLast) < 60 { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    private static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) ?? 0 }
    private static func obj(_ o: [String: Any], _ k: String) -> [String: Any] { (o[k] as? [String: Any]) ?? [:] }
    private static func canon(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private static func ms(_ d: Double) -> Int64 { Int64(d.rounded()) }

    /// Wie StateSync.merge in app.js
    static func mergeState(_ L: [String: Any], _ R: [String: Any]) -> [String: Any] {
        var rd: [String: Double] = [:], sd: [String: Double] = [:]
        for o in [obj(L, "rdel"), obj(R, "rdel")] { for (k, v) in o { let n = num(v); if n > (rd[k] ?? 0) { rd[k] = n } } }
        for o in [obj(L, "sdel"), obj(R, "sdel")] { for (k, v) in o { let n = num(v); if n > (sd[k] ?? 0) { sd[k] = n } } }
        var res: [String: [String: Any]] = [:]
        for o in [obj(L, "res"), obj(R, "res")] {
            for (k, v) in o {
                guard let e = v as? [String: Any] else { continue }
                if let cur = res[k], num(e["at"]) <= num(cur["at"]) { continue }
                res[k] = e
            }
        }
        var rk = res.keys.filter { num(res[$0]?["at"]) > (rd[$0] ?? 0) }
        rk.sort { let a = num(res[$0]?["at"]), b = num(res[$1]?["at"]); return a != b ? a > b : $0 < $1 }
        var mres: [String: Any] = [:]
        for k in rk.prefix(40) { mres[k] = res[k] }
        var seen: [String: [String: Any]] = [:]
        for o in [obj(L, "seen"), obj(R, "seen")] {
            for (id, v) in o {
                guard let b = v as? [String: Any] else { continue }
                guard let a = seen[id] else { seen[id] = b; continue }
                let bWins = num(b["at"]) > num(a["at"])
                let win = bWins ? b : a, lose = bWins ? a : b
                if num(lose["d"]) > 0 && num(win["d"]) == 0 { seen[id] = ["p": num(lose["p"]), "d": 1, "at": num(win["at"])] }
                else { seen[id] = win }
            }
        }
        var sk = seen.keys.filter { num(seen[$0]?["at"]) > (sd[$0] ?? 0) }
        if sk.count > 4000 { sk.sort { num(seen[$0]?["at"]) > num(seen[$1]?["at"]) }; sk = Array(sk.prefix(4000)) }
        var mseen: [String: Any] = [:]
        for id in sk {
            let x = seen[id] ?? [:]
            mseen[id] = ["p": Int(num(x["p"])), "d": num(x["d"]) > 0 ? 1 : 0, "at": ms(num(x["at"]))]
        }
        func keep(_ del: [String: Double], _ live: [String: Any]) -> [String: Any] {
            var l = del.keys.filter { live[$0] == nil }
            l.sort { let a = del[$0] ?? 0, b = del[$1] ?? 0; return a != b ? a > b : $0 < $1 }
            var out: [String: Any] = [:]
            for k in l.prefix(400) { out[k] = ms(del[k] ?? 0) }
            return out
        }
        return ["res": mres, "rdel": keep(rd, mres), "seen": mseen, "sdel": keep(sd, mseen)]
    }

    /// Eigener Stand dieser Liste im Format der anderen Geräte
    private func localState(_ src: String) -> [String: Any] {
        let pre = src + "|"
        var res: [String: Any] = [:]
        for e in entries where e.key.hasPrefix(pre) {
            let wk = String(e.key.dropFirst(pre.count))
            var o: [String: Any] = ["key": wk, "pos": Int(e.pos), "dur": Int(e.dur), "at": Self.ms(e.at * 1000), "logo": e.art ?? ""]
            if e.kind == "series" {
                guard let ep = e.epId else { continue }        // ältere Einträge ohne Folgen-Nummer bleiben nur hier
                o["kind"] = "episode"; o["id"] = Int(ep).map { $0 as Any } ?? ep
                o["name"] = e.epName ?? e.episodeTitle ?? e.name
                o["season"] = e.season ?? 0; o["num"] = e.num ?? 0
                o["series"] = ["id": e.itemId, "name": e.name, "logo": e.art ?? ""] as [String: Any]
                o["next"] = e.next ?? false; o["ext"] = e.ext ?? ""
            } else {
                o["kind"] = "movie"; o["id"] = e.itemId; o["name"] = e.name; o["ext"] = e.ext ?? "mp4"; o["next"] = false
            }
            if let cur = res[wk] as? [String: Any], Self.num(cur["at"]) >= Self.num(o["at"]) { continue }
            res[wk] = o
        }
        var seenOut: [String: Any] = [:]
        for k in seen where k.hasPrefix(pre) {
            let rest = String(k.dropFirst(pre.count))
            let wk: String
            if rest.hasPrefix("movie:") { wk = "mv" + rest.dropFirst(6) }
            else if rest.hasPrefix("ep:") { wk = String(rest.dropFirst(3)) }
            else { continue }
            if wk.isEmpty || wk == "mv" { continue }
            seenOut[wk] = ["p": 100, "d": 1, "at": Self.ms(seenAt[k] ?? 1)]
        }
        func del(_ d: [String: Double], seenKeys: Bool) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d where k.hasPrefix(pre) {
                var rest = String(k.dropFirst(pre.count))
                if seenKeys {
                    if rest.hasPrefix("movie:") { rest = "mv" + rest.dropFirst(6) }
                    else if rest.hasPrefix("ep:") { rest = String(rest.dropFirst(3)) }
                }
                out[rest] = Self.ms(v)
            }
            return out
        }
        return ["res": res, "rdel": del(rdel, seenKeys: false), "seen": seenOut, "sdel": del(sdel, seenKeys: true)]
    }

    /// Zusammengeführten Stand hier übernehmen
    private func applyState(_ M: [String: Any], _ src: String) {
        let pre = src + "|"
        var keepOthers = entries.filter { !$0.key.hasPrefix(pre) }
        let old = Dictionary(entries.filter { $0.key.hasPrefix(pre) }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (wk, v) in Self.obj(M, "res") {
            guard let o = v as? [String: Any] else { continue }
            let key = pre + wk
            let at = Self.num(o["at"]) / 1000
            let logo = (o["logo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if (o["kind"] as? String) == "episode" {
                let ser = (o["series"] as? [String: Any]) ?? [:]
                let sid = Int(Self.num(ser["id"])) != 0 ? Int(Self.num(ser["id"])) : (Int(wk.replacingOccurrences(of: "series:", with: "")) ?? 0)
                guard sid != 0 else { continue }
                let epId = o["id"].map { "\($0)" } ?? ""
                let season = Int(Self.num(o["season"])), number = Int(Self.num(o["num"]))
                let epName = (o["name"] as? String) ?? ""
                let isNext = (o["next"] as? Bool) ?? (Self.num(o["next"]) > 0)
                let prev = old[key]
                var e = TVResumeEntry(key: key, kind: "series", itemId: sid, name: (ser["name"] as? String) ?? prev?.name ?? epName,
                                      cat: prev?.cat ?? "", art: (ser["logo"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? logo ?? prev?.art,
                                      demoTitle: prev?.demoTitle, demoColor: prev?.demoColor,
                                      episode: prev?.epId == epId ? prev?.episode : nil,
                                      episodeTitle: isNext ? "Nächste Folge" : "S\(season) F\(number) · \(epName)",
                                      pos: Self.num(o["pos"]), dur: Self.num(o["dur"]), at: at)
                e.ext = o["ext"] as? String; e.epId = epId; e.season = season; e.num = number; e.epName = epName; e.next = isNext
                keepOthers.append(e)
            } else {
                let id = Int(Self.num(o["id"]))
                guard id != 0 else { continue }
                let prev = old[key]
                var e = TVResumeEntry(key: key, kind: "movie", itemId: id, name: (o["name"] as? String) ?? prev?.name ?? "",
                                      cat: prev?.cat ?? "", art: logo ?? prev?.art, demoTitle: prev?.demoTitle, demoColor: prev?.demoColor,
                                      episode: nil, episodeTitle: nil, pos: Self.num(o["pos"]), dur: Self.num(o["dur"]), at: at)
                e.ext = (o["ext"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                keepOthers.append(e)
            }
        }
        // Ältere eigene Serien-Einträge ohne Folgen-Nummer behalten (die kennen die anderen Geräte nicht)
        for e in old.values where e.kind == "series" && e.epId == nil && !keepOthers.contains(where: { $0.key == e.key }) { keepOthers.append(e) }
        entries = keepOthers.sorted { $0.at > $1.at }
        // Gesehen (nur ganz gesehene; angefangene merkt sich das Apple TV nicht einzeln)
        seen = seen.filter { !$0.hasPrefix(pre) }
        for k in seenAt.keys where k.hasPrefix(pre) { seenAt[k] = nil }
        for (wk, v) in Self.obj(M, "seen") {
            guard let o = v as? [String: Any], Self.num(o["d"]) > 0 else { continue }
            let k = wk.hasPrefix("mv") ? pre + "movie:" + wk.dropFirst(2) : pre + "ep:" + wk
            seen.insert(k); seenAt[k] = Self.num(o["at"])
        }
        for k in rdel.keys where k.hasPrefix(pre) { rdel[k] = nil }
        for (wk, v) in Self.obj(M, "rdel") { rdel[pre + wk] = Self.num(v) }
        for k in sdel.keys where k.hasPrefix(pre) { sdel[k] = nil }
        for (wk, v) in Self.obj(M, "sdel") {
            let k = wk.hasPrefix("mv") ? pre + "movie:" + wk.dropFirst(2) : pre + "ep:" + wk
            sdel[k] = Self.num(v)
        }
        persist()
        saveSyncMeta()
    }

    private func rpcJSON(_ name: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let d = try? await RemoteAPI.rpc(name, body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func syncNow(tries: Int = 0) async {
        guard profile.isEmpty, !syncBusy, let host = syncHost?(), !host.acc.isEmpty, !host.source.isEmpty else { return }
        syncBusy = true
        defer { syncBusy = false }
        syncLast = Date()
        let src = host.source, acc = host.acc
        let ids = DeviceIdentity.load()
        let dirty = syncDirty[src] ?? false
        guard let r = await rpcJSON("sync_get", ["p_mac": ids.mac, "p_key": ids.key, "p_acc": acc, "p_kind": "state", "p_have": syncRev[src] ?? -1]),
              (r["ok"] as? Bool) != false, syncHost?()?.source == src else { return }
        let rev = Int(Self.num(r["rev"]))
        let L = localState(src)
        var M: [String: Any]
        if (r["same"] as? Bool) == true {
            if !dirty { return }
            M = Self.mergeState(L, [:])
        } else {
            let R = (r["data"] as? [String: Any]) ?? [:]
            M = Self.mergeState(L, R)
            applyState(M, src)
            if Self.canon(M) == Self.canon(Self.mergeState(R, [:])) {
                syncRev[src] = rev; syncDirty[src] = nil; saveSyncMeta(); return
            }
        }
        let empty = ["res", "seen", "rdel", "sdel"].allSatisfy { Self.obj(M, $0).isEmpty }
        if empty && rev <= 0 { syncRev[src] = rev; syncDirty[src] = nil; saveSyncMeta(); return }
        guard let w = await rpcJSON("sync_put", ["p_mac": ids.mac, "p_key": ids.key, "p_acc": acc, "p_kind": "state", "p_data": M, "p_rev": rev]) else { return }
        if (w["ok"] as? Bool) == true {
            syncRev[src] = Int(Self.num(w["rev"])); syncDirty[src] = nil; saveSyncMeta()
        } else if (w["conflict"] as? Bool) == true && tries < 3 {
            syncBusy = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            await syncNow(tries: tries + 1)
        }
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
