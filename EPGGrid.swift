import SwiftUI

// MARK: - Ausführliches Programm (für das Raster)

extension AppStore {
    /// Programm eines Senders mit Beschreibungen, 10 Minuten zwischengespeichert
    func fullEPG(streamId: Int) async -> [EPGEntry] {
        if let cached = fullEPGCache[streamId], Date().timeIntervalSince(cached.at) < 600 { return cached.list }
        guard let api = currentAPI else { return [] }
        let list = (try? await api.shortEPG(streamId: streamId, limit: 60)) ?? []
        fullEPGCache[streamId] = (at: Date(), list: list)
        return list
    }
}

/// Angetippte Sendung
private struct EPGPick: Identifiable {
    let id = UUID()
    let channelIndex: Int
    let channel: Channel
    let entry: EPGEntry
}

// MARK: - EPG-Raster: Sender untereinander, Zeit nach rechts

struct EPGGridView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var parental = Parental.shared
    @State private var pinRequest: PinRequest?
    @State private var group: String?
    @State private var windowStart = EPGGridView.floorHalfHour(Date())
    @State private var pick: EPGPick?
    @State private var pendingPlay: PlayRequest?
    @State private var request: PlayRequest?

    /// Sichtbare Zeitspanne in Minuten
    private let span: Double = 180
    private let channelWidth: CGFloat = 130
    private let rowHeight: CGFloat = 54

    private var groups: [String] {
        Array(Set(store.channels.compactMap(\.group))).sorted()
    }

    private var list: [Channel] {
        parental.visible("live", store.channels).filter { group == nil || $0.group == group }
    }

    static func floorHalfHour(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(t / 1800) * 1800)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE dd.MM."
        return f
    }()

    var body: some View {
        Group {
            if !store.isXtream {
                NeedsXtreamView()
            } else {
                GeometryReader { geo in
                    let timelineWidth = max(200, geo.size.width - channelWidth)
                    VStack(spacing: 0) {
                        controls
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        timeHeader(width: timelineWidth)
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                let channels = list
                                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                                    HStack(spacing: 0) {
                                        channelCell(channel)
                                        EPGTimelineRow(channel: channel, windowStart: windowStart, span: span,
                                                       width: timelineWidth, height: rowHeight) { entry in
                                            pick = EPGPick(channelIndex: index, channel: channel, entry: entry)
                                        }
                                    }
                                    .frame(height: rowHeight)
                                }
                            }
                            .padding(.bottom, 16)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 40).onEnded { value in
                            let dx = value.translation.width, dy = value.translation.height
                            guard abs(dx) > abs(dy) * 1.6 else { return }
                            shift(dx < 0 ? 60 : -60)
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.75))
        .navigationTitle("TV-Programm")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: Route.epgList) {
                    Label("Liste", systemImage: "list.bullet")
                }
            }
        }
        .sheet(item: $pick, onDismiss: {
            if let play = pendingPlay {
                pendingPlay = nil
                request = play
            }
        }) { p in
            programSheet(p)
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: true)
                .environmentObject(store)
        }
        .background(EmptyView().sheet(item: $pinRequest) { req in PinSheet(request: req) })
    }

    // MARK: Bausteine

    private var controls: some View {
        HStack(spacing: 8) {
            if groups.count > 1 {
                Menu {
                    Button("Alle Kategorien") { group = nil }
                    ForEach(groups.filter { !(Profiles.shared.isKids && parental.isProtected("live", $0)) }, id: \.self) { g in
                        Button(parental.isProtected("live", g) ? "🔒 \(g)" : g) {
                            if parental.isLocked("live", g) {
                                pinRequest = PinRequest(title: "PIN für „\(g)“") { group = g }
                            } else {
                                group = g
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(group ?? "Alle Kategorien").lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.goldLight)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.panel))
                    .overlay(Capsule().stroke(Theme.gold.opacity(0.45)))
                }
            }
            Spacer()
            Text(Self.day.string(from: windowStart))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            navButton("chevron.left", "2 Std.") { shift(-120) }
            Button {
                windowStart = Self.floorHalfHour(Date())
            } label: {
                Text("Jetzt")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.gold))
            }
            .buttonStyle(.plain)
            navButton("chevron.right", "2 Std.") { shift(120) }
        }
    }

    private func navButton(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if icon == "chevron.left" { Image(systemName: icon) }
                Text(text)
                if icon == "chevron.right" { Image(systemName: icon) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func timeHeader(width: CGFloat) -> some View {
        let perMinute = width / CGFloat(span)
        return HStack(spacing: 0) {
            Color.clear.frame(width: channelWidth, height: 22)
            ZStack(alignment: .topLeading) {
                ForEach(0..<Int(span / 30), id: \.self) { i in
                    Text(Self.clock.string(from: windowStart.addingTimeInterval(Double(i) * 1800)))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.goldLight)
                        .offset(x: CGFloat(i) * 30 * perMinute + 4)
                }
                let nowMin = Date().timeIntervalSince(windowStart) / 60
                if nowMin >= 0 && nowMin <= span {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 22)
                        .offset(x: CGFloat(nowMin) * perMinute)
                }
            }
            .frame(width: width, height: 22, alignment: .topLeading)
            .clipped()
        }
    }

    private func channelCell(_ channel: Channel) -> some View {
        HStack(spacing: 6) {
            ChannelLogo(url: channel.logo, size: 34)
            Text(channel.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: channelWidth, height: rowHeight)
        .background(Color.black.opacity(0.45))
    }

    private func programSheet(_ p: EPGPick) -> some View {
        let e = p.entry
        let now = Date()
        let running = (e.start ?? .distantFuture) <= now && now < (e.end ?? .distantPast)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(e.title)
                        .font(.title3.weight(.bold))
                    HStack(spacing: 8) {
                        if let s = e.start {
                            Text(Self.day.string(from: s) + " · " + e.timeRange)
                        }
                        Text("· " + p.channel.name)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.goldLight)
                    if running {
                        ProgressView(value: e.progress).tint(Theme.gold)
                    }
                    if let desc = e.desc {
                        Text(desc)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Button {
                        pendingPlay = PlayRequest(channels: list, index: p.channelIndex, isLive: true)
                        pick = nil
                    } label: {
                        Label(running ? "Jetzt ansehen" : "Sender ansehen", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Theme.gold))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { pick = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
    }

    private func shift(_ minutes: Double) {
        let earliest = Self.floorHalfHour(Date()).addingTimeInterval(-2 * 3600)
        let target = windowStart.addingTimeInterval(minutes * 60)
        windowStart = max(earliest, target)
    }
}

/// Eine Zeile mit den Sendungen eines Senders im gewählten Zeitfenster
struct EPGTimelineRow: View {
    @EnvironmentObject private var store: AppStore
    let channel: Channel
    let windowStart: Date
    let span: Double
    let width: CGFloat
    let height: CGFloat
    let onTap: (EPGEntry) -> Void

    @State private var entries: [EPGEntry] = []
    @State private var loaded = false

    var body: some View {
        let perMinute = width / CGFloat(span)
        let windowEnd = windowStart.addingTimeInterval(span * 60)
        let now = Date()
        let visible = entries.filter { e in
            guard let s = e.start, let end = e.end else { return false }
            return end > windowStart && s < windowEnd
        }
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.25))
            if loaded && visible.isEmpty {
                Text("Kein Programm verfügbar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(height: height)
            }
            ForEach(visible) { e in
                let s = max(e.start ?? windowStart, windowStart)
                let end = min(e.end ?? windowEnd, windowEnd)
                let x = CGFloat(s.timeIntervalSince(windowStart) / 60) * perMinute
                let w = max(CGFloat(end.timeIntervalSince(s) / 60) * perMinute - 2, 2)
                let running = (e.start ?? .distantFuture) <= now && now < (e.end ?? .distantPast)
                Button {
                    onTap(e)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(e.timeRange)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(running ? Theme.goldLight : Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: w, height: height - 4, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(running ? Theme.gold.opacity(0.35) : Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(running ? Theme.gold.opacity(0.7) : Color.white.opacity(0.12)))
                    .clipped()
                }
                .buttonStyle(.plain)
                .offset(x: x + 1, y: 2)
            }
            let nowMin = now.timeIntervalSince(windowStart) / 60
            if nowMin >= 0 && nowMin <= span {
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 2, height: height)
                    .offset(x: CGFloat(nowMin) * perMinute)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .task(id: channel.id) {
            entries = await store.fullEPG(streamId: channel.id)
            loaded = true
        }
    }
}
