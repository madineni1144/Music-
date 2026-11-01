import Foundation
import Combine

@MainActor
final class AppUpdateChecker: ObservableObject {
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.4"
    }
    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "154") ?? 154
    }
    @Published private(set) var checking = false
    @Published private(set) var title = "Check for updates"
    @Published private(set) var message = "Check your music server for the latest app version."
    @Published private(set) var release: AppRelease?
    @Published private(set) var updateAvailable = false
    private let session: URLSession
    private let installedVersionNumber: String
    private let installedBuildNumber: Int

    init(session: URLSession = .shared, installedVersion: String? = nil, installedBuild: Int? = nil) {
        self.session = session
        installedVersionNumber = installedVersion ?? Self.installedVersion
        installedBuildNumber = installedBuild ?? Self.installedBuild
    }

    var downloadURL: URL? {
        guard updateAvailable, let value = release?.download_url,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    func check(serverText: String) async {
        guard !checking else { return }
        checking = true
        title = "Checking for updates"
        message = "Looking for the latest release."
        release = nil
        updateAvailable = false
        defer { checking = false }

        do {
            let server = try ServerAddress.parse(serverText)
            let url = server.appendingPathComponent("ios-app-release.json")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw MusicError.notJSON }
            if http.statusCode == 404 {
                title = "Update details aren't available yet"
                message = "Your music server hasn't published app release information. You can still update using the latest Xcode project on your Mac."
                return
            }
            guard (200..<300).contains(http.statusCode) else { throw MusicError.response(http.statusCode) }
            // Some simple static servers label JSON as application/octet-stream.
            // Decode the bytes rather than relying on their content-type header.
            let latest = try JSONDecoder().decode(AppRelease.self, from: data)
            guard latest.validVersion else {
                title = "Invalid update details"
                message = "The server's release file needs a numeric version and a positive build number."
                return
            }
            release = latest
            updateAvailable = latest.newerThan(version: installedVersionNumber, build: installedBuildNumber)
            if updateAvailable {
                title = "Version \(latest.version) is available"
                message = "A newer build (\(latest.build)) is available. Update using Xcode, or open the update page if one is provided."
            } else {
                title = "You're up to date"
                message = "Your installed app is as new as, or newer than, the release listed on your music server."
            }
        } catch is DecodingError {
            title = "Update details aren't available yet"
            message = "The server did not return a valid release file. Use the latest Xcode project to update, or publish ios-app-release.json on your music server."
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                title = "Check cancelled"
                message = "Close this panel and tap Update app to check again."
                return
            }
            title = "Couldn't check for updates"
            message = error.localizedDescription
        }
    }
}
