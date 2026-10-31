import SwiftUI

// MARK: - „Mehr davon“: ähnliche Filme
// Gleiche Filmreihe (gemeinsame Wörter im Titel) zuerst, dann gleiche Kategorie;
// ungesehene, gut bewertete und zeitlich nahe Filme weiter vorn.

enum SimilarMovies {
    private static let stop: Set<String> = ["der", "die", "das", "und", "the", "and", "von", "mit", "ein", "eine", "for", "des", "dem", "den",
                                            "auf", "aus", "part", "teil", "film", "movie"]
    private static let noise: Set<String> = ["4k", "uhd", "fhd", "hd", "sd", "hevc", "multi", "dual", "ger", "deu", "dt", "eng"]

    static func words(_ name: String) -> Set<String> {
        var s = name.lowercased()
        // „DE: …“ / „EN | …“ am Anfang weg
        if let r = s.range(of: #"^[a-z]{2,3}\s*[:|\-]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        let parts = s.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out = Set<String>()
        for w in parts where w.count >= 4 && !stop.contains(w) && !noise.contains(w) && Int(w) == nil {
            out.insert(w)
        }
        return out
    }

    @MainActor
    static func find(_ movie: Channel, store: AppStore, max: Int = 15) -> [Channel] {
        let list = Parental.shared.visible("movie", store.movies)
        let mine = words(movie.name)
        var scored: [(Channel, Double)] = []
        for x in list where x.id != movie.id {
            var score = 0.0
            if !mine.isEmpty {
                let shared = mine.intersection(words(x.name)).count
                if shared > 0 { score += 6 + Double(shared) * 3 }
            }
            if let g = movie.group, !g.isEmpty, x.group == g { score += 4 }
            if score == 0 { continue }
            score += min(x.rating ?? 0, 10) / 4
            if let a = movie.year, let b = x.year, abs(a - b) <= 3 { score += 1 }
            if store.movieSeen(x) != nil { score -= 2 }
            scored.append((x, score))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.added ?? 0) > ($1.0.added ?? 0) }
        var seenNames = Set<String>()
        var out: [Channel] = []
        for (x, _) in scored {
            let key = x.name.lowercased().filter { $0.isLetter || $0.isNumber }
            if seenNames.contains(key) { continue }
            seenNames.insert(key)
            out.append(x)
            if out.count >= max { break }
        }
        return out
    }
}

/// Leiste „Mehr davon“ unter der Film-Beschreibung
struct SimilarMoviesSection: View {
    @EnvironmentObject private var store: AppStore
    let movie: Channel

    var body: some View {
        let list = SimilarMovies.find(movie, store: store)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mehr davon" + ((movie.group ?? "").isEmpty ? "" : " · \(movie.group ?? "")"))
                    .font(.headline)
                    .foregroundStyle(Theme.goldLight)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(list) { x in
                            NavigationLink(value: x) {
                                PosterCard(title: x.name, image: x.logo, isFavorite: store.isFavorite(x),
                                           rating: x.rating, seen: store.movieSeen(x) != nil)
                                    .frame(width: 104)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
    }
}
