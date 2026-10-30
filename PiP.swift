import SwiftUI
import AVKit

// MARK: - Bild-in-Bild (PiP) wie in der Apple-TV-App
//
// Startet Bild-in-Bild, schließt sich der große Player und man kann in der App weiterblättern.
// Das kleine Fenster läuft weiter. „Zurück zur App“ im kleinen Fenster öffnet den Player wieder groß,
// das Schließen-Kreuz beendet die Wiedergabe.

final class PiPCenter: ObservableObject {
    static let shared = PiPCenter()

    struct Session: Identifiable {
        let id = UUID()
        let model: PlayerModel
        let channels: [Channel]
        let index: Int
        let isLive: Bool
        let resume: [ResumeInfo]?
    }

    /// Läuft gerade im kleinen Fenster (hält den Player am Leben)
    private(set) var active: Session?
    /// Wird gesetzt, wenn der Player wieder groß geöffnet werden soll
    @Published var restore: Session?
    /// Gerade beim Zurückholen (dann beim Ende von PiP nicht stoppen)
    private(set) var restoring = false
    private var restoreDone: ((Bool) -> Void)?

    /// PiP hat begonnen: Player merken, damit er nach dem Schließen des Bildschirms weiterläuft
    func started(_ session: Session) {
        if let old = active, old.model !== session.model { stopActive() }
        active = session
    }

    /// Ein anderer Player wird geöffnet: laufendes kleines Fenster beenden
    func willOpen(_ model: PlayerModel) {
        guard let s = active, s.model !== model, !restoring else { return }
        stopActive()
    }

    func stopActive() {
        guard let s = active else { return }
        active = nil
        s.model.stop()
    }

    /// „Zurück zur App“ im kleinen Fenster gedrückt
    func requestRestore(for model: PlayerModel, completion: @escaping (Bool) -> Void) {
        guard let s = active, s.model === model else {
            completion(false)
            return
        }
        restoring = true
        restoreDone = completion
        restore = Session(model: s.model, channels: s.channels, index: s.index, isLive: s.isLive, resume: s.resume)
        // Falls der Bildschirm nicht erscheint, nach 2 Sekunden trotzdem melden
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishRestore() }
    }

    /// Der große Player ist wieder da: PiP darf hineinfliegen
    func finishRestore() {
        guard let done = restoreDone else { return }
        restoreDone = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(true) }
    }

    /// PiP ist zu Ende (Kreuz oder Zurückholen)
    func ended(_ model: PlayerModel) {
        if restoring {
            restoring = false
            if active?.model === model { active = nil }
            return
        }
        // Mit dem Kreuz geschlossen und kein großer Player offen: Wiedergabe beenden
        if let s = active, s.model === model {
            active = nil
            model.stop()
        }
    }
}
