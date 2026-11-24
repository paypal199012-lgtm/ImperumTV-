import SwiftUI
import AVFoundation
import VideoToolbox
import UIKit

// MARK: - Geräte-Check (wie auf Android/iPhone): einmal nach dem ersten Laden, danach in den Einstellungen

struct DevCheckResult: Codable {
    var at: Double
    var maxH: Int
    var hevc: Bool
    var hdr: Bool
    var ram: Int
    var mbit: Double
    var pref4k: Bool
}

@MainActor
enum DevCheck {
    private static let key = "tv.devCheck"
    private static var shown = false

    static var saved: DevCheckResult? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DevCheckResult.self, from: d)
    }
    static var done: Bool { saved != nil }
    /// 4K-Fassungen zuerst? (ohne Check: ja, wie bisher)
    static var prefer4k: Bool { saved?.pref4k ?? true }

    /// Admin: „Geräte-Check neu“
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        shown = false
    }

    static func save(_ r: DevCheckResult) {
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: key) }
        Report.send("diagnose", "Geräte-Check (Apple TV): Bildschirm \(r.maxH)p · HEVC \(r.hevc ? "ja" : "nein") · HDR \(r.hdr ? "ja" : "nein")"
                    + " · Dolby ja · RAM \(r.ram) MB · Internet " + (r.mbit > 0 ? String(format: "%.1f", r.mbit) : "?") + " Mbit/s\nEingestellt: "
                    + (r.pref4k ? "4K-Fassungen bevorzugen" : "Full-HD-Fassungen bevorzugen"))
    }

    /// Bildhöhe des angeschlossenen Fernsehers (1080 oder 2160)
    static var screenHeight: Int {
        let b = UIScreen.main.nativeBounds
        return Int(min(b.width, b.height))
    }

    /// Nach dem Laden: sobald die Startseite frei ist, kurz stehen lassen, dann der Check (höchstens 20 Minuten warten)
    static func firstRun(nav: Nav, store: TVStore) {
        guard !done, !shown, !TVStore.testMode else { return }
        shown = true
        Task { @MainActor in
            var ready = 0
            for _ in 0..<4800 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if done { return }
                let free = nav.top == .home && !store.loading && store.hasSource
                    && Backup.shared.choice == nil && !Backup.shared.askPending && !RemoteHelp.shared.asking
                ready = free ? ready + 1 : 0
                if ready >= 3 { nav.push(.devcheck(true)); return }
            }
        }
    }
}

struct DevCheckScreen: View {
    let first: Bool
    @EnvironmentObject var nav: Nav
    @State private var cards: [(icon: String, title: String, value: String, ok: Bool?)] = []
    @State private var step = -1
    @State private var result: DevCheckResult?
    @State private var running = false
    @FocusState private var focus: String?

    private static let items: [(String, String)] = [("🖥", "Bildschirm"), ("🎞", "Videoformate"), ("🔊", "Ton"),
                                                     ("🧠", "Leistung"), ("📶", "Internet"), ("▶", "Player")]

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 14) {
                Text(first ? "Willkommen bei ImperumTV" : "Gerät prüfen").font(UI.font(48, .bold)).foregroundColor(UI.gold)
                Text(result == nil ? "Wir prüfen kurz dein Apple TV, damit alles flüssig läuft …"
                                   : "Fertig! ImperumTV ist passend für dein Apple TV eingestellt.")
                    .font(UI.font(28)).foregroundColor(UI.text.opacity(0.85))
            }
            .place(0, 120, 1920, 140, alignment: .center)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(500), spacing: 30), count: 3), spacing: 30) {
                ForEach(Array(cards.enumerated()), id: \.offset) { i, c in card(i, c) }
            }
            .place(0, 300, 1920, 480, alignment: .top)

            HStack(spacing: 30) {
                Button { nav.pop() } label: {
                    Text(first ? "Los geht’s" : "Fertig").font(UI.font(28, .bold)).padding(.horizontal, 50).frame(height: 70)
                }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                .focused($focus, equals: "go")
                Button { Task { await run() } } label: {
                    Text("Erneut prüfen").font(UI.font(28, .bold)).padding(.horizontal, 50).frame(height: 70)
                }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .black.opacity(0.4), border: UI.tan(0.6), borderWidth: 2))
                .focused($focus, equals: "again")
            }
            .opacity(running ? 0 : 1)
            .disabled(running)
            .place(0, 830, 1920, 90, alignment: .center)
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, "go")
        .task { await run() }
    }

    private func card(_ i: Int, _ c: (icon: String, title: String, value: String, ok: Bool?)) -> some View {
        let active = running && i == step
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(c.icon).font(UI.font(40))
                Text(c.title).font(UI.font(30, .bold))
                Spacer()
                Text(c.ok == nil ? (active ? "…" : "") : c.ok! ? "✓" : "!").font(UI.font(32, .bold))
                    .foregroundColor(c.ok == nil ? UI.muted : c.ok! ? Color(rgb: 0x7ee08a) : Color(rgb: 0xffc46b))
            }
            Text(c.value.isEmpty ? (active ? "wird geprüft …" : "") : c.value)
                .font(UI.font(24)).foregroundColor(UI.gold).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 500, height: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(.black.opacity(active ? 0.55 : 0.4)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(active ? UI.gold : c.ok == true ? Color(rgb: 0x7ee08a).opacity(0.5)
                                                            : c.ok == false ? Color(rgb: 0xffc46b).opacity(0.6) : .white.opacity(0.1), lineWidth: active ? 3 : 1.5))
    }

    private func set(_ i: Int, _ value: String, _ ok: Bool?) {
        cards[i].value = value; cards[i].ok = ok
    }

    private func run() async {
        guard !running else { return }
        running = true
        result = nil
        cards = Self.items.map { ($0.0, $0.1, "", nil) }
        let pause: UInt64 = 450_000_000

        // 1. Bildschirm
        step = 0; try? await Task.sleep(nanoseconds: pause)
        let h = DevCheck.screenHeight
        let hdr = AVPlayer.eligibleForHDRPlayback
        set(0, (h >= 2000 ? "4K Ultra HD (\(h)p)" : "Full HD (\(h)p)") + (hdr ? " · HDR" : ""), true)

        // 2. Videoformate
        step = 1; try? await Task.sleep(nanoseconds: pause)
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        set(1, "H.264 ja · HEVC " + (hevc ? "ja" : "nein") + " · HDR " + (hdr ? "ja" : "nein"), hevc)

        // 3. Ton
        step = 2; try? await Task.sleep(nanoseconds: pause)
        set(2, "Stereo · Dolby Digital · Dolby Digital Plus", true)

        // 4. Leistung
        step = 3; try? await Task.sleep(nanoseconds: pause)
        let ram = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        set(3, "\(ram) MB Arbeitsspeicher", ram >= 1500)

        // 5. Internet (bis 20 MB, höchstens etwa 8 Sekunden)
        step = 4
        let mbit = await speed()
        set(4, mbit > 0 ? String(format: "%.0f Mbit/s", mbit) + (mbit < 20 ? " · für 4K knapp" : "") : "nicht messbar", mbit >= 20 ? true : mbit > 0 ? false : nil)

        // 6. Player
        step = 5; try? await Task.sleep(nanoseconds: pause)
        let pref4k = h >= 2000 && hevc && (mbit <= 0 || mbit >= 20)
        set(5, pref4k ? "4K-Fassungen werden bevorzugt" : "Full-HD-Fassungen werden bevorzugt", true)

        let r = DevCheckResult(at: Date().timeIntervalSince1970, maxH: h, hevc: hevc, hdr: hdr, ram: ram, mbit: (mbit * 10).rounded() / 10, pref4k: pref4k)
        DevCheck.save(r)
        result = r
        step = -1
        running = false
        focus = "go"
    }

    private func speed() async -> Double {
        guard let u = URL(string: "https://speed.cloudflare.com/__down?bytes=20000000") else { return 0 }
        var req = URLRequest(url: u); req.timeoutInterval = 10
        let t0 = Date()
        guard let res = try? await URLSession.shared.bytes(for: req) else { return 0 }
        let stream = res.0
        var n = 0
        var it = stream.makeAsyncIterator()
        do {
            while let _ = try await it.next() {
                n += 1
                if n & 0xFFFF == 0, Date().timeIntervalSince(t0) > 8 { break }
            }
        } catch { if n == 0 { return 0 } }
        let secs = max(0.05, Date().timeIntervalSince(t0))
        return Double(n) * 8 / secs / 1_000_000
    }
}

// MARK: - Befehle aus dem Admin (Geräte-Check neu, Fernhilfe anfragen, Neu laden) – wie auf Android

@MainActor
enum RemoteFlags {
    private static var started = false

    /// Beim Start nach 1 s, dann alle 2 s bis die Verbindung steht (VPN, Anmeldung); danach alle 30 s
    static func start(nav: Nav, store: TVStore) {
        guard !started, !TVStore.testMode else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for _ in 0..<20 {
                if await poll(nav: nav, store: store) { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                _ = await poll(nav: nav, store: store)
            }
        }
    }

    private static func poll(nav: Nav, store: TVStore) async -> Bool {
        let ids = DeviceIdentity.load()
        guard !ids.mac.isEmpty, !ids.key.isEmpty else { return false }
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let d = try? await RemoteAPI.rpc("device_flags", ["p_mac": ids.mac, "p_key": ids.key, "p_version": "tvOS " + v]),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (o["ok"] as? Bool) == true else { return false }
        if let c = o["cmd"] as? String { run(c, nav: nav, store: store) }
        return true
    }

    private static func run(_ c: String, nav: Nav, store: TVStore) {
        switch c {
        case "devcheck": DevCheck.reset(); DevCheck.firstRun(nav: nav, store: store)
        case "help": if !RemoteHelp.shared.on { RemoteHelp.shared.asking = true }
        case "reload", "clearcache": Task { await store.reload() }
        default: break
        }
    }
}
