import SwiftUI

// MARK: - Sortieren (Filme und Serien)

enum SortMode: String, CaseIterable, Identifiable {
    case standard = "default"
    case newest = "new"
    case rating
    case year
    case az

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .newest: return "Neueste zuerst"
        case .rating: return "Beste Bewertung"
        case .year: return "Erscheinungsjahr"
        case .az: return "A – Z"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "list.bullet"
        case .newest: return "clock"
        case .rating: return "star"
        case .year: return "calendar"
        case .az: return "textformat"
        }
    }
}

enum Sorter {
    /// Name zum Sortieren: ohne Länderkürzel vorne („DE - “), ohne Akzente, klein
    static func key(_ name: String) -> String {
        var s = name
        if let r = s.range(of: "^[\\[(|]?\\s*(?:[A-Z]{2}|GER|ENG|DEU|4K)\\s*[\\])|:-]+\\s*", options: .regularExpression) {
            s.removeSubrange(r)
        }
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        if let r = s.range(of: "^[^a-z0-9]+", options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    private struct Row<T> {
        let i: Int
        let item: T
        let key: String
        let added: Int
        let rating: Double
        let year: Int
    }

    /// Stabil sortieren (gleiche Werte behalten die Reihenfolge des Anbieters)
    static func sort<T>(_ list: [T], _ mode: SortMode,
                        name: (T) -> String, added: (T) -> Int, rating: (T) -> Double, year: (T) -> Int) -> [T] {
        guard mode != .standard, list.count > 1 else { return list }
        var rows: [Row<T>] = []
        rows.reserveCapacity(list.count)
        for (i, item) in list.enumerated() {
            let k: String = mode == .az ? key(name(item)) : ""
            rows.append(Row(i: i, item: item, key: k, added: added(item), rating: rating(item), year: year(item)))
        }
        rows.sort { (a: Row<T>, b: Row<T>) -> Bool in
            switch mode {
            case .az:
                return a.key != b.key ? a.key < b.key : a.i < b.i
            case .newest:
                return a.added != b.added ? a.added > b.added : a.i < b.i
            case .rating:
                return a.rating != b.rating ? a.rating > b.rating : a.i < b.i
            case .year:
                if a.year != b.year { return a.year > b.year }
                return a.rating != b.rating ? a.rating > b.rating : a.i < b.i
            case .standard:
                return a.i < b.i
            }
        }
        return rows.map { $0.item }
    }
}

/// Knopf oben rechts: Sortierung wählen
struct SortMenu: View {
    @Binding var raw: String

    var body: some View {
        Menu {
            Picker("Sortieren", selection: $raw) {
                ForEach(SortMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .foregroundStyle(Theme.gold)
        }
    }
}

// MARK: - Bewertung

func ratingText(_ value: Double) -> String {
    String(format: "%.1f", value)
}

/// Kleines Abzeichen „★ 7.5“ oben links auf dem Poster
struct RatingBadge: View {
    let value: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill").font(.system(size: 8))
            Text(ratingText(value)).font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(Theme.goldLight)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.72)))
        .padding(4)
    }
}

// MARK: - Trailer

/// Öffnet den Trailer in der YouTube-App (oder in Safari, wenn sie fehlt)
struct TrailerButton: View {
    let id: String
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { openURL(url) }
        } label: {
            Label("Trailer", systemImage: "play.rectangle")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.vertical, compact ? 6 : 10)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
