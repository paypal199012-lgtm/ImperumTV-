import SwiftUI

// MARK: - Poster

struct PosterCard: View {
    let title: String
    let image: URL?
    var isFavorite = false
    /// Fortschritt 0 … 1 (Weiterschauen)
    var progress: Double? = nil
    var subtitle: String? = nil
    /// Bewertung 0–10, wird oben links gezeigt
    var rating: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    PosterImage(url: image)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gold.opacity(0.3)))
                .overlay(alignment: .bottom) {
                    if let progress = progress {
                        ProgressStrip(part: progress)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rating = rating, rating > 0 {
                        RatingBadge(value: rating)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.gold)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                            .padding(4)
                    }
                }

            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(subtitle == nil ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.gold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}

private let posterColumns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

/// Sonder-Kategorie mit angefangenen Filmen bzw. Serien
let resumeCategory = "▶ Weiter ansehen"
/// Sonder-Kategorie mit den neuesten Titeln des Anbieters
let newCategory = "Zuletzt hinzugefügt"
/// Schlüssel für die Zahl bei „Alle“ und „Favoriten“ (kann mit keinem Kategorienamen kollidieren)
let countAll = "\u{1}alle"
let countFavorites = "\u{1}favoriten"


// MARK: - Kategorien-Spalte (wie bei XCIPTV)

struct CategorySidebar: View {
    let groups: [String]
    @Binding var group: String?
    @Binding var favoritesOnly: Bool
    /// "movie" oder "series": für die Kindersicherung
    var kind: String? = nil
    /// Anzahl je Kategorie (Schlüssel: Kategoriename, dazu countAll/countFavorites)
    var counts: [String: Int] = [:]
    @ObservedObject private var parental = Parental.shared
    @State private var pinRequest: PinRequest?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("Kategorien")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.goldLight)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                row("Alle", icon: "square.grid.2x2", count: counts[countAll], selected: group == nil && !favoritesOnly) {
                    group = nil
                    favoritesOnly = false
                }
                row("Favoriten", icon: "star.fill", count: counts[countFavorites], selected: favoritesOnly) {
                    favoritesOnly = true
                    group = nil
                }
                ForEach(groups, id: \.self) { name in
                    let protected = kind.map { parental.isProtected($0, name) } ?? false
                    row(name, icon: protected ? "lock.fill" : nil, count: counts[name], selected: group == name && !favoritesOnly) {
                        if let k = kind, parental.isLocked(k, name) {
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
        .sheet(item: $pinRequest) { req in
            PinSheet(request: req)
        }
    }

    private func row(_ title: String, icon: String?, count: Int? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count = count {
                    Text(count.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? Theme.goldLight : Color.white.opacity(0.5))
                }
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
}

/// Suchfeld für die Spalten-Ansichten
struct InlineSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
    }
}

private struct ColumnDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
    }
}

// MARK: - Filme

struct MovieGridView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var parental = Parental.shared
    @State private var query = ""
    @State private var group: String?
    @State private var favoritesOnly = false
    @State private var counts: [String: Int] = [:]
    @AppStorage("sort.movies") private var sortRaw = SortMode.standard.rawValue

    /// Zahl der Filme je Kategorie (einmal berechnet, nicht bei jedem Tippen)
    private func countGroups() {
        let all = parental.visible("movie", store.movies)
        var c = Dictionary(grouping: all.compactMap(\.group), by: { $0 }).mapValues(\.count)
        c[countAll] = all.count
        c[countFavorites] = all.filter { store.isFavorite($0) }.count
        c[yearCategory] = all.filter { $0.year == currentYear }.count
        c[newCategory] = min(150, all.count)
        c[resumeCategory] = store.resumeEntries.filter { !$0.isEpisode && $0.pos >= 30 }.count
        counts = c
    }

    /// Aktuelles Jahr, z. B. 2026
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    /// Name der Sonder-Kategorie mit den Filmen aus diesem Jahr
    private var yearCategory: String { "Filme \(currentYear)" }

    private var groups: [String] {
        [resumeCategory, newCategory, yearCategory] + Array(Set(store.movies.compactMap(\.group))).sorted()
    }

    /// Gefiltert und sortiert (angefangene Filme bleiben in der Reihenfolge „zuletzt geschaut“)
    private var filtered: [Channel] {
        let list = unsorted
        if group == resumeCategory && !favoritesOnly { return list }
        return Sorter.sort(list, SortMode(rawValue: sortRaw) ?? .standard,
                           name: { $0.name }, added: { $0.added ?? 0 }, rating: { $0.rating ?? 0 }, year: { $0.year ?? 0 })
    }

    private var unsorted: [Channel] {
        if group == resumeCategory && !favoritesOnly {
            let byId = Dictionary(parental.visible("movie", store.movies).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return store.resumeEntries.compactMap { e -> Channel? in
                guard !e.isEpisode, e.pos >= 30, let id = Int(e.itemId), let movie = byId[id] else { return nil }
                return (query.isEmpty || movie.name.localizedCaseInsensitiveContains(query)) ? movie : nil
            }
        }
        if group == newCategory && !favoritesOnly {
            let all = parental.visible("movie", store.movies)
            let dated = all.filter { ($0.added ?? 0) > 0 }
            let newest = dated.count >= all.count / 2
                ? Array(dated.sorted { ($0.added ?? 0) > ($1.added ?? 0) }.prefix(150))
                : Array(all.suffix(150).reversed())
            return newest.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        }
        return parental.visible("movie", store.movies).filter { movie in
            let inGroup: Bool
            if group == yearCategory {
                inGroup = movie.year == currentYear
            } else {
                inGroup = group == nil || movie.group == group
            }
            return (!favoritesOnly || store.isFavorite(movie))
                && inGroup
                && (query.isEmpty || movie.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Group {
            if !store.isXtream {
                NeedsXtreamView()
            } else if store.moviesLoading && store.movies.isEmpty {
                ProgressView("Lade Filme …")
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        CategorySidebar(groups: groups, group: $group, favoritesOnly: $favoritesOnly, kind: "movie", counts: counts)
                            .frame(width: geo.size.width * 0.24)
                        ColumnDivider()
                        grid
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.78))
        .navigationTitle(group ?? (favoritesOnly ? "Favoriten" : "Filme"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { SortMenu(raw: $sortRaw) }
        }
        .task { await store.loadMoviesIfNeeded() }
        .task(id: store.movies.count) { countGroups() }
        .onAppear { countGroups() }
        .onChange(of: favoritesOnly) { _ in countGroups() }
    }

    private var grid: some View {
        let list = filtered
        return VStack(spacing: 8) {
            InlineSearchField(prompt: "Film suchen", text: $query)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            ScrollView {
                if let error = store.sectionError, store.movies.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.top, 30)
                }
                if list.isEmpty && !store.movies.isEmpty {
                    Text(favoritesOnly ? "Noch keine Film-Favoriten. Halte den Finger auf ein Poster."
                         : group == resumeCategory ? "Hier erscheinen Filme, die du angefangen hast."
                         : group == yearCategory ? "Dein Anbieter hat keine Filme mit dem Jahr \(currentYear) gekennzeichnet."
                         : "Keine Filme gefunden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 30)
                }
                LazyVGrid(columns: posterColumns, spacing: 16) {
                    ForEach(list) { movie in
                        NavigationLink(value: movie) {
                            PosterCard(title: movie.name, image: movie.logo, isFavorite: store.isFavorite(movie),
                                       progress: store.resumeEntry(movieId: movie.id).flatMap { $0.pos >= 30 ? $0.part : nil },
                                       rating: movie.rating)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                store.toggleFavorite(movie)
                            } label: {
                                Label(
                                    store.isFavorite(movie) ? "Aus Favoriten entfernen" : "Zu Favoriten",
                                    systemImage: store.isFavorite(movie) ? "star.slash" : "star"
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
            .refreshable { await store.loadMoviesIfNeeded(force: true) }
        }
    }
}

struct MovieDetailView: View {
    @EnvironmentObject private var store: AppStore
    let movie: Channel

    @State private var info: MediaInfo?
    @State private var loading = true
    @State private var request: PlayRequest?

    var body: some View {
        ZStack {
            backdrop
            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    PosterCard(title: "", image: info?.cover ?? movie.logo)
                        .frame(width: 150)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(movie.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        if let meta = info?.metaLine, !meta.isEmpty {
                            Text(meta)
                                .font(.subheadline)
                                .foregroundStyle(Theme.goldLight)
                        }

                        let score = (info?.score ?? 0) > 0 ? (info?.score ?? 0) : (movie.rating ?? 0)
                        if score > 0 {
                            Label("\(ratingText(score)) / 10", systemImage: "star.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.gold)
                        }

                        HStack(spacing: 12) {
                            let saved = store.resumeEntry(movieId: movie.id).flatMap { $0.pos >= 30 ? $0 : nil }
                            Button {
                                request = PlayRequest(channels: [movie], index: 0, isLive: false,
                                                      resume: [ResumeInfo.movie(movie)], startAt: saved?.pos ?? 0)
                            } label: {
                                Label(saved.map { "Weiter ab \(timeText($0.pos))" } ?? "Abspielen", systemImage: "play.fill")
                                    .font(.headline)
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(Theme.gold))
                            }
                            if saved != nil {
                                Button {
                                    request = PlayRequest(channels: [movie], index: 0, isLive: false,
                                                          resume: [ResumeInfo.movie(movie)], startAt: 0)
                                } label: {
                                    Label("Von vorne", systemImage: "arrow.counterclockwise")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(Capsule().fill(Color.white.opacity(0.12)))
                                }
                            }

                            Button {
                                store.toggleFavorite(movie)
                            } label: {
                                Image(systemName: store.isFavorite(movie) ? "star.fill" : "star")
                                    .font(.headline)
                                    .foregroundStyle(store.isFavorite(movie) ? Theme.gold : Color.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color.white.opacity(0.12)))
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)

                        if let trailer = info?.trailer {
                            TrailerButton(id: trailer)
                        }

                        if loading {
                            ProgressView().tint(.white)
                        }

                        if let plot = info?.plot {
                            Text(plot)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        if let director = info?.director {
                            detailLine("Regie", director)
                        }
                        if let cast = info?.cast {
                            let names = People.names(cast, max: 15)
                            if names.isEmpty {
                                detailLine("Besetzung", cast)
                            } else {
                                CastSection(names: names)
                                    .padding(.top, 6)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
        }
        .navigationTitle(movie.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            info = await store.movieInfo(movie.id)
            loading = false
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: false,
                         resume: req.resume, startAt: req.startAt)
                .environmentObject(store)
        }
    }

    private var backdrop: some View {
        ZStack {
            Theme.dark
            // Bild darf das Layout nicht vergrößern (sonst rutschen Staffeln/Knöpfe aus dem Bildschirm)
            Color.clear
                .overlay {
                    AsyncImage(url: info?.backdrop ?? info?.cover ?? movie.logo) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill().blur(radius: 18)
                        }
                    }
                }
                .clipped()
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        (Text(label + ": ").foregroundColor(Theme.goldLight) + Text(value).foregroundColor(.white.opacity(0.85)))
            .font(.subheadline)
    }
}

// MARK: - Serien

struct SeriesGridView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var parental = Parental.shared
    @State private var query = ""
    @State private var group: String?
    @State private var favoritesOnly = false
    @State private var counts: [String: Int] = [:]
    @AppStorage("sort.series") private var sortRaw = SortMode.standard.rawValue

    /// Zahl der Serien je Kategorie (einmal berechnet, nicht bei jedem Tippen)
    private func countGroups() {
        let all = parental.visibleSeries(store.seriesList)
        var c = Dictionary(grouping: all.compactMap(\.group), by: { $0 }).mapValues(\.count)
        c[countAll] = all.count
        c[countFavorites] = all.filter { store.isFavoriteSeries($0) }.count
        c[newCategory] = min(150, all.count)
        c[resumeCategory] = Set(store.resumeEntries.filter { $0.isEpisode }.compactMap { $0.seriesId }).count
        counts = c
    }

    private var groups: [String] {
        [resumeCategory, newCategory] + Array(Set(store.seriesList.compactMap(\.group))).sorted()
    }

    /// Gefiltert und sortiert (angefangene Serien bleiben in der Reihenfolge „zuletzt geschaut“)
    private var filtered: [SeriesItem] {
        let list = unsorted
        if group == resumeCategory && !favoritesOnly { return list }
        return Sorter.sort(list, SortMode(rawValue: sortRaw) ?? .standard,
                           name: { $0.name }, added: { $0.added }, rating: { $0.rating }, year: { $0.year ?? 0 })
    }

    private var unsorted: [SeriesItem] {
        if group == resumeCategory && !favoritesOnly {
            let byId = Dictionary(parental.visibleSeries(store.seriesList).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return store.resumeEntries.compactMap { e -> SeriesItem? in
                guard e.isEpisode, let sid = e.seriesId, let show = byId[sid] else { return nil }
                return (query.isEmpty || show.name.localizedCaseInsensitiveContains(query)) ? show : nil
            }
        }
        if group == newCategory && !favoritesOnly {
            let all = parental.visibleSeries(store.seriesList)
            let dated = all.filter { $0.added > 0 }
            let newest = dated.count >= all.count / 2
                ? Array(dated.sorted { $0.added > $1.added }.prefix(150))
                : Array(all.suffix(150).reversed())
            return newest.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        }
        return parental.visibleSeries(store.seriesList).filter { show in
            (!favoritesOnly || store.isFavoriteSeries(show))
                && (group == nil || show.group == group)
                && (query.isEmpty || show.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Group {
            if !store.isXtream {
                NeedsXtreamView()
            } else if store.seriesLoading && store.seriesList.isEmpty {
                ProgressView("Lade Serien …")
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        CategorySidebar(groups: groups, group: $group, favoritesOnly: $favoritesOnly, kind: "series", counts: counts)
                            .frame(width: geo.size.width * 0.24)
                        ColumnDivider()
                        grid
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.78))
        .navigationTitle(group ?? (favoritesOnly ? "Favoriten" : "Serien"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { SortMenu(raw: $sortRaw) }
        }
        .task { await store.loadSeriesIfNeeded() }
        .task(id: store.seriesList.count) { countGroups() }
        .onAppear { countGroups() }
        .onChange(of: favoritesOnly) { _ in countGroups() }
    }

    private var grid: some View {
        let list = filtered
        return VStack(spacing: 8) {
            InlineSearchField(prompt: "Serie suchen", text: $query)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            ScrollView {
                if let error = store.sectionError, store.seriesList.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.top, 30)
                }
                if list.isEmpty && !store.seriesList.isEmpty {
                    Text(favoritesOnly ? "Noch keine Serien-Favoriten. Halte den Finger auf ein Poster."
                         : group == resumeCategory ? "Hier erscheinen Serien, die du angefangen hast." : "Keine Serien gefunden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 30)
                }
                LazyVGrid(columns: posterColumns, spacing: 16) {
                    ForEach(list) { show in
                        NavigationLink(value: show) {
                            let saved = store.resumeEntry(seriesId: show.id)
                            PosterCard(title: show.name, image: show.cover, isFavorite: store.isFavoriteSeries(show),
                                       progress: saved.flatMap { $0.next ? nil : $0.part },
                                       subtitle: saved.map { "S\($0.season ?? 1) F\($0.number ?? 0) · \($0.leftText)" },
                                       rating: show.rating)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                store.toggleFavoriteSeries(show)
                            } label: {
                                Label(
                                    store.isFavoriteSeries(show) ? "Aus Favoriten entfernen" : "Zu Favoriten",
                                    systemImage: store.isFavoriteSeries(show) ? "star.slash" : "star"
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
            .refreshable { await store.loadSeriesIfNeeded(force: true) }
        }
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject private var store: AppStore
    let series: SeriesItem

    @State private var episodes: [Episode] = []
    @State private var info: MediaInfo?
    @State private var loading = true
    @State private var errorText: String?
    @State private var season = 1
    @State private var request: PlayRequest?
    @State private var askEpisode: Episode?

    private var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted()
    }

    /// Alle Folgen abspielen (damit nach dem Ende automatisch die nächste kommt, auch über Staffeln hinweg)
    private func play(_ episode: Episode, from start: Double?) {
        guard let i = episodes.firstIndex(of: episode) else { return }
        request = PlayRequest(channels: episodes.map(\.asChannel), index: i, isLive: false,
                              resume: episodes.map { ResumeInfo.episode($0, series: series) }, startAt: start)
    }

    /// Nach dem Schauen die Staffel der zuletzt gesehenen Folge zeigen
    private func jumpToLastSeason() {
        if let last = store.resumeEntry(seriesId: series.id), let s = last.season, seasons.contains(s) {
            season = s
        }
    }

    var body: some View {
        let current = episodes.filter { $0.season == season }

        ZStack {
            backdrop
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 0) {
                    // Links: Poster und Beschreibung
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            PosterCard(title: "", image: info?.cover ?? series.cover)
                                .frame(width: 120)
                            Text(series.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            if let meta = info?.metaLine, !meta.isEmpty {
                                Text(meta)
                                    .font(.caption)
                                    .foregroundStyle(Theme.goldLight)
                            }
                            let score = (info?.score ?? 0) > 0 ? (info?.score ?? 0) : series.rating
                            if score > 0 {
                                Label("\(ratingText(score)) / 10", systemImage: "star.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.gold)
                            }
                            Button {
                                store.toggleFavoriteSeries(series)
                            } label: {
                                Label(store.isFavoriteSeries(series) ? "Favorit" : "Zu Favoriten",
                                      systemImage: store.isFavoriteSeries(series) ? "star.fill" : "star")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(store.isFavoriteSeries(series) ? Theme.gold : Color.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            if let trailer = info?.trailer {
                                TrailerButton(id: trailer, compact: true)
                            }
                            if let last = store.resumeEntry(seriesId: series.id),
                               let ep = episodes.first(where: { $0.id == last.itemId }) {
                                Button {
                                    play(ep, from: last.next ? 0 : last.pos)
                                } label: {
                                    Label(last.next ? "Nächste: S\(ep.season) F\(ep.number)"
                                          : "Weiter: S\(ep.season) F\(ep.number) ab \(timeText(last.pos))",
                                          systemImage: "play.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Theme.gold))
                                }
                                .buttonStyle(.plain)
                            }
                            if let plot = info?.plot {
                                Text(plot)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            if let cast = info?.cast {
                                let names = People.names(cast, max: 10)
                                if names.isEmpty {
                                    (Text("Besetzung: ").foregroundColor(Theme.goldLight) + Text(cast).foregroundColor(.white.opacity(0.8)))
                                        .font(.caption)
                                } else {
                                    CastSection(names: names, compact: true)
                                        .padding(.top, 4)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .frame(width: geo.size.width * 0.34)

                    ColumnDivider()

                    // Rechts: Staffeln und Folgen
                    VStack(alignment: .leading, spacing: 10) {
                        // Staffeln immer zeigen (auch bei nur einer), gewählte Staffel in den sichtbaren Bereich holen
                        if !seasons.isEmpty {
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(seasons, id: \.self) { s in
                                            Button {
                                                season = s
                                            } label: {
                                                Text("Staffel \(s)")
                                                    .font(.subheadline.weight(.medium))
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 8)
                                                    .background(Capsule().fill(s == season ? Theme.gold : Theme.panel))
                                                    .foregroundStyle(s == season ? Color.black : Color.white)
                                            }
                                            .buttonStyle(.plain)
                                            .id(s)
                                        }
                                    }
                                }
                                .frame(height: 40)
                                .onAppear { proxy.scrollTo(season, anchor: .center) }
                                .onChange(of: season) { s in
                                    withAnimation { proxy.scrollTo(s, anchor: .center) }
                                }
                            }
                        }

                        if loading {
                            HStack {
                                Spacer()
                                ProgressView("Lade Folgen …")
                                Spacer()
                            }
                            .padding(.top, 20)
                        }

                        if let errorText = errorText {
                            Text(errorText)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(current) { episode in
                                    EpisodeRow(episode: episode,
                                               saved: store.resumeEntry(for: ResumeInfo.episode(episode, series: series)),
                                               seen: store.seenState(for: episode)) { hasProgress in
                                        if hasProgress {
                                            askEpisode = episode
                                        } else {
                                            play(episode, from: 0)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard episodes.isEmpty else { return }
            do {
                let details = try await store.seriesDetails(series.id)
                episodes = details.episodes
                info = details.info
                season = episodes.first?.season ?? 1
                jumpToLastSeason()
                if episodes.isEmpty { errorText = "Keine Folgen gefunden." }
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
        }
        .confirmationDialog(askEpisode?.title ?? "", isPresented: Binding(
            get: { askEpisode != nil },
            set: { if !$0 { askEpisode = nil } }
        ), titleVisibility: .visible, presenting: askEpisode) { ep in
            Button("Fortsetzen ab \(timeText(store.resumePosition(for: ResumeInfo.episode(ep, series: series))))") {
                play(ep, from: nil)
            }
            Button("Von vorne") { play(ep, from: 0) }
            Button("Abbrechen", role: .cancel) {}
        }
        .fullScreenCover(item: $request, onDismiss: { jumpToLastSeason() }) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: false,
                         resume: req.resume, startAt: req.startAt)
                .environmentObject(store)
        }
    }

    private var backdrop: some View {
        ZStack {
            Theme.dark
            // Bild darf das Layout nicht vergrößern (sonst rutschen Staffeln/Knöpfe aus dem Bildschirm)
            Color.clear
                .overlay {
                    AsyncImage(url: info?.backdrop ?? info?.cover ?? series.cover) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill().blur(radius: 18)
                        }
                    }
                }
                .clipped()
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// Eine Folge in der Liste: gesehen (Haken), angefangen (Balken) oder als Nächstes dran
struct EpisodeRow: View {
    let episode: Episode
    let saved: ResumeEntry?
    var seen: SeenState? = nil
    /// true = es gibt einen gespeicherten Stand
    let onTap: (Bool) -> Void

    /// Angefangen laut „Weiter ansehen“
    private var part: Double? {
        guard let s = saved, !s.next, s.pos >= 30 else { return nil }
        return s.part
    }

    private var isDone: Bool { part == nil && (seen?.d ?? false) }
    private var isNext: Bool { part == nil && !isDone && (saved?.next ?? false) }
    /// Angefangen, aber nicht mehr in „Weiter ansehen“
    private var seenPart: Double? {
        guard part == nil, !isDone, !isNext, let s = seen, s.p >= 3 else { return nil }
        return Double(s.p) / 100
    }

    var body: some View {
        Button {
            onTap(part != nil)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("\(episode.number)")
                        .font(.headline)
                        .foregroundStyle(isDone ? Theme.gold.opacity(0.6) : Theme.gold)
                        .frame(width: 32)
                    Text(episode.title)
                        .foregroundStyle(isDone ? Color.white.opacity(0.55) : Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if isDone {
                        Label("Gesehen", systemImage: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.goldLight)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.gold.opacity(0.22)))
                    } else if isNext {
                        Label("Als Nächstes", systemImage: "play.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.gold))
                    } else if let saved = saved, part != nil {
                        Text(saved.leftText)
                            .font(.caption2)
                            .foregroundStyle(Theme.gold)
                    } else if seenPart != nil {
                        Text("Angefangen")
                            .font(.caption2)
                            .foregroundStyle(Theme.gold)
                    }
                    Image(systemName: isDone ? "arrow.counterclockwise.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isDone ? Theme.gold.opacity(0.6) : Theme.gold)
                }
                if let p = part ?? seenPart {
                    ProgressStrip(part: p)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(alignment: .leading) {
                if part != nil || seenPart != nil || isNext {
                    Rectangle()
                        .fill(isNext ? Theme.goldLight : Theme.gold)
                        .frame(width: 4)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TV-Programm (EPG)

struct EPGListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var group: String?
    @State private var request: PlayRequest?

    private var groups: [String] {
        Array(Set(store.channels.compactMap(\.group))).sorted()
    }

    private var filtered: [Channel] {
        store.channels.filter { channel in
            (group == nil || channel.group == group)
                && (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let list = filtered
        Group {
            if !store.isXtream {
                NeedsXtreamView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if groups.count > 1 {
                            CategoryMenu(groups: groups, selection: $group)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, channel in
                            EPGRow(channel: channel) {
                                request = PlayRequest(channels: list, index: index, isLive: true)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("TV-Programm")
        .searchable(text: $query, prompt: "Sender suchen")
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: true)
                .environmentObject(store)
        }
    }
}

struct EPGRow: View {
    @EnvironmentObject private var store: AppStore
    let channel: Channel
    let onTap: () -> Void

    @State private var entries: [EPGEntry] = []
    @State private var loaded = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                ChannelLogo(url: channel.logo)
                VStack(alignment: .leading, spacing: 5) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let now = entries.first {
                        HStack(spacing: 6) {
                            Text(now.timeRange)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.gold)
                            Text(now.title)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        ProgressView(value: now.progress)
                            .tint(Theme.gold)
                        if entries.count > 1 {
                            Text("Danach: \(entries[1].timeRange) \(entries[1].title)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(loaded ? "Kein Programm verfügbar" : "Lade Programm …")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gold.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: channel.id) {
            entries = await store.shortEPG(streamId: channel.id)
            loaded = true
        }
    }
}
