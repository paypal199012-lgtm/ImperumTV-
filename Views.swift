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
    @State private var groupMemo = Memo<[String]>()
    @State private var memo = Memo<[Channel]>()

    private var groups: [String] {
        groupMemo.get([items.count, items.first?.id, items.last?.id]) { Array(Set(items.compactMap(\.group))).sorted() }
    }

    private var filtered: [Channel] {
        memo.get([items.count, items.first?.id, items.last?.id, group, query]) {
            items.filter { channel in
                (group == nil || channel.group == group)
                    && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
            }
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
    @State private var memo = Memo<([Channel], [Channel], [SeriesItem])>()

    var body: some View {
        let favs = memo.get([store.dataVersion, parental.stamp]) {
            (parental.visible("live", store.channels).filter { store.isFavorite($0) },
             parental.visible("movie", store.movies).filter { store.isFavorite($0) },
             parental.visibleSeries(store.seriesList).filter { store.isFavoriteSeries($0) })
        }
        let live = favs.0
        let films = favs.1
        let shows = favs.2
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
    /// Erst suchen, wenn kurz nicht mehr getippt wird
    @State private var q = ""
    @State private var request: PlayRequest?
    @State private var memo = Memo<([Channel], [Channel], [SeriesItem])>()

    var body: some View {
        let found = memo.get([store.dataVersion, parental.stamp, q]) {
            q.isEmpty ? ([Channel](), [Channel](), [SeriesItem]()) : (
                Array(parental.visible("live", store.channels).lazy.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50)),
                Array(parental.visible("movie", store.movies).lazy.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50)),
                Array(parental.visibleSeries(store.seriesList).lazy.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50)))
        }
        let live = found.0
        let films = found.1
        let shows = found.2

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
        .task(id: query) {
            let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !q.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            if !Task.isCancelled { q = t }
        }
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
    @State private var showNetTest = false
    @AppStorage("liveWithVLC") private var liveWithVLC = false
    @AppStorage("vodWithVLC") private var vodWithVLC = false
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("introBtn") private var introBtn = true
    @AppStorage("clockMode") private var clockMode = "sec"
    @AppStorage("bufferMode") private var bufferMode = "normal"
    @AppStorage("netqMode") private var netqMode = "always"
    @AppStorage("catchup") private var catchup = true
    @State private var showSleep = false
    @ObservedObject private var sleep = SleepTimer.shared
    @State private var askClearCache = false
    @State private var cacheMessage: String?
    @State private var aboNote: String?

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func openParental() {
        if parental.enabled {
            pinRequest = PinRequest(title: "PIN eingeben") { showParental = true }
        } else {
            pinRequest = PinRequest(title: "Neue PIN", mode: .create) { showParental = true }
        }
    }

    /// Banner oben: Logo, Konto und Version, rechts Kinderschutz und Gerät
    private var banner: some View {
        HStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("ImperumTV").font(.title3.weight(.bold)).foregroundStyle(.white)
                Text((store.license?.activated == true ? "Konto aktiviert" : store.licenseText) + (version.isEmpty ? "" : " · Version \(version)"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            statusBox("lock", "Kinderschutz", parental.enabled ? "An" : "Aus") { openParental() }
            statusBox("calendar", abo.label, abo.value, tint: abo.tint) {
                aboNote = store.expiry.map { "Dein Abo beim Anbieter läuft bis \(Self.dateText($0)). Verlängern kannst du es bei deinem Anbieter." }
                    ?? "Dein Anbieter meldet kein Ablaufdatum."
            }
            statusBox("display", "Gerät", store.macText, small: true) { store.showSetup = true }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Theme.gold.opacity(0.45), Theme.gold.opacity(0.12), Color.white.opacity(0.04)],
                                     startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.goldLight.opacity(0.6), lineWidth: 1))
    }

    private static func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; return f.string(from: d)
    }

    /// Abo beim Anbieter: Datum, ab 7 Tagen vorher gelb, abgelaufen rot
    private var abo: (label: String, value: String, tint: Color?) {
        guard let exp = store.expiry else { return ("Abo", "unbegrenzt", nil) }
        let days = Int(ceil(exp.timeIntervalSinceNow / 86400))
        if days <= 0 { return ("Abo", "abgelaufen", .red) }
        if days <= 7 { return ("Abo läuft ab", days == 1 ? "morgen" : "in \(days) Tagen", .orange) }
        return ("Abo bis", Self.dateText(exp), nil)
    }

    private func statusBox(_ icon: String, _ label: String, _ value: String, small: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(label, systemImage: icon).font(.caption2).foregroundStyle(Color.white.opacity(0.65))
                Text(value).font(small ? .caption.weight(.bold).monospacedDigit() : .subheadline.weight(.bold)).foregroundStyle(tint ?? .white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.map { $0.opacity(0.18) } ?? Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint ?? .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Aktionen unten wie auf dem Fernseher: Neu laden, Cache leeren, Verbindungstest
    private var actions: some View {
        HStack(spacing: 10) {
            actionTile("arrow.clockwise", "Neu laden", "Sender, Filme, Serien") { Task { await store.refresh() } }
                .disabled(store.isLoading)
            actionTile("paintbrush", "Cache leeren", "Bilder & Programm") { askClearCache = true }
                .disabled(store.isLoading)
            actionTile("speedometer", "Verbindungstest", "Internet & Sender") { showNetTest = true }
        }
    }

    private func actionTile(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.goldLight)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.gold.opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Form {
            Section {
                banner
                actions
                if let msg = cacheMessage ?? aboNote {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Theme.goldLight)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))

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
                Picker("Puffer", selection: $bufferMode) {
                    Text("Klein · 0,5 s (schnellster Start)").tag("small")
                    Text("Normal · 2 s (wie bisher)").tag("normal")
                    Text("Groß · 5 s (gegen Ruckler)").tag("large")
                }
                Toggle("Näher am Live-Geschehen", isOn: $catchup)
                    .tint(Theme.gold)
                Toggle("Nächste Folge automatisch", isOn: $autoNext)
                    .tint(Theme.gold)
                Toggle("Knopf „Intro überspringen“", isOn: $introBtn)
                    .tint(Theme.gold)
            } header: {
                Label("Wiedergabe", systemImage: "play")
            } footer: {
                Text("VLC einschalten, wenn Sender beim Start oft hängen oder ein Standbild zeigen (dann ohne Bild-in-Bild). Kurz vor Ende einer Folge zählt die App 10 Sekunden herunter und startet die nächste; „Intro überspringen“ springt 20 Sekunden weiter.")
            }

            Section {
                Picker("Uhrzeit oben rechts", selection: $clockMode) {
                    Text("Mit Sekunden").tag("sec")
                    Text("Ohne Sekunden").tag("min")
                    Text("Aus").tag("off")
                }
                Picker("Verbindungsanzeige", selection: $netqMode) {
                    Text("Immer").tag("always")
                    Text("Nur bei Problemen").tag("problems")
                    Text("Aus").tag("off")
                }
                Button { showSleep = true } label: {
                    HStack {
                        Label("Schlaf-Timer", systemImage: sleep.active ? "moon.fill" : "moon")
                        Spacer()
                        Text(sleep.active ? "An · noch \(sleep.minutesLeft) Min" : "Aus").foregroundStyle(.secondary)
                    }
                }
                Button { openParental() } label: {
                    HStack {
                        Label("Kindersicherung", systemImage: parental.enabled ? "lock.fill" : "lock.open")
                        Spacer()
                        Text(parental.enabled ? "An" : "Aus")
                            .foregroundStyle(.secondary)
                    }
                }
                if !Profiles.shared.isKids {
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
                }
            } header: {
                Label("Anzeige & Familie", systemImage: "clock")
            }

            Section {
                Button("Wiedergabelisten") { store.showSetup = true }
                NavigationLink {
                    AccountView()
                } label: {
                    HStack {
                        Label("Konto", systemImage: "person.crop.circle")
                        Spacer()
                        Text(store.license?.activated == true ? "Aktiviert" : "").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Konto", systemImage: "person")
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
        .sheet(item: $pinRequest) { req in
            PinSheet(request: req)
        }
        .navigationDestination(isPresented: $showParental) {
            ParentalSettingsView()
        }
        .sleepTimerDialog(isPresented: $showSleep)
        .navigationDestination(isPresented: $showNetTest) {
            NetTestView().clockInToolbar()
        }
    }
}
