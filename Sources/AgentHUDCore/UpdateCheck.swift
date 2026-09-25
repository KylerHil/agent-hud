import Foundation

/// Finds out whether a newer Agent HUD has been released, from GitHub's latest-release API.
/// This is the app's only network request, and Settings can turn it off.
public enum UpdateCheck {
    public static let repo = "KylerHil/agent-hud"
    public static var latestURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    public static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    public struct Release: Equatable, Sendable {
        public var version: String
        public var page: URL
        public var notes: String?
    }

    public static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, obj["draft"] as? Bool != true, obj["prerelease"] as? Bool != true
        else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, notes: obj["body"] as? String)
    }

    /// "1.10.0" > "1.9.2"; missing parts count as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Homebrew's install of the cask, if that's how this copy got here.
    public static func brewCaskroom() -> URL? {
        ["/opt/homebrew/Caskroom/agent-hud", "/usr/local/Caskroom/agent-hud"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static var brewBinary: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
