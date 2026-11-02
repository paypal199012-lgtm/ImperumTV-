import SwiftUI
import UIKit
import WebKit
import AVFoundation
import MobileVLCKit

// =====================================================================
// ImperumTV fürs iPhone mit derselben Oberfläche wie Android/Fire TV:
// Die Oberfläche (app.js, style.css) läuft in einer WKWebView, darunter liegt der Player (AVPlayer oder VLC).
// Die Oberfläche spricht über window.AndroidBridge mit der App – hier nachgebaut (siehe bridgeScript).
// =====================================================================

struct WebRootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebAppController { WebAppController() }
    func updateUIViewController(_ vc: WebAppController, context: Context) {}
}

/// Hält die WebView nicht fest (sonst gibt es nie frei)
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

final class WebAppController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let playerHost = UIView()
    private var web: WKWebView!
    private let scheme = AppScheme()
    private lazy var player = NativePlayer(host: playerHost)
    private var stateTimer: Timer?
    private var lastState = ""

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerHost.backgroundColor = .black
        playerHost.isUserInteractionEnabled = false
        playerHost.isHidden = true
        view.addSubview(playerHost)

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: AppScheme.name)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = cfg.userContentController
        ucc.add(WeakHandler(self), name: "ab")
        ucc.addUserScript(WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))

        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        web.uiDelegate = self
        web.customUserAgent = "ImperumTV/1.0 (iPhone; iOS " + UIDevice.current.systemVersion + ")"
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view.addSubview(web)

        player.emit = { [weak self] name, value in self?.emit(name, value) }
        web.load(URLRequest(url: URL(string: AppScheme.name + "://app/index.html")!))

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pushState() }
        #if DEBUG
        // Simulator-Test: nach 15 s den Zustand ins Protokoll und ein Foto der Oberfläche in „Dokumente“
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.debugSnapshot() }
        #endif

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(toBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(toForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        web.frame = view.bounds
        player.relayout(in: view.bounds)
    }

    private func debugSnapshot() {
        NSLog("[ImperumTV-Web] Ansicht: view=%@ web=%@ hidden=%d alpha=%f", "\(view.bounds)", "\(web.frame)", web.isHidden ? 1 : 0, web.alpha)
        web.evaluateJavaScript("[document.body.className, (document.getElementById('app')||{}).innerHTML ? document.getElementById('app').innerHTML.length : -1, getComputedStyle(document.body).backgroundColor, (document.getElementById('stage')||{}).style ? document.getElementById('stage').style.transform : '', (document.getElementById('loader')||{}).className, document.title].join(' | ')") { r, e in
            NSLog("[ImperumTV-Web] Zustand: %@ %@", "\(r ?? "")", "\(e?.localizedDescription ?? "")")
        }
        web.takeSnapshot(with: nil) { img, err in
            if let d = img?.pngData(), let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? d.write(to: dir.appendingPathComponent("web.png"))
                NSLog("[ImperumTV-Web] Foto gespeichert %d Bytes", d.count)
            } else { NSLog("[ImperumTV-Web] Foto fehlgeschlagen %@", err?.localizedDescription ?? "") }
        }
    }

    @objc private func toBackground() { js("window.__androidLifecycle && window.__androidLifecycle('hidden')") }
    @objc private func toForeground() { js("window.__androidLifecycle && window.__androidLifecycle('visible')") }

    // ---------- Oberfläche ↔ App ----------

    private func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

    private func emit(_ name: String, _ value: Any?) {
        var v = "null"
        if let b = value as? Bool { v = b ? "true" : "false" }
        else if let d = value as? Double { v = String(d) }
        else if let i = value as? Int { v = String(i) }
        else if let s = value as? String { v = Self.jsString(s) }
        js("window.__androidPlayerEvent && window.__androidPlayerEvent('\(name)', \(v))")
    }

    static func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let t = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }

    /// Werte, die die Oberfläche jederzeit sofort abfragen darf (isPlaying, Position, Spuren …)
    private func pushState() {
        let s = player.state()
        guard let d = try? JSONSerialization.data(withJSONObject: s), let t = String(data: d, encoding: .utf8), t != lastState else { return }
        lastState = t
        js("window.__abSet && window.__abSet(\(t))")
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let m = body["m"] as? String else { return }
        let a = body["a"] as? [Any] ?? []
        func d(_ i: Int) -> Double { (a.count > i ? (a[i] as? NSNumber)?.doubleValue : nil) ?? 0 }
        func s(_ i: Int) -> String { a.count > i ? "\(a[i])" : "" }
        switch m {
        case "open": player.open(s(0), CGRect(x: d(1), y: d(2), width: d(3), height: d(4)), in: view.bounds)
        case "setRect": player.place(CGRect(x: d(0), y: d(1), width: d(2), height: d(3)), in: view.bounds)
        case "stop": player.stop()
        case "toggle": player.toggle()
        case "setResize": player.setResize(s(0))
        case "seekTo": player.seekTo(d(0))
        case "seekBy": player.seekBy(d(0))
        case "selectTrack": player.selectTrack(s(0), Int(d(1)))
        case "setAudioLangs": player.audioLangs = s(0).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        case "setBuffer": UserDefaults.standard.set(s(0), forKey: "web.buffer")
        case "setLiveEngine": UserDefaults.standard.set(s(0) == "vlc" ? "vlc" : "exo", forKey: "web.liveEngine")
        case "setNextEngine": player.forceVLCNext = s(0) == "vlc"
        case "keepAwake": UIApplication.shared.isIdleTimerDisabled = (a.first as? Bool) ?? true
        case "openUrl": if let u = URL(string: s(0)) { UIApplication.shared.open(u) }
        case "log": NSLog("[ImperumTV-Web] %@", s(0))
        default: break
        }
        pushState()
    }

    // Links mit target=_blank: im Browser öffnen
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { UIApplication.shared.open(u) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = navigationAction.request.url else { decisionHandler(.allow); return }
        if u.scheme == AppScheme.name || u.scheme == "about" || u.scheme == "blob" || u.scheme == "data" { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame == true { UIApplication.shared.open(u); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("location.href + ' | body=' + document.body.innerHTML.length + ' | app=' + (document.getElementById('app') ? document.getElementById('app').innerHTML.length : -1) + ' | w=' + innerWidth + 'x' + innerHeight") { r, e in
            NSLog("[ImperumTV-Web] geladen: %@ %@", "\(r ?? "")", "\(e?.localizedDescription ?? "")")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[ImperumTV-Web] didFail: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[ImperumTV-Web] didFailProvisional: %@", error.localizedDescription)
    }

    // Bricht der Web-Prozess ab (zu wenig Speicher): neu laden
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        player.stop()
        webView.reload()
    }

    // ---------- window.AndroidBridge für die Oberfläche ----------

    private func bridgeScript() -> String {
        let ids = DeviceIdentity.load()
        let ver = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let device = UIDevice.current.model + " · iOS " + UIDevice.current.systemVersion
        let buffer = UserDefaults.standard.string(forKey: "web.buffer") ?? "normal"
        let engine = UserDefaults.standard.string(forKey: "web.liveEngine") ?? "exo"
        return """
        (function () {
          var S = window.__abState = { playing: false, pos: 0, dur: 0, kbps: 0, audio: '[]', text: '[]',
            version: \(ver), device: \(Self.jsString(device)), mk: \(Self.jsString(ids.mac + "|" + ids.key)),
            buffer: \(Self.jsString(buffer)), engine: \(Self.jsString(engine)) };
          function post(m, a) { try { window.webkit.messageHandlers.ab.postMessage({ m: m, a: a || [] }); } catch (e) {} }
          // Programmfehler der Oberfläche ins Protokoll der App (zum Prüfen im Simulator)
          window.addEventListener('error', function (e) { post('log', ['JS-Fehler: ' + e.message + ' @ ' + (e.filename || '') + ':' + e.lineno]); });
          var oe = console.error; console.error = function () { post('log', ['console.error: ' + Array.prototype.join.call(arguments, ' ')]); try { oe.apply(console, arguments); } catch (x) {} };
          function P(m) { return function () { post(m, Array.prototype.slice.call(arguments)); }; }
          window.__abSet = function (o) { for (var k in o) S[k] = o[k]; };
          function list(kind) { try { return JSON.parse(kind === 'text' ? S.text : S.audio) || []; } catch (e) { return []; } }
          window.AndroidBridge = {
            open: function (u, x, y, w, h) { S.playing = true; S.pos = 0; S.dur = 0; S.audio = '[]'; S.text = '[]'; post('open', [u, x, y, w, h]); },
            setRect: P('setRect'),
            stop: function () { S.playing = false; post('stop'); },
            toggle: function () { S.playing = !S.playing; post('toggle'); },
            isPlaying: function () { return !!S.playing; },
            position: function () { return S.pos || 0; },
            duration: function () { return S.dur || 0; },
            setResize: P('setResize'), seekTo: P('seekTo'), seekBy: P('seekBy'),
            tracks: function (kind) { return kind === 'text' ? S.text : S.audio; },
            selectTrack: function (kind, i) { post('selectTrack', [kind, i]); return true; },
            nextAudio: function () {
              var l = list('audio'), cur = 0, i;
              if (!l.length) return '';
              if (l.length === 1) return '=' + l[0].name;
              for (i = 0; i < l.length; i++) if (l[i].selected) cur = i;
              var n = (cur + 1) % l.length; post('selectTrack', ['audio', n]); return l[n].name;
            },
            nextSubtitle: function () {
              var l = list('text'), cur = -1, i;
              if (!l.length) return '';
              for (i = 0; i < l.length; i++) if (l[i].selected) cur = i;
              var n = cur + 1;
              if (n >= l.length) { post('selectTrack', ['text', -1]); return 'Aus'; }
              post('selectTrack', ['text', n]); return l[n].name;
            },
            setAudioLangs: P('setAudioLangs'),
            applyPrefs: function () {},
            appVersion: function () { return S.version; },
            deviceName: function () { return S.device; },
            deviceMacKey: function () { return S.mk; },
            netInfo: function () { return '{"kbps":' + (S.kbps || 0) + '}'; },
            getBuffer: function () { return S.buffer; },
            setBuffer: function (m) { S.buffer = m; post('setBuffer', [m]); },
            hasVlc: function () { return true; },
            getLiveEngine: function () { return S.engine; },
            setLiveEngine: function (m) { S.engine = m === 'vlc' ? 'vlc' : 'exo'; post('setLiveEngine', [S.engine]); },
            setNextEngine: P('setNextEngine'),
            keepAwake: P('keepAwake'),
            openUrl: P('openUrl')
          };
          // Anfragen an fremde Server (Anbieter, Fußball, Bilder-Listen) über die App: dort gibt es keine CORS-Sperre
          var of = window.fetch;
          window.fetch = function (input, init) {
            var u = typeof input === 'string' ? input : (input && input.url) || '';
            var m = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
            if (/^https?:/i.test(u) && m === 'GET' && !/supabase\\.co/i.test(u)) {
              return of.call(window, '\(AppScheme.name)://net/?u=' + encodeURIComponent(u), init && init.signal ? { signal: init.signal } : undefined);
            }
            return of.apply(window, arguments);
          };
        })();
        """
    }
}

// =====================================================================
// Eigenes Adress-Schema: imptv://app/… liefert die Oberfläche aus dem App-Paket,
// imptv://net/?u=… holt Daten von fremden Servern (ohne CORS-Sperre im Browser)
// =====================================================================

final class AppScheme: NSObject, WKURLSchemeHandler {
    static let name = "imptv"
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.httpAdditionalHeaders = ["User-Agent": "ImperumTV/1.0 (iPhone)"]
        return URLSession(configuration: c)
    }()

    private func isStopped(_ t: WKURLSchemeTask) -> Bool { lock.lock(); defer { lock.unlock() }; return stopped.contains(ObjectIdentifier(t)) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if url.host == "net" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value ?? ""
            guard let target = URL(string: q) else { task.didFailWithError(URLError(.badURL)); return }
            var req = URLRequest(url: target)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            session.dataTask(with: req) { [weak self] data, resp, err in
                DispatchQueue.main.async {
                    guard let self = self, !self.isStopped(task) else { return }
                    if let err = err { task.didFailWithError(err); return }
                    let http = resp as? HTTPURLResponse
                    var headers = ["Content-Type": http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                                   "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
                    if let len = data?.count { headers["Content-Length"] = String(len) }
                    let r = HTTPURLResponse(url: url, statusCode: http?.statusCode ?? 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                    task.didReceive(r)
                    task.didReceive(data ?? Data())
                    task.didFinish()
                }
            }.resume()
            return
        }
        // Dateien der Oberfläche aus dem App-Paket (Ordner „www“)
        NSLog("[ImperumTV-Web] Datei: %@", url.path)
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("www"),
              let data = try? Data(contentsOf: base.appendingPathComponent(String(path.dropFirst()))) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(r); task.didReceive(Data()); task.didFinish()
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                     "png": "image/png", "jpg": "image/jpeg", "webp": "image/webp", "svg": "image/svg+xml", "json": "application/json"]
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": types[ext] ?? "application/octet-stream", "Content-Length": String(data.count)])!
        task.didReceive(r)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(task)); lock.unlock()
    }
}

// =====================================================================
// Player unter der Oberfläche: AVPlayer (HLS, MP4) oder VLC (TS, MKV, AVI …)
// =====================================================================

final class AVLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class NativePlayer {
    private let host: UIView
    private let avView = AVLayerView()
    private let vlcView = UIView()
    private let av = AVPlayer()
    private lazy var vlc = VLCMediaPlayer()
    var emit: ((String, Any?) -> Void)?
    var forceVLCNext = false
    var audioLangs: [String] = []

    private var useVLC = false
    private var active = false
    private var isLive = false
    private var original: URL?
    private var triedVLC = false
    private var readySent = false
    private var buffering = false
    private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var gravity = "fit"
    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var vlcTimer: Timer?
    private var langPicked = false
    private let ua = "ImperumTV/1.0 (iPhone)"

    init(host: UIView) {
        self.host = host
        avView.frame = host.bounds; avView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vlcView.frame = host.bounds; vlcView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        avView.backgroundColor = .black; vlcView.backgroundColor = .black
        avView.isUserInteractionEnabled = false; vlcView.isUserInteractionEnabled = false
        host.addSubview(avView); host.addSubview(vlcView)
        avView.playerLayer.player = av
        avView.playerLayer.videoGravity = .resizeAspect
        av.automaticallyWaitsToMinimizeStalling = true
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self = self, (n.object as? AVPlayerItem) === self.av.currentItem, self.active, !self.useVLC else { return }
            self.emit?("end", nil)
        }
    }

    private var bufferMode: String { UserDefaults.standard.string(forKey: "web.buffer") ?? "normal" }
    private var liveEngine: String { UserDefaults.standard.string(forKey: "web.liveEngine") ?? "exo" }

    // ---------- Fläche ----------

    func place(_ r: CGRect, in bounds: CGRect) {
        rect = r
        relayout(in: bounds)
        host.isHidden = !active
    }

    func relayout(in bounds: CGRect) {
        host.frame = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                            width: max(1, rect.width * bounds.width), height: max(1, rect.height * bounds.height))
    }

    // ---------- Abspielen ----------

    func open(_ s: String, _ r: CGRect, in bounds: CGRect) {
        stop()
        guard let url = URL(string: s) else { emit?("error", "Ungültige Adresse"); return }
        active = true
        original = url
        isLive = s.contains("/live/")
        readySent = false; buffering = false; triedVLC = false; langPicked = false
        place(r, in: bounds)
        let ext = url.pathExtension.lowercased()
        let wantVLC = forceVLCNext || (isLive && liveEngine == "vlc") || (!isLive && ["mkv", "avi", "wmv", "flv", "ts", "divx", "webm"].contains(ext))
        forceVLCNext = false
        if wantVLC { playVLC(url) } else { playAV(isLive && ext == "ts" ? Self.asHLS(url) : url) }
    }

    /// Live-Sender: der iPhone-Player kann HLS (.m3u8), aber keinen direkten TS-Strom
    private static func asHLS(_ url: URL) -> URL {
        URL(string: url.absoluteString.replacingOccurrences(of: #"\.ts$"#, with: ".m3u8", options: .regularExpression)) ?? url
    }

    private func setBuffering(_ b: Bool) {
        guard b != buffering else { return }
        buffering = b
        emit?("buffer", b)
    }

    private func sendReady() {
        setBuffering(false)
        if !readySent { readySent = true; emit?("ready", nil) }
    }

    private func playAV(_ url: URL) {
        useVLC = false
        avView.isHidden = false; vlcView.isHidden = true
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = bufferMode == "small" ? 1 : bufferMode == "large" ? 8 : 3
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self = self, self.active, !self.useVLC else { return }
                if it.status == .readyToPlay { self.sendReady(); self.pickLanguage() }
                else if it.status == .failed { self.avFailed(it.error?.localizedDescription ?? "Wiedergabe fehlgeschlagen") }
            }
        }
        tcsObs = av.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self, self.active, !self.useVLC else { return }
                if p.timeControlStatus == .waitingToPlayAtSpecifiedRate { self.setBuffering(true) }
                else if p.timeControlStatus == .playing { self.sendReady() }
            }
        }
        if timeObs == nil {
            timeObs = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
                guard let self = self, self.active, !self.useVLC, self.av.timeControlStatus == .playing else { return }
                self.emit?("time", t.seconds)
            }
        }
        av.replaceCurrentItem(with: item)
        av.play()
        setBuffering(true)
    }

    /// Der iPhone-Player kann es nicht: einmal still mit VLC versuchen (VLC kann mehr Formate)
    private func avFailed(_ msg: String) {
        if !triedVLC, let u = original {
            triedVLC = true
            playVLC(u)
            emit?("notice", "Sender läuft jetzt mit VLC")
            return
        }
        emit?("error", "AV: " + msg)
    }

    private func playVLC(_ url: URL) {
        useVLC = true
        triedVLC = true
        av.pause(); av.replaceCurrentItem(with: nil)
        avView.isHidden = true; vlcView.isHidden = false
        let media = VLCMedia(url: url)
        media.addOption(":http-user-agent=\(ua)")
        media.addOption(":network-caching=" + (bufferMode == "small" ? "1000" : bufferMode == "large" ? "5000" : "2500"))
        vlc.drawable = vlcView
        vlc.media = media
        applyGravity()
        vlc.play()
        setBuffering(true)
        vlcTimer?.invalidate()
        vlcTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollVLC() }
    }

    private func pollVLC() {
        guard active, useVLC else { return }
        switch vlc.state {
        case .playing: sendReady(); emit?("time", Double(vlc.time.intValue) / 1000); pickLanguage()
        case .buffering, .opening: if !readySent { setBuffering(true) }
        case .error: active = false; emit?("error", "VLC: Wiedergabe fehlgeschlagen")
        case .ended, .stopped: if readySent { active = false; emit?(isLive ? "error" : "end", isLive ? "VLC: Verbindung abgebrochen" : nil) }
        default: break
        }
    }

    func stop() {
        active = false
        vlcTimer?.invalidate(); vlcTimer = nil
        statusObs = nil; tcsObs = nil
        av.pause(); av.replaceCurrentItem(with: nil)
        if useVLC { vlc.stop() }
        host.isHidden = true
    }

    func toggle() {
        if useVLC { if vlc.isPlaying { vlc.pause() } else { vlc.play() } }
        else { if av.timeControlStatus == .paused { av.play() } else { av.pause() } }
    }

    func setResize(_ mode: String) { gravity = mode; applyGravity() }

    private func applyGravity() {
        avView.playerLayer.videoGravity = gravity == "zoom" ? .resizeAspectFill : gravity == "fill" ? .resize : .resizeAspect
        if useVLC {
            let w = Int(max(1, host.bounds.width)), h = Int(max(1, host.bounds.height))
            vlc.videoAspectRatio = nil
            vlc.videoCropGeometry = nil
            if gravity == "fill" { vlc.videoAspectRatio = strdup("\(w):\(h)") }
            else if gravity == "zoom" { vlc.videoCropGeometry = strdup("\(w):\(h)") }
        }
    }

    func seekTo(_ sec: Double) {
        if useVLC { vlc.time = VLCTime(int: Int32(max(0, sec) * 1000)) }
        else { av.seek(to: CMTime(seconds: max(0, sec), preferredTimescale: 600)) }
    }

    func seekBy(_ sec: Double) {
        if useVLC { if sec >= 0 { vlc.jumpForward(Int32(sec)) } else { vlc.jumpBackward(Int32(-sec)) } }
        else { seekTo(av.currentTime().seconds + sec) }
    }

    // ---------- Ton und Untertitel ----------

    private struct Track { let name: String; let selected: Bool }

    private func tracks(_ kind: String) -> [Track] {
        if useVLC {
            let names = kind == "text" ? vlc.videoSubTitlesNames : vlc.audioTrackNames
            let idx = kind == "text" ? vlc.videoSubTitlesIndexes : vlc.audioTrackIndexes
            let cur = kind == "text" ? vlc.currentVideoSubTitleIndex : vlc.currentAudioTrackIndex
            var out: [Track] = []
            for (n, i) in zip(names, idx) {
                guard let v = (i as? NSNumber)?.int32Value, v >= 0 else { continue }
                out.append(Track(name: (n as? String) ?? "Spur \(v)", selected: v == cur))
            }
            return out
        }
        guard let item = av.currentItem,
              let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: kind == "text" ? .legible : .audible) else { return [] }
        let sel = item.currentMediaSelection.selectedMediaOption(in: g)
        return g.options.map { Track(name: $0.displayName, selected: $0 == sel) }
    }

    func selectTrack(_ kind: String, _ index: Int) {
        if useVLC {
            let idx = kind == "text" ? vlc.videoSubTitlesIndexes : vlc.audioTrackIndexes
            let valid = idx.compactMap { ($0 as? NSNumber)?.int32Value }.filter { $0 >= 0 }
            if kind == "text" { vlc.currentVideoSubTitleIndex = index >= 0 && index < valid.count ? valid[index] : -1 }
            else if index >= 0 && index < valid.count { vlc.currentAudioTrackIndex = valid[index] }
            return
        }
        guard let item = av.currentItem,
              let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: kind == "text" ? .legible : .audible) else { return }
        if index < 0 || index >= g.options.count { if kind == "text" { item.select(nil, in: g) }; return }
        item.select(g.options[index], in: g)
    }

    /// Filme/Serien: einmal Deutsch, sonst Englisch nehmen (wie auf Android)
    private func pickLanguage() {
        guard !langPicked, !audioLangs.isEmpty else { return }
        let list = tracks("audio")
        guard list.count > 1 else { if !list.isEmpty { langPicked = true }; return }
        langPicked = true
        for want in audioLangs {
            let keys = want == "de" ? ["deutsch", "german", "ger", "deu", "de"] : want == "en" ? ["englisch", "english", "eng", "en"] : [want]
            if let i = list.firstIndex(where: { t in keys.contains(where: { t.name.lowercased().contains($0) }) }) {
                if !list[i].selected { selectTrack("audio", i) }
                return
            }
        }
    }

    // ---------- Zustand für die Oberfläche ----------

    func state() -> [String: Any] {
        func json(_ l: [Track]) -> String {
            let arr = l.enumerated().map { ["i": $0.offset, "name": $0.element.name, "detail": "", "selected": $0.element.selected] as [String: Any] }
            guard let d = try? JSONSerialization.data(withJSONObject: arr), let s = String(data: d, encoding: .utf8) else { return "[]" }
            return s
        }
        var pos = 0.0, dur = 0.0, kbps = 0, playing = false
        if active {
            if useVLC {
                pos = Double(max(0, vlc.time.intValue)) / 1000
                if !isLive, let l = vlc.media?.length.intValue, l > 0 { dur = Double(l) / 1000 }
                playing = vlc.isPlaying || buffering
            } else {
                pos = max(0, av.currentTime().seconds.isFinite ? av.currentTime().seconds : 0)
                if !isLive, let d = av.currentItem?.duration.seconds, d.isFinite, d > 0 { dur = d }
                playing = av.timeControlStatus != .paused
                if let e = av.currentItem?.accessLog()?.events.last, e.observedBitrate > 0 { kbps = Int(e.observedBitrate / 1000) }
            }
        }
        return ["playing": playing, "pos": (pos * 10).rounded() / 10, "dur": dur.rounded(), "kbps": kbps,
                "audio": json(tracks("audio")), "text": json(tracks("text"))]
    }
}
