import SwiftUI

// Aussehen wie die Android-/Fire-TV-Oberfläche (style.css). Alle Maße in Punkten auf 1920 × 1080 –
// das ist auf dem Apple TV genau die Bildschirmgröße in Punkten, also 1:1 wie auf Android.

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255,
                  opacity: opacity)
    }
}

enum UI {
    static var gold: Color { Theme.color(0xf4dc9e) }
    static var gold2: Color { Theme.color(0xd9b066) }
    static let text = Color(rgb: 0xf2efe8)
    static let muted = Color(rgb: 0xa7a39a)
    static var dark: Color { Theme.current.hue == nil ? Color(rgb: 0x1a1408) : Color(rgb: 0x101014) }
    static func tan(_ a: Double) -> Color { Theme.color(0xd9b066, a) }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

extension View {
    /// Absolut platzieren wie in der Android-Oberfläche (links/oben, Breite/Höhe)
    func place(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, alignment: Alignment = .topLeading) -> some View {
        self.frame(width: w, height: h, alignment: alignment).position(x: x + w / 2, y: y + h / 2)
    }
}

// MARK: - Hintergrund (goldene Lichtstreifen)

private func cssGradient(_ deg: Double, _ stops: [(Color, Double)], _ w: CGFloat, _ h: CGFloat) -> LinearGradient {
    let a: Double = deg * Double.pi / 180
    let sa: Double = Foundation.sin(a), ca: Double = Foundation.cos(a)
    let W = Double(w), H = Double(h)
    let len: Double = Swift.abs(W * sa) + Swift.abs(H * ca)
    let dx: Double = sa * len / 2 / W, dy: Double = -ca * len / 2 / H
    return LinearGradient(stops: stops.map { Gradient.Stop(color: $0.0, location: $0.1) },
                          startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                          endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
}

struct AppBackground: View {
    var body: some View {
        let w: CGFloat = 1920, h: CGFloat = 1080
        ZStack {
            cssGradient(135, [(Color(rgb: 0x1d1a17), 0), (Color(rgb: 0x0c0d10), 1)], w, h)
            cssGradient(20, [(.clear, 0.61), (.black.opacity(0.40), 0.64), (.black.opacity(0.40), 0.68), (.clear, 0.71)], w, h)
            cssGradient(115, [(.clear, 0.57), (UI.tan(0.14), 0.60), (UI.tan(0.14), 0.69), (.clear, 0.72)], w, h)
            cssGradient(160, [(.clear, 0.29), (UI.tan(0.30), 0.32), (UI.tan(0.08), 0.46), (.clear, 0.49)], w, h)
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Uhr oben rechts

struct ClockView: View {
    private static let days = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
    private static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let c = Calendar.current.dateComponents([.hour, .minute, .second, .weekday, .day, .month], from: ctx.date)
            VStack(alignment: .trailing, spacing: 5) {
                (Text(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)).foregroundColor(UI.text)
                 + Text(String(format: ":%02d", c.second ?? 0)).foregroundColor(UI.gold))
                    .font(UI.font(30, .bold))
                Text("\(Self.days[((c.weekday ?? 1) - 1) % 7]), \(c.day ?? 1). \(Self.months[((c.month ?? 1) - 1) % 12])")
                    .font(UI.font(17))
                    .foregroundColor(Color(rgb: 0xb9b4a9))
            }
            .shadow(color: .black.opacity(0.75), radius: 3, y: 2)
        }
    }
}

// MARK: - Symbole (dieselben Linien-Symbole wie auf Android)

struct Icon: View {
    let name: String
    var size: CGFloat
    init(_ name: String, _ size: CGFloat) { self.name = name; self.size = size }
    var body: some View {
        Image("ic-" + name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
    }
}

// MARK: - Fokus wie auf Android: goldener Rahmen mit Schein, goldene Fläche

struct GoldStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    var normal: Color = .clear
    var focusFill: Color = UI.tan(0.40)
    var active: Bool = false
    var activeFill: Color = UI.tan(0.22)
    var border: Color = .clear
    var borderWidth: CGFloat = 0
    var scale: CGFloat = 1
    var ring: Bool = true
    /// Knopf: im Fokus ganz gold mit dunkler Schrift
    var solid: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GoldBody(configuration: configuration, style: self)
    }
}

private struct GoldBody: View {
    let configuration: ButtonStyle.Configuration
    let style: GoldStyle
    @Environment(\.isFocused) private var focused

    var body: some View {
        let fill: Color = focused ? (style.solid ? UI.gold : style.focusFill) : (style.active ? style.activeFill : style.normal)
        configuration.label
            .foregroundColor(style.solid && focused ? UI.dark : UI.text)
            .background(style.shape.fill(fill))
            .overlay(style.shape.stroke(style.border, lineWidth: style.borderWidth))
            .overlay(style.shape.stroke(UI.gold, lineWidth: focused && style.ring && !style.solid ? 4 : 0).padding(-2))
            .shadow(color: focused && style.ring ? UI.gold.opacity(0.45) : .clear, radius: 14)
            .scaleEffect(focused ? style.scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Runder Knopf oben rechts (Suche, Neu laden)
struct RoundButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Icon(icon, 44).frame(width: 92, height: 92)
        }
        .buttonStyle(GoldStyle(shape: AnyShape(Circle()), normal: .black.opacity(0.45), ring: true, solid: true))
    }
}

/// Bild eines Senders, Films oder einer Serie (Demo: Farbfläche mit Titel wie auf Android)
struct ArtView: View {
    let art: Art
    var poster = false

    var body: some View {
        switch art {
        case .url(let u):
            AsyncImage(url: u, transaction: Transaction(animation: nil)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: poster ? .fill : .fit)
                } else {
                    Color.white.opacity(0.05)
                }
            }
        case .demo(let title, let color):
            GeometryReader { g in
                ZStack {
                    LinearGradient(colors: [Color(rgb: color), Color(rgb: 0x111418)], startPoint: .top, endPoint: .bottom)
                    Text(title)
                        .font(UI.font(g.size.height * (poster ? 0.075 : 0.16), .bold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                    Text("DEMO")
                        .font(UI.font(g.size.height * 0.043))
                        .foregroundColor(UI.gold2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, g.size.height * 0.05)
                }
            }
        case .none:
            Color.white.opacity(0.05)
        }
    }
}
