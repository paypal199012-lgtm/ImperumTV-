import SwiftUI
import AVFoundation

// MARK: - Schlaf-Timer: stoppt die Wiedergabe nach der gewählten Zeit (1 Minute vorher Warnung)

extension Notification.Name {
    static let sleepTimerFired = Notification.Name("imptv.sleepTimerFired")
}

final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    @Published private(set) var until: Date?
    @Published var showWarning = false
    /// Zählt jede Sekunde hoch, damit Anzeigen die Restzeit auffrischen
    @Published private(set) var tickCount = 0
    private var timer: Timer?

    var active: Bool { (until ?? .distantPast) > Date() }
    var minutesLeft: Int { max(0, Int(ceil((until ?? Date()).timeIntervalSinceNow / 60))) }
    var secondsLeft: Int { max(0, Int(ceil((until ?? Date()).timeIntervalSinceNow))) }

    func set(minutes: Double) { set(until: Date().addingTimeInterval(minutes * 60)) }

    func set(until date: Date) {
        until = date
        showWarning = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func extend30() {
        set(minutes: 30)
    }

    func cancel() {
        until = nil
        showWarning = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let u = until else { return }
        let left = u.timeIntervalSinceNow
        if left <= 0 {
            cancel()
            NotificationCenter.default.post(name: .sleepTimerFired, object: nil)
            return
        }
        if left <= 60 && !showWarning { showWarning = true }
        tickCount &+= 1
    }
}

/// „☾ 28 Min“ neben der Uhr, solange der Timer läuft
struct SleepBadge: View {
    @ObservedObject private var sleep = SleepTimer.shared
    var body: some View {
        if sleep.active {
            Text("☾ \(sleep.minutesLeft) Min")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.goldLight)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().stroke(Theme.goldLight, lineWidth: 1))
                .allowsHitTesting(false)
        }
    }
}

/// Warnung 1 Minute vor Ende: verlängern, jetzt beenden oder Timer aus
struct SleepWarning: View {
    @ObservedObject private var sleep = SleepTimer.shared
    var body: some View {
        if sleep.showWarning {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 10) {
                    Text("☾").font(.system(size: 40))
                    Text("Gute Nacht").font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text("Die Wiedergabe stoppt in \(sleep.secondsLeft) Sekunden.")
                        .font(.subheadline).foregroundStyle(Theme.goldLight)
                        .monospacedDigit()
                    HStack(spacing: 10) {
                        Button("+ 30 Minuten") { sleep.extend30() }
                            .buttonStyle(.borderedProminent).tint(Theme.gold)
                        Button("Jetzt beenden") {
                            sleep.cancel()
                            NotificationCenter.default.post(name: .sleepTimerFired, object: nil)
                        }
                        .buttonStyle(.bordered).tint(.white)
                        Button("Timer aus") { sleep.cancel() }
                            .buttonStyle(.bordered).tint(.white)
                    }
                    .padding(.top, 6)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.goldLight, lineWidth: 1.2))
            }
            .transition(.opacity)
        }
    }
}

/// Auswahl als Bestätigungsdialog; end = Ende der Sendung/des Films (optional)
struct SleepTimerDialog: ViewModifier {
    @Binding var isPresented: Bool
    var end: Date?
    var endLabel: String
    @ObservedObject private var sleep = SleepTimer.shared

    func body(content: Content) -> some View {
        content.confirmationDialog("Schlaf-Timer", isPresented: $isPresented, titleVisibility: .visible) {
            if sleep.active {
                Button("Aus (noch \(sleep.minutesLeft) Min)", role: .destructive) { sleep.cancel() }
            }
            ForEach([15, 30, 60, 90], id: \.self) { m in
                Button("\(m) Minuten") { sleep.set(minutes: Double(m)) }
            }
            if let end, end.timeIntervalSinceNow > 60 {
                Button(endLabel + " · " + Self.hm.string(from: end)) { sleep.set(until: end) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Wiedergabe stoppt automatisch – praktisch zum Einschlafen.")
        }
    }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}

extension View {
    func sleepTimerDialog(isPresented: Binding<Bool>, end: Date? = nil, endLabel: String = "") -> some View {
        modifier(SleepTimerDialog(isPresented: isPresented, end: end, endLabel: endLabel))
    }
}

// MARK: - Verbindungsanzeige im Player

/// Gut / Mäßig / Schwach aus den Hängern der letzten 2 Minuten
enum NetLevel { case wait, good, mid, bad
    var text: String { self == .bad ? "Schwache Verbindung" : self == .mid ? "Mäßige Verbindung" : "Gute Verbindung" }
    var color: Color { self == .bad ? Color(red: 0.94, green: 0.44, blue: 0.44) : self == .mid ? Color(red: 0.94, green: 0.76, blue: 0.35) : Color(red: 0.44, green: 0.85, blue: 0.54) }
    var bars: Int { self == .bad ? 1 : self == .mid ? 2 : 4 }
}

struct NetBadge: View {
    let level: NetLevel
    let mbit: Double
    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < level.bars ? level.color : Color.white.opacity(0.25))
                        .frame(width: 4, height: CGFloat(5 + i * 4))
                }
            }
            Text(level.text).font(.caption.weight(.bold)).foregroundStyle(.white)
            if mbit > 0 {
                Text("· " + (mbit >= 10 ? String(Int(mbit.rounded())) : String(format: "%.1f", mbit).replacingOccurrences(of: ".", with: ",")) + " Mbit/s")
                    .font(.caption2).foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().stroke(level.color, lineWidth: 1.5))
        .allowsHitTesting(false)
    }
}
