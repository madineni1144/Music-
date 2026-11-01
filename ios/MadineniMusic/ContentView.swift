import SwiftUI
import UIKit

private enum MusicStyle {
    static let background = Color(red: 0.025, green: 0.025, blue: 0.025)
    static let surface = Color(red: 0.161, green: 0.141, blue: 0.122)
    static let accent = Color(red: 0.79, green: 0.47, blue: 0.27)
}

private enum MusicTab: String, CaseIterable {
    case home = "Home", trending = "Trending", explore = "Search", library = "Library", account = "Profile"
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .trending: return "flame.fill"
        case .explore: return "magnifyingglass"
        case .library: return "square.stack.fill"
        case .account: return "person.crop.circle"
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @StateObject private var trendingCharts = InternetTrendingCharts()
    @State private var tab: MusicTab = .home
    @State private var showPlayer = false
    @State private var showSettings = false
    @State private var navigationPath = NavigationPath()
    @State private var exploreQuery = ""
    @State private var librarySection = "Albums"

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                MusicStyle.background.ignoresSafeArea()
                Group {
                    switch tab {
                    case .home:
                        HomeScreen(
                            charts: trendingCharts,
                            openExplore: { query in exploreQuery = query; tab = .explore },
                            openAccount: { tab = .account },
                            openTrending: { tab = .trending },
                            openLibrary: { section in librarySection = section; tab = .library },
                            openSettings: { showSettings = true }
                        )
                    case .explore: ExploreScreen(initialQuery: exploreQuery)
                    case .trending: TrendingScreen(charts: trendingCharts)
                    case .library: LibraryScreen(initialSection: librarySection)
                    case .account: AccountScreen(openSettings: { showSettings = true })
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onChange(of: tab) { _, _ in navigationPath = NavigationPath() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                MiniPlayer(open: { showPlayer = true })
                HStack(spacing: 0) {
                    ForEach(MusicTab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.icon).font(.system(size: 21, weight: .semibold))
                                Text(item.rawValue).font(.caption2.weight(.medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(tab == item ? MusicStyle.accent : Color.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }.background(MusicStyle.background)
            }
            .background(MusicStyle.background)
        }
        .tint(MusicStyle.accent)
        .sheet(isPresented: $showSettings) { ServerSettings() }
        .sheet(isPresented: $showPlayer) { NowPlayingView() }
        .onAppear {
            player.artworkProvider = { song, source in
                library.artworkURLs(song: song, album: library.albums.first(where: { $0.id == song.albumKey }), source: source)
            }
        }
        .task {
            if !library.hasLoaded { _ = await library.connect() }
            _ = await library.refreshPlaylists()
        }
        .alert("Madineni Music", isPresented: Binding(
            get: { library.error != nil || library.playlistError != nil || player.error != nil },
            set: { if !$0 { library.error = nil; library.playlistError = nil; player.error = nil } }
        )) {
            Button("OK") { library.error = nil; library.playlistError = nil; player.error = nil }
        } message: { Text(player.error ?? library.error ?? library.playlistError ?? "") }
    }
}

@MainActor
private struct ScreenHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let subtitle { Text(subtitle.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary) }
            Text(title).font(.largeTitle.bold())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct SectionHeading: View {
    let title: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption { Text(caption.uppercased()).font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary) }
            Text(title).font(.title2.bold())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct HomeScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.openURL) private var openURL
    @ObservedObject var charts: InternetTrendingCharts
    let openExplore: (String) -> Void
    let openAccount: () -> Void
    let openTrending: () -> Void
    let openLibrary: (String) -> Void
    let openSettings: () -> Void
    @AppStorage("trendingChartCountry") private var chartCountry = "in"
    @State private var selectedCategory = "Telugu"
    @State private var chartMatches: [String: Song] = [:]

    private let categories = ["Telugu", "Trending", "Albums", "Artists", "Mood"]
    private var topChartSongs: [InternetTrendingSong] { Array(charts.songs.prefix(3)) }
    private struct ArtistSummary: Identifiable {
        let name: String
        let song: Song
        let count: Int
        var id: String { name }
    }
    private var artists: [ArtistSummary] {
        Dictionary(grouping: library.songs, by: \.artistName)
            .map { ArtistSummary(name: $0.key, song: $0.value[0], count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                categoryChips
                if library.loading || library.loadIssue != nil { LibraryLoadStatus() }
                if library.songs.isEmpty && !library.loading {
                    EmptyLibrary(openSettings: openSettings)
                } else {
                    featuredCard
                    if selectedCategory == "Telugu" || selectedCategory == "Trending" {
                        trendingSection
                        quickPicks
                    }
                    if selectedCategory == "Telugu" || selectedCategory == "Albums" {
                        albumsSection
                    }
                    if selectedCategory == "Artists" { artistsSection }
                    if selectedCategory == "Mood" { playlistsSection }
                    if selectedCategory == "Telugu", !player.recentSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: "Recently played", caption: "Pick up where you left off")
                            ForEach(Array(player.recentSongs.prefix(4))) { song in SongRow(song: song, context: player.recentSongs) }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }.refreshable { _ = await library.connect(); _ = await library.refreshPlaylists() }
            .task(id: chartCountry) { await charts.refresh(country: chartCountry) }
            .onAppear { updateChartMatches() }
            .onChange(of: charts.songs) { _, _ in updateChartMatches() }
            .onChange(of: library.songs) { _, _ in updateChartMatches() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").font(.system(size: 31)).foregroundStyle(MusicStyle.accent)
                Text("Madineni Music").font(.title2.bold())
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { openExplore("") } label: {
                Image(systemName: "magnifyingglass").font(.title3).frame(width: 40, height: 40)
            }.accessibilityLabel("Search music")
            Button(action: openAccount) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
            }.accessibilityLabel("Profile and settings")
        }.foregroundStyle(.primary)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { name in
                    Button {
                        selectedCategory = name
                        switch name {
                        case "Trending": openTrending()
                        case "Albums": openLibrary("Albums")
                        case "Artists": openLibrary("Artists")
                        case "Mood": openLibrary("Playlists")
                        default: break
                        }
                    } label: {
                        Text(name).font(.subheadline.weight(.semibold)).padding(.horizontal, 17).padding(.vertical, 10)
                            .foregroundStyle(selectedCategory == name ? Color.white : Color.primary)
                            .background(selectedCategory == name ? MusicStyle.accent : MusicStyle.surface, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var featuredCard: some View {
        Button {
                let mix = library.songs.shuffled()
                if let first = mix.first, let server = library.server { player.start(first, within: mix, server: server) }
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    CoverView(song: library.songs.first, server: library.server, size: geometry.size.width)
                        .frame(width: geometry.size.width, height: 205).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("MADE FOR YOUR LIBRARY").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.82))
                        Text("Telugu Hits").font(.system(size: 30, weight: .bold))
                        Text("\(library.songs.count) songs · Your personal mix").font(.subheadline).foregroundStyle(.white.opacity(0.82))
                        Image(systemName: "play.fill").font(.headline).foregroundStyle(.white)
                            .frame(width: 48, height: 48).background(MusicStyle.accent, in: Circle()).padding(.top, 2)
                    }.padding(20)
                }.frame(width: geometry.size.width, height: 205).clipShape(RoundedRectangle(cornerRadius: 22))
            }.frame(height: 205)
        }.buttonStyle(.plain).accessibilityLabel("Play Telugu Hits mix")
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionHeading(title: "Trending in India", caption: "Live internet chart")
                Spacer()
                Button("See all", action: openTrending).font(.subheadline.weight(.semibold)).foregroundStyle(MusicStyle.accent)
            }
            if charts.loading && charts.songs.isEmpty {
                ProgressView("Loading current chart…").font(.caption).padding(.vertical, 10)
            } else if let error = charts.error, charts.songs.isEmpty {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") { Task { await charts.refresh(country: chartCountry, force: true) } }.buttonStyle(.bordered)
            } else {
                ForEach(topChartSongs) { item in homeTrendingRow(item) }
            }
        }
    }

    private func homeTrendingRow(_ item: InternetTrendingSong) -> some View {
        let match = chartMatches[item.id]
        return HStack(spacing: 12) {
            Button {
                if let match, let server = library.server { player.start(match, within: library.songs, server: server) }
                else if let url = item.appleMusicURL { openURL(url) }
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: item.artworkURL) { image in image.resizable().scaledToFill() }
                        placeholder: { ZStack { MusicStyle.surface; Image(systemName: "music.note").foregroundStyle(MusicStyle.accent) } }
                        .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(item.artistName) · \(match == nil ? "Open in Apple Music" : "In your library")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Image(systemName: match == nil ? "arrow.up.right.square" : "play.circle.fill")
                .font(.title3).foregroundStyle(MusicStyle.accent).accessibilityHidden(true)
        }
    }

    private func updateChartMatches() {
        let index = TrendingCatalogIndex(songs: library.songs)
        var values: [String: Song] = [:]
        for item in charts.songs {
            if let match = index.match(item) { values[item.id] = match }
        }
        chartMatches = values
    }

    private var quickPicks: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionHeading(title: "Quick picks", caption: "From your collection")
                Spacer()
                Button("Shuffle") {
                    let mix = library.songs.shuffled()
                    if let first = mix.first, let server = library.server { player.start(first, within: mix, server: server) }
                }.font(.subheadline.weight(.semibold)).foregroundStyle(MusicStyle.accent)
            }
            ForEach(Array(library.songs.prefix(4))) { song in SongRow(song: song, context: library.songs) }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionHeading(title: "Albums for you", caption: "From your music library")
                Spacer()
                Button { openLibrary("Albums") } label: { Image(systemName: "chevron.right").font(.headline) }
                    .foregroundStyle(.primary).accessibilityLabel("Browse all albums")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 15) {
                    ForEach(Array(library.albums.prefix(12))) { album in
                        NavigationLink { AlbumScreen(album: album) } label: { AlbumTile(album: album, size: 145) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeading(title: "Artists", caption: "From your collection")
            ForEach(Array(artists.prefix(8))) { artist in
                Button { openExplore(artist.name) } label: {
                    HStack(spacing: 12) {
                        CoverView(song: artist.song, server: library.server, size: 52)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name).font(.subheadline.bold()).lineLimit(1)
                            Text("\(artist.count) songs").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeading(title: "Your playlists", caption: "Pick a mood")
            if library.playlists.isEmpty {
                Text("Create playlists in your Library to build a mood collection.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(library.playlists) { playlist in
                            NavigationLink { PlaylistScreen(playlist: playlist) } label: { PlaylistTile(playlist: playlist) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct EmptyLibrary: View {
    @EnvironmentObject private var library: MusicLibrary
    let openSettings: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.house.fill").font(.system(size: 58)).foregroundStyle(MusicStyle.accent)
            Text(library.server == nil ? "Let's get your music" : "Your library is empty").font(.title2.bold())
            Text(library.server == nil ? "We couldn't load your library. Try connecting again or check your server settings." : "Add songs to your server, then refresh your library.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { Task { await library.connect() } }.buttonStyle(.borderedProminent)
            Button("Server settings", action: openSettings)
        }.padding(28).frame(maxWidth: .infinity).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct RankedChartSong: Identifiable {
    let rank: Int
    let song: InternetTrendingSong
    var id: String { song.id }
}

@MainActor
private struct TrendingScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @ObservedObject var charts: InternetTrendingCharts
    @AppStorage("trendingChartCountry") private var country = "in"
    @State private var teluguOnly = false
    @State private var onlyAvailable = false
    @State private var matches: [String: Song] = [:]

    private var regionName: String { country == "us" ? "USA" : "India" }
    private var visible: [RankedChartSong] {
        charts.songs.enumerated().compactMap { index, song in
            guard !teluguOnly || song.isTelugu, !onlyAvailable || matches[song.id] != nil else { return nil }
            return RankedChartSong(rank: index + 1, song: song)
        }
    }
    private var playable: [Song] {
        var seen = Set<Int>()
        return visible.compactMap { item in
            guard let song = matches[item.id], seen.insert(song.id).inserted else { return nil }
            return song
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack {
                    ScreenHeading(title: "Trending", subtitle: "From internet charts")
                    Image(systemName: "flame.fill").font(.largeTitle).foregroundStyle(MusicStyle.accent)
                }
                HStack {
                    Text("Apple Music · \(regionName) Top 100").font(.subheadline.bold())
                    Spacer()
                    Picker("Chart region", selection: $country) {
                        Text("India").tag("in"); Text("USA").tag("us")
                    }.pickerStyle(.menu)
                }
                Picker("Chart language", selection: $teluguOnly) {
                    Text("All languages").tag(false); Text("Telugu").tag(true)
                }.pickerStyle(.segmented)
                if teluguOnly {
                    Text("Telugu entries within the overall \(regionName) Top 100.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Available in my library", isOn: $onlyAvailable).font(.subheadline)
                Text("Suggestions update from the internet. Play matching songs from your server, or open other songs in Apple Music.")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = charts.fetchedAt {
                    Text("Fetched \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
                if charts.loading { ProgressView("Fetching online chart…") }
                if let error = charts.error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("Retry") { Task { await charts.refresh(country: country, force: true) } }
                        .buttonStyle(.borderedProminent).disabled(charts.loading)
                }
                if !playable.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            let songs = playable
                            if let first = songs.first, let server = library.server { player.start(first, within: songs, server: server) }
                        } label: { Label("Play matches", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                        Button {
                            let songs = playable.shuffled()
                            if let first = songs.first, let server = library.server { player.start(first, within: songs, server: server) }
                        } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    }.controlSize(.large)
                    Text("\(playable.count) chart songs available in your library").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visible) { item in
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(item.rank)").font(.caption.bold()).monospacedDigit().foregroundStyle(MusicStyle.accent).frame(width: 25)
                        if let local = matches[item.id] {
                            SongRow(song: local, context: playable)
                        } else {
                            InternetChartRow(song: item.song)
                        }
                    }.padding(.vertical, 4)
                }
                if visible.isEmpty && !charts.loading && charts.error == nil {
                    ContentUnavailableView("No songs for these filters", systemImage: "music.note.list", description: Text("Try All languages or turn off Available in my library. Your server needs matching title and artist metadata for in-app playback."))
                }
                Link("Chart source: Apple Music RSS", destination: URL(string: "https://rss.marketingtools.apple.com/")!)
                    .font(.caption)
            }.padding(20)
        }
        .task(id: country) { await charts.refresh(country: country) }
        .refreshable { await charts.refresh(country: country, force: true) }
        .onAppear { updateMatches() }
        .onChange(of: charts.songs) { _, _ in updateMatches() }
        .onChange(of: library.songs) { _, _ in updateMatches() }
        .onChange(of: library.server) { _, _ in updateMatches() }
    }

    private func updateMatches() {
        guard library.server != nil else { matches = [:]; return }
        let index = TrendingCatalogIndex(songs: library.songs)
        var values: [String: Song] = [:]
        for song in charts.songs { if let local = index.match(song) { values[song.id] = local } }
        matches = values
    }
}

private struct InternetChartRow: View {
    let song: InternetTrendingSong
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack { MusicStyle.surface; Image(systemName: "music.note").foregroundStyle(MusicStyle.accent) }
            }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(song.name).font(.subheadline.bold()).lineLimit(2)
                Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Not in your library").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let url = song.appleMusicURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("Open \(song.name) in Apple Music")
            }
        }
    }
}

@MainActor
private struct ExploreScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let initialQuery: String
    @State private var search: String
    init(initialQuery: String = "") {
        self.initialQuery = initialQuery
        _search = State(initialValue: initialQuery)
    }
    private var songs: [Song] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? library.songs : library.songs.filter {
            "\($0.title) \($0.artistName) \($0.albumName)".localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ScreenHeading(title: "Search", subtitle: "Find songs, artists, and albums")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Songs, artists, albums", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                }.padding(15).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                if !search.isEmpty {
                    let matches = library.albums.filter { $0.title.localizedCaseInsensitiveContains(search) }
                    if !matches.isEmpty {
                        SectionHeading(title: "Albums")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(matches) { album in
                                    NavigationLink { AlbumScreen(album: album) } label: { AlbumTile(album: album, size: 130) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Text(search.isEmpty ? "All songs" : "\(songs.count) results").font(.title3.bold())
                    Spacer()
                    Button {
                        let mix = songs.shuffled()
                        if let first = mix.first, let server = library.server { player.start(first, within: mix, server: server) }
                    } label: { Image(systemName: "shuffle").padding(10).background(MusicStyle.surface, in: Circle()) }
                        .disabled(songs.isEmpty).accessibilityLabel("Shuffle search results")
                }
                if songs.isEmpty { Text(search.isEmpty ? "Your library has no songs yet." : "No matching songs.").foregroundStyle(.secondary).padding(.vertical, 32) }
                ForEach(songs) { song in SongRow(song: song, context: songs) }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively).refreshable { await library.connect() }
            .onChange(of: initialQuery) { _, value in search = value }
    }
}

private enum SongSort: String, CaseIterable {
    case title = "Title", artist = "Artist", album = "Album", newest = "Newest"
    func sorted(_ songs: [Song]) -> [Song] {
        songs.sorted {
            switch self {
            case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case .artist: return $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending
            case .album: return $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending
            case .newest: return $0.id > $1.id
            }
        }
    }
}

@MainActor
private struct LibraryScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let initialSection: String
    @State private var section: String
    @State private var sort: SongSort = .title
    @State private var search = ""
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    init(initialSection: String = "Albums") {
        self.initialSection = initialSection
        _section = State(initialValue: initialSection)
    }
    private var albums: [AlbumGroup] { library.albums.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    private var songs: [Song] { sort.sorted(library.songs.filter { search.isEmpty || "\($0.title) \($0.artistName) \($0.albumName)".localizedCaseInsensitiveContains(search) }) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ScreenHeading(title: "Library", subtitle: "Your personal collection")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(["Playlists", "Albums", "Songs", "Favorites", "Artists", "History", "Queue"], id: \.self) { name in
                            Button { section = name } label: {
                                Text(name).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(section == name ? MusicStyle.accent : MusicStyle.surface, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if library.loading || library.loadIssue != nil { LibraryLoadStatus() }
                if ["Albums", "Songs", "Favorites", "Artists"].contains(section) {
                    TextField("Search your library", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if section == "Playlists" {
                    HStack {
                        Text("Playlists stored on your server").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button { showingNewPlaylist = true } label: { Label("New", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    }
                    if library.playlists.isEmpty {
                        ContentUnavailableView("No playlists yet", systemImage: "music.note.list", description: Text("Create a playlist. It will be available anywhere this app connects to your music server."))
                    }
                    ForEach(library.playlists) { playlist in
                        NavigationLink { PlaylistScreen(playlist: playlist) } label: {
                            HStack(spacing: 14) {
                                PlaylistArtwork(size: 58)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.song_count) songs").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                            .contextMenu { Button("Delete playlist", systemImage: "trash", role: .destructive) { Task { _ = await library.deletePlaylist(playlist) } } }
                    }
                    if let error = library.playlistError { Text(error).font(.caption).foregroundStyle(MusicStyle.accent) }
                } else if section == "Albums" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], alignment: .leading, spacing: 22) {
                        ForEach(albums) { album in
                            NavigationLink { AlbumScreen(album: album) } label: { AlbumTile(album: album, size: 145) }.buttonStyle(.plain)
                        }
                    }
                    if albums.isEmpty { Text("No matching albums.").foregroundStyle(.secondary) }
                } else if section == "Songs" {
                    Picker("Sort songs", selection: $sort) { ForEach(SongSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                    ForEach(songs) { song in SongRow(song: song, context: songs) }
                    if songs.isEmpty { Text("No matching songs.").foregroundStyle(.secondary) }
                } else if section == "Favorites" {
                    Text("Saved on this device").font(.caption).foregroundStyle(.secondary)
                    let favorites = sort.sorted(library.favoriteSongs.filter { search.isEmpty || "\($0.title) \($0.artistName) \($0.albumName)".localizedCaseInsensitiveContains(search) })
                    ForEach(favorites) { song in SongRow(song: song, context: favorites) }
                    if favorites.isEmpty { Text("Tap the heart beside a song to save it here.").foregroundStyle(.secondary).padding(.vertical, 20) }
                } else if section == "Artists" {
                    let artists = Dictionary(grouping: songs, by: \.artistName)
                    ForEach(artists.keys.sorted(), id: \.self) { name in
                        NavigationLink { SongCollectionScreen(title: name, songs: artists[name] ?? []) } label: {
                            HStack { Image(systemName: "person.circle").font(.title); Text(name); Spacer(); Text("\(artists[name]?.count ?? 0)").foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                    }
                } else if section == "History" {
                    HStack { Text("This session").font(.headline); Spacer(); Button("Clear") { player.clearHistory() }.disabled(player.recentSongs.isEmpty) }
                    ForEach(player.recentSongs) { song in SongRow(song: song, context: player.recentSongs) }
                    if player.recentSongs.isEmpty { Text("Played songs appear here. History stays in memory for this session.").foregroundStyle(.secondary) }
                } else {
                    HStack { Text("Up next").font(.title2.bold()); Spacer(); Button("Shuffle") { player.shuffleUpcoming() }.disabled(!player.canShuffle) }
                    Text("Hold an upcoming song to move it or remove it.").font(.caption).foregroundStyle(.secondary)
                    QueueRows()
                    Button("Clear queue", role: .destructive) { player.clear() }.disabled(player.queue.isEmpty)
                }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively).refreshable { _ = await library.connect(); _ = await library.refreshPlaylists() }
            .onChange(of: initialSection) { _, value in section = value; search = "" }
            .alert("Create playlist", isPresented: $showingNewPlaylist) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    let name = newPlaylistName
                    newPlaylistName = ""
                    Task { _ = await library.createPlaylist(name: name) }
                }
            } message: { Text("Your playlist is saved to your music server.") }
    }
}

@MainActor
private struct PlaylistTile: View {
    let playlist: MusicPlaylist
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistArtwork(size: 136)
            Text(playlist.name).font(.subheadline.bold()).lineLimit(1)
            Text("\(playlist.song_count) songs").font(.caption).foregroundStyle(.secondary)
        }.frame(width: 136, alignment: .leading)
    }
}

@MainActor
private struct PlaylistArtwork: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.58, green: 0.29, blue: 0.16), Color(red: 0.20, green: 0.14, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note.list").font(.system(size: size * 0.34, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: max(8, size * 0.08)))
    }
}

@MainActor
private struct PlaylistScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let playlist: MusicPlaylist
    @State private var songs: [Song] = []
    @State private var loading = true
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    PlaylistArtwork(size: 116)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(playlist.name).font(.title2.bold())
                        Text("\(songs.count) songs • Saved to your server").font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            if let first = songs.first, let server = library.server { player.start(first, within: songs, server: server) }
                        } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(songs.isEmpty)
                    }
                }
                if loading { ProgressView("Loading playlist…") }
                if songs.isEmpty && !loading { Text(library.playlistError ?? "This playlist is empty.").foregroundStyle(.secondary).padding(.vertical, 28) }
                ForEach(songs) { song in
                    HStack(spacing: 0) {
                        SongRow(song: song, context: songs)
                        Button(role: .destructive) {
                            Task {
                                if await library.remove(song, from: playlist) { songs.removeAll { $0.id == song.id } }
                            }
                        } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary).frame(width: 42, height: 44) }
                            .accessibilityLabel("Remove from playlist")
                    }
                }
            }.padding(20)
        }
        .background(MusicStyle.background)
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .task { loading = true; songs = await library.loadPlaylistSongs(playlist) ?? []; loading = false }
        .refreshable { songs = await library.loadPlaylistSongs(playlist) ?? [] }
    }
}

@MainActor
private struct SongCollectionScreen: View {
    let title: String
    let songs: [Song]
    var body: some View {
        ScrollView { LazyVStack(spacing: 18) { ForEach(songs) { SongRow(song: $0, context: songs) } }.padding(20) }
            .background(MusicStyle.background).navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

@MainActor
private struct AlbumTile: View {
    @EnvironmentObject private var library: MusicLibrary
    let album: AlbumGroup
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverView(song: album.songs.first, server: library.server, size: size, album: album)
            Text(album.title).font(.subheadline.bold()).lineLimit(2)
            Text("Album • \(album.songs.count) songs").font(.caption).foregroundStyle(.secondary)
        }.frame(width: size, alignment: .leading)
    }
}

@MainActor
private struct AlbumScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let album: AlbumGroup
    private var currentAlbum: AlbumGroup { library.albums.first(where: { $0.id == album.id }) ?? album }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                CoverView(song: currentAlbum.songs.first, server: library.server, size: 220, album: currentAlbum)
                VStack(spacing: 8) {
                    Text(currentAlbum.title).font(.title.bold()).multilineTextAlignment(.center)
                    Text("Album • \(currentAlbum.songs.count) songs").foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Button {
                        if let song = currentAlbum.songs.first, let server = library.server { player.start(song, within: currentAlbum.songs, server: server) }
                    } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    Button {
                        let mix = currentAlbum.songs.shuffled()
                        if let first = mix.first, let server = library.server { player.start(first, within: mix, server: server) }
                    } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }.controlSize(.large)
                ForEach(currentAlbum.songs) { song in SongRow(song: song, context: currentAlbum.songs) }
            }.padding(20)
        }.background(MusicStyle.background).navigationTitle("Album").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

@MainActor
private struct QueueRows: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    var body: some View {
        if player.queue.isEmpty { Text("Play a song to start your queue.").foregroundStyle(.secondary).padding(.vertical, 24) }
        ForEach(Array(player.queue.enumerated()), id: \.offset) { position, song in
            Button { player.jump(to: position) } label: {
                HStack(spacing: 12) {
                    CoverView(song: song, server: player.playbackServer, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.subheadline.bold()).lineLimit(1)
                        Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if position == player.index { Image(systemName: "waveform").foregroundStyle(MusicStyle.accent) }
                    else { Text("\(position + 1)").font(.caption).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu {
                if position > player.index {
                    Button("Remove from queue", role: .destructive) { player.removeUpcoming(at: position) }
                    Button("Move up") { player.moveUpcoming(from: position, to: position - 1) }.disabled(position == player.index + 1)
                    Button("Move down") { player.moveUpcoming(from: position, to: position + 1) }.disabled(position == player.queue.count - 1)
                }
            }
        }
    }
}

@MainActor
private struct AccountScreen: View {
    @EnvironmentObject private var library: MusicLibrary
    @StateObject private var updates = AppUpdateChecker()
    @State private var showUpdate = false
    let openSettings: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeading(title: "Account")
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 62)).foregroundStyle(MusicStyle.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Madineni Music").font(.title2.bold())
                        Text("Personal library").foregroundStyle(.secondary)
                        Label(library.server == nil ? "Not connected" : library.hasLoaded ? "Library loaded" : "Partial library", systemImage: library.server == nil ? "wifi.slash" : "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(library.server == nil ? Color.secondary : Color.green)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))

                HStack(spacing: 12) {
                    statistic("Songs", value: library.songs.count)
                    statistic("Albums", value: library.albums.count)
                    statistic("Favorites", value: library.favoriteIDs.count)
                }

                VStack(spacing: 0) {
                    Button(action: openSettings) {
                        accountRow("Server settings", detail: library.server?.host ?? "madinenimusic.madineni.xyz", icon: "server.rack")
                    }.buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    Button { Task { await library.connect() } } label: {
                        accountRow(library.loading ? "Refreshing library…" : "Refresh library", detail: "Load the latest songs from your server", icon: "arrow.clockwise")
                    }.buttonStyle(.plain).disabled(library.loading)
                    Divider().padding(.leading, 58)
                    Button {
                        showUpdate = true
                        Task { await updates.check(serverText: library.serverText) }
                    } label: {
                        accountRow("Update app", detail: "Check for a newer version", icon: "arrow.down.circle")
                    }.buttonStyle(.plain)
                }.background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 10) {
                    Text("About").font(.headline)
                    Text("Version \(AppUpdateChecker.installedVersion) • Build \(AppUpdateChecker.installedBuild)").font(.subheadline).foregroundStyle(.secondary)
                    if let refreshed = library.lastRefreshed {
                        Text("Last refreshed: \(refreshed.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Your music streams from your Ubuntu server. Keep it online to listen anywhere.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            }.padding(20)
        }
        .sheet(isPresented: $showUpdate) { UpdateAppSheet(checker: updates) }.presentationDragIndicator(.visible)
    }
    private func statistic(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value)").font(.title.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private func accountRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: icon).font(.title3).foregroundStyle(MusicStyle.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.padding(18).contentShape(Rectangle())
    }
}

@MainActor
private struct MiniPlayer: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let open: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        CoverView(song: player.current, server: player.playbackServer, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.current?.title ?? "Nothing is playing").font(.subheadline.bold()).lineLimit(1)
                            Text(player.buffering ? "Buffering…" : player.current?.artistName ?? "Choose a song to start listening")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(player.current == nil)
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 44, height: 44) }
                    .disabled(player.current == nil).accessibilityLabel(player.playing ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title3).frame(width: 40, height: 44) }.disabled(!player.canGoNext).accessibilityLabel("Next song")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            ProgressView(value: min(player.elapsed, max(player.duration, 1)), total: max(player.duration, 1)).tint(MusicStyle.accent).scaleEffect(x: 1, y: 0.6, anchor: .bottom)
        }.background(MusicStyle.surface)
    }
}

@MainActor
struct SongRow: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let song: Song
    let context: [Song]
    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let server = library.server { player.start(song, within: context, server: server) }
            } label: {
                HStack(spacing: 12) {
                    CoverView(song: song, server: library.server, size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.title).font(.subheadline.bold()).foregroundStyle(player.current?.id == song.id ? MusicStyle.accent : Color.primary).lineLimit(1)
                        Text("\(song.artistName) • \(song.albumName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { library.toggleFavorite(song) } label: {
                Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                    .foregroundStyle(library.isFavorite(song) ? MusicStyle.accent : Color.secondary)
                    .frame(width: 36, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(library.isFavorite(song) ? "Remove from favorites" : "Add to favorites")
            Menu {
                if let album = library.albums.first(where: { $0.id == song.albumKey }) {
                    NavigationLink("Go to album") { AlbumScreen(album: album) }
                }
                Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    if let server = library.server { player.addNext(song, from: server) }
                }.disabled(library.server == nil)
                Button("Add to queue", systemImage: "text.append") {
                    if let server = library.server { player.addToQueue(song, from: server) }
                }.disabled(library.server == nil)
                if !library.playlists.isEmpty {
                    Menu("Add to playlist", systemImage: "music.note.list") {
                        ForEach(library.playlists) { playlist in
                            Button(playlist.name) { Task { _ = await library.add(song, to: playlist) } }
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 40, height: 44) }.accessibilityLabel("Song menu")
        }
    }
}

@MainActor
struct CoverView: View {
    @EnvironmentObject private var library: MusicLibrary
    let song: Song?
    let server: URL?
    let size: CGFloat
    var album: AlbumGroup? = nil
    @State private var image: UIImage?
    private var urls: [URL] { library.artworkURLs(song: song, album: album, source: server) }
    var body: some View {
        ZStack {
            MusicStyle.surface
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(MusicStyle.accent.opacity(0.8)) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(6, size * 0.06)))
        .task(id: urls) {
            image = nil
            for url in urls {
                guard !Task.isCancelled else { return }
                let candidate = await ArtworkLoader.shared.image(from: url)
                guard !Task.isCancelled else { return }
                if let candidate { image = candidate; return }
            }
        }
    }
}

@MainActor
private struct LibraryLoadStatus: View {
    @EnvironmentObject private var library: MusicLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if library.loading {
                ProgressView(library.loadMessage)
                Text("Songs appear as they load. You can browse or play them now.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel loading") { library.cancelLoading() }
            } else if let issue = library.loadIssue {
                Text(issue).font(.subheadline)
                Button("Retry") { Task { await library.connect() } }.buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor
struct ServerSettings: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Music server URL") {
                    TextField("https://madinenimusic.madineni.xyz", text: $draft)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Your music server is filled in automatically. Change it only if you move your server.").font(.caption)
                }
                Section {
                    Button {
                        Task {
                            let previousServer = library.server
                            if await library.connect(to: draft) {
                                if previousServer != library.server { player.clear() }
                                _ = await library.refreshPlaylists()
                                dismiss()
                            }
                        }
                    } label: {
                        if library.loading { ProgressView("Connecting…") } else { Text("Connect and load songs") }
                    }.disabled(library.loading || draft.isEmpty)
                    if library.loading { Button("Cancel loading") { library.cancelLoading() } }
                    if let error = library.error { Text(error).foregroundStyle(.red) }
                }
            }.navigationTitle("Server settings")
                .toolbar { Button("Done") { dismiss() } }
                .onAppear { draft = library.serverText }
        }.tint(MusicStyle.accent)
    }
}

@MainActor
struct NowPlayingView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var section = "Song"
    @State private var seekPosition = 0.0
    @State private var seeking = false
    @State private var seekFromID: UUID?
    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    Picker("Player section", selection: $section) {
                        Text("Song").tag("Song"); Text("Lyrics").tag("Lyrics"); Text("Up next").tag("Up next")
                    }.pickerStyle(.segmented)
                    if section == "Up next" {
                        HStack { Text("Your queue").font(.title2.bold()); Spacer(); Button("Shuffle") { player.shuffleUpcoming() }.disabled(!player.canShuffle) }
                        QueueRows()
                    } else if section == "Lyrics" {
                        LyricsPanel()
                    } else {
                        ViewThatFits(in: .horizontal) {
                            ArtworkStage(size: 310)
                            ArtworkStage(size: 250)
                            ArtworkStage(size: 200)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(player.current?.title ?? "Nothing playing").font(.title2.bold())
                            Text(player.current?.artistName ?? "").font(.subheadline).foregroundStyle(.secondary)
                            Text(player.current?.albumName ?? "").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            if let song = player.current, let album = library.albums.first(where: { $0.id == song.albumKey }) {
                                NavigationLink("Go to album") { AlbumScreen(album: album) }
                            }
                            Spacer()
                            if let song = player.current {
                                Button { library.toggleFavorite(song) } label: {
                                    Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                                        .font(.title3).foregroundStyle(library.isFavorite(song) ? MusicStyle.accent : Color.secondary)
                                        .frame(width: 44, height: 44)
                                }.accessibilityLabel(library.isFavorite(song) ? "Remove from favorites" : "Add to favorites")
                            }
                            AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("Audio output")
                            Menu {
                                Button("Simulate a 3-second interruption", systemImage: "phone.down.fill") {
                                    player.simulateAudioInterruption()
                                }.disabled(!player.playing)
                                Text("Real calls and disconnected headphones are handled automatically.")
                            } label: { Image(systemName: "waveform").frame(width: 40, height: 44) }
                                .accessibilityLabel("Audio interruption test")
                            Menu {
                                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                                    Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                                }
                                Button("Turn off") { player.setSleepTimer(minutes: nil) }
                            } label: { Image(systemName: player.sleepUntil == nil ? "moon" : "moon.fill").frame(width: 44, height: 44) }.accessibilityLabel("Sleep timer")
                        }
                        if let deadline = player.sleepUntil { Text("Sleep timer: \(deadline.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        if player.buffering { ProgressView("Buffering…") }
                        VStack(spacing: 8) {
                            Slider(value: Binding(get: { min(seekPosition, max(player.duration, 1)) }, set: { seekPosition = $0 }), in: 0...max(player.duration, 1), onEditingChanged: { editing in
                                if editing { seekFromID = player.playbackID; seeking = true }
                                else {
                                    if seekFromID == player.playbackID { player.seek(seekPosition) }
                                    seeking = false
                                }
                            }).disabled(player.duration <= 0 || player.playbackFailed).accessibilityLabel("Playback position")
                            HStack { Text(time(seeking ? seekPosition : player.elapsed)); Spacer(); Text(time(player.duration)) }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 0) {
                            Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle").font(.title3).frame(maxWidth: .infinity) }.disabled(!player.canShuffle).accessibilityLabel("Shuffle upcoming songs")
                            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(maxWidth: .infinity) }.accessibilityLabel("Previous song")
                            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 76)).foregroundStyle(MusicStyle.accent) }.accessibilityLabel(player.playing ? "Pause" : "Play")
                            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(maxWidth: .infinity) }.disabled(!player.canGoNext).accessibilityLabel("Next song")
                            Button { player.cycleRepeat() } label: {
                                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3).foregroundStyle(player.repeatMode == .off ? Color.secondary : MusicStyle.accent).frame(maxWidth: .infinity)
                            }.accessibilityLabel("Repeat: \(player.repeatMode.rawValue)")
                        }.foregroundStyle(.white)
                        if let error = player.error { Text(error).font(.caption).foregroundStyle(MusicStyle.accent) }
                        if player.playbackFailed {
                            Button("Retry playback", systemImage: "arrow.clockwise") { player.loadCurrent() }.buttonStyle(.borderedProminent)
                        }
                    }
                }.padding(24)
            }
            .background(LinearGradient(colors: trackPalette(for: player.current), startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
            .navigationTitle("Now playing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Close player") } }
        }
        .onAppear { seekPosition = player.elapsed }
        .onChange(of: player.elapsed) { _, elapsed in if !seeking { seekPosition = elapsed } }
        .onChange(of: player.playbackID) { _, _ in seeking = false; seekFromID = nil; seekPosition = 0 }
        .tint(MusicStyle.accent)
    }

    private func trackPalette(for song: Song?) -> [Color] {
        let identity = "\(song?.title ?? "") \(song?.albumName ?? "")".lowercased()
        if identity.contains("devara") { return [Color(red: 0.38, green: 0.07, blue: 0.09), MusicStyle.background] }
        if identity.contains("pushpa") { return [Color(red: 0.43, green: 0.20, blue: 0.08), MusicStyle.background] }
        if identity.contains("game changer") { return [Color(red: 0.04, green: 0.28, blue: 0.29), MusicStyle.background] }
        if identity.contains("hi nanna") { return [Color(red: 0.24, green: 0.12, blue: 0.39), MusicStyle.background] }
        return [Color(red: 0.30, green: 0.18, blue: 0.13), MusicStyle.background]
    }
}

@MainActor
private struct ArtworkStage: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    let size: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            CoverView(song: player.current, server: player.playbackServer, size: size)
            if player.playing { AudioSpectrum(isPlaying: player.playing).frame(height: 42).padding(.horizontal, 8).padding(.bottom, 7) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity)
    }
}

private struct AudioSpectrum: View {
    let isPlaying: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isPlaying)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let count = 48
                let gap: CGFloat = 2
                let width = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
                for index in 0..<count {
                    let wave = abs(sin(time * 3.4 + Double(index) * 0.42) * cos(time * 1.7 + Double(index) * 0.19))
                    let height = max(3, CGFloat(wave) * size.height)
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(MusicStyle.accent.opacity(0.92)))
                }
            }
        }
        .accessibilityLabel("Animated playback visualizer")
    }
}

@MainActor
private struct LyricsPanel: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @State private var lines: [LyricLine] = []
    @State private var message = ""
    @State private var loading = false
    private var activeIndex: Int {
        guard !lines.isEmpty else { return 0 }
        return max(0, lines.lastIndex(where: { $0.time <= player.elapsed }) ?? 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lyrics").font(.title2.bold())
            Text(player.current?.title ?? "Nothing playing").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if loading { ProgressView("Finding synchronized lyrics…").padding(.top, 28) }
            else if lines.isEmpty { ContentUnavailableView("Lyrics unavailable", systemImage: "quote.bubble", description: Text(message.isEmpty ? "Your server can provide synced LRC lyrics at /api/lyrics?song_id=…" : message)) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                Button { player.seek(line.time) } label: {
                                    Text(line.text).font(index == activeIndex ? .title2.bold() : .title3.weight(.medium))
                                        .foregroundStyle(index == activeIndex ? Color.white : Color.white.opacity(0.43))
                                        .shadow(color: index == activeIndex ? MusicStyle.accent.opacity(0.8) : .clear, radius: 14)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).id(line.id).accessibilityLabel("Seek to \(Int(line.time)) seconds: \(line.text)")
                            }
                        }.padding(.vertical, 36)
                    }
                    .onChange(of: activeIndex) { _, index in
                        guard lines.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(lines[index].id, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .task(id: player.current?.id) {
            lines = []; message = ""
            guard let song = player.current else { return }
            loading = true
            defer { loading = false }
            do { lines = try await library.loadLyrics(for: song) }
            catch { message = error.localizedDescription }
        }
    }
}

@MainActor
private struct UpdateAppSheet: View {
    @ObservedObject var checker: AppUpdateChecker
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 52)).foregroundStyle(MusicStyle.accent)
                    Text(checker.title).font(.title2.bold())
                    if checker.checking { ProgressView("Checking your music server…") }
                    Text(checker.message).foregroundStyle(.secondary)
                    if let release = checker.release, !release.notes.isEmpty {
                        Text("What's new").font(.headline)
                        Text(release.notes).font(.subheadline)
                    }
                    if checker.updateAvailable, let url = checker.downloadURL {
                        Link(destination: url) { Label("Open update page", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    if !checker.checking {
                        Text("For your Xcode installation, open the updated project on your Mac, select the same signing team and bundle ID, then press Run with your iPhone connected.").font(.subheadline)
                    }
                    Text("Installed: \(AppUpdateChecker.installedVersion) (\(AppUpdateChecker.installedBuild))").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(MusicStyle.background)
                .navigationTitle("Update app").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }.tint(MusicStyle.accent)
    }
}
