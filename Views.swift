import SwiftUI
import UniformTypeIdentifiers

// MARK: - Gemeinsame Bausteine

struct PlayRequest: Identifiable {
    let id = UUID()
    let channels: [Channel]
    let index: Int
    let isLive: Bool
    /// Bei Filmen und Folgen: Angaben fürs Weiterschauen (gleiche Reihenfolge wie channels)
    var resume: [ResumeInfo]? = nil
    /// Startpunkt in Sekunden. nil = gespeicherten Stand nehmen, 0 = von vorne
    var startAt: Double? = nil
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
        PosterImage(url: url, maxPixel: 160, fit: true, icon: "play.tv")
            .padding(4)
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
        .contextMenu {
            Button {
                store.toggleFavorite(channel)
            } label: {
                Label(store.isFavorite(channel) ? "Aus Favoriten entfernen" : "Zu Favoriten",
                      systemImage: store.isFavorite(channel) ? "star.slash" : "star")
            }
        }
    }
}

/// Langes Tippen auf eine Serie: Favorit hinzufügen oder entfernen
struct SeriesFavoriteMenu: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let show: SeriesItem

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                store.toggleFavoriteSeries(show)
            } label: {
                Label(store.isFavoriteSeries(show) ? "Aus Favoriten entfernen" : "Zu Favoriten",
                      systemImage: store.isFavoriteSeries(show) ? "star.slash" : "star")
            }
        }
    }
}

struct NeedsXtreamView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.gold)
            Text("Filme, Serien und das TV-Programm gibt es nur mit einem Xtream-Zugang (Server, Benutzername und Passwort).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Wiedergabelisten") { store.showSetup = true }
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
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: req.isLive,
                         resume: req.resume, startAt: req.startAt)
                .environmentObject(store)
        }
    }
}

// MARK: - Favoriten

struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var parental = Parental.shared
    @State private var request: PlayRequest?

    var body: some View {
        let live = parental.visible("live", store.channels).filter { store.isFavorite($0) }
        let films = parental.visible("movie", store.movies).filter { store.isFavorite($0) }
        let shows = parental.visibleSeries(store.seriesList).filter { store.isFavoriteSeries($0) }
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
                            request = PlayRequest(channels: films, index: index, isLive: false, resume: films.map { ResumeInfo.movie($0) })
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
                        .modifier(SeriesFavoriteMenu(show: show))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Favoriten")
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: req.isLive,
                         resume: req.resume, startAt: req.startAt)
                .environmentObject(store)
        }
    }
}

// MARK: - Suche

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var parental = Parental.shared
    @State private var query = ""
    @State private var request: PlayRequest?

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let live: [Channel] = q.isEmpty ? [] : Array(parental.visible("live", store.channels).filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50))
        let films: [Channel] = q.isEmpty ? [] : Array(parental.visible("movie", store.movies).filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50))
        let shows: [SeriesItem] = q.isEmpty ? [] : Array(parental.visibleSeries(store.seriesList).filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50))

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
                            request = PlayRequest(channels: films, index: index, isLive: false, resume: films.map { ResumeInfo.movie($0) })
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
                        .modifier(SeriesFavoriteMenu(show: show))
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
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: req.isLive,
                         resume: req.resume, startAt: req.startAt)
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

            Section("Gerät") {
                LabeledContent("Lizenz", value: store.license?.activated == true ? "Aktiviert (unbegrenzt)" : store.licenseText)
                LabeledContent("MAC-Adresse", value: store.macText)
                LabeledContent("Geräte-Schlüssel", value: store.deviceKey)
                if let link = store.deviceLink {
                    Link("Website öffnen", destination: link)
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
    @ObservedObject private var parental = Parental.shared
    @State private var pinRequest: PinRequest?
    @State private var showParental = false
    @AppStorage("liveWithVLC") private var liveWithVLC = false
    @AppStorage("vodWithVLC") private var vodWithVLC = false
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("introBtn") private var introBtn = true
    @State private var askClearCache = false
    @State private var cacheMessage: String?

    var body: some View {
        Form {
            Section {
                Button("Alles neu laden") {
                    Task { await store.refresh() }
                }
                .disabled(store.isLoading)

                Button("Cache leeren") { askClearCache = true }
                    .disabled(store.isLoading)
                    .confirmationDialog("Cache leeren?", isPresented: $askClearCache, titleVisibility: .visible) {
                        Button("Cache leeren", role: .destructive) {
                            Task {
                                let mb = await store.clearCache()
                                cacheMessage = mb > 0 ? "Cache geleert (\(mb) MB frei) – Listen neu geladen." : "Cache geleert – Listen neu geladen."
                            }
                        }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Gespeicherte Cover, Bilder und das Programm werden gelöscht und neu geladen. Favoriten, Weiterschauen, gesehene Folgen und Einstellungen bleiben erhalten.")
                    }
                if let msg = cacheMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Theme.goldLight)
                }

                Button("Wiedergabelisten") { store.showSetup = true }
            }

            if !Profiles.shared.isKids {
                Section {
                    NavigationLink {
                        ProfilesSettingsView()
                    } label: {
                        HStack {
                            Label("Profile", systemImage: "person.2.fill")
                            Spacer()
                            Text(Profiles.shared.list.isEmpty ? "Aus" : "\(Profiles.shared.list.count) · \(Profiles.shared.current?.name ?? "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Mehrere Personen auf diesem Gerät: eigene Favoriten, „Weiterschauen“ und Gesehen-Haken. Auch als Kinder-Profil.")
                }
            }

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Section {
                Toggle("Live-TV mit VLC abspielen", isOn: $liveWithVLC)
                    .tint(Theme.gold)
                Toggle("Filme & Serien mit VLC abspielen", isOn: $vodWithVLC)
                    .tint(Theme.gold)
            } header: {
                Text("Wiedergabe")
            } footer: {
                Text("Einschalten, wenn Sender beim Start oft hängen bleiben oder ein Standbild zeigen. Mit VLC gibt es kein Bild-in-Bild. Im Player kannst du jederzeit oben mit dem Pfeil-Knopf zwischen iPhone-Player und VLC wechseln.")
            }

            Section {
                Toggle("Nächste Folge automatisch", isOn: $autoNext)
                    .tint(Theme.gold)
                Toggle("Knopf „Intro überspringen“", isOn: $introBtn)
                    .tint(Theme.gold)
            } header: {
                Text("Serien")
            } footer: {
                Text("Kurz vor Ende einer Folge zählt die App 10 Sekunden herunter und startet dann die nächste. „Intro überspringen“ erscheint 8 Sekunden lang am Anfang jeder Folge und springt 20 Sekunden weiter.")
            }

            Section {
                Button {
                    if parental.enabled {
                        pinRequest = PinRequest(title: "PIN eingeben") { showParental = true }
                    } else {
                        pinRequest = PinRequest(title: "Neue PIN", mode: .create) { showParental = true }
                    }
                } label: {
                    HStack {
                        Label("Kindersicherung", systemImage: parental.enabled ? "lock.fill" : "lock.open")
                        Spacer()
                        Text(parental.enabled ? "An" : "Aus")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Kindersicherung")
            } footer: {
                Text("Mit einer PIN werden Erwachsenen-Kategorien und Kategorien deiner Wahl gesperrt.")
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

        }
        .scrollContentBackground(.hidden)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Einstellungen")
        .sheet(item: $pinRequest) { req in
            PinSheet(request: req)
        }
        .navigationDestination(isPresented: $showParental) {
            ParentalSettingsView()
        }
    }
}
