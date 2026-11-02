import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Wiedergabelisten (MAC-Adresse, Geräte-Schlüssel, QR-Code wie auf Android)

func qrImage(_ text: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

struct PlaylistsScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @State private var busy = false

    private var link: String {
        RemoteConfig.website + "?mac=" + store.device.mac.lowercased() + "&key=" + store.device.key + "&app=apple"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 22) {
                Image("Logo").resizable().scaledToFit().themedLogo().frame(height: 60)
                Text("Wiedergabelisten").font(UI.font(40, .bold))
            }
            .place(70, 34, 1000, 70)

            if store.lists.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Noch keine Wiedergabeliste").font(UI.font(32, .bold)).foregroundColor(UI.gold)
                    Text("Scanne den QR-Code unten mit dem Handy oder öffne die Website und gib dort MAC-Adresse und Geräte-Schlüssel ein. Die Wiedergabeliste erscheint danach hier von selbst.")
                        .font(UI.font(25)).foregroundColor(Color(rgb: 0xd6d1c6)).lineSpacing(6)
                }
                .place(100, 200, 980, 230)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 30) {
                    ForEach(store.lists) { l in
                        card(l.name, l.address, active: store.savedId == l.id) { Task { await choose { await store.use(l) } } }
                    }
                    card("Demo", "Freie Testvideos zum Ausprobieren", active: store.source == .demo) { Task { await choose { store.useDemo() } } }
                }
                .padding(20)
            }
            .place(store.lists.isEmpty ? 1100 : 80, store.lists.isEmpty ? 180 : 160, store.lists.isEmpty ? 780 : 1760, 240)

            if let m = store.message {
                Text(m).font(UI.font(24)).foregroundColor(Color(rgb: 0xff8a7a)).place(100, 430, 1720, 70)
            }

            // QR-Code und Gerätedaten
            HStack(spacing: 50) {
                if let img = qrImage(link) {
                    Image(uiImage: img).interpolation(.none).resizable()
                        .frame(width: 220, height: 220).padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Scanne den QR-Code, um eine Wiedergabeliste hinzuzufügen.").font(UI.font(25)).foregroundColor(UI.gold)
                    Text(store.listsLoaded ? "Dein Gerät ist verbunden." : "Gerät wird angemeldet …").font(UI.font(28, .bold))
                    Text(RemoteConfig.websiteHost).font(UI.font(21, .semibold)).foregroundColor(UI.gold2)
                }
                .frame(width: 560, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("MAC-Adresse").font(UI.font(24))
                    Text(store.device.mac.lowercased()).font(.system(size: 32, weight: .bold, design: .monospaced)).foregroundColor(UI.gold)
                    Text("Geräte-Schlüssel").font(UI.font(24)).padding(.top, 10)
                    Text(store.device.key).font(.system(size: 32, weight: .bold, design: .monospaced)).foregroundColor(UI.gold)
                }
                Spacer()
                Button { Task { busy = true; await store.refreshLists(); busy = false } } label: {
                    Text(busy ? "Lädt …" : "Aktualisieren").font(UI.font(26, .bold)).padding(.horizontal, 40).frame(height: 64)
                }
                .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .white.opacity(0.08), ring: false, solid: true))
            }
            .padding(.horizontal, 50)
            .frame(width: 1720, height: 330)
            .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1.5))
            .place(100, 520, 1720, 330)

            Text("ImperumTV ist ein Player für deine eigenen Wiedergabelisten · ImperumTV verkauft keine Inhalte")
                .font(UI.font(21)).foregroundColor(UI.muted).place(0, 960, 1920, 40, alignment: .center)
        }
        .frame(width: 1920, height: 1080)
        .task {
            // Liste auf der Website eingetragen? Alle 15 s nachsehen, solange dieser Bildschirm offen ist
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await store.refreshLists()
            }
        }
    }

    private func card(_ title: String, _ sub: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(UI.font(34, .bold)).foregroundColor(UI.gold).lineLimit(1)
                Text(sub).font(UI.font(23)).foregroundColor(UI.text.opacity(0.85)).lineLimit(2)
                Spacer(minLength: 0)
                if active { Text("● Aktiv").font(UI.font(20, .bold)).foregroundColor(UI.gold2) }
            }
            .padding(24)
            .frame(width: 400, height: 190, alignment: .topLeading)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 14)), normal: .black.opacity(0.4),
                               focusFill: UI.tan(0.42), border: .white.opacity(0.15), borderWidth: 1.5, scale: 1.04))
    }

    private func choose(_ f: () async -> Void) async {
        await f()
        if store.hasSource && store.message == nil { nav.reset(.home) }
    }
}

// MARK: - Favoriten

struct FavoritesScreen: View {
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        let live = store.live.filter { store.isFav($0, .live) }
        let movies = store.vod.filter { store.isFav($0, .movie) }
        let series = store.series.filter { store.isFav($0, .series) }
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Favoriten")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if live.isEmpty && movies.isEmpty && series.isEmpty {
                        Text("Noch keine Favoriten. In Live TV „★ Favorit“ drücken, bei Filmen und Serien OK lange drücken.")
                            .font(UI.font(28)).foregroundColor(UI.muted).padding(.top, 40)
                    }
                    ResultRows(title: "Sender", items: live, kind: .live)
                    ResultRows(title: "Filme", items: movies, kind: .movie)
                    ResultRows(title: "Serien", items: series, kind: .series)
                }
                .padding(30)
            }
            .place(40, 100, 1840, 980)
        }
        .frame(width: 1920, height: 1080)
    }
}

/// Waagerechte Reihe mit Ergebnissen (Favoriten, Suche)
struct ResultRows: View {
    let title: String
    let items: [TVItem]
    let kind: MediaKind
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHead(text: "\(title) · \(items.count)")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 22) {
                        ForEach(items.prefix(60)) { it in
                            if kind == .live {
                                Button { open(it) } label: {
                                    VStack(spacing: 10) {
                                        ArtView(art: it.art).frame(width: 220, height: 124).clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(it.name).font(UI.font(22, .medium)).lineLimit(2).frame(width: 220, height: 56, alignment: .top)
                                    }
                                    .padding(10)
                                }
                                .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 12)), scale: 1.05))
                            } else {
                                PosterCard(item: it, fav: store.isFav(it, kind)) { open(it) }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func open(_ it: TVItem) {
        switch kind {
        case .series: nav.push(.seriesDetail(it))
        case .movie: nav.push(.movieDetail(it))
        case .live:
            guard let u = store.url(it, kind) else { return }
            if kind == .live { engine.items = items; engine.index = items.firstIndex(of: it) ?? 0 }
            engine.play(u, item: it, kind: kind, fallback: kind == .movie ? store.altURL(it) : nil)
            nav.push(.player)
        }
    }
}

// MARK: - Suche über Sender, Filme und Serien

struct SearchScreen: View {
    @EnvironmentObject var store: TVStore
    @State private var query = ""
    @FocusState private var fieldFocus: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let live = q.count < 2 ? [] : store.visible(.live).filter { $0.name.lowercased().contains(q) }
        let movies = q.count < 2 ? [] : store.visible(.movie).filter { $0.name.lowercased().contains(q) }
        let series = q.count < 2 ? [] : store.visible(.series).filter { $0.name.lowercased().contains(q) }
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Suche")
            TextField("Sender, Filme oder Serien suchen", text: $query)
                .font(UI.font(30, .medium))
                .focused($fieldFocus)
                .place(70, 110, 1000, 80)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if q.count >= 2 && live.isEmpty && movies.isEmpty && series.isEmpty {
                        Text("Nichts gefunden für „\(query)“").font(UI.font(28)).foregroundColor(UI.muted)
                    }
                    ResultRows(title: "Sender", items: live, kind: .live)
                    ResultRows(title: "Filme", items: movies, kind: .movie)
                    ResultRows(title: "Serien", items: series, kind: .series)
                }
                .padding(30)
            }
            .place(40, 200, 1840, 880)
        }
        .frame(width: 1920, height: 1080)
        .onAppear { fieldFocus = true }
    }
}

