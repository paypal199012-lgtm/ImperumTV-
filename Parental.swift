import SwiftUI

// MARK: - Kindersicherung
// Eine 4-stellige PIN schützt Erwachsenen- und ausgewählte Kategorien.
// Der Admin kann die PIN auf der Website zurücksetzen; die App merkt das beim nächsten Abgleich.

@MainActor
final class Parental: ObservableObject {
    static let shared = Parental()

    private let defaults = UserDefaults.standard
    @Published private(set) var pinHash: String?
    @Published var autoAdult: Bool {
        didSet { defaults.set(autoAdult, forKey: "parentalAdult") }
    }
    @Published private(set) var cats: Set<String>
    @Published private(set) var unlockedUntil = Date.distantPast

    /// Für die Meldung an die Website (wird vom AppStore gesetzt)
    var deviceMAC = ""
    var deviceKey = ""
    private var lastReset: String?
    private var lastResetKnown = false

    init() {
        pinHash = UserDefaults.standard.string(forKey: "parentalPin")
        autoAdult = (UserDefaults.standard.object(forKey: "parentalAdult") as? Bool) ?? true
        cats = Set(UserDefaults.standard.stringArray(forKey: "parentalCats") ?? [])
    }

    var enabled: Bool { pinHash != nil }
    var isUnlocked: Bool { !Profiles.shared.isKids && Date() < unlockedUntil }

    private static let adultPattern = #"(^|[^a-z])(xxx|adult|adults|erwachsene?|for adults|18\s*\+|\+\s*18|porn|porno|sex|sexy|erotik|erotic|playboy|hustler|brazzers|redlight|private)([^a-z]|$)"#

    func isAdult(_ cat: String) -> Bool {
        cat.range(of: Self.adultPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Geschützte Kategorie? kind: "live", "movie" oder "series"
    func isProtected(_ kind: String, _ cat: String?) -> Bool {
        // Kinder-Profil: alles außer den freigegebenen Kategorien
        if Profiles.shared.isKids, let c = cat, !c.isEmpty { return !Profiles.shared.kidAllowed(kind, c) }
        guard enabled, let c = cat, !c.isEmpty else { return false }
        if autoAdult && isAdult(c) { return true }
        return cats.contains("\(kind):\(c)")
    }

    /// Geschützt und gerade nicht mit der PIN geöffnet
    func isLocked(_ kind: String, _ cat: String?) -> Bool {
        !isUnlocked && isProtected(kind, cat)
    }

    func visible(_ kind: String, _ list: [Channel]) -> [Channel] {
        guard (enabled || Profiles.shared.isKids) && !isUnlocked else { return list }
        return list.filter { !isProtected(kind, $0.group) }
    }

    func visibleSeries(_ list: [SeriesItem]) -> [SeriesItem] {
        guard (enabled || Profiles.shared.isKids) && !isUnlocked else { return list }
        return list.filter { !isProtected("series", $0.group) }
    }

    func isOwnLock(_ kind: String, _ cat: String) -> Bool { cats.contains("\(kind):\(cat)") }

    func toggle(_ kind: String, _ cat: String) {
        let key = "\(kind):\(cat)"
        if cats.contains(key) { cats.remove(key) } else { cats.insert(key) }
        defaults.set(Array(cats), forKey: "parentalCats")
    }

    private func hash(_ pin: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in "imperum-pin:\(pin):\(deviceKey)".utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return String(format: "i%08x", h)
    }

    func check(_ pin: String) -> Bool { pinHash == hash(pin) }

    func setPin(_ pin: String) {
        let value = hash(pin)
        pinHash = value
        defaults.set(value, forKey: "parentalPin")
        // Schon bekannte Rücksetzungen zählen nicht ("?" = noch unbekannt)
        defaults.set(lastResetKnown ? (lastReset ?? "") : "?", forKey: "parentalResetSeen")
        report(true)
    }

    func clear() {
        pinHash = nil
        defaults.removeObject(forKey: "parentalPin")
        lock()
        report(false)
    }

    func unlock() { unlockedUntil = Date().addingTimeInterval(3600) }
    func lock() { unlockedUntil = .distantPast }

    /// Bei jedem Abgleich mit der Website
    func onStatus(_ resetAt: String?) {
        let now = resetAt ?? ""
        lastReset = now
        lastResetKnown = true
        guard enabled || Profiles.shared.hasAnyPin else { return }
        let seen = defaults.string(forKey: "parentalResetSeen") ?? "?"
        if seen == "?" {
            defaults.set(now, forKey: "parentalResetSeen")
            return
        }
        if !now.isEmpty && now != seen {
            pinHash = nil
            defaults.removeObject(forKey: "parentalPin")
            defaults.set(now, forKey: "parentalResetSeen")
            lock()
            // auch die PINs der Profile (sonst käme man nie mehr in ein Profil mit vergessener PIN)
            Profiles.shared.clearPins()
        }
    }

    private func report(_ on: Bool) {
        let mac = deviceMAC, key = deviceKey
        guard !mac.isEmpty else { return }
        Task {
            _ = try? await RemoteAPI.rpc("device_parental", ["p_mac": mac, "p_key": key, "p_on": on])
        }
    }
}

// MARK: - PIN-Eingabe

struct PinRequest: Identifiable {
    enum Mode { case check, create }
    let id = UUID()
    var title: String
    var mode: Mode = .check
    var onSuccess: () -> Void
}

struct PinSheet: View {
    let request: PinRequest
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var parental = Parental.shared
    @State private var pin = ""
    @State private var first: String?
    @State private var error: String?

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "←", "0", "✕"]

    private var heading: String {
        if request.mode == .create { return first == nil ? "Neue PIN" : "PIN wiederholen" }
        return request.title
    }

    private var subtitle: String {
        if request.mode == .create {
            return first == nil ? "Wähle eine 4-stellige PIN für die Kindersicherung." : "Gib dieselbe PIN noch einmal ein."
        }
        return "Diese Inhalte sind mit der Kindersicherung geschützt."
    }

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text(heading)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
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
                if request.mode == .check {
                    Text("PIN vergessen? Dein Anbieter kann sie für dein Gerät zurücksetzen (MAC-Adresse unter Konto).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
        switch request.mode {
        case .check:
            if parental.check(entered) {
                parental.unlock()
                dismiss()
                request.onSuccess()
            } else {
                error = "Falsche PIN. Bitte noch einmal."
                pin = ""
            }
        case .create:
            if let f = first {
                if f == entered {
                    parental.setPin(entered)
                    parental.unlock()
                    dismiss()
                    request.onSuccess()
                } else {
                    error = "Die PINs stimmen nicht überein. Noch einmal."
                    first = nil
                    pin = ""
                }
            } else {
                first = entered
                pin = ""
            }
        }
    }
}

// MARK: - Einstellungen der Kindersicherung

struct ParentalSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var parental = Parental.shared
    @State private var pinRequest: PinRequest?
    @State private var confirmOff = false

    var body: some View {
        Form {
            Section {
                Toggle("Erwachsenen-Kategorien automatisch sperren", isOn: $parental.autoAdult)
                    .tint(Theme.gold)
            } footer: {
                Text("Gesperrt werden Kategorien mit Namen wie „XXX“, „Adult“, „18+“ oder „Erotik“.")
            }

            Section("Eigene Sperren") {
                NavigationLink("Live-TV-Kategorien") { ParentalCategoriesView(kind: "live") }
                NavigationLink("Film-Kategorien") { ParentalCategoriesView(kind: "movie") }
                NavigationLink("Serien-Kategorien") { ParentalCategoriesView(kind: "series") }
            }

            Section {
                Button("PIN ändern") {
                    pinRequest = PinRequest(title: "Neue PIN", mode: .create) {}
                }
                Button("Kindersicherung ausschalten", role: .destructive) {
                    confirmOff = true
                }
            } footer: {
                Text("Nach der PIN bleibt alles eine Stunde offen oder bis die App in den Hintergrund geht. PIN vergessen? Dein Anbieter kann sie für die MAC-Adresse \(store.macText) zurücksetzen.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Kindersicherung")
        .sheet(item: $pinRequest) { req in
            PinSheet(request: req)
        }
        .confirmationDialog("Kindersicherung ausschalten?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Ausschalten", role: .destructive) {
                parental.clear()
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Danach sind alle Kategorien ohne PIN zu sehen.")
        }
    }
}

/// Kategorien zum Sperren an- und abhaken
struct ParentalCategoriesView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var parental = Parental.shared
    let kind: String

    private var categories: [String] {
        let names: [String?]
        switch kind {
        case "live": names = store.channels.map(\.group)
        case "movie": names = store.movies.map(\.group)
        default: names = store.seriesList.map(\.group)
        }
        return Array(Set(names.compactMap { $0 })).sorted()
    }

    var body: some View {
        List {
            if categories.isEmpty {
                Text(kind == "live" ? "Keine Kategorien gefunden." : "Kategorien werden geladen …")
                    .foregroundStyle(.secondary)
            }
            ForEach(categories, id: \.self) { cat in
                let auto = parental.autoAdult && parental.isAdult(cat)
                let own = parental.isOwnLock(kind, cat)
                Button {
                    if !auto || own { parental.toggle(kind, cat) }
                } label: {
                    HStack {
                        Image(systemName: (own || auto) ? "lock.fill" : "lock.open")
                            .foregroundStyle((own || auto) ? Theme.gold : Color.secondary)
                            .frame(width: 24)
                        Text(cat)
                            .foregroundStyle(.primary)
                        Spacer()
                        if auto && !own {
                            Text("automatisch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(kind == "live" ? "Live-TV sperren" : kind == "movie" ? "Filme sperren" : "Serien sperren")
        .task {
            if kind == "movie" { await store.loadMoviesIfNeeded() }
            if kind == "series" { await store.loadSeriesIfNeeded() }
        }
    }
}
