import SwiftUI

enum Theme {
    static let gold = Color(red: 0.85, green: 0.69, blue: 0.40)
    static let goldLight = Color(red: 0.96, green: 0.86, blue: 0.62)
    static let dark = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let panel = Color.black.opacity(0.42)
}

/// Dunkler Hintergrund mit goldenen diagonalen Flächen
struct GoldBackground: View {
    var dim: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.16, blue: 0.15), Theme.dark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.18))
                    p.addLine(to: CGPoint(x: w, y: h * 0.62))
                    p.addLine(to: CGPoint(x: w, y: h * 0.82))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.38))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Theme.goldLight.opacity(0.6), Theme.gold.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))

                Path { p in
                    p.move(to: CGPoint(x: w * 0.62, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.92, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.30, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Theme.gold.opacity(0.18))

                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.74))
                    p.addLine(to: CGPoint(x: w, y: h * 0.34))
                    p.addLine(to: CGPoint(x: w, y: h * 0.42))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.86))
                    p.closeSubpath()
                }
                .fill(Color.black.opacity(0.35))

                Color.black.opacity(dim)
            }
        }
        .ignoresSafeArea()
    }
}

/// Große runde Kachel (Live TV, EPG, Filme, Serien)
struct CircleTile: View {
    let title: String
    let icon: String

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.38))
            Circle().stroke(Color.white.opacity(0.65), lineWidth: 1.5)
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .light))
                Text(title.uppercased())
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Circle())
    }
}

/// Kleine eckige Kachel (Favoriten, Suche, Konto, Einstellungen)
struct SquareTile: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 24))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.goldLight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}
