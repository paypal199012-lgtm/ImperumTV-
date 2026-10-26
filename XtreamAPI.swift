import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)
    case rejected
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Die Server-Adresse ist ungültig."
        case .http(let code, let snippet):
            let extra = snippet.isEmpty ? "" : " Antwort des Servers: \(snippet)"
            return "Der Server antwortet mit HTTP \(code).\(extra)"
        case .rejected:
            return "Anmeldung abgelehnt. Benutzername oder Passwort stimmt nicht, oder das Abo ist abgelaufen."
        case .unexpected(let snippet):
            let extra = snippet.isEmpty ? "" : " Antwort des Servers: \(snippet)"
            return "Unerwartete Antwort vom Server.\(extra)"
        }
    }
}

struct CategoryDTO: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexibleString(.id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

struct LiveStreamDTO: Decodable {
    let streamId: Int
    let name: String
    let icon: String?
    let categoryId: String?

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case name
        case icon = "stream_icon"
        case categoryId = "category_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamId = try c.flexibleInt(.streamId)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        icon = try? c.decode(String.self, forKey: .icon)
        categoryId = try? c.flexibleString(.categoryId)
    }
}

extension KeyedDecodingContainer {
    func flexibleInt(_ key: Key) throws -> Int {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let s = try? decode(String.self, forKey: key), let i = Int(s) { return i }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Keine Zahl")
    }

    func flexibleString(_ key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Kein Text")
    }
}

/// Einfacher Client für die Xtream-Codes-Schnittstelle (player_api.php)
struct XtreamAPI {
    let account: Account
    let userAgent: String

    private func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func pathEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func request(action: String?) async throws -> Data {
        var urlString = "\(account.server)/player_api.php?username=\(queryEncode(account.username))&password=\(queryEncode(account.password))"
        if let action = action { urlString += "&action=\(action)" }
        guard let url = URL(string: urlString) else { throw APIError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, Self.snippet(data))
        }
        return data
    }

    static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prüft die Anmeldung und liefert einen kurzen Statustext
    func authenticate() async throws -> String {
        let data = try await request(action: nil)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = json["user_info"] as? [String: Any] else {
            throw APIError.unexpected(Self.snippet(data))
        }
        if "\(user["auth"] ?? 0)" != "1" { throw APIError.rejected }

        var parts: [String] = []
        if let status = user["status"] as? String { parts.append("Status: \(status)") }
        if let exp = user["exp_date"], !(exp is NSNull), let ts = Double("\(exp)"), ts > 0 {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = Locale(identifier: "de_DE")
            parts.append("Läuft ab: \(formatter.string(from: Date(timeIntervalSince1970: ts)))")
        }
        return parts.joined(separator: " · ")
    }

    func liveCategories() async throws -> [CategoryDTO] {
        let data = try await request(action: "get_live_categories")
        return (try? JSONDecoder().decode([CategoryDTO].self, from: data)) ?? []
    }

    func liveStreams() async throws -> [LiveStreamDTO] {
        let data = try await request(action: "get_live_streams")
        do {
            return try JSONDecoder().decode([LiveStreamDTO].self, from: data)
        } catch {
            throw APIError.unexpected(Self.snippet(data))
        }
    }

    func streamURL(id: Int) -> URL? {
        URL(string: "\(account.server)/live/\(pathEncode(account.username))/\(pathEncode(account.password))/\(id).m3u8")
    }
}
