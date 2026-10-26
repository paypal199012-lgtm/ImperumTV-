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

    @State private var group: String?
    @State private var favoritesOnly = false
    @State private var query = ""
    @State private var selected: Channel?
    @State private var request: PlayRequest?
    @State private var epg: [EPGEntry] = []

    private var groups: [String] {
        Array(Set(store.channels.compactMap(\.group))).sorted()
    }

    private var filtered: [Channel] {
        store.channels.filter { channel in
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
        .onDisappear { preview.stop() }
        .fullScreenCover(item: $request, onDismiss: resumePreview) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: true)
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
                    categoryRow(name, icon: nil, selected: group == name && !favoritesOnly) {
                        group = name
                        favoritesOnly = false
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
                    if preview.usesVLC {
                        VLCVideoView(player: preview.vlcPlayer)
                    } else {
                        PlayerLayerView(player: preview.player)
                    }
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

    /// Vorschau anhalten, damit nicht zwei Verbindungen gleichzeitig laufen
    private func openFullscreen(list: [Channel], index: Int) {
        preview.stop()
        request = PlayRequest(channels: list, index: index, isLive: true)
    }

    private func resumePreview() {
        if let channel = selected {
            preview.play(channel.url, userAgent: store.userAgentValue)
        }
    }
}

// MARK: - Multi: bis zu 4 Sender gleichzeitig

final class MultiPlayers: ObservableObject {
    let models: [PlayerModel] = (0..<4).map { _ in PlayerModel() }
}

struct SlotRef: Identifiable {
    let id: Int
}

struct MultiView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var players = MultiPlayers()

    @State private var slots: [Channel?] = [nil, nil, nil, nil]
    @State private var active = 0
    @State private var picking: SlotRef?

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let tileHeight = max((geo.size.height - spacing) / 2, 60)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)],
                spacing: spacing
            ) {
                ForEach(0..<4, id: \.self) { i in
                    MultiTile(
                        model: players.models[i],
                        channel: slots[i],
                        isActive: i == active,
                        onTap: { activate(i) },
                        onPick: { picking = SlotRef(id: i) },
                        onRemove: { remove(i) }
                    )
                    .frame(height: tileHeight)
                }
            }
        }
        .padding(4)
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .padding(10)
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .sheet(item: $picking) { ref in
            ChannelPickerSheet { channel in
                assign(channel, to: ref.id)
            }
            .environmentObject(store)
        }
        .onDisappear {
            players.models.forEach { $0.stop() }
        }
    }

    private func assign(_ channel: Channel, to index: Int) {
        slots[index] = channel
        players.models[index].play(channel.url, userAgent: store.userAgentValue)
        activate(index)
    }

    /// Nur der ausgewählte Sender hat Ton
    private func activate(_ index: Int) {
        active = index
        for (i, model) in players.models.enumerated() {
            model.setMuted(i != index)
        }
    }

    private func remove(_ index: Int) {
        players.models[index].stop()
        slots[index] = nil
    }
}

struct MultiTile: View {
    @ObservedObject var model: PlayerModel
    let channel: Channel?
    let isActive: Bool
    let onTap: () -> Void
    let onPick: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack {
            Color(white: 0.06)
            if let channel = channel {
                if model.usesVLC {
                    VLCVideoView(player: model.vlcPlayer)
                } else {
                    PlayerLayerView(player: model.player)
                }
                if model.isBuffering && model.errorMessage == nil {
                    ProgressView().tint(.white)
                }
                if model.errorMessage != nil {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Nicht verfügbar").font(.caption)
                    }
                    .foregroundStyle(.white)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(isActive ? Theme.goldLight : Color.white.opacity(0.7))
                        Text(channel.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 30))
                    Text("Sender wählen")
                        .font(.caption)
                }
                .foregroundStyle(Theme.goldLight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive && channel != nil ? Theme.gold : Color.white.opacity(0.15),
                        lineWidth: isActive && channel != nil ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if channel == nil { onPick() } else { onTap() }
        }
        .contextMenu {
            if channel != nil {
                Button { onPick() } label: {
                    Label("Sender ändern", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { onRemove() } label: {
                    Label("Entfernen", systemImage: "xmark")
                }
            }
        }
    }
}

struct ChannelPickerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (Channel) -> Void

    @State private var query = ""
    @State private var group: String?

    var body: some View {
        let groups = Array(Set(store.channels.compactMap(\.group))).sorted()
        let list = store.channels.filter { channel in
            (group == nil || channel.group == group)
                && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
        }

        NavigationStack {
            List(list) { channel in
                Button {
                    onPick(channel)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        ChannelLogo(url: channel.logo, size: 36)
                        Text(channel.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Sender suchen")
            .navigationTitle(group ?? "Sender wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Alle Kategorien") { group = nil }
                        ForEach(groups, id: \.self) { name in
                            Button(name) { group = name }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .tint(Theme.gold)
    }
}
