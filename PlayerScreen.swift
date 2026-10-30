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
    /// Zählt hoch, wenn ein Film/eine Folge zu Ende ist
    @Published var endedCount = 0
    /// Bildformat: fit = ganzes Bild, zoom = Bildschirm füllen, fill = strecken,
    /// "16:9", "4:3", "21:9" = Bild in genau diesem Seitenverhältnis
    @Published var aspect: String = "fit"
    static let aspectModes = ["fit", "zoom", "fill", "16:9", "4:3", "21:9"]

    /// Für welchen Sender/Film/welche Serie das Bildformat gilt (z. B. "live:123")
    var aspectKey: String? {
        didSet {
            guard aspectKey != oldValue else { return }
            aspect = Self.savedAspects()[aspectKey ?? ""] ?? "fit"
        }
    }

    /// Bildformat wählen und nur für den aktuellen Sender/Film/die Serie merken
    func setAspect(_ mode: String) {
        aspect = mode
        guard let key = aspectKey else { return }
        var all = Self.savedAspects()
        all[key] = mode == "fit" ? nil : mode
        UserDefaults.standard.set(all, forKey: "aspects")
    }

    private static func savedAspects() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: "aspects") as? [String: String]) ?? [:]
    }

    /// Seitenverhältnis bei festen Formaten (16:9, 4:3, 21:9), sonst nil
    var aspectRatio: CGFloat? {
        switch aspect {
        case "16:9": return 16.0 / 9.0
        case "4:3": return 4.0 / 3.0
        case "21:9": return 21.0 / 9.0
        default: return nil
        }
    }
    /// Bildgröße bei VLC (für das Bildformat)
    @Published var vlcVideoSize: CGSize = .zero

    var gravity: AVLayerVideoGravity {
        switch aspect {
        case "zoom": return .resizeAspectFill
        case "fill", "16:9", "4:3", "21:9": return .resize
        default: return .resizeAspect
        }
    }

    /// Stelle, zu der nach dem Laden gesprungen wird (Weiterschauen, Player-Wechsel)
    private var pendingSeek: Double?
    private var endObserver: NSObjectProtocol?
    private var vlcEndSent = false
    var isSeekPending: Bool { pendingSeek != nil }

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
    /// Was gerade läuft (für die Übergabe Vorschau → Vollbild)
    var playingURL: URL? { currentURL }
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
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        vlcTimer?.invalidate()
    }

    func play(_ url: URL, userAgent: String, startAt: Double = 0) {
        pendingSeek = startAt > 5 ? startAt : nil
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
        let vodWithVLC = UserDefaults.standard.bool(forKey: "vodWithVLC")
        if isLiveStream && liveWithVLC {
            playVLC(Self.vlcURL(for: url), userAgent: userAgent)
        } else if !isLiveStream && vodWithVLC {
            playVLC(url, userAgent: userAgent)
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
                DispatchQueue.main.async { self?.applyPendingSeekNative() }
                return
            }
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                // Kann das iPhone das Format nicht, übernimmt VLC
                guard let self = self, let url = self.currentURL else { return }
                self.playVLC(Self.vlcURL(for: url), userAgent: self.currentUserAgent)
            }
        }
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.endedCount += 1
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func applyPendingSeekNative() {
        guard !usesVLC, let target = pendingSeek else { return }
        pendingSeek = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
    }

    /// Mitten im Film zwischen iPhone-Player und VLC wechseln, an derselben Stelle
    func switchEngine(toVLC: Bool) {
        guard let url = currentURL, toVLC != usesVLC else { return }
        let pos = currentTime
        pendingSeek = pos > 5 ? pos : nil
        stallRetries = 0
        lastProgressValue = -1
        lastProgressDate = Date()
        errorMessage = nil
        if toVLC {
            playVLC(Self.vlcURL(for: url), userAgent: currentUserAgent)
        } else {
            playNative(url, userAgent: currentUserAgent)
        }
    }

    /// Aktuelle Stream-Adresse (für andere Apps)
    var streamURL: URL? { currentURL }

    private func playVLC(_ url: URL, userAgent: String) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObserver = nil
        usesVLC = true
        isPiPPossible = false
        errorMessage = nil
        isBuffering = true
        resetTracks()
        vlcEndSent = false

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

        let size = p.videoSize
        if size != vlcVideoSize { vlcVideoSize = size }
        if ms > 0, let target = pendingSeek {
            pendingSeek = nil
            p.time = VLCTime(int: Int32(target * 1000))
            currentTime = target
        }
        if p.state == .ended && !vlcEndSent {
            vlcEndSent = true
            endedCount += 1
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
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // Neuer großer Player (z. B. nach „Zurück zur App“): PiP auf dieses Bild umstellen
        if let controller = pipController {
            if controller.playerLayer !== layer {
                controller.contentSource = AVPictureInPictureController.ContentSource(playerLayer: layer)
            }
            return
        }
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
        currentURL = nil
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
        DispatchQueue.main.async {
            self.isPiPActive = false
            PiPCenter.shared.ended(self)
        }
    }

    /// „Zurück zur App“ im kleinen Fenster: Player wieder groß öffnen
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            PiPCenter.shared.requestRestore(for: self, completion: completionHandler)
        }
    }
}

/// Reines Videobild ohne eingebaute Steuerung
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onReady: (AVPlayerLayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        onReady(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }
}

// MARK: - Player-Bildschirm

struct PlayerScreen: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model: PlayerModel
    /// Player kommt aus der Live-Vorschau: weiterlaufen lassen, nicht neu laden
    private let handedOff: Bool
    /// Beim Schließen anhalten, obwohl der Player übergeben wurde (nach „Zurück zur App“ aus PiP)
    private let stopOnClose: Bool

    let channels: [Channel]
    let isLive: Bool
    /// Angaben fürs Weiterschauen (gleiche Reihenfolge wie channels)
    let resume: [ResumeInfo]?
    @State private var index: Int
    @State private var startAt: Double?
    /// Programm des Senders (jetzt und danach)
    @State private var epg: [EPGEntry] = []
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?
    @State private var showTracks = false
    @State private var showEngines = false
    @State private var showAspect = false
    @State private var lastSave = Date.distantPast
    @State private var hint: String?
    @State private var hintTask: Task<Void, Never>?
    // Serien: „Intro überspringen“ und Countdown zur nächsten Folge
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("introBtn") private var introBtn = true
    @State private var introDoneIndex: Int?
    @State private var nextCancelledIndex: Int?
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    /// Sekunden, die „Intro überspringen“ weiterspringt
    private static let introSeconds: Double = 20

    init(channels: [Channel], startIndex: Int, isLive: Bool = false, resume: [ResumeInfo]? = nil, startAt: Double? = nil,
         handoff: PlayerModel? = nil, stopOnClose: Bool = false) {
        _model = StateObject(wrappedValue: handoff ?? PlayerModel())
        handedOff = handoff != nil
        self.stopOnClose = stopOnClose
        self.channels = channels
        self.isLive = isLive
        self.resume = (resume?.count == channels.count) ? resume : nil
        _index = State(initialValue: startIndex)
        _startAt = State(initialValue: startAt)
    }

    private var channel: Channel { channels[index] }

    private var currentInfo: ResumeInfo? {
        guard !isLive, let list = resume, index < list.count else { return nil }
        return list[index]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Videobild: bei 16:9, 4:3 und 21:9 in einem Rahmen mit genau diesem Seitenverhältnis
            GeometryReader { geo in
                let box = videoBox(geo.size)
                ZStack {
                    PlayerLayerView(player: model.player, gravity: model.gravity) { layer in
                        model.attach(layer: layer)
                    }
                    .frame(width: box.width, height: box.height)
                    .opacity(model.usesVLC ? 0 : 1)

                    if model.usesVLC {
                        let scale = vlcScale(box)
                        VLCVideoView(player: model.vlcPlayer)
                            .frame(width: box.width, height: box.height)
                            .scaleEffect(x: scale.width, y: scale.height)
                            .frame(width: box.width, height: box.height)
                            .clipped()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .ignoresSafeArea()

            // Tippen aufs Bild blendet die Bedienelemente ein oder aus;
            // bei Live TV wechselt Wischen nach oben/unten den Sender
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 40).onEnded { value in
                        guard isLive, channels.count > 1,
                              abs(value.translation.height) > abs(value.translation.width) * 1.5,
                              abs(value.translation.height) > 60 else { return }
                        step(value.translation.height < 0 ? 1 : -1)
                    }
                )

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
        .overlay(alignment: .bottomTrailing) {
            episodeExtras
                .padding(.trailing, 24)
                .padding(.bottom, controlsVisible ? 150 : 28)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        }
        .overlay(alignment: .top) {
            if let hint = hint {
                Text(hint)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(.top, 60)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showTracks, onDismiss: { scheduleHide() }) {
            TrackSheet(model: model)
        }
        .confirmationDialog("Bildformat", isPresented: $showAspect, titleVisibility: .visible) {
            ForEach(PlayerModel.aspectModes, id: \.self) { mode in
                Button(model.aspect == mode ? Self.aspectName(mode) + " ✓" : Self.aspectName(mode)) {
                    model.setAspect(mode)
                    showHint("Bildformat \(aspectScope): \(Self.aspectName(mode))")
                    scheduleHide()
                }
            }
            Button("Abbrechen", role: .cancel) { scheduleHide() }
        } message: {
            Text("Gilt nur \(aspectScope). Andere bleiben unverändert.")
        }
        .confirmationDialog("Player wählen", isPresented: $showEngines, titleVisibility: .visible) {
            Button(model.usesVLC ? "iPhone-Player" : "iPhone-Player ✓") {
                model.switchEngine(toVLC: false)
                scheduleHide()
            }
            Button(model.usesVLC ? "VLC (in der App) ✓" : "VLC (in der App)") {
                model.switchEngine(toVLC: true)
                scheduleHide()
            }
            Button("In der VLC-App öffnen") { openExternal("vlc") }
            Button("In Infuse öffnen") { openExternal("infuse") }
            Button("Abbrechen", role: .cancel) { scheduleHide() }
        } message: {
            Text("VLC spielt fast jedes Format (MKV, AVI …). Der iPhone-Player kann Bild-in-Bild. Die Stelle bleibt beim Wechsel erhalten.")
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.aspectKey = aspectKey
            PiPCenter.shared.willOpen(model)       // anderes kleines Fenster beenden
            PiPCenter.shared.finishRestore()       // aus PiP zurückgeholt: kleines Fenster fliegt hinein
            // Aus der Vorschau: das Bild wird nur größer, kein neues Laden
            if handedOff && model.playingURL == channel.url && model.errorMessage == nil {
                scheduleHide()
                return
            }
            let start = firstStart()
            model.play(channel.url, userAgent: store.userAgentValue, startAt: start)
            if start > 5 { showHint("Weiter ab \(timeText(start))") }
            scheduleHide()
        }
        .onChange(of: index) { _ in
            model.aspectKey = aspectKey
            stopCountdown()
            let start = savedStart()
            model.play(channel.url, userAgent: store.userAgentValue, startAt: start)
            if start > 5 { showHint("Weiter ab \(timeText(start))") }
            showControls()
        }
        .onReceive(model.$currentTime) { t in
            if Date().timeIntervalSince(lastSave) > 10 { saveProgress() }
            if nextDue(at: t) {
                if countdown == nil { startCountdown() }
            } else if countdown != nil {
                stopCountdown()
            }
        }
        .onChange(of: model.isPiPActive) { active in
            // Bild-in-Bild gestartet: großen Player schließen, kleines Fenster läuft weiter
            guard active else { return }
            saveProgress()
            PiPCenter.shared.started(.init(model: model, channels: channels, index: index, isLive: isLive, resume: resume))
            dismiss()
        }
        .onChange(of: model.errorMessage) { message in
            // Wiedergabefehler an den Admin melden (Website → Fehlerberichte)
            if let message = message {
                CrashReport.player(name: channel.name, url: channel.url, message: message)
            }
        }
        .onChange(of: model.endedCount) { _ in
            stopCountdown()
            if isEpisode && hasNext && autoNext && nextCancelledIndex != index {
                goNext()
            } else {
                saveProgress(ended: true)
                if !isLive && currentInfo != nil { dismiss() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveProgress()
        }
        .task(id: index) {
            epg = []
            if isLive && store.isXtream {
                epg = await store.shortEPG(streamId: channel.id)
            }
        }
        .onDisappear {
            saveProgress()
            countdownTask?.cancel()
            hideTask?.cancel()
            hintTask?.cancel()
            // Übergebener Player läuft in der kleinen Vorschau weiter
            if model.isPiPActive {
                // Läuft im kleinen Fenster weiter
            } else if !handedOff || stopOnClose {
                model.stop()
            }
            model.aspectKey = nil          // Vorschau zeigt wieder das ganze Bild
        }
    }

    // MARK: Bedienelemente (Info-Banner wie auf dem Fernseher)

    private var controls: some View {
        ZStack {
            // Leichte Abdunkelung oben für den Zurück-Knopf
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !isLive { centerButtons }
                Spacer()
                banner
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
            .accessibilityLabel("Zurück")
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
                .accessibilityLabel("Bild in Bild")
            }
        }
    }

    /// Filme und Serien: Pause und 10 Sekunden springen in der Mitte (bei Live keine Pause)
    private var centerButtons: some View {
        HStack(spacing: 28) {
            if model.duration > 0 {
                roundButton("gobackward.10", size: 50) { model.skip(-10) }
            }
            roundButton(model.isPlaying ? "pause.fill" : "play.fill", size: 70) {
                model.togglePlay()
            }
            if model.duration > 0 {
                roundButton("goforward.10", size: 50) { model.skip(10) }
            }
        }
    }

    /// Schmales Banner unten: Logo, Sendung jetzt/danach mit Fortschritt, runde Knöpfe
    private var banner: some View {
        HStack(alignment: .center, spacing: 14) {
            bannerLogo
            bannerInfo
                .frame(maxWidth: .infinity, alignment: .leading)
            bannerButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.gold.opacity(0.5), lineWidth: 1))
    }

    private var bannerLogo: some View {
        let url = isLive ? channel.logo : (currentInfo?.seriesCover ?? channel.logo)
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
            if let url = url {
                PosterImage(url: url, maxPixel: 200, fit: isLive, icon: isLive ? "tv" : "film")
                    .padding(isLive ? 4 : 0)
            } else {
                Text(isLive ? "\(index + 1)" : "▶")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.goldLight)
            }
        }
        .frame(width: isLive ? 72 : 38, height: isLive ? 46 : 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var bannerInfo: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                liveInfo(now: context.date)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
                if let info = currentInfo, info.kind == .episode {
                    Text("\(info.seriesName ?? "") · Staffel \(info.season ?? 1) · Folge \(info.number ?? index + 1)")
                        .font(.caption)
                        .foregroundStyle(Theme.goldLight)
                        .lineLimit(1)
                }
                if model.duration > 0 {
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
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    private func liveInfo(now: Date) -> some View {
        let current = epg.first { ($0.start ?? .distantPast) <= now && ($0.end ?? .distantFuture) > now }
        let next = epg.first { ($0.start ?? .distantPast) > now }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.red))
                Text("\(index + 1) · \(channel.name)")
                    .font(.headline)
                    .lineLimit(1)
            }
            if let cur = current {
                Text("Jetzt: \(cur.title)" + timeRange(cur))
                    .font(.caption)
                    .foregroundStyle(Theme.goldLight)
                    .lineLimit(1)
                if let s = cur.start, let e = cur.end, e > s {
                    ProgressView(value: min(max(now.timeIntervalSince(s) / e.timeIntervalSince(s), 0), 1))
                        .tint(Theme.gold)
                }
            }
            if let nxt = next {
                Text("Danach: \(nxt.title)" + (nxt.start.map { "  ab " + clock($0) } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            } else {
                Text("Kanal \(index + 1) / \(channels.count)" + (channels.count > 1 ? "  ·  nach oben/unten wischen wechselt den Sender" : ""))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
    }

    private var bannerButtons: some View {
        HStack(spacing: 8) {
            if isLive {
                if channels.count > 1 {
                    bannerButton("chevron.left", "Kanal zurück") { step(-1) }
                    bannerButton("chevron.right", "Kanal vor") { step(1) }
                }
            } else if isEpisode && hasNext {
                bannerButton("forward.end.fill", "Nächste Folge") { goNext() }
            }
            bannerButton("arrow.triangle.2.circlepath", "Player wechseln", keepOpen: true) { showEngines = true }
            bannerButton("aspectratio", "Bildformat", keepOpen: true) { showAspect = true }
            // Filme/Serien: immer; Live: nur wenn der Sender eine Auswahl hat
            if !isLive || model.audioTracks.count > 1 {
                bannerButton("speaker.wave.2", "Sprache", keepOpen: true) { showTracks = true }
            }
            if !isLive || model.subtitleTracks.count > 1 {
                bannerButton("captions.bubble", "Untertitel", keepOpen: true) { showTracks = true }
            }
            if !isEpisode {
                let fav = store.isFavorite(channel)
                bannerButton(fav ? "star.fill" : "star", "Favorit", tint: fav ? Theme.gold : .white) {
                    store.toggleFavorite(channel)
                }
            }
        }
    }

    private func bannerButton(_ icon: String, _ label: String, tint: Color = .white, keepOpen: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button {
            if keepOpen { hideTask?.cancel() }
            action()
            if !keepOpen { scheduleHide() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.white.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func clock(_ date: Date) -> String { Self.clockFormatter.string(from: date) }

    private func timeRange(_ entry: EPGEntry) -> String {
        guard let s = entry.start, let e = entry.end else { return "" }
        return "   \(clock(s)) – \(clock(e))"
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

    // MARK: Serien: Intro überspringen / nächste Folge

    private var isEpisode: Bool { currentInfo?.kind == .episode }
    private var hasNext: Bool { index < channels.count - 1 }

    private var showIntroButton: Bool {
        guard isEpisode, introBtn, introDoneIndex != index, countdown == nil, !model.isSeekPending else { return false }
        let t = model.currentTime
        return t >= 2 && t < 10          // nur 8 Sekunden lang
    }

    private func nextDue(at t: Double) -> Bool {
        guard isEpisode, hasNext, autoNext, nextCancelledIndex != index, !model.isSeekPending else { return false }
        let d = model.duration
        return d > 300 && d - t <= 30 && d - t > 1
    }

    @ViewBuilder
    private var episodeExtras: some View {
        if let c = countdown, hasNext {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nächste Folge in \(c) s")
                    .font(.headline)
                    .foregroundStyle(Theme.goldLight)
                Text(nextTitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                ProgressView(value: Double(10 - c), total: 10)
                    .tint(Theme.gold)
                HStack(spacing: 10) {
                    Button {
                        cancelNext()
                    } label: {
                        Text("Abbrechen")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                    Button {
                        goNext()
                    } label: {
                        Label("Jetzt ansehen", systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.gold))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(width: 290, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.82)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gold.opacity(0.6)))
        } else if showIntroButton {
            Button {
                skipIntro()
            } label: {
                Label("Intro überspringen", systemImage: "forward.end.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.gold))
                    .shadow(color: .black.opacity(0.5), radius: 6)
            }
            .buttonStyle(.plain)
        }
    }

    private var nextTitle: String {
        guard hasNext else { return "" }
        let name = channels[index + 1].name
        if let list = resume, index + 1 < list.count, let s = list[index + 1].season, let n = list[index + 1].number {
            return "S\(s) F\(n) · \(name)"
        }
        return name
    }

    private func startCountdown() {
        countdown = 10
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let c = countdown else { return }
                if !model.isPlaying { continue }          // Pause hält den Countdown an
                if c <= 1 {
                    goNext()
                    return
                }
                countdown = c - 1
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func goNext() {
        guard hasNext else { return }
        stopCountdown()
        saveProgress(ended: true)
        showHint("Nächste Folge: \(nextTitle)")
        index += 1
    }

    private func cancelNext() {
        nextCancelledIndex = index
        stopCountdown()
        showHint("Automatische Wiedergabe abgebrochen")
    }

    private func skipIntro() {
        introDoneIndex = index
        model.skip(Self.introSeconds)
        showHint("Intro übersprungen (+\(Int(Self.introSeconds)) s)")
    }

    // MARK: Logik

    private func step(_ delta: Int) {
        saveProgress()
        index = (index + delta + channels.count) % channels.count
    }

    static func aspectName(_ mode: String) -> String {
        switch mode {
        case "zoom": return "Bildschirm füllen (Zoom)"
        case "fill": return "Vollbild (strecken)"
        case "16:9": return "16:9"
        case "4:3": return "4:3"
        case "21:9": return "21:9 (Kino)"
        default: return "Original (ganzes Bild)"
        }
    }

    /// Wofür das Bildformat gilt
    private var aspectScope: String {
        isLive ? "für diesen Sender" : (isEpisode ? "für diese Serie" : "für diesen Film")
    }

    /// Schlüssel, unter dem das Bildformat gespeichert wird
    private var aspectKey: String {
        if isLive { return "live:\(channel.id)" }
        if let info = currentInfo, info.kind == .episode, let sid = info.seriesId { return "series:\(sid)" }
        return "movie:\(channel.id)"
    }

    /// Fläche fürs Videobild: ganzer Bildschirm oder ein Rahmen in 16:9, 4:3 bzw. 21:9
    private func videoBox(_ view: CGSize) -> CGSize {
        guard let r = model.aspectRatio, view.width > 0, view.height > 0 else { return view }
        if view.width / view.height > r {
            return CGSize(width: view.height * r, height: view.height)
        }
        return CGSize(width: view.width, height: view.width / r)
    }

    /// Bei VLC das Bild für „Zoom“ bzw. „Strecken“ vergrößern (VLC zeigt sonst immer das ganze Bild)
    private func vlcScale(_ view: CGSize) -> CGSize {
        let video = model.vlcVideoSize
        guard video.width > 0, video.height > 0, view.width > 0, view.height > 0 else { return CGSize(width: 1, height: 1) }
        let fit = min(view.width / video.width, view.height / video.height)
        let fittedW = video.width * fit, fittedH = video.height * fit
        switch model.aspect {
        case "zoom":
            let s = max(view.width / fittedW, view.height / fittedH)
            return CGSize(width: s, height: s)
        case "fill", "16:9", "4:3", "21:9":
            return CGSize(width: view.width / fittedW, height: view.height / fittedH)
        default:
            return CGSize(width: 1, height: 1)
        }
    }

    // MARK: Weiterschauen

    /// Startpunkt beim Öffnen: übergebener Wert, sonst gespeicherter Stand
    private func firstStart() -> Double {
        if let s = startAt {
            startAt = nil
            return s
        }
        return savedStart()
    }

    private func savedStart() -> Double {
        guard let info = currentInfo else { return 0 }
        return store.resumePosition(for: info)
    }

    private func saveProgress(ended: Bool = false) {
        lastSave = Date()
        guard let info = currentInfo else { return }
        if !ended && model.isSeekPending { return }
        var next: (info: ResumeInfo, channel: Channel)?
        if info.kind == .episode, let list = resume, index + 1 < channels.count {
            next = (list[index + 1], channels[index + 1])
        }
        store.recordProgress(info: info, channel: channel, next: next,
                             pos: model.currentTime, dur: model.duration, ended: ended)
    }

    private func showHint(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            hint = nil
        }
    }

    /// Film in VLC oder Infuse öffnen (wenn installiert)
    private func openExternal(_ app: String) {
        guard let stream = model.streamURL,
              let encoded = stream.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        let link = app == "vlc"
            ? "vlc-x-callback://x-callback-url/stream?url=\(encoded)"
            : "infuse://x-callback-url/play?url=\(encoded)"
        guard let url = URL(string: link) else { return }
        saveProgress()
        openURL(url) { accepted in
            if accepted {
                model.stop()
                dismiss()
            } else {
                showHint(app == "vlc" ? "Die VLC-App ist nicht installiert (gratis im App Store)." : "Infuse ist nicht installiert.")
                scheduleHide()
            }
        }
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
        let total = Int(max(0, seconds))
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
