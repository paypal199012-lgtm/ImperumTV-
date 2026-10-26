import Foundation

/// Verbindung zur Playlist-Website (Supabase-Datenbank)
enum RemoteSetup {
    // Diese zwei Werte kommen aus deinem Supabase-Projekt
    // (Project Settings > API: Project URL und publishable/anon key).
    static let supabaseURL = "DEINE_SUPABASE_URL"
    static let supabaseKey = "DEIN_SUPABASE_KEY"

    /// Adresse der Website (GitHub Pages)
    static let websiteURL = "https://paypal199012-lgtm.github.io/ImperumTV-/"

    static var isConfigured: Bool {
        supabaseURL.hasPrefix("https://") && !supabaseKey.hasPrefix("DEIN")
    }

    struct RemotePlaylist: Decodable {
        let m3u_url: String?
        let server: String?
        let username: String?
        let password: String?
        let updated_at: String?
    }

    /// Meldet MAC-Adresse und Device Key an, damit die Website sie kennt
    static func register(mac: String, key: String) async throws {
        _ = try await rpc("register_device", ["p_mac": mac, "p_key": key])
    }

    /// Holt die auf der Website eingetragene Playlist
    static func fetch(mac: String, key: String) async throws -> RemotePlaylist? {
        let data = try await rpc("get_playlist", ["p_mac": mac, "p_key": key])
        return try JSONDecoder().decode([RemotePlaylist].self, from: data).first
    }

    private static func rpc(_ name: String, _ body: [String: String]) async throws -> Data {
        var base = supabaseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/rest/v1/rpc/" + name) else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        // Ältere Supabase-Schlüssel (JWT) brauchen zusätzlich diesen Header
        if supabaseKey.hasPrefix("eyJ") {
            request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, XtreamAPI.snippet(data))
        }
        return data
    }

    /// Erzeugt eine eigene MAC-Adresse (iOS gibt die echte nicht heraus)
    static func makeMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE   // lokal vergeben, kein Multicast
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Erzeugt einen 6-stelligen Device Key
    static func makeKey() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func isValidMAC(_ mac: String) -> Bool {
        mac.range(of: "^([0-9A-F]{2}:){5}[0-9A-F]{2}$", options: .regularExpression) != nil
    }

    static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }

    /// MAC-Adresse und Device Key laden oder einmalig erzeugen.
    /// Im Schlüsselbund gespeichert, damit sie auch nach dem Neuinstallieren gleich bleiben.
    static func loadIdentity() -> (mac: String, key: String) {
        let defaults = UserDefaults.standard
        var mac = Keychain.load("deviceMAC") ?? defaults.string(forKey: "deviceMAC") ?? ""
        var key = Keychain.load("deviceKey") ?? defaults.string(forKey: "deviceKey") ?? ""
        if !isValidMAC(mac) { mac = makeMAC() }
        if !isValidKey(key) { key = makeKey() }
        Keychain.save(mac, for: "deviceMAC")
        Keychain.save(key, for: "deviceKey")
        defaults.set(mac, forKey: "deviceMAC")
        defaults.set(key, forKey: "deviceKey")
        return (mac, key)
    }
}
