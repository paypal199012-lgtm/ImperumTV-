import SwiftUI
import CryptoKit

// MARK: - Farbthemen (wie Android: Goldtöne werden umgefärbt, Logo passend getönt)

struct ThemeDef {
    let id: String
    let name: String
    let hue: Double?        // nil = Gold (Original)
    let sat: Double
    let light: Double
    let logoHue: Double     // Grad
    let logoSat: Double
    let gray: Bool
}

enum Theme {
    static let all: [ThemeDef] = [
        ThemeDef(id: "gold", name: "Gold", hue: nil, sat: 1, light: 1, logoHue: 0, logoSat: 1, gray: false),
        ThemeDef(id: "blau", name: "Blau", hue: 212, sat: 1.0, light: 1, logoHue: 175, logoSat: 1.2, gray: false),
        ThemeDef(id: "silber", name: "Silber", hue: 0, sat: 0, light: 1.06, logoHue: 0, logoSat: 0, gray: true),
        ThemeDef(id: "smaragd", name: "Smaragd", hue: 150, sat: 0.95, light: 1, logoHue: 95, logoSat: 1.1, gray: false),
        ThemeDef(id: "pink", name: "Pink", hue: 322, sat: 1.15, light: 1, logoHue: -95, logoSat: 1.6, gray: false),
        ThemeDef(id: "violett", name: "Violett", hue: 268, sat: 0.95, light: 1, logoHue: 225, logoSat: 1.2, gray: false),
        ThemeDef(id: "tuerkis", name: "Türkis", hue: 178, sat: 1.0, light: 1, logoHue: 135, logoSat: 1.3, gray: false),
        ThemeDef(id: "kobalt", name: "Kobalt", hue: 230, sat: 1.35, light: 1, logoHue: 195, logoSat: 1.8, gray: false)
    ]

    static var currentId: String {
        get { UserDefaults.standard.string(forKey: "tv.theme") ?? "gold" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.theme") }
    }
    static var current: ThemeDef { all.first { $0.id == currentId } ?? all[0] }

    /// Goldton in das Farbthema umrechnen (Helligkeit bleibt, Farbton wechselt)
    static func color(_ rgb: UInt32, _ opacity: Double = 1) -> Color {
        let t = current
        guard let hue = t.hue else { return Color(rgb: rgb, opacity: opacity) }
        let r = Double((rgb >> 16) & 0xff) / 255, g = Double((rgb >> 8) & 0xff) / 255, b = Double(rgb & 0xff) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let s = mx == mn ? 0 : (l > 0.5 ? (mx - mn) / (2 - mx - mn) : (mx - mn) / (mx + mn))
        let s2 = min(1, s * t.sat), l2 = min(1, l * t.light)
        // HSL → RGB
        func f(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let a = s2 * min(l2, 1 - l2)
            return l2 - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return Color(.sRGB, red: f(0), green: f(8), blue: f(4), opacity: opacity)
    }
}

extension View {
    /// Logo im Farbthema
    func themedLogo() -> some View {
        let t = Theme.current
        return self.hueRotation(.degrees(t.logoHue)).saturation(t.gray ? 0 : t.logoSat).brightness(t.gray ? 0.04 : 0)
    }
}

// MARK: - Profile (eigene Favoriten und „Weiterschauen“; Kinderprofil ohne gesperrte Kategorien)

struct TVProfile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kids: Bool
}

enum Profiles {
    static var list: [TVProfile] {
        get {
            if let d = UserDefaults.standard.data(forKey: "tv.profiles"), let l = try? JSONDecoder().decode([TVProfile].self, from: d), !l.isEmpty { return l }
            return [TVProfile(id: "p0", name: "Hauptprofil", kids: false)]
        }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "tv.profiles") } }
    }
    static var currentId: String {
        get { UserDefaults.standard.string(forKey: "tv.profile") ?? "p0" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.profile") }
    }
    static var current: TVProfile { list.first { $0.id == currentId } ?? list[0] }
    static var isKids: Bool { current.kids }
}

// MARK: - Kindersicherung (PIN, Erwachsenen-Kategorien automatisch, eigene Kategorien sperren)

enum Parental {
    static let adult = try! NSRegularExpression(pattern: "(^|[^a-z])(xxx|adult|adults|erwachsene?|for adults|18\\s*\\+|\\+\\s*18|porn|porno|sex|sexy|erotik|erotic|hot\\s*club|playboy|hustler|brazzers|redlight|private)([^a-z]|$)", options: [.caseInsensitive])

    static func hash(_ pin: String) -> String {
        let d = SHA256.hash(data: Data(("imperum-pin:" + pin + ":" + DeviceIdentity.load().key).utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
    static var pinHash: String {
        get { UserDefaults.standard.string(forKey: "tv.pin") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.pin") }
    }
    static var hasPin: Bool { !pinHash.isEmpty }
    static func check(_ pin: String) -> Bool { hasPin && hash(pin) == pinHash }
    static var autoAdult: Bool {
        get { UserDefaults.standard.object(forKey: "tv.pinAdult") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.pinAdult") }
    }
    static var lockedCats: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "tv.pinCats") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "tv.pinCats") }
    }
    static var unlockedUntil = Date.distantPast
    static var unlocked: Bool { !Profiles.isKids && Date() < unlockedUntil }
    static var enabled: Bool { hasPin || Profiles.isKids }

    static func isAdult(_ name: String) -> Bool {
        adult.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
    /// Kategorie geschützt?
    static func protected(_ kind: MediaKind, _ catName: String) -> Bool {
        guard enabled else { return false }
        if autoAdult && isAdult(catName) { return true }
        if Profiles.isKids && isAdult(catName) { return true }
        return lockedCats.contains(kind.rawValue + ":" + catName)
    }
    static func locked(_ kind: MediaKind, _ catName: String) -> Bool { !unlocked && protected(kind, catName) }
}

/// PIN-Abfrage (4 Ziffern über die Tastatur des Apple TV)
struct PinPrompt: View {
    let title: String
    let onDone: (String?) -> Void
    @State private var pin = ""
    @FocusState private var field: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 24) {
                Text(title).font(UI.font(34, .bold)).foregroundColor(UI.gold)
                SecureField("PIN (4 Ziffern)", text: $pin)
                    .keyboardType(.numberPad)
                    .font(UI.font(30))
                    .frame(width: 500)
                    .focused($field)
                    .onSubmit { onDone(pin) }
                HStack(spacing: 20) {
                    Button { onDone(pin) } label: { Text("OK").font(UI.font(26, .bold)).padding(.horizontal, 40).frame(height: 60) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                    Button { onDone(nil) } label: { Text("Abbrechen").font(UI.font(26, .bold)).padding(.horizontal, 40).frame(height: 60) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.1), ring: false, solid: true))
                }
            }
            .padding(50)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(rgb: 0x16151a)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(UI.tan(0.5), lineWidth: 1.5))
        }
        .frame(width: 1920, height: 1080)
        .focusSection()
        .onAppear { field = true }
        .onExitCommand { onDone(nil) }
    }
}

// MARK: - Einstellungen

struct SettingsScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook
    @AppStorage("tv.theme") private var theme = "gold"
    @State private var pinMode: String?          // "set", "check-off"
    @State private var note: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Einstellungen")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHead(text: "Wiedergabe & Listen")
                    row("list", "Wiedergabelisten", store.sourceName.isEmpty ? "Keine gewählt" : store.sourceName) { nav.push(.playlists) }
                    row("users", "Profil", Profiles.current.name + (Profiles.isKids ? " · Kinder" : "")) { nav.push(.profiles) }
                    row("refresh", "Neu laden", "Sender, Filme, Serien") { Task { await store.reload() } }

                    SectionHead(text: "Player")
                    row("tv", "Player Live TV", engine.liveEngine == "vlc" ? "VLC" : "Automatisch") {
                        engine.liveEngine = engine.liveEngine == "vlc" ? "auto" : "vlc"
                    }
                    row("refresh", "Ersatzsender bei Hängern", engine.autoAlt ? "An" : "Aus") { engine.autoAlt.toggle() }
                    row("clock", "Puffer", engine.bufferMode == "small" ? "Klein · schneller Start" : engine.bufferMode == "large" ? "Groß · stabiler" : "Normal") {
                        engine.bufferMode = engine.bufferMode == "normal" ? "large" : engine.bufferMode == "large" ? "small" : "normal"
                    }
                    row("device", "Bildformat", engine.gravity == "fill" ? "Zoomen" : engine.gravity == "stretch" ? "Strecken" : "Ganzes Bild") {
                        engine.setGravity(engine.gravity == "fit" ? "fill" : engine.gravity == "fill" ? "stretch" : "fit")
                    }
                    row("clock", "Schlaf-Timer", engine.sleepAt.map { "noch \(max(1, Int($0.timeIntervalSinceNow / 60))) Min" } ?? "Aus") {
                        let steps: [Int] = [0, 30, 60, 90, 120]
                        let cur = engine.sleepAt.map { Int(($0.timeIntervalSinceNow / 60).rounded()) } ?? 0
                        let next = steps.first { $0 > cur + 1 } ?? 0
                        engine.sleepAt = next == 0 ? nil : Date().addingTimeInterval(Double(next) * 60)
                    }
                    row("speed", "Verbindungstest", "Internet & Sender") { nav.push(.nettest) }

                    SectionHead(text: "Anzeige & Familie")
                    row("star", "Farbthema", Theme.current.name) {
                        let ids = Theme.all.map(\.id)
                        let i = ids.firstIndex(of: theme) ?? 0
                        theme = ids[(i + 1) % ids.count]
                        Theme.currentId = theme
                    }
                    row("lock", "Kindersicherung", Parental.hasPin ? "An · PIN gesetzt" : "Aus") {
                        pinMode = Parental.hasPin ? "check-off" : "set"
                    }
                    if Parental.hasPin {
                        row("lock", "Erwachsenen-Kategorien sperren", Parental.autoAdult ? "An" : "Aus") {
                            Parental.autoAdult.toggle(); store.objectWillChange.send()
                        }
                        row("lock", "Kategorien sperren", "\(Parental.lockedCats.count) gesperrt") { nav.push(.lockCats) }
                    }

                    SectionHead(text: "Daten")
                    row("resume", "Weiterschauen & Gesehen löschen", "\(resume.entries.count) angefangen · \(resume.seen.count) gesehen") {
                        resume.clearAll(); show("Gelöscht")
                    }
                    row("star", "Favoriten löschen", "\(store.favorites.count) gespeichert") {
                        store.clearFavorites(); show("Favoriten gelöscht")
                    }
                    row("device", "Gerät", "MAC \(store.device.mac.lowercased()) · Schlüssel \(store.device.key)") { nav.push(.playlists) }
                    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
                    Text("ImperumTV für Apple TV · Version \(v) (\(b))" + (PlayerEngine.hasVLC ? " · VLC" : ""))
                        .font(UI.font(22)).foregroundColor(UI.muted).padding(.top, 20)
                }
                .padding(.vertical, 20).padding(.horizontal, 20)
            }
            .place(260, 110, 1400, 960)

            if let n = note {
                Text(n).font(UI.font(26, .semibold)).padding(.horizontal, 30).padding(.vertical, 16)
                    .background(Capsule().fill(.black.opacity(0.85))).overlay(Capsule().stroke(UI.tan(0.5), lineWidth: 1.5))
                    .place(0, 980, 1920, 70, alignment: .center)
            }
            if let m = pinMode {
                PinPrompt(title: m == "set" ? "Neue PIN festlegen" : "PIN eingeben (Kindersicherung aus)") { pin in
                    pinMode = nil
                    guard let pin = pin, pin.count >= 4, pin.allSatisfy(\.isNumber) else { if pin != nil { show("Die PIN braucht 4 Ziffern") }; return }
                    if m == "set" { Parental.pinHash = Parental.hash(pin); show("Kindersicherung an") }
                    else if Parental.check(pin) { Parental.pinHash = ""; show("Kindersicherung aus") }
                    else { show("Falsche PIN") }
                    store.objectWillChange.send()
                }
            }
        }
        .frame(width: 1920, height: 1080)
    }

    private func show(_ t: String) {
        note = t
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if note == t { note = nil } }
    }

    private func row(_ icon: String, _ title: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Icon(icon, 36).foregroundColor(UI.gold)
                Text(title).font(UI.font(28, .semibold))
                Spacer()
                Text(value).font(UI.font(23)).foregroundColor(UI.muted).lineLimit(1)
            }
            .padding(.horizontal, 30).frame(height: 80)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 14)), normal: .black.opacity(0.35),
                               border: .white.opacity(0.1), borderWidth: 1.5))
    }
}

// MARK: - Profile verwalten

struct ProfilesScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var resume: ResumeBook
    @State private var list = Profiles.list
    @State private var newName = ""
    @State private var newKids = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Wer schaut?")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 40) {
                    ForEach(list) { p in
                        Button { choose(p) } label: {
                            VStack(spacing: 16) {
                                Text(String(p.name.prefix(1)).uppercased()).font(.system(size: 90, weight: .bold))
                                    .frame(width: 220, height: 220)
                                    .background(Circle().fill(p.kids ? Color(rgb: 0x3a7a4a) : UI.tan(0.35)))
                                Text(p.name).font(UI.font(30, .semibold)).lineLimit(1)
                                Text(p.id == Profiles.currentId ? "● Aktiv" : (p.kids ? "Kinder" : " ")).font(UI.font(20)).foregroundColor(UI.gold2)
                            }
                            .padding(24)
                        }
                        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 24)), scale: 1.05))
                        .contextMenu {
                            if p.id != "p0" { Button("Profil löschen", role: .destructive) { remove(p) } }
                        }
                    }
                }
                .padding(40)
            }
            .place(60, 150, 1800, 460)

            VStack(alignment: .leading, spacing: 18) {
                Text("Neues Profil").font(UI.font(28, .bold)).foregroundColor(UI.gold)
                HStack(spacing: 20) {
                    TextField("Name", text: $newName).font(UI.font(26)).frame(width: 520)
                    Button { newKids.toggle() } label: { Text(newKids ? "✓ Kinderprofil" : "Kinderprofil").font(UI.font(24, .bold)).padding(.horizontal, 28).frame(height: 60) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: newKids ? UI.tan(0.4) : .white.opacity(0.08), ring: false, solid: true))
                    Button { add() } label: { Text("+ Anlegen").font(UI.font(24, .bold)).padding(.horizontal, 28).frame(height: 60) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                }
                Text("Jedes Profil hat eigene Favoriten und eigenes „Weiterschauen“. Kinderprofile zeigen keine Erwachsenen-Kategorien. Profil löschen: OK lange drücken.")
                    .font(UI.font(21)).foregroundColor(UI.muted)
            }
            .place(120, 660, 1700, 260)
        }
        .frame(width: 1920, height: 1080)
    }

    private func choose(_ p: TVProfile) {
        Profiles.currentId = p.id
        store.setProfile(p.id)
        resume.setProfile(p.id)
        nav.reset(.home)
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, list.count < 8 else { return }
        list.append(TVProfile(id: "p" + String(Int(Date().timeIntervalSince1970)), name: n, kids: newKids))
        Profiles.list = list
        newName = ""; newKids = false
    }

    private func remove(_ p: TVProfile) {
        list.removeAll { $0.id == p.id }
        Profiles.list = list
        if Profiles.currentId == p.id { choose(list[0]) }
    }
}

// MARK: - Kategorien sperren

struct LockCatsScreen: View {
    @EnvironmentObject var store: TVStore
    @State private var kind: MediaKind = .live
    @State private var locked = Parental.lockedCats

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Kategorien sperren")
            HStack(spacing: 14) {
                ForEach([(MediaKind.live, "Live TV"), (.movie, "Filme"), (.series, "Serien")], id: \.0) { k in
                    Button { kind = k.0 } label: { Text(k.1).font(UI.font(24, .bold)).padding(.horizontal, 30).frame(height: 56) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: kind == k.0 ? UI.tan(0.45) : .white.opacity(0.08), ring: false, solid: true))
                }
            }
            .place(70, 110, 1200, 70)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.cats(kind)) { c in
                        let key = kind.rawValue + ":" + c.name
                        let auto = Parental.autoAdult && Parental.isAdult(c.name)
                        Button {
                            if locked.contains(key) { locked.remove(key) } else { locked.insert(key) }
                            Parental.lockedCats = locked
                        } label: {
                            HStack {
                                Text(c.name).font(UI.font(26, .medium)).lineLimit(1)
                                Spacer()
                                Text(auto ? "🔒 automatisch" : locked.contains(key) ? "🔒 gesperrt" : "frei").font(UI.font(22)).foregroundColor(UI.muted)
                            }
                            .padding(.horizontal, 24).frame(height: 64)
                        }
                        .buttonStyle(GoldStyle(normal: .black.opacity(0.3), active: locked.contains(key) || auto))
                    }
                }
                .padding(12)
            }
            .place(60, 200, 1800, 860)
        }
        .frame(width: 1920, height: 1080)
    }
}

// MARK: - Verbindungstest

struct NetTestScreen: View {
    @EnvironmentObject var store: TVStore
    @State private var lines: [(String, String, Bool?)] = []
    @State private var running = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Verbindungstest")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 20) {
                        Text(l.2 == nil ? "…" : l.2! ? "✓" : "✕").font(UI.font(30, .bold))
                            .foregroundColor(l.2 == nil ? UI.muted : l.2! ? Color(rgb: 0x7ee08a) : Color(rgb: 0xff8a7a)).frame(width: 40)
                        Text(l.0).font(UI.font(28, .semibold)).frame(width: 520, alignment: .leading)
                        Text(l.1).font(UI.font(26)).foregroundColor(UI.gold)
                    }
                }
                Button { Task { await run() } } label: {
                    Text(running ? "Test läuft …" : "Erneut testen").font(UI.font(26, .bold)).padding(.horizontal, 40).frame(height: 64)
                }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                .disabled(running)
                .padding(.top, 30)
            }
            .place(200, 180, 1500, 800)
        }
        .frame(width: 1920, height: 1080)
        .task { await run() }
    }

    private func run() async {
        running = true
        defer { running = false }
        lines = [("Internet", "", nil), ("Geschwindigkeit", "", nil), ("Server der Wiedergabeliste", "", nil), ("Erster Sender", "", nil)]
        // 1. Internet
        let t0 = Date()
        let ok = (try? await URLSession.shared.data(from: URL(string: "https://www.apple.com/library/test/success.html")!)) != nil
        lines[0] = ("Internet", ok ? "verbunden · \(Int(Date().timeIntervalSince(t0) * 1000)) ms" : "keine Verbindung", ok)
        // 2. Geschwindigkeit (8 MB laden)
        let t1 = Date()
        if let res = try? await URLSession.shared.data(from: URL(string: "https://speed.cloudflare.com/__down?bytes=8000000")!) {
            let d = res.0
            let secs = max(0.05, Date().timeIntervalSince(t1))
            let mbit = Double(d.count) * 8 / secs / 1_000_000
            lines[1] = ("Geschwindigkeit", String(format: "%.0f Mbit/s", mbit) + (mbit < 15 ? " · für HD knapp" : ""), mbit >= 15)
        } else { lines[1] = ("Geschwindigkeit", "nicht messbar", false) }
        // 3. Server
        if let u = store.serverTestURL {
            let t2 = Date()
            var req = URLRequest(url: u); req.timeoutInterval = 15
            req.setValue(TVStore.userAgent, forHTTPHeaderField: "User-Agent")
            if let res = try? await URLSession.shared.data(for: req), let h = res.1 as? HTTPURLResponse {
                let ms = Int(Date().timeIntervalSince(t2) * 1000)
                lines[2] = ("Server der Wiedergabeliste", "Antwort \(h.statusCode) · \(ms) ms", (200..<400).contains(h.statusCode))
            } else { lines[2] = ("Server der Wiedergabeliste", "antwortet nicht", false) }
        } else { lines[2] = ("Server der Wiedergabeliste", "keine Liste gewählt", nil) }
        // 4. Erster Sender
        if let ch = store.live.first, let u = store.url(ch, .live) {
            let t3 = Date()
            var req = URLRequest(url: u); req.timeoutInterval = 15
            req.setValue(TVStore.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=0-200000", forHTTPHeaderField: "Range")
            if let res = try? await URLSession.shared.data(for: req), let h = res.1 as? HTTPURLResponse {
                let d = res.0
                let ms = Int(Date().timeIntervalSince(t3) * 1000)
                lines[3] = ("Erster Sender", "\(ch.name) · \(h.statusCode) · \(ms) ms · \(d.count / 1024) KB", (200..<400).contains(h.statusCode))
            } else { lines[3] = ("Erster Sender", "\(ch.name) antwortet nicht", false) }
        } else { lines[3] = ("Erster Sender", "keine Sender", nil) }
    }
}

// MARK: - Fehlerberichte an die Website (Admin → Fehlerberichte), wie auf Android

enum Report {
    private static var lastStall = Date.distantPast
    private static var count = 0

    static func send(_ kind: String, _ text: String) {
        guard ProcessInfo.processInfo.environment["IMPTV_TEST"] != "1", count < 20 else { return }
        count += 1
        let ids = DeviceIdentity.load()
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") + " ("
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") + ")"
        Task.detached {
            _ = try? await RemoteAPI.rpc("report_crash", ["p_mac": ids.mac, "p_key": ids.key, "p_version": "tvOS " + v,
                                                          "p_device": "Apple TV", "p_kind": kind, "p_message": String(text.prefix(6000))])
        }
    }

    /// Hänger: höchstens einer pro Minute
    static func stall(_ channel: String, _ what: String) {
        guard Date().timeIntervalSince(lastStall) > 60 else { return }
        lastStall = Date()
        send("haenger", "Sender: \(channel)\n\(what)\nPlayer: Apple TV")
    }
}
