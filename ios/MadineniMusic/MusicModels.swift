import Foundation

struct Song: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String
    let artist: String?
    let album: String?
    let album_id: Int?
    let duration_seconds: Double?
    let file_path: String
    let cover_art: String?
    let track_number: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, album_id, duration_seconds, file_path, cover_art, track_number
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func integer(_ key: CodingKeys) -> Int? {
            if let value = try? c.decode(Int.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
            return nil
        }
        guard let songID = integer(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Song ID must be an integer.")
        }
        id = songID
        file_path = try c.decode(String.self, forKey: .file_path)
        let name = try c.decodeIfPresent(String.self, forKey: .title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = (name?.isEmpty == false ? name : nil) ?? URL(fileURLWithPath: file_path).deletingPathExtension().lastPathComponent
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        album_id = integer(.album_id)
        track_number = integer(.track_number)
        cover_art = try c.decodeIfPresent(String.self, forKey: .cover_art)
        let rawDuration = (try? c.decode(Double.self, forKey: .duration_seconds))
            ?? (try? c.decode(String.self, forKey: .duration_seconds)).flatMap { Double($0) }
        duration_seconds = rawDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var artistName: String { artist.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Unknown artist" }
    var albumName: String { album.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Unknown album" }
    var externalPlaybackTitle: String {
        guard let movie = album?.trimmingCharacters(in: .whitespacesAndNewlines),
              !movie.isEmpty, movie.caseInsensitiveCompare("Unknown album") != .orderedSame,
              !title.localizedCaseInsensitiveContains(movie) else { return title }
        return "\(title) • \(movie)"
    }
    var albumKey: String { album_id.map { "id:\($0)" } ?? "name:\(albumName)" }
}

struct LyricLine: Identifiable, Equatable {
    let time: Double
    let text: String
    var id: String { "\(time)-\(text)" }

    /// Parses standard LRC timestamp tags, including multiple tags on one line.
    static func parseLRC(_ source: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return source.components(separatedBy: .newlines).flatMap { row -> [LyricLine] in
            let range = NSRange(row.startIndex..., in: row)
            let matches = regex.matches(in: row, range: range)
            guard !matches.isEmpty else { return [] }
            let lyric = regex.stringByReplacingMatches(in: row, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            guard !lyric.isEmpty else { return [] }
            return matches.compactMap { match in
                guard let m = Range(match.range(at: 1), in: row),
                      let s = Range(match.range(at: 2), in: row),
                      let minutes = Double(String(row[m])), let seconds = Double(String(row[s])) else { return nil }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound, let f = Range(match.range(at: 3), in: row) {
                    fraction = (Double("0." + String(row[f])) ?? 0)
                }
                return LyricLine(time: minutes * 60 + seconds + fraction, text: lyric)
            }
        }.sorted { $0.time < $1.time }
    }
}

enum LyricsError: LocalizedError {
    case unavailable, invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Synchronized lyrics are not available for this song on your server."
        case .invalid: return "The lyrics response could not be read."
        }
    }
}

struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let songs: [Song]
}

struct AlbumArtwork: Decodable {
    let id: Int
    let cover_art: String?
    let cover_path: String?
}

struct MusicPlaylist: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let description: String?
    let song_count: Int

    private enum CodingKeys: String, CodingKey { case id, name, description, song_count }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? Int((try? c.decode(String.self, forKey: .id)) ?? "") ?? 0
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        song_count = (try? c.decode(Int.self, forKey: .song_count)) ?? Int((try? c.decode(String.self, forKey: .song_count)) ?? "") ?? 0
    }
}

struct MusicAPIErrorEnvelope: Decodable {
    let error: String?
    let details: String?
}

enum MusicError: LocalizedError {
    case invalidServer, invalidFile, response(Int), serverResponse(Int, String), notJSON, repeatedPage, invalidCatalog(String)
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter your server's full URL, such as https://music.example.com, without /api or a page path."
        case .invalidFile: return "This song has an unsupported file path. Check its file_path in the database."
        case .response(let code): return code == 403 ? "The server blocked this request (HTTP 403). Check Cloudflare Access or firewall rules for the music API." : "The server returned HTTP \(code). Check that the music API is available."
        case .serverResponse(let code, let detail): return "The music server returned HTTP \(code): \(detail)"
        case .notJSON: return "The server did not return song JSON. Check the URL and any Cloudflare sign-in page."
        case .repeatedPage: return "The server repeated a full page of songs. Check that /api/songs respects the offset parameter."
        case .invalidCatalog(let field): return "The song API returned JSON, but its \(field) field has missing or invalid metadata."
        }
    }
}

enum ServerAddress {
    static func parse(_ input: String) throws -> URL {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else {
            throw MusicError.invalidServer
        }
        c.scheme = scheme
        c.host = host.lowercased()
        c.path = ""
        if c.port == (scheme == "https" ? 443 : 80) { c.port = nil }
        guard let url = c.url else { throw MusicError.invalidServer }
        return url
    }

    static func sameOrigin(_ url: URL, _ server: URL) -> Bool {
        let a = url.scheme?.lowercased(), b = server.scheme?.lowercased()
        return a == b && url.host?.lowercased() == server.host?.lowercased()
            && (url.port ?? (a == "https" ? 443 : 80)) == (server.port ?? (b == "https" ? 443 : 80))
            && url.user == nil && url.password == nil
    }

    static func mediaURL(for song: Song, server: URL) throws -> URL {
        var value = song.file_path
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard let url = URL(string: value), sameOrigin(url, server) else {
                throw MusicError.invalidFile
            }
            return url
        }
        let diskPrefix = "/opt/musicapp/music/Songs/"
        if value.hasPrefix(diskPrefix) { value = String(value.dropFirst(diskPrefix.count)) }
        else if value.hasPrefix("/music/") { value = String(value.dropFirst(7)) }
        else if value.hasPrefix("music/") { value = String(value.dropFirst(6)) }
        else if value.hasPrefix("Songs/") { value = String(value.dropFirst(6)) }
        else if value.hasPrefix("/") { throw MusicError.invalidFile }
        let segments = value.split(separator: "/").map(String.init)
        guard !segments.isEmpty, !segments.contains(".."), !segments.contains(".") else {
            throw MusicError.invalidFile
        }
        var url = server.appendingPathComponent("music", isDirectory: true)
        for segment in segments { url.appendPathComponent(segment) }
        return url
    }

    static func coverURL(for song: Song, server: URL?) -> URL? {
        guard let server else { return nil }
        if let path = song.cover_art?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            if let url = URL(string: path, relativeTo: server)?.absoluteURL,
               sameOrigin(url, server) { return url }
        }
        return server.appendingPathComponent("covers").appendingPathComponent("\(song.id).jpg")
    }
}

struct SongPage: Decodable {
    let songs: [Song]
    private enum CodingKeys: String, CodingKey { case success, data }
    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([Song].self) { songs = array; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .success) == false {
            throw DecodingError.dataCorruptedError(forKey: .success, in: c, debugDescription: "The song API reported a failure.")
        }
        songs = try c.decode([Song].self, forKey: .data)
    }
}

struct SongCatalogAccumulator {
    private(set) var songs: [Song] = []
    private var seen = Set<Int>()
    mutating func append(_ page: [Song], pageSize: Int) throws {
        let fresh = page.filter { seen.insert($0.id).inserted }
        if page.count >= pageSize && fresh.isEmpty { throw MusicError.repeatedPage }
        songs.append(contentsOf: fresh)
    }
}

