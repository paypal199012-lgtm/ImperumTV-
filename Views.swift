import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var pickingFile = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("M3U-URL", text: $store.playlistURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { Task { await store.loadFromURL() } }

                    Button("Playlist laden") {
                        Task { await store.loadFromURL() }
                    }
                    .disabled(store.isLoading)

                    Button("M3U-Datei auswählen") {
                        pickingFile = true
                    }
                    .disabled(store.isLoading)
                } footer: {
                    Text("Gib die URL deiner M3U-Playlist ein (z. B. von deinem IPTV-Anbieter) oder wähle eine M3U-Datei aus.")
                }

                if store.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }

                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                if !store.channels.isEmpty {
                    Button("Zurück zur Kanalliste") { store.showSetup = false }
                }
            }
            .navigationTitle("IPTV Player")
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    Task { await store.loadFromFile(url) }
                }
            }
        }
    }
}

struct ChannelListView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var query = ""
    @State private var selectedGroup: String?
    @State private var playing: Channel?

    private var groups: [String] {
        Array(Set(store.channels.compactMap(\.group))).sorted()
    }

    private var filtered: [Channel] {
        store.channels.filter { channel in
            (selectedGroup == nil || channel.group == selectedGroup)
                && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !groups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("Alle", selected: selectedGroup == nil) { selectedGroup = nil }
                            ForEach(groups, id: \.self) { group in
                                chip(group, selected: selectedGroup == group) { selectedGroup = group }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                ForEach(filtered) { channel in
                    Button { playing = channel } label: {
                        ChannelRow(channel: channel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Kanal suchen")
            .navigationTitle("IPTV Player")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await store.loadFromURL() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.playlistURL.isEmpty || store.isLoading)

                    Button { store.showSetup = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .overlay(alignment: .top) {
                if store.isLoading { ProgressView().padding() }
            }
        }
        .fullScreenCover(item: $playing) { channel in
            PlayerScreen(channel: channel) { playing = nil }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: channel.logo) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "play.tv")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).lineLimit(1)
                if let group = channel.group {
                    Text(group)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
