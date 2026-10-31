import SwiftUI
import UIKit
import ImageIO

// MARK: - Start-Abgleich: Live TV, Filme, Serien

enum SyncPhase: Equatable {
    case waiting, loading, done, failed
}

struct SyncItem: Equatable {
    var phase: SyncPhase = .waiting
    var count = 0
    var fresh = 0
}

struct SyncInfo: Equatable {
    var title: String
    var live = SyncItem()
    var movies = SyncItem()
    var series = SyncItem()
    var finished = false
    var message: String?
}

/// Ganzer Bildschirm mit drei Karten, wird beim Start und beim Aktualisieren gezeigt
struct SyncView: View {
    @EnvironmentObject private var store: AppStore
    let info: SyncInfo

    var body: some View {
        ZStack {
            GoldBackground(dim: 0.55)

            VStack(spacing: 18) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 46)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 3)

                Text(info.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 14) {
                    SyncCard(title: "Live TV", icon: "tv", item: info.live, unit: "Sender")
                    SyncCard(title: "Filme", icon: "film", item: info.movies, unit: "Filme")
                    SyncCard(title: "Serien", icon: "play.rectangle.on.rectangle", item: info.series, unit: "Serien")
                }
                .frame(maxWidth: 620)

                footer
                    .frame(height: 22)
            }
            .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.skipSync() }
    }

    @ViewBuilder
    private var footer: some View {
        if let message = info.message {
            Text(message + " · Tippen zum Schließen")
                .font(.footnote)
                .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.55))
                .multilineTextAlignment(.center)
        } else if info.finished {
            Label("Alles aktuell", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.goldLight)
        } else if info.live.phase == .done {
            Text("Tippen zum Überspringen – lädt im Hintergrund weiter")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            Text("Wird aktualisiert …")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct SyncCard: View {
    let title: String
    let icon: String
    let item: SyncItem
    let unit: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 54, height: 54)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.gold)
            }
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            status
                .frame(height: 22)

            if item.fresh > 0 {
                Text("+\(item.fresh.formatted()) neu")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.goldLight))
            } else {
                Color.clear.frame(height: 18)
            }

            bar
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.3), value: item)
    }

    @ViewBuilder
    private var status: some View {
        switch item.phase {
        case .waiting:
            Text("Wartet …").font(.caption).foregroundStyle(.white.opacity(0.5))
        case .loading:
            ProgressView().tint(Theme.goldLight)
        case .done:
            CountUpText(value: item.count, unit: unit)
        case .failed:
            Text("Nicht verfügbar").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Laufender Balken während des Ladens, voll wenn fertig
    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if item.phase == .loading {
                    RunningBar(width: geo.size.width)
                } else if item.phase == .done {
                    Capsule().fill(Theme.gold)
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }

    private var borderColor: Color {
        switch item.phase {
        case .done: return Theme.gold.opacity(0.8)
        case .loading: return Theme.goldLight.opacity(0.45)
        case .failed: return Color.red.opacity(0.4)
        case .waiting: return Color.white.opacity(0.15)
        }
    }
}

/// Kurzer Lichtstreifen, der von links nach rechts läuft
private struct RunningBar: View {
    let width: CGFloat
    @State private var moved = false

    var body: some View {
        Capsule()
            .fill(Theme.goldLight)
            .frame(width: width * 0.35)
            .offset(x: moved ? width : -width * 0.35)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { moved = true }
            }
    }
}

/// Zahl zählt in ca. 0,6 Sekunden hoch (wenige Schritte, damit nichts hakt)
private struct CountUpText: View {
    let value: Int
    let unit: String
    @State private var shown = 0

    var body: some View {
        Text("\(shown.formatted()) \(unit)")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(Theme.goldLight)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .task(id: value) {
                let steps = 12
                for i in 1...steps {
                    shown = value * i / steps
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { break }
                }
                shown = value
            }
    }
}

// MARK: - Schnelle Poster (verkleinert und zwischengespeichert)

/// TMDB-Bilder in passender Größe laden statt im Original
func thumbURL(_ url: URL) -> URL {
    let s = url.absoluteString
    guard s.contains("tmdb.org"),
          let range = s.range(of: "/t/p/(original|w[0-9]+)/", options: .regularExpression) else { return url }
    return URL(string: s.replacingCharacters(in: range, with: "/t/p/w342/")) ?? url
}

final class ThumbCache {
    static let shared = ThumbCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var running: [URL: Task<UIImage?, Never>] = [:]

    /// Festplatten-Speicher der Poster (für „Cache leeren“ erreichbar)
    private static let diskCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)

    /// Eigene Sitzung mit Festplatten-Speicher: beim nächsten Start sind die Bilder sofort da
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = ThumbCache.diskCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private init() {
        memory.countLimit = 800
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Belegter Platz auf dem Gerät (Bytes)
    var diskUsage: Int { ThumbCache.diskCache.currentDiskUsage }

    /// Alle gespeicherten Poster löschen
    func clear() {
        memory.removeAllObjects()
        ThumbCache.diskCache.removeAllCachedResponses()
    }

    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let image = cached(url) { return image }

        lock.lock()
        if let task = running[url] {
            lock.unlock()
            return await task.value
        }
        let session = self.session
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let result = try? await session.data(from: url) else { return nil }
            return ThumbCache.downsample(result.0, maxPixel: maxPixel)
        }
        running[url] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        running[url] = nil
        lock.unlock()
        if let image = image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// Nur so groß dekodieren, wie das Bild angezeigt wird (spart Speicher und Zeit)
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Ersatz für AsyncImage: verkleinert, im Speicher und auf der Festplatte zwischengespeichert
struct PosterImage: View {
    let url: URL?
    var maxPixel: CGFloat = 360
    var fit = false
    var icon = "film"
    @State private var image: UIImage?

    init(url: URL?, maxPixel: CGFloat = 360, fit: Bool = false, icon: String = "film") {
        self.url = url
        self.maxPixel = maxPixel
        self.fit = fit
        self.icon = icon
        _image = State(initialValue: url.flatMap { ThumbCache.shared.cached(thumbURL($0)) })
    }

    var body: some View {
        ZStack {
            if let image = image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                if !fit { Theme.panel }
                Image(systemName: icon)
                    .font(fit ? .title3 : .title)
                    .foregroundStyle(Theme.gold.opacity(0.7))
            }
        }
        .task(id: url) {
            guard let url = url else {
                image = nil
                return
            }
            let target = thumbURL(url)
            if let hit = ThumbCache.shared.cached(target) {
                image = hit
                return
            }
            let loaded = await ThumbCache.shared.load(target, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}
