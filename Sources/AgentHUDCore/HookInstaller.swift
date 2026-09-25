import Foundation

/// Merges AgentHUD hook entries into ~/.claude/settings.json and ~/.codex/hooks.json.
///
/// - Only entries whose command mentions `agenthud-report` are ever added or removed.
/// - Install = strip ours, then append ours, so it is idempotent.
/// - Uses /usr/bin/jq so the user's key order and formatting survive.
/// - Every write is preceded by a timestamped backup in ~/.agenthud/backups.
public enum HookInstaller {
    public enum Target: String, CaseIterable, Sendable {
        case claude, codex

        public var file: URL { self == .claude ? Paths.claudeSettings : Paths.codexHooks }
        public var displayName: String { self == .claude ? "Claude Code" : "Codex" }

        public var events: [String] {
            switch self {
            case .claude:
                ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                 "PostToolUseFailure", "PostToolBatch", "PermissionRequest", "PermissionDenied", "Notification",
                 "Stop", "StopFailure", "SubagentStart", "SubagentStop", "Elicitation", "ElicitationResult"]
            case .codex:
                ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                 "Stop", "Interrupt", "SubagentStart", "SubagentStop"]
            }
        }
    }

    public struct Plan: Sendable {
        public var target: Target
        public var install: Bool
        public var file: URL
        public var original: String?
        /// nil = delete the file (it only ever held our hooks).
        public var updated: String?
        public var diff: String
        public var warnings: [String]
        public var changed: Bool { original != updated }
    }

    public enum InstallError: LocalizedError {
        case jqMissing
        case jq(String)
        case blocked(String)

        public var errorDescription: String? {
            switch self {
            case .jqMissing: "jq not found at /usr/bin/jq (it ships with macOS 15+; or `brew install jq`)."
            case .jq(let msg): "Could not parse or update the config file: \(msg)"
            case .blocked(let msg): msg
            }
        }
    }

    static let marker = "agenthud-report"
    /// What hook commands said before the rename; still recognized so installing replaces them.
    static let legacyMarker = "agentwatch-report"

    /// The reporter hook commands run: a stable copy in ~/.agenthud/bin, or, in App Sandbox (where the app
    /// can't write there), the one inside the app bundle.
    public static var defaultReporter: String {
        Paths.isSandboxed ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agenthud-report").path
            : Paths.installedReporter.path
    }
    static var jqPath: String {
        ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/usr/bin/jq"
    }

    static let jqFunctions = #"""
    def isours: (type == "object") and ((.command? // "") | tostring | test("agenthud-report|agentwatch-report"));
    def hasours: [.. | select(isours)] | length > 0;
    def strip:
      if (.hooks | type) == "object" and (.hooks | hasours) then
        .hooks |= with_entries(
          if (.value | hasours) then
            (.value |= map(
              if (.hooks | type) == "array" and (.hooks | hasours)
              then (.hooks |= map(select(isours | not))) | select(.hooks | length > 0)
              else . end))
            | select(.value | length > 0)
          else . end)
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end;
    """#

    public static func hookEntry(target: Target, reporter: String) -> [String: Any] {
        [
            "type": "command",
            "command": "'\(reporter)' --agent \(target.rawValue)",
            "async": true,
            "timeout": 5,
        ]
    }

    public static func isInstalled(_ target: Target) -> Bool {
        guard let text = try? String(contentsOf: target.file, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Hooks installed by AgentWatch, before the rename. Installing again replaces them.
    public static func hasLegacyHooks(_ target: Target) -> Bool {
        guard let text = try? String(contentsOf: target.file, encoding: .utf8) else { return false }
        return text.contains(legacyMarker)
    }

    public static func plan(_ target: Target, install: Bool, reporter: String = defaultReporter) throws -> Plan {
        let fm = FileManager.default
        let original = try? String(contentsOf: target.file, encoding: .utf8)
        var warnings: [String] = []

        if target == .codex, let toml = try? String(contentsOf: Paths.codexConfig, encoding: .utf8) {
            let lines = toml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if install, lines.contains(where: { $0.hasPrefix("[hooks") || $0.hasPrefix("[[hooks") }) {
                throw InstallError.blocked("""
                    \(Paths.codexConfig.path) already defines [hooks]. Codex does not allow hooks.json and inline \
                    [hooks] in the same layer, so AgentHUD will not add hooks.json. Move those hooks into \
                    hooks.json first, or add AgentHUD's entries to config.toml by hand.
                    """)
            }
            var inFeatures = false
            for l in lines {
                if l.hasPrefix("[") { inFeatures = l == "[features]" }
                if inFeatures, l.replacingOccurrences(of: " ", with: "").hasPrefix("hooks=false") {
                    warnings.append("Codex hooks are disabled (`hooks = false` under [features] in config.toml).")
                }
            }
        }

        let input = (original?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? "{}" : original!
        var filter = jqFunctions + "\nstrip"
        var args: [String] = []
        if install {
            filter += " | .hooks = (.hooks // {}) | reduce $events[] as $e (.; .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [$hook]}]))"
            let events = try JSONSerialization.data(withJSONObject: target.events)
            let hook = try JSONSerialization.data(withJSONObject: hookEntry(target: target, reporter: reporter),
                                                  options: [.sortedKeys, .withoutEscapingSlashes])
            args = ["--argjson", "events", String(decoding: events, as: UTF8.self),
                    "--argjson", "hook", String(decoding: hook, as: UTF8.self)]
        }
        var updated: String? = try runJQ(filter: filter, args: args, input: input)

        if original == nil && !install { updated = nil }
        // Normalize: an unchanged document must compare equal even if the original lacked a trailing newline.
        if let o = original, let u = updated, try runJQ(filter: ".", args: [], input: o) == u { updated = o }
        if target == .codex, !install, updated?.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" { updated = nil }
        if original == nil, updated == "{}\n" { updated = nil }

        if !fm.fileExists(atPath: target.file.deletingLastPathComponent().path), install, target == .codex {
            warnings.append("\(target.file.deletingLastPathComponent().path) does not exist; is Codex installed?")
        }
        let diff = unifiedDiff(original ?? "", updated ?? "", path: target.file.path)
        return Plan(target: target, install: install, file: target.file, original: original, updated: updated,
                    diff: diff, warnings: warnings)
    }

    /// Back up, then write atomically. Returns the backup paths.
    @discardableResult
    public static func apply(_ plan: Plan, now: Date = Date()) throws -> [URL] {
        guard plan.changed else { return [] }
        let fm = FileManager.default
        Paths.ensureDir(Paths.backupsDir)
        let stamp = backupStamp(now)
        var backups: [URL] = []
        func backup(_ url: URL, as name: String) throws {
            guard fm.fileExists(atPath: url.path) else { return }
            let dest = Paths.backupsDir.appendingPathComponent("\(name).\(stamp).bak")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
            backups.append(dest)
        }
        switch plan.target {
        case .claude: try backup(plan.file, as: "claude-settings.json")
        case .codex:
            try backup(plan.file, as: "codex-hooks.json")
            try backup(Paths.codexConfig, as: "codex-config.toml") // not modified, backed up anyway
        }

        guard let updated = plan.updated else {
            try? fm.removeItem(at: plan.file)
            return backups
        }
        let dir = plan.file.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = (try? fm.attributesOfItem(atPath: plan.file.path)[.posixPermissions]) ?? NSNumber(value: 0o644)
        let tmp = dir.appendingPathComponent(".\(plan.file.lastPathComponent).agenthud-tmp")
        try Data(updated.utf8).write(to: tmp)
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(plan.file, withItemAt: tmp)
        return backups
    }

    /// Copies the reporter binary to its stable home (~/.agenthud/bin) that hook commands point at.
    @discardableResult
    public static func installReporter(from source: URL) throws -> Bool {
        let fm = FileManager.default
        let dest = Paths.installedReporter
        if source.standardizedFileURL == dest.standardizedFileURL { return false }
        if let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: dest), a == b { return false }
        Paths.ensureDir(Paths.binDir)
        let tmp = Paths.binDir.appendingPathComponent(".agenthud-report.tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
        return true
    }

    static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func runJQ(filter: String, args: [String], input: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: jqPath) else { throw InstallError.jqMissing }
        return try run(jqPath, [filter] + args + ["--indent", "2"], input: input, allowFailure: false)
    }

    static func unifiedDiff(_ a: String, _ b: String, path: String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = dir.appendingPathComponent("a"), fb = dir.appendingPathComponent("b")
        try? a.write(to: fa, atomically: true, encoding: .utf8)
        try? b.write(to: fb, atomically: true, encoding: .utf8)
        return (try? run("/usr/bin/diff", ["-u", "--label", "\(path) (current)", "--label", "\(path) (new)",
                                          fa.path, fb.path], input: nil, allowFailure: true)) ?? ""
    }

    private static func run(_ exe: String, _ args: [String], input: String?, allowFailure: Bool) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        try p.run()
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 && !allowFailure {
            throw InstallError.jq(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
