import Foundation

struct AppRelease: Decodable {
    let version: String
    let build: Int
    let notes: String
    let download_url: String?

    enum CodingKeys: String, CodingKey { case version, build, notes, download_url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decode(Int.self, forKey: .build)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        download_url = try c.decodeIfPresent(String.self, forKey: .download_url)
    }

    var validVersion: Bool {
        version.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil
            && version.split(separator: ".").allSatisfy { Int($0) != nil }
            && build > 0
    }

    func newerThan(version installed: String, build installedBuild: Int) -> Bool {
        let latest = version.split(separator: ".").map { Int($0) ?? 0 }
        let current = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(latest.count, current.count) {
            let a = index < latest.count ? latest[index] : 0
            let b = index < current.count ? current[index] : 0
            if a != b { return a > b }
        }
        return build > installedBuild
    }
}

