import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var resume: ResumeBook
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("Logo")
                .resizable().scaledToFit()
                .shadow(color: .black.opacity(0.55), radius: 10, y: 6)
                .place(0, 148, 1920, 127, alignment: .center)

            HStack(spacing: 22) {
                RoundButton(icon: "search") { nav.push(.search) }.focused($focus, equals: "top-search")
                RoundButton(icon: "refresh") { Task { await store.reload() } }.focused($focus, equals: "top-reload")
            }
            .place(1464, 26, 206, 92)

            HStack(spacing: 44) {
                circle("live", "tv", "LIVE TV") { nav.push(.live) }
                circle("epg", "epg", "EPG") { nav.push(.epg) }
                circle("movies", "film", "FILME") { nav.push(.movies) }
                circle("series", "series", "SERIEN") { nav.push(.series) }
            }
            .place(0, 330, 1920, 346, alignment: .center)

            HStack(spacing: 20) {
                if !resume.list(source: store.sourceName).isEmpty {
                    tile("continue", "resume", "WEITERSCHAUEN") { nav.push(.continueWatching) }
                }
                tile("favs", "star", "FAVORITEN") { nav.push(.favorites) }
                tile("search", "search", "SUCHE") { nav.push(.search) }
                tile("football", "ball", "FUSSBALL") { nav.push(.football) }
                tile("settings", "gear", "EINSTELLUNGEN") { nav.push(.settings) }
            }
            .place(0, 771, 1920, 126, alignment: .center)

            if let exp = store.expiry {
                Text("Abo gültig bis \(exp.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()))")
                    .font(UI.font(30, .bold))
                    .shadow(color: .black.opacity(0.7), radius: 3, y: 2)
                    .place(0, 1000, 1920, 46, alignment: .center)
            }
        }
        .frame(width: 1920, height: 1080)
        .defaultFocus($focus, nav.lastFocus["home"] ?? "live")
        .onChange(of: focus) { _, f in if let f = f { nav.lastFocus["home"] = f } }
    }

    private func circle(_ key: String, _ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Icon(icon, 120).padding(.top, 81)
                Text(label).font(UI.font(40, .bold)).tracking(1).padding(.top, 20)
                Spacer(minLength: 0)
            }
            .frame(width: 346, height: 346)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(Circle()), normal: .black.opacity(0.42), focusFill: UI.tan(0.38),
                               border: .white.opacity(0.7), borderWidth: 3, scale: 1.06))
        .focused($focus, equals: key)
    }

    private func tile(_ key: String, _ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Icon(icon, 46).padding(.top, 20)
                Text(label).font(UI.font(21, .bold)).tracking(0.5).padding(.top, 10)
                Spacer(minLength: 0)
            }
            .frame(width: 204, height: 126)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)), normal: .black.opacity(0.45),
                               focusFill: UI.tan(0.38), border: .white.opacity(0.5), borderWidth: 2))
        .focused($focus, equals: key)
    }
}
