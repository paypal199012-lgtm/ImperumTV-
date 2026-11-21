import Foundation

// MARK: - Doppelte Filme (wie auf Android): derselbe Film (Titel + Jahr) in anderer Qualität oder Sprache
// steht nur einmal da; beim Öffnen wählt man die Fassung. Die meist gewählte Sprache kommt nach oben.

struct DupInfo {
    var key = ""
    var disp = ""
    var year = 0
    var langs: [String] = []
    var q = ""
    var d3 = false
    /// „Eiserne Wildnis: Heart of the Beast“ → beide Teile (gleicher Film unter anderem Titel)
    var alt: [String] = []
    /// Quelle („Disney+“, „Netflix“ …), falls im Namen
    var src = ""
    var sig: String { langs.joined(separator: "+") + "|" + q + "|" + (d3 ? "1" : "0") + "|" + src }
}

final class DupGroup {
    let n: Int
    var items: [TVItem] = []
    var info: [DupInfo] = []
    init(n: Int) { self.n = n }
}

struct DupOption: Identifiable {
    var id: Int { item.id }
    let item: TVItem
    let info: DupInfo
    let resumePos: Double?
    let label: String
}

@MainActor
final class MovieDups {
    static let shared = MovieDups()

    enum Mode: String { case ask, auto, off }

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "tv.dupMode") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tv.dupMode"); sigs = [:] }
    }
    var on: Bool { mode != .off }
    var label: String {
        switch mode {
        case .off: return "Aus"
        case .auto: return "Zusammenfassen · automatisch"
        case .ask: return "Zusammenfassen · fragen"
        }
    }
    func nextMode() { mode = mode == .ask ? .auto : mode == .auto ? .off : .ask }

    private enum Tag { case l(String), q(String), s(String?) }

    private static let LANG: [String: String] = [
        "DE": "DE", "GER": "DE", "GERMAN": "DE", "DEUTSCH": "DE", "DEU": "DE",
        "EN": "EN", "ENG": "EN", "ENGLISH": "EN", "ENGLISCH": "EN",
        "FR": "FR", "FRE": "FR", "FRA": "FR", "FRENCH": "FR", "FRANÇAIS": "FR", "FRANCAIS": "FR", "FRANZÖSISCH": "FR", "VF": "FR", "VFF": "FR", "VOSTFR": "FR",
        "TR": "TR", "TUR": "TR", "TURKISH": "TR", "TÜRKISCH": "TR", "TÜRK": "TR",
        "IT": "IT", "ITA": "IT", "ITALIAN": "IT", "ITALIENISCH": "IT",
        "ES": "ES", "ESP": "ES", "SPA": "ES", "SPANISH": "ES", "SPANISCH": "ES",
        "NL": "NL", "DUTCH": "NL", "PL": "PL", "POLISH": "PL", "RU": "RU", "RUS": "RU", "RUSSIAN": "RU",
        "AR": "AR", "ARA": "AR", "ARABIC": "AR", "GR": "GR", "GRE": "GR", "GREEK": "GR", "GRIECHISCH": "GR",
        "PT": "PT", "POR": "PT", "AL": "AL", "ALB": "AL",
        "MULTI": "MULTI", "MULTISUB": "MULTI", "MULTI-SUB": "MULTI", "DUAL": "MULTI", "OMU": "OMU", "OV": "OV"
    ]
    private static let QUAL: [String: String] = ["8K": "8K", "4320P": "8K", "4K": "4K", "UHD": "4K", "2160P": "4K", "FHD": "FHD", "FULLHD": "FHD", "1080P": "FHD",
                                                 "HD": "HD", "720P": "HD", "SD": "SD", "480P": "SD", "3D": "3D"]
    private static let SKIP: Set<String> = ["HEVC", "H265", "X265", "H264", "X264", "HDR", "HDR10", "DV", "DOLBY", "ATMOS", "10BIT", "SUB", "SUBS", "VOD"]
    /// Quelle/Streamingdienst („AMZ - Film“, „4K-A+ - Film“): nur in GROSSSCHRIFT (sonst wären „Sky“, „Prime“ im Titel betroffen)
    private static let SVC: Set<String> = ["AMZ", "AMAZON", "PRIME", "NF", "NFLX", "NETFLIX", "APLUS", "ATV", "ATVP", "APPLE", "DPLUS", "DSNP", "DISNEY", "HMAX", "MAX", "HBO",
                                           "SKY", "WOW", "PPLUS", "PMTP", "PARAMOUNT", "RTLPLUS", "JOYN", "MAGENTA", "MGM", "PCOK", "PEACOCK", "HULU", "CRAV", "STAN",
                                           "WEB", "WEBDL", "WEBRIP", "BLURAY", "BD", "REMUX", "CAM", "TS",
                                           // Rubriken des Anbieters („TOP - Film“, „4K-TOP - Film“, „AS - Film“)
                                           "TOP", "VIP", "HOT", "NEW", "NEU", "AS", "KINO", "CINEMA"]
    /// Anzeigename der Quelle in der Fassungs-Auswahl
    private static let srcName: [String: String] = [
        "AMZ": "Amazon", "AMAZON": "Amazon", "PRIME": "Amazon", "NF": "Netflix", "NFLX": "Netflix", "NETFLIX": "Netflix", "APLUS": "Apple TV+", "ATV": "Apple TV+",
        "ATVP": "Apple TV+", "APPLE": "Apple TV+", "DPLUS": "Disney+", "DSNP": "Disney+", "DISNEY": "Disney+", "HMAX": "HBO Max", "MAX": "HBO Max", "HBO": "HBO",
        "SKY": "Sky", "WOW": "WOW", "PPLUS": "Paramount+", "PMTP": "Paramount+", "PARAMOUNT": "Paramount+", "RTLPLUS": "RTL+", "JOYN": "Joyn", "MAGENTA": "MagentaTV",
        "MGM": "MGM+", "PCOK": "Peacock", "PEACOCK": "Peacock", "HULU": "Hulu"
    ]
    /// Kürzel, die der Anbieter mit einer Qualität verbindet („4K-MRVL - Film“ → „MRVL - Film“ ist dieselbe Rubrik)
    private static var learned: Set<String> = []
    static let RANK: [String: Int] = ["8K": 5, "4K": 4, "FHD": 3, "HD": 2, "SD": 1]
    static let langName: [String: String] = [
        "DE": "Deutsch", "EN": "Englisch", "FR": "Französisch", "TR": "Türkisch", "IT": "Italienisch", "ES": "Spanisch", "NL": "Niederländisch",
        "PL": "Polnisch", "RU": "Russisch", "AR": "Arabisch", "GR": "Griechisch", "PT": "Portugiesisch", "AL": "Albanisch",
        "MULTI": "Mehrsprachig", "OMU": "Original mit Untertiteln", "OV": "Originalfassung"
    ]
    static let qualName: [String: String] = ["8K": "8K", "4K": "4K Ultra HD", "FHD": "Full HD", "HD": "HD", "SD": "SD"]

    /// Zwei Buchstaben zählen nur in Großschrift (sonst wäre „Es“ Spanisch)
    private static func tag(_ w: Substring) -> Tag? {
        if w.isEmpty { return nil }
        let u = w.uppercased()
        if w.count <= 2 && String(w) != u && !w.contains(where: { $0.isNumber }) { return nil }
        if let q = QUAL[u] { return .q(q) }
        if let l = LANG[u] { return .l(l) }
        if SKIP.contains(u) { return .s(nil) }
        if (SVC.contains(u) || learned.contains(u)) && String(w) == u { return .s(srcName[u] ?? (learned.contains(u) ? u : nil)) }
        return nil
    }

    /// „DE 4K“, „GER/ENG“, „4K-HDR“: nur wenn alle Teile bekannte Zusätze sind
    private static func tags(_ t: Substring) -> [Tag]? {
        // „A+“, „D+“, „RTL+“ (Apple TV+, Disney+ …) als ein Wort
        let norm = String(t).replacingOccurrences(of: "\\b([A-Za-z]{1,8})\\+", with: "$1PLUS", options: .regularExpression)
        let parts = norm.split(whereSeparator: { " /,+&_.-".contains($0) })
        if parts.isEmpty { return nil }
        var out: [Tag] = [], known = false, odd = 0
        for p in parts {
            guard let x = tag(p) else {
                // unbekanntes Kürzel neben einer Qualität/Sprache („4K-XYZ“): nur GROSS, 2–5 Buchstaben
                if (2...5).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isUppercase }) { odd += 1; continue }
                return nil
            }
            switch x { case .l(_), .q(_): known = true; case .s(_): break }
            out.append(x)
        }
        if odd > 0 && !known { return nil }
        return out.isEmpty ? nil : out
    }

    private static func add(_ p: inout DupInfo, _ list: [Tag]) {
        for t in list {
            switch t {
            case .l(let l): if !p.langs.contains(l) { p.langs.append(l) }
            case .q(let q):
                if q == "3D" { p.d3 = true } else if p.q.isEmpty || (RANK[q] ?? 0) > (RANK[p.q] ?? 0) { p.q = q }
            case .s(let src): if let v = src, p.src.isEmpty { p.src = v }
            }
        }
    }

    private var catLang: [String: String] = [:]
    private var catNoLang: Set<String> = []

    private func langOfCat(_ id: String, _ name: String) -> String? {
        if let l = catLang[id] { return l }
        if catNoLang.contains(id) { return nil }
        for w in name.split(whereSeparator: { !$0.isLetter }) {
            if case .l(let l)? = Self.tag(w) { catLang[id] = l; return l }
        }
        catNoLang.insert(id)
        return nil
    }

    /// Name zerlegen: Titel ohne Zusätze, Jahr, Sprachen, Qualität
    func parse(_ it: TVItem, catName: String) -> DupInfo {
        var p = DupInfo()
        p.year = it.year ?? 0
        var s = Substring(it.name)
        let seps: Set<Character> = ["]", ")", "|", ":"]
        // vorne: „DE | “, „|4K| “, „[EN] “, „DE: “, „EN - “
        for _ in 0..<3 {
            var t = s.drop(while: { $0 == " " })
            if let f = t.first, "[(|".contains(f) { t = t.dropFirst() }
            var cut: Substring.Index? = nil, after: Substring.Index? = nil
            var i = t.startIndex, n = 0
            while i < t.endIndex && n < 20 {
                if seps.contains(t[i]) { cut = i; after = t.index(after: i); break }
                if t[i] == "-", i > t.startIndex, t[t.index(before: i)] == " ", t.index(after: i) < t.endIndex, t[t.index(after: i)] == " " {
                    cut = t.index(before: i); after = t.index(after: i); break
                }
                i = t.index(after: i); n += 1
            }
            guard let c = cut, let a = after else { break }
            let inner = t[t.startIndex..<c].trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty, let tl = Self.tags(Substring(inner)) else { break }
            Self.add(&p, tl)
            s = t[a...].drop(while: { $0 == " " })
        }
        // Klammern irgendwo: Jahr oder Zusätze
        if s.contains("(") || s.contains("[") {
            var out = ""
            var i = s.startIndex
            while i < s.endIndex {
                let c = s[i]
                if c == "(" || c == "[" {
                    let start = s.index(after: i)
                    if let close = s[start...].firstIndex(where: { "()[]".contains($0) }), ")]".contains(s[close]) {
                        let inner = s[start..<close]
                        if !inner.isEmpty && inner.count <= 24 {
                            let tr = inner.trimmingCharacters(in: .whitespaces)
                            if tr.count == 4, let y = Int(tr), (1900...2099).contains(y) {
                                if p.year == 0 { p.year = y }
                                out += " "; i = s.index(after: close); continue
                            }
                            if let t = Self.tags(Substring(tr)) { Self.add(&p, t); out += " "; i = s.index(after: close); continue }
                            // Herkunftsland „(US)“, „(CA)“
                            if tr.count == 2, tr.allSatisfy({ $0.isASCII && $0.isUppercase }) { out += " "; i = s.index(after: close); continue }
                        }
                    }
                }
                out.append(c)
                i = s.index(after: i)
            }
            s = Substring(out)
        }
        // hinten: „… 4K“, „… - GER“, „… 2026“
        let tailSep: Set<Character> = [" ", "-", "|", ":", "\t"]
        for _ in 0..<4 {
            let trimmed = s.reversed().drop(while: { $0 == " " })
            let end = s.index(s.startIndex, offsetBy: trimmed.count)
            var st = end
            while st > s.startIndex && !tailSep.contains(s[s.index(before: st)]) { st = s.index(before: st) }
            let word = s[st..<end]
            if st == s.startIndex || word.count < 2 || word.count > 12 { break }
            var restEnd = st
            while restEnd > s.startIndex && tailSep.contains(s[s.index(before: restEnd)]) { restEnd = s.index(before: restEnd) }
            let rest = s[s.startIndex..<restEnd]
            if !rest.contains(where: { $0.isLetter || $0.isNumber }) { break }
            if word.count == 4, let y = Int(word), (1900...2099).contains(y) {
                if p.year == 0 || p.year == y { p.year = y; s = rest; continue }
                break
            }
            guard let t2 = Self.tags(word) else { break }
            Self.add(&p, t2)
            s = rest
        }
        var disp = s.trimmingCharacters(in: CharacterSet(charactersIn: " |:-–"))
        disp = disp.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if disp.isEmpty { disp = it.name }
        p.disp = disp
        let folded = disp.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().replacingOccurrences(of: "ß", with: "ss")
        let words = folded.split(whereSeparator: { !(($0.isASCII && ($0.isLetter || $0.isNumber))) })
        p.key = words.filter { $0 != "und" && $0 != "and" && $0 != "et" }.joined(separator: " ")
        if let r = folded.range(of: ": ") {
            func norm(_ x: Substring) -> String {
                x.split(whereSeparator: { !(($0.isASCII && ($0.isLetter || $0.isNumber))) })
                    .filter { $0 != "und" && $0 != "and" && $0 != "et" }.joined(separator: " ")
            }
            p.alt = [norm(folded[..<r.lowerBound]), norm(folded[r.upperBound...])].filter { $0.count >= 8 && $0.contains(" ") }
        }
        if p.langs.isEmpty, let l = langOfCat(it.cat, catName) { p.langs.append(l) }
        return p
    }

    // MARK: Gruppen

    private var maps: [String: [Int: DupGroup]] = [:]
    private var sigs: [String: String] = [:]

    /// „4K-MRVL“ → MRVL ist ein Kürzel des Anbieters
    private static func learn(_ all: [TVItem]) {
        learned = []
        var found = Set<String>()
        let re = try? NSRegularExpression(pattern: "^[\\s\\[(|]*([A-Za-z0-9+]{2,6})[-_]([A-Za-z0-9+]{2,6})\\s*(?:[\\])|:]|\\s-\\s)")
        for m in all {
            let n = m.name as NSString
            guard let r = re?.firstMatch(in: m.name, range: NSRange(location: 0, length: n.length)), r.numberOfRanges == 3 else { continue }
            let a = n.substring(with: r.range(at: 1)), b = n.substring(with: r.range(at: 2))
            for (x, y) in [(a, b), (b, a)] {
                guard let t = tag(Substring(x)) else { continue }
                switch t {
                case .l(_), .q(_):
                    if (2...5).contains(y.count), y.allSatisfy({ $0.isASCII && $0.isUppercase }), tag(Substring(y)) == nil { found.insert(y) }
                case .s(_): break
                }
            }
        }
        learned = found
    }

    /// Gruppen bilden (einmal je Liste): ID → Gruppe – nur Filme/Serien, die es mehrfach gibt
    func groups(_ all: [TVItem], kind: MediaKind = .movie, catName: (String) -> String) -> [Int: DupGroup] {
        let k0 = "\(kind)", s = "\(all.count)|\(all.first?.id ?? 0)|\(all.last?.id ?? 0)"
        if sigs[k0] == s, let m = maps[k0] { return m }
        Self.learn(all)
        var byKey: [String: [(TVItem, DupInfo)]] = [:]
        var names: [String: String] = [:]
        for m in all {
            var cn = names[m.cat] ?? ""
            if names[m.cat] == nil { cn = catName(m.cat); names[m.cat] = cn }
            let p = parse(m, catName: cn)
            if p.key.isEmpty { continue }
            byKey[p.key + "|" + (p.year > 0 ? String(p.year) : ""), default: []].append((m, p))
        }
        // Doppeltitel: „Eiserne Wildnis: Heart of the Beast (2026)“ zu „Heart of the Beast (2026)“ (nur mit gleichem Jahr)
        for ka in Array(byKey.keys) where !ka.hasSuffix("|") {
            guard let arrA = byKey[ka], let bar = ka.lastIndex(of: "|") else { continue }
            let yr = String(ka[bar...])
            var target: String? = nil
            for e in arrA { for a in e.1.alt { let kb = a + yr; if kb != ka && byKey[kb] != nil { target = kb; break } }; if target != nil { break } }
            if let kb = target { byKey[kb, default: []].append(contentsOf: arrA); byKey[ka] = nil }
        }
        // ohne Jahr („TOP - Film“) zu der einzigen Fassung mit Jahr („4K-TOP - Film (2015)“)
        var withYear: [String: [String]] = [:]
        for k in byKey.keys where !k.hasSuffix("|") { if let bar = k.lastIndex(of: "|") { withYear[String(k[..<bar]), default: []].append(k) } }
        for kn in Array(byKey.keys) where kn.hasSuffix("|") {
            if let wy = withYear[String(kn.dropLast())], wy.count == 1, let arr = byKey[kn] { byKey[wy[0], default: []].append(contentsOf: arr); byKey[kn] = nil }
        }
        var out: [Int: DupGroup] = [:], num = 0
        for (k, arr) in byKey where arr.count > 1 {
            let noYear = k.hasSuffix("|")
            num += 1
            let g = DupGroup(n: num)
            var ids = Set<Int>(), sigs = Set<String>(), extra: [Int] = []
            for (m, p) in arr {
                if ids.contains(m.id) { extra.append(m.id); continue }      // derselbe Stream doppelt in der Liste
                if noYear && sigs.contains(p.sig) { continue }              // ohne Jahr und ohne Unterschied: wohl zwei Filme gleichen Namens
                ids.insert(m.id); sigs.insert(p.sig)
                g.items.append(m); g.info.append(p)
            }
            if g.items.count < 2 { continue }
            for m in g.items { out[m.id] = g }
            for id in extra { out[id] = g }
        }
        maps[k0] = out
        sigs[k0] = s
        return out
    }

    func group(_ it: TVItem, _ kind: MediaKind = .movie) -> DupGroup? {
        guard on, let g = maps["\(kind)"]?[it.id], g.items.count > 1 else { return nil }
        return g
    }

    /// Liste kürzen: von jedem Film / jeder Serie nur die erste Fassung (Reihenfolge bleibt)
    func collapse(_ list: [TVItem], _ kind: MediaKind = .movie) -> [TVItem] {
        guard on, list.count > 1, let map = maps["\(kind)"], !map.isEmpty else { return list }
        var used = Set<Int>()
        return list.filter { m in
            guard let g = map[m.id] else { return true }
            return used.insert(g.n).inserted
        }
    }

    func title(_ g: DupGroup) -> String {
        let p = g.info.first { $0.disp.uppercased() != $0.disp } ?? g.info[0]
        return p.disp + (p.year > 0 ? " (\(p.year))" : "")
    }

    // MARK: Auswahl

    private var langHist: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "tv.dupLang") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "tv.dupLang") }
    }

    private func langScore(_ langs: [String], _ h: [String: Int]) -> Int {
        let any = h.values.contains { $0 > 0 }
        return langs.map { any ? (h[$0] ?? 0) : ($0 == "DE" ? 1 : 0) }.max() ?? 0
    }

    func remember(_ p: DupInfo) {
        guard !p.langs.isEmpty else { return }
        var h = langHist
        for l in p.langs { h[l] = min((h[l] ?? 0) + 1, 50) }
        langHist = h
    }

    private static func time(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Fassungen in der Reihenfolge, in der sie angeboten werden: angefangene zuerst, dann Lieblingssprache, dann Qualität
    func options(_ g: DupGroup, series: Bool = false, resume: (Int) -> (pos: Double, at: Double)?) -> [DupOption] {
        let h = langHist
        var rows = g.items.indices.map { i -> (TVItem, DupInfo, (pos: Double, at: Double)?, Int) in (g.items[i], g.info[i], resume(g.items[i].id), i) }
        rows.sort { a, b in
            if (a.2 != nil) != (b.2 != nil) { return a.2 != nil }
            if let x = a.2, let y = b.2 { return x.at > y.at }
            let la = langScore(a.1.langs, h), lb = langScore(b.1.langs, h)
            if la != lb { return la > lb }
            if a.1.d3 != b.1.d3 { return !a.1.d3 }
            let qa = Self.RANK[a.1.q] ?? 2, qb = Self.RANK[b.1.q] ?? 2
            if qa != qb { return qa > qb }
            return a.3 < b.3
        }
        func label(_ p: DupInfo, _ cat: String?, _ pos: Double?) -> String {
            var parts: [String] = []
            if !p.langs.isEmpty { parts.append(p.langs.map { Self.langName[$0] ?? $0 }.joined(separator: " + ")) }
            if !p.q.isEmpty { parts.append(Self.qualName[p.q] ?? p.q) }
            if p.d3 { parts.append("3D") }
            if !p.src.isEmpty { parts.append(p.src) }
            if parts.isEmpty { parts.append("Standard") }
            if let c = cat { parts.append(c) }
            if let s = pos { parts.append(series ? "angefangen" : "weiter bei " + Self.time(s)) }
            return parts.joined(separator: " · ")
        }
        var count: [String: Int] = [:]
        for r in rows { count[label(r.1, nil, nil), default: 0] += 1 }
        return rows.map { r in
            let dup = (count[label(r.1, nil, nil)] ?? 0) > 1
            return DupOption(item: r.0, info: r.1, resumePos: r.2?.pos, label: label(r.1, dup ? "Nr. \(r.0.id)" : nil, r.2?.pos))
        }
    }

    /// Kleine Schilder auf der Kachel: DE · EN · 4K · HD · 3D
    func badges(_ g: DupGroup) -> [String] {
        var langs: [String] = [], qs: [String] = [], d3 = false
        for p in g.info {
            for l in p.langs where !langs.contains(l) { langs.append(l) }
            if !p.q.isEmpty && !qs.contains(p.q) { qs.append(p.q) }
            if p.d3 { d3 = true }
        }
        let h = langHist
        langs.sort { langScore([$0], h) > langScore([$1], h) }
        qs.sort { (Self.RANK[$0] ?? 0) > (Self.RANK[$1] ?? 0) }
        var tags = Array(langs.prefix(3)) + qs
        if d3 { tags.append("3D") }
        if tags.isEmpty { tags = ["\(g.items.count)×"] }
        if tags.count > 4 { tags = Array(tags.prefix(3)) + ["+\(tags.count - 3)"] }
        return tags
    }
}
