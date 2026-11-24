import SwiftUI
import UIKit

// MARK: - Fernhilfe (wie auf Android): der Support sieht ein Bild von ImperumTV und gibt einfache Befehle.
// Nur nach Zustimmung am Gerät, höchstens 60 Minuten, jederzeit beendbar.
// tvOS lässt keine Pfeil-/OK-Tasten von außen zu – deshalb Befehle wie „Zurück“, „Live TV öffnen“, „Pause“, „Sender +/−“.

@MainActor
final class RemoteHelp: ObservableObject {
    static let shared = RemoteHelp()

    @Published var on = false
    @Published var code = ""
    @Published var viewer = false
    /// Frage „Fernhilfe erlauben?“ anzeigen (true = vom Support angefragt)
    @Published var asking = false
    @Published var askingStop = false
    @Published var message: String?

    weak var nav: Nav?
    weak var engine: PlayerEngine?
    weak var store: TVStore?

    private var ack = 0
    private var lastSent: Data?
    private var lastSentAt = Date.distantPast
    private var task: Task<Void, Never>?

    var codeText: String { code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code }

    private var ids: (mac: String, key: String) { DeviceIdentity.load() }

    private func json(_ d: Data?) -> [String: Any]? {
        guard let d = d else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func start() {
        Task {
            let d = try? await RemoteAPI.rpc("device_help_start", ["p_mac": ids.mac, "p_key": ids.key])
            guard let o = json(d), let c = o["code"] as? String else {
                // Schutz gegen Dauer-Anfragen (höchstens 3× am Tag, 10 Minuten Pause) – Text kommt vom Server
                message = (json(d)?["error"] as? String) ?? "Fernhilfe ließ sich nicht starten. Prüfe die Internetverbindung."
                return
            }
            code = c; ack = 0; lastSent = nil
            let mins = (o["minutes"] as? NSNumber)?.doubleValue ?? 60
            UserDefaults.standard.set(["code": c, "until": Date().addingTimeInterval(mins * 60).timeIntervalSince1970], forKey: "tv.help")
            on = true
            message = "Fernhilfe läuft · Dein Code: \(codeText)\nNenne ihn dem Support. Beenden: Einstellungen → Fernhilfe."
            loop()
        }
    }

    /// Nach einem Neustart der App weitermachen, wenn die Fernhilfe noch läuft
    func resume() {
        guard let d = UserDefaults.standard.dictionary(forKey: "tv.help"), let c = d["code"] as? String,
              let u = d["until"] as? Double, u > Date().timeIntervalSince1970 else { return }
        code = c; ack = 0; on = true
        loop()
    }

    func stop(tell: Bool) {
        on = false; viewer = false
        task?.cancel(); task = nil
        UserDefaults.standard.removeObject(forKey: "tv.help")
        if tell {
            let i = ids
            Task.detached { _ = try? await RemoteAPI.rpc("device_help_end", ["p_mac": i.mac, "p_key": i.key]) }
        }
    }

    private func loop() {
        task?.cancel()
        task = Task { [weak self] in
            var fails = 0
            while !Task.isCancelled {
                guard let self = self, self.on else { return }
                let ok = await self.tick()
                fails = ok ? 0 : fails + 1
                if fails > 150 { self.stop(tell: false); return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func tick() async -> Bool {
        // Bild nur oft schicken, wenn der Support gerade zusieht (spart Datenvolumen)
        var snap: String?
        if viewer || Date().timeIntervalSince(lastSentAt) > 10, let s = snapshot() { snap = s }
        var body: [String: Any] = ["p_mac": ids.mac, "p_key": ids.key, "p_ack": ack]
        body["p_snap"] = snap ?? NSNull()
        guard let o = json(try? await RemoteAPI.rpc("device_help_push", body)) else { return false }
        if (o["active"] as? Bool) == false { stop(tell: false); return true }
        if snap != nil { lastSentAt = Date() }
        viewer = (o["viewer"] as? Bool) ?? false
        var ran = false
        for c in (o["cmds"] as? [[String: Any]]) ?? [] {
            let n = (c["n"] as? NSNumber)?.intValue ?? 0
            guard n > ack else { continue }
            ack = n; ran = true
            run(c["c"] as? String ?? "")
        }
        if ran { lastSent = nil; lastSentAt = .distantPast }
        return true
    }

    /// Bild des Bildschirms (ohne laufendes Video) als kleines JPEG
    private func snapshot() -> String? {
        guard let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        let size = CGSize(width: 960, height: 540)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            win.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        guard let jpg = img.jpegData(compressionQuality: 0.5) else { return nil }
        if jpg == lastSent { return nil }
        lastSent = jpg
        let obj: [String: Any] = ["tv": true, "img": "data:image/jpeg;base64," + jpg.base64EncodedString(), "p": nav?.top == .player]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Befehl vom Support ausführen
    private func run(_ c: String) {
        guard let nav = nav else { return }
        switch c {
        case "key:back":
            if nav.top == .player, let e = engine, e.kind != .live { e.stop() }
            if nav.top == .live || nav.top == .epg { engine?.stop() }
            nav.pop()
        case "key:play": engine?.toggle()
        case "key:ff": engine?.seek(by: 30)
        case "key:rw": engine?.seek(by: -30)
        case "key:chup", "key:chdown":
            guard let e = engine, e.kind == .live, !e.items.isEmpty, let st = store else { return }
            let n = (e.index + (c == "key:chup" ? 1 : -1) + e.items.count) % e.items.count
            e.index = n
            let it = e.items[n]
            if let u = st.url(it, .live) { e.play(u, item: it, kind: .live) }
        case "click:@home": engine?.stop(); nav.reset(.home)
        case "click:@live": nav.reset(.home); nav.push(.live)
        case "click:@epg": nav.reset(.home); nav.push(.epg)
        case "click:@movies": engine?.stop(); nav.reset(.home); nav.push(.movies)
        case "click:@series": engine?.stop(); nav.reset(.home); nav.push(.series)
        case "click:@settings": engine?.stop(); nav.reset(.home); nav.push(.settings)
        case "click:@playlists": engine?.stop(); nav.reset(.home); nav.push(.playlists)
        case "click:@nettest": nav.reset(.home); nav.push(.settings); nav.push(.nettest)
        case "click:@reload": if let st = store { Task { await st.reload() } }
        case "click:@cache": store?.clearCache()
        case "key:up", "key:down", "key:left", "key:right": FocusMover.move(String(c.dropFirst(4)))
        case "key:ok": FocusMover.activate()
        default: break
        }
    }
}

/// Fernhilfe: Pfeile und OK. tvOS lässt keine Tastendrücke von außen zu – die App verschiebt deshalb selbst den Fokus
/// zum nächsten Knopf in der Richtung und löst den gewählten Knopf aus (wie die Bedienungshilfen).
@MainActor
enum FocusMover {
    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// Alle Elemente, die den Fokus bekommen können, mit Rahmen im Fenster
    private static func items(in win: UIWindow) -> [(item: UIFocusItem, frame: CGRect)] {
        var out: [(UIFocusItem, CGRect)] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ container: UIFocusItemContainer, depth: Int) {
            guard depth < 40 else { return }
            let space = container.coordinateSpace
            let area = space.convert(win.bounds, from: win)
            for it in container.focusItems(in: area) {
                let id = ObjectIdentifier(it as AnyObject)
                if seen.contains(id) { continue }
                seen.insert(id)
                let f = space.convert(it.frame, to: win)
                if it.canBecomeFocused, f.width > 4, f.height > 4, f.intersects(win.bounds) { out.append((it, f)) }
                if let sub = (it as? UIFocusEnvironment)?.focusItemContainer, sub !== container { walk(sub, depth: depth + 1) }
            }
        }
        if let c = win.focusItemContainer { walk(c, depth: 0) }
        return out
    }

    private static func frame(of item: UIFocusItem, in win: UIWindow) -> CGRect? {
        guard let env = item.parentFocusEnvironment, let c = env.focusItemContainer else { return nil }
        return c.coordinateSpace.convert(item.frame, to: win)
    }

    @discardableResult
    static func move(_ dir: String) -> Bool {
        guard let win = window, let fs = UIFocusSystem.focusSystem(for: win) else { NSLog("IMPTVFOCUS kein Fenster"); return false }
        let all = items(in: win)
        NSLog("IMPTVFOCUS move %@: %d Elemente, Fokus %@ %@", dir, all.count, String(describing: fs.focusedItem.map { type(of: $0) }),
              String(describing: fs.focusedItem.flatMap { frame(of: $0, in: win) }))
        for (it, f) in all.prefix(30) { NSLog("IMPTVFOCUS  - %@ %@", String(describing: type(of: it)), NSCoder.string(for: f)) }
        guard !all.isEmpty else { return false }
        guard let cur = fs.focusedItem, let cf = frame(of: cur, in: win) ?? all.first(where: { $0.item === cur })?.frame else {
            fs.requestFocusUpdate(to: all[0].item); fs.updateFocusIfNeeded(); return true
        }
        let c = CGPoint(x: cf.midX, y: cf.midY)
        var best: (UIFocusItem, CGFloat)?
        for (it, f) in all where it !== cur {
            let p = CGPoint(x: f.midX, y: f.midY)
            let dx = p.x - c.x, dy = p.y - c.y
            let main: CGFloat, side: CGFloat
            switch dir {
            case "right": main = dx; side = abs(dy)
            case "left": main = -dx; side = abs(dy)
            case "down": main = dy; side = abs(dx)
            default: main = -dy; side = abs(dx)
            }
            guard main > 8 else { continue }
            let score = main + side * 2.2
            if best == nil || score < best!.1 { best = (it, score) }
        }
        guard let target = best?.0 else { NSLog("IMPTVFOCUS kein Ziel"); return false }
        fs.requestFocusUpdate(to: target)
        fs.updateFocusIfNeeded()
        NSLog("IMPTVFOCUS Ziel %@ → jetzt %@", String(describing: type(of: target)), String(describing: fs.focusedItem.map { type(of: $0) }))
        return true
    }

    /// OK: gewählten Knopf auslösen
    @discardableResult
    static func activate() -> Bool {
        guard let win = window, let fs = UIFocusSystem.focusSystem(for: win), let cur = fs.focusedItem else { return false }
        if let ctl = cur as? UIControl { ctl.sendActions(for: .primaryActionTriggered); return true }
        if let o = cur as? NSObject, o.accessibilityActivate() { return true }
        // Bedienungshilfen-Element an der Stelle des Fokus suchen und auslösen
        if let f = frame(of: cur, in: win) {
            let pt = CGPoint(x: f.midX, y: f.midY)
            func find(_ el: NSObject, depth: Int) -> NSObject? {
                guard depth < 30 else { return nil }
                let n = el.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<n {
                        guard let child = el.accessibilityElement(at: i) as? NSObject else { continue }
                        if child.accessibilityFrame.contains(win.convert(pt, to: nil)), let hit = find(child, depth: depth + 1) { return hit }
                    }
                }
                if let subs = (el as? UIView)?.subviews {
                    for v in subs.reversed() where !v.isHidden && v.frame.size.width > 0 {
                        if v.convert(v.bounds, to: win).contains(pt), let hit = find(v, depth: depth + 1) { return hit }
                    }
                }
                return el.isAccessibilityElement ? el : nil
            }
            if let hit = find(win, depth: 0), hit !== win, hit.accessibilityActivate() { return true }
        }
        return false
    }
}

/// Hinweis oben in der Mitte, solange die Fernhilfe läuft
struct HelpBanner: View {
    @ObservedObject var help = RemoteHelp.shared
    var body: some View {
        if help.on {
            Text("Fernhilfe " + (help.viewer ? "aktiv · Support sieht zu" : "bereit") + " · Code " + help.codeText)
                .font(UI.font(24, .semibold))
                .foregroundColor(Color(rgb: 0x1a1408))
                .padding(.horizontal, 26).frame(height: 50)
                .background(Capsule().fill(Color(rgb: 0xf4dc9e)))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                .allowsHitTesting(false)
        }
    }
}
