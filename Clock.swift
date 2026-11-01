import SwiftUI

// MARK: - Uhr oben rechts (mit Sekunden, abschaltbar in den Einstellungen)

struct ClockBadge: View {
    /// "sec" = mit Sekunden, "min" = ohne Sekunden, "off" = aus
    @AppStorage("clockMode") private var mode = "sec"

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let ss: DateFormatter = { let f = DateFormatter(); f.dateFormat = ":ss"; return f }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EE, d. MMMM"; return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            SleepBadge()
            clock
        }
    }

    @ViewBuilder
    private var clock: some View {
        if mode != "off" {
            TimelineView(.periodic(from: .now, by: mode == "sec" ? 1 : 30)) { ctx in
                VStack(alignment: .trailing, spacing: 1) {
                    (Text(Self.hm.string(from: ctx.date)).foregroundColor(.white)
                     + Text(mode == "sec" ? Self.ss.string(from: ctx.date) : "").foregroundColor(Theme.goldLight))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                    Text(Self.day.string(from: ctx.date))
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.65))
                }
                .shadow(color: .black.opacity(0.7), radius: 3)
                .accessibilityElement(children: .combine)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Uhr oben rechts in der Navigationsleiste (neben vorhandenen Knöpfen)
    func clockInToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { ClockBadge() }
        }
    }
}

// MARK: - Verbindungstest: Internet, Geschwindigkeit, Server, Test-Sender

/// Lädt eine Adresse und misst: Zeit bis zu den ersten Daten, Menge, Datenrate
final class ByteMeter: NSObject, URLSessionDataDelegate {
    struct Result {
        var ok = false
        var status = 0
        var firstMs = 0
        var bytes = 0
        var mbit = 0.0
        var body = Data()
    }

    private var result = Result()
    private var start = Date()
    private var firstAt: Date?
    private var firstBytes = 0
    private var lastAt: Date?
    private var stopBytes = Int.max
    private var keepBody = false
    private var cont: CheckedContinuation<Result, Never>?
    private var session: URLSession?
    private var finished = false

    static func run(_ url: URL, maxSeconds: Double, stopBytes: Int = .max, keepBody: Bool = false, userAgent: String? = nil) async -> Result {
        let m = ByteMeter()
        return await m.start(url, maxSeconds: maxSeconds, stopBytes: stopBytes, keepBody: keepBody, userAgent: userAgent)
    }

    private func start(_ url: URL, maxSeconds: Double, stopBytes: Int, keepBody: Bool, userAgent: String?) async -> Result {
        self.stopBytes = stopBytes
        self.keepBody = keepBody
        return await withCheckedContinuation { c in
            self.cont = c
            let cfg = URLSessionConfiguration.ephemeral
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.timeoutIntervalForRequest = maxSeconds + 2
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue())
            self.session = s
            var req = URLRequest(url: url)
            if let ua = userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
            self.start = Date()
            s.dataTask(with: req).resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) { [weak self] in
                self?.queue.async { self?.finish(ok: self?.firstAt != nil) }
            }
        }
    }

    private let queue = DispatchQueue(label: "bytemeter")

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async { self.result.status = (response as? HTTPURLResponse)?.statusCode ?? 0 }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            guard !self.finished else { return }
            let now = Date()
            if self.firstAt == nil { self.firstAt = now; self.firstBytes = data.count }
            self.result.bytes += data.count
            self.lastAt = now
            if self.keepBody && self.result.body.count < 200_000 { self.result.body.append(data) }
            if self.result.bytes >= self.stopBytes { self.finish(ok: true) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            let ok = error == nil && (200..<400).contains(self.result.status)
            self.finish(ok: ok)
        }
    }

    /// Nur auf `queue` aufrufen
    private func finish(ok: Bool) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        let now = Date()
        if let f = firstAt {
            result.firstMs = Int(f.timeIntervalSince(start) * 1000)
            let span = (lastAt ?? now).timeIntervalSince(f)
            if span > 0.15 {
                result.mbit = Double(result.bytes - firstBytes) * 8 / span / 1_000_000
            } else if result.bytes > 500_000 {
                result.mbit = Double(result.bytes) * 8 / max(0.05, now.timeIntervalSince(start)) / 1_000_000
            }
        }
        result.ok = ok
        let c = cont
        cont = nil
        c?.resume(returning: result)
    }
}

struct NetTestView: View {
    @EnvironmentObject private var store: AppStore

    enum State { case wait, run, ok, warn, bad, skip }
    struct Row: Identifiable {
        let id: String
        let title: String
        var state: State = .wait
        var sub = "wartet …"
        var value = ""
        var bar: Double?
    }

    @SwiftUI.State private var rows: [Row] = [
        Row(id: "net", title: "Internet"),
        Row(id: "speed", title: "Geschwindigkeit"),
        Row(id: "server", title: "Server deines Anbieters"),
        Row(id: "stream", title: "Test-Sender")
    ]
    @SwiftUI.State private var running = false
    @SwiftUI.State private var resultText: String?
    @SwiftUI.State private var tipText = ""
    @SwiftUI.State private var lines: [String] = []
    @SwiftUI.State private var sentNote: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(rows) { r in rowView(r) }
                if let text = resultText {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Ergebnis", systemImage: "lightbulb").font(.subheadline.weight(.bold)).foregroundStyle(Theme.goldLight)
                        Text(text).font(.body)
                        Text(tipText).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { Task { await run() } } label: {
                                Label("Erneut testen", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(Theme.goldLight))
                            }
                            .buttonStyle(.plain)
                            Button { Task { await send() } } label: {
                                Label("Ergebnis an Support senden", systemImage: "paperplane")
                                    .font(.subheadline).foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(Color.white.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                        if let sentNote { Text(sentNote).font(.footnote).foregroundStyle(Theme.goldLight) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.gold.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.goldLight, lineWidth: 1.2))
                }
            }
            .padding(16)
        }
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Verbindungstest")
        .task { await run() }
    }

    private func rowView(_ r: Row) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color(r.state).opacity(0.18)).frame(width: 34, height: 34)
                switch r.state {
                case .run: ProgressView().tint(Theme.goldLight).scaleEffect(0.8)
                case .ok: Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(color(r.state))
                case .warn: Image(systemName: "exclamationmark").font(.subheadline.weight(.bold)).foregroundStyle(color(r.state))
                case .bad: Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(color(r.state))
                case .skip: Text("–").foregroundStyle(.secondary)
                case .wait: Text("•").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.subheadline.weight(.bold))
                Text(r.sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let b = r.bar {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(Theme.goldLight).frame(width: g.size.width * max(0.02, min(1, b)))
                        }
                    }
                    .frame(height: 5)
                }
            }
            Spacer()
            Text(r.value).font(.subheadline.weight(.bold)).foregroundStyle(r.state == .warn ? Color.orange : r.state == .bad ? Color.red : Color.white)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
    }

    private func color(_ s: State) -> Color {
        switch s {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        default: return .gray
        }
    }

    private func set(_ id: String, _ state: State, _ sub: String, _ value: String = "", bar: Double? = nil) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = state; rows[i].sub = sub; rows[i].value = value; rows[i].bar = bar
    }

    private static func num(_ x: Double, _ d: Int = 1) -> String {
        String(format: "%.\(d)f", x).replacingOccurrences(of: ".", with: ",")
    }

    private func run() async {
        guard !running else { return }
        running = true
        resultText = nil; sentNote = nil; lines = []
        for r in rows { set(r.id, .wait, "wartet …") }
        defer { running = false }

        // 1) Internet
        set("net", .run, "prüft …")
        let site = URL(string: "https://holy-mode-e130.imperumtv.workers.dev/robots.txt?t=\(Int(Date().timeIntervalSince1970))")!
        let net = await ByteMeter.run(site, maxSeconds: 6)
        guard net.ok else {
            set("net", .bad, "Keine Antwort aus dem Internet", "Keine Verbindung")
            lines.append("Internet: keine Verbindung")
            for id in ["speed", "server", "stream"] { set(id, .skip, "übersprungen", "–") }
            finish(text: "Das iPhone hat gerade keine Internetverbindung.", tip: "Tipp: WLAN oder mobile Daten prüfen.")
            return
        }
        set("net", .ok, "Antwortzeit \(net.firstMs) ms", "Verbunden")
        lines.append("Internet: verbunden, \(net.firstMs) ms")

        // 2) Geschwindigkeit (öffentlicher Messserver von Cloudflare)
        set("speed", .run, "misst …")
        let sp = await ByteMeter.run(URL(string: "https://speed.cloudflare.com/__down?bytes=20000000")!, maxSeconds: 6)
        let mb = sp.mbit
        if mb <= 0 {
            set("speed", .skip, "Messung hat nicht geklappt", "–")
            lines.append("Geschwindigkeit: nicht messbar")
        } else {
            let st: State = mb >= 10 ? .ok : mb >= 5 ? .warn : .bad
            let txt = mb >= 25 ? "Reicht auch für 4K" : mb >= 10 ? "Reicht für HD (für 4K etwa 25 Mbit/s nötig)" : mb >= 5 ? "Reicht knapp für HD" : "Zu langsam für flüssiges HD"
            set("speed", st, txt, Self.num(mb, mb >= 10 ? 0 : 1) + " Mbit/s", bar: mb / 50)
            lines.append("Geschwindigkeit: \(Self.num(mb)) Mbit/s")
        }

        // 3) Server des Anbieters
        var serverFail = false, full = false, inactive = false
        if store.isXtream, let url = store.accountInfoURL {
            set("server", .run, "prüft …")
            let r = await ByteMeter.run(url, maxSeconds: 10, keepBody: true, userAgent: store.userAgentValue)
            let info = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
            let ui = info?["user_info"] as? [String: Any]
            if !r.ok || ui == nil {
                serverFail = true
                set("server", .bad, r.status > 0 ? "Server meldet HTTP \(r.status)" : "Server nicht erreichbar", "Fehler")
                lines.append("Server: Fehler \(r.status)")
            } else {
                func str(_ k: String) -> String { if let s = ui?[k] as? String { return s }; if let n = ui?[k] as? NSNumber { return n.stringValue }; return "" }
                let maxC = Int(str("max_connections")) ?? 0, act = Int(str("active_cons")) ?? 0
                let status = str("status")
                full = maxC > 0 && act >= maxC
                inactive = !status.isEmpty && status.lowercased() != "active"
                let cons = maxC > 0 ? "\(act) von \(maxC) Verbindungen belegt" : ""
                let st: State = inactive ? .bad : (full || r.firstMs > 2000) ? .warn : .ok
                set("server", st, "Antwortzeit \(r.firstMs) ms" + (cons.isEmpty ? "" : " · " + cons) + (inactive ? " · Zugang: \(status)" : ""),
                    r.firstMs > 2000 ? "Langsam" : inactive ? "Gesperrt" : "Erreichbar")
                lines.append("Server: \(r.firstMs) ms, \(cons), Status \(status)")
            }
        } else {
            set("server", .skip, "Nur mit Zugangsdaten (Xtream) prüfbar", "–")
            lines.append("Server: nicht geprüft")
        }

        // 4) Test-Sender: wie schnell kommen Bilddaten?
        var streamSlow = false
        let favs = store.channels.first(where: { store.isFavorite($0) })
        if let ch = favs ?? store.channels.first(where: { !Football.isSeparator($0.name) }) {
            set("stream", .run, ch.name + " · prüft …")
            var r = await ByteMeter.run(ch.url, maxSeconds: 5, stopBytes: 6_000_000, keepBody: ch.url.pathExtension.lowercased() == "m3u8", userAgent: store.userAgentValue)
            if let text = String(data: r.body, encoding: .utf8), text.hasPrefix("#EXTM3U"),
               let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
               let seg = URL(string: String(line), relativeTo: ch.url) {
                let pl = r.firstMs
                r = await ByteMeter.run(seg.absoluteURL, maxSeconds: 5, stopBytes: 6_000_000, userAgent: store.userAgentValue)
                r.firstMs += pl
            }
            if r.firstMs == 0 && r.bytes == 0 {
                streamSlow = true
                set("stream", .bad, ch.name + " · keine Bilddaten", "Fehler")
                lines.append("Sender \(ch.name): keine Daten (HTTP \(r.status))")
            } else {
                let sec = Double(r.firstMs) / 1000
                let st: State = sec < 2 ? .ok : sec < 4.5 ? .warn : .bad
                streamSlow = st != .ok
                set("stream", st, ch.name + " · Bilddaten nach \(Self.num(sec)) s" + (r.mbit > 0 ? " · \(Self.num(r.mbit)) Mbit/s" : "") + (st != .ok ? " (normal: unter 2 s)" : ""),
                    st == .ok ? "Schnell" : st == .warn ? "Langsam" : "Sehr langsam")
                lines.append("Sender \(ch.name): erste Daten nach \(Self.num(sec)) s, \(Self.num(r.mbit)) Mbit/s")
            }
        } else {
            set("stream", .skip, "Keine Sender in der Liste", "–")
        }

        if inactive {
            finish(text: "Dein Zugang beim Anbieter ist nicht aktiv (abgelaufen oder gesperrt).", tip: "Tipp: Beim Anbieter nachfragen.")
        } else if serverFail {
            finish(text: "Dein Internet funktioniert, aber der Server deines Anbieters antwortet nicht richtig.", tip: "Tipp: Später noch einmal probieren oder beim Anbieter nachfragen.")
        } else if full {
            finish(text: "Alle Verbindungen deines Zugangs sind belegt.", tip: "Tipp: Auf anderen Geräten die Wiedergabe beenden, dann geht es hier wieder.")
        } else if mb > 0 && mb < 5 {
            finish(text: "Dein Internet ist zu langsam für flüssiges Fernsehen (\(Self.num(mb)) Mbit/s).", tip: "Tipp: Näher an den Router, 5-GHz-WLAN nutzen oder andere Downloads beenden.")
        } else if streamSlow {
            finish(text: "Dein Internet ist schnell genug, aber der Sender startet langsam. Das liegt wahrscheinlich am Server deines Anbieters.", tip: "Tipp: Später noch einmal probieren oder in den Einstellungen „Live-TV mit VLC abspielen“ einschalten.")
        } else {
            finish(text: "Alles in Ordnung.", tip: "Wenn ein einzelner Sender trotzdem hängt, liegt es meist an diesem Sender beim Anbieter.")
        }
    }

    private func finish(text: String, tip: String) {
        resultText = text
        tipText = tip
    }

    private func send() async {
        guard let text = resultText else { return }
        let ok = await CrashReport.sendNow(kind: "verbindungstest", message: text + "\n" + lines.joined(separator: "\n"))
        sentNote = ok ? "Ergebnis gesendet." : "Senden hat nicht geklappt."
    }
}
