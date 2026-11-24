import SwiftUI

// MARK: - Leitfaden „Was kann ImperumTV?“ (wie in der Android-App): alle Funktionen kurz erklärt und wo man sie findet

private struct GuideItem: Hashable { let icon: String; let title: String; let text: String; let path: String }

private let guideSections: [(String, String, [GuideItem])] = [
    ("Live TV", "tv", [
        GuideItem(icon: "📺", title: "Vorschau und Vollbild", text: "Auf einem Sender stehen bleiben zeigt die Vorschau, OK schaltet auf Vollbild.", path: "Live TV"),
        GuideItem(icon: "📅", title: "Programm (EPG)", text: "Was läuft jetzt und später – alle Sender auf einen Blick. Uhrzeit und Programm stellt die App selbst richtig.", path: "Startseite → EPG"),
        GuideItem(icon: "🎚", title: "Sender zusammenfassen", text: "Denselben Sender in HD, FHD und 4K gibt es nur einmal. Lange drücken wählt die Qualität.", path: "Einstellungen → Sender zusammenfassen"),
        GuideItem(icon: "🔁", title: "Ersatzsender", text: "Zeigt ein Sender kein Bild, wechselt die App von selbst auf eine andere Qualität desselben Senders.", path: "Einstellungen → Ersatzsender"),
        GuideItem(icon: "⚽", title: "Fußball", text: "Welche Spiele heute laufen und auf welchem Sender – Bundesliga, Champions League und mehr.", path: "Startseite → Fußball")
    ]),
    ("Filme & Serien", "film", [
        GuideItem(icon: "▶", title: "Weiterschauen auf allen Geräten", text: "Am Fernseher angefangen, am Handy weiter. Weiterschauen, „Gesehen“ und Favoriten sind überall gleich.", path: "Filme / Serien → Weiter ansehen"),
        GuideItem(icon: "🎬", title: "Doppelte Filme & Serien", text: "Gibt es einen Film oder eine Serie mehrmals (4K, HD, Deutsch, Englisch …), steht er nur einmal da. Beim Öffnen wählst du die Fassung.", path: "Einstellungen → Doppelte Filme & Serien"),
        GuideItem(icon: "🎭", title: "Besetzung", text: "Bei Serien die Schauspieler mit Fotos.", path: "Serie öffnen"),
        GuideItem(icon: "🆕", title: "Neue Folgen", text: "Serien, die du schaust, erscheinen hier, sobald es neue Folgen gibt. Lange drücken entfernt sie aus der Liste.", path: "Serien → Neue Folgen"),
        GuideItem(icon: "🗂", title: "Genres und Sortieren", text: "Filme und Serien nach Genre ansehen und nach Neuheit, A–Z oder Bewertung sortieren.", path: "Filme / Serien → Genres, Sortieren"),
        GuideItem(icon: "★", title: "Favoriten", text: "Lange drücken auf Sender, Film oder Serie merkt sie als Favorit.", path: "Startseite → Favoriten")
    ]),
    ("Bedienung", "search", [
        GuideItem(icon: "🔍", title: "Suche", text: "Sender, Filme und Serien auf einmal finden.", path: "Startseite → Suche"),
        GuideItem(icon: "🎨", title: "Farbthema", text: "Gold, Blau, Pink und weitere Farben für die ganze App.", path: "Einstellungen → Farbthema"),
        GuideItem(icon: "💤", title: "Schlaf-Timer", text: "Die Wiedergabe stoppt nach der gewählten Zeit – praktisch zum Einschlafen.", path: "Einstellungen → Schlaf-Timer")
    ]),
    ("Familie & Konto", "users", [
        GuideItem(icon: "👥", title: "Profile", text: "Jedes Familienmitglied mit eigenen Favoriten und eigenem Weiterschauen.", path: "Einstellungen → Profile"),
        GuideItem(icon: "🔒", title: "Kinderschutz", text: "Kategorien mit einer PIN sperren.", path: "Einstellungen → Kinderschutz"),
        GuideItem(icon: "📋", title: "Wiedergabelisten", text: "Mehrere Listen speichern und wechseln. Neue Liste: QR-Code scannen und auf der Website eintragen.", path: "Einstellungen → Wiedergabelisten"),
        GuideItem(icon: "💾", title: "Sicherung", text: "Favoriten, Profile und Weiterschauen sichern und auf ein neues Gerät übernehmen.", path: "Einstellungen → Sicherung")
    ]),
    ("Hilfe", "shield", [
        GuideItem(icon: "🛟", title: "Fernhilfe", text: "Kommst du nicht weiter, sieht der Support ImperumTV auf deinem Bildschirm und hilft dir.", path: "Einstellungen → Fernhilfe"),
        GuideItem(icon: "📶", title: "Verbindungstest", text: "Prüft Internet, Geschwindigkeit und den Server deines Anbieters.", path: "Einstellungen → Verbindungstest")
    ])
]

struct GuideScreen: View {
    @State private var sec = 0
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenTitle(text: "Was kann ImperumTV?")
            Text("Links Bereich wählen · rechts blättern").font(UI.font(24)).foregroundColor(UI.muted)
                .place(1100, 44, 570, 34, alignment: .topTrailing)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(guideSections.enumerated()), id: \.offset) { i, s in
                    CatRow(name: s.0, count: s.2.count, active: sec == i, size: 28) { sec = i }
                        .remoteFocused($focus, equals: "sec\(i)")
                }
            }
            .padding(.vertical, 20).padding(.horizontal, 10)
            .place(4, 100, 416, 970)
            .focusSection()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.fixed(680), spacing: 24), GridItem(.fixed(680), spacing: 24)], alignment: .leading, spacing: 24) {
                    ForEach(guideSections[sec].2, id: \.self) { it in
                        Button {} label: {
                            HStack(alignment: .top, spacing: 20) {
                                Text(it.icon).font(.system(size: 44)).frame(width: 60)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(it.title).font(UI.font(30, .bold)).foregroundColor(UI.gold2)
                                    Text(it.text).font(UI.font(24)).foregroundColor(UI.text).fixedSize(horizontal: false, vertical: true)
                                    Text("📍 " + it.path).font(UI.font(21)).foregroundColor(UI.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(24).frame(width: 680, alignment: .topLeading)
                        }
                        .buttonStyle(GoldStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 16)), normal: .white.opacity(0.05), scale: 1.02))
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 14)
            }
            .place(440, 100, 1460, 980)
            .focusSection()
        }
        .frame(width: 1920, height: 1080)
        .onChange(of: focus) { _, f in
            if let f = f, f.hasPrefix("sec"), let i = Int(f.dropFirst(3)) { sec = i }
        }
    }
}
