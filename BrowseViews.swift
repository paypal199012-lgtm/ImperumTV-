import SwiftUI

// MARK: - Poster

struct PosterCard: View {
    let title: String
    let image: URL?
    var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: image) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            ZStack {
                                Theme.panel
                                Image(systemName: "film")
                                    .font(.title)
                                    .foregroundStyle(Theme.gold.opacity(0.7))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gold.opacity(0.3)))
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

            Text(title)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

private let posterColumns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

// MARK: - Filme

struct MovieGridView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var group: String?
    @State private var request: PlayRequest?

    private var groups: [String] {
        Array(Set(store.movies.compactMap(\.group))).sorted()
    }

    private var filtered: [Channel] {
        store.movies.filter { movie in
            (group == nil || movie.group == group)
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
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Filme")
        .searchable(text: $query, prompt: "Film suchen")
        .task { await store.loadMoviesIfNeeded() }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: false)
                .environmentObject(store)
        }
    }

    private var content: some View {
        let list = filtered
        return ScrollView {
            VStack(spacing: 12) {
                if groups.count > 1 {
                    CategoryMenu(groups: groups, selection: $group)
                }
                if let error = store.sectionError, store.movies.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.top, 30)
                }
                LazyVGrid(columns: posterColumns, spacing: 16) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, movie in
                        Button {
                            request = PlayRequest(channels: list, index: index, isLive: false)
                        } label: {
                            PosterCard(title: movie.name, image: movie.logo, isFavorite: store.isFavorite(movie))
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
            }
            .padding(16)
        }
        .refreshable { await store.loadMoviesIfNeeded(force: true) }
    }
}

// MARK: - Serien

struct SeriesGridView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var group: String?

    private var groups: [String] {
        Array(Set(store.seriesList.compactMap(\.group))).sorted()
    }

    private var filtered: [SeriesItem] {
        store.seriesList.filter { show in
            (group == nil || show.group == group)
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
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.6))
        .navigationTitle("Serien")
        .searchable(text: $query, prompt: "Serie suchen")
        .task { await store.loadSeriesIfNeeded() }
    }

    private var content: some View {
        let list = filtered
        return ScrollView {
            VStack(spacing: 12) {
                if groups.count > 1 {
                    CategoryMenu(groups: groups, selection: $group)
                }
                if let error = store.sectionError, store.seriesList.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.top, 30)
                }
                LazyVGrid(columns: posterColumns, spacing: 16) {
                    ForEach(list) { show in
                        NavigationLink(value: show) {
                            PosterCard(title: show.name, image: show.cover)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await store.loadSeriesIfNeeded(force: true) }
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject private var store: AppStore
    let series: SeriesItem

    @State private var episodes: [Episode] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var season = 1
    @State private var request: PlayRequest?

    private var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted()
    }

    var body: some View {
        let current = episodes.filter { $0.season == season }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    PosterCard(title: "", image: series.cover)
                        .frame(width: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(series.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        if let group = series.group {
                            Text(group)
                                .font(.subheadline)
                                .foregroundStyle(Theme.goldLight)
                        }
                        if !episodes.isEmpty {
                            Text("\(seasons.count) Staffel(n) · \(episodes.count) Folgen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                if seasons.count > 1 {
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
                            }
                        }
                    }
                }

                ForEach(Array(current.enumerated()), id: \.element.id) { index, episode in
                    Button {
                        request = PlayRequest(channels: current.map(\.asChannel), index: index, isLive: false)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(episode.number)")
                                .font(.headline)
                                .foregroundStyle(Theme.gold)
                                .frame(width: 32)
                            Text(episode.title)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.gold)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(GoldBackground(dim: 0.6))
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard episodes.isEmpty else { return }
            do {
                episodes = try await store.seriesEpisodes(series.id)
                season = episodes.first?.season ?? 1
                if episodes.isEmpty { errorText = "Keine Folgen gefunden." }
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: false)
                .environmentObject(store)
        }
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
