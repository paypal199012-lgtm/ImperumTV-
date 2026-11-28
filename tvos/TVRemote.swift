import Foundation
import GameController

/// Unterscheidet bei der Siri Remote echtes Drücken von bloßem Wischen auf der Touch-Fläche.
/// Wischen meldet Bewegung auf der Fläche ohne Klick. Andere Fernbedienungen (Fernseher, IR)
/// berühren die Fläche nicht und werden deshalb nie ausgefiltert.
@MainActor
final class TVRemote {
    static let shared = TVRemote()
    private var lastTouch = Date.distantPast
    private var lastClick = Date.distantPast
    private var hooked = Set<ObjectIdentifier>()

    /// Wischen im Vollbild ignorieren (Einstellung, Standard: an)
    static var clickOnly: Bool {
        get { UserDefaults.standard.object(forKey: "tv.clickZap") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.clickZap") }
    }

    func start() {
        GCController.controllers().forEach(hook)
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { TVRemote.shared.hook(c) } }
        }
    }

    private func hook(_ c: GCController) {
        guard let pad = c.microGamepad, !hooked.contains(ObjectIdentifier(c)) else { return }
        hooked.insert(ObjectIdentifier(c))
        // Handler setzen, ohne die des Systems zu stören (nur Zeitpunkte merken)
        let oldDpad = pad.dpad.valueChangedHandler
        pad.dpad.valueChangedHandler = { d, x, y in
            oldDpad?(d, x, y)
            DispatchQueue.main.async { MainActor.assumeIsolated { TVRemote.shared.lastTouch = Date() } }
        }
        let oldA = pad.buttonA.pressedChangedHandler
        pad.buttonA.pressedChangedHandler = { b, v, p in
            oldA?(b, v, p)
            if p { DispatchQueue.main.async { MainActor.assumeIsolated { TVRemote.shared.lastClick = Date() } } }
        }
    }

    /// Kam die letzte Richtungs-Eingabe nur vom Wischen? (Finger auf der Fläche, aber kein Klick)
    func wasSwipe() -> Bool {
        let now = Date()
        let touching = now.timeIntervalSince(lastTouch) < 0.45
        let clicked = now.timeIntervalSince(lastClick) < 0.45
        return touching && !clicked
    }
}
