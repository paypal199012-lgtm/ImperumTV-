import SwiftUI
import UIKit
import AVKit
import MobileVLCKit

// MARK: - Wiedergabe

/// Eine Tonspur oder ein Untertitel zur Auswahl
struct TrackOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Spielt mit dem iPhone-Player (AVPlayer) ab und wechselt bei Formaten,
/// die das iPhone nicht kann (z. B. MKV, AVI), automatisch auf VLC.
final class PlayerModel: NSObject, ObservableObject {
    let player = AVPlayer()
    private(set) lazy var vlcPlayer = VLCMediaPlayer()

    @Published var usesVLC = false
    @Published var isPiPPossible = false
    @Published var isPiPActive = false
    @Published var errorMessage: String?
    @Published var isPlaying = true
    @Published var isBuffering = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var audioTracks: [TrackOption] = []
    @Published var subtitleTracks: [TrackOption] = []
    @Published var selectedAudio: String?
    @Published var selectedSubtitle: String?

    private var avAudioGroup: AVMediaSelectionGroup?
    private var avSubtitleGroup: AVMediaSelectionGroup?
    private var avOptions: [String: AVMediaSelectionOption] = [:]
    private var audioPrefApplied = false
    private var subPrefApplied = false

    private var wantsMuted = false

    // Erkennung von hängenden Streams (Standbild)
    private var lastProgressValue: Double = -1
    private var lastProgressDate = Date()
    private var stallRetries = 0

    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var vlcTimer: Timer?
    private var currentURL: URL?
    private var currentUserAgent = "IPTVPlayer/3.0"
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObserver: NSKeyValueObservation?

    /// Formate, die der iPhone-Player sicher kann
    private static let nativeExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "ts", ""]

    override init() {
        super.init()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.usesVLC else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            } else {
                self.duration = 0
            }
            self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            self.isPlaying = self.player.timeControlStatus != .paused
            self.checkForStall()
        }
    }

    /// Ton aus- oder einschalten (für die Multi-Ansicht)
    func setMuted(_ muted: Bool) {
        wantsMuted = muted
        applyMute()
    }

    private func applyMute() {
        player.isMuted = wantsMuted
        if usesVLC, let audio = vlcPlayer.audio as VLCAudio? {
            if audio.isMuted != wantsMuted { audio.isMuted = wantsMuted }
        }
    }

    /// Läuft die Zeit trotz Wiedergabe 10 Sekunden nicht weiter, wird neu geladen
    private func checkForStall() {
        guard currentURL != nil, errorMessage == nil else { return }
        let active = usesVLC ? vlcPlayer.state != .paused && vlcPlayer.state != .stopped && vlcPlayer.state != .ended
                             : player.timeControlStatus != .paused
        guard active else {
            lastProgressDate = Date()
            return
        }
        if abs(currentTime - lastProgressValue) > 0.2 {
            lastProgressValue = currentTime
            lastProgressDate = Date()
        } else if Date().timeIntervalSince(lastProgressDate) > 10 {
            handleStall()
        }
    }

    private func handleStall() {
        guard let url = currentURL else { return }
        stallRetries += 1
        lastProgressValue = -1
        lastProgressDate = Date()

        if usesVLC {
            if stallRetries <= 3 {
                // VLC neu starten
                let resume = currentTime
                vlcPlayer.stop()
                playVLC(Self.vlcURL(for: url), userAgent: currentUserAgent)
                if resume > 5 && duration > 0 { seek(to: resume) }
            } else {
                errorMessage = "Der Sender reagiert nicht. Versuche es gleich noch einmal oder wähle einen anderen Sender."
            }
        } else if stallRetries == 1 {
            // Erst den iPhone-Player neu laden …
            playNative(url, userAgent: currentUserAgent)
        } else {
            // … dann auf VLC wechseln
            playVLC(Self.vlcURL(for: url), userAgent: currentUserAgent)
        }
    }

    /// Für Live-Sender ist bei VLC der direkte .ts-Stream meist stabiler als .m3u8
    private static func vlcURL(for url: URL) -> URL {
        let s = url.absoluteString
        guard s.contains("/live/"), url.pathExtension.lowercased() == "m3u8" else { return url }
        return URL(string: String(s.dropLast(4)) + "ts") ?? url
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        vlcTimer?.invalidate()
    }

    func play(_ url: URL, userAgent: String) {
        currentURL = url
        currentUserAgent = userAgent
        errorMessage = nil
        isBuffering = true
        isPlaying = true
        currentTime = 0
        duration = 0
        stallRetries = 0
        lastProgressValue = -1
        lastProgressDate = Date()

        // Ton auch bei stummgeschaltetem iPhone abspielen
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let ext = url.pathExtension.lowercased()
        let isLiveStream = url.absoluteString.contains("/live/")
        let liveWithVLC = UserDefaults.standard.bool(forKey: "liveWithVLC")
        if isLiveStream && liveWithVLC {
            playVLC(Self.vlcURL(for: url), userAgent: userAgent)
        } else if Self.nativeExtensions.contains(ext) {
            playNative(url, userAgent: userAgent)
        } else {
            playVLC(url, userAgent: userAgent)
        }
    }

    private func playNative(_ url: URL, userAgent: String) {
        stopVLC()
        usesVLC = false
        resetTracks()

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay {
                self?.loadAVTracks(for: item)
                return
            }
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                // Kann das iPhone das Format nicht, übernimmt VLC
                guard let self = self, let url = self.currentURL else { return }
                self.playVLC(Self.vlcURL(for: url), userAgent: self.currentUserAgent)
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func playVLC(_ url: URL, userAgent: String) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObserver = nil
        usesVLC = true
        isPiPPossible = false
        errorMessage = nil
        isBuffering = true
        resetTracks()

        let media = VLCMedia(url: url)
        media.addOption(":http-user-agent=\(userAgent)")
        media.addOption(":network-caching=1500")
        vlcPlayer.media = media
        vlcPlayer.play()

        vlcTimer?.invalidate()
        vlcTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollVLC()
        }
    }

    private func pollVLC() {
        let p = vlcPlayer
        let ms = p.time.intValue
        currentTime = Double(ms) / 1000
        if let length = p.media?.length.intValue, length > 0 {
            duration = Double(length) / 1000
        } else {
            duration = 0
        }

        switch p.state {
        case .error:
            isBuffering = false
            errorMessage = "Wiedergabe fehlgeschlagen. Der Server liefert die Datei nicht oder das Format wird nicht unterstützt."
        case .paused, .stopped, .ended:
            isBuffering = false
            isPlaying = false
        case .opening, .buffering:
            isBuffering = ms == 0
            isPlaying = true
        default:
            isBuffering = false
            isPlaying = true
        }

        if ms > 0 { refreshVLCTracks() }
        applyMute()
        checkForStall()
    }

    // MARK: Tonspuren und Untertitel

    private func resetTracks() {
        audioTracks = []
        subtitleTracks = []
        selectedAudio = nil
        selectedSubtitle = nil
        avAudioGroup = nil
        avSubtitleGroup = nil
        avOptions = [:]
        audioPrefApplied = false
        subPrefApplied = false
    }

    /// Liest die Ton- und Untertitelspuren beim iPhone-Player
    private func loadAVTracks(for item: AVPlayerItem) {
        Task { [weak self] in
            let asset = item.asset
            let audio = (try? await asset.loadMediaSelectionGroup(for: .audible)) ?? nil
            let legible = (try? await asset.loadMediaSelectionGroup(for: .legible)) ?? nil
            await MainActor.run {
                guard let self = self, self.player.currentItem === item else { return }
                self.applyAVGroups(item: item, audio: audio, legible: legible)
            }
        }
    }

    private func applyAVGroups(item: AVPlayerItem, audio: AVMediaSelectionGroup?, legible: AVMediaSelectionGroup?) {
        avAudioGroup = audio
        avSubtitleGroup = legible
        avOptions = [:]

        var audioList: [TrackOption] = []
        if let group = audio {
            for (i, option) in group.options.enumerated() {
                let id = "a\(i)"
                avOptions[id] = option
                audioList.append(TrackOption(id: id, name: Self.trackName(option, index: i)))
            }
            if let current = item.currentMediaSelection.selectedMediaOption(in: group) {
                selectedAudio = avOptions.first(where: { $0.value == current })?.key
            }
        }

        var subList = [TrackOption(id: "off", name: "Aus")]
        selectedSubtitle = "off"
        if let group = legible {
            for (i, option) in group.options.enumerated() {
                let id = "s\(i)"
                avOptions[id] = option
                subList.append(TrackOption(id: id, name: Self.trackName(option, index: i)))
            }
            if let current = item.currentMediaSelection.selectedMediaOption(in: group),
               let key = avOptions.first(where: { $0.value == current })?.key {
                selectedSubtitle = key
            }
        }

        audioTracks = audioList
        subtitleTracks = subList
        applyPreferencesIfNeeded()
    }

    private static func trackName(_ option: AVMediaSelectionOption, index: Int) -> String {
        var name = option.displayName
        if name.isEmpty {
            name = option.locale.flatMap { Locale.current.localizedString(forIdentifier: $0.identifier) } ?? "Spur \(index + 1)"
        }
        if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
            name += " (nur Einblendungen)"
        }
        return name
    }

    /// Liest die Ton- und Untertitelspuren beim VLC-Player
    private func refreshVLCTracks() {
        var audioList: [TrackOption] = []
        for (name, index) in zip(vlcPlayer.audioTrackNames, vlcPlayer.audioTrackIndexes) {
            guard let idx = (index as? NSNumber)?.int32Value, idx >= 0 else { continue }
            audioList.append(TrackOption(id: String(idx), name: (name as? String) ?? "Spur \(idx)"))
        }

        var subList = [TrackOption(id: "-1", name: "Aus")]
        for (name, index) in zip(vlcPlayer.videoSubTitlesNames, vlcPlayer.videoSubTitlesIndexes) {
            guard let idx = (index as? NSNumber)?.int32Value, idx >= 0 else { continue }
            subList.append(TrackOption(id: String(idx), name: (name as? String) ?? "Untertitel \(idx)"))
        }

        if audioList != audioTracks { audioTracks = audioList }
        if subList != subtitleTracks { subtitleTracks = subList }

        let currentAudio = String(vlcPlayer.currentAudioTrackIndex)
        if selectedAudio != currentAudio { selectedAudio = currentAudio }
        let currentSub = String(vlcPlayer.currentVideoSubTitleIndex)
        if selectedSubtitle != currentSub { selectedSubtitle = currentSub }

        applyPreferencesIfNeeded()
    }

    func selectAudio(_ id: String, remember: Bool = true) {
        if usesVLC {
            if let idx = Int32(id) { vlcPlayer.currentAudioTrackIndex = idx }
        } else if let group = avAudioGroup, let option = avOptions[id] {
            player.currentItem?.select(option, in: group)
        }
        selectedAudio = id
        if remember, let name = audioTracks.first(where: { $0.id == id })?.name {
            UserDefaults.standard.set(name, forKey: "prefAudio")
        }
    }

    func selectSubtitle(_ id: String, remember: Bool = true) {
        if usesVLC {
            vlcPlayer.currentVideoSubTitleIndex = Int32(id) ?? -1
        } else if let group = avSubtitleGroup {
            player.currentItem?.select(id == "off" ? nil : avOptions[id], in: group)
        }
        selectedSubtitle = id
        if remember, let name = subtitleTracks.first(where: { $0.id == id })?.name {
            UserDefaults.standard.set(name, forKey: "prefSubtitle")
        }
    }

    /// Nimmt automatisch die zuletzt gewählte Sprache (z. B. Deutsch), wenn vorhanden
    private func applyPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        if !audioPrefApplied, !audioTracks.isEmpty {
            audioPrefApplied = true
            if let pref = defaults.string(forKey: "prefAudio"),
               let track = Self.match(pref, in: audioTracks),
               track.id != selectedAudio {
                selectAudio(track.id, remember: false)
            }
        }
        if !subPrefApplied, subtitleTracks.count > 1 {
            subPrefApplied = true
            if let pref = defaults.string(forKey: "prefSubtitle") {
                let target = pref == "Aus" ? subtitleTracks.first : Self.match(pref, in: Array(subtitleTracks.dropFirst()))
                if let track = target, track.id != selectedSubtitle {
                    selectSubtitle(track.id, remember: false)
                }
            }
        }
    }

    private static func match(_ name: String, in tracks: [TrackOption]) -> TrackOption? {
        let wanted = name.lowercased()
        if let exact = tracks.first(where: { $0.name.lowercased() == wanted }) { return exact }
        return tracks.first { track in
            let n = track.name.lowercased()
            return n.contains(wanted) || wanted.contains(n)
        }
    }

    private func stopVLC() {
        vlcTimer?.invalidate()
        vlcTimer = nil
        if usesVLC { vlcPlayer.stop() }
    }

    /// Bild-in-Bild vorbereiten, sobald das Videobild existiert (nur iPhone-Player)
    func attach(layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        // Startet automatisch, wenn man beim Schauen nach Hause wischt
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
        pipPossibleObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPiPPossible = c.isPictureInPicturePossible && !self.usesVLC
            }
        }
    }

    func togglePiP() {
        guard let controller = pipController, !usesVLC else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func togglePlay() {
        if usesVLC {
            if vlcPlayer.isPlaying {
                vlcPlayer.pause()
                isPlaying = false
            } else {
                vlcPlayer.play()
                isPlaying = true
            }
            return
        }
        if player.timeControlStatus == .paused {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        if usesVLC {
            vlcPlayer.time = VLCTime(int: Int32(target * 1000))
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
        currentTime = target
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
        stopVLC()
    }
}

/// Videobild für den VLC-Player
struct VLCVideoView: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // Berührungen an SwiftUI weiterreichen (Tippen blendet Steuerung ein/aus)
        view.isUserInteractionEnabled = false
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
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
        view.isUserInteractionEnabled = false
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
    @State private var showTracks = false

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
            .opacity(model.usesVLC ? 0 : 1)

            if model.usesVLC {
                VLCVideoView(player: model.vlcPlayer)
                    .ignoresSafeArea()
            }

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
        .sheet(isPresented: $showTracks, onDismiss: { scheduleHide() }) {
            TrackSheet(model: model)
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
            Button {
                hideTask?.cancel()
                showTracks = true
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
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

// MARK: - Auswahl von Sprache und Untertiteln

struct TrackSheet: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.audioTracks.isEmpty {
                        Text("Keine weiteren Sprachen verfügbar")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.audioTracks) { track in
                        row(track.name, selected: track.id == model.selectedAudio) {
                            model.selectAudio(track.id)
                        }
                    }
                } header: {
                    Label("Sprache (Tonspur)", systemImage: "speaker.wave.2")
                }

                Section {
                    if model.subtitleTracks.count <= 1 {
                        Text("Keine Untertitel verfügbar")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.subtitleTracks) { track in
                            row(track.name, selected: track.id == model.selectedSubtitle) {
                                model.selectSubtitle(track.id)
                            }
                        }
                    }
                } header: {
                    Label("Untertitel (CC)", systemImage: "captions.bubble")
                } footer: {
                    Text("Deine Auswahl wird gemerkt und beim nächsten Sender oder Film automatisch genommen, wenn es sie dort gibt.")
                }
            }
            .navigationTitle("Sprache und Untertitel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Theme.gold)
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.gold)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
    }
}
