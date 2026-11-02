import SwiftUI

// MARK: - EPG wie auf Android: Vorschau oben links, Sendung oben rechts, Filter-Chips, Zeitraster mit „JETZT“-Linie

private let pxPerMin: CGFloat = 288.0 / 30.0       // 30 Minuten = 288 Punkte
private let windowMin: Double = 150                 // 2,5 Stunden sichtbar
private let gridX: CGFloat = 440
private let rowH: CGFloat = 74

/// immer 24-Stunden-Uhr (auch wenn das Apple TV auf 12 Stunden steht)
let hhmm: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "HH:mm"
    return f
}()

private func fmt(_ d: Date?) -> String {
    guard let d = d else { return "" }
    return hhmm.string(from: d)
}

private func isNow(_ e: EPGEntry, _ now: Date = Date()) -> Bool {
    (e.start ?? .distantFuture) <= now && (e.end ?? .distantPast) > now
}

struct EpgScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine

    enum F: Hashable { case chip(String), ch(Int), cell(Int, Double), watch }
    @FocusState private var focus: F?
    @State private var cat = "all"
    @State private var onlyWithProgram = false
    @State private var shift: Double = 0                  // Minuten gegenüber „jetzt“
    @State private var epg: [Int: [EPGEntry]] = [:]
    @State private var selCh: TVItem?
    @State private var selEntry: EPGEntry?

    private var base: Date {
        let now = Date().timeIntervalSince1970 + shift * 60
        return Date(timeIntervalSince1970: floor(now / 1800) * 1800)
    }

    private var channels: [TVItem] {
        _ = store.unlockTick
        var l: [TVItem]
        switch cat {
        case "all": l = store.visible(.live)
        case "fav": l = store.visible(.live).filter { store.isFav($0, .live) }
        default: l = store.catLocked(.live, cat) ? [] : store.live.filter { $0.cat == cat }
        }
        if onlyWithProgram { l = l.filter { !(epg[$0.id]?.isEmpty ?? false) } }
        return l
    }

    private var shownEntry: EPGEntry? {
        if let e = selEntry { return e }
        guard let ch = selCh ?? channels.first, let l = epg[ch.id] else { return nil }
        return l.first { isNow($0) } ?? l.first
    }

    var body: some View {
        let ch = selCh ?? channels.first
        ZStack(alignment: .topLeading) {
            preview(ch).place(40, 30, 620, 349)
            info.place(700, 34, 1000, 300)
            chips.place(40, 398, 1840, 58)
            timeHeader.place(gridX, 462, 1440, 30)
            grid.place(0, 500, 1920, 530)
            footer.place(40, 1034, 1840, 36)
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, .ch(channels.first?.id ?? 0))
        .onChange(of: focus) { _, f in
            switch f {
            case .chip(let c)?:
                if c.hasPrefix("cat:") { cat = String(c.dropFirst(4)) }
            case .ch(let id)?:
                selCh = channels.first { $0.id == id }; selEntry = nil
            case .cell(let id, let t)?:
                selCh = channels.first { $0.id == id }
                selEntry = epg[id]?.first { ($0.start?.timeIntervalSince1970 ?? 0) == t }
            default: break
            }
        }
        // Vorschau: kurz nach dem Wechsel den gewählten Sender klein abspielen (wie auf Android)
        .task(id: selCh?.id) {
            guard let c = selCh ?? channels.first else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            if engine.item?.id != c.id || engine.kind != .live, let u = store.url(c, .live) {
                engine.items = channels
                engine.index = channels.firstIndex(of: c) ?? 0
                engine.play(u, item: c, kind: .live)
            }
        }
    }

    // MARK: Vorschau oben links

    private func preview(_ ch: TVItem?) -> some View {
        let now = ch.flatMap { epg[$0.id] }?.first { isNow($0) }
        return ZStack(alignment: .bottomLeading) {
            Color.black
            if engine.item != nil && engine.kind == .live {
                VideoView(engine: engine)
                if engine.buffering { ProgressView().scaleEffect(1.4).tint(UI.gold).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            if let c = ch {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.name).font(UI.font(28, .bold)).lineLimit(1)
                    if let n = now {
                        Text("Jetzt: \(n.title) · \(n.timeRange)").font(UI.font(20, .bold)).foregroundColor(UI.gold).lineLimit(1)
                        bar(n.progress, width: 340).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 50).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UI.tan(0.6), lineWidth: 2))
    }

    // MARK: Sendung oben rechts

    private var info: some View {
        let e = shownEntry
        let list = (selCh ?? channels.first).flatMap { epg[$0.id] } ?? []
        let after = list.filter { ($0.start ?? .distantPast) >= (e?.end ?? Date()) }.prefix(3)
        return VStack(alignment: .leading, spacing: 0) {
            Text(e?.title ?? "Kein Programm").font(UI.font(40, .heavy)).lineLimit(1)
            if let e = e {
                let left = e.end.map { max(0, Int($0.timeIntervalSinceNow / 60)) } ?? 0
                Text("\(fmt(e.start)) – \(fmt(e.end))" + (isNow(e) ? " · noch \(left) Min" : ""))
                    .font(UI.font(23)).foregroundColor(UI.gold).padding(.top, 8)
                if isNow(e) { bar(e.progress, width: 520).padding(.top, 12) }
            }
            HStack(spacing: 14) {
                ForEach(Array(after)) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fmt(n.start)).font(UI.font(19, .bold)).foregroundColor(UI.gold)
                        Text(n.title).font(UI.font(19)).lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 311, height: 66, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1), lineWidth: 1))
                }
            }
            .padding(.top, 14)
            HStack(spacing: 14) {
                Button { if let c = selCh ?? channels.first { full(c) } } label: {
                    Text("▶ Ansehen").font(UI.font(22, .heavy)).padding(.horizontal, 26).frame(height: 48)
                }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: UI.gold, ring: false, solid: true))
                .focused($focus, equals: .watch)
                Text("mit OK oder Klick").font(UI.font(19)).foregroundColor(UI.muted)
            }
            .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func bar(_ p: Double, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.2))
            Capsule().fill(UI.gold2).frame(width: width * min(max(p, 0), 1))
        }
        .frame(width: width, height: 5)
    }

    // MARK: Filter-Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip("only", "Nur mit Programm", active: onlyWithProgram) { onlyWithProgram.toggle() }
                chip("cat:all", "☰  Alle", active: cat == "all") { cat = "all" }
                chip("cat:fav", "★ Favoriten", active: cat == "fav") { cat = "fav" }
                ForEach(store.visibleCats(.live).filter { !store.catLocked(.live, $0.id) }) { c in chip("cat:" + c.id, c.name, active: cat == c.id) { cat = c.id } }
                chip("t-", "◀ −2 Std.", active: false) { shift -= 120 }
                chip("t0", "Jetzt", active: false) { shift = 0 }
                chip("t+", "+2 Std. ▶", active: false) { shift += 120 }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
    }

    private func chip(_ key: String, _ t: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(UI.font(21, .bold)).padding(.horizontal, 20).frame(height: 43)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: active ? UI.tan(0.45) : .white.opacity(0.08), ring: false, solid: true))
        .focused($focus, equals: .chip(key))
    }

    // MARK: Zeitleiste und Raster

    private var timeHeader: some View {
        HStack(spacing: 0) {
            ForEach(0..<5) { i in
                Text(fmt(base.addingTimeInterval(Double(i) * 1800)))
                    .font(UI.font(22, .bold)).foregroundColor(Color(rgb: 0xcfc8bb))
                    .frame(width: 288, alignment: .leading)
            }
        }
    }

    private var grid: some View {
        let nowX = CGFloat(Date().timeIntervalSince(base) / 60) * pxPerMin
        return ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if channels.isEmpty {
                        Text(cat == "fav" ? "Noch keine Favoriten" : "Keine Sender").font(UI.font(26)).foregroundColor(UI.muted).padding(40)
                    }
                    ForEach(Array(channels.enumerated()), id: \.element.id) { i, c in
                        row(i, c)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 1920, height: 530)
            // JETZT-Linie
            if nowX >= 0 && nowX <= 1440 {
                Rectangle().fill(UI.gold).frame(width: 3, height: 250)
                    .offset(x: gridX + nowX - 1, y: 0)
                    .allowsHitTesting(false)
                Text("JETZT").font(UI.font(14, .black)).foregroundColor(UI.dark)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(UI.gold))
                    .offset(x: gridX + nowX - 29, y: -16)
                    .allowsHitTesting(false)
            }
        }
    }

    private func row(_ i: Int, _ c: TVItem) -> some View {
        HStack(spacing: 20) {
            Button { full(c) } label: {
                HStack(spacing: 12) {
                    Text("\(i + 1)").font(UI.font(20)).foregroundColor(UI.muted).frame(width: 40)
                    ArtView(art: c.art).frame(width: 76, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(c.name).font(UI.font(21, .heavy)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).frame(width: 380, height: rowH)
            }
            .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 8)), normal: .white.opacity(0.05),
                                   active: selCh?.id == c.id, activeFill: UI.tan(0.3)))
            .focused($focus, equals: .ch(c.id))

            programs(c).frame(width: 1440, height: rowH, alignment: .leading).clipped()
        }
        .padding(.leading, 40)
        .task(id: c.id) { if epg[c.id] == nil { epg[c.id] = await store.epg(c) } }
    }

    @ViewBuilder private func programs(_ c: TVItem) -> some View {
        let end = base.addingTimeInterval(windowMin * 60)
        let list = (epg[c.id] ?? []).filter { ($0.end ?? .distantPast) > base && ($0.start ?? .distantFuture) < end }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        if list.isEmpty {
            Text(epg[c.id] == nil ? "" : "Kein Programm").font(UI.font(19)).foregroundColor(UI.muted)
                .frame(width: 1432, height: rowH).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
        } else {
            HStack(spacing: 0) {
                ForEach(Array(segments(list, end: end).enumerated()), id: \.offset) { _, seg in
                    if let e = seg.entry {
                        cell(c, e, width: seg.width)
                    } else {
                        Color.clear.frame(width: seg.width, height: rowH)
                    }
                }
            }
        }
    }

    private struct Seg { let entry: EPGEntry?; let width: CGFloat }

    /// Lücken und Sendungen nebeneinander (feste Breiten statt Verschieben, damit die Fernbedienung richtig springt)
    private func segments(_ list: [EPGEntry], end: Date) -> [Seg] {
        var out: [Seg] = []
        var cursor = base
        for e in list {
            let s = max(e.start ?? base, base), en = min(e.end ?? end, end)
            if en <= s { continue }
            if s > cursor { out.append(Seg(entry: nil, width: CGFloat(s.timeIntervalSince(cursor) / 60) * pxPerMin)) }
            out.append(Seg(entry: e, width: CGFloat(en.timeIntervalSince(s) / 60) * pxPerMin))
            cursor = en
        }
        return out
    }

    private func cell(_ c: TVItem, _ e: EPGEntry, width: CGFloat) -> some View {
        let now = isNow(e)
        return Button { full(c) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(UI.font(21, .bold)).lineLimit(1)
                Text("\(fmt(e.start)) – \(fmt(e.end))").font(UI.font(16)).foregroundColor(now ? UI.gold : UI.muted)
            }
            .padding(.horizontal, 14)
            .frame(width: max(8, width - 8), height: rowH, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                if now { Rectangle().fill(UI.gold2).frame(width: max(0, (width - 8) * e.progress), height: 3) }
            }
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 8)), normal: now ? UI.tan(0.22) : .white.opacity(0.06),
                               focusFill: UI.tan(0.4)))
        .frame(width: width, alignment: .leading)
        .focused($focus, equals: .cell(c.id, e.start?.timeIntervalSince1970 ?? 0))
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack(spacing: 34) {
            hint("◀ ▶", "Zeit"); hint("▲ ▼", "Sender"); hint("OK", "Ansehen"); hint("Menü", "Zurück")
            Spacer()
        }
    }

    private func hint(_ k: String, _ t: String) -> some View {
        (Text(k + " ").font(UI.font(21, .bold)).foregroundColor(UI.text) + Text(t).font(UI.font(21)).foregroundColor(UI.muted))
    }

    private func full(_ c: TVItem) {
        if engine.item?.id != c.id || engine.kind != .live {
            guard let u = store.url(c, .live) else { return }
            engine.play(u, item: c, kind: .live)
        }
        engine.items = channels
        engine.index = channels.firstIndex(of: c) ?? 0
        nav.push(.player)
    }
}
