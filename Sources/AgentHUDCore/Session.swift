import Foundation

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case needsInput, running, idle, stale, unknown, ended

    /// NEEDS INPUT first, then RUNNING, then IDLE; stale/unknown/ended trail.
    public var sortRank: Int {
        switch self {
        case .needsInput: 0
        case .running: 1
        case .stale: 2
        case .idle: 3
        case .unknown: 4
        case .ended: 5
        }
    }

    public var verb: String {
        switch self {
        case .needsInput: "waiting"
        case .running: "running"
        case .idle: "idle"
        case .stale: "stale"
        case .unknown: "seen"
        case .ended: "ended"
        }
    }
}

/// Something the agent is blocked on. Keyed by tool_use_id when the hook gives one.
public struct PendingInput: Equatable, Sendable {
    public var reason: String
    public var detail: String?
    public var scope: String?   // subagent id, nil = main thread
    public var since: Date
}

public struct Subagent: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var running: Bool
    public var since: Date
    public var lastEventAt: Date
}

/// One line in a session's recent history, for the detail view.
public struct TimelineEntry: Equatable, Sendable {
    public enum Tone: String, Sendable { case normal, prompt, attention, error, done, running }
    public var at: Date
    public var kind: String
    public var note: String?
    public var detail: String?
    public var tone: Tone
}

/// A test command the agent ran, and how it came out.
public struct TestRun: Equatable, Sendable {
    public var command: String
    public var passed: Bool
    public var at: Date
}

public struct Session: Identifiable, Equatable, Sendable {
    public var id: String            // "<agent>:<session_id>"
    public var agent: AgentKind
    public var sessionId: String
    /// Current working directory, which follows the agent's `cd`s.
    public var cwd: String?
    /// Where the session started (what `--resume` needs) and the project it belongs to (its git root).
    public var launchDir: String?
    public var root: String?
    public var transcriptPath: String?
    public var pid: Int32?
    public var tty: String?
    public var hostApp: String?
    public var hostKind: String?

    /// running / idle / ended / unknown; needsInput is derived from `pending`.
    public var base: SessionState
    public var pending: [String: PendingInput] = [:]
    public var subagents: [String: Subagent] = [:]
    public var stateSince: Date
    public var lastEventAt: Date
    public var lastActivityEvent: String?
    public var lastPrompt: String?
    public var lastMessage: String?
    public var currentDetail: String?
    public var error: String?
    public var endedAt: Date?
    /// True once a real hook event arrived (vs. inferred from processes or Codex rollout logs).
    public var hasHooks: Bool = false
    public var origin: String?
    /// Conversation title from the host app, when it has one.
    public var title: String?
    /// Opens this exact session in its host app, when the app has such a link.
    public var openURL: String?

    /// Most recent first-class events, oldest first, capped at `timelineLimit`.
    public var timeline: [TimelineEntry] = []
    public static let timelineLimit = 60
    public var toolCalls = 0
    /// Files edited or written this session, in first-touched order.
    public var filesChanged: [String] = []
    /// Total time spent waiting on you, and how many times.
    public var waitedTotal: TimeInterval = 0
    public var waits = 0
    /// When the current (or last) turn began, and how long the last finished one took.
    public var turnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?
    /// The current (or last) turn: files it edited, commands it ran and its last test run, for the recap.
    public var turnFiles: [String] = []
    public var turnCommands = 0
    public var turnTest: TestRun?

    public init(id: String, agent: AgentKind, sessionId: String, base: SessionState, stateSince: Date, lastEventAt: Date) {
        self.id = id
        self.agent = agent
        self.sessionId = sessionId
        self.base = base
        self.stateSince = stateSince
        self.lastEventAt = lastEventAt
    }

    public var state: SessionState {
        if base == .ended { return .ended }
        return pending.isEmpty ? base : .needsInput
    }

    public var projectName: String {
        if isChat { return title ?? agent.displayName }
        guard let dir = root ?? cwd, !dir.isEmpty, dir != "/" else { return title ?? "(unknown)" }
        return (dir as NSString).lastPathComponent
    }

    /// What "group by project" groups on: the project root (so subfolders and different apps join their
    /// project). Chats and sessions with no folder stand alone.
    public var projectKey: String {
        if isChat { return id }
        return root ?? cwd.flatMap { $0 == "/" ? nil : $0 } ?? id
    }

    /// Sessions collected by project, keeping the given order (most urgent first), so each group's first
    /// session is its most urgent.
    public static func groupedByProject(_ ordered: [Session]) -> [[Session]] {
        var groups: [[Session]] = []
        var index: [String: Int] = [:]
        for s in ordered {
            if let i = index[s.projectKey] { groups[i].append(s) } else {
                index[s.projectKey] = groups.count
                groups.append([s])
            }
        }
        return groups
    }

    /// The current folder relative to the project root, when the agent is working below it ("apps/mobile").
    public var subpath: String? {
        guard let root, let cwd, cwd != root, ProjectRoot.contains(root, cwd) else { return nil }
        return String(cwd.dropFirst(root.count).drop { $0 == "/" })
    }

    /// The app the session lives in, for the row's source chip.
    public var hostLabel: String? {
        switch hostKind {
        case nil: return nil
        case "terminal": return "Terminal"
        case "iterm": return "iTerm2"
        case "vscode": return "VS Code"
        case "cursor": return "Cursor"
        case "windsurf": return "Windsurf"
        case "ghostty": return "Ghostty"
        case "warp": return "Warp"
        case "wezterm": return "WezTerm"
        case "claude-desktop": return "Claude app"
        case "chatgpt": return "ChatGPT app"
        case "codex-desktop": return "Codex app"
        case "tmux": return "tmux"
        case let k?: return k.prefix(1).uppercased() + k.dropFirst()
        }
    }

    /// Desktop-app sessions and chats, which the Sources settings can hide.
    public var isDesktop: Bool { ["claude-desktop", "chatgpt", "codex-desktop"].contains(hostKind ?? "") }
    public var isChat: Bool { origin == "chat" }

    /// Shell command that reopens this conversation, when the agent supports it.
    public var resumeCommand: String? {
        guard !isChat, !sessionId.hasPrefix("pid-") else { return nil }
        let cd = (launchDir ?? cwd).map { "cd \(Self.shellQuote($0)) && " } ?? ""
        switch agent {
        case .claude: return cd + "claude --resume \(sessionId)"
        case .codex: return cd + "codex resume \(sessionId)"
        case .chatgpt: return nil
        }
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "Edited 3 files · ran 7 commands · tests passed": what the last turn did, or nil when it did none of it.
    public var turnSummary: String? {
        var parts: [String] = []
        if !turnFiles.isEmpty { parts.append("edited \(turnFiles.count) file\(turnFiles.count == 1 ? "" : "s")") }
        if turnCommands > 0 { parts.append("ran \(turnCommands) command\(turnCommands == 1 ? "" : "s")") }
        if let t = turnTest { parts.append(t.passed ? "tests passed" : "tests failed") }
        guard let first = parts.first else { return nil }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: " · ")
    }

    /// Oldest outstanding request, the one worth showing.
    public var primaryPending: PendingInput? { pending.values.min { $0.since < $1.since } }

    public var sortedSubagents: [Subagent] {
        subagents.values.sorted { ($0.running ? 0 : 1, $0.since) < ($1.running ? 0 : 1, $1.since) }
    }

    /// Adds staleness, which depends on the clock rather than events.
    public func displayState(now: Date, staleAfter: TimeInterval, lastOutputAt: Date? = nil) -> SessionState {
        let s = state
        guard s == .running else { return s }
        let last = max(lastEventAt, lastOutputAt ?? .distantPast)
        return now.timeIntervalSince(last) > staleAfter ? .stale : s
    }
}
