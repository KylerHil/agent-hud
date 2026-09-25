import Foundation

/// Which folder a session belongs to. Agents `cd` around while they work (Claude Code keeps the shell's
/// directory between commands), so the hook's `cwd` drifts into subfolders; the name shown should not.
public enum ProjectRoot {
    private static let lock = NSLock()
    private static var gitCache: [String: String?] = [:]

    /// Where the session started: Claude names its transcript folder after the launch directory
    /// (`~/.claude/projects/-Users-me-proj/…`), so the ancestor of `cwd` with that encoding is it.
    public static func launchDir(cwd: String, transcriptPath: String?) -> String {
        guard let transcriptPath else { return cwd }
        let encoded = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return launchDir(cwd: cwd, encodedDir: encoded)
    }

    /// The ancestor of `cwd` whose Claude project-folder encoding is `encoded`, else `cwd`.
    public static func launchDir(cwd: String, encodedDir encoded: String) -> String {
        var dir = cwd
        while dir.count > 1 {
            if encode(dir) == encoded { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return cwd
    }

    /// The git root above `dir` (a `.git` directory or worktree file), else `dir` itself.
    /// A repo at the home folder (dotfiles) is not a project root.
    public static func root(of dir: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let hit = gitCache[dir] { return hit ?? dir }
        let home = Paths.userHome.path
        var p = dir
        var found: String?
        while p.count > 1, p != home {
            if FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) {
                found = p
                break
            }
            p = (p as NSString).deletingLastPathComponent
        }
        gitCache[dir] = found
        return found ?? dir
    }

    /// Claude Code's project-folder encoding: every character that isn't an ASCII letter or digit becomes "-".
    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// `true` when `path` is `ancestor` or inside it.
    public static func contains(_ ancestor: String, _ path: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}
