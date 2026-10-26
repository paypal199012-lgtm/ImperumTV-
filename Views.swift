import SwiftUI
import UniformTypeIdentifiers

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
                        Text("Anmelden").frame(maxWidth: .infinity)
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
                    Button("Zurück zum Menü") { store.showSetup = false }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GoldBackground(dim: 0.45))
            .navigationTitle("ImperumTV")
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

// MARK: - Gemeinsame Bausteine

struct PlayRequest: Identifiable {
    let id = UUID()
    let channels: [Channel]
    let index: Int
    let isLive: Bool
}

struct CategoryMenu: View {
    let groups: [String]
    @Binding var selection: String?

    var body: some View {
        HStack {
            Menu {
                Button("Alle Kategorien") { selection = nil }
                ForEach(groups, id: \.self) { group in
                    Button(group) { selection = group }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(selection ?? "Alle Kategorien").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.goldLight)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.panel))
                .overlay(Capsule().stroke(Theme.gold.opacity(0.45)))
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

struct ChannelLogo: View {
    let url: URL?
    var size: CGFloat = 52

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: "play.tv")
                    .font(.title3)
                    .foregroundStyle(Theme.gold.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
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
                    ChannelLogo(url: channel.logo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let group = channel.group {
                            Text(group)
                                .font(.caption)
                                .foregroundStyle(Theme.goldLight.opacity(0.8))
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
                    .foregroundStyle(store.isFavorite(channel) ? Theme.gold : Color.white.opacity(0.6))
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gold.opacity(0.25)))
    }
}

struct NeedsXtreamView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.gold)
            Text("Filme, Serien und das TV-Programm gibt es nur mit der Anmeldung über Benutzername und Passwort.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Anmeldung ändern") { store.showSetup = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - Senderliste

struct ChannelListView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let items: [Channel]
    let isLive: Bool

    @State private var query = ""
    @State private var group: String?
    @State private var request: PlayRequest?

    private var groups: [String] {
        Array(Set(items.compactMap(\.group))).sorted()
    }

    private var filtered: [Channel] {
        items.filter { channel in
            (group == nil || channel.group == group)
                && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let list = filtered
        ScrollView {
            LazyVStack(spacing: 10) {
                if groups.count > 1 {
                    CategoryMenu(groups: groups, selection: $group)
                }
                if list.isEmpty {
                    Text("Keine Sender gefunden.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { index, channel in
                    ChannelCard(channel: channel) {
                        request = PlayRequest(channels: list, index: index, isLive: isLive)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(GoldBackground(dim: 0.6))
        .searchable(text: $query, prompt: "Suchen")
        .navigationTitle(title)
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: req.isLive)
                .environmentObject(store)
        }
    }
}

// MARK: - Favoriten

struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var request: PlayRequest?

    var body: some View {
        let live = store.channels.filter { store.isFavorite($0) }
        let films = store.movies.filter { store.isFavorite($0) }
        let shows = store.seriesList.filter { store.isFavoriteSeries($0) }
        ScrollView {
            LazyVStack(spacing: 10) {
                if live.isEmpty && films.isEmpty && shows.isEmpty {
                    Text("Noch keine Favoriten. Tippe bei einem Sender auf den Stern oder halte bei einem Film den Finger auf das Bild.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                if !live.isEmpty {
                    SectionTitle(text: "Live-TV")
                    ForEach(Array(live.enumerated()), id: \.element.id) { index, channel in
                        ChannelCard(channel: channel) {
                            request = PlayRequest(channels: live, index: index, isLive: true)
                        }
                    }
                }
                if !films.isEmpty {
                    SectionTitle(text: "Filme")
                    ForEach(Array(films.enumerated()), id: \.element.id) { index, film in
                        ChannelCard(channel: film) {
                            request = PlayRequest(channels: films, index: index, isLive: false)
                        }
                    }
                }
                if !shows.isEmpty {
                    SectionTitle(text: "Serien")
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            HStack(spacing: 12) {
                                ChannelLogo(url: show.cover)
                                Text(show.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.gold)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Favoriten")
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: req.isLive)
                .environmentObject(store)
        }
    }
}

// MARK: - Suche

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var request: PlayRequest?

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let live: [Channel] = q.isEmpty ? [] : Array(store.channels.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50))
        let films: [Channel] = q.isEmpty ? [] : Array(store.movies.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50))
        let shows: [SeriesItem] = q.isEmpty ? [] : Array(store.seriesList.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50))

        ScrollView {
            LazyVStack(spacing: 10) {
                if q.isEmpty {
                    Text("Suche nach Sendern, Filmen und Serien.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else if live.isEmpty && films.isEmpty && shows.isEmpty {
                    Text("Nichts gefunden.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }

                if !live.isEmpty {
                    SectionTitle(text: "Live-TV")
                    ForEach(Array(live.enumerated()), id: \.element.id) { index, channel in
                        ChannelCard(channel: channel) {
                            request = PlayRequest(channels: live, index: index, isLive: true)
                        }
                    }
                }
                if !films.isEmpty {
                    SectionTitle(text: "Filme")
                    ForEach(Array(films.enumerated()), id: \.element.id) { index, film in
                        ChannelCard(channel: film) {
                            request = PlayRequest(channels: films, index: index, isLive: false)
                        }
                    }
                }
                if !shows.isEmpty {
                    SectionTitle(text: "Serien")
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            HStack(spacing: 12) {
                                ChannelLogo(url: show.cover)
                                Text(show.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.gold)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(GoldBackground(dim: 0.6))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Sender, Filme, Serien")
        .navigationTitle("Suche")
        .task {
            if store.isXtream {
                await store.loadMoviesIfNeeded()
                await store.loadSeriesIfNeeded()
            }
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: req.isLive)
                .environmentObject(store)
        }
    }
}

// MARK: - Konto und Einstellungen

struct AccountView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Verbindung") {
                if !store.serverInput.isEmpty {
                    LabeledContent("Server", value: store.serverInput)
                }
                if !store.username.isEmpty {
                    LabeledContent("Benutzer", value: store.username)
                }
                if let info = store.infoMessage {
                    Text(info)
                }
                if let exp = store.expiryText {
                    LabeledContent("Läuft ab", value: exp)
                }
            }

            Section("Inhalte") {
                LabeledContent("Live-Sender", value: "\(store.channels.count)")
                LabeledContent("Filme", value: store.movies.isEmpty ? "–" : "\(store.movies.count)")
                LabeledContent("Serien", value: store.seriesList.isEmpty ? "–" : "\(store.seriesList.count)")
                LabeledContent("Favoriten", value: "\(store.favorites.count)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Konto")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("liveWithVLC") private var liveWithVLC = false

    var body: some View {
        Form {
            Section {
                Button("Alles neu laden") {
                    Task { await store.refresh() }
                }
                .disabled(store.isLoading)

                Button("Anmeldung ändern") { store.showSetup = true }
            }

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Section {
                Toggle("Live-TV mit VLC abspielen", isOn: $liveWithVLC)
                    .tint(Theme.gold)
            } header: {
                Text("Wiedergabe")
            } footer: {
                Text("Einschalten, wenn Sender beim Start oft hängen bleiben oder ein Standbild zeigen. Mit VLC gibt es bei Live-TV kein Bild-in-Bild.")
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
                Button("Abmelden", role: .destructive) { store.logout() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Einstellungen")
    }
}
