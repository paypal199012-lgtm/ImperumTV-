import SwiftUI

// MARK: - Fußball: Spielplan von der Website + passende Sender aus der eigenen Liste
//
// Der Spielplan kommt von der ImperumTV-Website (/api/fussball, kostenlose Quellen zusammengelegt).
// Sender werden nur angezeigt, wenn das Spiel nachweislich dort läuft:
//  - Event-Sender: beide Vereine stehen im Sendernamen („Live | Milan vs. Inter“)
//  - laut Programm: zur Anstoßzeit steht ein Verein (oder „Konferenz“) im Programm des Senders

struct FBTeam: Decodable, Hashable {
    let n: String
    let s: String
    let l: String?
    var display: String { s.isEmpty ? n : s }
}

struct FBMatch: Decodable, Identifiable, Hashable {
    let id: String
    let c: String
    let t: Double
    let s: String
    let h: FBTeam
    let a: FBTeam
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
        h = try k.decode(FBTeam.self, forKey: .h)
        a = try k.decode(FBTeam.self, forKey: .a)
        sc = (try? k.decode([Int?].self, forKey: .sc)) ?? [nil, nil]
        mn = try? k.decode(String.self, forKey: .mn)
    }
    static func == (l: FBMatch, r: FBMatch) -> Bool { l.id == r.id && l.s == r.s && l.sc == r.sc && l.mn == r.mn }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct FBResponse: Decodable {
    let ok: Bool
    let error: String?
    let matches: [FBMatch]?
}

enum Football {
    static let leagues: [(String, String)] = [("", "Alle"), ("BL1", "Bundesliga"), ("BL2", "2. Liga"), ("DFB", "DFB-Pokal"),
        ("CL", "Champions League"), ("EL", "Europa League"), ("ECL", "Conference L."), ("PL", "Premier League"),
        ("SA", "Serie A"), ("PD", "LaLiga"), ("FL1", "Ligue 1")]
    static let short: [String: String] = ["BL1": "BL", "BL2": "2.BL", "DFB": "POK", "CL": "CL", "EL": "EL", "ECL": "ECL",
        "PL": "PL", "SA": "SA", "PD": "LL", "FL1": "L1"]
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

    /// Suchwörter einer Mannschaft, z. B. „bayern“, „dortmund“, „inter“
    static func words(_ team: FBTeam) -> [String] {
        var out: [String] = []
        for name in [team.s, team.n] {
            for w in fold(name).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            where w.count >= 4 && !stop.contains(w) && !out.contains(w) { out.append(w) }
        }
        return Array(out.prefix(3))
    }

    /// Wort enthalten? Kurze Wörter nur als ganzes Wort
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
    private static func isYouth(_ s: String) -> Bool { youth.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Event-Sender, die beide Vereine im Namen tragen
    static func eventChannels(_ m: FBMatch, in channels: [Channel]) -> [Channel] {
        let hw = words(m.h), aw = words(m.a)
        if hw.isEmpty || aw.isEmpty { return [] }
        let teamYouth = isYouth(fold(m.h.n + " " + m.a.n))
        var out: [Channel] = []
        for ch in channels where !isSeparator(ch.name) {
            let f = fold(ch.name)
            if !teamYouth && isYouth(f) { continue }
            if hw.contains(where: { has(f, $0) }) && aw.contains(where: { has(f, $0) }) { out.append(ch) }
            if out.count >= 20 { break }
        }
        return out
    }

    /// Üblicher Rechteinhaber in Deutschland (nur als grauer Hinweis)
    static func rights(_ m: FBMatch) -> String {
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.component(.weekday, from: m.date)   // 1 = Sonntag
        let hr = cal.component(.hour, from: m.date)
        switch m.c {
        case "BL1": return wd == 1 ? "DAZN" : (wd == 7 && hr < 17 ? "Sky · Konferenz DAZN" : "Sky")
        case "BL2": return "Sky"
        case "DFB": return "Sky · ARD/ZDF"
        case "EL", "ECL": return "RTL+"
        case "PL": return "Sky"
        case "SA", "PD", "FL1": return "DAZN"
        case "CL": return wd == 3 ? "DAZN · Prime Video" : "DAZN"
        default: return ""
        }
    }

    /// Welche Sender könnten es zeigen? (werden danach im Programm geprüft)
    static func candidates(_ m: FBMatch, in channels: [Channel]) -> [Channel] {
        func match(_ pattern: String) -> [Channel] {
            channels.filter { !isSeparator($0.name) && $0.name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        var list: [Channel] = []
        switch m.c {
        case "BL1", "BL2", "DFB": list = match("sky.*(bundesliga|buli|top ?event)") + match("dazn") + match("konferenz") + match("(^|[^a-z])(ard|das erste|zdf)([^a-z]|$)")
        case "PL": list = match("sky.*(premier|top ?event|mix)")
        case "SA", "PD", "FL1": list = match("dazn")
        case "CL": list = match("dazn") + match("prime|amazon")
        case "EL", "ECL": list = match("(^|[^a-z])(rtl|nitro)([^a-z]|$)")
        default: list = []
        }
        var seen = Set<Int>()
        return Array(list.filter { seen.insert($0.id).inserted }.prefix(40))
    }
}

@MainActor
final class FootballStore: ObservableObject {
    static let shared = FootballStore()
    @Published var matches: [FBMatch] = []
    @Published var error: String?
    @Published var loading = false
    private var loadedAt = Date.distantPast

    func load(force: Bool = false) async {
        if !force && Date().timeIntervalSince(loadedAt) < 90 && !matches.isEmpty { return }
        guard let url = URL(string: RemoteConfig.website + "api/fussball") else { return }
        loading = true
        defer { loading = false }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(FBResponse.self, from: data)
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

// MARK: - Ansicht

struct FootballView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var fb = FootballStore.shared
    @State private var league = ""
    @State private var request: PlayRequest?
    @State private var choice: FBChoice?
    @State private var searching: String?
    @State private var note: String?
    @State private var events: [String: [Channel]] = [:]

    private var shown: [FBMatch] {
        let old = Date().addingTimeInterval(-6 * 3600)
        return fb.matches.filter { m in
            (league.isEmpty || m.c == league) && m.s != "CANCELLED" && !(m.isOver && m.date < old)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Football.leagues, id: \.0) { item in
                        Button { league = item.0 } label: {
                            Text(item.1)
                                .font(.subheadline.weight(league == item.0 ? .bold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundStyle(league == item.0 ? Color.black : Color.white)
                                .background(Capsule().fill(league == item.0 ? Theme.goldLight : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }

            if let err = fb.error, fb.matches.isEmpty {
                Spacer()
                Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                Spacer()
            } else if fb.matches.isEmpty {
                Spacer()
                ProgressView("Spielplan wird geladen …").tint(Theme.gold)
                Spacer()
            } else if shown.isEmpty {
                Spacer()
                Text("In den nächsten Tagen keine Spiele.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        ForEach(groupedByDay(shown), id: \.0) { day, list in
                            Text(day)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.goldLight)
                                .padding(.top, 10).padding(.leading, 4)
                            ForEach(list) { m in
                                FBRow(match: m, channel: events[m.id]?.first, extra: max(0, (events[m.id]?.count ?? 0) - 1),
                                      busy: searching == m.id)
                                    .onTapGesture { Task { await open(m) } }
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 20)
                }
                .refreshable { await fb.load(force: true) }
            }
        }
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Fußball")
        .overlay(alignment: .bottom) {
            if let note {
                Text(note)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.goldLight)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.85)))
                    .padding(20)
                    .task(id: note) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if self.note == note { self.note = nil }
                    }
            }
        }
        .task {
            await fb.load()
            computeEvents()
            // Live-Stände regelmäßig auffrischen
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                await fb.load(force: true)
                computeEvents()
            }
        }
        .confirmationDialog(choice?.title ?? "", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                            titleVisibility: .visible) {
            if let c = choice {
                ForEach(c.channels.prefix(12), id: \.id) { ch in
                    Button("▶ " + ch.name) { play(ch) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(choice?.subtitle ?? "")
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: true)
                .environmentObject(store)
        }
    }

    private func computeEvents() {
        var map: [String: [Channel]] = [:]
        let live = store.channels
        for m in fb.matches where !m.isOver {
            let ev = Football.eventChannels(m, in: live)
            if !ev.isEmpty { map[m.id] = ev }
        }
        events = map
    }

    private func groupedByDay(_ list: [FBMatch]) -> [(String, [FBMatch])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM"
        var out: [(String, [FBMatch])] = []
        for m in list {
            var label = f.string(from: m.date)
            if cal.isDateInToday(m.date) { label = "Heute · " + label }
            else if cal.isDateInTomorrow(m.date) { label = "Morgen · " + label }
            else if cal.isDateInYesterday(m.date) { label = "Gestern · " + label }
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(m) } else { out.append((label, [m])) }
        }
        return out
    }

    private func play(_ ch: Channel) {
        let all = store.channels
        let i = all.firstIndex(where: { $0.id == ch.id }) ?? 0
        request = PlayRequest(channels: all.isEmpty ? [ch] : all, index: all.isEmpty ? 0 : i, isLive: true)
    }

    /// Sender finden, die das Spiel nachweislich zeigen
    private func open(_ m: FBMatch) async {
        let title = m.h.display + " – " + m.a.display
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let when = tf.string(from: m.date) + " Uhr"
        var found = events[m.id] ?? []
        // Programm der in Frage kommenden Sender zur Anstoßzeit prüfen
        if !m.isOver && store.isXtream {
            searching = m.id
            let words = Football.words(m.h) + Football.words(m.a)
            let kick = m.date
            let cands = Football.candidates(m, in: store.channels).filter { c in !found.contains(where: { $0.id == c.id }) }
            var prog: [Channel] = [], konf: [Channel] = []
            let st = store
            await withTaskGroup(of: (Channel, Int).self) { group in
                for ch in cands {
                    group.addTask {
                        let list = await st.shortEPG(streamId: ch.id)
                        guard let e = list.first(where: { ($0.start ?? .distantFuture) <= kick.addingTimeInterval(900)
                            && ($0.end ?? .distantPast) >= kick.addingTimeInterval(1200) }) else { return (ch, 0) }
                        let text = Football.fold(e.title + " " + (e.desc ?? ""))
                        if words.contains(where: { Football.has(text, $0) }) { return (ch, 2) }
                        if text.contains("konferenz") && (m.c == "BL1" || m.c == "BL2") { return (ch, 1) }
                        return (ch, 0)
                    }
                }
                for await (ch, hit) in group {
                    if hit == 2 { prog.append(ch) } else if hit == 1 { konf.append(ch) }
                }
            }
            searching = nil
            found += prog + konf
        }
        if found.isEmpty {
            let r = Football.rights(m)
            note = title + ": kein passender Sender in deiner Liste gefunden" + (r.isEmpty ? "." : " (voraussichtlich " + r + ").")
            return
        }
        if found.count == 1 { play(found[0]); return }
        choice = FBChoice(title: title, subtitle: when, channels: found)
    }
}

struct FBChoice {
    let title: String
    let subtitle: String
    let channels: [Channel]
}

private struct FBRow: View {
    let match: FBMatch
    let channel: Channel?
    let extra: Int
    let busy: Bool

    var body: some View {
        let m = match
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(timeText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(Football.short[m.c] ?? m.c)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Football.color(m.c)))
                Spacer()
                if m.isLive {
                    Text(stateText).font(.caption.weight(.bold)).foregroundStyle(.red)
                } else if m.isOver {
                    Text("Ende").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                } else if m.s == "POSTPONED" {
                    Text("verlegt").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                team(m.h, alignRight: true)
                Text(m.hasScore ? "\(m.sc[0] ?? 0) : \(m.sc[1] ?? 0)" : "–")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(m.isLive ? Color.red : Color.secondary)
                    .frame(minWidth: 52)
                team(m.a, alignRight: false)
            }
            if !m.isOver {
                HStack(spacing: 6) {
                    if busy { ProgressView().scaleEffect(0.7).tint(Theme.gold) }
                    if let ch = channel {
                        Text("▶ " + ch.name + (extra > 0 ? "  +\(extra)" : ""))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.goldLight)
                            .lineLimit(1)
                    } else {
                        Text(Football.rights(m))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
    }

    private var timeText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: match.date)
    }

    private var stateText: String {
        switch match.s {
        case "PAUSED": return "HALBZEIT"
        case "EXTRA_TIME": return "VERLÄNGERUNG"
        case "PENALTY_SHOOTOUT": return "ELFMETER"
        case "SUSPENDED": return "UNTERBROCHEN"
        default: return "LIVE" + ((match.mn ?? "").isEmpty ? "" : " " + (match.mn ?? ""))
        }
    }

    @ViewBuilder
    private func team(_ t: FBTeam, alignRight: Bool) -> some View {
        HStack(spacing: 6) {
            if alignRight { Spacer(minLength: 0) }
            if !alignRight { crest(t) }
            Text(t.display)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if alignRight { crest(t) }
            if !alignRight { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func crest(_ t: FBTeam) -> some View {
        if let s = t.l, let url = URL(string: s), !s.isEmpty {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: 22, height: 22)
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }
}
