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

public struct Session: Identifiable, Equatable, Sendable {
    public var id: String            // "<agent>:<session_id>"
    public var agent: AgentKind
    public var sessionId: String
    public var cwd: String?
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

    public var state: SessionState {
        if base == .ended { return .ended }
        return pending.isEmpty ? base : .needsInput
    }

    public var projectName: String {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return "(unknown)" }
        return (cwd as NSString).lastPathComponent
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
