import SwiftUI

/// Zeile in der linken Spalte (Kategorien)
struct CatRow: View {
    let name: String
    var icon: String? = nil
    var count: Int? = nil
    var active = false
    var gold = false
    var size: CGFloat = 27
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let i = icon { Icon(i, 30) }
                Text(name).font(UI.font(size, .medium)).lineLimit(1)
                Spacer(minLength: 8)
                if let c = count { Text("\(c)").font(UI.font(20)).foregroundColor(active ? UI.gold : UI.muted) }
            }
            .foregroundColor(gold ? UI.gold : UI.text)
            .padding(.horizontal, 16)
            .frame(height: 50)
        }
        .buttonStyle(GoldStyle(active: active))
    }
}

struct SectionHead: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(UI.font(19, .bold)).tracking(3).foregroundColor(UI.gold)
            .padding(.top, 14).padding(.leading, 4)
    }
}

struct LiveScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine

    enum F: Hashable { case search, cat(String), ch(Int), full, fav, prog }
    @FocusState private var focus: F?
    @State private var cat = "all"
    @State private var query = ""
    @State private var shown: TVItem?
    @State private var epg: [EPGEntry] = []
    @State private var showProgram = false
    @State private var askPin = false
    /// Qualitätswahl offen für diesen Sender
    @State private var qualityFor: MergeGroup?

    private var channels: [TVItem] {
        _ = store.unlockTick
        var l: [TVItem]
        switch cat {
        case "all": l = store.visible(.live)
        case "fav": l = store.visible(.live).filter { store.isFav($0, .live) }
        default: l = store.catLocked(.live, cat) ? [] : store.visible(.live).filter { $0.cat == cat }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { l = l.filter { $0.name.lowercased().contains(q) } }
        return l
    }

    /// Gleiche Sender in mehreren Qualitäten zusammengefasst (Favoriten nicht)
    private var groups: [MergeGroup] {
        cat == "fav" ? channels.map { MergeGroup(rep: $0, variants: [$0], name: $0.name, key: "") } : store.mergeGroups(channels)
    }

    private var info: TVItem? { shown ?? engine.item ?? channels.first }

    private func group(of it: TVItem?) -> MergeGroup? {
        guard let it = it else { return nil }
        let v = store.variants(of: it)
        return v.count > 1 ? MergeGroup(rep: it, variants: v, name: store.cleanName(it), key: store.mergeKey(it)) : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Live TV")

            // Kategorien
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    TextField("Suchen", text: $query)
                        .font(UI.font(27, .medium))
                        .focused($focus, equals: .search)
                    CatRow(name: "☰ Alle", count: store.visible(.live).count, active: cat == "all") { cat = "all" }
                        .focused($focus, equals: .cat("all"))
                    CatRow(name: "★ Favoriten", count: store.live.filter { store.isFav($0, .live) }.count, active: cat == "fav") { cat = "fav" }
                        .focused($focus, equals: .cat("fav"))
                    ForEach(store.visibleCats(.live)) { c in
                        CatRow(name: (store.catLocked(.live, c.id) ? "🔒 " : "") + c.name, count: store.live.lazy.filter { $0.cat == c.id }.count,
                               active: cat == c.id) { cat = c.id; if store.catLocked(.live, c.id) { askPin = true } }
                            .focused($focus, equals: .cat(c.id))
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 10)
            }
            .place(20, 92, 400, 970)

            // Sender
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if channels.isEmpty {
                        Text(store.catLocked(.live, cat) ? "🔒 Gesperrt – links auf die Kategorie drücken und PIN eingeben."
                             : cat == "fav" ? "Noch keine Favoriten. Sender auswählen und unten „Favorit“ drücken." : "Keine Sender")
                            .font(UI.font(26)).foregroundColor(UI.muted).padding(30)
                    }
                    ForEach(groups) { g in
                        let ch = g.rep
                        Button { open(ch) } label: {
                            HStack(spacing: 14) {
                                ArtView(art: ch.art).frame(width: 84, height: 56).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(g.name).font(UI.font(28, .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if g.variants.count > 1 { badges(g) }
                                if store.isFav(ch, .live) { Text("★").font(UI.font(26)).foregroundColor(UI.gold2) }
                            }
                            .padding(.horizontal, 22)
                            .frame(height: 86)
                        }
                        .buttonStyle(GoldStyle(active: engine.kind == .live && g.variants.contains { $0.id == engine.item?.id }))
                        .focused($focus, equals: .ch(ch.id))
                        .contextMenu {
                            if g.variants.count > 1 { Button("◎ Qualität wählen") { qualityFor = g } }
                            Button(store.isFav(ch, .live) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen") { store.toggleFav(ch, .live) }
                            Button("Sender ausblenden", role: .destructive) { store.hide(ch) }
                        }
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 6)
            }
            .place(416, 92, 568, 970)

            preview.place(1000, 120, 880, 495)
            if showProgram { programList.place(1000, 635, 880, 380) } else { nextCards.place(1000, 635, 880, 80) }
            buttons.place(1000, showProgram ? 1020 : 735, 880, 60)
        }
        .overlay {
            if askPin {
                PinPrompt(title: "PIN eingeben") { pin in
                    askPin = false
                    if let p = pin, Parental.check(p) { store.unlock() }
                }
            }
        }
        .confirmationDialog(qualityFor.map { "Qualität · " + $0.name } ?? "", isPresented: Binding(get: { qualityFor != nil }, set: { if !$0 { qualityFor = nil } }),
                            titleVisibility: .visible) {
            if let g = qualityFor {
                ForEach(g.variants) { v in
                    Button((v.id == g.rep.id ? "✓ " : "") + store.qualityLabel(v) + " – " + v.name) { pick(v) }
                }
                Button("Nicht zusammenfassen") { store.dontMerge(g.rep); qualityFor = nil }
                Button("Abbrechen", role: .cancel) { qualityFor = nil }
            }
        } message: {
            Text("Die Wahl wird für diesen Sender gemerkt.")
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, .ch(engine.item?.id ?? channels.first?.id ?? 0))
        .onChange(of: focus) { _, f in
            switch f {
            case .cat(let c)?: cat = c
            case .ch(let id)?: shown = groups.first { $0.rep.id == id }?.rep
            default: break
            }
        }
        .task(id: info?.id) {
            guard let it = info else { epg = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            epg = await store.epg(it)
        }
    }

    private var nowEntry: EPGEntry? {
        epg.first { ($0.start ?? .distantFuture) <= Date() && ($0.end ?? .distantPast) > Date() } ?? epg.first
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            Color(rgb: 0x1c1d21)
            if engine.item != nil && engine.kind == .live {
                VideoView(engine: engine)
                if engine.buffering { ProgressView().scaleEffect(1.6).tint(UI.gold).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                Text("OK drücken für die Vorschau").font(UI.font(30)).foregroundColor(UI.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 120)
            }
            if let it = info {
                VStack(alignment: .leading, spacing: 6) {
                    Text(it.name).font(UI.font(32, .bold)).lineLimit(1)
                    if let n = nowEntry {
                        Text("Jetzt: \(n.title) · \(n.timeRange)").font(UI.font(23)).foregroundColor(UI.gold).lineLimit(1)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2))
                                Capsule().fill(UI.gold2).frame(width: g.size.width * n.progress)
                            }
                        }
                        .frame(width: 490, height: 4).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 60).padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UI.tan(0.5), lineWidth: 2))
    }

    private var nextCards: some View {
        HStack(spacing: 14) {
            ForEach(Array(epg.filter { ($0.start ?? .distantPast) > Date() }.prefix(3))) { e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.timeRange.components(separatedBy: "–").first ?? "").font(UI.font(22, .bold)).foregroundColor(UI.gold)
                    Text(e.title).font(UI.font(22)).lineLimit(1)
                }
                .padding(.horizontal, 18)
                .frame(width: 284, height: 80, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var programList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                if epg.isEmpty { Text("Kein Programm verfügbar").font(UI.font(24)).foregroundColor(UI.muted) }
                ForEach(epg) { e in
                    HStack(alignment: .top, spacing: 18) {
                        Text(e.timeRange).font(UI.font(22, .bold)).foregroundColor(UI.gold).frame(width: 170, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.title).font(UI.font(23, .semibold))
                            if let d = e.desc { Text(d).font(UI.font(19)).foregroundColor(UI.muted).lineLimit(2) }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 16) {
            Button { if let it = info { full(it) } } label: { pill("▶ Vollbild") }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                .focused($focus, equals: .full)
            Button { if let it = info { store.toggleFav(it, .live) } } label: {
                pill(info.map { store.isFav($0, .live) } == true ? "★ Favorit entfernen" : "★ Favorit")
            }
            .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.08), ring: false, solid: true))
            .focused($focus, equals: .fav)
            Button { showProgram.toggle() } label: { pill(showProgram ? "☰ Weniger" : "☰ Programm") }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.08), ring: false, solid: true))
                .focused($focus, equals: .prog)
            if let g = group(of: info) {
                Button { qualityFor = g } label: { pill("◎ " + store.qualityLabel(g.rep)) }
                    .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.08), ring: false, solid: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ t: String) -> some View {
        Text(t).font(UI.font(26, .bold)).lineLimit(1).padding(.horizontal, 26).frame(height: 56)
    }

    /// Qualitäts-Abzeichen: höchstens 3, die gewählte hervorgehoben, Rest als „+2“
    private func badges(_ g: MergeGroup) -> some View {
        let tags = g.variants.map { store.qualityTags($0).first ?? "STD" }
        var seen: [String] = []
        for t in tags where !seen.contains(t) { seen.append(t) }
        let cur = store.qualityTags(g.rep).first ?? "STD"
        let shownTags = Array(seen.prefix(3))
        return HStack(spacing: 6) {
            ForEach(shownTags, id: \.self) { t in
                Text(t).font(UI.font(17, .heavy))
                    .foregroundColor(t == cur ? UI.dark : UI.gold)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t == cur ? UI.gold : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.gold.opacity(0.6), lineWidth: 1.5))
            }
            if seen.count > 3 { Text("+\(seen.count - 3)").font(UI.font(17, .bold)).foregroundColor(UI.muted) }
        }
    }

    /// Qualität gewählt: merken und gleich abspielen
    private func pick(_ v: TVItem) {
        store.choose(v)
        qualityFor = nil
        guard let u = store.url(v, .live) else { return }
        let reps = groups.map(\.rep)
        engine.items = reps
        engine.index = reps.firstIndex { $0.id == v.id } ?? engine.index
        engine.play(u, item: v, kind: .live)
        shown = v
    }

    /// OK auf einem Sender: erst Vorschau, nochmal OK = Vollbild (wie auf Android)
    private func open(_ ch: TVItem) {
        if engine.item?.id == ch.id && engine.kind == .live { full(ch); return }
        guard let u = store.url(ch, .live) else { return }
        let reps = groups.map(\.rep)
        engine.items = reps
        engine.index = reps.firstIndex(of: ch) ?? 0
        engine.play(u, item: ch, kind: .live)
    }

    private func full(_ ch: TVItem) {
        if engine.item?.id != ch.id || engine.kind != .live {
            guard let u = store.url(ch, .live) else { return }
            engine.play(u, item: ch, kind: .live)
        }
        let reps = groups.map(\.rep)
        engine.items = reps
        engine.index = reps.firstIndex(of: ch) ?? 0
        nav.push(.player)
    }
}
