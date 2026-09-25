import Foundation

/// A permission prompt you said yes to: the agent asked, then ran the tool.
public struct ApprovedPermission: Codable, Equatable, Sendable {
    /// When the prompt appeared, plus its session: together they identify it, so a replayed log isn't counted twice.
    public var ts: Double
    public var sessionId: String
    /// The project (git root) it was asked in.
    public var root: String
    public var tool: String
    /// The command, URL or path the tool ran on (truncated, as the hook reported it).
    public var detail: String?
}

/// Commands you approve over and over, as allow rules you could add instead.
public struct PermissionSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { root + "|" + rule }
    public var root: String
    public var project: String { (root as NSString).lastPathComponent }
    /// The rule for Claude's `permissions.allow`, e.g. `Bash(pnpm test:*)`.
    public var rule: String
    /// What the rule allows, in words: `pnpm test`, `fetches from docs.github.com`.
    public var label: String
    public var count: Int
    public var last: Date
    /// A few of the commands it would have covered.
    public var examples: [String]
}

/// Remembers approved permission prompts (~/.agenthud/permissions.json), since the event log only keeps a
/// day or two. Fed every event in log order; a prompt followed by the tool running counts as approved.
public final class PermissionTally {
    public private(set) var approvals: [ApprovedPermission] = []
    private var keys: Set<String> = []
    private var asked: [String: AgentEvent] = [:]
    private let file: URL
    private var dirty = false
    public static let keepFor: TimeInterval = 30 * 86400

    public init(file: URL = Paths.home.appendingPathComponent("permissions.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ApprovedPermission].self, from: data) {
            approvals = saved
            keys = Set(saved.map(Self.key))
        }
    }

    private static func key(_ a: ApprovedPermission) -> String { "\(a.sessionId)@\(a.ts)" }

    /// Returns true when an approval was added.
    @discardableResult
    public func observe(_ e: AgentEvent) -> Bool {
        guard e.agent == .claude, e.origin == "hook" || e.origin == "fake" else { return false }
        switch e.event {
        case "PermissionRequest":
            guard let tool = e.toolName, !SessionStore.questionTools.contains(tool) else { return false }
            asked[e.sessionId] = e
        case "PostToolUse", "PostToolUseFailure":
            // Ran after the prompt (a failing command was still allowed to run).
            guard let q = asked[e.sessionId], q.toolName == e.toolName else { return false }
            asked.removeValue(forKey: e.sessionId)
            guard let cwd = q.cwd ?? e.cwd, cwd != "/" else { return false }
            let a = ApprovedPermission(ts: q.ts, sessionId: q.sessionId, root: ProjectRoot.root(of: cwd),
                                       tool: q.toolName ?? "", detail: q.detail)
            guard keys.insert(Self.key(a)).inserted else { return false }
            approvals.append(a)
            dirty = true
            return true
        case "PermissionDenied", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd":
            asked.removeValue(forKey: e.sessionId)
        default:
            break
        }
        return false
    }

    public func save(now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - Self.keepFor
        if approvals.contains(where: { $0.ts < cutoff }) {
            approvals.removeAll { $0.ts < cutoff }
            keys = Set(approvals.map(Self.key))
            dirty = true
        }
        guard dirty, let data = try? JSONEncoder().encode(approvals) else { return }
        Paths.ensureDir(file.deletingLastPathComponent())
        if (try? data.write(to: file, options: .atomic)) != nil { dirty = false }
    }

    /// Rules that would have saved at least `minCount` prompts in the last `window`, skipping any the
    /// project's settings already allow and any you dismissed. Most-approved first.
    public func suggestions(now: Date = Date(), window: TimeInterval = 14 * 86400, minCount: Int = 3,
                            dismissed: Set<String> = [], allowed: (String) -> [String] = PermissionRules.allowRules)
        -> [PermissionSuggestion] {
        let cutoff = now.timeIntervalSince1970 - window
        var groups: [String: PermissionSuggestion] = [:]
        var allowCache: [String: [String]] = [:]
        for a in approvals where a.ts >= cutoff {
            guard let (rule, label) = PermissionRules.rule(tool: a.tool, detail: a.detail) else { continue }
            let rules = allowCache[a.root] ?? allowed(a.root)
            allowCache[a.root] = rules
            if rules.contains(where: { PermissionRules.covers($0, tool: a.tool, detail: a.detail) }) { continue }
            let id = a.root + "|" + rule
            guard !dismissed.contains(id) else { continue }
            var g = groups[id] ?? PermissionSuggestion(root: a.root, rule: rule, label: label, count: 0,
                                                       last: .distantPast, examples: [])
            g.count += 1
            g.last = max(g.last, Date(timeIntervalSince1970: a.ts))
            if let d = a.detail, g.examples.count < 3, !g.examples.contains(d) { g.examples.append(d) }
            groups[id] = g
        }
        return groups.values.filter { $0.count >= minCount }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
    }
}

/// Claude Code's `permissions.allow` rules: which one a prompt suggests, whether one already covers it,
/// and adding one to a project's `.claude/settings.local.json`.
public enum PermissionRules {
    /// Runners whose second word is what matters: `pnpm test`, `swift build`, `git diff`.
    static let twoWord: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "npx", "bunx", "deno", "make", "swift", "cargo", "go", "uv", "poetry", "pip",
        "pip3", "python", "python3", "node", "docker", "gh", "git", "xcodebuild", "dotnet", "mvn", "gradle",
        "./gradlew", "brew", "bundle", "rake", "rails", "mix", "flutter", "dart", "terraform", "kubectl", "pod", "eas", "expo",
    ]
    /// `npm run test`, `uv run pytest`: the script name is the third word.
    static let scriptVerbs: Set<String> = ["run", "exec", "x", "dlx"]
    /// Never suggested: allowing these broadly would let an agent do real damage without asking.
    static let risky: Set<String> = [
        "rm", "sudo", "su", "dd", "mkfs", "chmod", "chown", "kill", "killall", "pkill", "shutdown", "reboot", "curl",
        "wget", "ssh", "scp", "rsync", "eval", "exec", "sh", "bash", "zsh", "osascript", "security", "launchctl", "mv",
    ]
    static let riskyGit: Set<String> = ["push", "reset", "clean", "checkout", "rebase", "restore", "switch", "branch", "tag", "rm"]

    /// The rule to suggest for a prompt, and a short label for it. nil when nothing safe and specific fits.
    public static func rule(tool: String, detail: String?) -> (rule: String, label: String)? {
        switch tool {
        case "Bash":
            guard let prefix = detail.flatMap(commandPrefix) else { return nil }
            return ("Bash(\(prefix):*)", prefix)
        case "WebFetch":
            guard let d = detail, let host = URL(string: d)?.host, !host.isEmpty else { return nil }
            return ("WebFetch(domain:\(host))", "fetches from \(host)")
        case "WebSearch":
            return ("WebSearch", "web searches")
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
            // File access is better handled by the permission mode (accept edits) than a blanket rule.
            return nil
        default:
            guard !SessionStore.questionTools.contains(tool) else { return nil }
            return (tool, tool.hasPrefix("mcp__") ? tool.components(separatedBy: "__").dropFirst().joined(separator: " › ") : tool)
        }
    }

    /// `pnpm test src/x` → `pnpm test`; `npm run build -- --watch` → `npm run build`; `ls -la` → `ls`.
    /// nil for compound commands, env assignments, truncated runner commands and anything risky.
    static func commandPrefix(_ command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !["&&", "||", ";", "|", ">", "<", "`", "$("].contains(where: { c.contains($0) }) else { return nil }
        let words = c.split(separator: " ").map(String.init)
        guard let first = words.first, !first.contains("="), !first.hasSuffix("…"), !risky.contains(first) else { return nil }
        func plain(_ w: String) -> Bool {
            !w.hasPrefix("-") && !w.hasSuffix("…") && w.allSatisfy { $0.isLetter || $0.isNumber || "-_:.@/".contains($0) }
        }
        guard twoWord.contains(first) else { return first.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) ? first : nil }
        guard words.count > 1, plain(words[1]) else { return nil }
        if first == "git", riskyGit.contains(words[1]) { return nil }
        if scriptVerbs.contains(words[1]) {
            guard words.count > 2, plain(words[2]) else { return nil }
            return words[0...2].joined(separator: " ")
        }
        return words[0...1].joined(separator: " ")
    }

    /// Whether an allow rule already permits this tool call.
    public static func covers(_ rule: String, tool: String, detail: String?) -> Bool {
        let r = rule.trimmingCharacters(in: .whitespaces)
        if r == tool { return true }
        // mcp__server or mcp__server__* covers every tool on that server.
        if tool.hasPrefix("mcp__"), r.hasPrefix("mcp__") {
            let server = r.hasSuffix("__*") ? String(r.dropLast(3)) : r
            if tool.hasPrefix(server + "__") { return true }
        }
        guard r.hasPrefix(tool + "("), r.hasSuffix(")") else { return false }
        let inner = String(r.dropFirst(tool.count + 1).dropLast())
        let d = detail?.trimmingCharacters(in: .whitespaces) ?? ""
        if tool == "WebFetch", inner.hasPrefix("domain:") {
            return URL(string: d)?.host == String(inner.dropFirst("domain:".count))
        }
        for suffix in [":*", " *", "*"] where inner.hasSuffix(suffix) {
            let p = String(inner.dropLast(suffix.count))
            return d == p || d.hasPrefix(p + " ") || (suffix == "*" && d.hasPrefix(p))
        }
        return d == inner
    }

    /// Every allow rule that applies in a project: its shared and local settings, and your own.
    public static func allowRules(root: String) -> [String] {
        let home = Paths.userHome.appendingPathComponent(".claude")
        let project = URL(fileURLWithPath: root).appendingPathComponent(".claude")
        let files = [project.appendingPathComponent("settings.json"), project.appendingPathComponent("settings.local.json"),
                     home.appendingPathComponent("settings.json"), home.appendingPathComponent("settings.local.json")]
        return files.flatMap { url -> [String] in
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let perms = obj["permissions"] as? [String: Any] else { return [] }
            return perms["allow"] as? [String] ?? []
        }
    }

    public static func localSettings(root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(".claude/settings.local.json")
    }

    /// The change adding `rule` would make, without making it.
    public static func plan(adding rule: String, root: String) throws -> (file: URL, original: String?, updated: String, diff: String) {
        let file = localSettings(root: root)
        let original = try? String(contentsOf: file, encoding: .utf8)
        let input = (original?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? "{}" : original!
        let filter = #".permissions = (.permissions // {}) | .permissions.allow = ((.permissions.allow // []) | if index([$rule]) then . else . + [$rule] end)"#
        let updated = try HookInstaller.runJQ(filter: filter, args: ["--arg", "rule", rule], input: input)
        return (file, original, updated, HookInstaller.unifiedDiff(original ?? "", updated, path: file.path))
    }

    /// Adds `rule` to the project's `.claude/settings.local.json` (your own, untracked settings), backing up
    /// the old file first. Returns the backup, if there was a file to back up.
    @discardableResult
    public static func add(_ rule: String, root: String, now: Date = Date()) throws -> URL? {
        let p = try plan(adding: rule, root: root)
        let fm = FileManager.default
        var backup: URL?
        if fm.fileExists(atPath: p.file.path) {
            Paths.ensureDir(Paths.backupsDir)
            let name = (root as NSString).lastPathComponent
            let dest = Paths.backupsDir.appendingPathComponent("\(name)-settings.local.json.\(HookInstaller.backupStamp(now)).bak")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: p.file, to: dest)
            backup = dest
        }
        try fm.createDirectory(at: p.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(p.updated.utf8).write(to: p.file, options: .atomic)
        return backup
    }
}
