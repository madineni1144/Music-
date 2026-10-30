import SwiftUI

@main
@MainActor
struct MadineniMusicApp: App {
    @StateObject private var library = MusicLibrary()
    @StateObject private var player = MusicPlayer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.79, green: 0.47, blue: 0.27))
        }
    }
}
