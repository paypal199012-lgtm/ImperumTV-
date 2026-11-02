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
    /// Bildformat: fit (ganzes Bild), fill (zoomen), stretch (strecken)
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
              startAt: Double = 0, keepAltState: Bool = false, forceVLC: Bool = false) {
        self.fallback = fallback
        error = nil
        if !keepAltState { triedAlt = []; originalId = item.id }
        self.item = item
        self.kind = kind
        self.title = title ?? item.name
        self.art = art ?? item.art
        position = 0; duration = 0
        currentURL = url
        triedVLC = forceVLC
        stallTask?.cancel()
        let ext = url.pathExtension.lowercased()
        let wantVLC = Self.hasVLC && (forceVLC || (kind == .live && liveEngine == "vlc") || Self.vlcExt.contains(ext))
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
                if it.status == .failed { self.failed(it.error?.localizedDescription) }
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
        let m = VLCMedia(url: url)
        let cache = kind == .live ? (bufferMode == "small" ? 1000 : bufferMode == "large" ? 5000 : 2500) : 1500
        m.addOptions(["network-caching": cache, "http-user-agent": TVStore.userAgent, "http-reconnect": true])
        vlc.media = m
        vlc.play()
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
        switch st {
        case .opening, .buffering:
            setBuffering(!vlc.isPlaying)
        case .playing, .esAdded:
            vlcReady = true
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
        // Live-Sender hängt länger als 3 s (bzw. 8 s mit VLC) → Ersatzsender, sonst neu verbinden
        guard b, kind == .live, let it = item else { return }
        let wait: UInt64 = usingVLC ? 8 : 3
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard let self = self, !Task.isCancelled, self.buffering, self.item?.id == it.id else { return }
            self.onStall?(it, "Bild steht länger als \(wait) s")
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
        error = "Sender ließ sich nicht abspielen" + (msg.map { " (\($0))" } ?? "")
        setBuffering(false)
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

    private func reconnect() {
        guard let it = item, let u = currentURL else { return }
        notice("Verbindung wird neu aufgebaut …")
        play(u, item: it, kind: kind, title: title, art: art, keepAltState: true, forceVLC: usingVLC)
    }

    private func ended() {
        // Serie: nächste Folge, Live: neu verbinden
        if kind == .series, index + 1 < episodes.count { onEpisodeEnd?(); playEpisode(index + 1); return }
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
            book.save(source: source, kind: .series, item: it, pos: position, dur: duration, episode: index,
                      episodeTitle: "S\(e.season) F\(e.number) · \(e.title)", episodeCount: episodes.count, episodeId: e.id)
        } else {
            book.save(source: source, kind: .movie, item: it, pos: position, dur: duration)
        }
    }

    func stop() {
        stallTask?.cancel()
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

    func setGravity(_ g: String) {
        gravity = g
        UserDefaults.standard.set(g, forKey: "tv.gravity")
        #if canImport(TVVLCKit)
        if usingVLC {
            switch g {
            case "fill": vlc.videoCropGeometry = strdup("16:9"); vlc.videoAspectRatio = nil
            case "stretch": vlc.videoCropGeometry = nil; vlc.videoAspectRatio = strdup("16:9")
            default: vlc.videoCropGeometry = nil; vlc.videoAspectRatio = nil
            }
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
            AVLayerView(player: engine.player, gravity: engine.gravity)
            if engine.usingVLC { HostView(view: engine.vlcView) }
        }
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
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Button(action: { openMenu() }) {
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
                }
                .frame(width: 1920, height: 1080)
            }
            .buttonStyle(PlainPress())
            .disabled(menu != nil)
            .focused($focused)
            .onMoveCommand { dir in
                switch dir {
                case .up: if engine.kind == .live { step(-1) } else { showOSD() }
                case .down: if engine.kind == .live { step(1) } else { showOSD() }
                case .left: if engine.kind != .live { engine.seek(by: -10) }; showOSD()
                case .right: if engine.kind != .live { engine.seek(by: 10) }; showOSD()
                default: break
                }
            }
            .onPlayPauseCommand { engine.toggle(); showOSD() }

            if let m = menu { menuPanel(m).focusSection() }
        }
        .onAppear { focused = true; showOSD() }
        .onExitCommand {
            if menu != nil { withAnimation { menu = nil }; focused = true } else { close() }
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
            epgNow = l.first { ($0.start ?? .distantFuture) <= Date() && ($0.end ?? .distantPast) > Date() } ?? l.first
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
            VStack(alignment: .trailing, spacing: 4) {
                Text(engine.kind == .live ? "▲ ▼  Sender wechseln" : "◀ ▶  10 s spulen  ·  ▶❙❙  Pause")
                Text("OK  Ton · Untertitel · Bild · Schlaf-Timer")
                if let s = engine.sleepAt { Text("Schlaf-Timer: \(max(1, Int(s.timeIntervalSinceNow / 60))) Min").foregroundColor(UI.gold) }
                if engine.usingVLC { Text("VLC").foregroundColor(UI.gold2) }
            }
            .font(UI.font(19)).foregroundColor(UI.muted)
            Image(systemName: engine.playing ? "pause.fill" : "play.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(UI.dark)
                .frame(width: 62, height: 62)
                .background(Circle().fill(UI.gold))
        }
        .padding(.horizontal, 24)
        .frame(width: 1620, height: 142)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(rgb: 0x0c0c0e, opacity: 0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(UI.tan(0.5), lineWidth: 1.5))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
    }

    // MARK: Menü (Ton, Untertitel, Bildformat, Schlaf-Timer)

    private func menuPanel(_ m: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(menuTitle(m)).font(UI.font(30, .bold)).foregroundColor(UI.gold).padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch m {
                    case "audio", "text":
                        let l = engine.tracks(m == "audio")
                        if l.isEmpty { Text("Keine weiteren Spuren").font(UI.font(24)).foregroundColor(UI.muted) }
                        ForEach(l) { t in
                            row(t.name, t.selected) { engine.select(m == "audio", t.id); close(menu: true) }
                        }
                    case "format":
                        row("Ganzes Bild", engine.gravity == "fit") { engine.setGravity("fit"); close(menu: true) }
                        row("Zoomen (füllen)", engine.gravity == "fill") { engine.setGravity("fill"); close(menu: true) }
                        row("Strecken", engine.gravity == "stretch") { engine.setGravity("stretch"); close(menu: true) }
                    case "sleep":
                        ForEach([0, 15, 30, 60, 90, 120], id: \.self) { mins in
                            row(mins == 0 ? "Aus" : "\(mins) Minuten", mins == 0 ? engine.sleepAt == nil : false) {
                                engine.sleepAt = mins == 0 ? nil : Date().addingTimeInterval(Double(mins) * 60)
                                if mins > 0 { engine.notice("Schlaf-Timer: \(mins) Minuten") }
                                close(menu: true)
                            }
                        }
                    default:
                        row("🔊  Tonspur", false) { menu = "audio" }
                        row("💬  Untertitel", false) { menu = "text" }
                        row("🖼  Bildformat", false) { menu = "format" }
                        row("🌙  Schlaf-Timer" + (engine.sleepAt != nil ? " (an)" : ""), false) { menu = "sleep" }
                        if engine.kind == .live {
                            row("🔁  Ersatzsender suchen", false) { close(menu: true); if !engine.tryAlt() { engine.notice("Kein Ersatzsender gefunden") } }
                        }
                    }
                }
                .padding(6)
            }
        }
        .padding(36)
        .frame(width: 620, height: 640, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(rgb: 0x121114, opacity: 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(UI.tan(0.5), lineWidth: 1.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 60)
    }

    private func menuTitle(_ m: String) -> String {
        switch m { case "audio": return "Tonspur"; case "text": return "Untertitel"; case "format": return "Bildformat"
        case "sleep": return "Schlaf-Timer"; default: return "Optionen" }
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

    private func openMenu() {
        hideTask?.cancel()
        withAnimation { menu = "main" }
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
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { withAnimation { osd = false } }
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
