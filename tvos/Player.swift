import SwiftUI
import AVFoundation
import UIKit

/// Ein Player für Vorschau und Vollbild (wie auf Android läuft der Sender beim Wechsel ins Vollbild einfach weiter)
@MainActor
final class PlayerEngine: ObservableObject {
    let player = AVPlayer()

    @Published var item: TVItem?
    @Published var kind: MediaKind = .live
    @Published var title = ""
    @Published var buffering = false
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?

    /// Liste, durch die im Vollbild geschaltet wird (Sender der Kategorie bzw. Folgen der Staffel)
    var items: [TVItem] = []
    var episodes: [Episode] = []
    var index = 0
    var art: Art = .none

    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    private var tcObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.position = max(0, t.seconds.isFinite ? t.seconds : 0)
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d } else { self.duration = 0 }
            }
        }
        tcObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.playing = p.timeControlStatus == .playing
            }
        }
    }

    func play(_ url: URL, item: TVItem, kind: MediaKind, title: String? = nil, art: Art? = nil) {
        error = nil
        self.item = item
        self.kind = kind
        self.title = title ?? item.name
        self.art = art ?? item.art
        position = 0; duration = 0
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": TVStore.userAgent]])
        let pi = AVPlayerItem(asset: asset)
        pi.preferredForwardBufferDuration = kind == .live ? 4 : 0
        statusObs = pi.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if it.status == .failed {
                    self.error = "Sender ließ sich nicht abspielen" + (it.error.map { " (\($0.localizedDescription))" } ?? "")
                }
            }
        }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        player.replaceCurrentItem(with: pi)
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func ended() {
        // Serie: nächste Folge, Live: neu verbinden
        if kind == .series, index + 1 < episodes.count { playEpisode(index + 1); return }
        if kind == .live, let it = item, let u = (player.currentItem?.asset as? AVURLAsset)?.url {
            play(u, item: it, kind: .live)
        }
    }

    func playEpisode(_ i: Int) {
        guard i >= 0, i < episodes.count, let it = item else { return }
        index = i
        let e = episodes[i]
        play(e.url, item: it, kind: .series, title: "\(it.name) · S\(e.season) F\(e.number) · \(e.title)", art: it.art)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        playing = false
        buffering = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func toggle() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func seek(by s: Double) {
        guard duration > 0 else { return }
        let t = min(max(0, position + s), duration - 1)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        position = t
    }
}

/// Videobild (AVPlayerLayer)
struct VideoView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

// MARK: - Vollbild mit Leiste unten (wie Android)

struct PlayerScreen: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: TVStore
    @State private var osd = true
    @State private var hideTask: Task<Void, Never>?
    @State private var epgNow: EPGEntry?
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: { showOSD() }) {
            ZStack {
                Color.black
                VideoView(player: engine.player)
                if engine.buffering {
                    ProgressView().scaleEffect(2).tint(UI.gold)
                }
                if let e = engine.error {
                    Text(e).font(UI.font(30, .bold)).foregroundColor(UI.gold)
                        .padding(30).background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.8)))
                }
                if osd { bar.transition(.opacity) }
            }
            .frame(width: 1920, height: 1080)
        }
        .buttonStyle(PlainPress())
        .focused($focused)
        .onAppear { focused = true; showOSD() }
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
        .onExitCommand { close() }
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
            Text(engine.kind == .live ? "▲ ▼  Sender wechseln" : "◀ ▶  10 s spulen\n▶❙❙  Pause")
                .font(UI.font(21)).foregroundColor(UI.muted).multilineTextAlignment(.trailing)
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
        if engine.kind != .live { engine.stop() }
        nav.pop()
    }
}

/// Knopf ohne sichtbaren Fokus (ganzer Bildschirm im Vollbild)
struct PlainPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
