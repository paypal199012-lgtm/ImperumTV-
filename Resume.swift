import SwiftUI

// MARK: - Weiterschauen: Speicher

extension AppStore {
    /// Kennung der aktuellen Wiedergabeliste (jede Liste hat ihre eigene Weiterschauen-Liste)
    var resumeAccount: String { "\(serverInput)|\(username)" }

    /// Einträge der aktuellen Liste, zuletzt geschaute zuerst
    var resumeEntries: [ResumeEntry] {
        let acc = resumeAccount
        return resumeList.filter { $0.acc == acc }.sorted { $0.at > $1.at }
    }

    func resumeEntry(for info: ResumeInfo) -> ResumeEntry? {
        let acc = resumeAccount, key = info.key
        return resumeList.first { $0.acc == acc && $0.key == key && $0.itemId == info.itemId }
    }

    func resumeEntry(movieId: Int) -> ResumeEntry? {
        resumeEntry(for: ResumeInfo(kind: .movie, itemId: String(movieId)))
    }

    func resumeEntry(seriesId: Int) -> ResumeEntry? {
        let acc = resumeAccount, key = "series:\(seriesId)"
        return resumeList.first { $0.acc == acc && $0.key == key }
    }

    /// Gespeicherte Stelle (in Sekunden), ab der weitergeschaut wird, sonst 0
    func resumePosition(for info: ResumeInfo) -> Double {
        guard let e = resumeEntry(for: info), !e.next, e.pos >= 30 else { return 0 }
        return e.pos
    }

    func removeResume(key: String) {
        let acc = resumeAccount
        resumeList.removeAll { $0.acc == acc && $0.key == key }
        saveResumeList()
    }

    private func putResume(_ entry: ResumeEntry) {
        resumeList.removeAll { $0.acc == entry.acc && $0.key == entry.key }
        resumeList.insert(entry, at: 0)
        if resumeList.count > 60 { resumeList = Array(resumeList.prefix(60)) }
        saveResumeList()
    }

    private func saveResumeList() {
        if let data = try? JSONEncoder().encode(resumeList) {
            defaults.set(data, forKey: "resume")
        }
    }

    private func makeEntry(_ info: ResumeInfo, _ channel: Channel, pos: Double, dur: Double, next: Bool) -> ResumeEntry {
        ResumeEntry(
            acc: resumeAccount,
            key: info.key,
            kind: info.kind.rawValue,
            itemId: info.itemId,
            name: channel.name,
            logo: (info.seriesCover ?? channel.logo)?.absoluteString,
            url: channel.url.absoluteString,
            pos: pos,
            dur: dur,
            at: Date().timeIntervalSince1970,
            next: next,
            seriesId: info.seriesId,
            seriesName: info.seriesName,
            season: info.season,
            number: info.number
        )
    }

    /// Stand merken. Fast zu Ende geschaut: Eintrag weg bzw. nächste Folge vormerken.
    func recordProgress(info: ResumeInfo, channel: Channel, next: (info: ResumeInfo, channel: Channel)?,
                        pos: Double, dur: Double, ended: Bool) {
        let done = ended || (dur > 60 && (pos >= dur * 0.95 || dur - pos < 60))
        if done {
            if let n = next {
                putResume(makeEntry(n.info, n.channel, pos: 0, dur: 0, next: true))
            } else {
                removeResume(key: info.key)
            }
        } else if dur > 60 && pos >= 30 {
            putResume(makeEntry(info, channel, pos: pos, dur: dur, next: false))
        }
    }
}

// MARK: - Fortschrittsbalken

struct ProgressStrip: View {
    let part: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(Theme.gold).frame(width: max(4, geo.size.width * part))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Weiter ansehen (eigener Bildschirm)

struct ResumeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var request: PlayRequest?
    @State private var loadingKey: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    var body: some View {
        let list = store.resumeEntries
        ScrollView {
            if list.isEmpty {
                Text("Hier erscheinen Filme und Serien, die du angefangen hast.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 40)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(list) { entry in
                    Button {
                        play(entry, from: entry.next ? 0 : entry.pos)
                    } label: {
                        PosterCard(title: entry.title, image: entry.logo.flatMap { URL(string: $0) },
                                   progress: entry.next ? nil : entry.part, subtitle: entry.leftText)
                            .overlay {
                                if loadingKey == entry.key { ProgressView().tint(.white) }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !entry.next {
                            Button {
                                play(entry, from: 0)
                            } label: {
                                Label("Von vorne", systemImage: "arrow.counterclockwise")
                            }
                        }
                        Button(role: .destructive) {
                            store.removeResume(key: entry.key)
                        } label: {
                            Label("Aus der Liste entfernen", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(GoldBackground(dim: 0.7))
        .navigationTitle("Weiter ansehen")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $request) { req in
            PlayerScreen(channels: req.channels, startIndex: req.index, isLive: false,
                         resume: req.resume, startAt: req.startAt)
                .environmentObject(store)
        }
    }

    /// Filme sofort, Folgen mit allen Folgen der Serie (damit die nächste automatisch kommt)
    private func play(_ entry: ResumeEntry, from start: Double) {
        guard let channel = entry.channel else { return }
        guard entry.isEpisode, let sid = entry.seriesId else {
            request = PlayRequest(channels: [channel], index: 0, isLive: false, resume: [entry.info], startAt: start)
            return
        }
        loadingKey = entry.key
        Task {
            let show = SeriesItem(id: sid, name: entry.seriesName ?? entry.name,
                                  cover: entry.logo.flatMap { URL(string: $0) }, group: nil)
            if let details = try? await store.seriesDetails(sid),
               let index = details.episodes.firstIndex(where: { $0.id == entry.itemId }) {
                let eps = details.episodes
                request = PlayRequest(channels: eps.map(\.asChannel), index: index, isLive: false,
                                      resume: eps.map { ResumeInfo.episode($0, series: show) }, startAt: start)
            } else {
                request = PlayRequest(channels: [channel], index: 0, isLive: false, resume: [entry.info], startAt: start)
            }
            loadingKey = nil
        }
    }
}
