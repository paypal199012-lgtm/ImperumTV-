import SwiftUI

// MARK: - Profile: mehrere Personen auf einem Gerät
// Jedes Profil hat eigene Favoriten, „Weiterschauen“, Gesehen-Haken und Hinweise auf neue Folgen.
// Das Hauptprofil „p0“ benutzt die bisherigen Speicherplätze (deine Daten bleiben dort).
// Ein Kinder-Profil zeigt nur freigegebene Kategorien.

struct UserProfile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: Int
    var kids: Bool = false
    var pin: String? = nil
}

@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    /// Farbverlauf (oben, unten) und Schriftfarbe je Profil
    static let palette: [(Color, Color, Color)] = [
        (Color(red: 0.91, green: 0.78, blue: 0.49), Color(red: 0.54, green: 0.42, blue: 0.17), Color(red: 0.10, green: 0.08, blue: 0.03)),
        (Color(red: 0.76, green: 0.09, blue: 0.36), Color(red: 0.42, green: 0.11, blue: 0.60), .white),
        (Color(red: 0.16, green: 0.71, blue: 0.96), Color(red: 0.08, green: 0.40, blue: 0.75), .white),
        (Color(red: 0.40, green: 0.73, blue: 0.42), Color(red: 0.11, green: 0.37, blue: 0.13), .white),
        (Color(red: 1.00, green: 0.54, blue: 0.40), Color(red: 0.75, green: 0.21, blue: 0.05), .white),
        (Color(red: 0.58, green: 0.46, blue: 0.80), Color(red: 0.19, green: 0.11, blue: 0.57), .white)
    ]

    private static let kidsPattern = #"(kids|kinder|kid\b|junior|cartoon|zeichentrick|disney|nick|toon|famil|baby|kika|super\s*rtl|anima)"#

    @Published private(set) var list: [UserProfile] = []
    @Published private(set) var curId: String = "p0"
    @Published var askOnStart: Bool {
        didSet { UserDefaults.standard.set(askOnStart, forKey: "profiles.ask") }
    }
    /// In dieser Sitzung schon ein Profil gewählt („Wer schaut?“ nicht noch einmal zeigen)
    @Published var chosen = false
    /// „Profil wechseln“ auf dem Startbildschirm gedrückt
    @Published var showPicker = false
    private var next: Int

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "profiles.list"),
           let decoded = try? JSONDecoder().decode([UserProfile].self, from: data) {
            list = decoded
        }
        curId = d.string(forKey: "profiles.cur") ?? "p0"
        askOnStart = (d.object(forKey: "profiles.ask") as? Bool) ?? true
        next = max(1, d.integer(forKey: "profiles.next"))
    }

    /// Speicher-Schlüssel des aktiven Profils (Hauptprofil: unverändert)
    nonisolated static func storageKey(_ base: String) -> String {
        let d = UserDefaults.standard
        guard d.data(forKey: "profiles.list") != nil,
              let id = d.string(forKey: "profiles.cur"), id != "p0" else { return base }
        return "p.\(id).\(base)"
    }

    var current: UserProfile? { list.first { $0.id == curId } ?? list.first }
    var isKids: Bool { current?.kids ?? false }
    var needsChoice: Bool { list.count >= 2 && ((askOnStart && !chosen) || showPicker) }

    private func save() {
        let d = UserDefaults.standard
        if list.isEmpty {
            d.removeObject(forKey: "profiles.list")
        } else if let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: "profiles.list")
        }
        d.set(curId, forKey: "profiles.cur")
        d.set(next, forKey: "profiles.next")
    }

    /// Profil wechseln: Favoriten, Weiterschauen usw. des Profils laden
    func use(_ id: String, store: AppStore) {
        curId = id
        chosen = true
        showPicker = false
        save()
        SeenStore.resetCache()
        NewEpisodesStore.resetCache()
        Parental.shared.lock()
        store.reloadProfileData()
    }

    /// Beim ersten Mal: dein bisheriges Profil bekommt einen Namen
    func createMain(_ name: String) {
        guard list.isEmpty else { return }
        list = [UserProfile(id: "p0", name: name, color: 0)]
        curId = "p0"
        save()
    }

    @discardableResult
    func add(_ name: String, kids: Bool) -> UserProfile {
        if list.isEmpty { list = [UserProfile(id: "p0", name: "Ich", color: 0)] }
        let p = UserProfile(id: "p\(next)", name: name, color: list.count % Self.palette.count, kids: kids)
        next += 1
        list.append(p)
        save()
        return p
    }

    func update(_ p: UserProfile) {
        guard let i = list.firstIndex(where: { $0.id == p.id }) else { return }
        list[i] = p
        save()
    }

    func remove(_ id: String, store: AppStore) {
        guard id != "p0" else { return }
        list.removeAll { $0.id == id }
        let d = UserDefaults.standard
        for key in ["favorites", "resume", "seenEpisodes", "newEpisodes", "kidsCats"] {
            d.removeObject(forKey: "p.\(id).\(key)")
        }
        if list.count == 1 { list = [] }        // nur noch ein Profil: Auswahl verschwindet wieder
        if curId == id || list.isEmpty { curId = "p0" }
        save()
        use(curId, store: store)
    }

    // MARK: PIN eines Profils

    func pinHash(_ pin: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in "imperum-profile:\(pin):\(Parental.shared.deviceKey)".utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return String(format: "q%08x", h)
    }

    // MARK: Kinder-Profil

    private func kidsKey(_ id: String) -> String { id == "p0" ? "kidsCats" : "p.\(id).kidsCats" }

    /// Eigene Auswahl (nil = automatisch nach dem Namen)
    func kidsCats(_ id: String) -> Set<String>? {
        guard let l = UserDefaults.standard.stringArray(forKey: kidsKey(id)) else { return nil }
        return Set(l)
    }

    func setKidsCats(_ id: String, _ cats: Set<String>) {
        objectWillChange.send()
        UserDefaults.standard.set(Array(cats), forKey: kidsKey(id))
    }

    func kidAllowed(_ id: String, _ kind: String, _ cat: String) -> Bool {
        if Parental.shared.isAdult(cat) { return false }
        if let own = kidsCats(id) { return own.contains("\(kind):\(cat)") }
        return cat.range(of: Self.kidsPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Für die Anzeige im aktiven Kinder-Profil. Sonder-Kategorien („Zuletzt hinzugefügt“ …) zeigen ohnehin nur Freigegebenes.
    func kidAllowed(_ kind: String, _ cat: String) -> Bool {
        let special = [resumeCategory, newCategory, seenCategory, unseenCategory, newEpisodesCategory]
        if special.contains(cat) || cat.range(of: #"^Filme \d{4}$"#, options: .regularExpression) != nil { return true }
        return kidAllowed(current?.id ?? "p0", kind, cat)
    }
}

// MARK: - Runder Profil-Kreis

struct ProfileAvatar: View {
    let profile: UserProfile
    var size: CGFloat = 90

    var body: some View {
        let c = Profiles.palette[profile.color % Profiles.palette.count]
        ZStack {
            Circle().fill(LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing))
            if profile.kids {
                Image(systemName: "face.smiling")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(c.2)
            } else {
                Text(String(profile.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .heavy))
                    .foregroundStyle(c.2)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 2))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }
}

// MARK: - PIN-Eingabe für Profile (und zum Verlassen des Kinder-Profils)

struct CodeRequest: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    /// true = richtig (Fenster schließt), false = falsch
    var check: (String) -> Bool
    var twice = false
    var onDone: (String) -> Void
}

struct CodeSheet: View {
    let request: CodeRequest
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var first: String?
    @State private var error: String?
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "←", "0", "✕"]

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text(request.twice && first != nil ? "PIN wiederholen" : request.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(request.twice && first != nil ? "Gib dieselbe PIN noch einmal ein." : request.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.goldLight)
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? Theme.goldLight : Color.clear)
                            .overlay(Circle().stroke(Theme.gold, lineWidth: 2))
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(.vertical, 6)
                Text(error ?? " ")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: 300, alignment: .leading)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 10), count: 3), spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        tap(key)
                    } label: {
                        Text(key)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(key == "←" || key == "✕" ? Theme.gold : Color.white)
                            .frame(width: 64, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 212)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.dark.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func tap(_ key: String) {
        switch key {
        case "✕":
            dismiss()
        case "←":
            if !pin.isEmpty { pin.removeLast() }
        default:
            guard pin.count < 4 else { return }
            pin += key
            error = nil
            if pin.count == 4 { submit() }
        }
    }

    private func submit() {
        let entered = pin
        if request.twice {
            if let f = first {
                if f == entered {
                    dismiss()
                    request.onDone(entered)
                } else {
                    error = "Die PINs stimmen nicht überein. Noch einmal."
                    first = nil
                    pin = ""
                }
            } else {
                first = entered
                pin = ""
            }
            return
        }
        if request.check(entered) {
            dismiss()
            request.onDone(entered)
        } else {
            error = "Falsche PIN. Bitte noch einmal."
            pin = ""
        }
    }
}

// MARK: - „Wer schaut?“

struct WhoView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var profiles = Profiles.shared
    @State private var code: CodeRequest?
    @State private var adding = false

    var body: some View {
        GeometryReader { geo in
            let size = min(120, max(70, (geo.size.width - 80) / CGFloat(max(4, profiles.list.count + 1)) - 30))
            VStack(spacing: 18) {
                Spacer(minLength: 8)
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 44)
                Text("Wer schaut?")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 26) {
                        ForEach(profiles.list) { p in
                            Button { open(p) } label: { item(p, size: size) }
                                .buttonStyle(.plain)
                        }
                        if !profiles.isKids {
                            Button { adding = true } label: {
                                VStack(spacing: 10) {
                                    Circle()
                                        .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                                        .foregroundStyle(Color.white.opacity(0.4))
                                        .frame(width: size, height: size)
                                        .overlay(Image(systemName: "plus").font(.system(size: size * 0.4, weight: .light)).foregroundStyle(.secondary))
                                    Text("Profil hinzufügen")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(width: size + 20)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 30)
                    .frame(minWidth: geo.size.width)
                }
                Text("Jedes Profil hat eigene Favoriten, „Weiterschauen“, Gesehen-Haken und Hinweise auf neue Folgen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Spacer(minLength: 8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(GoldBackground())
        .overlay(alignment: .topTrailing) {
            // Vom Startbildschirm aus geöffnet: ohne Wechsel zurück
            if profiles.showPicker {
                Button {
                    profiles.showPicker = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                .padding(16)
            }
        }
        .sheet(item: $code) { req in CodeSheet(request: req) }
        .sheet(isPresented: $adding) { AddProfileSheet().environmentObject(store) }
    }

    private func item(_ p: UserProfile, size: CGFloat) -> some View {
        VStack(spacing: 8) {
            ProfileAvatar(profile: p, size: size)
                .overlay(alignment: .topTrailing) {
                    if p.kids {
                        Text("KIDS")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color(red: 0.03, green: 0.19, blue: 0.06))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(red: 0.30, green: 0.85, blue: 0.39)))
                    }
                }
                .overlay(Circle().stroke(p.id == profiles.current?.id ? Theme.goldLight : .clear, lineWidth: 3))
            HStack(spacing: 4) {
                Text(p.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                if p.pin != nil { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.gold) }
            }
            Text(p.kids ? "Kinder-Profil" : (p.pin != nil ? "mit PIN" : " "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: size + 20)
    }

    private func open(_ p: UserProfile) {
        func finish() {
            if let hash = p.pin {
                code = CodeRequest(title: "PIN für „\(p.name)“", subtitle: "Dieses Profil ist mit einer PIN geschützt.",
                                   check: { Profiles.shared.pinHash($0) == hash }) { _ in
                    Profiles.shared.use(p.id, store: store)
                }
            } else {
                profiles.use(p.id, store: store)
            }
        }
        // Aus dem Kinder-Profil heraus nur mit der PIN der Kindersicherung
        if profiles.isKids && p.id != profiles.current?.id && Parental.shared.pinHash != nil {
            code = CodeRequest(title: "Kinder-Profil verlassen", subtitle: "Bitte die PIN der Kindersicherung eingeben.",
                               check: { Parental.shared.check($0) }) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish() }
            }
            return
        }
        finish()
    }
}

// MARK: - Profil anlegen

struct AddProfileSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profiles = Profiles.shared
    @State private var mainName = ""
    @State private var name = ""
    @State private var kids = false

    var body: some View {
        NavigationStack {
            Form {
                if profiles.list.isEmpty {
                    Section {
                        TextField("Dein Name", text: $mainName)
                    } header: {
                        Text("Dein Profil")
                    } footer: {
                        Text("Deine bisherigen Favoriten und „Weiterschauen“ bleiben in deinem Profil.")
                    }
                }
                Section {
                    TextField("Name", text: $name)
                    Toggle("Kinder-Profil", isOn: $kids).tint(Theme.gold)
                } header: {
                    Text("Neues Profil")
                } footer: {
                    Text(kids ? "Zeigt nur Kinder-Kategorien (automatisch erkannt, anpassbar unter Einstellungen → Profile). Ohne Einstellungen und Listen." : "Eigene Favoriten, „Weiterschauen“ und Gesehen-Haken.")
                }
            }
            .navigationTitle("Profil hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") {
                        let me = clean(mainName), n = clean(name)
                        if profiles.list.isEmpty { profiles.createMain(me.isEmpty ? "Ich" : me) }
                        profiles.add(n, kids: kids)
                        dismiss()
                    }
                    .disabled(clean(name).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased() + String(t.dropFirst().prefix(19))
    }
}

// MARK: - Einstellungen → Profile

struct ProfilesSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var profiles = Profiles.shared
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ForEach(profiles.list) { p in
                    NavigationLink {
                        ProfileEditView(profileId: p.id)
                    } label: {
                        HStack(spacing: 12) {
                            ProfileAvatar(profile: p, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(info(p)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button {
                    adding = true
                } label: {
                    Label("Profil hinzufügen", systemImage: "plus.circle")
                }
            } footer: {
                Text("Jedes Profil hat eigene Favoriten, „Weiterschauen“, Gesehen-Haken und Hinweise auf neue Folgen. Wiedergabeliste und Einstellungen gelten für alle. Ist die Kindersicherung an, braucht man zum Verlassen des Kinder-Profils deren PIN.")
            }
            if profiles.list.count >= 2 {
                Section {
                    Toggle("„Wer schaut?“ beim Start", isOn: $profiles.askOnStart).tint(Theme.gold)
                } footer: {
                    Text("Aus: Die App startet mit dem zuletzt benutzten Profil. Wechseln kannst du immer oben links auf dem Startbildschirm.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Profile")
        .sheet(isPresented: $adding) { AddProfileSheet().environmentObject(store) }
    }

    private func info(_ p: UserProfile) -> String {
        var bits: [String] = []
        if p.id == "p0" { bits.append("Hauptprofil") }
        if p.kids { bits.append("Kinder-Profil") }
        if p.pin != nil { bits.append("PIN") }
        if p.id == profiles.current?.id { bits.append("aktiv") }
        return bits.isEmpty ? " " : bits.joined(separator: " · ")
    }
}

struct ProfileEditView: View {
    let profileId: String
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profiles = Profiles.shared
    @State private var name = ""
    @State private var code: CodeRequest?
    @State private var askDelete = false

    private var profile: UserProfile? { profiles.list.first { $0.id == profileId } }

    var body: some View {
        Form {
            if let p = profile {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatar(profile: p, size: 80)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("Name", text: $name)
                        .onSubmit { rename(p) }
                    Button("Farbe ändern") {
                        var q = p
                        q.color = (p.color + 1) % Profiles.palette.count
                        profiles.update(q)
                    }
                    Toggle("Kinder-Profil", isOn: Binding(get: { p.kids }, set: { on in
                        var q = p
                        q.kids = on
                        profiles.update(q)
                    }))
                    .tint(Theme.gold)
                }
                Section {
                    if p.pin != nil {
                        Button("PIN entfernen", role: .destructive) {
                            var q = p
                            q.pin = nil
                            profiles.update(q)
                        }
                    } else {
                        Button("PIN festlegen") {
                            code = CodeRequest(title: "PIN für „\(p.name)“", subtitle: "Neue 4-stellige PIN eingeben.",
                                               check: { _ in true }, twice: true) { pin in
                                var q = p
                                q.pin = Profiles.shared.pinHash(pin)
                                Profiles.shared.update(q)
                            }
                        }
                    }
                } footer: {
                    Text("Mit PIN kommt nur in dieses Profil, wer die PIN kennt.")
                }
                if p.kids {
                    Section {
                        NavigationLink("Live TV") { KidsCategoriesView(profileId: p.id, kind: "live") }
                        NavigationLink("Filme") { KidsCategoriesView(profileId: p.id, kind: "movie") }
                        NavigationLink("Serien") { KidsCategoriesView(profileId: p.id, kind: "series") }
                    } header: {
                        Text("Freigegebene Kategorien")
                    } footer: {
                        Text(profiles.kidsCats(p.id) == nil ? "Noch automatisch: freigegeben sind Kategorien mit „Kids“, „Kinder“, „Disney“, „Cartoon“ … im Namen." : "Eigene Auswahl. Erwachsenen-Kategorien sind immer gesperrt.")
                    }
                }
                if p.id != "p0" {
                    Section {
                        Button("Profil löschen", role: .destructive) { askDelete = true }
                    }
                } else {
                    Section {
                        EmptyView()
                    } footer: {
                        Text("Hauptprofil – kann nicht gelöscht werden.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle(profile?.name ?? "Profil")
        .onAppear { name = profile?.name ?? "" }
        .onDisappear { if let p = profile { rename(p) } }
        .sheet(item: $code) { req in CodeSheet(request: req) }
        .confirmationDialog("Profil löschen?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                profiles.remove(profileId, store: store)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Favoriten, „Weiterschauen“ und Gesehen-Haken dieses Profils werden gelöscht.")
        }
    }

    private func rename(_ p: UserProfile) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != p.name else { return }
        var q = p
        q.name = String(t.prefix(20))
        profiles.update(q)
    }
}

/// Kinder-Profil: Kategorien freigeben
struct KidsCategoriesView: View {
    let profileId: String
    let kind: String
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var profiles = Profiles.shared

    private var cats: [String] {
        let groups: [String?]
        switch kind {
        case "live": groups = store.channels.map(\.group)
        case "movie": groups = store.movies.map(\.group)
        default: groups = store.seriesList.map(\.group)
        }
        return Array(Set(groups.compactMap { $0 }.filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        List {
            if cats.isEmpty {
                Text(kind == "live" ? "Keine Kategorien gefunden." : "Noch nicht geladen – öffne einmal \(kind == "movie" ? "Filme" : "Serien").")
                    .foregroundStyle(.secondary)
            }
            ForEach(cats, id: \.self) { cat in
                let adult = Parental.shared.isAdult(cat)
                let on = profiles.kidAllowed(profileId, kind, cat)
                Button {
                    guard !adult else { return }
                    toggle(cat)
                } label: {
                    HStack {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Theme.gold : Color.secondary)
                        Text(cat).foregroundStyle(adult ? .secondary : .primary)
                        Spacer()
                        if adult { Text("immer gesperrt").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle(kind == "live" ? "Live TV" : kind == "movie" ? "Filme" : "Serien")
    }

    private func toggle(_ cat: String) {
        var set = profiles.kidsCats(profileId) ?? autoSelection()
        let key = "\(kind):\(cat)"
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        profiles.setKidsCats(profileId, set)
    }

    /// Erste Änderung: automatische Auswahl (alle Arten) als Startpunkt
    private func autoSelection() -> Set<String> {
        var out = Set<String>()
        let all: [(String, [String?])] = [("live", store.channels.map(\.group)), ("movie", store.movies.map(\.group)), ("series", store.seriesList.map(\.group))]
        for (k, groups) in all {
            for g in Set(groups.compactMap { $0 }) where profiles.kidAllowed(profileId, k, g) {
                out.insert("\(k):\(g)")
            }
        }
        return out
    }
}

// MARK: - Startbildschirm: wer gerade schaut

struct ProfileChip: View {
    @ObservedObject private var profiles = Profiles.shared

    var body: some View {
        if let me = profiles.current, profiles.list.count >= 2 {
            Button {
                profiles.showPicker = true       // zeigt „Wer schaut?“
            } label: {
                HStack(spacing: 8) {
                    ProfileAvatar(profile: me, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(me.name).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                        Text("Profil wechseln").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 3)
                .padding(.trailing, 12)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().stroke(Color.white.opacity(0.25)))
            }
            .buttonStyle(.plain)
        }
    }
}
