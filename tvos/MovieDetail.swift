import SwiftUI

/// Film-Detailseite wie auf Android: Hintergrund, Plakat, Titel, Jahr · Länge · Genre, Bewertung, Beschreibung, Knöpfe
struct MovieDetailScreen: View {
    let movie: TVItem
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var resume: ResumeBook
    @State private var info: MediaInfo?
    @State private var loading = true
    enum F: Hashable { case play, restart, fav }
    @FocusState private var focus: F?

    private var saved: TVResumeEntry? { resume.entry(store.sourceName, .movie, movie.id) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ArtView(art: info?.cover.map { .url($0) } ?? movie.art, poster: true)
                .frame(width: 380, height: 570).clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.6), radius: 24)
                .place(90, 130, 380, 570)

            VStack(alignment: .leading, spacing: 16) {
                Text(movie.name).font(UI.font(54, .bold)).foregroundColor(UI.gold).lineLimit(2)
                HStack(spacing: 22) {
                    let score = movie.rating > 0 ? movie.rating : (info?.score ?? 0)
                    if score > 0 {
                        Text("★ " + String(format: "%.1f", score)).font(UI.font(26, .bold)).foregroundColor(UI.dark)
                            .padding(.horizontal, 14).padding(.vertical, 4)
                            .background(Capsule().fill(UI.gold))
                    }
                    if let meta = info?.metaLine, !meta.isEmpty {
                        Text(meta).font(UI.font(26)).foregroundColor(Color(rgb: 0xd6d1c6))
                    } else if let y = movie.year {
                        Text(String(y)).font(UI.font(26)).foregroundColor(Color(rgb: 0xd6d1c6))
                    }
                }
                if loading {
                    ProgressView().tint(UI.gold).padding(.top, 20)
                } else {
                    Text(info?.plot ?? "Keine Beschreibung vorhanden.")
                        .font(UI.font(26)).foregroundColor(UI.text.opacity(0.9)).lineSpacing(6).lineLimit(7)
                        .frame(maxWidth: 1250, alignment: .leading)
                    if let d = info?.director, !d.isEmpty {
                        (Text("Regie: ").foregroundColor(UI.muted) + Text(d)).font(UI.font(23)).lineLimit(1)
                    }
                    if let c = info?.cast, !c.isEmpty {
                        (Text("Mit: ").foregroundColor(UI.muted) + Text(c)).font(UI.font(23)).lineLimit(2)
                            .frame(maxWidth: 1250, alignment: .leading)
                    }
                }

                if let s = saved {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(UI.gold2).frame(width: g.size.width * s.part)
                        }
                    }
                    .frame(width: 520, height: 6).padding(.top, 8)
                }

                HStack(spacing: 18) {
                    Button { play(from: saved?.pos ?? 0) } label: {
                        pill(saved.map { "▶ Fortsetzen ab \(timeText($0.pos))" } ?? "▶ Abspielen")
                    }
                    .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                    .focused($focus, equals: .play)
                    if saved != nil {
                        Button { play(from: 0) } label: { pill("↺ Von vorne") }
                            .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.1), ring: false, solid: true))
                            .focused($focus, equals: .restart)
                    }
                    Button { store.toggleFav(movie, .movie) } label: {
                        pill(store.isFav(movie, .movie) ? "★ Favorit entfernen" : "☆ Favorit")
                    }
                    .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.1), ring: false, solid: true))
                    .focused($focus, equals: .fav)
                }
                .padding(.top, 14)
            }
            .place(530, 130, 1330, 880)
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, .play)
        .task {
            info = await store.movieInfo(movie)
            if let i = info { GenreBook.shared.learn(.movie, movie.id, genre: i.genre, plot: i.plot) }
            loading = false
        }
    }

    @ViewBuilder private var backdrop: some View {
        if let b = info?.backdrop {
            AsyncImage(url: b) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
                .frame(width: 1920, height: 1080).clipped().opacity(0.35)
                .overlay(LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
        } else if case .demo(_, let c) = movie.art {
            RadialGradient(colors: [Color(rgb: c).opacity(0.55), .clear], center: UnitPoint(x: 0.7, y: 0.3), startRadius: 0, endRadius: 1300)
                .frame(width: 1920, height: 1080)
        }
    }

    private func pill(_ t: String) -> some View {
        Text(t).font(UI.font(28, .bold)).padding(.horizontal, 32).frame(height: 64)
    }

    private func play(from pos: Double) {
        guard let u = store.url(movie, .movie) else { return }
        engine.play(u, item: movie, kind: .movie, fallback: store.altURL(movie), startAt: pos)
        nav.push(.player)
    }
}
