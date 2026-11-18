import XCTest

// MARK: - Network stub

/// Intercepts every request made through a session that lists it in `protocolClasses`,
/// so these tests never touch a real server.
final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let url: URL
        let body: Data?
    }
    typealias Handler = (Recorded) -> (status: Int, body: String)

    private static let lock = NSLock()
    private static var storedHandler: Handler?
    private static var storedLog: [Recorded] = []

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }
    static var log: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return storedLog
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        storedHandler = nil
        storedLog = []
    }
    static func clearLog() {
        lock.lock(); defer { lock.unlock() }
        storedLog = []
    }
    private static func record(_ item: Recorded) {
        lock.lock(); defer { lock.unlock() }
        storedLog.append(item)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let recorded = Recorded(method: request.httpMethod ?? "GET", url: url, body: Self.readBody(request))
        Self.record(recorded)
        let result = Self.handler?(recorded) ?? (404, "{}")
        let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func songJSON(_ id: Int) -> String {
    #"{"id":\#(id),"title":"Song \#(id)","artist":"Artist","album":"Album","file_path":"Album/\#(id).mp3"}"#
}

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// Default routes mirroring the backend contract; `extra` can override any route.
private func install(catalog: [Int] = [1, 2, 3], extra: ((StubURLProtocol.Recorded) -> (Int, String)?)? = nil) {
    StubURLProtocol.reset()
    StubURLProtocol.handler = { request in
        if let hit = extra?(request) { return (hit.0, hit.1) }
        switch (request.method, request.url.path) {
        case ("GET", "/api/songs"):
            let limit = Int(queryValue(request.url, "limit") ?? "") ?? 100
            let offset = Int(queryValue(request.url, "offset") ?? "") ?? 0
            let slice = catalog.dropFirst(offset).prefix(limit)
            return (200, "[" + slice.map(songJSON).joined(separator: ",") + "]")
        case ("GET", "/api/playlists"):
            return (200, #"{"success":true,"data":[{"id":4,"name":"Mood","song_count":"0"}]}"#)
        default:
            return (200, #"{"success":true}"#)
        }
    }
}

// MARK: - Tests

@MainActor
final class MusicLibraryTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "MusicLibraryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeLibrary(pageSize: Int = 500, defaults: UserDefaults? = nil) -> MusicLibrary {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return MusicLibrary(session: URLSession(configuration: configuration), fetchArtwork: false,
                            defaults: defaults ?? makeDefaults(), pageSize: pageSize)
    }

    private func connectedLibrary() async -> MusicLibrary {
        let library = makeLibrary()
        _ = await library.connect(to: "https://music.test")
        return library
    }

    private func playlist(_ id: Int = 4) throws -> MusicPlaylist {
        try JSONDecoder().decode(MusicPlaylist.self, from: Data(#"{"id":\#(id),"name":"Mood"}"#.utf8))
    }

    // Catalog

    func testCatalogPaginatesUntilAShortPageAndRemembersTheServer() async {
        install(catalog: [1, 2, 3])
        let defaults = makeDefaults()
        let library = makeLibrary(pageSize: 2, defaults: defaults)
        let connected = await library.connect(to: "https://music.test")
        XCTAssertTrue(connected)
        XCTAssertEqual(library.songs.map(\.id).sorted(), [1, 2, 3])
        let pages = StubURLProtocol.log.filter { $0.url.path == "/api/songs" }
        XCTAssertEqual(pages.map { queryValue($0.url, "offset") }, ["0", "2"])
        XCTAssertEqual(pages.map { queryValue($0.url, "limit") }, ["2", "2"])
        XCTAssertEqual(defaults.string(forKey: "musicServerURL"), "https://music.test")
    }

    func testServerErrorFailsTheLoadWithoutPublishingASongList() async {
        install(extra: { $0.url.path == "/api/songs" ? (500, #"{"error":"boom"}"#) : nil })
        let library = makeLibrary()
        let connected = await library.connect(to: "https://music.test")
        XCTAssertFalse(connected)
        XCTAssertFalse(library.hasLoaded)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.error != nil || library.loadIssue != nil)
    }

    func testInvalidServerAddressIsRejectedBeforeAnyRequest() async {
        install()
        let library = makeLibrary()
        let connected = await library.connect(to: "https://music.test/api")
        XCTAssertFalse(connected)
        XCTAssertTrue(StubURLProtocol.log.isEmpty)
    }

    // Lyrics (regression: the app used to call /api/lyrics?song_id=)

    func testLyricsRequestUsesTheBackendRouteAndParsesSyncedLyrics() async throws {
        install(extra: { request in
            request.url.path == "/api/songs/1/lyrics"
                ? (200, #"{"success":true,"data":{"song_id":"1","status":"synced","syncedLyrics":"[00:01.00]Hi\n[00:03.50]There","plainLyrics":"Hi\nThere"}}"#)
                : nil
        })
        let library = await connectedLibrary()
        let song = try XCTUnwrap(library.songs.first { $0.id == 1 })
        let lines = try await library.loadLyrics(for: song)
        XCTAssertEqual(lines.map(\.text), ["Hi", "There"])
        XCTAssertEqual(lines.map(\.time), [1, 3.5])
        let lyricRequests = StubURLProtocol.log.filter { $0.url.path.hasSuffix("/lyrics") }
        XCTAssertEqual(lyricRequests.map { $0.url.path }, ["/api/songs/1/lyrics"])
        XCTAssertNil(lyricRequests.first?.url.query)
    }

    func testLyricsAreUnavailableForNullSyncedLyricsAndForErrors() async throws {
        install(extra: { request in
            switch request.url.path {
            case "/api/songs/1/lyrics": return (200, #"{"success":true,"data":{"syncedLyrics":null,"plainLyrics":"Hi"}}"#)
            case "/api/songs/2/lyrics": return (404, #"{"success":false,"error":"Song not found"}"#)
            default: return nil
            }
        })
        let library = await connectedLibrary()
        for id in [1, 2] {
            let song = try XCTUnwrap(library.songs.first { $0.id == id })
            do {
                _ = try await library.loadLyrics(for: song)
                XCTFail("Expected lyrics to be unavailable for song \(id)")
            } catch {
                XCTAssertTrue(error is LyricsError, "song \(id): \(error)")
            }
        }
    }

    // Playlists

    func testPlaylistWritesUseTheDocumentedRoutesAndBodies() async throws {
        install()
        let library = await connectedLibrary()
        let song = try XCTUnwrap(library.songs.first { $0.id == 1 })
        let mood = try playlist()
        StubURLProtocol.clearLog()

        let created = await library.createPlaylist(name: "  Chill  ")
        let added = await library.add(song, to: mood)
        let removed = await library.remove(song, from: mood)
        let deleted = await library.deletePlaylist(mood)
        XCTAssertTrue(created && added && removed && deleted)

        let writes = StubURLProtocol.log.filter { $0.method != "GET" }
        XCTAssertEqual(writes.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/playlists", "POST /api/playlists/4/songs",
            "DELETE /api/playlists/4/songs/1", "DELETE /api/playlists/4",
        ])
        let createBody = try JSONSerialization.jsonObject(with: try XCTUnwrap(writes[0].body)) as? [String: String]
        XCTAssertEqual(createBody?["name"], "Chill")
        let addBody = try JSONSerialization.jsonObject(with: try XCTUnwrap(writes[1].body)) as? [String: Int]
        XCTAssertEqual(addBody?["song_id"], 1)
    }

    func testBlankPlaylistNameIsRejectedWithoutARequest() async {
        install()
        let library = await connectedLibrary()
        StubURLProtocol.clearLog()
        let created = await library.createPlaylist(name: "   ")
        XCTAssertFalse(created)
        XCTAssertEqual(library.playlistError, "Enter a playlist name.")
        XCTAssertTrue(StubURLProtocol.log.isEmpty)
    }

    func testPlaylistSongsPreferTheFullCatalogRow() async throws {
        install(extra: { request in
            request.url.path == "/api/playlists/4/songs"
                ? (200, #"{"success":true,"data":[{"id":2,"title":"Stripped","file_path":"x.mp3"}]}"#)
                : nil
        })
        let library = await connectedLibrary()
        let songs = try XCTUnwrap(await library.loadPlaylistSongs(try playlist()))
        XCTAssertEqual(songs.map(\.id), [2])
        XCTAssertEqual(songs.first?.title, "Song 2", "catalog metadata should replace the sparse playlist row")
    }

    func testMissingPlaylistColumnProducesTheActionableError() async throws {
        install(extra: { request in
            request.url.path == "/api/playlists/4/songs"
                ? (500, #"{"error":"Failed","details":"column ps.id does not exist"}"#)
                : nil
        })
        let library = await connectedLibrary()
        let songs = await library.loadPlaylistSongs(try playlist())
        XCTAssertNil(songs)
        XCTAssertEqual(library.playlistError?.contains("ps.song_id"), true)
    }

    // Favorites

    func testFavoritesPersistAcrossLibraryInstances() async throws {
        install()
        let defaults = makeDefaults()
        let first = makeLibrary(defaults: defaults)
        _ = await first.connect(to: "https://music.test")
        let song = try XCTUnwrap(first.songs.first { $0.id == 2 })
        first.toggleFavorite(song)
        XCTAssertTrue(first.isFavorite(song))

        let second = makeLibrary(defaults: defaults)
        XCTAssertTrue(second.favoriteIDs.contains(2))
        second.toggleFavorite(song)
        XCTAssertFalse(second.isFavorite(song))
    }
}
