import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.channels.isEmpty || store.showSetup {
                SetupView()
            } else {
                MainTabs()
            }
        }
        .tint(.indigo)
    }
}

// MARK: - Anmeldung

struct SetupView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pickingFile = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server oder kompletter Link", text: $store.serverInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Benutzername", text: $store.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $store.password)

                    Button {
                        Task { await store.login() }
                    } label: {
                        Text("Anmelden und laden").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading)
                } header: {
                    Text("Anmeldung")
                } footer: {
                    Text("Du kannst auch den kompletten Link deines Anbieters einfügen. Benutzername und Passwort werden dann automatisch ausgefüllt.")
                }

                if store.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Lade Sender …")
                        Spacer()
                    }
                }

                if let error = store.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Section {
                    TextField("Kennung (User-Agent)", text: $store.userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Erweitert")
                } footer: {
                    Text("Leer lassen. Nur ändern, wenn dein Anbieter eine bestimmte Kennung verlangt.")
                }

                Section {
                    Button("Link als M3U-Playlist laden") {
                        Task { await store.loadM3U(link: store.serverInput) }
                    }
                    .disabled(store.isLoading)

                    Button("M3U-Datei auswählen") { pickingFile = true }
                        .disabled(store.isLoading)
                } header: {
                    Text("Alternative: M3U")
                }

                if !store.channels.isEmpty {
                    Button("Zurück zu den Sendern") { store.showSetup = false }
                }
            }
            .navigationTitle("IPTV Player")
            .onChange(of: store.serverInput) { value in
                if let account = Account.parse(link: value) {
                    store.serverInput = account.server
                    store.username = account.username
                    store.password = account.password
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    Task { await store.loadFile(url) }
                }
            }
        }
    }
}

// MARK: - Hauptansicht

struct MainTabs: View {
    var body: some View {
        TabView {
            LiveView(favoritesOnly: false)
                .tabItem { Label("Live", systemImage: "tv") }
            LiveView(favoritesOnly: true)
                .tabItem { Label("Favoriten", systemImage: "star.fill") }
            AccountView()
                .tabItem { Label("Konto", systemImage: "person.crop.circle") }
        }
    }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let channels: [Channel]
    let index: Int
}

struct LiveView: View {
    @EnvironmentObject private var store: AppStore
    let favoritesOnly: Bool

    @State private var query = ""
    @State private var selectedGroup: String?
    @State private var request: PlayRequest?

    private var filtered: [Channel] {
        store.channels.filter { channel in
            (!favoritesOnly || store.isFavorite(channel))
                && (selectedGroup == nil || channel.group == selectedGroup)
                && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            let list = filtered
            ScrollView {
                LazyVStack(spacing: 10) {
                    categoryMenu

                    if list.isEmpty {
                        Text(favoritesOnly
                             ? "Noch keine Favoriten. Tippe bei einem Sender auf den Stern."
                             : "Keine Sender gefunden.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }

                    ForEach(Array(list.enumerated()), id: \.element.id) { index, channel in
                        ChannelCard(channel: channel) {
                            request = PlayRequest(channels: list, index: index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .searchable(text: $query, prompt: "Sender suchen")
            .navigationTitle(favoritesOnly ? "Favoriten" : "Live-TV")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index)
        }
    }

    private var categoryMenu: some View {
        HStack {
            Menu {
                Button("Alle Kategorien") { selectedGroup = nil }
                ForEach(store.groups, id: \.self) { group in
                    Button(group) { selectedGroup = group }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(selectedGroup ?? "Alle Kategorien").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

struct ChannelCard: View {
    @EnvironmentObject private var store: AppStore
    let channel: Channel
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    logo
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if let group = channel.group {
                            Text(group)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.toggleFavorite(channel)
            } label: {
                Image(systemName: store.isFavorite(channel) ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(store.isFavorite(channel) ? Color.yellow : Color.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var logo: some View {
        AsyncImage(url: channel.logo) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: "play.tv")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Konto

struct AccountView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Verbindung") {
                    if !store.serverInput.isEmpty {
                        LabeledContent("Server", value: store.serverInput)
                    }
                    if !store.username.isEmpty {
                        LabeledContent("Benutzer", value: store.username)
                    }
                    if let info = store.infoMessage {
                        Text(info).foregroundStyle(.secondary)
                    }
                    LabeledContent("Sender", value: "\(store.channels.count)")
                }

                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }

                Section {
                    Button("Senderliste neu laden") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isLoading)

                    Button("Anmeldung ändern") { store.showSetup = true }

                    Button("Abmelden", role: .destructive) { store.logout() }
                }
            }
            .navigationTitle("Konto")
        }
    }
}
