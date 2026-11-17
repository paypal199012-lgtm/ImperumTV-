import Foundation

// MARK: - Richtige Uhrzeit und richtiges Programm (wie TimeFix/EpgShift in der Android-App)
//
// Geht die Uhr des Apple TV falsch, steht die Zeitzone fälschlich auf UTC oder liefert der Anbieter das Programm
// um ganze Stunden verschoben, rechnet die App selbst richtig. Der Kunde muss nichts tun.
// Anker für das Programm: die 15-minütige „Tagesschau“ um 20:00 Uhr deutscher Zeit (läuft auf vielen ARD-Sendern).

enum TVTime {
    /// Sekunden, die das Gerät nachgeht (+) bzw. vorgeht (−)
    private(set) static var off: TimeInterval = 0
    /// Zeitzone für alle Uhrzeiten (korrigiert, wenn das Gerät auf UTC steht)
    private(set) static var zone: TimeZone = .current
    /// Sekunden, um die das Programm des Anbieters verschoben wird
    private(set) static var epgShift: TimeInterval = 0
    /// Richtige Uhrzeit
    static var now: Date { Date().addingTimeInterval(off) }

    private static var checkedAt: Date?
    private static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current

    /// Beim Start: zuletzt gemerkten Stand sofort benutzen
    static func load() {
        let d = UserDefaults.standard.dictionary(forKey: "tv.timeFix") ?? [:]
        let z = (d["zone"] as? String).flatMap { TimeZone(identifier: $0) } ?? .current
        apply(off: (d["off"] as? Double) ?? 0, zone: z, save: false)
        EPGEntry.now = { TVTime.now }
    }

    private static func apply(off o: TimeInterval, zone z: TimeZone, save: Bool) {
        off = abs(o) < 90 ? 0 : o
        zone = z
        hhmm.timeZone = z
        EPGEntry.setZone(z)
        if save { UserDefaults.standard.set(["off": off, "zone": z.identifier], forKey: "tv.timeFix") }
    }

    static func utcLike(_ id: String) -> Bool {
        id.range(of: "^(etc/)?(utc|gmt|uct|zulu|universal|greenwich)([+-]?0)?$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Zeitzone eines Landes (nur Länder mit einer einzigen Zeitzone)
    static func zoneFor(_ cc: String) -> TimeZone? {
        let c = cc.uppercased()
        let cet = ["DE", "AT", "CH", "NL", "BE", "LU", "FR", "IT", "ES", "PL", "CZ", "SK", "HU", "SI", "HR", "BA", "RS", "ME", "MK", "AL", "XK", "DK", "SE", "NO", "MT", "LI", "MC", "AD", "SM", "VA"]
        if cet.contains(c) { return TimeZone(identifier: "Europe/Berlin") }
        if ["GB", "IE", "PT"].contains(c) { return TimeZone(identifier: "Europe/London") }
        if ["GR", "RO", "BG", "FI", "EE", "LV", "LT", "CY", "UA", "MD"].contains(c) { return TimeZone(identifier: "Europe/Athens") }
        if c == "TR" { return TimeZone(identifier: "Europe/Istanbul") }
        return nil
    }

    /// Mit der Uhr des Servers vergleichen (beim Start, danach höchstens alle 6 Stunden)
    static func check(force: Bool = false) async {
        if !force, let c = checkedAt, abs(c.timeIntervalSinceNow) < 6 * 3600 { return }
        checkedAt = Date()
        let id = DeviceIdentity.load()
        let t0 = Date()
        let body: [String: Any] = [
            "p_mac": id.mac, "p_key": id.key,
            "p_client_ms": Int64(t0.timeIntervalSince1970 * 1000),
            "p_tz_min": TimeZone.current.secondsFromGMT(for: t0) / 60,
            "p_tz_name": TimeZone.current.identifier,
            "p_epg_shift": Int(epgShift / 60)
        ]
        guard let data = try? await Remote.rpc("device_clock", body),
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let nowMs = (r["now_ms"] as? NSNumber)?.doubleValue else { checkedAt = nil; return }
        let t1 = Date()
        if t1 < t0 || t1.timeIntervalSince(t0) > 15 { return }          // Antwort zu langsam: ungenau
        let o = nowMs / 1000 - (t0.timeIntervalSince1970 + t1.timeIntervalSince1970) / 2
        var z = TimeZone.current
        if utcLike(TimeZone.current.identifier), let exp = (r["exp_tz"] as? NSNumber)?.intValue,
           exp != TimeZone.current.secondsFromGMT() / 60 {
            z = (r["cc"] as? String).flatMap { zoneFor($0) } ?? TimeZone(secondsFromGMT: exp * 60) ?? .current
        }
        apply(off: o, zone: z, save: true)
    }

    // MARK: Programm des Anbieters verschoben?

    /// Programm mit der erkannten Verschiebung
    static func shifted(_ list: [EPGEntry]) -> [EPGEntry] {
        epgShift == 0 ? list : list.map { $0.shifted(epgShift) }
    }

    private static func key(_ acc: Account) -> String {
        var srv = acc.server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while srv.hasSuffix("/") { srv.removeLast() }
        return srv + "|" + acc.username
    }

    /// Gemerkte Verschiebung für diese Liste laden und einmal am Tag neu prüfen
    @MainActor
    static func detect(_ store: TVStore, force: Bool = false) async {
        guard case .xtream(let acc, _) = store.source else { epgShift = 0; return }
        let k = key(acc)
        var all = (UserDefaults.standard.dictionary(forKey: "tv.epgShift") as? [String: [String: Double]]) ?? [:]
        epgShift = all[k]?["s"] ?? 0
        if !force, let at = all[k]?["at"], Date().timeIntervalSince1970 - at < 20 * 3600 { return }
        let anchor = "(das erste|\\bard\\b|tagesschau|phoenix|3sat|\\b(br|hr|mdr|ndr|rbb|sr|swr|wdr)\\b)"
        let main = "(das erste|\\bard\\b|tagesschau|phoenix)"
        func has(_ s: String, _ p: String) -> Bool { s.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        let chans = store.live.filter { has($0.name, anchor) }
            .sorted { (has($0.name, main) ? 0 : 1) < (has($1.name, main) ? 0 : 1) }
            .prefix(6)
        if chans.isEmpty { return }
        let api = store.client(acc)
        var entries: [(String, EPGEntry)] = []
        for c in chans {
            if let l = try? await api.shortEPG(streamId: c.id, limit: 60) { entries += l.map { (String(c.id), $0) } }
        }
        guard let h = decide(entries) else { return }
        all[k] = ["s": Double(h) * 3600, "at": Date().timeIntervalSince1970]
        UserDefaults.standard.set(all, forKey: "tv.epgShift")
        let before = epgShift
        epgShift = Double(h) * 3600
        if before != epgShift { await check(force: true) }
    }

    /// Stunden, um die verschoben werden muss – oder nil, wenn es nicht sicher ist
    static func decide(_ entries: [(String, EPGEntry)]) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        var votes: [Int: Int] = [:], chans: [Int: Set<String>] = [:]
        for (ch, e) in entries {
            guard let s = e.start, let en = e.end,
                  e.title.range(of: "^\\s*tagesschau\\s*(\\(.*\\))?\\s*$", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let len = en.timeIntervalSince(s)
            guard len >= 600, len <= 1200 else { continue }
            let c = cal.dateComponents([.hour, .minute], from: s)
            guard c.minute == 0, let hr = c.hour else { continue }
            let sh = 20 - hr
            guard abs(sh) <= 2 else { continue }
            votes[sh, default: 0] += 1
            chans[sh, default: []].insert(ch)
        }
        guard let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        let rest = votes.filter { $0.key != best.key }.values.reduce(0, +)
        guard best.value >= 3, (chans[best.key]?.count ?? 0) >= 2, best.value >= rest * 3 else { return nil }
        return best.key
    }
}
