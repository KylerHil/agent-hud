import Foundation

/// All on-disk locations. `AGENTWATCH_HOME` overrides the base dir (used by tests and fake-events).
public enum Paths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTWATCH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return userHome.appendingPathComponent(".agentwatch", isDirectory: true)
    }

    /// `AGENTWATCH_USER_HOME` lets tests point the installer at a scratch home.
    public static var userHome: URL {
        if let h = ProcessInfo.processInfo.environment["AGENTWATCH_USER_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static var eventsFile: URL { home.appendingPathComponent("events.jsonl") }
    public static var rotatedEventsFile: URL { home.appendingPathComponent("events.1.jsonl") }
    public static var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public static var installedReporter: URL { binDir.appendingPathComponent("agentwatch-report") }
    public static var backupsDir: URL { home.appendingPathComponent("backups", isDirectory: true) }

    public static var claudeSettings: URL { userHome.appendingPathComponent(".claude/settings.json") }
    public static var codexHome: URL {
        if ProcessInfo.processInfo.environment["AGENTWATCH_USER_HOME"] == nil,
           let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty {
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
}
