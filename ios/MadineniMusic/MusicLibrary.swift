import Foundation
import Combine

@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var server: URL?
    static let defaultServer = "https://madinenimusic.madineni.xyz"
    @Published var serverText: String
    @Published private(set) var loading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastRefreshed: Date?
    @Published var error: String?
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published var playlistError: String?

    @Published private(set) var albums: [AlbumGroup] = []
    @Published private(set) var favoriteIDs: Set<Int>
    @Published private(set) var loadMessage = "Connecting to your music server…"
    @Published private(set) var loadIssue: String?
    private var loadTask: Task<Bool, Never>?
    private var timedOut = false
    private var resumeBase: URL?
    private var resumeCatalog: SongCatalogAccumulator?
    private var resumeOffset = 0
    private var artworkTask: Task<Void, Never>?
    @Published private(set) var albumArtwork: [Int: String] = [:]
    private let session: URLSession
    private let defaults: UserDefaults
    private let pageSize: Int
    private let fetchArtwork: Bool

    init(session: URLSession = .shared, fetchArtwork: Bool = true, defaults: UserDefaults = .standard, pageSize: Int = 500) {
        self.session = session
        self.fetchArtwork = fetchArtwork
        self.defaults = defaults
        self.pageSize = max(1, pageSize)
        self.favoriteIDs = Set(defaults.array(forKey: "favoriteSongIDs") as? [Int] ?? [])
        if let stored = defaults.string(forKey: "musicServerURL"), let url = try? ServerAddress.parse(stored) {
            serverText = url.absoluteString
        } else { serverText = Self.defaultServer }
    }

    @discardableResult
    func connect(to candidate: String? = nil) async -> Bool {
        guard !loading else { return false }
        loading = true
        error = nil
        loadIssue = nil
        timedOut = false
        loadMessage = "Connecting to your music server…"
        let operation = Task { await self.loadCatalog(candidate: candidate) }
        loadTask = operation
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            self.timedOut = true
            operation.cancel()
        }
        defer { deadline.cancel(); loadTask = nil; loading = false }
        return await withTaskCancellationHandler(operation: { await operation.value }, onCancel: { operation.cancel() })
    }

    func cancelLoading() { loadTask?.cancel() }

    var favoriteSongs: [Song] { songs.filter { favoriteIDs.contains($0.id) } }

    func isFavorite(_ song: Song) -> Bool { favoriteIDs.contains(song.id) }

    func toggleFavorite(_ song: Song) {
        if !favoriteIDs.insert(song.id).inserted { favoriteIDs.remove(song.id) }
        defaults.set(favoriteIDs.sorted(), forKey: "favoriteSongIDs")
    }

    /// Optional server contract: GET /api/lyrics?song_id=123 returns LRC text,
    /// either as text/plain or in a JSON `lyrics`, `lrc`, `text`, or `data` field.
    func loadLyrics(for song: Song) async throws -> [LyricLine] {
        guard let server else { throw LyricsError.unavailable }
        var components = URLComponents(url: server.appendingPathComponent("api/lyrics"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "song_id", value: String(song.id))]
        guard let url = components?.url else { throw LyricsError.invalid }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LyricsError.unavailable
        }
        let raw: String
        if let object = try? JSONSerialization.jsonObject(with: data) {
            guard let text = Self.lyricsText(in: object) else { throw LyricsError.invalid }
            raw = text
        } else if let text = String(data: data, encoding: .utf8) {
            raw = text
        } else { throw LyricsError.invalid }
        let lines = LyricLine.parseLRC(raw)
        guard !lines.isEmpty else { throw LyricsError.unavailable }
        return lines
    }

    private static func lyricsText(in value: Any) -> String? {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            for key in ["lyrics", "lrc", "text", "data"] {
                if let nested = object[key], let text = lyricsText(in: nested) { return text }
            }
        }
        return nil
    }

    private func publish(_ values: [Song], server base: URL) {
        if server != base {
            albumArtwork = [:]
            artworkTask?.cancel()
            if fetchArtwork { artworkTask = Task { await self.fetchAlbumArtwork(base) } }
        }
        songs = values
        albums = Dictionary(grouping: values, by: \.albumKey).map { key, songs in
            AlbumGroup(id: key, title: songs.first?.albumName ?? "Unknown album", songs: songs.sorted {
                if $0.track_number != $1.track_number { return ($0.track_number ?? Int.max) < ($1.track_number ?? Int.max) }
                return $0.id < $1.id
            })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        server = base
    }

    private func fetchAlbumArtwork(_ base: URL) async {
        var request = URLRequest(url: base.appendingPathComponent("api/albums"))
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let records = try? JSONDecoder().decode([AlbumArtwork].self, from: data),
              !Task.isCancelled, server == base else { return }
        var covers: [Int: String] = [:]
        for record in records {
            if let path = record.cover_path ?? record.cover_art, !path.isEmpty { covers[record.id] = path }
        }
        albumArtwork = covers
    }

    func artworkURLs(song: Song?, album: AlbumGroup? = nil, source: URL? = nil) -> [URL] {
        guard let base = source ?? server else { return [] }
        let tracks = album?.songs ?? song.map { [$0] } ?? []
        var urls: [URL] = []
        func add(_ path: String?) {
            guard let path, let url = URL(string: path, relativeTo: base)?.absoluteURL,
                  ServerAddress.sameOrigin(url, base), !urls.contains(url) else { return }
            urls.append(url)
        }
        if base == server, let id = tracks.first?.album_id { add(albumArtwork[id]) }
        for track in tracks.prefix(12) { add(track.cover_art) }
        for track in tracks.prefix(3) { add("/covers/\(track.id).jpg") }
        return urls
    }

    @discardableResult
    func refreshPlaylists() async -> Bool {
        guard let server else { return false }
        do {
            let data = try await playlistRequest("api/playlists", server: server)
            let page = try JSONDecoder().decode(PlaylistPage.self, from: data)
            playlists = page.data.filter { $0.id > 0 }
            playlistError = nil
            return true
        } catch {
            playlistError = error.localizedDescription
            return false
        }
    }

    func createPlaylist(name: String) async -> Bool {
        guard let server else { playlistError = "Connect to your music server first."; return false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { playlistError = "Enter a playlist name."; return false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["name": clean, "description": ""])
            _ = try await playlistRequest("api/playlists", server: server, method: "POST", body: body)
            return await refreshPlaylists()
        } catch { playlistError = error.localizedDescription; return false }
    }

    func loadPlaylistSongs(_ playlist: MusicPlaylist) async -> [Song]? {
        guard let server else { playlistError = "Connect to your music server first."; return nil }
        do {
            let data = try await playlistRequest("api/playlists/\(playlist.id)/songs", server: server)
            let page = try JSONDecoder().decode(SongPage.self, from: data)
            playlistError = nil
            // Use the full catalog row when available, preserving album IDs and artwork metadata.
            return page.songs.map { row in songs.first(where: { $0.id == row.id }) ?? row }
        } catch { playlistError = error.localizedDescription; return nil }
    }

    func add(_ song: Song, to playlist: MusicPlaylist) async -> Bool {
        guard let server else { playlistError = "Connect to your music server first."; return false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["song_id": song.id])
            _ = try await playlistRequest("api/playlists/\(playlist.id)/songs", server: server, method: "POST", body: body)
            return await refreshPlaylists()
        } catch { playlistError = error.localizedDescription; return false }
    }

    func remove(_ song: Song, from playlist: MusicPlaylist) async -> Bool {
        guard let server else { playlistError = "Connect to your music server first."; return false }
        do {
            _ = try await playlistRequest("api/playlists/\(playlist.id)/songs/\(song.id)", server: server, method: "DELETE")
            _ = await refreshPlaylists()
            return true
        } catch { playlistError = error.localizedDescription; return false }
    }

    func deletePlaylist(_ playlist: MusicPlaylist) async -> Bool {
        guard let server else { playlistError = "Connect to your music server first."; return false }
        do {
            _ = try await playlistRequest("api/playlists/\(playlist.id)", server: server, method: "DELETE")
            return await refreshPlaylists()
        } catch { playlistError = error.localizedDescription; return false }
    }

    private func playlistRequest(_ path: String, server: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        var url = server
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.details
                ?? (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error
            if let message, message.contains("column ps.id does not exist") {
                throw PlaylistError.serverNeedsPlaylistOrderFix
            }
            throw PlaylistError.response(message ?? "The playlist request failed. Check your server connection.")
        }
        return data
    }

    private func loadCatalog(candidate: String?) async -> Bool {
        do {
            let base = try ServerAddress.parse(candidate ?? serverText)
            let progressive = !hasLoaded && (server == nil || server == base)
            let continuing = progressive && resumeBase == base
            var catalog = continuing ? (resumeCatalog ?? SongCatalogAccumulator()) : SongCatalogAccumulator()
            var offset = continuing ? resumeOffset : 0
            var pages = 0
            repeat {
                try Task.checkCancellation()
                guard var c = URLComponents(url: base.appendingPathComponent("api/songs"), resolvingAgainstBaseURL: false) else { throw MusicError.invalidServer }
                let limit = offset == 0 ? min(pageSize, 100) : pageSize
                c.queryItems = [URLQueryItem(name: "limit", value: "\(limit)"),
                               URLQueryItem(name: "offset", value: "\(offset)")]
                guard let url = c.url else { throw MusicError.invalidServer }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw MusicError.notJSON }
                guard (200..<300).contains(http.statusCode) else {
                    let apiError = try? JSONDecoder().decode(MusicAPIErrorEnvelope.self, from: data)
                    let detail = apiError?.details ?? apiError?.error
                    if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw MusicError.serverResponse(http.statusCode, String(detail.prefix(400)))
                    }
                    throw MusicError.response(http.statusCode)
                }
                let page: [Song]
                do { page = try JSONDecoder().decode(SongPage.self, from: data).songs }
                catch {
                    if (try? JSONSerialization.jsonObject(with: data)) == nil { throw MusicError.notJSON }
                    let field: String
                    switch error {
                    case DecodingError.keyNotFound(let key, _): field = key.stringValue
                    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
                        field = context.codingPath.last?.stringValue ?? "songs"
                    default: field = "songs"
                    }
                    throw MusicError.invalidCatalog(field)
                }
                try Task.checkCancellation()
                try catalog.append(page, pageSize: limit)
                if progressive && !catalog.songs.isEmpty {
                    // Show the first page promptly, then publish the complete
                    // catalog once pagination finishes. Publishing every page
                    // repeatedly rebuilds albums and redraws the home screen.
                    if offset == 0 { publish(catalog.songs, server: base) }
                    resumeBase = base
                    resumeCatalog = catalog
                    resumeOffset = offset + page.count
                }
                loadMessage = "Loaded \(catalog.songs.count) songs…"
                pages += 1
                guard pages < 200 else { throw MusicError.repeatedPage }
                if page.count < limit { break }
                offset += page.count
                try Task.checkCancellation()
            } while true
            try Task.checkCancellation()
            publish(catalog.songs, server: base)
            serverText = base.absoluteString
            defaults.set(serverText, forKey: "musicServerURL")
            loadMessage = "Library is ready"
            hasLoaded = true
            resumeBase = nil
            resumeCatalog = nil
            resumeOffset = 0
            lastRefreshed = Date()
            return true
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                loadIssue = timedOut ? "Loading took too long. Check the server connection, then tap Retry." : "Loading stopped. Tap Retry to finish loading your library."
                return false
            }
            if (error as? URLError)?.code == .timedOut {
                loadIssue = "Your server didn't respond in time. Tap Retry, or check Server settings."
            } else { loadIssue = error.localizedDescription }
            self.error = loadIssue
            return false
        }
    }
}

private struct PlaylistPage: Decodable { let data: [MusicPlaylist] }
private struct APIErrorResponse: Decodable { let error: String?; let details: String? }
private enum PlaylistError: LocalizedError {
    case response(String), serverNeedsPlaylistOrderFix
    var errorDescription: String? {
        switch self {
        case .response(let message): return message
        case .serverNeedsPlaylistOrderFix:
            return "The music server needs a small playlist fix. In backend/server.js, change the playlist songs query from ORDER BY ps.id ASC to ORDER BY ps.song_id ASC, then restart the server."
        }
    }
}
