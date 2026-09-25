import Darwin
import Foundation

/// All on-disk locations. `AGENTHUD_HOME` overrides the base dir (used by tests and fake-events).
public enum Paths {
    /// App Store builds run in App Sandbox; the app and its hook reporter then share an App Group container.
    public static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// The App Group id, written into Info.plist at build time (`AgentHUDAppGroup`). The reporter lives in
    /// the app's Contents/MacOS, so `Bundle.main` finds the same Info.plist for both.
    public static var appGroup: String? { Bundle.main.object(forInfoDictionaryKey: "AgentHUDAppGroup") as? String }

    public static var home: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["AGENTHUD_HOME"] ?? env["AGENTWATCH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        if isSandboxed, let group = appGroup,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container
        }
        return userHome.appendingPathComponent(".agenthud", isDirectory: true)
    }

    /// Where AgentWatch (AgentHUD's earlier name) kept its data.
    public static var legacyHome: URL { userHome.appendingPathComponent(".agentwatch", isDirectory: true) }

    /// The real home folder, even inside App Sandbox (where NSHomeDirectory() is the container).
    /// `AGENTHUD_USER_HOME` lets tests point the installer at a scratch home.
    public static var userHome: URL {
        let env = ProcessInfo.processInfo.environment
        if let h = env["AGENTHUD_USER_HOME"] ?? env["AGENTWATCH_USER_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static var eventsFile: URL { home.appendingPathComponent("events.jsonl") }
    public static var rotatedEventsFile: URL { home.appendingPathComponent("events.1.jsonl") }
    public static var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public static var installedReporter: URL { binDir.appendingPathComponent("agenthud-report") }
    public static var backupsDir: URL { home.appendingPathComponent("backups", isDirectory: true) }

    /// Claude Code's own state file: per-project model usage, among much else.
    public static var claudeState: URL { userHome.appendingPathComponent(".claude.json") }
    public static var claudeSettings: URL { userHome.appendingPathComponent(".claude/settings.json") }
    public static var claudeProjects: URL { userHome.appendingPathComponent(".claude/projects", isDirectory: true) }
    /// Claude desktop's per-session metadata for its Code tab.
    public static var claudeDesktopSessions: URL {
        userHome.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }
    public static var codexHome: URL {
        let env = ProcessInfo.processInfo.environment
        if env["AGENTHUD_USER_HOME"] == nil, env["AGENTWATCH_USER_HOME"] == nil,
           let h = env["CODEX_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }
    public static var codexHooks: URL { codexHome.appendingPathComponent("hooks.json") }
    public static var codexConfig: URL { codexHome.appendingPathComponent("config.toml") }
    public static var codexSessions: URL { codexHome.appendingPathComponent("sessions", isDirectory: true) }

    public static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// One-time move of `~/.agentwatch` to `~/.agenthud`, leaving a symlink behind so hooks installed by
    /// AgentWatch (which run `~/.agentwatch/bin/agentwatch-report`) keep writing to the same log until
    /// they're updated. Returns true when it moved something.
    @discardableResult
    /// Moves `src`'s contents into `dst`: folders merge, and files from `src` replace same-named ones.
    private static func merge(_ src: String, into dst: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: src) {
            let s = (src as NSString).appendingPathComponent(name), d = (dst as NSString).appendingPathComponent(name)
            var sDir: ObjCBool = false, dDir: ObjCBool = false
            fm.fileExists(atPath: s, isDirectory: &sDir)
            if fm.fileExists(atPath: d, isDirectory: &dDir) {
                if sDir.boolValue && dDir.boolValue { try merge(s, into: d); continue }
                try fm.removeItem(atPath: d)
            }
            try fm.moveItem(atPath: s, toPath: d)
        }
    }

    public static func migrateLegacyHome() -> Bool {
        let fm = FileManager.default
        guard !isSandboxed, ProcessInfo.processInfo.environment["AGENTHUD_HOME"] == nil,
              ProcessInfo.processInfo.environment["AGENTWATCH_HOME"] == nil else { return false }
        let old = legacyHome.path, new = home.path
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old, isDirectory: &isDir), isDir.boolValue,
              (try? fm.destinationOfSymbolicLink(atPath: old)) == nil else { return false }
        do {
            if fm.fileExists(atPath: new) {
                // Something ran before the migration and started a fresh folder (an empty log, a rebuildable
                // index): the old folder's files are the real ones, so they win.
                try merge(old, into: new)
                try fm.removeItem(atPath: old)
            } else {
                try fm.moveItem(atPath: old, toPath: new)
            }
            try fm.createSymbolicLink(atPath: old, withDestinationPath: new)
            return true
        } catch {
            return false
        }
    }
}
