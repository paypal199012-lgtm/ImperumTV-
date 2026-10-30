import Foundation
import UIKit

// MARK: - Fehlerberichte an den Admin (Website → Admin → Fehlerberichte)

/// Schickt Abstürze und Wiedergabefehler an die Datenbank, wie die Android-App.
/// Es werden nur Gerät, App-Version und der Fehlertext gesendet, keine Zugangsdaten.
enum CrashReport {
    private static var lastSent: [String: Date] = [:]

    /// App-Version, z. B. "iOS 2.0"
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        return "iOS " + v
    }

    /// Gerät, z. B. "Apple iPhone15,2 · iOS 18.1"
    static var device: String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return "Apple \(model) · iOS \(UIDevice.current.systemVersion)"
    }

    /// Beim Start aufrufen: fängt Abstürze ab und schickt einen gespeicherten Bericht nach
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(25).joined(separator: "\n")
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)"
            UserDefaults.standard.set(text, forKey: "pendingCrashReport")
            UserDefaults.standard.synchronize()
        }
        if let pending = UserDefaults.standard.string(forKey: "pendingCrashReport") {
            UserDefaults.standard.removeObject(forKey: "pendingCrashReport")
            // Kurz warten, bis das Netz bereit ist
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                send(kind: "absturz", message: pending)
            }
        }
    }

    /// Wiedergabefehler eines Senders/Films melden
    static func player(name: String, url: URL?, message: String) {
        var text = "Sender: \(name)\nFehler: \(message)"
        if let ext = url?.pathExtension, !ext.isEmpty { text += "\nFormat: \(ext)" }
        send(kind: "wiedergabe", message: text)
    }

    /// Bericht senden (gleicher Text höchstens einmal pro Minute)
    static func send(kind: String, message: String) {
        let now = Date()
        if let last = lastSent[message], now.timeIntervalSince(last) < 60 { return }
        lastSent[message] = now
        let id = DeviceIdentity.load()
        let body: [String: Any] = [
            "p_mac": id.mac, "p_key": id.key, "p_version": version, "p_device": device,
            "p_kind": kind, "p_message": String(message.prefix(6000))
        ]
        Task.detached(priority: .utility) {
            _ = try? await RemoteAPI.rpc("report_crash", body)
        }
    }
}
