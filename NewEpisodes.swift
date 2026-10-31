import SwiftUI

// MARK: - Neue Folgen bei Serien, die man schaut (angefangen oder Favorit)
//
// Nach dem Abgleich wird für diese Serien nachgesehen, ob der Anbieter Folgen dazugelegt hat
// (nur wenn sich „zuletzt geändert“ verschoben hat). Beim ersten Mal wird nur der Stand gemerkt.

struct NewEpisodeMark: Codable, Hashable {
    var s: Int
    var n: Int
    var at: Double
}

struct NewEpisodeEntry: Codable {
    var lm: Int
    var known: [String]
    var fresh: [String: NewEpisodeMark]
}

struct FreshEpisode: Hashable {
    let id: String
    let season: Int
    let number: Int
    let at: Double
}

enum NewEpisodesStore {
    static let keepDays: Double = 14
    static let maxSeries = 30
    private static var storageKey: String { Profiles.storageKey("newEpisodes") }
    private static var cache: [String: NewEpisodeEntry]?

    /// Profil gewechselt: neu laden
    static func resetCache() { cache = nil }

    static func all() -> [String: NewEpisodeEntry] {
        if let c = cache { return c }
        let data = UserDefaults.standard.data(forKey: storageKey)
        let value = data.flatMap { try? JSONDecoder().decode([String: NewEpisodeEntry].self, from: $0) } ?? [:]
        cache = value
        return value
    }

    static func save(_ dict: [String: NewEpisodeEntry]) {
        cache = dict
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Kurztext, z. B. „S2 F7–F8“
    static func label(_ list: [FreshEpisode]) -> String {
        guard let a = list.first, let b = list.last else { return "" }
        if list.count == 1 { return "S\(a.season) F\(a.number)" }
        if a.season == b.season { return "S\(a.season) F\(a.number)–F\(b.number)" }
        return "S\(a.season) F\(a.number) … S\(b.season) F\(b.number)"
    }
}

extension AppStore {
    /// Neue, noch nicht gesehene Folgen einer Serie
    func freshEpisodes(seriesId: Int) -> [FreshEpisode] {
        guard let entry = NewEpisodesStore.all()[resumeAccount + "|\(seriesId)"] else { return [] }
        let now = Date().timeIntervalSince1970
        let keep = NewEpisodesStore.keepDays * 86_400
        var out: [FreshEpisode] = []
        for (id, mark) in entry.fresh {
            if now - mark.at > keep { continue }
            if let seen = SeenStore.get(resumeAccount, id), seen.d { continue }
            out.append(FreshEpisode(id: id, season: mark.s, number: mark.n, at: mark.at))
        }
        return out.sorted { $0.season != $1.season ? $0.season < $1.season : $0.number < $1.number }
    }

    /// Serien mit neuen Folgen, zuletzt gefundene zuerst
    var seriesWithNewEpisodes: [SeriesItem] {
        let byId = Dictionary(seriesList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prefix = resumeAccount + "|"
        var out: [(series: SeriesItem, at: Double)] = []
        for key in NewEpisodesStore.all().keys where key.hasPrefix(prefix) {
            guard let sid = Int(key.dropFirst(prefix.count)), let series = byId[sid] else { continue }
            let fresh = freshEpisodes(seriesId: sid)
            if let newest = fresh.map(\.at).max() { out.append((series, newest)) }
        }
        return out.sorted { $0.at > $1.at }.map { $0.series }
    }

    /// Serien, die man verfolgt: angefangen oder als Favorit
    private func trackedSeries() -> [SeriesItem] {
        var ids = Set<Int>()
        let acc = resumeAccount
        for entry in resumeList where entry.acc == acc && entry.isEpisode {
            if let sid = entry.seriesId { ids.insert(sid) }
        }
        for key in favorites where key.hasPrefix("series:") {
            if let sid = Int(key.dropFirst("series:".count)) { ids.insert(sid) }
        }
        return Array(seriesList.filter { ids.contains($0.id) }.prefix(NewEpisodesStore.maxSeries))
    }

    /// Nach dem Abgleich: bei verfolgten Serien nach neuen Folgen sehen
    func checkNewEpisodes() async {
        guard isXtream, !seriesList.isEmpty, !newEpisodesChecking else { return }
        let list = trackedSeries()
        guard !list.isEmpty else { return }
        newEpisodesChecking = true
        defer { newEpisodesChecking = false }

        var dict = NewEpisodesStore.all()
        var found: [SeriesItem] = []
        let now = Date().timeIntervalSince1970
        let keep = NewEpisodesStore.keepDays * 86_400

        for series in list {
            let key = resumeAccount + "|\(series.id)"
            if let entry = dict[key], series.added > 0, entry.lm == series.added { continue }   // unverändert
            guard let details = try? await seriesDetails(series.id) else { continue }
            let ids = details.episodes.map(\.id)
            if var entry = dict[key] {
                let known = Set(entry.known)
                let added = details.episodes.filter { !known.contains($0.id) }
                for ep in added {
                    entry.fresh[ep.id] = NewEpisodeMark(s: ep.season, n: ep.number, at: now)
                }
                entry.fresh = entry.fresh.filter { now - $0.value.at <= keep }
                entry.known = ids
                entry.lm = series.added
                dict[key] = entry
                if !added.isEmpty { found.append(series) }
            } else {
                // Erstes Mal: nur den Stand merken
                dict[key] = NewEpisodeEntry(lm: series.added, known: ids, fresh: [:])
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        NewEpisodesStore.save(dict)
        newEpisodesVersion += 1
        if !found.isEmpty {
            let parts = found.prefix(3).map { "\($0.name) (\(NewEpisodesStore.label(freshEpisodes(seriesId: $0.id))))" }
            newEpisodesNote = "Neue Folgen bei \(found.count) \(found.count == 1 ? "Serie" : "Serien"): "
                + parts.joined(separator: " · ") + (found.count > 3 ? " …" : "")
        }
    }

    // MARK: Gesehene Filme

    func movieSeen(_ movie: Channel) -> SeenState? {
        guard let state = SeenStore.get(resumeAccount, "mv\(movie.id)"), state.d else { return nil }
        return state
    }

    /// Film von Hand als gesehen / ungesehen markieren
    func setMovieSeen(_ movie: Channel, _ done: Bool) {
        objectWillChange.send()
        if done {
            SeenStore.mark(resumeAccount, "mv\(movie.id)", part: 1, done: true)
            removeResume(key: ResumeInfo.movie(movie).key)
        } else {
            SeenStore.remove(resumeAccount, "mv\(movie.id)")
        }
    }
}

/// „Gesehen am 28. Oktober“
func seenDateText(_ state: SeenState) -> String {
    let date = Date(timeIntervalSince1970: state.at)
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d. MMMM" : "d. MMMM yyyy"
    return f.string(from: date)
}

/// Hinweis unten, z. B. „Neue Folgen bei 2 Serien …“
struct NoteBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.title3)
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.gold))
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gold, lineWidth: 1.5))
        .padding(.horizontal, 40)
        .padding(.bottom, 16)
    }
}
