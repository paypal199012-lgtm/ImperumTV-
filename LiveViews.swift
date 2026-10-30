import SwiftUI

// MARK: - Live-TV (im Querformat drei Spalten wie bei XCIPTV)

struct LiveTVView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        // Die App läuft nur im Querformat, deshalb immer drei Spalten
        LiveThreePaneView()
    }
}

struct LiveThreePaneView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var preview = PlayerModel()
    @ObservedObject private var parental = Parental.shared
    @State private var pinRequest: PinRequest?

    @State private var group: String?
    @State private var favoritesOnly = false
    @State private var query = ""
    @State private var selected: Channel?
    @State private var request: PlayRequest?
    @State private var epg: [EPGEntry] = []
    /// Vollbild offen: Vorschau nicht anhalten
    @State private var handingOff = false
    /// Neu zeichnen nach dem Vollbild (VLC braucht seine Fläche zurück)
    @State private var surface = 0

    private var groups: [String] {
        Array(Set(store.channels.compactMap(\.group))).sorted()
    }

    private var filtered: [Channel] {
        parental.visible("live", store.channels).filter { channel in
            (!favoritesOnly || store.isFavorite(channel))
                && (group == nil || channel.group == group)
                && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let list = filtered
        let numbers = Dictionary(
            store.channels.enumerated().map { ($0.element.id, $0.offset + 1) },
            uniquingKeysWith: { first, _ in first }
        )

        GeometryReader { geo in
            HStack(spacing: 0) {
                categoryColumn
                    .frame(width: geo.size.width * 0.24)
                divider
                channelColumn(list, numbers: numbers)
                    .frame(width: geo.size.width * 0.36)
                divider
                previewColumn(list)
            }
        }
        .background(GoldBackground(dim: 0.78))
        .navigationTitle("Live-TV")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selected?.id) {
            epg = []
            if let channel = selected, store.isXtream {
                epg = await store.shortEPG(streamId: channel.id)
            }
        }
        .onDisappear { if !handingOff && !preview.isPiPActive { preview.stop() } }   // Bild-in-Bild läuft weiter
        .sheet(item: $pinRequest) { req in
            PinSheet(request: req)
        }
        .fullScreenCover(item: $request, onDismiss: resumePreview) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: true, handoff: preview)
                .environmentObject(store)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
    }

    // MARK: Spalte 1: Kategorien

    private var categoryColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("Kategorien")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.goldLight)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                categoryRow("Alle", icon: "square.grid.2x2", selected: group == nil && !favoritesOnly) {
                    group = nil
                    favoritesOnly = false
                }
                categoryRow("Favoriten", icon: "star.fill", selected: favoritesOnly) {
                    favoritesOnly = true
                    group = nil
                }
                ForEach(groups, id: \.self) { name in
                    categoryRow(name, icon: parental.isProtected("live", name) ? "lock.fill" : nil,
                                selected: group == name && !favoritesOnly) {
                        if parental.isLocked("live", name) {
                            pinRequest = PinRequest(title: "PIN für „\(name)“") {
                                group = name
                                favoritesOnly = false
                            }
                        } else {
                            group = name
                            favoritesOnly = false
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func categoryRow(_ title: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.goldLight : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.gold.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: Spalte 2: Sender

    private func channelColumn(_ list: [Channel], numbers: [Int: Int]) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Suchen", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.subheadline)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if list.isEmpty {
                        Text(favoritesOnly ? "Noch keine Favoriten" : "Keine Sender gefunden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, channel in
                        channelRow(channel, number: numbers[channel.id] ?? index + 1, isSelected: channel.id == selected?.id) {
                            tap(channel, list: list, index: index)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    private func channelRow(_ channel: Channel, number: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                ChannelLogo(url: channel.logo, size: 30)
                Text(channel.name)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if store.isFavorite(channel) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.gold)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.gold.opacity(0.25) : Color.clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Theme.goldLight).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.toggleFavorite(channel)
            } label: {
                Label(store.isFavorite(channel) ? "Aus Favoriten entfernen" : "Zu Favoriten",
                      systemImage: store.isFavorite(channel) ? "star.slash" : "star")
            }
        }
    }

    // MARK: Spalte 3: Vorschau und Programm

    private func previewColumn(_ list: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if selected != nil {
                    Group {
                        if preview.usesVLC {
                            VLCVideoView(player: preview.vlcPlayer)
                        } else {
                            PlayerLayerView(player: preview.player)
                        }
                    }
                    .id(surface)
                    if preview.isBuffering && preview.errorMessage == nil {
                        ProgressView().tint(.white)
                    }
                    if preview.errorMessage != nil {
                        Text("Sender nicht verfügbar")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "play.tv").font(.title)
                        Text("Sender antippen").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.4)))
            .contentShape(Rectangle())
            .onTapGesture { openSelected(list) }

            if let channel = selected {
                HStack {
                    Text(channel.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button { openSelected(list) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.goldLight)
                            .padding(6)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if epg.isEmpty {
                            Text(store.isXtream ? "Kein Programm verfügbar" : "Programm nur mit Benutzername und Passwort")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(epg.prefix(4).enumerated()), id: \.element.id) { i, entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.timeRange)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.gold)
                                    Text(entry.title)
                                        .font(.caption)
                                        .foregroundStyle(i == 0 ? Color.white : Color.gray)
                                        .lineLimit(2)
                                }
                                if i == 0 {
                                    ProgressView(value: entry.progress)
                                        .tint(Theme.gold)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    // MARK: Logik

    private func tap(_ channel: Channel, list: [Channel], index: Int) {
        if channel.id == selected?.id {
            openFullscreen(list: list, index: index)
        } else {
            selected = channel
            preview.play(channel.url, userAgent: store.userAgentValue)
        }
    }

    private func openSelected(_ list: [Channel]) {
        guard let channel = selected else { return }
        if let index = list.firstIndex(where: { $0.id == channel.id }) {
            openFullscreen(list: list, index: index)
        } else {
            openFullscreen(list: [channel], index: 0)
        }
    }

    /// Vollbild übernimmt den laufenden Player – nur das Bild wird größer
    private func openFullscreen(list: [Channel], index: Int) {
        handingOff = true
        if index < list.count, list[index].id != selected?.id {
            selected = list[index]
        }
        request = PlayRequest(channels: list, index: index, isLive: true)
    }

    private func resumePreview() {
        handingOff = false
        surface += 1
        // Im Vollbild umgeschaltet? Dann diesen Sender in der Vorschau markieren
        if let url = preview.playingURL {
            if let channel = store.channels.first(where: { $0.url == url }), channel.id != selected?.id {
                selected = channel
            }
        } else if let channel = selected {
            preview.play(channel.url, userAgent: store.userAgentValue)
        }
    }
}
