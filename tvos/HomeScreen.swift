import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: TVStore
    @EnvironmentObject var resume: ResumeBook
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("Logo")
                .resizable().scaledToFit().themedLogo()
                .shadow(color: .black.opacity(0.55), radius: 10, y: 6)
                .place(0, 148, 1920, 127, alignment: .center)

            // Oben rechts: Knöpfe mit Text (wie auf Android), unter „Aktualisieren“ der Stand der Liste
            HStack(spacing: 18) {
                textButton("search", "Suchen", nil) { nav.push(.search) }.remoteFocused($focus, equals: "top-search")
                textButton("refresh", "Aktualisieren", freshText) { Task { await store.reload() } }.remoteFocused($focus, equals: "top-reload")
                RoundButton(icon: "users") { nav.push(.profiles) }.remoteFocused($focus, equals: "top-profile")
            }
            .place(640, 26, 1000, 92, alignment: .topTrailing)

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
                tile("football", "ball", "FUSSBALL") { nav.push(.football) }
                tile("settings", "gear", "EINSTELLUNGEN") { nav.push(.settings) }
            }
            .place(0, 771, 1920, 126, alignment: .center)

            if let exp = store.expiry {
                Text("Wiedergabeliste gültig bis \(exp.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()))")
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
        .remoteFocused($focus, equals: key)
    }

    /// „Stand 08:44 Uhr“ (heute) bzw. „Stand 23.11.“; während des Ladens „wird aktualisiert …“
    private var freshText: String? {
        if store.loading { return "wird aktualisiert …" }
        guard let d = store.freshAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'Stand' HH:mm 'Uhr'" : "'Stand' dd.MM."
        return f.string(from: d)
    }

    private func textButton(_ icon: String, _ title: String, _ sub: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Icon(icon, 34).foregroundColor(UI.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(UI.font(28, .bold))
                    if let sub = sub { Text(sub).font(UI.font(19)).foregroundColor(UI.gold) }
                }
            }
            .padding(.horizontal, 30).frame(height: 92)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(Capsule()), normal: .black.opacity(0.45), focusFill: UI.tan(0.38),
                               border: UI.tan(0.5), borderWidth: 1.5, scale: 1.05))
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
        .remoteFocused($focus, equals: key)
    }
}
