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

/// Überspringt einzelne fehlerhafte Einträge statt die ganze Liste zu verwerfen
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
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

    func optionalString(_ key: Key) -> String? {
        guard let s = try? flexibleString(key), !s.isEmpty else { return nil }
        return s
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
        name = c.optionalString(.name) ?? ""
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
        name = c.optionalString(.name) ?? ""
        icon = c.optionalString(.icon)
        categoryId = c.optionalString(.categoryId)
    }
}

struct VodStreamDTO: Decodable {
    let streamId: Int
    let name: String
    let icon: String?
    let categoryId: String?
    let ext: String
    let year: Int?

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case name
        case icon = "stream_icon"
        case categoryId = "category_id"
        case ext = "container_extension"
        case year
        case releaseDate = "release_date"
        case releaseDate2 = "releaseDate"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamId = try c.flexibleInt(.streamId)
        name = c.optionalString(.name) ?? ""
        icon = c.optionalString(.icon)
        categoryId = c.optionalString(.categoryId)
        ext = c.optionalString(.ext) ?? "mp4"

        // Jahr: erst aus den Feldern des Anbieters, sonst aus dem Namen, z. B. "Titel (2026)"
        let fromFields = [c.optionalString(.year), c.optionalString(.releaseDate), c.optionalString(.releaseDate2)]
            .compactMap { $0 }
            .compactMap { VodStreamDTO.firstYear(in: $0) }
            .first
        year = fromFields ?? VodStreamDTO.yearFromName(name)
    }

    /// Erste vierstellige Jahreszahl (1900–2099) in einem Text
    static func firstYear(in text: String) -> Int? {
        guard let range = text.range(of: "(19|20)[0-9]{2}", options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// Jahr aus dem Filmnamen, z. B. "Titel (2026)", "Titel [2026]" oder "Titel - 2026"
    static func yearFromName(_ name: String) -> Int? {
        let patterns = ["[(\\[](19|20)[0-9]{2}[)\\]]", "[ ._-](19|20)[0-9]{2}$"]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                return firstYear(in: String(name[range]))
            }
        }
        return nil
    }
}

struct SeriesDTO: Decodable {
    let seriesId: Int
    let name: String
    let cover: String?
    let categoryId: String?

    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id"
        case name
        case cover
        case categoryId = "category_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seriesId = try c.flexibleInt(.seriesId)
        name = c.optionalString(.name) ?? ""
        cover = c.optionalString(.cover)
        categoryId = c.optionalString(.categoryId)
    }
}

/// Client für die Xtream-Codes-Schnittstelle (player_api.php)
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

    private func request(action: String?, extra: [String: String] = [:]) async throws -> Data {
        var urlString = "\(account.server)/player_api.php?username=\(queryEncode(account.username))&password=\(queryEncode(account.password))"
        if let action = action { urlString += "&action=\(action)" }
        for (key, value) in extra { urlString += "&\(key)=\(queryEncode(value))" }
        guard let url = URL(string: urlString) else { throw APIError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 90
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

    private func decodeList<T: Decodable>(_ type: T.Type, action: String) async throws -> [T] {
        let data = try await request(action: action)
        guard let list = try? JSONDecoder().decode([Lossy<T>].self, from: data) else {
            throw APIError.unexpected(Self.snippet(data))
        }
        return list.compactMap(\.value)
    }

    /// Prüft die Anmeldung und liefert Status und Ablaufdatum
    func authenticate() async throws -> (status: String, expiry: Date?) {
        let data = try await request(action: nil)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = json["user_info"] as? [String: Any] else {
            throw APIError.unexpected(Self.snippet(data))
        }
        if "\(user["auth"] ?? 0)" != "1" { throw APIError.rejected }

        let status = (user["status"] as? String) ?? "Active"
        var expiry: Date?
        if let exp = user["exp_date"], !(exp is NSNull), let ts = Double("\(exp)"), ts > 0 {
            expiry = Date(timeIntervalSince1970: ts)
        }
        return (status, expiry)
    }

    func categories(_ action: String) async throws -> [CategoryDTO] {
        let data = try await request(action: action)
        return ((try? JSONDecoder().decode([Lossy<CategoryDTO>].self, from: data)) ?? []).compactMap(\.value)
    }

    func liveStreams() async throws -> [LiveStreamDTO] {
        try await decodeList(LiveStreamDTO.self, action: "get_live_streams")
    }

    func vodStreams() async throws -> [VodStreamDTO] {
        try await decodeList(VodStreamDTO.self, action: "get_vod_streams")
    }

    func series() async throws -> [SeriesDTO] {
        try await decodeList(SeriesDTO.self, action: "get_series")
    }

    func seriesEpisodes(seriesId: Int) async throws -> [Episode] {
        try await seriesDetails(seriesId: seriesId).episodes
    }

    /// Folgen und Beschreibung einer Serie
    func seriesDetails(seriesId: Int) async throws -> (episodes: [Episode], info: MediaInfo) {
        let data = try await request(action: "get_series_info", extra: ["series_id": String(seriesId)])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.unexpected(Self.snippet(data))
        }

        var seasons: [String: Any] = [:]
        if let dict = json["episodes"] as? [String: Any] {
            seasons = dict
        } else if let array = json["episodes"] as? [Any] {
            for (i, value) in array.enumerated() { seasons[String(i + 1)] = value }
        }

        var result: [Episode] = []
        for (seasonKey, value) in seasons {
            guard let episodes = value as? [[String: Any]] else { continue }
            for ep in episodes {
                let id = "\(ep["id"] ?? "")"
                guard !id.isEmpty else { continue }
                var ext = (ep["container_extension"] as? String) ?? ""
                if ext.isEmpty { ext = "mp4" }
                guard let url = episodeURL(id: id, ext: ext) else { continue }

                let season = Int("\(ep["season"] ?? seasonKey)") ?? Int(seasonKey) ?? 1
                let number = Int("\(ep["episode_num"] ?? 0)") ?? 0
                var title = (ep["title"] as? String) ?? ""
                if title.isEmpty { title = "Folge \(number)" }

                var image: URL?
                if let info = ep["info"] as? [String: Any], let img = info["movie_image"] as? String, !img.isEmpty {
                    image = URL(string: img)
                }
                result.append(Episode(id: id, season: season, number: number, title: title, url: url, image: image))
            }
        }
        let sorted = result.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        return (sorted, Self.parseInfo(json["info"] as? [String: Any]))
    }

    /// Beschreibung, Genre, Jahr usw. eines Films
    func vodInfo(vodId: Int) async throws -> MediaInfo {
        let data = try await request(action: "get_vod_info", extra: ["vod_id": String(vodId)])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Self.parseInfo(json?["info"] as? [String: Any])
    }

    static func parseInfo(_ dict: [String: Any]?) -> MediaInfo {
        var info = MediaInfo()
        guard let d = dict else { return info }

        func text(_ keys: [String]) -> String? {
            for key in keys {
                guard let value = d[key], !(value is NSNull) else { continue }
                let s = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty && s != "0" && s.lowercased() != "null" && s != "N/A" { return s }
            }
            return nil
        }

        info.plot = text(["plot", "description"])
        info.genre = text(["genre"])
        if let date = text(["releasedate", "releaseDate", "release_date", "year"]) {
            info.year = String(date.prefix(4))
        }
        info.rating = text(["rating"])
        info.duration = text(["duration"]).map(Self.formatDuration)
        info.cast = text(["cast", "actors"])
        info.director = text(["director"])
        if let list = d["backdrop_path"] as? [Any], let first = list.first as? String, !first.isEmpty {
            info.backdrop = URL(string: first)
        } else if let single = d["backdrop_path"] as? String, !single.isEmpty {
            info.backdrop = URL(string: single)
        }
        info.cover = text(["movie_image", "cover_big", "cover"]).flatMap { URL(string: $0) }
        return info
    }

    /// "01:52:00" -> "1 Std. 52 Min."
    static func formatDuration(_ raw: String) -> String {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return raw }
        let (h, m) = (parts[0], parts[1])
        if h > 0 { return "\(h) Std. \(m) Min." }
        return "\(m) Min."
    }

    func shortEPG(streamId: Int, limit: Int = 4) async throws -> [EPGEntry] {
        let data = try await request(action: "get_short_epg", extra: ["stream_id": String(streamId), "limit": String(limit)])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["epg_listings"] as? [[String: Any]] else { return [] }

        return list.compactMap { item -> EPGEntry? in
            let title = Self.decodeBase64((item["title"] as? String) ?? "")
            guard !title.isEmpty else { return nil }
            let start = Double("\(item["start_timestamp"] ?? "")").map { Date(timeIntervalSince1970: $0) }
            let end = Double("\(item["stop_timestamp"] ?? "")").map { Date(timeIntervalSince1970: $0) }
            let desc = Self.decodeBase64((item["description"] as? String) ?? "")
            return EPGEntry(title: title, start: start, end: end, desc: desc.isEmpty ? nil : desc)
        }
    }

    static func decodeBase64(_ s: String) -> String {
        if let data = Data(base64Encoded: s), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return s
    }

    private var credentialsPath: String {
        "\(pathEncode(account.username))/\(pathEncode(account.password))"
    }

    func streamURL(id: Int) -> URL? {
        URL(string: "\(account.server)/live/\(credentialsPath)/\(id).m3u8")
    }

    func movieURL(id: Int, ext: String) -> URL? {
        URL(string: "\(account.server)/movie/\(credentialsPath)/\(id).\(ext)")
    }

    func episodeURL(id: String, ext: String) -> URL? {
        URL(string: "\(account.server)/series/\(credentialsPath)/\(id).\(ext)")
    }
}
