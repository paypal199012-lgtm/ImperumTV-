import SwiftUI

// MARK: - Fußball: Spielplan von der ImperumTV-Website (/api/fussball), Sender aus der eigenen Liste
// Wie auf Android, aber ohne Hinweise auf Bezahlsender (App Store): Es werden nur Sender gezeigt,
// die beide Vereine im Namen tragen („Live | Bayern vs. Dortmund“).

struct FTeam: Decodable, Hashable {
    let n: String
    let s: String
    let l: String?
    var display: String { s.isEmpty ? n : s }
}

struct FMatch: Decodable, Identifiable, Hashable {
    let id: String
    let c: String
    let t: Double
    let s: String
    let h: FTeam
    let a: FTeam
    let sc: [Int?]
    let mn: String?

    var date: Date { Date(timeIntervalSince1970: t / 1000) }
    var isLive: Bool { ["IN_PLAY", "PAUSED", "LIVE", "EXTRA_TIME", "PENALTY_SHOOTOUT", "SUSPENDED"].contains(s) }
    var isOver: Bool { s == "FINISHED" || s == "AWARDED" }
    var hasScore: Bool { sc.count == 2 && sc[0] != nil && sc[1] != nil && (isLive || isOver || date <= Date()) }

    enum CodingKeys: String, CodingKey { case id, c, t, s, h, a, sc, mn }
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? k.decode(Int.self, forKey: .id) { id = String(i) } else { id = (try? k.decode(String.self, forKey: .id)) ?? UUID().uuidString }
        c = (try? k.decode(String.self, forKey: .c)) ?? ""
        t = (try? k.decode(Double.self, forKey: .t)) ?? 0
        s = (try? k.decode(String.self, forKey: .s)) ?? ""
        h = try k.decode(FTeam.self, forKey: .h)
        a = try k.decode(FTeam.self, forKey: .a)
        sc = (try? k.decode([Int?].self, forKey: .sc)) ?? [nil, nil]
        mn = try? k.decode(String.self, forKey: .mn)
    }
    static func == (l: FMatch, r: FMatch) -> Bool { l.id == r.id && l.s == r.s && l.sc == r.sc && l.mn == r.mn }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var stateText: String {
        switch s {
        case "PAUSED": return "HALBZEIT"
        case "EXTRA_TIME": return "VERLÄNGERUNG"
        case "PENALTY_SHOOTOUT": return "ELFMETER"
        case "SUSPENDED": return "UNTERBROCHEN"
        case "POSTPONED": return "verlegt"
        default:
            if isLive { return "LIVE" + ((mn ?? "").isEmpty ? "" : " " + (mn ?? "")) }
            return isOver ? "Ende" : ""
        }
    }
}

private struct FResponse: Decodable {
    let ok: Bool
    let error: String?
    let matches: [FMatch]?
}

enum FB {
    static let leagues: [(String, String)] = [("", "Alle"), ("__live", "● Jetzt live"), ("BL1", "Bundesliga"), ("BL2", "2. Bundesliga"),
        ("DFB", "DFB-Pokal"), ("CL", "Champions League"), ("EL", "Europa League"), ("ECL", "Conference League"), ("PL", "Premier League"),
        ("SA", "Serie A"), ("SB", "Serie B"), ("PD", "LaLiga"), ("FL1", "Ligue 1")]
    static let short: [String: String] = ["BL1": "BL", "BL2": "2.BL", "DFB": "POKAL", "CL": "CL", "EL": "EL", "ECL": "ECL",
        "PL": "PL", "SA": "SA", "SB": "SB", "PD": "LL", "FL1": "L1"]

    static func color(_ c: String) -> Color {
        switch c {
        case "BL1": return Color(red: 0.82, green: 0.02, blue: 0.08)
        case "BL2": return Color(red: 0.56, green: 0.04, blue: 0.08)
        case "DFB": return Color(red: 0.04, green: 0.48, blue: 0.23)
        case "CL": return Color(red: 0.11, green: 0.16, blue: 0.42)
        case "EL": return Color(red: 0.95, green: 0.42, blue: 0.13)
        case "ECL": return Color(red: 0.07, green: 0.64, blue: 0.35)
        case "PL": return Color(red: 0.24, green: 0.10, blue: 0.36)
        case "SA": return Color(red: 0.04, green: 0.36, blue: 0.71)
        case "SB": return Color(red: 0.18, green: 0.49, blue: 0.20)
        case "PD": return Color(red: 0.88, green: 0.25, blue: 0.23)
        case "FL1": return Color(red: 0.07, green: 0.19, blue: 0.37)
        default: return Color.gray
        }
    }

    private static let stop: Set<String> = ["club", "real", "borussia", "united", "city", "sporting", "athletic", "atletico", "olympique",
        "stade", "calcio", "football", "fussball", "hotspur", "albion", "wanderers", "deportivo", "racing", "union", "saint", "paris",
        "germain", "munchen", "internazionale", "milano", "town", "county", "rovers", "villa", "palace", "forest", "ham", "hove",
        "sport", "sports", "verein", "olympic", "dynamo", "balompie", "futbol"]

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased().replacingOccurrences(of: "ß", with: "ss")
    }

    static func words(_ team: FTeam) -> [String] {
        var out: [String] = []
        for name in [team.s, team.n] {
            for w in fold(name).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            where w.count >= 4 && !stop.contains(w) && !out.contains(w) { out.append(w) }
        }
        return Array(out.prefix(3))
    }

    static func has(_ text: String, _ w: String) -> Bool {
        if w.count >= 6 { return text.contains(w) }
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: w, range: range) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? " " : text[r.upperBound]
            if !(before.isLetter || before.isNumber) && !(after.isLetter || after.isNumber) { return true }
            range = r.upperBound..<text.endIndex
        }
        return false
    }

    static func isSeparator(_ name: String) -> Bool {
        name.contains("##") || name.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            || name.contains("---") || name.contains("===") || name.contains("***")
    }

    private static let youth = try! NSRegularExpression(pattern: "(^|[^a-z0-9])(u ?1[5-9]|u ?2[0-3]|ii|frauen|women|damen|jugend|youth|reserves?)([^a-z0-9]|$)")
    static func isYouth(_ s: String) -> Bool { youth.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    private static let ended = try! NSRegularExpression(pattern: "(^|\\|)\\s*(ended|ende|beendet|finished|vorbei)([^a-z]|$)")
    static func isEnded(_ s: String) -> Bool { ended.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    struct Indexed { let item: TVItem; let f: String; let youth: Bool }

    static func index(_ live: [TVItem]) -> [Indexed] {
        live.compactMap { ch in
            if isSeparator(ch.name) { return nil }
            let f = fold(ch.name)
            if isEnded(f) { return nil }
            return Indexed(item: ch, f: f, youth: isYouth(f))
        }
    }

    /// Sender, die beide Vereine im Namen tragen
    static func channels(_ m: FMatch, _ idx: [Indexed]) -> [TVItem] {
        let hw = words(m.h), aw = words(m.a)
        if hw.isEmpty || aw.isEmpty { return [] }
        let teamYouth = isYouth(fold(m.h.n + " " + m.a.n))
        var out: [TVItem] = []
        for it in idx {
            if !teamYouth && it.youth { continue }
            if hw.contains(where: { has(it.f, $0) }) && aw.contains(where: { has(it.f, $0) }) { out.append(it.item) }
            if out.count >= 20 { break }
        }
        return out
    }
}

@MainActor
final class FootballData: ObservableObject {
    @Published var matches: [FMatch] = []
    @Published var error: String?
    @Published var loading = false
    private var loadedAt = Date.distantPast

    func load(force: Bool = false) async {
        if !force && Date().timeIntervalSince(loadedAt) < 60 && !matches.isEmpty { return }
        guard let url = URL(string: RemoteConfig.website + "api/fussball") else { return }
        loading = true
        defer { loading = false }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(FResponse.self, from: data)
            if res.ok, let list = res.matches {
                matches = list.sorted { $0.t < $1.t }
                error = nil
                loadedAt = Date()
            } else {
                error = res.error == "nokey" ? "Der Fußball-Spielplan ist noch nicht eingerichtet." : "Der Spielplan ist gerade nicht erreichbar."
            }
        } catch {
            if matches.isEmpty { self.error = "Der Spielplan ist gerade nicht erreichbar. Bitte später noch einmal versuchen." }
        }
    }
}

struct FootballScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @StateObject private var data = FootballData()

    enum F: Hashable { case lg(String), m(String) }
    @FocusState private var focus: F?
    @State private var league = ""
    @State private var idx: [FB.Indexed] = []
    @State private var found: [String: [TVItem]] = [:]
    @State private var choose: (FMatch, [TVItem])?
    @State private var note: String?

    private var list: [FMatch] {
        data.matches.filter { m in
            if league == "__live" { return m.isLive }
            return league.isEmpty || m.c == league
        }
    }

    private var days: [(String, [FMatch])] {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"
        let cal = Calendar.current
        var out: [(String, [FMatch])] = []
        for m in list {
            let key: String
            if cal.isDateInToday(m.date) { key = "Heute" } else if cal.isDateInTomorrow(m.date) { key = "Morgen" }
            else if cal.isDateInYesterday(m.date) { key = "Gestern" } else { key = f.string(from: m.date) }
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(m) } else { out.append((key, [m])) }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Fußball")
            Text("OK: Sender suchen und abspielen").font(UI.font(24)).foregroundColor(UI.muted)
                .place(1100, 44, 570, 34, alignment: .topTrailing)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(FB.leagues, id: \.0) { lg in
                        let n = lg.0 == "__live" ? data.matches.filter(\.isLive).count : (lg.0.isEmpty ? data.matches.count : data.matches.filter { $0.c == lg.0 }.count)
                        CatRow(name: lg.1, count: n, active: league == lg.0) { league = lg.0 }
                            .focused($focus, equals: .lg(lg.0))
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 10)
            }
            .place(20, 100, 400, 970)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if data.loading && data.matches.isEmpty {
                        ProgressView().scaleEffect(1.6).tint(UI.gold).padding(60)
                    } else if let e = data.error, data.matches.isEmpty {
                        Text(e).font(UI.font(28)).foregroundColor(UI.muted).padding(40)
                    } else if list.isEmpty {
                        Text(league == "__live" ? "Gerade läuft kein Spiel." : "Keine Spiele").font(UI.font(28)).foregroundColor(UI.muted).padding(40)
                    }
                    ForEach(days, id: \.0) { day in
                        SectionHead(text: day.0).padding(.top, 10)
                        ForEach(day.1) { m in
                            row(m).focused($focus, equals: .m(m.id))
                        }
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 12)
            }
            .place(424, 100, 1470, 980)

            if let c = choose { chooser(c.0, c.1) }
            if let n = note {
                Text(n).font(UI.font(26, .semibold)).foregroundColor(UI.text)
                    .padding(.horizontal, 30).padding(.vertical, 18)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(UI.tan(0.5), lineWidth: 1.5))
                    .place(0, 960, 1920, 90, alignment: .center)
            }
        }
        .frame(width: 1920, height: 1080)
        .onChange(of: focus) { _, f in if case .lg(let l)? = f { league = l } }
        .task {
            idx = FB.index(store.live)
            await data.load()
            recompute()
            // während Spiele laufen: alle 60 s neu laden (Spielstand)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await data.load(force: true)
                recompute()
            }
        }
        .onExitCommand(perform: choose != nil ? { choose = nil } : nil)
    }

    private func recompute() {
        var out: [String: [TVItem]] = [:]
        for m in data.matches where !m.isOver {
            let l = FB.channels(m, idx)
            if !l.isEmpty { out[m.id] = l }
        }
        found = out
    }

    private func row(_ m: FMatch) -> some View {
        let chs = found[m.id] ?? []
        let time = hhmm.string(from: m.date)
        return Button { open(m) } label: {
            HStack(spacing: 18) {
                Text(time).font(.system(size: 26, weight: .bold).monospacedDigit()).frame(width: 90, alignment: .leading)
                Text(FB.short[m.c] ?? m.c).font(UI.font(17, .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FB.color(m.c)))
                    .frame(width: 92, alignment: .leading)
                team(m.h, right: true)
                Text(m.hasScore ? "\(m.sc[0] ?? 0) : \(m.sc[1] ?? 0)" : "–")
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundColor(m.isLive ? Color(rgb: 0xff6b5e) : UI.muted)
                    .frame(width: 110)
                team(m.a, right: false)
                VStack(alignment: .trailing, spacing: 4) {
                    if !m.stateText.isEmpty {
                        Text(m.stateText).font(UI.font(20, .bold)).foregroundColor(m.isLive ? Color(rgb: 0xff6b5e) : UI.muted)
                    }
                    if let ch = chs.first {
                        Text("▶ " + ch.name + (chs.count > 1 ? "  +\(chs.count - 1)" : "")).font(UI.font(20, .semibold))
                            .foregroundColor(UI.gold).lineLimit(1)
                    }
                }
                .frame(width: 330, alignment: .trailing)
            }
            .padding(.horizontal, 20).frame(height: 84)
        }
        .buttonStyle(GoldStyle(normal: .black.opacity(0.3)))
    }

    private func team(_ t: FTeam, right: Bool) -> some View {
        HStack(spacing: 12) {
            if right { Spacer(minLength: 0) }
            if !right { crest(t) }
            Text(t.display).font(UI.font(26, .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            if right { crest(t) }
            if !right { Spacer(minLength: 0) }
        }
        .frame(width: 320)
    }

    @ViewBuilder private func crest(_ t: FTeam) -> some View {
        if let s = t.l, !s.isEmpty, let u = URL(string: s) {
            AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: 40, height: 40)
        } else {
            Color.clear.frame(width: 40, height: 40)
        }
    }

    private func open(_ m: FMatch) {
        let chs = found[m.id] ?? FB.channels(m, idx)
        if chs.isEmpty {
            show("Kein Sender in deiner Liste trägt „\(m.h.display)“ und „\(m.a.display)“ im Namen.")
            return
        }
        if chs.count == 1 { play(chs[0], chs); return }
        choose = (m, chs)
    }

    private func chooser(_ m: FMatch, _ chs: [TVItem]) -> some View {
        ZStack {
            Color.black.opacity(0.65)
            VStack(alignment: .leading, spacing: 10) {
                Text("\(m.h.display) – \(m.a.display)").font(UI.font(34, .bold)).foregroundColor(UI.gold)
                Text("Welcher Sender?").font(UI.font(24)).foregroundColor(UI.muted).padding(.bottom, 10)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(chs) { ch in
                            Button { choose = nil; play(ch, chs) } label: {
                                HStack(spacing: 18) {
                                    ArtView(art: ch.art).frame(width: 84, height: 56).clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(ch.name).font(UI.font(26, .semibold)).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 18).frame(height: 76)
                            }
                            .buttonStyle(GoldStyle(normal: .white.opacity(0.05)))
                        }
                    }
                    .padding(8)
                }
            }
            .padding(40)
            .frame(width: 900, height: 700)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(rgb: 0x16151a)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(UI.tan(0.5), lineWidth: 1.5))
        }
        .frame(width: 1920, height: 1080)
        .focusSection()
    }

    private func play(_ ch: TVItem, _ all: [TVItem]) {
        guard let u = store.url(ch, .live) else { return }
        engine.items = all
        engine.index = all.firstIndex(of: ch) ?? 0
        engine.play(u, item: ch, kind: .live)
        nav.push(.player)
    }

    private func show(_ t: String) {
        note = t
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); note = nil }
    }
}
