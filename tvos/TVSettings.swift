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

// MARK: - Einstellungen (Aufbau wie Android: Kopfkarte, drei Spalten, Aktionen unten)

struct SettingsScreen: View {
    /// Player-Wahl: Automatisch → Apple-Player → VLC → Automatisch
    static func engName(_ m: String) -> String { m == "vlc" ? "VLC" : m == "apple" ? "Apple-Player" : "Automatisch" }
    static func nextEngine(_ m: String) -> String { m == "vlc" ? "auto" : m == "apple" ? "vlc" : "apple" }

    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook
    @AppStorage("tv.theme") private var theme = "gold"
    @AppStorage("tv.clock") private var clock = "sec"
    @AppStorage("tv.autonext") private var autoNext = true
    @AppStorage("tv.intro") private var introBtn = true
    @AppStorage("tv.netq") private var netq = "always"
    @State private var pinMode: String?          // "set", "check-off"
    @State private var note: String?
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Einstellungen").font(UI.font(40, .bold)).foregroundColor(UI.gold).place(70, 34, 900, 56)

            header.place(70, 110, 1780, 168)

            HStack(alignment: .top, spacing: 30) {
                section("play", "Wiedergabe") {
                    row("tv", "Live-Format", store.liveExt.uppercased() == "TS" ? "TS" : "HLS") {
                        store.liveExt = store.liveExt == "ts" ? "m3u8" : "ts"
                    }
                    row("play", "Player Live TV", Self.engName(engine.liveEngine)) {
                        engine.liveEngine = Self.nextEngine(engine.liveEngine)
                    }
                    row("tv", "Ersatzsender", engine.autoAlt ? "An · automatisch" : "Aus") { engine.autoAlt.toggle() }
                    row("up", "Puffer", engine.bufferMode == "small" ? "Klein · 1 s" : engine.bufferMode == "large" ? "Groß · 5 s" : "Normal · 2,5 s") {
                        engine.bufferMode = engine.bufferMode == "normal" ? "large" : engine.bufferMode == "large" ? "small" : "normal"
                    }
                    row("play", "Player Filme & Serien", Self.engName(engine.vodEngine)) {
                        engine.vodEngine = Self.nextEngine(engine.vodEngine)
                    }
                    row("next", "Nächste Folge", autoNext ? "An · 10 s" : "Aus") { autoNext.toggle() }
                    row("next", "Intro überspringen", introBtn ? "An · 20 s" : "Aus") { introBtn.toggle() }
                }
                section("clock", "Anzeige & Familie") {
                    row("tv", "Farbthema", Theme.current.name) {
                        let ids = Theme.all.map(\.id)
                        let i = ids.firstIndex(of: theme) ?? 0
                        Theme.currentId = ids[(i + 1) % ids.count]
                        theme = Theme.currentId
                    }
                    row("clock", "Uhrzeit oben rechts", clock == "sec" ? "Mit Sekunden" : clock == "min" ? "Ohne Sekunden" : "Aus") {
                        clock = clock == "sec" ? "min" : clock == "min" ? "off" : "sec"
                    }
                    row("speed", "Verbindungsanzeige", netq == "always" ? "Immer" : netq == "problems" ? "Bei Problemen" : "Aus") {
                        netq = netq == "always" ? "problems" : netq == "problems" ? "off" : "always"
                    }
                    row("clock", "Schlaf-Timer", engine.sleepAt.map { "noch \(max(1, Int($0.timeIntervalSinceNow / 60))) Min" } ?? "Aus") {
                        let steps: [Int] = [0, 30, 60, 90, 120]
                        let cur = engine.sleepAt.map { Int(($0.timeIntervalSinceNow / 60).rounded()) } ?? 0
                        let next = steps.first { $0 > cur + 1 } ?? 0
                        engine.sleepAt = next == 0 ? nil : Date().addingTimeInterval(Double(next) * 60)
                    }
                    row("lock", "Kinderschutz", Parental.hasPin ? "An" : "Aus") {
                        if Parental.hasPin { nav.push(.lockCats) } else { pinMode = "set" }
                    }
                    row("list", "Ausgeblendete Sender", store.hidden.isEmpty ? "Keine" : "\(store.hidden.count)") {
                        if !store.hidden.isEmpty { store.unhideAll(); show("Alle Sender wieder eingeblendet") }
                        else { show("Sender ausblenden: in Live TV auf einem Sender OK lange drücken") }
                    }
                    row("users", "Profile", Profiles.list.count > 1 ? Profiles.current.name : "Aus") { nav.push(.profiles) }
                }
                section("shield", "Konto") {
                    row("list", "Wiedergabelisten", "Wechseln") { nav.push(.playlists) }
                    row("user", "Konto", "Kostenlos") { show("ImperumTV für Apple TV ist kostenlos") }
                    row("resume", "Weiterschauen löschen", "\(resume.entries.count + resume.seen.count)") { resume.clearAll(); show("Weiterschauen und Gesehen gelöscht") }
                    row("star", "Favoriten löschen", "\(store.favorites.count)") { store.clearFavorites(); show("Favoriten gelöscht") }
                    if Parental.hasPin {
                        row("lock", "Kinderschutz ausschalten", "PIN") { pinMode = "check-off" }
                    }
                }
            }
            .place(70, 298, 1780, 620)

            HStack(spacing: 22) {
                action("refresh", "Neu laden", "Sender, Filme, Serien") { Task { await store.reload(); show("Neu geladen") } }
                action("clean", "Cache leeren", "Bilder & Programm") { store.clearCache(); show("Cache geleert") }
                action("up", "Updates", "Version " + appVersion) { show("Updates kommen automatisch über den App Store") }
                action("speed", "Verbindungstest", "Internet & Sender") { nav.push(.nettest) }
            }
            .place(70, 946, 1780, 104)

            if let n = note {
                Text(n).font(UI.font(26, .semibold)).padding(.horizontal, 30).padding(.vertical, 16)
                    .background(Capsule().fill(.black.opacity(0.85))).overlay(Capsule().stroke(UI.tan(0.5), lineWidth: 1.5))
                    .place(0, 860, 1920, 70, alignment: .center)
            }
            if let m = pinMode {
                PinPrompt(title: m == "set" ? "Neue PIN festlegen" : "PIN eingeben (Kinderschutz aus)") { pin in
                    pinMode = nil
                    guard let pin = pin, pin.count >= 4, pin.allSatisfy(\.isNumber) else { if pin != nil { show("Die PIN braucht 4 Ziffern") }; return }
                    if m == "set" { Parental.pinHash = Parental.hash(pin); show("Kinderschutz an") }
                    else if Parental.check(pin) { Parental.pinHash = ""; show("Kinderschutz aus") }
                    else { show("Falsche PIN") }
                    store.objectWillChange.send()
                }
            }
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, "Live-Format")
    }

    // MARK: Kopfkarte

    private var header: some View {
        HStack(spacing: 26) {
            Image("Logo").resizable().scaledToFit().themedLogo().padding(10)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Color(rgb: 0x10141c)))
                .overlay(Circle().stroke(UI.gold2, lineWidth: 3))
            VStack(alignment: .leading, spacing: 6) {
                Text("ImperumTV").font(UI.font(42, .bold))
                Text("Konto aktiviert · Version \(appVersion) · \(store.favorites.count) Favoriten")
                    .font(UI.font(24)).foregroundColor(UI.text.opacity(0.85)).lineLimit(1)
            }
            Spacer(minLength: 10)
            chip("users", "Profil", Profiles.current.name)
            chip("lock", "Kinderschutz", Parental.hasPin ? "An" : "Aus")
            chip("list", store.expiry == nil ? "Abo" : "Abo bis", store.expiry.map { $0.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()) } ?? "unbegrenzt")
            chip("device", "Gerät", store.device.mac.lowercased())
        }
        .padding(.horizontal, 30)
        .frame(width: 1780, height: 168)
        .background(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [UI.tan(0.32), UI.tan(0.08)], startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(UI.tan(0.6), lineWidth: 2))
    }

    private func chip(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) { Icon(icon, 22); Text(label).font(UI.font(20)) }.foregroundColor(UI.text.opacity(0.8))
            Text(value).font(UI.font(value.count > 14 ? 22 : 28, .bold)).lineLimit(1).foregroundColor(label == "Profil" ? UI.gold : UI.text)
        }
        .padding(.horizontal, 22)
        .frame(height: 92, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.45)))
    }

    // MARK: Spalten

    private func section<C: View>(_ icon: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Icon(icon, 26)
                Text(title.uppercased()).font(UI.font(22, .heavy)).tracking(3)
            }
            .foregroundColor(UI.gold2).padding(.leading, 12).padding(.bottom, 4)
            content()
        }
        .padding(14)
        .frame(width: 573, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1.5))
        .focusSection()
    }

    private func row(_ icon: String, _ title: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Icon(icon, 26).foregroundColor(UI.gold)
                Text(title).font(UI.font(26, .bold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).font(UI.font(22)).foregroundColor(UI.text.opacity(0.8)).lineLimit(1)
            }
            .padding(.horizontal, 20).frame(width: 545, height: 56)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 10)), normal: .black.opacity(0.3), focusFill: UI.tan(0.3)))
        .focused($focus, equals: title)
    }

    private func action(_ icon: String, _ title: String, _ sub: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 20) {
                Icon(icon, 34).foregroundColor(UI.gold).frame(width: 60, height: 60).background(Circle().fill(UI.tan(0.2)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(UI.font(27, .bold))
                    Text(sub).font(UI.font(20)).foregroundColor(UI.text.opacity(0.75))
                }
                Spacer()
            }
            .padding(.horizontal, 24).frame(width: 428, height: 102)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 16)), normal: .black.opacity(0.35), focusFill: UI.tan(0.3),
                               border: UI.tan(0.5), borderWidth: 2))
        .focused($focus, equals: title)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") + " ("
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") + ")"
    }

    private func show(_ t: String) {
        note = t
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if note == t { note = nil } }
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
