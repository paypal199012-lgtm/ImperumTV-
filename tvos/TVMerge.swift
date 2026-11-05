import Foundation

/// Ein Sender mit allen Qualitäten (FHD, HD, 4K, RAW …), wie auf Android
struct MergeGroup: Identifiable {
    var id: Int { rep.id }
    /// angezeigte/abgespielte Variante (eigene Wahl oder beste Qualität)
    let rep: TVItem
    let variants: [TVItem]
    /// längster Name ohne Qualitätsangaben
    let name: String
    let key: String
}

// MARK: - Sender zusammenfassen

extension TVStore {
    var mergeOn: Bool {
        get { UserDefaults.standard.object(forKey: "tv.mergeCh") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.mergeCh"); objectWillChange.send() }
    }

    /// Gewählte Qualität je Sender (Schlüssel → Sender-ID)
    var mergePref: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "tv.mergePref") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "tv.mergePref"); objectWillChange.send() }
    }

    /// Sender, die nicht zusammengefasst werden sollen
    var mergeOff: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "tv.mergeOff") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "tv.mergeOff"); objectWillChange.send() }
    }

    private static let synonyms: [String: String] = [
        "austria": "at", "osterreich": "at", "oesterreich": "at", "deutschland": "de", "germany": "de", "ger": "de", "deu": "de",
        "schweiz": "ch", "swiss": "ch", "suisse": "ch", "bundesliga": "buli"
    ]

    /// Qualitätsangaben im Namen, in der Reihenfolge des Namens
    func qualityTags(_ it: TVItem) -> [String] {
        if let t = mergeTagCache[it.id] { return t }
        var out: [String] = []
        func add(_ t: String) { if !out.contains(t) { out.append(t) } }
        for w in Self.words(it.name.lowercased().replacingOccurrences(of: #"(?<=[A-Za-z])(?=\d)|(?<=\d)(?=[A-Za-z])"#, with: " ", options: .regularExpression)
                                .replacingOccurrences(of: "4 k", with: "4k").replacingOccurrences(of: "8 k", with: "8k")
                                .replacingOccurrences(of: "50 fps", with: "50fps").replacingOccurrences(of: "60 fps", with: "60fps")
                                .replacingOccurrences(of: "1080 p", with: "1080p").replacingOccurrences(of: "720 p", with: "720p")
                                .replacingOccurrences(of: "h 265", with: "h265").replacingOccurrences(of: "x 265", with: "x265")) {
            switch w {
            case "fhd", "1080p", "1080": add("FHD")
            case "hd", "720p", "720", "hq": add("HD")
            case "uhd", "4k", "8k": add("4K")
            case "sd": add("SD")
            case "raw": add("RAW")
            case "50fps", "60fps", "fps": add("50FPS")
            case "hevc", "h265", "x265": add("HEVC")
            case "backup", "bkp": add("Backup")
            default: break
            }
        }
        mergeTagCache[it.id] = out
        return out
    }

    /// Kleiner = besser: 4K/UHD, „FHD RAW“, RAW, FHD, „HD RAW“, HD, ohne Angabe, SD – Backup und Handy-Versionen ganz hinten
    func qualityRank(_ it: TVItem) -> Double {
        let t = qualityTags(it)
        var r: Double = 4
        if t.contains("4K") { r = 0 }
        else if t.contains("FHD") { r = 2 }
        else if t.contains("HD") { r = 3 }
        else if t.contains("RAW") { r = 1 }
        else if t.contains("SD") { r = 6 }
        // RAW-Zusatz: „FHD RAW“ vor „RAW“ vor „FHD“; „HD RAW“ nach FHD, aber vor HD
        if t.contains("RAW") { if r == 2 { r = 0.9 } else if r == 3 { r = 2.5 } else if r == 0 { r = -0.1 } }
        if t.contains("50FPS") { r -= 0.2 }
        if t.contains("Backup") { r += 5 }
        if t.contains("SD") && r < 6 { r += 6 }
        if Self.words(it.name).contains(where: { ["mobile", "low", "lq"].contains($0) }) { r += 8 }
        return r
    }

    /// Land + Name ohne Qualität („AT: Sky Sport Austria 1 HD“ und „Sky Sport Austria1 FHD“ → gleicher Schlüssel)
    func mergeKey(_ it: TVItem) -> String {
        if let k = mergeCache[it.id] { return k }
        var n = it.name
        if let r = n.range(of: #"^[A-Za-z]{2,3}\s*[:|]"#, options: .regularExpression) { n.removeSubrange(r) }
        n = n.replacingOccurrences(of: #"(?<=[A-Za-z])(?=\d)|(?<=\d)(?=[A-Za-z])"#, with: " ", options: .regularExpression)
        let skip: Set<String> = ["hd", "fhd", "uhd", "4k", "8k", "4", "k", "sd", "hq", "raw", "hevc", "h265", "h264", "x265", "50fps", "60fps", "fps",
                                 "50", "60", "backup", "bkp", "1080p", "720p", "1080", "720", "p", "mobile", "low", "lq", "orig", "multi"]
        let w = Self.words(n).map { Self.synonyms[$0] ?? $0 }.filter { !skip.contains($0) }
        let k = country(it) + "|" + w.joined(separator: " ")
        mergeCache[it.id] = k
        return k
    }

    /// Name ohne Qualitätsangaben (Groß-/Kleinschreibung bleibt)
    func cleanName(_ it: TVItem) -> String {
        var n = it.name.replacingOccurrences(of: #"(?i)(?<![A-Za-z0-9])(FHD|UHD|HD|SD|4K|8K|RAW|HEVC|H\.?265|x265|50\s?FPS|60\s?FPS|1080p|720p|Backup|BKP)(?![A-Za-z0-9])"#,
                                             with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: " -|·:+"))
        return n.isEmpty ? it.name : n
    }

    /// Liste zusammenfassen (Reihenfolge wie das erste Vorkommen)
    func mergeGroups(_ list: [TVItem]) -> [MergeGroup] {
        guard mergeOn else { return list.map { MergeGroup(rep: $0, variants: [$0], name: $0.name, key: "") } }
        let off = mergeOff, pref = mergePref
        var order: [String] = []
        var byKey: [String: [TVItem]] = [:]
        for it in list {
            var k = mergeKey(it)
            if k.hasSuffix("|") || off.contains(k) { k = "#\(it.id)" }      // ohne Namen oder „nicht zusammenfassen“
            if byKey[k] == nil { order.append(k); byKey[k] = [it] } else { byKey[k]!.append(it) }
        }
        return order.map { k in
            let v = byKey[k]!
            if v.count == 1 { return MergeGroup(rep: v[0], variants: v, name: v[0].name, key: k) }
            let sorted = v.sorted { qualityRank($0) < qualityRank($1) }
            let rep = pref[k].flatMap { id in v.first { $0.id == id } } ?? sorted[0]
            let name = v.map { cleanName($0) }.max { $0.count < $1.count } ?? rep.name
            return MergeGroup(rep: rep, variants: sorted, name: name, key: k)
        }
    }

    /// Alle Qualitäten eines Senders (für den Player)
    func variants(of it: TVItem) -> [TVItem] {
        guard mergeOn else { return [it] }
        let k = mergeKey(it)
        if k.hasSuffix("|") || mergeOff.contains(k) { return [it] }
        let v = live.filter { mergeKey($0) == k }
        return v.isEmpty ? [it] : v.sorted { qualityRank($0) < qualityRank($1) }
    }

    func choose(_ it: TVItem) {
        var p = mergePref
        p[mergeKey(it)] = it.id
        mergePref = p
    }

    func dontMerge(_ it: TVItem) {
        var o = mergeOff
        o.insert(mergeKey(it))
        mergeOff = o
    }

    /// „FHD“, „HD · RAW“ oder „Standard“
    func qualityLabel(_ it: TVItem) -> String {
        let t = qualityTags(it)
        return t.isEmpty ? "Standard" : t.joined(separator: " · ")
    }
}
