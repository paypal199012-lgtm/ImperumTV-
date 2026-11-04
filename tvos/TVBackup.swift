import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Sicherung in der Cloud (wie Android): Favoriten, Profile, Weiterschauen, Gesehen, Kindersicherung, Einstellungen

/// Eine Sicherung, die gerade zur Auswahl steht
struct BackupChoice: Identifiable {
    let id = UUID()
    let title: String
    let data: [String: Any]
    let at: Date?
    /// Gruppe → Anzahl Einträge
    let counts: [String: Int]
    /// von Android/iPhone: nur Favoriten übernehmbar
    let foreign: Bool
    /// nach dem Übernehmen/Abbrechen „erledigt“ melden (übertragene Sicherung)
    let pending: Bool
}

@MainActor
final class Backup: ObservableObject {
    static let shared = Backup()

    static let groups: [(id: String, name: String)] = [
        ("favs", "Favoriten"), ("profiles", "Profile"), ("resume", "Weiterschauen"), ("seen", "Gesehen"),
        ("parental", "Kindersicherung"), ("settings", "Einstellungen")
    ]
    private static let settingsKeys: Set<String> = [
        "tv.theme", "tv.clock", "tv.autonext", "tv.intro", "tv.netq", "tv.liveExt", "tv.gravity", "tv.liveEngine", "tv.vodEngine",
        "tv.autoAlt", "tv.altWait", "tv.buffer", "tv.mergeCh", "tv.mergePref", "tv.mergeOff", "tv.genreScan"
    ]

    @Published var missing = false
    @Published var busy = false
    @Published var hasCloud = false
    @Published var cloudAt: Date?
    /// eine übertragene Sicherung wartet (MAC des alten Geräts)
    @Published var pendingFrom: String?
    @Published var askPending = false
    @Published var choice: BackupChoice?
    @Published var message: String?
    @Published var waiting = false

    weak var store: TVStore?
    weak var resume: ResumeBook?
    private var changeObs: NSObjectProtocol?
    private var touchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSaved = ""
    private var applying = false

    var auto: Bool {
        get { UserDefaults.standard.object(forKey: "tv.backupAuto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.backupAuto"); objectWillChange.send() }
    }
    var savedAt: Date? {
        let t = UserDefaults.standard.double(forKey: "tv.backupAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    var lastText: String {
        guard let d = savedAt else { return "Favoriten, Profile …" }
        return "Gesichert · " + Self.dayText(d) + ", " + Self.clock(d) + " Uhr"
    }

    /// „20:23“ (immer 24 Stunden)
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func dayText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "heute" }
        if cal.isDateInYesterday(d) { return "gestern" }
        return d.formatted(.dateTime.day().month(.defaultDigits).year())
    }

    /// Gruppe eines Speicher-Schlüssels, sonst nil
    static func groupOf(_ k: String) -> String? {
        func base(_ b: String) -> Bool { k == b || k.hasPrefix(b + ".") }
        if base("tv.favs") { return "favs" }
        if k == "tv.profiles" || k == "tv.profile" { return "profiles" }
        if base("tv.resume") { return "resume" }
        if base("tv.seen") { return "seen" }
        if k == "tv.pinCats" || k == "tv.pinAdult" || base("tv.hidden") { return "parental" }
        if settingsKeys.contains(k) { return "settings" }
        return nil
    }

    // MARK: Einpacken / Auspacken

    private func collect() -> [String: String] {
        var items: [String: String] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where Self.groupOf(k) != nil {
            let wrapped: [String: Any]
            if let d = v as? Data { wrapped = ["b64": d.base64EncodedString()] } else { wrapped = ["v": v] }
            if JSONSerialization.isValidJSONObject(wrapped), let d = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]) {
                items[k] = String(decoding: d, as: UTF8.self)
            }
        }
        return items
    }

    private func unwrap(_ s: String) -> Any? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return nil }
        if let b = o["b64"] as? String { return Data(base64Encoded: b) }
        return o["v"]
    }

    private func counts(_ data: [String: Any]) -> (counts: [String: Int], foreign: Bool) {
        let items = data["items"] as? [String: String] ?? [:]
        var c: [String: Int] = [:]
        if (data["app"] as? String) != "tvos" {
            // Android / iPhone: Favoriten („live:12“ …)
            let favs = items["favs"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String] ?? []
            c["favs"] = favs.count
            return (c, true)
        }
        for (k, raw) in items {
            guard let g = Self.groupOf(k) else { continue }
            let v = unwrap(raw)
            var n = 1
            if let a = v as? [Any] { n = a.count } else if let d = v as? [String: Any] { n = d.count }
            else if g == "resume", let d = v as? Data, let l = try? JSONSerialization.jsonObject(with: d) as? [Any] { n = l.count }
            else if g == "profiles", let d = v as? Data, let l = try? JSONSerialization.jsonObject(with: d) as? [Any] { n = l.count }
            c[g, default: 0] += n
        }
        return (c, false)
    }

    // MARK: Server

    private func rpc(_ name: String, _ body: [String: Any], device: Bool = true) async throws -> [String: Any] {
        var b = body
        if device {
            let ids = DeviceIdentity.load()
            b["p_mac"] = ids.mac; b["p_key"] = ids.key
        }
        let data: Data
        do { data = try await RemoteAPI.rpc(name, b) } catch let e as RemoteError {
            if e.isMissingFunction { missing = true; throw BackupError("Die Sicherung ist auf dem Server noch nicht eingerichtet.") }
            throw e
        }
        let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let ok = r["ok"] as? Bool, !ok { throw BackupError(r["error"] as? String ?? "Fehler") }
        return r
    }

    struct BackupError: LocalizedError {
        let text: String
        init(_ t: String) { text = t }
        var errorDescription: String? { text }
    }

    @discardableResult
    func save(quiet: Bool = false) async -> Bool {
        guard !busy, !TVStore.testMode || TVStore.env["IMPTV_SCREEN"] == "backup" else { return false }
        let items = collect()
        let env: [String: Any] = ["v": 1, "app": "tvos", "at": Int(Date().timeIntervalSince1970 * 1000), "mac": DeviceIdentity.load().mac, "items": items]
        guard let d = try? JSONSerialization.data(withJSONObject: env) else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await rpc("device_backup_save", ["p_data": String(decoding: d, as: UTF8.self)])
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "tv.backupAt")
            lastSaved = itemsSignature(items)
            hasCloud = true; cloudAt = Date()
            if !quiet { message = "Gesichert" }
            objectWillChange.send()
            return true
        } catch {
            if !quiet { message = "Sicherung fehlgeschlagen: " + error.localizedDescription }
            return false
        }
    }

    private func itemsSignature(_ items: [String: String]) -> String {
        items.keys.sorted().map { $0 + "=" + (items[$0] ?? "") }.joined(separator: "\n")
    }

    /// Etwas Gesichertes geändert: eine Minute später sichern (nur wenn sich wirklich etwas geändert hat)
    private func touched() {
        guard auto, !missing, !applying else { return }
        touchTask?.cancel()
        touchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.itemsSignature(self.collect()) != self.lastSaved { await self.save(quiet: true) }
        }
    }

    func refreshInfo() async {
        guard let r = try? await rpc("device_backup_info", [:]) else { return }
        hasCloud = r["has"] as? Bool ?? false
        cloudAt = (r["saved_at"] as? String).flatMap { ISO8601DateFormatter.flexible($0) }
        pendingFrom = (r["pending"] as? Bool ?? false) ? (r["pending_from"] as? String ?? "") : nil
    }

    /// Beim Start: wartet eine übertragene Sicherung? Täglich sichern. Änderungen beobachten.
    func startup(store: TVStore, resume: ResumeBook) {
        self.store = store; self.resume = resume
        guard !TVStore.testMode else { return }
        lastSaved = itemsSignature(collect())
        changeObs = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.touched() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await refreshInfo()
            if pendingFrom != nil { askPending = true }
            if auto, !missing, (savedAt.map { Date().timeIntervalSince($0) > 86_400 } ?? true) { await save(quiet: true) }
        }
    }

    // MARK: Zurückspielen / Übernehmen

    private func load(_ which: String, title: String) async {
        do {
            let r = try await rpc("device_backup_load", ["p_which": which])
            guard let s = r["data"] as? String, let data = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else {
                message = "Die Sicherung ist beschädigt."; return
            }
            let c = counts(data)
            let at = (data["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let from = (r["from"] as? String ?? "").lowercased()
            choice = BackupChoice(title: which == "pending" ? "Sicherung von \(from) übernehmen?" : title, data: data, at: at,
                                  counts: c.counts, foreign: c.foreign, pending: which == "pending")
        } catch {
            message = error.localizedDescription
        }
    }

    func takePending() async { await load("pending", title: "") }
    func restoreOwn() async { await load("own", title: "Sicherung zurückspielen") }

    func dismissPending() {
        pendingFrom = nil
        Task { _ = try? await rpc("device_backup_done", [:]) }
    }

    /// Gewählte Bereiche einspielen (ersetzt diese Bereiche auf diesem Gerät)
    func apply(_ c: BackupChoice, groups: Set<String>) {
        applying = true
        defer { applying = false }
        let items = c.data["items"] as? [String: String] ?? [:]
        let ud = UserDefaults.standard
        if c.foreign {
            // Android / iPhone: Favoriten der aktuellen Wiedergabeliste zuordnen
            if groups.contains("favs"), let store = store,
               let favs = items["favs"].flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String] {
                for f in favs {
                    let k = store.sourceName + "|" + f
                    if !store.favorites.contains(k) { store.favorites.insert(k) }
                }
                let key = Profiles.currentId == "p0" ? "tv.favs" : "tv.favs." + Profiles.currentId
                ud.set(Array(store.favorites), forKey: key)
            }
        } else {
            for k in ud.dictionaryRepresentation().keys where Self.groupOf(k).map({ groups.contains($0) }) == true { ud.removeObject(forKey: k) }
            for (k, raw) in items {
                guard let g = Self.groupOf(k), groups.contains(g), let v = unwrap(raw) else { continue }
                ud.set(v, forKey: k)
            }
        }
        if c.pending { dismissPending() }
        choice = nil
        // alles neu einlesen
        if !Profiles.list.contains(where: { $0.id == Profiles.currentId }) { Profiles.currentId = "p0" }
        store?.setProfile(Profiles.currentId)
        resume?.setProfile(Profiles.currentId)
        store?.objectWillChange.send()
        message = c.foreign ? "Favoriten übernommen (von Android/iPhone werden nur Favoriten übernommen)." : "Sicherung übernommen."
        lastSaved = itemsSignature(collect())
    }

    /// Am Fernseher: MAC + Schlüssel des alten Geräts eingeben
    func copyFrom(mac: String, key: String) async {
        let hex = mac.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hex.count == 12 else { message = "Die MAC-Adresse hat 12 Zeichen (0–9, A–F)."; return }
        let m = stride(from: 0, to: 12, by: 2).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i); return String(hex[a...hex.index(after: a)])
        }.joined(separator: ":")
        let k = key.filter(\.isNumber)
        let me = DeviceIdentity.load()
        do {
            _ = try await rpc("device_backup_copy", ["p_from_mac": m, "p_from_key": k, "p_to_mac": me.mac, "p_to_key": me.key], device: false)
            await takePending()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Simulator-Test: Auswahl mit den eigenen Daten zeigen
    func testChoice() {
        UserDefaults.standard.set(["Demo|live:1", "Demo|movie:101"], forKey: "tv.favs")
        let data: [String: Any] = ["v": 1, "app": "tvos", "at": Date().timeIntervalSince1970 * 1000, "items": collect()]
        let c = counts(data)
        choice = BackupChoice(title: "Sicherung von 1e:e8:92:7a:61:39 übernehmen?", data: data, at: Date(), counts: c.counts, foreign: false, pending: false)
    }

    /// Adresse für das Handy (QR-Code)
    var transferLink: String {
        let me = DeviceIdentity.load()
        return RemoteConfig.website + "sicherung.html?to=" + (me.mac.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? me.mac) + "&key=" + me.key
    }

    /// Auf die Übertragung vom Handy warten
    func startWaiting() {
        waiting = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self = self, self.waiting else { return }
                await self.refreshInfo()
                if self.pendingFrom != nil { self.waiting = false; await self.takePending(); return }
            }
        }
    }
    func stopWaiting() { waiting = false; pollTask?.cancel() }
}

extension ISO8601DateFormatter {
    static func flexible(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// QR-Code als Bild
struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
        } else { Color.white }
    }
    static func make(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Bildschirm „Sicherung“

struct BackupScreen: View {
    @EnvironmentObject var store: TVStore
    @ObservedObject private var bk = Backup.shared
    @State private var mode = ""              // "", "transfer", "type"
    @State private var oldMac = ""
    @State private var oldKey = ""
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Sicherung")
            if mode == "transfer" { transfer.place(120, 140, 1680, 860) }
            else if mode == "type" { typeOld.place(120, 140, 1680, 860) }
            else { main.place(120, 130, 1680, 900) }

            if let c = bk.choice { BackupChooser(choice: c) }
            if let m = bk.message {
                Text(m).font(UI.font(26, .semibold)).padding(.horizontal, 30).padding(.vertical, 16)
                    .background(Capsule().fill(.black.opacity(0.85))).overlay(Capsule().stroke(UI.tan(0.5), lineWidth: 1.5))
                    .place(0, 960, 1920, 70, alignment: .center)
                    .task(id: m) { try? await Task.sleep(nanoseconds: 4_000_000_000); if bk.message == m { bk.message = nil } }
            }
        }
        .frame(width: 1920, height: 1080)
        .task { await bk.refreshInfo() }
        .onDisappear { bk.stopWaiting() }
        .onExitCommand(perform: mode.isEmpty ? nil : { bk.stopWaiting(); mode = "" })
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 30) {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 64, weight: .semibold)).foregroundColor(UI.gold)
                    .frame(width: 130, height: 130).background(Circle().fill(UI.tan(0.2)))
                VStack(alignment: .leading, spacing: 8) {
                    Text(bk.missing ? "Sicherung noch nicht eingerichtet" : bk.savedAt != nil ? "Zuletzt gesichert: " + bk.lastText.replacingOccurrences(of: "Gesichert · ", with: "") : "Noch keine Sicherung")
                        .font(UI.font(36, .bold))
                    Text("Favoriten, Profile, Weiterschauen, Kindersicherung und Einstellungen – in der Cloud. Die Zugangsdaten deines Anbieters werden nicht gesichert.")
                        .font(UI.font(24)).foregroundColor(UI.text.opacity(0.8)).frame(maxWidth: 1300, alignment: .leading)
                    HStack(spacing: 14) {
                        chip("Gerät " + store.device.mac.lowercased())
                        chip(bk.auto ? "Automatisch: an" : "Automatisch: aus")
                    }
                    .padding(.top, 6)
                }
            }
            .padding(30)
            .frame(width: 1680, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [UI.tan(0.3), UI.tan(0.08)], startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(UI.tan(0.55), lineWidth: 2))

            LazyVGrid(columns: [GridItem(.fixed(820), spacing: 30), GridItem(.fixed(820))], spacing: 24) {
                tile("↑", "Jetzt sichern", bk.busy ? "läuft …" : "dauert 1 Sekunde", "save") { Task { await bk.save() } }
                tile("↓", "Von anderem Gerät übernehmen", "z. B. neues Apple TV", "transfer") { mode = "transfer"; bk.startWaiting() }
                tile("↺", "Sicherung zurückspielen", bk.cloudAt.map { "Stand " + Backup.dayText($0) } ?? "", "restore") { Task { await bk.restoreOwn() } }
                tile("⟳", "Automatisch sichern", bk.auto ? "An · bei Änderungen + täglich" : "Aus", "auto") { bk.auto.toggle() }
            }
            Text("Gesichert werden: Favoriten · Profile · Weiterschauen · Gesehen · Kindersicherung (ohne PIN) · Einstellungen")
                .font(UI.font(22)).foregroundColor(UI.muted)
        }
        .focusSection()
        .defaultFocus($focus, "save")
    }

    private var transfer: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 26) {
                Text("Von anderem Gerät übernehmen").font(UI.font(40, .bold)).foregroundColor(UI.gold)
                Text("1. Den QR-Code mit dem Handy scannen und dort MAC-Adresse und Geräte-Schlüssel des alten Geräts eingeben.").font(UI.font(27))
                Text("2. Sobald die Sicherung übertragen ist, erscheint hier die Auswahl, was übernommen wird.").font(UI.font(27))
                Text("MAC und Schlüssel des alten Geräts stehen in der alten App unter Wiedergabelisten bzw. Einstellungen → Gerät.").font(UI.font(23)).foregroundColor(UI.muted)
                HStack(spacing: 14) {
                    ProgressView().tint(UI.gold)
                    Text("Warte auf die Übertragung …").font(UI.font(25, .semibold)).foregroundColor(UI.gold)
                }
                HStack(spacing: 20) {
                    pillButton("Am Fernseher eingeben", gold: true) { bk.stopWaiting(); mode = "type" }
                    pillButton("Abbrechen") { bk.stopWaiting(); mode = "" }
                }
                .padding(.top, 10)
            }
            .frame(width: 1000, alignment: .leading)
            QRCodeView(text: bk.transferLink).padding(24).frame(width: 420, height: 420)
                .background(RoundedRectangle(cornerRadius: 22).fill(.white))
        }
    }

    private var typeOld: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Altes Gerät eingeben").font(UI.font(40, .bold)).foregroundColor(UI.gold)
            TextField("MAC-Adresse, z. B. 1e:e8:92:7a:61:39", text: $oldMac).font(UI.font(30)).frame(width: 900)
            TextField("Geräte-Schlüssel (6 Ziffern)", text: $oldKey).keyboardType(.numberPad).font(UI.font(30)).frame(width: 900)
            HStack(spacing: 20) {
                pillButton("Sicherung holen", gold: true) {
                    Task { await bk.copyFrom(mac: oldMac, key: oldKey); if bk.choice != nil { mode = "" } }
                }
                pillButton("Abbrechen") { mode = "" }
            }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(UI.font(21, .semibold)).padding(.horizontal, 18).frame(height: 42)
            .background(Capsule().fill(.black.opacity(0.4)))
    }

    private func tile(_ sym: String, _ title: String, _ sub: String, _ key: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 24) {
                Text(sym).font(.system(size: 40, weight: .bold)).foregroundColor(UI.gold)
                    .frame(width: 84, height: 84).background(Circle().fill(UI.tan(0.2)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(UI.font(30, .bold)).lineLimit(1)
                    Text(sub).font(UI.font(22)).foregroundColor(UI.text.opacity(0.75)).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 28).frame(width: 820, height: 130)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 18)), normal: .black.opacity(0.35), focusFill: UI.tan(0.3),
                               border: UI.tan(0.5), borderWidth: 2))
        .focused($focus, equals: key)
    }

    private func pillButton(_ t: String, gold: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Text(t).font(UI.font(26, .bold)).padding(.horizontal, 36).frame(height: 64) }
            .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: gold ? UI.gold : .white.opacity(0.1), ring: false, solid: true))
    }
}

/// Auswahl: was übernommen wird
struct BackupChooser: View {
    let choice: BackupChoice
    @ObservedObject private var bk = Backup.shared
    @State private var pick: Set<String> = []

    private var shown: [(id: String, name: String)] {
        Backup.groups.filter { g in choice.foreign ? g.id == "favs" : ((choice.counts[g.id] ?? 0) > 0 || g.id == "settings") }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
            VStack(alignment: .leading, spacing: 20) {
                Text(choice.title).font(UI.font(36, .bold)).foregroundColor(UI.gold)
                Text("Stand: " + (choice.at.map { Backup.dayText($0) + ", " + Backup.clock($0) + " Uhr" } ?? "unbekannt")
                     + ". Was soll übernommen werden?").font(UI.font(25))
                if choice.foreign {
                    Text("Diese Sicherung kommt von Android oder iPhone – übernommen werden die Favoriten (für die gerade gewählte Wiedergabeliste).")
                        .font(UI.font(22)).foregroundColor(UI.muted).frame(width: 900, alignment: .leading)
                }
                ForEach(shown, id: \.id) { g in
                    Button {
                        if pick.contains(g.id) { pick.remove(g.id) } else { pick.insert(g.id) }
                    } label: {
                        HStack(spacing: 18) {
                            Text(pick.contains(g.id) ? "✓" : "").font(UI.font(26, .heavy)).foregroundColor(UI.dark)
                                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 8).fill(pick.contains(g.id) ? UI.gold : Color.white.opacity(0.12)))
                            Text(g.name + ((choice.counts[g.id] ?? 0) > 0 && g.id != "settings" ? " (\(choice.counts[g.id]!))" : "")).font(UI.font(27, .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 20).frame(width: 900, height: 62)
                    }
                    .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 12)), normal: .black.opacity(0.3), focusFill: UI.tan(0.3)))
                }
                Text("Die gewählten Bereiche auf diesem Gerät werden ersetzt.").font(UI.font(21)).foregroundColor(UI.muted)
                HStack(spacing: 20) {
                    Button { bk.apply(choice, groups: pick) } label: { Text("↓  Übernehmen").font(UI.font(26, .bold)).padding(.horizontal, 36).frame(height: 64) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                    Button {
                        if choice.pending { bk.dismissPending() }
                        bk.choice = nil
                    } label: { Text("Abbrechen").font(UI.font(26, .bold)).padding(.horizontal, 36).frame(height: 64) }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.1), ring: false, solid: true))
                }
                .padding(.top, 6)
            }
            .padding(50)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(rgb: 0x16151a)))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(UI.tan(0.5), lineWidth: 1.5))
        }
        .frame(width: 1920, height: 1080)
        .focusSection()
        .onAppear { pick = Set(shown.map(\.id)) }
        .onExitCommand { if choice.pending { bk.dismissPending() }; bk.choice = nil }
    }
}
