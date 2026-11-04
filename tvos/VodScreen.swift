import SwiftUI

/// Plakat mit Bewertung und Titel (Filme, Serien)
struct PosterCard: View {
    let item: TVItem
    var fav = false
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ArtView(art: item.art, poster: true)
                    .frame(width: 200, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if item.rating > 0 {
                            Text("★ " + String(format: "%.1f", item.rating))
                                .font(UI.font(21, .semibold)).foregroundColor(UI.gold)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.7)))
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if fav { Text("★").font(UI.font(26)).foregroundColor(UI.gold2).padding(10) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let b = badge {
                            Text(b).font(UI.font(18, .heavy)).foregroundColor(UI.dark)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(UI.gold)).padding(8)
                        }
                    }
                Text(item.name).font(UI.font(24)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(width: 200, height: 62, alignment: .topLeading)
            }
            .padding(10)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 12)), scale: 1.05))
    }
}

struct VodScreen: View {
    let kind: MediaKind
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook
    @ObservedObject private var genres = GenreBook.shared

    enum F: Hashable { case search, sort, cat(String), item(Int) }
    @FocusState private var focus: F?
    @State private var cat = "all"
    @State private var query = ""
    @State private var sort = 0
    @State private var askPin = false

    private static let sorts = ["Standard", "Neueste", "A–Z", "Bewertung"]
    private var title: String { kind == .movie ? "Filme" : "Serien" }

    private var src: String { store.sourceName }
    private var started: Set<Int> {
        Set(resume.list(source: src).filter { $0.kind == (kind == .movie ? "movie" : "series") }.map(\.itemId))
    }

    private var items: [TVItem] {
        _ = store.unlockTick
        let all = store.visible(kind)
        var l: [TVItem]
        switch cat {
        case "all": l = all
        case "fav": l = all.filter { store.isFav($0, kind) }
        case "resume": let s = started; l = all.filter { s.contains($0.id) }
        case "seen": l = all.filter { resume.isSeen(src, movie: $0.id) }
        case "unseen": l = all.filter { !resume.isSeen(src, movie: $0.id) }
        case "neweps": l = all.filter { store.newEpisodes.contains($0.id) }
        case "new": l = all.sorted { $0.added > $1.added }.prefix(200).map { $0 }
        case "year": let y = Calendar.current.component(.year, from: Date()); l = all.filter { $0.year == y }
        case let c where c.hasPrefix("g:"):
            let bit = 1 << (Int(c.dropFirst(2)) ?? 0)
            l = all.filter { genres.mask($0, kind, store) & bit != 0 }
        default: l = store.catLocked(kind, cat) ? [] : store.items(kind).filter { $0.cat == cat }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { l = l.filter { $0.name.lowercased().contains(q) } }
        switch sort {
        case 1: l.sort { $0.added > $1.added }
        case 2: l.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case 3: l.sort { $0.rating > $1.rating }
        default: break
        }
        return l
    }

    var body: some View {
        let list = items
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: title)
            Text("OK: Öffnen · lange drücken: Favorit").font(UI.font(24)).foregroundColor(UI.muted)
                .place(1100, 44, 570, 34, alignment: .topTrailing)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    TextField("Suchen", text: $query).font(UI.font(27, .medium)).focused($focus, equals: .search)
                    CatRow(name: "Sortieren: \(Self.sorts[sort])", icon: nil, gold: true) { sort = (sort + 1) % Self.sorts.count }
                        .focused($focus, equals: .sort)
                    SectionHead(text: "Für dich")
                    row("all", "☰ Alle", store.visible(kind).count)
                    row("fav", "★ Favoriten", store.items(kind).filter { store.isFav($0, kind) }.count)
                    row("resume", "▶ Weiter ansehen", started.count)
                    if kind == .movie {
                        row("seen", "✓ Gesehen", store.items(kind).filter { resume.isSeen(src, movie: $0.id) }.count)
                    }
                    SectionHead(text: "Neu & Stöbern")
                    if kind == .series { row("neweps", "● Neue Folgen", store.newEpisodes.count) }
                    row("new", "Zuletzt hinzugefügt", nil)
                    if kind == .movie { row("unseen", "Nicht gesehen", nil) }
                    let gc = genres.counts(kind, store.visible(kind), store)
                    if gc.contains(where: { $0 > 0 }) || !genres.progressText.isEmpty {
                        SectionHead(text: "Genres" + (kind == .movie && !genres.progressText.isEmpty ? " · wird ergänzt " + genres.progressText : ""))
                        ForEach(Array(GenreMask.names.enumerated()).filter { gc[$0.offset] > 0 }, id: \.offset) { i, n in
                            row("g:\(i)", n, gc[i])
                        }
                    }
                    SectionHead(text: "Kategorien")
                    ForEach(store.visibleCats(kind)) { c in
                        row(c.id, (store.catLocked(kind, c.id) ? "🔒 " : "") + c.name, nil)
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 10)
            }
            .place(4, 100, 416, 970)

            ScrollView(.vertical, showsIndicators: false) {
                if list.isEmpty {
                    Text(store.catLocked(kind, cat) ? "🔒 Diese Kategorie ist gesperrt. Links auf die Kategorie drücken und PIN eingeben."
                         : cat == "fav" ? "Noch keine Favoriten. Auf einem Plakat OK lange drücken." : "Nichts gefunden")
                        .font(UI.font(28)).foregroundColor(UI.muted).padding(40)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 22), count: 6), alignment: .leading, spacing: 26) {
                    ForEach(list) { it in
                        PosterCard(item: it, fav: store.isFav(it, kind),
                                   badge: kind == .series && store.newEpisodes.contains(it.id) ? "NEU" : (kind == .movie && resume.isSeen(src, movie: it.id) ? "✓" : nil)) { open(it) }
                            .contextMenu {
                                Button(store.isFav(it, kind) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen") { store.toggleFav(it, kind) }
                                if kind == .movie {
                                    Button(resume.isSeen(src, movie: it.id) ? "Als nicht gesehen markieren" : "Als gesehen markieren") { resume.toggleSeen(src, movie: it.id) }
                                }
                            }
                            .focused($focus, equals: .item(it.id))
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 14)
            }
            .place(424, 100, 1470, 980)

            if askPin {
                PinPrompt(title: "PIN eingeben") { pin in
                    askPin = false
                    if let p = pin, Parental.check(p) { store.unlock() }
                }
            }
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, nav.lastFocus[title].flatMap { Int($0) }.map { F.item($0) } ?? .item(list.first?.id ?? 0))
        .onChange(of: focus) { _, f in
            switch f {
            case .cat(let c)?: cat = c
            case .item(let id)?: nav.lastFocus[title] = String(id)
            default: break
            }
        }
    }

    private func row(_ id: String, _ name: String, _ count: Int?) -> some View {
        CatRow(name: name, count: count, active: cat == id, size: 28) {
            cat = id
            if store.catLocked(kind, id) { askPin = true }
        }
            .focused($focus, equals: .cat(id))
    }

    private func open(_ it: TVItem) {
        if kind == .series { nav.push(.seriesDetail(it)); return }
        nav.push(.movieDetail(it))
    }
}

// MARK: - Serie: wie auf Android – Plakat, Titel, Bewertung, Beschreibung, Staffeln, Folgen als Kacheln

struct SeriesScreen: View {
    let series: TVItem
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook
    @State private var episodes: [Episode] = []
    @State private var info: MediaInfo?
    @State private var season = 1
    @State private var loading = true
    enum F: Hashable { case resume, fav, season(Int), ep(String) }
    @FocusState private var focus: F?

    private static let colors: [UInt32] = [0x2f5070, 0x4c6a2c, 0x5c2f72, 0x6f5530, 0x7a2f3a, 0x2f6a66]
    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    private var current: [Episode] { episodes.filter { $0.season == season }.sorted { $0.number < $1.number } }
    private var sortedAll: [Episode] { episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) } }

    var body: some View {
        let saved = resume.entry(store.sourceName, .series, series.id)
        ZStack(alignment: .topLeading) {
            // großer, blasser Titel im Hintergrund
            Text(series.name)
                .font(.system(size: 230, weight: .heavy))
                .foregroundColor(.white.opacity(0.045))
                .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center)
                .place(300, 150, 1560, 620, alignment: .center)

            ArtView(art: info?.cover.map { .url($0) } ?? series.art, poster: true)
                .frame(width: 304, height: 444).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(UI.tan(0.45), lineWidth: 2))
                .shadow(color: .black.opacity(0.6), radius: 18)
                .place(90, 130, 304, 444)

            VStack(alignment: .leading, spacing: 10) {
                Text(series.name).font(UI.font(60, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: 18) {
                    let score = series.rating > 0 ? series.rating : (info?.score ?? 0)
                    if score > 0 { Text("★ " + String(format: "%.1f", score)).font(UI.font(28, .bold)).foregroundColor(UI.gold2) }
                    let meta = [info?.year ?? series.year.map { String($0) }, info?.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).font(UI.font(28)).foregroundColor(UI.gold) }
                }
                if let p = info?.plot, !p.isEmpty {
                    Text(p).font(UI.font(24)).foregroundColor(.white.opacity(0.85)).lineLimit(2)
                        .frame(maxWidth: 1400, alignment: .leading)
                }
                HStack(spacing: 18) {
                    if let s = saved, let ep = s.episode, ep < sortedAll.count {
                        Button { play(sortedAll[ep], startAt: s.pos) } label: {
                            pill("▶ Weiter: " + (s.episodeTitle ?? "Folge \(ep + 1)") + (s.pos > 30 ? " ab \(timeText(s.pos))" : ""))
                        }
                        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                        .focused($focus, equals: .resume)
                    }
                    Button { store.toggleFav(series, .series) } label: {
                        pill(store.isFav(series, .series) ? "★  Favorit entfernen" : "☆  Zu Favoriten")
                    }
                    .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.08), ring: false, solid: true))
                    .focused($focus, equals: .fav)
                }
                .padding(.top, 6)
            }
            .place(430, 130, 1440, 300)

            if loading {
                ProgressView().scaleEffect(1.6).tint(UI.gold).place(90, 620, 300, 100)
            } else {
                // Staffeln
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: {
                                Text("Staffel \(s)").font(UI.font(26)).padding(.horizontal, 26).frame(height: 55)
                            }
                            .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: s == season ? UI.tan(0.45) : .white.opacity(0.08), ring: false, solid: true))
                            .focused($focus, equals: .season(s))
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 8)
                }
                .place(86, 590, 1760, 72)

                // Folgen als Kacheln
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(Array(current.enumerated()), id: \.element.id) { i, e in
                            EpisodeCard(ep: e, color: Self.colors[(e.number - 1 + Self.colors.count * 10) % Self.colors.count],
                                        minutes: store.episodeMinutes(e), seen: resume.isSeen(store.sourceName, episode: e.id)) { play(e) }
                                .focused($focus, equals: .ep(e.id))
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 14)
                }
                .place(82, 666, 1838, 300)
            }
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, saved != nil ? .resume : .ep(current.first?.id ?? ""))
        .onChange(of: focus) { _, f in if case .season(let s)? = f { season = s } }
        .task {
            let r = await store.seriesDetails(series)
            episodes = r.episodes; info = r.info
            if let i = r.info { GenreBook.shared.learn(.series, series.id, genre: i.genre, plot: i.plot) }
            store.markSeriesOpened(series, count: r.episodes.count)
            if let s = saved, let ep = s.episode, ep < sortedAll.count { season = sortedAll[ep].season } else { season = seasons.first ?? 1 }
            loading = false
        }
    }

    private func pill(_ t: String) -> some View {
        Text(t).font(UI.font(30, .bold)).lineLimit(1).padding(.horizontal, 40).frame(height: 72)
    }

    private func play(_ e: Episode, startAt: Double = 0) {
        let all = sortedAll
        engine.episodes = all
        engine.item = series
        engine.index = all.firstIndex(of: e) ?? 0
        let book = resume, src = store.sourceName, eng = engine
        engine.onEpisodeEnd = { eng.saveResume(book, source: src) }
        engine.playEpisode(engine.index, startAt: startAt)
        nav.push(.player)
    }
}

/// Folge als Kachel: Bild (oder Farbfläche mit „F1“), darunter „1. Titel“ und Länge
private struct EpisodeCard: View {
    let ep: Episode
    let color: UInt32
    let minutes: Int?
    var seen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { CardBody(ep: ep, color: color, minutes: minutes, seen: seen) }
            .buttonStyle(PlainPress())
    }

    private struct CardBody: View {
        let ep: Episode
        let color: UInt32
        let minutes: Int?
        let seen: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let u = ep.image {
                        AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { tile }
                    } else { tile }
                }
                .frame(width: 340, height: 190)
                .overlay(alignment: .topTrailing) {
                    if seen {
                        Text("✓ Gesehen").font(UI.font(16, .heavy)).foregroundColor(UI.dark)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(UI.gold)).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? UI.gold : .white.opacity(0.08), lineWidth: focused ? 5 : 1).padding(focused ? -3 : 0))
                .shadow(color: focused ? UI.gold.opacity(0.45) : .clear, radius: 14)
                Text("\(ep.number). \(ep.title)")
                    .font(UI.font(24, focused ? .bold : .regular))
                    .foregroundColor(focused ? UI.gold : UI.text)
                    .lineLimit(1).frame(width: 340, alignment: .leading)
                    .padding(.top, 4)
                if let m = minutes {
                    Text("\(m) Min").font(UI.font(19)).foregroundColor(UI.muted)
                }
            }
            .scaleEffect(focused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
        }

        private var tile: some View {
            ZStack {
                LinearGradient(colors: [Color(rgb: color), Color(rgb: 0x111418)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("F\(ep.number)").font(.system(size: 48, weight: .heavy)).foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            }
        }
    }
}
