import SwiftUI
import AVFoundation
import UIKit
#if canImport(TVVLCKit)
import TVVLCKit
#endif

/// Tonspur bzw. Untertitel zur Auswahl
struct TrackOption: Identifiable, Hashable {
    let id: Int
    let name: String
    let selected: Bool
}

/// Ein Player für Vorschau und Vollbild (wie auf Android läuft der Sender beim Wechsel ins Vollbild einfach weiter).
/// Apple-Player (AVPlayer) für HLS/MP4, VLC für alles andere (MKV, AVI, TS …) oder wenn der Apple-Player scheitert.
@MainActor
final class PlayerEngine: ObservableObject {
    let player = AVPlayer()
    #if canImport(TVVLCKit)
    let vlc = VLCMediaPlayer()
    #endif
    let vlcView: UIView = {
        let v = UIView(); v.backgroundColor = .black; v.isUserInteractionEnabled = false; return v
    }()
    static var hasVLC: Bool {
        #if canImport(TVVLCKit)
        return true
        #else
        return false
        #endif
    }

    @Published var item: TVItem?
    @Published var kind: MediaKind = .live
    @Published var title = ""
    @Published var buffering = false
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var usingVLC = false
    @Published var notice: String?
    /// Bildformat: fit (ganzes Bild), fill (zoomen), stretch (strecken), zoom (stärker zoomen) oder festes Format 16:9 / 4:3 / 21:9
    @Published var gravity: String = UserDefaults.standard.string(forKey: "tv.gravity") ?? "fit"
    /// Schlaf-Timer: Zeitpunkt, zu dem angehalten wird
    @Published var sleepAt: Date?

    /// Liste, durch die im Vollbild geschaltet wird (Sender der Kategorie bzw. Folgen der Staffel)
    var items: [TVItem] = []
    var episodes: [Episode] = []
    var index = 0
    var art: Art = .none
    /// wird vor dem Wechsel zur nächsten Folge aufgerufen (Stand merken)
    var onEpisodeEnd: (() -> Void)?
    /// Ersatzsender für einen Sender (gleicher Sender in anderer Qualität)
    var altProvider: ((TVItem) -> [TVItem])?
    /// Adresse eines Senders
    var urlProvider: ((TVItem) -> URL?)?
    /// Sender zusammenfassen: alle Qualitäten eines Senders, Name der Qualität, Wahl merken
    var variantsProvider: ((TVItem) -> [TVItem])?
    var qualityName: ((TVItem) -> String)?
    var onChooseVariant: ((TVItem) -> Void)?
    /// Hänger melden (Fehlerberichte)
    var onStall: ((TVItem, String) -> Void)?
    /// Schlaf-Timer abgelaufen
    var onSleep: (() -> Void)?

    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    private var tcObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var pollTimer: Timer?
    private var stallTask: Task<Void, Never>?
    private var currentURL: URL?
    private var triedVLC = false
    /// Sender, die für den ursprünglichen Sender schon probiert wurden
    private var triedAlt: Set<Int> = []
    private var originalId: Int?
    private var vlcReady = false
    /// Filme/Folgen mit VLC: startet nicht → nach einiger Zeit Fehler zeigen statt endlos zu laden
    private var vodWatch: Task<Void, Never>?
    /// Fehlerbericht zur Wiedergabe: je Titel höchstens einmal pro App-Start
    private var diagSent: Set<String> = []
    private var lastAVError: String?

    /// Formate, die der Apple-Player nicht kann
    static let vlcExt: Set<String> = ["mkv", "avi", "wmv", "flv", "ts", "divx", "webm", "mpg", "mpeg", "vob", "m2ts", "3gp"]

    var liveEngine: String {
        get { UserDefaults.standard.string(forKey: "tv.liveEngine") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.liveEngine"); objectWillChange.send() }
    }
    var autoAlt: Bool {
        get { UserDefaults.standard.object(forKey: "tv.autoAlt") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.autoAlt"); objectWillChange.send() }
    }
    /// So lange darf ein Live-Sender hängen, bevor der Ersatzsender startet (Sekunden, Standard 1,5)
    var altWait: Double {
        get {
            // Standard 1 s; der alte Standard 1,5 s wird einmal umgestellt
            let ud = UserDefaults.standard
            if !ud.bool(forKey: "tv.altWait1s") {
                ud.set(true, forKey: "tv.altWait1s")
                if ud.object(forKey: "tv.altWait") as? Double == 1.5 { ud.set(1.0, forKey: "tv.altWait") }
            }
            return ud.object(forKey: "tv.altWait") as? Double ?? 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "tv.altWait"); objectWillChange.send() }
    }
    var vodEngine: String {
        get { UserDefaults.standard.string(forKey: "tv.vodEngine") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.vodEngine"); objectWillChange.send() }
    }

    /// Datenrate in Mbit/s (für die Verbindungsanzeige), 0 = unbekannt
    var mbit: Double {
        #if canImport(TVVLCKit)
        if usingVLC, let m = vlc.media {
            let st = (m as NSObject).value(forKey: "stats") as? [String: Any]
            return ((st?["inputBitrate"] as? NSNumber)?.doubleValue ?? 0) * 8
        }
        #endif
        guard let ev = player.currentItem?.accessLog()?.events.last else { return 0 }
        let b = ev.observedBitrate > 0 ? ev.observedBitrate : ev.indicatedBitrate
        return b > 0 ? b / 1_000_000 : 0
    }

    var bufferMode: String {
        get { UserDefaults.standard.string(forKey: "tv.buffer") ?? "normal" }
        set { UserDefaults.standard.set(newValue, forKey: "tv.buffer"); objectWillChange.send() }
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #if canImport(TVVLCKit)
        vlc.drawable = vlcView
        #endif
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self, !self.usingVLC else { return }
                self.position = max(0, t.seconds.isFinite ? t.seconds : 0)
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d } else { self.duration = 0 }
            }
        }
        tcObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.usingVLC else { return }
                self.setBuffering(p.timeControlStatus == .waitingToPlayAtSpecifiedRate && self.item != nil)
                self.playing = p.timeControlStatus == .playing
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: Abspielen

    /// Zweite Adresse, falls die erste nicht abspielbar ist
    var fallback: URL?

    func play(_ url: URL, item: TVItem, kind: MediaKind, title: String? = nil, art: Art? = nil, fallback: URL? = nil,
              startAt: Double = 0, keepAltState: Bool = false, forceVLC: Bool = false, forceApple: Bool = false) {
        self.fallback = fallback
        error = nil
        if !keepAltState { triedAlt = []; originalId = item.id; lastAVError = nil }
        vodWatch?.cancel()
        self.item = item
        self.kind = kind
        self.title = title ?? item.name
        self.art = art ?? item.art
        position = 0; duration = 0
        currentURL = url
        triedVLC = forceVLC
        stallTask?.cancel()
        let ext = url.pathExtension.lowercased()
        // „auto“ = Apple-Player, bei Problemen VLC · „apple“ = nur Apple-Player · „vlc“ = immer VLC
        let eng = kind == .live ? liveEngine : vodEngine
        if (eng == "apple" || forceApple) && !forceVLC { triedVLC = true }
        let wantVLC = Self.hasVLC && !forceApple && (forceVLC || eng == "vlc" || (eng != "apple" && Self.vlcExt.contains(ext)))
        if wantVLC { playVLC(url, startAt: startAt) } else { playAV(url, startAt: startAt) }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func playAV(_ url: URL, startAt: Double) {
        stopVLC()
        usingVLC = false
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": TVStore.userAgent]])
        let pi = AVPlayerItem(asset: asset)
        pi.preferredForwardBufferDuration = kind == .live ? (bufferMode == "small" ? 2 : bufferMode == "large" ? 8 : 4) : 0
        statusObs = pi.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.usingVLC else { return }
                if it.status == .failed {
                    let e = it.error as NSError?
                    self.lastAVError = e.map { "\($0.domain) \($0.code): \($0.localizedDescription)" + (($0.userInfo[NSUnderlyingErrorKey] as? NSError).map { " · \($0.domain) \($0.code)" } ?? "") }
                    self.failed(it.error?.localizedDescription)
                }
            }
        }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        player.replaceCurrentItem(with: pi)
        if startAt > 5 { player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
        player.play()
    }

    private func playVLC(_ url: URL, startAt: Double) {
        #if canImport(TVVLCKit)
        player.pause()
        player.replaceCurrentItem(with: nil)
        usingVLC = true
        vlcReady = false
        vlcGravityApplied = nil
        let m = VLCMedia(url: url)
        let cache = kind == .live ? (bufferMode == "small" ? 1000 : bufferMode == "large" ? 5000 : 2500) : 1500
        m.addOptions(["network-caching": cache, "http-user-agent": TVStore.userAgent, "http-reconnect": true])
        vlc.media = m
        vlc.play()
        vodWatch?.cancel()
        if kind != .live {
            let it = item, u = url
            vodWatch = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self = self, !Task.isCancelled, self.usingVLC, !self.vlcReady, self.item?.id == it?.id, self.currentURL == u else { return }
                // VLC meldet auch beim Abspielen oft weiter „puffert“: läuft die Zeit oder spielt er, ist alles gut
                if self.vlc.isPlaying || self.vlc.time.intValue > 0 { self.vlcReady = true; return }
                self.failed("VLC: nach 25 s noch kein Bild (Zustand \(self.vlcStateName()))")
            }
        }
        if startAt > 5 {
            let ms = Int32(startAt * 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.vlc.time = VLCTime(int: ms) }
        }
        setBuffering(true)
        #else
        playAV(url, startAt: startAt)
        #endif
    }

    private func stopVLC() {
        #if canImport(TVVLCKit)
        if usingVLC { vlc.stop() }
        #endif
    }

    /// Zustand von VLC und Schlaf-Timer prüfen
    private func poll() {
        if let s = sleepAt, Date() >= s {
            sleepAt = nil
            stop()
            onSleep?()
            return
        }
        #if canImport(TVVLCKit)
        guard usingVLC, item != nil else { return }
        let st = vlc.state
        position = Double(max(0, vlc.time.intValue)) / 1000
        let len = Double(vlc.media?.length.intValue ?? 0) / 1000
        duration = kind == .live ? 0 : max(0, len)
        playing = vlc.isPlaying
        if !vlcReady && kind != .live && (vlc.isPlaying || vlc.time.intValue > 0) { vlcReady = true; vodWatch?.cancel() }
        switch st {
        case .opening, .buffering:
            setBuffering(!vlc.isPlaying)
        case .playing, .esAdded:
            if vlcGravityApplied != gravity || !vlcReady { applyVLCGravity() }
            vlcReady = true
            vodWatch?.cancel()
            setBuffering(false)
        case .error:
            failed("VLC konnte die Adresse nicht öffnen")
        case .ended, .stopped:
            if item != nil && vlcReady { vlcReady = false; ended() }
        default: break
        }
        #endif
    }

    private func setBuffering(_ b: Bool) {
        if b == buffering { return }
        buffering = b
        stallTask?.cancel()
        // Live-Sender hängt länger als eingestellt (Standard 1,5 s, mit VLC 2 s länger) → Ersatzsender, sonst neu verbinden
        guard b, kind == .live, let it = item else { return }
        let wait = usingVLC ? altWait + 2 : altWait
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.buffering, self.item?.id == it.id else { return }
            self.onStall?(it, "Bild steht länger als \(String(format: "%.1f", wait)) s")
            if !self.tryAlt() { self.reconnect() }
        }
    }

    private func failed(_ msg: String?) {
        guard let it = item else { return }
        if let f = fallback {
            fallback = nil
            play(f, item: it, kind: kind, title: title, art: art, keepAltState: true)
            return
        }
        // Apple-Player kann das Format nicht → VLC
        if !triedVLC && !usingVLC && Self.hasVLC, let u = currentURL {
            triedVLC = true
            notice("Anderer Player wird versucht …")
            play(u, item: it, kind: kind, title: title, art: art, keepAltState: true, forceVLC: true)
            return
        }
        if kind == .live && tryAlt() { return }
        vodWatch?.cancel()
        if usingVLC { stopVLC() }
        error = (kind == .live ? "Sender" : "Titel") + " ließ sich nicht abspielen" + (msg.map { " (\($0))" } ?? "")
        setBuffering(false)
        if kind != .live { diagnose(it, msg) }
    }

    private func vlcStateName() -> String {
        #if canImport(TVVLCKit)
        switch vlc.state {
        case .opening: return "öffnet"
        case .buffering: return "puffert"
        case .playing: return "spielt"
        case .paused: return "Pause"
        case .stopped: return "gestoppt"
        case .ended: return "Ende"
        case .error: return "Fehler"
        case .esAdded: return "Spuren"
        @unknown default: return "?"
        }
        #else
        return "-"
        #endif
    }

    /// Film/Folge startet nicht: kurz beim Anbieter nachfragen, was er antwortet, und das melden (ohne Zugangsdaten)
    private func diagnose(_ it: TVItem, _ msg: String?) {
        guard let u = currentURL else { return }
        let key = "\(kind)-\(u.lastPathComponent)"
        guard !diagSent.contains(key) else { return }
        diagSent.insert(key)
        let ext = u.pathExtension.lowercased(), title = self.title ?? it.name
        let parts = u.path.split(separator: "/")
        let shown = (u.scheme ?? "") + "://" + (u.host ?? "") + "/" + (parts.first.map(String.init) ?? "") + "/…/…/" + u.lastPathComponent
        let engineInfo = (usingVLC ? "VLC" : "Apple-Player") + " · Einstellung \(vodEngine) · VLC versucht \(triedVLC ? "ja" : "nein") · VLC-Zustand \(vlcStateName())"
        let av = lastAVError ?? "-"
        Task.detached {
            var req = URLRequest(url: u, timeoutInterval: 12)
            req.setValue(TVStore.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=0-15", forHTTPHeaderField: "Range")
            var probe = ""
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let h = resp as? HTTPURLResponse
                let magic = data.prefix(8).map { String(format: "%02x", $0) }.joined()
                let fin = h?.url.map { ($0.scheme ?? "") + "://" + ($0.host ?? "") } ?? "-"
                probe = "HTTP \(h?.statusCode ?? 0) · \(h?.value(forHTTPHeaderField: "Content-Type") ?? "-") · Länge \(h?.value(forHTTPHeaderField: "Content-Range") ?? h?.value(forHTTPHeaderField: "Content-Length") ?? "-") · Anfang \(magic) · Ziel \(fin)"
            } catch {
                probe = "Abruf fehlgeschlagen: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)"
            }
            Report.send("wiedergabe", "Startet nicht (Apple TV): \(title)\nFormat: \(ext) · Adresse: \(shown)\nPlayer: \(engineInfo)\nMeldung: \(msg ?? "-")\nApple-Player: \(av)\nAnbieter: \(probe)")
        }
    }

    /// Ersatzsender versuchen (gleicher Sender in anderer Variante). true = gewechselt
    @discardableResult
    func tryAlt() -> Bool {
        guard autoAlt, kind == .live, let it = item, let provider = altProvider, let urlFor = urlProvider else { return false }
        triedAlt.insert(it.id)
        if let o = originalId { triedAlt.insert(o) }
        guard let alt = provider(it).first(where: { !triedAlt.contains($0.id) }), let u = urlFor(alt) else { return false }
        triedAlt.insert(alt.id)
        if let i = items.firstIndex(of: alt) { index = i }
        notice("Hänger – gewechselt auf " + alt.name)
        play(u, item: alt, kind: .live, keepAltState: true)
        return true
    }

    /// Im Player: andere Qualität desselben Senders (FHD, HD, 4K …)
    func switchVariant(_ v: TVItem) {
        guard kind == .live, let u = urlProvider?(v) else { return }
        if items.indices.contains(index) { items[index] = v }
        onChooseVariant?(v)
        play(u, item: v, kind: .live)
        notice("Qualität: " + (qualityName?(v) ?? v.name))
    }

    /// Im Player: dasselbe mit dem anderen Player weiter abspielen (Apple-Player ⇄ VLC)
    func switchPlayer() {
        guard Self.hasVLC, let it = item, let u = currentURL else { return }
        let toVLC = !usingVLC
        let at = kind == .live ? 0 : position
        play(u, item: it, kind: kind, title: title, art: art, startAt: at, keepAltState: true, forceVLC: toVLC, forceApple: !toVLC)
        notice("Läuft jetzt mit " + (toVLC ? "VLC" : "Apple-Player"))
    }

    private func reconnect() {
        guard let it = item, let u = currentURL else { return }
        notice("Verbindung wird neu aufgebaut …")
        play(u, item: it, kind: kind, title: title, art: art, keepAltState: true, forceVLC: usingVLC)
    }

    private func ended() {
        // Serie: nächste Folge, Live: neu verbinden
        if kind == .series, index + 1 < episodes.count, UserDefaults.standard.object(forKey: "tv.autonext") as? Bool ?? true { onEpisodeEnd?(); playEpisode(index + 1); return }
        if kind == .live { reconnect() }
    }

    func notice(_ t: String) {
        notice = t
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.notice == t { self?.notice = nil }
        }
    }

    func playEpisode(_ i: Int, startAt: Double = 0) {
        guard i >= 0, i < episodes.count, let it = item else { return }
        index = i
        let e = episodes[i]
        play(e.url, item: it, kind: .series, title: "\(it.name) · S\(e.season) F\(e.number) · \(e.title)", art: it.art, startAt: startAt)
    }

    /// Aktueller Stand für „Weiterschauen“
    func saveResume(_ book: ResumeBook, source: String) {
        guard let it = item, kind != .live, duration > 0 else { return }
        if kind == .series, index < episodes.count {
            let e = episodes[index]
            let n = index + 1 < episodes.count ? episodes[index + 1] : nil
            book.save(source: source, kind: .series, item: it, pos: position, dur: duration, episode: index,
                      episodeTitle: "S\(e.season) F\(e.number) · \(e.title)", episodeCount: episodes.count, episodeId: e.id,
                      season: e.season, num: e.number, epName: e.title,
                      nextEp: n.map { (id: $0.id, season: $0.season, num: $0.number, title: $0.title) })
        } else {
            book.save(source: source, kind: .movie, item: it, pos: position, dur: duration)
        }
    }

    func stop() {
        stallTask?.cancel()
        vodWatch?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        stopVLC()
        usingVLC = false
        item = nil
        playing = false
        buffering = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func toggle() {
        #if canImport(TVVLCKit)
        if usingVLC { if vlc.isPlaying { vlc.pause() } else { vlc.play() }; return }
        #endif
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func seek(by s: Double) {
        guard duration > 0 else { return }
        let t = min(max(0, position + s), duration - 1)
        #if canImport(TVVLCKit)
        if usingVLC { vlc.time = VLCTime(int: Int32(t * 1000)); position = t; return }
        #endif
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        position = t
    }

    /// festes Seitenverhältnis des Bildformats (nil = keins)
    static func ratio(_ g: String) -> CGFloat? { g == "16:9" ? 16.0 / 9 : g == "4:3" ? 4.0 / 3 : g == "21:9" ? 21.0 / 9 : nil }
    /// Zoomstufe für „Zoomen (stärker)“: schneidet auch schwarze Balken in Kinofilmen ab
    static let zoomScale: CGFloat = 1.33

    func setGravity(_ g: String) {
        let names = ["fit": "Ganzes Bild", "fill": "Zoomen (füllen)", "zoom": "Zoomen (stärker)", "stretch": "Strecken", "21:9": "21:9 (Kino)"]
        notice("Bildformat: " + (names[g] ?? g))
        gravity = g
        UserDefaults.standard.set(g, forKey: "tv.gravity")
        applyVLCGravity()
    }

    /// Bildformat bei VLC einstellen – bei jedem Start neu, sonst gilt es nur nach einem Wechsel im Menü
    private var vlcGravityApplied: String?
    func applyVLCGravity() {
        #if canImport(TVVLCKit)
        guard usingVLC else { return }
        vlcGravityApplied = gravity
        func set(_ crop: String?, _ ar: String?) {
            vlc.videoCropGeometry = crop.map { strdup($0) }
            vlc.videoAspectRatio = ar.map { strdup($0) }
        }
        let v = vlc.videoSize, src = v.width > 0 && v.height > 0 ? v.width / v.height : 16.0 / 9
        let screen = 16.0 / 9
        switch gravity {
        case "fill":                                       // Bildschirm füllen: Bild auf Bildschirmformat zuschneiden
            set(abs(src - screen) < 0.02 ? nil : "16:9", nil)
        case "zoom":                                       // erst füllen, das Vergrößern macht die Ansicht (scaleEffect)
            set(abs(src - screen) < 0.02 ? nil : "16:9", nil)
        case "stretch": set(nil, "16:9")
        case "16:9", "4:3", "21:9": set(nil, gravity)
        default: set(nil, nil)
        }
        #endif
    }

    // MARK: Ton und Untertitel

    func tracks(_ audio: Bool) -> [TrackOption] {
        #if canImport(TVVLCKit)
        if usingVLC {
            let names = (audio ? vlc.audioTrackNames : vlc.videoSubTitlesNames).compactMap { $0 as? String }
            let ids = (audio ? vlc.audioTrackIndexes : vlc.videoSubTitlesIndexes).compactMap { ($0 as? NSNumber)?.intValue }
            let cur = Int(audio ? vlc.currentAudioTrackIndex : vlc.currentVideoSubTitleIndex)
            return zip(ids, names).filter { audio ? $0.0 >= 0 : true }.map {
                TrackOption(id: $0.0, name: $0.0 < 0 ? "Aus" : $0.1, selected: $0.0 == cur)
            }
        }
        #endif
        guard let pi = player.currentItem,
              let g = pi.asset.mediaSelectionGroup(forMediaCharacteristic: audio ? .audible : .legible) else {
            return audio ? [] : [TrackOption(id: -1, name: "Aus", selected: true)]
        }
        let sel = pi.currentMediaSelection.selectedMediaOption(in: g)
        var out: [TrackOption] = audio ? [] : [TrackOption(id: -1, name: "Aus", selected: sel == nil)]
        for (i, o) in g.options.enumerated() {
            let lang = o.locale.flatMap { Locale(identifier: "de_DE").localizedString(forIdentifier: $0.identifier) }
            out.append(TrackOption(id: i, name: lang ?? o.displayName, selected: o == sel))
        }
        return out
    }

    func select(_ audio: Bool, _ id: Int) {
        #if canImport(TVVLCKit)
        if usingVLC {
            if audio { vlc.currentAudioTrackIndex = Int32(id) } else { vlc.currentVideoSubTitleIndex = Int32(id) }
            objectWillChange.send()
            return
        }
        #endif
        guard let pi = player.currentItem,
              let g = pi.asset.mediaSelectionGroup(forMediaCharacteristic: audio ? .audible : .legible) else { return }
        if id < 0 { pi.select(nil, in: g) } else if id < g.options.count { pi.select(g.options[id], in: g) }
        objectWillChange.send()
    }
}

/// Videobild (Apple-Player oder VLC)
struct VideoView: View {
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        ZStack {
            Color.black
            if let r = PlayerEngine.ratio(engine.gravity), !engine.usingVLC {
                // festes Format: Fläche in genau diesem Seitenverhältnis, Bild darin strecken
                AVLayerView(player: engine.player, gravity: "stretch").aspectRatio(r, contentMode: .fit)
            } else {
                AVLayerView(player: engine.player, gravity: engine.gravity == "zoom" ? "fill" : engine.gravity)
                    .scaleEffect(engine.gravity == "zoom" && !engine.usingVLC ? PlayerEngine.zoomScale : 1)
            }
            if engine.usingVLC {
                HostView(view: engine.vlcView).scaleEffect(engine.gravity == "zoom" ? PlayerEngine.zoomScale : 1)
            }
        }
        .clipped()
    }
}

private struct HostView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ v: UIView, context: Context) {}
}

private struct AVLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: String

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    private var g: AVLayerVideoGravity { gravity == "fill" ? .resizeAspectFill : gravity == "stretch" ? .resize : .resizeAspect }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = g
        v.playerLayer.player = player
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        if v.playerLayer.videoGravity != g { v.playerLayer.videoGravity = g }
    }
}

// MARK: - Vollbild mit Leiste unten (wie Android)

struct PlayerScreen: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var resume: ResumeBook
    @State private var osd = true
    @State private var hideTask: Task<Void, Never>?
    @State private var epgNow: EPGEntry?
    @State private var menu: String?            // nil, "main", "audio", "text", "format", "sleep"
    @State private var introDone = false
    @State private var nextCancelled = false
    @State private var nextCount = 10
    @AppStorage("tv.intro") private var introBtn = true
    @AppStorage("tv.autonext") private var autoNext = true
    @AppStorage("tv.netq") private var netq = "always"
    @FocusState private var focused: Bool
    /// Knöpfe in der Leiste (wie bei Android): welcher gerade gewählt ist
    @FocusState private var barFocus: String?
    /// Gewählter Knopf, von der App selbst verfolgt (der Fokus des Apple TV bleibt oft auf der Videofläche)
    @State private var barSel: String?
    /// Untermenü (Ton, Untertitel …): gewählte Zeile, von der App selbst verfolgt (wie die Leiste)
    @State private var menuSel = 0

    /// „Intro überspringen“ (Sekunde 2–10) bzw. „Nächste Folge in …“ (letzte 30 s)
    private var pop: String? {
        guard engine.kind == .series, menu == nil else { return nil }
        let t = engine.position, d = engine.duration
        if autoNext && !nextCancelled && engine.index + 1 < engine.episodes.count && d > 300 && d - t <= 30 && d - t > 1 { return "next" }
        if introBtn && !introDone && t >= 2 && t < 10 { return "intro" }
        return nil
    }

    var body: some View {
        ZStack {
            Button(action: {
                if let m = menu {                             // Untermenü offen: OK führt die gewählte Zeile aus
                    let it = menuItems(m)
                    if menuSel < it.count { it[menuSel].run() }
                    return
                }
                if osd, let k = barSel ?? barFocus { runBar(k); showOSD(); return }
                if pop == "intro" { engine.seek(by: 20); introDone = true; engine.notice("Intro übersprungen (+20 s)") }
                else if pop == "next" { goNext() }
                else { showBar() }
            }) {
                ZStack {
                    Color.black
                    VideoView(engine: engine)
                    if engine.buffering {
                        ProgressView().scaleEffect(2).tint(UI.gold)
                    }
                    if let e = engine.error {
                        Text(e).font(UI.font(30, .bold)).foregroundColor(UI.gold).multilineTextAlignment(.center)
                            .padding(30).background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.8)))
                    }
                    if let n = engine.notice {
                        Text(n).font(UI.font(26, .semibold)).foregroundColor(UI.text)
                            .padding(.horizontal, 28).padding(.vertical, 14)
                            .background(Capsule().fill(.black.opacity(0.8)))
                            .overlay(Capsule().stroke(UI.tan(0.6), lineWidth: 1.5))
                            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 60)
                    }
                    if osd && menu == nil { bar.transition(.opacity) }
                    if let p = pop { popView(p) }
                    if netq != "off" && engine.item != nil && (osd || netq == "problems") { netBadge }
                }
                .frame(width: 1920, height: 1080)
            }
            .buttonStyle(PlainPress())
            .focused($focused)
            .onMoveCommand { dir in
                if let m = menu {
                    let n = menuItems(m).count
                    if dir == .up { menuSel = max(0, menuSel - 1) }
                    if dir == .down { menuSel = min(max(0, n - 1), menuSel + 1) }
                    return
                }
                // Leiste offen: links/rechts springt von Knopf zu Knopf (nicht spulen), runter schließt die Leiste
                if osd, let f = barSel ?? barFocus {
                    let keys = barKeys()
                    let i = keys.firstIndex(of: f) ?? 0
                    switch dir {
                    case .left: if i > 0 { barSel = keys[i - 1]; barFocus = barSel }; showOSD()
                    case .right: if i < keys.count - 1 { barSel = keys[i + 1]; barFocus = barSel }; showOSD()
                    case .down: hideBar()
                    default: showOSD()
                    }
                    return
                }
                // Live: noch kein Knopf gewählt → links/rechts (auch Wischen) wählt gleich den Knopf neben „Pause“
                if engine.kind == .live && (dir == .left || dir == .right) { showBar(dir == .left ? "prev" : "next"); return }
                // Sender umschalten bzw. spulen nur mit Drücken – bloßes Wischen wird ignoriert (einstellbar)
                if TVRemote.clickOnly && TVRemote.shared.wasSwipe() { return }
                switch dir {
                case .up: if engine.kind == .live { step(-1) } else { showBar() }
                case .down: if engine.kind == .live { step(1) } else { showBar() }
                case .left: if engine.kind != .live { engine.seek(by: -10) }; showOSD()
                case .right: if engine.kind != .live { engine.seek(by: 10) }; showOSD()
                default: break
                }
            }
            .onPlayPauseCommand { engine.toggle(); showOSD() }

            if let m = menu { menuPanel(m) }
        }
        .onAppear {
            focused = true; showOSD()
            if TVStore.env["IMPTV_SCREEN"] == "playerbar" {    // Simulator-Test: Leiste mit Knöpfen zeigen
                Task { @MainActor in try? await Task.sleep(nanoseconds: 14_000_000_000); showBar() }
            }
        }
        .onExitCommand {
            if menu != nil { withAnimation { menu = nil }; focused = true }
            else if barFocus != nil { hideBar() }
            else if pop == "next" { nextCancelled = true }
            else { close() }
        }
        .onChange(of: menu) { _, m in
            // Menü auf: Auswahl auf die aktuelle Einstellung, Fokus bleibt auf der Videofläche (sie steuert das Menü)
            guard let m = m else { return }
            menuSel = menuItems(m).firstIndex(where: { $0.sel }) ?? 0
            focused = true
        }
        .onChange(of: engine.item?.id) { _, _ in introDone = false; nextCancelled = false }
        .onChange(of: barFocus) { _, f in if let f = f { barSel = f; showOSD() } }   // beim Wechseln in der Leiste nicht ausblenden
        .onChange(of: engine.index) { _, _ in introDone = false; nextCancelled = false }
        .task(id: pop) {
            guard pop == "next" else { nextCount = 10; return }
            nextCount = 10
            while nextCount > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if engine.playing { nextCount -= 1 }
            }
            if !Task.isCancelled && pop == "next" { goNext() }
        }
        .task {
            // alle 10 s den Stand merken (Filme, Folgen)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                engine.saveResume(resume, source: store.sourceName)
            }
        }
        .task(id: engine.item?.id) {
            guard engine.kind == .live, let it = engine.item else { epgNow = nil; return }
            let l = await store.epg(it)
            epgNow = l.first { ($0.start ?? .distantFuture) <= TVTime.now && ($0.end ?? .distantPast) > TVTime.now } ?? l.first
        }
    }

    private var bar: some View {
        HStack(spacing: 22) {
            ArtView(art: engine.art, poster: engine.kind != .live)
                .frame(width: 64, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 10) {
                Text(engine.title).font(UI.font(30, .bold)).lineLimit(1)
                if engine.kind == .live {
                    Text(epgNow.map { "Jetzt: \($0.title) · \($0.timeRange)" } ?? "Live")
                        .font(UI.font(23)).foregroundColor(UI.gold).lineLimit(1)
                    progress(epgNow?.progress ?? 0)
                } else {
                    progress(engine.duration > 0 ? engine.position / engine.duration : 0)
                    HStack {
                        Text(timeText(engine.position))
                        Spacer()
                        Text("-" + timeText(max(0, engine.duration - engine.position)))
                    }
                    .font(UI.font(19)).foregroundColor(UI.muted)
                }
            }
            Spacer(minLength: 20)
            // Knöpfe wie bei Android: gewählter Knopf gold, Name darüber
            HStack(spacing: 14) {
                if engine.kind == .live {
                    barButton("prev", "▲", "Sender zurück") { step(-1) }
                    barButton("play", engine.playing ? "❚❚" : "▶", engine.playing ? "Pause" : "Weiter") { engine.toggle() }
                    barButton("next", "▼", "Sender weiter") { step(1) }
                } else {
                    barButton("rw", "«", "10 s zurück") { engine.seek(by: -10) }
                    barButton("play", engine.playing ? "❚❚" : "▶", engine.playing ? "Pause" : "Weiter") { engine.toggle() }
                    barButton("ff", "»", "10 s vor") { engine.seek(by: 10) }
                }
                barButton("format", "▭", "Bildformat") { openMenu("format") }
                barButton("sleep", "☾", engine.sleepAt.map { "Schlaf-Timer · \(max(1, Int($0.timeIntervalSinceNow / 60))) Min" } ?? "Schlaf-Timer") { openMenu("sleep") }
                barButton("audio", "♪", "Ton") { openMenu("audio") }
                barButton("text", "CC", "Untertitel") { openMenu("text") }
                if engine.kind != .series, let it = engine.item {
                    barButton("fav", store.isFav(it, engine.kind) ? "★" : "☆", store.isFav(it, engine.kind) ? "Favorit entfernen" : "Favorit") {
                        store.toggleFav(it, engine.kind)
                        engine.notice(store.isFav(it, engine.kind) ? "Zu Favoriten hinzugefügt" : "Aus Favoriten entfernt")
                    }
                }
                barButton("more", "⋯", engine.usingVLC ? "Mehr · VLC" : "Mehr") { openMenu("main") }
            }
            .focusSection()
        }
        .padding(.horizontal, 24)
        .frame(width: 1620, height: 142)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(rgb: 0x0c0c0e, opacity: 0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(UI.tan(0.5), lineWidth: 1.5))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
    }

    // MARK: Einblendungen

    private func popView(_ p: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if p == "intro" {
                Text("⏭  Intro überspringen").font(UI.font(28, .bold)).foregroundColor(UI.dark)
                    .padding(.horizontal, 30).frame(height: 64).background(Capsule().fill(UI.gold))
                Text("OK drücken").font(UI.font(20)).foregroundColor(UI.muted)
            } else {
                let n = engine.index + 1 < engine.episodes.count ? engine.episodes[engine.index + 1] : nil
                Text("Nächste Folge in \(nextCount) s").font(UI.font(30, .bold))
                if let n = n { Text("S\(n.season) F\(n.number) · \(n.title)").font(UI.font(22)).foregroundColor(UI.muted).lineLimit(1) }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(UI.gold2).frame(width: g.size.width * Double(10 - nextCount) / 10)
                    }
                }
                .frame(height: 5)
                Text("OK: Jetzt ansehen · Zurück: Abbrechen").font(UI.font(20)).foregroundColor(UI.muted)
            }
        }
        .padding(28)
        .frame(width: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(rgb: 0x0c0c0e, opacity: 0.9)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(UI.tan(0.5), lineWidth: 1.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 80).padding(.bottom, osd ? 220 : 80)
    }

    /// Verbindungsanzeige oben (Datenrate)
    private var netBadge: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let m = engine.mbit
            let bad = engine.buffering || (m > 0 && m < 3)
            if netq == "always" || bad {
                HStack(spacing: 10) {
                    Circle().fill(engine.buffering ? Color(rgb: 0xff6b5e) : m == 0 ? UI.muted : m < 3 ? Color(rgb: 0xf4c35a) : Color(rgb: 0x7ee08a))
                        .frame(width: 14, height: 14)
                    Text(engine.buffering ? "Lädt …" : m > 0 ? String(format: "%.1f Mbit/s", m) : "Verbindung …")
                        .font(UI.font(22, .semibold))
                }
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.7)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 30)
            }
        }
    }

    private func goNext() {
        nextCancelled = true
        engine.onEpisodeEnd?()
        engine.playEpisode(engine.index + 1)
    }

    // MARK: Menü (Ton, Untertitel, Bildformat, Schlaf-Timer)

    private struct MItem { let title: String; let sel: Bool; let run: () -> Void }

    /// Zeilen des Untermenüs (Titel, aktuell eingestellt?, Aktion)
    private func menuItems(_ m: String) -> [MItem] {
        var r: [MItem] = []
        switch m {
        case "audio", "text":
            for t in engine.tracks(m == "audio") {
                r.append(MItem(title: t.name, sel: t.selected) { engine.select(m == "audio", t.id); close(menu: true) })
            }
        case "format":
            r.append(MItem(title: "Ganzes Bild", sel: engine.gravity == "fit") { engine.setGravity("fit"); close(menu: true) })
            r.append(MItem(title: "Zoomen (füllen)", sel: engine.gravity == "fill") { engine.setGravity("fill"); close(menu: true) })
            r.append(MItem(title: "Zoomen (stärker, Ränder abschneiden)", sel: engine.gravity == "zoom") { engine.setGravity("zoom"); close(menu: true) })
            r.append(MItem(title: "Strecken", sel: engine.gravity == "stretch") { engine.setGravity("stretch"); close(menu: true) })
            r.append(MItem(title: "16:9", sel: engine.gravity == "16:9") { engine.setGravity("16:9"); close(menu: true) })
            r.append(MItem(title: "4:3", sel: engine.gravity == "4:3") { engine.setGravity("4:3"); close(menu: true) })
            r.append(MItem(title: "21:9 (Kino)", sel: engine.gravity == "21:9") { engine.setGravity("21:9"); close(menu: true) })
        case "quality":
            for v in engine.item.flatMap({ engine.variantsProvider?($0) }) ?? [] {
                r.append(MItem(title: (engine.qualityName?(v) ?? "") + " – " + v.name, sel: v.id == engine.item?.id) { close(menu: true); engine.switchVariant(v) })
            }
        case "sleep":
            for mins in [0, 15, 30, 60, 90, 120] {
                r.append(MItem(title: mins == 0 ? "Aus" : "\(mins) Minuten", sel: mins == 0 ? engine.sleepAt == nil : false) {
                    engine.sleepAt = mins == 0 ? nil : Date().addingTimeInterval(Double(mins) * 60)
                    if mins > 0 { engine.notice("Schlaf-Timer: \(mins) Minuten") }
                    close(menu: true)
                })
            }
        default:
            r.append(MItem(title: "🔊  Tonspur", sel: false) { menu = "audio" })
            r.append(MItem(title: "💬  Untertitel", sel: false) { menu = "text" })
            r.append(MItem(title: "🖼  Bildformat", sel: false) { menu = "format" })
            r.append(MItem(title: "🌙  Schlaf-Timer" + (engine.sleepAt != nil ? " (an)" : ""), sel: false) { menu = "sleep" })
            if PlayerEngine.hasVLC {
                r.append(MItem(title: "⇄  Anderer Player (jetzt: " + (engine.usingVLC ? "VLC" : "Apple-Player") + ")", sel: false) { close(menu: true); engine.switchPlayer() })
            }
            if engine.kind == .live, let it = engine.item, (engine.variantsProvider?(it).count ?? 0) > 1 {
                r.append(MItem(title: "◎  Qualität · " + (engine.qualityName?(it) ?? ""), sel: false) { menu = "quality" })
            }
            if engine.kind == .live {
                r.append(MItem(title: "🔁  Ersatzsender suchen", sel: false) { close(menu: true); if !engine.tryAlt() { engine.notice("Kein Ersatzsender gefunden") } })
            }
        }
        return r
    }

    private func menuPanel(_ m: String) -> some View {
        let items = menuItems(m)
        return VStack(alignment: .leading, spacing: 10) {
            Text(menuTitle(m)).font(UI.font(30, .bold)).foregroundColor(UI.gold).padding(.bottom, 8)
            if items.isEmpty { Text("Keine weiteren Spuren").font(UI.font(24)).foregroundColor(UI.muted) }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(items.indices, id: \.self) { i in
                            menuRow(items[i].title, items[i].sel, i == menuSel).id(i)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: menuSel) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
            }
        }
        .padding(36)
        .frame(width: 620, height: 640, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(rgb: 0x121114, opacity: 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(UI.tan(0.5), lineWidth: 1.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 60)
    }

    /// Zeile im Untermenü: gewählt = gold mit dunkler Schrift, aktuell eingestellt = Haken
    private func menuRow(_ t: String, _ sel: Bool, _ cur: Bool) -> some View {
        HStack {
            Text(t).font(UI.font(26, .semibold)).lineLimit(1)
            Spacer()
            if sel { Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)) }
        }
        .foregroundColor(cur ? UI.dark : UI.text)
        .padding(.horizontal, 22).frame(width: 520, height: 66)
        .background(RoundedRectangle(cornerRadius: 12).fill(cur ? UI.gold : (sel ? UI.tan(0.22) : Color.white.opacity(0.06))))
        .scaleEffect(cur ? 1.03 : 1)
    }

    private func menuTitle(_ m: String) -> String {
        switch m { case "audio": return "Tonspur"; case "text": return "Untertitel"; case "format": return "Bildformat"
        case "sleep": return "Schlaf-Timer"; case "quality": return "Qualität"; default: return "Optionen" }
    }

    private func row(_ t: String, _ sel: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(t).font(UI.font(26, .semibold)).lineLimit(1)
                Spacer()
                if sel { Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)) }
            }
            .padding(.horizontal, 22).frame(width: 520, height: 66)
        }
        .buttonStyle(GoldStyle(normal: .white.opacity(0.06), active: sel))
    }

    private func openMenu(_ m: String = "main") {
        hideTask?.cancel()
        withAnimation { menu = m }
        focused = true
    }

    /// Leiste mit Knöpfen zeigen, Fokus auf Pause/Weiter
    private func showBar(_ key: String = "play") {
        showOSD()
        barSel = key
        // erst wenn die Knöpfe da sind, kann einer den Fokus bekommen (nur wenn noch derselbe Knopf gewählt ist)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            if barSel == key { barFocus = key }
            if barFocus == nil, barSel == key { try? await Task.sleep(nanoseconds: 200_000_000); if barSel == key { barFocus = key } }
        }
    }

    /// Leiste ausblenden, Fokus zurück aufs Bild (Pfeile spulen bzw. schalten Sender)
    /// Knopf der Leiste ausführen (OK auf der Fernbedienung)
    private func runBar(_ k: String) {
        switch k {
        case "prev": step(-1)
        case "next": step(1)
        case "rw": engine.seek(by: -10)
        case "ff": engine.seek(by: 10)
        case "play": engine.toggle()
        case "format", "sleep", "audio", "text": openMenu(k)
        case "fav":
            if let it = engine.item {
                store.toggleFav(it, engine.kind)
                engine.notice(store.isFav(it, engine.kind) ? "Zu Favoriten hinzugefügt" : "Aus Favoriten entfernt")
            }
        case "more": openMenu("main")
        default: break
        }
    }

    /// Reihenfolge der Knöpfe in der Leiste (wie sie angezeigt werden)
    private func barKeys() -> [String] {
        var k = engine.kind == .live ? ["prev", "play", "next"] : ["rw", "play", "ff"]
        k += ["format", "sleep", "audio", "text"]
        if engine.kind != .series, engine.item != nil { k.append("fav") }
        k.append("more")
        return k
    }

    private func hideBar() {
        hideTask?.cancel()
        barFocus = nil; barSel = nil
        focused = true
        withAnimation { osd = false }
    }

    private func barButton(_ key: String, _ label: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: label.count > 1 && label != "❚❚" ? 24 : 30, weight: .bold))
                .frame(width: 66, height: 66)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(Circle()), normal: .white.opacity(0.1), ring: false, solid: true))
        .remoteFocused($barFocus, equals: key)
        .background(Circle().fill(UI.gold).opacity((barSel == key && barFocus != key) ? 1 : 0))   // gewählt, auch wenn der Fokus woanders ist
        .overlay(alignment: .top) {
            if (barSel ?? barFocus) == key {
                Text(tip).font(UI.font(22, .bold)).foregroundColor(UI.dark).lineLimit(1).fixedSize()
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(UI.gold))
                    .offset(y: -50)
                    .allowsHitTesting(false)
            }
        }
    }

    private func close(menu: Bool) {
        withAnimation { self.menu = nil }
        focused = true
        showOSD()
    }

    private func progress(_ p: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(UI.gold2).frame(width: g.size.width * min(max(p, 0), 1))
            }
        }
        .frame(height: 4)
    }

    private func showOSD() {
        withAnimation { osd = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled && TVStore.env["IMPTV_SCREEN"] != "playerbar" {
                if menu == nil { barFocus = nil; barSel = nil; focused = true }
                withAnimation { osd = false }
            }
        }
    }

    private func step(_ d: Int) {
        guard engine.kind == .live, !engine.items.isEmpty else { return }
        let n = (engine.index + d + engine.items.count) % engine.items.count
        engine.index = n
        let it = engine.items[n]
        if let u = store.url(it, .live) { engine.play(u, item: it, kind: .live) }
        showOSD()
    }

    /// Zurück: Live läuft in der Senderliste als Vorschau weiter, Filme/Folgen halten an
    private func close() {
        hideTask?.cancel()
        engine.saveResume(resume, source: store.sourceName)
        if engine.kind != .live { engine.stop() }
        nav.pop()
    }
}

/// Knopf ohne sichtbaren Fokus (ganzer Bildschirm im Vollbild)
struct PlainPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
