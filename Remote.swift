import Foundation

// MARK: - Einstellungen der Website

/// Verbindung zur ImperumTV-Website (Cloudflare) und zur Datenbank (Supabase)
enum RemoteConfig {
    static let supabaseURL = "https://dprwastkfqhisvsjrvrv.supabase.co"
    static let supabaseKey = "sb_publishable_LZau0nT_CfDUYqrzlQfM2Q_61r7g-K3"
    /// Website, auf der man Wiedergabelisten einträgt und das Gerät aktiviert
    static let website = "https://holy-mode-e130.imperumtv.workers.dev/"
    /// Nur zur Anzeige, der echte Preis steht in der Stripe-Funktion
    static let price = "9,99 €"

    static var websiteHost: String {
        var s = website
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - MAC-Adresse und Geräte-Schlüssel

/// Eigene MAC-Adresse und Geräte-Schlüssel für dieses iPhone/iPad.
/// iOS gibt die echte MAC-Adresse nicht heraus, deshalb wird einmalig eine erzeugt
/// und im Schlüsselbund gespeichert (bleibt auch nach dem Neuinstallieren gleich).
enum DeviceIdentity {
    static func load() -> (mac: String, key: String) {
        var mac = Keychain.load("deviceMAC") ?? UserDefaults.standard.string(forKey: "deviceMAC") ?? ""
        var key = Keychain.load("deviceKey") ?? UserDefaults.standard.string(forKey: "deviceKey") ?? ""
        if !isValidMAC(mac) { mac = makeMAC() }
        if !isValidKey(key) { key = makeKey() }
        Keychain.save(mac, for: "deviceMAC")
        Keychain.save(key, for: "deviceKey")
        UserDefaults.standard.set(mac, forKey: "deviceMAC")
        UserDefaults.standard.set(key, forKey: "deviceKey")
        return (mac, key)
    }

    static func makeMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE   // lokal vergebene Adresse
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func makeKey() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func isValidMAC(_ mac: String) -> Bool {
        mac.range(of: "^([0-9A-F]{2}:){5}[0-9A-F]{2}$", options: .regularExpression) != nil
    }

    static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }
}

// MARK: - Wiedergabeliste von der Website

struct RemotePlaylist: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let server: String
    let username: String
    let password: String
    let m3u: String

    /// Xtream-Zugang aus Server/Benutzer/Passwort oder aus einem get.php-Link
    var account: Account? {
        if !server.isEmpty, !username.isEmpty, !password.isEmpty {
            if let fromLink = Account.parse(link: server) { return fromLink }
            return Account(server: Account.normalizeServer(server), username: username, password: password)
        }
        if let fromLink = Account.parse(link: m3u) { return fromLink }
        return Account.parse(link: server)
    }

    /// Adresse ohne Zugangsdaten, zum Anzeigen
    var address: String {
        if let acc = account { return acc.server }
        let raw = m3u.isEmpty ? server : m3u
        return raw.components(separatedBy: "?").first ?? raw
    }
}

// MARK: - Testphase und Aktivierung

struct LicenseState: Codable, Equatable {
    var activated: Bool
    var trialUntil: Date?
    var freeUntil: Date?
    /// Unterschied zwischen Server-Uhr und Geräte-Uhr (gegen falsch gestellte Uhren)
    var offset: TimeInterval
    var checked: Date
    /// Wann der Admin die Kindersicherung zuletzt zurückgesetzt hat
    var parentalReset: String? = nil

    var now: Date { Date().addingTimeInterval(offset) }

    var isFree: Bool {
        guard !activated, let free = freeUntil else { return false }
        return free > now
    }

    var isActive: Bool {
        if activated { return true }
        if let trial = trialUntil, trial > now { return true }
        return isFree
    }

    var isTrial: Bool { !activated && !isFree }

    var daysLeft: Int {
        guard let trial = trialUntil else { return 0 }
        return max(0, Int(ceil(trial.timeIntervalSince(now) / 86_400)))
    }

    var text: String {
        if activated { return "Dein Gerät ist aktiviert." }
        if isFree, let free = freeUntil { return "Freigeschaltet bis \(Self.dateText(free))" }
        let d = daysLeft
        if d <= 0 { return "Testphase abgelaufen" }
        return "Testphase: noch \(d) \(d == 1 ? "Tag" : "Tage")"
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }

    // Letzten Stand speichern, damit er auch ohne Internet gilt
    static func loadSaved() -> LicenseState? {
        guard let data = UserDefaults.standard.data(forKey: "license") else { return nil }
        return try? JSONDecoder().decode(LicenseState.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "license")
        }
    }
}

// MARK: - Aufrufe an die Datenbank

enum RemoteError: LocalizedError {
    case offline
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .offline: return "Keine Verbindung zur Website. Prüfe die Internetverbindung."
        case .server(let code): return "Die Website meldet einen Fehler (HTTP \(code))."
        }
    }

    var isMissingFunction: Bool {
        if case .server(404) = self { return true }
        return false
    }
}

enum RemoteAPI {
    private struct StatusRow: Decodable {
        let active: Bool?
        let activated: Bool?
        let trial_until: String?
        let server_time: String?
        let free_until: String?
        let parental_reset_at: String?
    }

    private struct PlaylistRow: Decodable {
        let id: Int64?
        let name: String?
        let server: String?
        let username: String?
        let password: String?
        let m3u_url: String?
    }

    static func rpc(_ name: String, _ body: [String: Any]) async throws -> Data {
        var base = RemoteConfig.supabaseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/rest/v1/rpc/" + name) else { throw RemoteError.offline }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RemoteConfig.supabaseKey, forHTTPHeaderField: "apikey")
        if RemoteConfig.supabaseKey.hasPrefix("eyJ") {
            request.setValue("Bearer \(RemoteConfig.supabaseKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteError.offline
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteError.server(http.statusCode)
        }
        return data
    }

    static func register(mac: String, key: String) async throws {
        _ = try await rpc("register_device", ["p_mac": mac, "p_key": key])
    }

    /// Stand der Testphase / Aktivierung. nil = ältere Datenbank ohne diese Funktion.
    static func status(mac: String, key: String) async throws -> LicenseState? {
        var data = Data()
        do {
            data = try await rpc("device_status", ["p_mac": mac, "p_key": key])
        } catch let error as RemoteError {
            if error.isMissingFunction { return nil }
            throw error
        }
        let rows = (try? JSONDecoder().decode([StatusRow].self, from: data)) ?? []
        guard let row = rows.first else { return nil }
        let serverNow = parseDate(row.server_time) ?? Date()
        return LicenseState(
            activated: row.activated ?? false,
            trialUntil: parseDate(row.trial_until),
            freeUntil: parseDate(row.free_until),
            offset: serverNow.timeIntervalSince(Date()),
            checked: Date(),
            parentalReset: row.parental_reset_at
        )
    }

    static func playlists(mac: String, key: String) async throws -> [RemotePlaylist] {
        let args = ["p_mac": mac, "p_key": key]
        var data = Data()
        var legacy = false
        do {
            data = try await rpc("get_playlists", args)
        } catch let error as RemoteError {
            guard error.isMissingFunction else { throw error }
            // Ältere Datenbank mit nur einer Wiedergabeliste
            data = try await rpc("get_playlist", args)
            legacy = true
        }
        let rows = (try? JSONDecoder().decode([PlaylistRow].self, from: data)) ?? []
        return rows.compactMap { row -> RemotePlaylist? in
            let server = row.server?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let m3u = row.m3u_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !server.isEmpty || !m3u.isEmpty else { return nil }
            let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return RemotePlaylist(
                id: legacy ? "alt" : String(row.id ?? 0),
                name: name.isEmpty ? "Wiedergabeliste" : name,
                server: server,
                username: row.username ?? "",
                password: row.password ?? "",
                m3u: m3u
            )
        }
    }

    /// Supabase liefert Zeitangaben wie "2026-11-04T11:55:46.6406+00:00"
    static func parseDate(_ text: String?) -> Date? {
        guard var s = text, !s.isEmpty else { return nil }
        // Sekundenbruchteile (beliebig viele Stellen) entfernen, das versteht jeder Parser
        if let range = s.range(of: "\\.[0-9]+", options: .regularExpression) {
            s.removeSubrange(range)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Manche Antworten haben ein Leerzeichen statt "T"
        return f.date(from: s.replacingOccurrences(of: " ", with: "T"))
    }
}
