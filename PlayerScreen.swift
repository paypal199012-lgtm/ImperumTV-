import SwiftUI
import UIKit
import AVKit

// MARK: - Wiedergabe

final class PlayerModel: NSObject, ObservableObject {
    let player = AVPlayer()
    @Published var isPiPPossible = false
    @Published var isPiPActive = false
    @Published var errorMessage: String?
    @Published var isPlaying = true
    @Published var isBuffering = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var currentURL: URL?
    private var currentUserAgent = "IPTVPlayer/3.0"
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObserver: NSKeyValueObservation?

    override init() {
        super.init()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            } else {
                self.duration = 0
            }
            self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            self.isPlaying = self.player.timeControlStatus != .paused
        }
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
    }

    func play(_ url: URL, userAgent: String) {
        currentURL = url
        currentUserAgent = userAgent
        errorMessage = nil
        isBuffering = true
        currentTime = 0
        duration = 0

        // Ton auch bei stummgeschaltetem iPhone abspielen
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        )
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                let reason = item.error?.localizedDescription ?? ""
                DispatchQueue.main.async {
                    self?.errorMessage = "Wiedergabe fehlgeschlagen. \(reason)"
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    /// Bild-in-Bild vorbereiten, sobald das Videobild existiert
    func attach(layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        // Startet automatisch, wenn man beim Schauen nach Hause wischt
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
        pipPossibleObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.isPiPPossible = c.isPictureInPicturePossible }
        }
    }

    func togglePiP() {
        guard let controller = pipController else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        currentTime = seconds
    }

    func skip(_ delta: Double) {
        let target = currentTime + delta
        seek(to: duration > 0 ? min(target, duration - 1) : target)
    }

    func retry() {
        if let url = currentURL { play(url, userAgent: currentUserAgent) }
    }

    func stop() {
        pipController?.stopPictureInPicture()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObserver = nil
    }
}

extension PlayerModel: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isPiPActive = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isPiPActive = false }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

/// Reines Videobild ohne eingebaute Steuerung
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var onReady: (AVPlayerLayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        onReady(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
    }
}

// MARK: - Player-Bildschirm

struct PlayerScreen: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()

    let channels: [Channel]
    let isLive: Bool
    @State private var index: Int
    @State private var nowTitle: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?

    init(channels: [Channel], startIndex: Int, isLive: Bool = false) {
        self.channels = channels
        self.isLive = isLive
        _index = State(initialValue: startIndex)
    }

    private var channel: Channel { channels[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: model.player) { layer in
                model.attach(layer: layer)
            }
            .ignoresSafeArea()

            // Tippen aufs Bild blendet die Bedienelemente ein oder aus
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if model.isBuffering && model.errorMessage == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
                    .allowsHitTesting(false)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if let message = model.errorMessage {
                VStack(spacing: 12) {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    Button("Erneut versuchen") { model.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.gold)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.7)))
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.play(channel.url, userAgent: store.userAgentValue)
            scheduleHide()
        }
        .onChange(of: index) { _ in
            model.play(channel.url, userAgent: store.userAgentValue)
            showControls()
        }
        .task(id: index) {
            nowTitle = nil
            if isLive && store.isXtream {
                nowTitle = await store.shortEPG(streamId: channel.id).first?.title
            }
        }
        .onDisappear {
            hideTask?.cancel()
            model.stop()
        }
    }

    // MARK: Bedienelemente

    private var controls: some View {
        ZStack {
            // Abdunkelung oben und unten, damit Text lesbar bleibt
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
                if let nowTitle = nowTitle {
                    Text("Jetzt: \(nowTitle)")
                        .font(.caption)
                        .foregroundStyle(Theme.goldLight)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.isPiPPossible {
                Button {
                    model.togglePiP()
                } label: {
                    Image(systemName: model.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
            }
            Button {
                store.toggleFavorite(channel)
                scheduleHide()
            } label: {
                Image(systemName: store.isFavorite(channel) ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(store.isFavorite(channel) ? Theme.gold : Color.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 28) {
            if channels.count > 1 {
                roundButton("backward.end.fill", size: 50) { step(-1) }
            }
            if !isLive && model.duration > 0 {
                roundButton("gobackward.10", size: 50) { model.skip(-10) }
            }
            roundButton(model.isPlaying ? "pause.fill" : "play.fill", size: 70) {
                model.togglePlay()
            }
            if !isLive && model.duration > 0 {
                roundButton("goforward.10", size: 50) { model.skip(10) }
            }
            if channels.count > 1 {
                roundButton("forward.end.fill", size: 50) { step(1) }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isLive || model.duration <= 0 {
            HStack {
                if isLive {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("LIVE").font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                }
                Spacer()
                if channels.count > 1 {
                    Text("\(index + 1) / \(channels.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        } else {
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubValue ?? model.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            hideTask?.cancel()
                        } else {
                            if let value = scrubValue { model.seek(to: value) }
                            scrubValue = nil
                            scheduleHide()
                        }
                    }
                )
                .tint(Theme.gold)

                HStack {
                    Text(timeString(scrubValue ?? model.currentTime))
                    Spacer()
                    Text("-" + timeString(max(model.duration - (scrubValue ?? model.currentTime), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func roundButton(_ systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }

    // MARK: Logik

    private func step(_ delta: Int) {
        index = (index + delta + channels.count) % channels.count
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        scheduleHide()
    }

    /// Blendet die Bedienelemente nach 4 Sekunden automatisch aus (nicht bei Pause)
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, model.isPlaying, scrubValue == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
