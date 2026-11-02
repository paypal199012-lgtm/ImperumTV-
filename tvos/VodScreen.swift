import SwiftUI

/// Plakat mit Bewertung und Titel (Filme, Serien)
struct PosterCard: View {
    let item: TVItem
    var fav = false
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

    enum F: Hashable { case search, sort, cat(String), item(Int) }
    @FocusState private var focus: F?
    @State private var cat = "all"
    @State private var query = ""
    @State private var sort = 0

    private static let sorts = ["Standard", "Neueste", "A–Z", "Bewertung"]
    private var title: String { kind == .movie ? "Filme" : "Serien" }

    private var items: [TVItem] {
        let all = store.items(kind)
        var l: [TVItem]
        switch cat {
        case "all": l = all
        case "fav": l = all.filter { store.isFav($0, kind) }
        case "new": l = all.sorted { $0.added > $1.added }.prefix(200).map { $0 }
        case "year": let y = Calendar.current.component(.year, from: Date()); l = all.filter { $0.year == y }
        default: l = all.filter { $0.cat == cat }
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
                    row("all", "☰ Alle", store.items(kind).count)
                    row("fav", "★ Favoriten", store.items(kind).filter { store.isFav($0, kind) }.count)
                    SectionHead(text: "Neu & Stöbern")
                    row("new", "Zuletzt hinzugefügt", nil)
                    row("year", "\(title) \(Calendar.current.component(.year, from: Date()))", nil)
                    SectionHead(text: "Kategorien")
                    ForEach(store.cats(kind)) { c in row(c.id, c.name, nil) }
                }
                .padding(.vertical, 20).padding(.horizontal, 10)
            }
            .place(4, 100, 416, 970)

            ScrollView(.vertical, showsIndicators: false) {
                if list.isEmpty {
                    Text(cat == "fav" ? "Noch keine Favoriten. Auf einem Plakat OK lange drücken." : "Nichts gefunden")
                        .font(UI.font(28)).foregroundColor(UI.muted).padding(40)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 22), count: 6), alignment: .leading, spacing: 26) {
                    ForEach(list) { it in
                        PosterCard(item: it, fav: store.isFav(it, kind)) { open(it) }
                            .contextMenu {
                                Button(store.isFav(it, kind) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen") { store.toggleFav(it, kind) }
                            }
                            .focused($focus, equals: .item(it.id))
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 14)
            }
            .place(424, 100, 1470, 980)
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
        CatRow(name: name, count: count, active: cat == id, size: 28) { cat = id }
            .focused($focus, equals: .cat(id))
    }

    private func open(_ it: TVItem) {
        if kind == .series { nav.push(.seriesDetail(it)); return }
        guard let u = store.url(it, .movie) else { return }
        engine.play(u, item: it, kind: .movie, fallback: store.altURL(it))
        nav.push(.player)
    }
}

// MARK: - Serie: Staffeln und Folgen

struct SeriesScreen: View {
    let series: TVItem
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var loading = true

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    private var current: [Episode] { episodes.filter { $0.season == season }.sorted { $0.number < $1.number } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtView(art: series.art, poster: true)
                .frame(width: 360, height: 540).clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.6), radius: 20)
                .place(80, 120, 360, 540)
            VStack(alignment: .leading, spacing: 12) {
                Text(series.name).font(UI.font(50, .bold)).foregroundColor(UI.gold).lineLimit(2)
                HStack(spacing: 20) {
                    if series.rating > 0 { Text("★ " + String(format: "%.1f", series.rating)).foregroundColor(UI.gold) }
                    if let y = series.year { Text(String(y)) }
                    Text("\(episodes.count) Folgen")
                }
                .font(UI.font(26)).foregroundColor(UI.muted)
            }
            .place(500, 110, 1340, 150)

            if loading {
                ProgressView().scaleEffect(1.6).tint(UI.gold).place(500, 300, 200, 100)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: { Text("Staffel \(s)").font(UI.font(24, .bold)).padding(.horizontal, 24).frame(height: 52) }
                                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: s == season ? UI.tan(0.3) : .white.opacity(0.08), ring: false, solid: true))
                        }
                    }
                    .padding(10)
                }
                .place(490, 270, 1390, 80)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(current.enumerated()), id: \.element.id) { _, e in
                            Button { play(e) } label: {
                                HStack(spacing: 20) {
                                    Text("\(e.number)").font(UI.font(30, .bold)).foregroundColor(UI.gold).frame(width: 60)
                                    Text(e.title).font(UI.font(27, .medium)).lineLimit(1)
                                    Spacer()
                                    Icon("play", 30)
                                }
                                .padding(.horizontal, 20).frame(height: 76)
                            }
                            .buttonStyle(GoldStyle(normal: .black.opacity(0.3)))
                        }
                    }
                    .padding(12)
                }
                .place(490, 360, 1390, 700)
            }
        }
        .frame(width: 1920, height: 1080)
        .task {
            episodes = await store.episodes(series)
            season = seasons.first ?? 1
            loading = false
        }
    }

    private func play(_ e: Episode) {
        let all = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        engine.episodes = all
        engine.item = series
        engine.index = all.firstIndex(of: e) ?? 0
        engine.playEpisode(engine.index)
        nav.push(.player)
    }
}
