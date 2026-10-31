import SwiftUI

/// Merkt sich ein teures Ergebnis (z. B. gefilterte Liste), bis sich die Eingaben ändern.
/// Wird als @State gehalten – ein neues Zeichnen der Ansicht rechnet dann nicht alles neu.
final class Memo<Value> {
    private var key: [AnyHashable]?
    private var value: Value?

    func get(_ key: [AnyHashable], _ make: () -> Value) -> Value {
        if let v = value, self.key == key { return v }
        let v = make()
        self.key = key
        value = v
        return v
    }

    func reset() {
        key = nil
        value = nil
    }
}

/// Hält einen Player, ohne dass die ganze Ansicht bei jedem Zeit-Tick neu gezeichnet wird
final class PlayerHolder: ObservableObject {
    let model = PlayerModel()
}

extension Parental {
    /// Ändert sich, sobald sich etwas an Sperren, Freischaltung oder Profil ändert
    var stamp: Int {
        var h = Hasher()
        h.combine(pinHash)
        h.combine(autoAdult)
        h.combine(cats)
        h.combine(isUnlocked)
        h.combine(Profiles.shared.current)
        return h.finalize()
    }
}
