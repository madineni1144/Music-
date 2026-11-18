import XCTest
@testable import CoreLogic

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func makeSong(_ id: Int = 1, path: String = "Album/Track.mp3", extra: String = "") throws -> Song {
    try decode(Song.self, #"{"id":\#(id),"title":"T\#(id)","file_path":"\#(path)"\#(extra)}"#)
}

final class SongDecodingTests: XCTestCase {
    func testDecodesLooselyTypedServerFields() throws {
        let song = try decode(Song.self, #"""
        {"id":"7","title":"  Srivalli ","artist":"Sid Sriram","album":"Pushpa","album_id":"3",
         "duration_seconds":"215.5","file_path":"Pushpa/Srivalli.mp3","track_number":"2","cover_art":"/covers/7.jpg"}
        """#)
        XCTAssertEqual(song.id, 7)
        XCTAssertEqual(song.title, "Srivalli")
        XCTAssertEqual(song.album_id, 3)
        XCTAssertEqual(song.track_number, 2)
        XCTAssertEqual(song.duration_seconds, 215.5)
    }

    func testMissingOrBlankTitleFallsBackToFileName() throws {
        XCTAssertEqual(try decode(Song.self, #"{"id":1,"file_path":"Hi Nanna/Gaana.mp3"}"#).title, "Gaana")
        XCTAssertEqual(try decode(Song.self, #"{"id":1,"title":"   ","file_path":"x/Odiyamma.mp3"}"#).title, "Odiyamma")
    }

    func testInvalidDurationsBecomeNil() throws {
        for value in ["0", "-3", #""abc""#, #""NaN""#] {
            let song = try decode(Song.self, #"{"id":1,"file_path":"a.mp3","duration_seconds":\#(value)}"#)
            XCTAssertNil(song.duration_seconds, "duration \(value)")
        }
    }

    func testMissingOrNonNumericIDOrMissingPathThrows() {
        XCTAssertThrowsError(try decode(Song.self, #"{"title":"x","file_path":"a.mp3"}"#))
        XCTAssertThrowsError(try decode(Song.self, #"{"id":"abc","file_path":"a.mp3"}"#))
        XCTAssertThrowsError(try decode(Song.self, #"{"id":1,"title":"x"}"#))
    }

    func testDisplayHelpers() throws {
        let plain = try makeSong(1)
        XCTAssertEqual(plain.artistName, "Unknown artist")
        XCTAssertEqual(plain.albumName, "Unknown album")
        XCTAssertEqual(plain.albumKey, "name:Unknown album")
        XCTAssertEqual(plain.externalPlaybackTitle, "T1")

        let movie = try decode(Song.self, #"{"id":2,"title":"Srivalli","album":"Pushpa","album_id":9,"artist":" ","file_path":"a.mp3"}"#)
        XCTAssertEqual(movie.externalPlaybackTitle, "Srivalli • Pushpa")
        XCTAssertEqual(movie.artistName, "Unknown artist")
        XCTAssertEqual(movie.albumKey, "id:9")

        let titleHasMovie = try decode(Song.self, #"{"id":3,"title":"Pushpa Theme","album":"Pushpa","file_path":"a.mp3"}"#)
        XCTAssertEqual(titleHasMovie.externalPlaybackTitle, "Pushpa Theme")
    }
}

final class SongPageTests: XCTestCase {
    func testDecodesBareArrayAsReturnedBySongsEndpoint() throws {
        let page = try decode(SongPage.self, #"[{"id":1,"file_path":"a.mp3"},{"id":2,"file_path":"b.mp3"}]"#)
        XCTAssertEqual(page.songs.map(\.id), [1, 2])
    }

    func testDecodesWrappedSuccessEnvelopeAsReturnedByPlaylistEndpoint() throws {
        let page = try decode(SongPage.self, #"{"success":true,"data":[{"id":5,"file_path":"a.mp3"}]}"#)
        XCTAssertEqual(page.songs.map(\.id), [5])
    }

    func testRejectsFailureEnvelopeAndMissingData() {
        XCTAssertThrowsError(try decode(SongPage.self, #"{"success":false,"data":[]}"#))
        XCTAssertThrowsError(try decode(SongPage.self, #"{"success":true}"#))
    }
}

final class SongCatalogAccumulatorTests: XCTestCase {
    func testDeduplicatesAndDetectsARepeatedFullPage() throws {
        var catalog = SongCatalogAccumulator()
        let one = try makeSong(1), two = try makeSong(2), three = try makeSong(3)
        try catalog.append([one, two], pageSize: 2)
        XCTAssertEqual(catalog.songs.map(\.id), [1, 2])

        try catalog.append([two, three], pageSize: 5)
        XCTAssertEqual(catalog.songs.map(\.id), [1, 2, 3], "a short page with overlap is deduplicated, not an error")

        XCTAssertThrowsError(try catalog.append([one, two], pageSize: 2)) { error in
            guard case MusicError.repeatedPage = error else { return XCTFail("Unexpected error \(error)") }
        }
    }
}

final class ServerAddressTests: XCTestCase {
    private let server = URL(string: "https://music.example.com")!

    private func assertInvalidServer(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ServerAddress.parse(input), "input: \(input)", file: file, line: line) { error in
            guard case MusicError.invalidServer = error else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
        }
    }

    func testParseNormalizesHostAndDefaultPorts() throws {
        XCTAssertEqual(try ServerAddress.parse(" https://Music.Example.com/ ").absoluteString, "https://music.example.com")
        XCTAssertEqual(try ServerAddress.parse("https://music.example.com:443").absoluteString, "https://music.example.com")
        XCTAssertEqual(try ServerAddress.parse("http://192.168.1.5:8080").absoluteString, "http://192.168.1.5:8080")
    }

    func testParseRejectsUnsafeOrIncompleteAddresses() {
        for input in ["", "music.example.com", "ftp://music.example.com", "https://", "https://user:pw@music.example.com",
                      "https://music.example.com/api", "https://music.example.com?x=1", "https://music.example.com/#top"] {
            assertInvalidServer(input)
        }
    }

    func testSameOriginComparesSchemeHostAndEffectivePort() {
        XCTAssertTrue(ServerAddress.sameOrigin(URL(string: "https://music.example.com:443/x")!, server))
        XCTAssertTrue(ServerAddress.sameOrigin(URL(string: "https://MUSIC.example.com/x")!, server))
        XCTAssertFalse(ServerAddress.sameOrigin(URL(string: "http://music.example.com/x")!, server))
        XCTAssertFalse(ServerAddress.sameOrigin(URL(string: "https://music.example.com:8443/x")!, server))
        XCTAssertFalse(ServerAddress.sameOrigin(URL(string: "https://other.example.com/x")!, server))
        XCTAssertFalse(ServerAddress.sameOrigin(URL(string: "https://user:pw@music.example.com/x")!, server))
    }

    func testMediaURLMapsKnownServerPathPrefixes() throws {
        let paths = [
            "Pushpa/Srivalli.mp3",
            "/opt/musicapp/music/Songs/Pushpa/Srivalli.mp3",
            "/music/Pushpa/Srivalli.mp3",
            "music/Pushpa/Srivalli.mp3",
            "Songs/Pushpa/Srivalli.mp3",
        ]
        for path in paths {
            let url = try ServerAddress.mediaURL(for: makeSong(path: path), server: server)
            XCTAssertEqual(url.host, "music.example.com", path)
            XCTAssertEqual(url.path, "/music/Pushpa/Srivalli.mp3", path)
        }
    }

    func testMediaURLKeepsSpacesAndUnicodeInSegments() throws {
        let url = try ServerAddress.mediaURL(for: makeSong(path: "Hi Nanna/Gaana ♪.mp3"), server: server)
        XCTAssertEqual(url.path, "/music/Hi Nanna/Gaana ♪.mp3")
    }

    func testMediaURLRejectsTraversalAbsoluteAndEmptyPaths() throws {
        for path in ["/etc/passwd", "../secret.mp3", "A/../B.mp3", "./a.mp3", "", "Songs/"] {
            XCTAssertThrowsError(try ServerAddress.mediaURL(for: makeSong(path: path), server: server), "path: \(path)") { error in
                guard case MusicError.invalidFile = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
    }

    func testMediaURLAcceptsOnlySameOriginAbsoluteURLs() throws {
        let same = try ServerAddress.mediaURL(for: makeSong(path: "https://music.example.com/music/a.mp3"), server: server)
        XCTAssertEqual(same.absoluteString, "https://music.example.com/music/a.mp3")
        for path in ["https://evil.example.org/a.mp3", "http://music.example.com/a.mp3"] {
            XCTAssertThrowsError(try ServerAddress.mediaURL(for: makeSong(path: path), server: server), path)
        }
    }

    func testCoverURLUsesSameOriginCoverArtOtherwiseFallsBackToSongCover() throws {
        let relative = try makeSong(9, extra: #","cover_art":"/covers/9.jpg""#)
        XCTAssertEqual(ServerAddress.coverURL(for: relative, server: server)?.absoluteString, "https://music.example.com/covers/9.jpg")

        let foreign = try makeSong(9, extra: #","cover_art":"https://cdn.evil.com/x.jpg""#)
        XCTAssertEqual(ServerAddress.coverURL(for: foreign, server: server)?.path, "/covers/9.jpg")
        XCTAssertEqual(ServerAddress.coverURL(for: foreign, server: server)?.host, "music.example.com")

        XCTAssertEqual(ServerAddress.coverURL(for: try makeSong(4), server: server)?.path, "/covers/4.jpg")
        XCTAssertNil(ServerAddress.coverURL(for: try makeSong(4), server: nil))
    }
}

final class LyricsTests: XCTestCase {
    func testParseLRCHandlesFractionsMultipleTagsAndMetadata() {
        let source = "[ar:Someone]\n[00:12.50]Hello\n[00:05.00][00:20.25]Chorus\n[00:30]\n[1:05]Late\nplain text"
        let lines = LyricLine.parseLRC(source)
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Hello", "Chorus", "Late"])
        XCTAssertEqual(lines.map(\.time), [5, 12.5, 20.25, 65])
    }

    func testParseLRCSupportsMillisecondsAndWindowsLineEndings() {
        let lines = LyricLine.parseLRC("[01:02.345]A\r\n[01:03.000]B")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 62.345, accuracy: 0.0001)
        XCTAssertEqual(lines[1].text, "B")
        XCTAssertTrue(LyricLine.parseLRC("").isEmpty)
    }

    func testPayloadReadsSyncedLyricsFromBackendEnvelope() {
        let json = #"{"success":true,"data":{"song_id":"5","status":"synced","syncedLyrics":"[00:01.00]Hi","plainLyrics":"Hi","lines":[]}}"#
        XCTAssertEqual(LyricsPayload.lrc(from: Data(json.utf8)), "[00:01.00]Hi")
    }

    func testPayloadIsNilWhenNothingIsSynced() {
        let nullSynced = #"{"success":true,"data":{"syncedLyrics":null,"plainLyrics":"Hi"}}"#
        XCTAssertNil(LyricsPayload.lrc(from: Data(nullSynced.utf8)))
        let failure = #"{"success":false,"error":"Song not found"}"#
        XCTAssertNil(LyricsPayload.lrc(from: Data(failure.utf8)))
    }

    func testPayloadStillAcceptsLegacyShapesAndPrefersSyncedLyrics() {
        XCTAssertEqual(LyricsPayload.lrc(from: Data(#"{"lrc":"[00:02.00]x"}"#.utf8)), "[00:02.00]x")
        XCTAssertEqual(LyricsPayload.lrc(from: Data("[00:03.00]y".utf8)), "[00:03.00]y")
        XCTAssertEqual(LyricsPayload.lrc(from: Data(#"{"data":{"lyrics":"B","syncedLyrics":"A"}}"#.utf8)), "A")
    }
}

final class PlaylistDecodingTests: XCTestCase {
    func testPlaylistToleratesStringCountsAndMissingFields() throws {
        let playlist = try decode(MusicPlaylist.self, #"{"id":"4","name":"Mood","description":null,"song_count":"12"}"#)
        XCTAssertEqual(playlist.id, 4)
        XCTAssertEqual(playlist.song_count, 12)
        XCTAssertNil(playlist.description)

        let bare = try decode(MusicPlaylist.self, #"{"id":"x","name":"Odd"}"#)
        XCTAssertEqual(bare.id, 0, "the library drops playlists whose id is not positive")
        XCTAssertEqual(bare.song_count, 0)
    }
}

final class AppReleaseTests: XCTestCase {
    private func release(_ version: String, build: Int) throws -> AppRelease {
        try decode(AppRelease.self, #"{"version":"\#(version)","build":\#(build)}"#)
    }

    func testDecodingDefaultsNotesAndDownloadURL() throws {
        let value = try release("1.5.5", build: 155)
        XCTAssertEqual(value.notes, "")
        XCTAssertNil(value.download_url)
    }

    func testVersionValidation() throws {
        XCTAssertTrue(try release("1.5.4", build: 1).validVersion)
        XCTAssertTrue(try release("2", build: 1).validVersion)
        for bad in ["", "1.", "1..2", "1.5.x", "v1.5"] { XCTAssertFalse(try release(bad, build: 1).validVersion, bad) }
        XCTAssertFalse(try release("1.5.4", build: 0).validVersion)
    }

    func testNewerThanComparesNumericallyThenByBuild() throws {
        XCTAssertTrue(try release("1.10.0", build: 1).newerThan(version: "1.9.9", build: 99))
        XCTAssertFalse(try release("1.4.9", build: 999).newerThan(version: "1.5.0", build: 1))
        XCTAssertFalse(try release("1.5.4", build: 154).newerThan(version: "1.5.4", build: 154))
        XCTAssertTrue(try release("1.5.4", build: 155).newerThan(version: "1.5.4", build: 154))
        XCTAssertFalse(try release("1.5", build: 154).newerThan(version: "1.5.0", build: 154))
    }
}
