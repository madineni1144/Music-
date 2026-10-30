import Foundation
import Combine

struct InternetTrendingSong: Decodable, Identifiable, Equatable {
    struct Genre: Decodable, Equatable { let name: String }
    let id: String
    let name: String
    let artistName: String
    let artworkUrl100: String?
    let url: String
    let genres: [Genre]?

    var appleMusicURL: URL? {
        guard let value = URL(string: url), value.scheme == "https", value.host == "music.apple.com",
              value.user == nil, value.password == nil else { return nil }
        return value
    }
    var artworkURL: URL? {
        guard let raw = artworkUrl100, let value = URL(string: raw), value.scheme == "https",
              let host = value.host, host.hasSuffix(".mzstatic.com") else { return nil }
        return value
    }
    var isTelugu: Bool { genres?.contains { $0.name.localizedCaseInsensitiveContains("telugu") } == true }
}

struct InternetChartResponse: Decodable {
    struct Feed: Decodable {
        let updated: String?
        let results: [InternetTrendingSong]
    }
    let feed: Feed
}

@MainActor
final class InternetTrendingCharts: ObservableObject {
    @Published private(set) var songs: [InternetTrendingSong] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var country = "in"
    private let session: URLSession
    private var operation = UUID()

    init(session: URLSession = .shared) { self.session = session }

    func refresh(country: String = "in", force: Bool = false) async {
        guard ["in", "us"].contains(country) else { return }
        if !force, self.country == country, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 1800 { return }
        let generation = UUID()
        operation = generation
        if self.country != country { songs = []; fetchedAt = nil }
        self.country = country
        loading = true
        error = nil
        defer { if operation == generation { loading = false } }
        do {
            let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/music/most-played/100/songs.json")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard operation == generation else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw TrendingChartError.unavailable
            }
            guard data.count < 2_000_000 else { throw TrendingChartError.invalid }
            let feed = try JSONDecoder().decode(InternetChartResponse.self, from: data)
            var seen = Set<String>()
            let results = feed.feed.results.filter { seen.insert($0.id).inserted }.prefix(100)
            guard !results.isEmpty else { throw TrendingChartError.unavailable }
            songs = Array(results)
            fetchedAt = Date()
        } catch {
            guard operation == generation, !Task.isCancelled,
                  (error as? URLError)?.code != .cancelled else { return }
            self.error = "Couldn't refresh internet charts. Check your connection and try again."
        }
    }
}

private enum TrendingChartError: Error { case unavailable, invalid }

/// Matches chart entries conservatively so a similarly named track is not played by mistake.
struct TrendingCatalogIndex {
    private let titles: [String: [Song]]
    init(songs: [Song]) { titles = Dictionary(grouping: songs, by: { Self.titleKey($0.title) }) }

    func match(_ item: InternetTrendingSong) -> Song? {
        let candidates = titles[Self.titleKey(item.name)] ?? []
        let artist = Self.key(item.artistName)
        let exact = candidates.filter { Self.key($0.artistName) == artist }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let tokens = Set(artist.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let matching = candidates.filter {
            let local = Set(Self.key($0.artistName).split(separator: " ").map(String.init).filter { $0.count >= 4 })
            return !tokens.intersection(local).isEmpty
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func titleKey(_ input: String) -> String {
        let text = input
            .replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*[\(\[]\s*from\b[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+-\s+from\b.*$"#, with: "", options: .regularExpression)
        return key(text)
    }

    private static func key(_ input: String) -> String {
        input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
