import Foundation
import Observation

public struct Transition: Equatable, Sendable {
    public var sessionID: String
    public var from: SessionState?
    public var to: SessionState
    public var at: Date
}

/// The per-session state machine. Feed it events in log order; it reports state changes.
@Observable
public final class SessionStore {
    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "request_user_input"]
    static let attentionNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]
    private static let notifyKey = "notification"
    private static let elicitKey = "elicitation"

    public static func key(_ agent: AgentKind, _ sessionId: String) -> String { "\(agent.rawValue):\(sessionId)" }
    public static func placeholderKey(_ agent: AgentKind, pid: Int32) -> String { "\(agent.rawValue):pid-\(pid)" }

    @discardableResult
    public func apply(_ e: AgentEvent) -> Transition? {
        let key = Self.key(e.agent, e.sessionId)
        let now = e.date
        let old = sessions[key]
        var s = old ?? Session(id: key, agent: e.agent, sessionId: e.sessionId, base: .idle,
                               stateSince: now, lastEventAt: now)
        let before = old?.state

        // A hooked session supersedes any process-only placeholder for the same pid.
        if let pid = e.pid, e.origin == "hook" || e.origin == "fake" {
            sessions.removeValue(forKey: Self.placeholderKey(e.agent, pid: pid))
        }

        if let v = e.cwd { s.cwd = v }
        if let v = e.transcriptPath { s.transcriptPath = v }
        if let v = e.pid { s.pid = v }
        if let v = e.tty { s.tty = v }
        if let v = e.hostApp { s.hostApp = v }
        if let v = e.hostKind { s.hostKind = v }
        if e.origin == "hook" || e.origin == "fake" { s.hasHooks = true }
        s.origin = s.origin ?? e.origin
        s.lastEventAt = max(s.lastEventAt, now)

        let scope = e.agentId
        if let scope, e.event != "SubagentStop" { touchSubagent(&s, id: scope, type: e.agentType, at: now) }

        switch e.event {
        case "SessionStart":
            if e.source != "compact" {
                s.base = .idle
                s.pending.removeAll()
                s.subagents.removeAll()
                s.endedAt = nil
                s.error = nil
            }
        case "UserPromptSubmit":
            s.base = .running
            s.pending.removeAll()
            s.error = nil
            s.lastMessage = nil
            s.currentDetail = nil
            s.lastPrompt = e.prompt ?? s.lastPrompt
        case "PreToolUse":
            markRunning(&s)
            s.currentDetail = [e.toolName, e.detail].compactMap { $0 }.joined(separator: " · ")
            if scope == nil { s.pending.removeValue(forKey: Self.notifyKey) }
            // Codex runs tools one at a time: starting a new tool means any earlier prompt was answered.
            if e.agent == .codex { s.pending = s.pending.filter { $0.value.scope != scope } }
            if let tool = e.toolName, Self.questionTools.contains(tool) {
                let reason = tool == "ExitPlanMode" ? "Plan approval" : "Question"
                s.pending[e.toolUseId ?? tool] = PendingInput(reason: reason, detail: e.detail, scope: scope, since: now)
            }
        case "PermissionRequest":
            markRunning(&s)
            let reason = "Permission: " + (e.toolName ?? "tool")
            s.pending[e.toolUseId ?? "permission-\(scope ?? "main")"] =
                PendingInput(reason: reason, detail: e.detail, scope: scope, since: now)
            s.pending.removeValue(forKey: Self.notifyKey)
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            markRunning(&s)
            if let id = e.toolUseId { s.pending.removeValue(forKey: id) }
            s.pending.removeValue(forKey: "permission-\(scope ?? "main")")
            if scope == nil { s.pending.removeValue(forKey: Self.notifyKey) }
        case "PostToolBatch":
            // Every call in the batch resolved, so every prompt in this scope was answered.
            markRunning(&s)
            s.pending = s.pending.filter { $0.value.scope != scope && $0.key != Self.notifyKey }
        case "Notification":
            let type = e.notificationType ?? ""
            if Self.attentionNotifications.contains(type) {
                // Usually a duplicate of PermissionRequest; only matters when nothing else is pending.
                if s.pending.isEmpty && s.base != .ended {
                    s.pending[Self.notifyKey] = PendingInput(reason: e.message ?? "Needs input", detail: nil,
                                                              scope: scope, since: now)
                }
            } else if type == "idle_prompt" {
                s.base = .idle
                s.pending.removeAll()
            } else if type.hasPrefix("elicitation_") {
                s.pending.removeValue(forKey: Self.notifyKey)
                s.pending.removeValue(forKey: Self.elicitKey)
            }
        case "Elicitation":
            s.pending[Self.elicitKey] = PendingInput(reason: "MCP input", detail: e.message, scope: scope, since: now)
        case "ElicitationResult":
            s.pending.removeValue(forKey: Self.elicitKey)
        case "Stop", "StopFailure", "Interrupt", "Interrupted":
            if scope == nil {
                s.base = .idle
                s.pending.removeAll()
                s.currentDetail = nil
                for id in s.subagents.keys { s.subagents[id]?.running = false }
                if let m = e.message { s.lastMessage = m }
                s.error = e.event == "StopFailure" ? (e.message ?? e.source ?? "API error") : nil
                if e.event.hasPrefix("Interrupt") { s.lastMessage = "Interrupted" }
            }
        case "SubagentStart":
            if let scope { touchSubagent(&s, id: scope, type: e.agentType, at: now, restart: true) }
            markRunning(&s)
        case "SubagentStop":
            if let scope {
                if s.subagents[scope] == nil { touchSubagent(&s, id: scope, type: e.agentType, at: now) }
                s.subagents[scope]?.running = false
                s.subagents[scope]?.since = now
                s.pending = s.pending.filter { $0.value.scope != scope }
            }
        case "SessionEnd", "ProcessExited":
            s.base = .ended
            s.endedAt = now
            s.pending.removeAll()
            for id in s.subagents.keys { s.subagents[id]?.running = false }
        case "RolloutRunning", "RolloutIdle", "RolloutNeedsInput", "ProcessSeen":
            // Inferred states never override what hooks told us.
            if !s.hasHooks {
                switch e.event {
                case "RolloutRunning": s.base = .running; s.pending.removeAll()
                case "RolloutIdle": s.base = .idle; s.pending.removeAll()
                case "RolloutNeedsInput":
                    s.pending["rollout"] = PendingInput(reason: e.message ?? "Approval", detail: e.detail,
                                                        scope: nil, since: now)
                default: if old == nil { s.base = .unknown }
                }
                if let m = e.message, e.event == "RolloutIdle" { s.lastMessage = m }
                if let p = e.prompt { s.lastPrompt = p }
            }
        default:
            break
        }

        if e.event != "ProcessSeen" { s.lastActivityEvent = e.event }
        let after = s.state
        if after != before { s.stateSince = now }
        sessions[key] = s
        return after != before ? Transition(sessionID: key, from: before, to: after, at: now) : nil
    }

    private func markRunning(_ s: inout Session) {
        if s.base != .ended { s.base = .running }
    }

    private func touchSubagent(_ s: inout Session, id: String, type: String?, at: Date, restart: Bool = false) {
        if var sub = s.subagents[id], !restart {
            if !sub.running { sub.running = true; sub.since = at }
            sub.lastEventAt = at
            s.subagents[id] = sub
        } else {
            s.subagents[id] = Subagent(id: id, type: type ?? "subagent", running: true, since: at, lastEventAt: at)
        }
    }

    // MARK: - Maintenance

    public func remove(_ id: String) { sessions.removeValue(forKey: id) }

    public func update(_ id: String, _ body: (inout Session) -> Void) {
        guard var s = sessions[id] else { return }
        body(&s)
        sessions[id] = s
    }

    /// Drop ended sessions after `endedRetention`, finished subagents after a minute,
    /// and pid-less sessions nobody has heard from in `abandonAfter`.
    public func prune(now: Date, endedRetention: TimeInterval, abandonAfter: TimeInterval = 12 * 3600) {
        for (id, s) in sessions {
            if s.state == .ended, now.timeIntervalSince(s.endedAt ?? s.lastEventAt) > endedRetention {
                sessions.removeValue(forKey: id)
            } else if s.pid == nil, now.timeIntervalSince(s.lastEventAt) > abandonAfter {
                sessions.removeValue(forKey: id)
            } else {
                let done = s.subagents.filter { !$0.value.running && now.timeIntervalSince($0.value.since) > 60 }
                if !done.isEmpty { update(id) { for k in done.keys { $0.subagents.removeValue(forKey: k) } } }
            }
        }
    }

    /// NEEDS INPUT, RUNNING, IDLE…; within a state, longest-waiting first.
    public func sorted(now: Date, staleAfter: TimeInterval, lastOutput: (Session) -> Date? = { _ in nil }) -> [Session] {
        sessions.values.sorted { a, b in
            let ra = a.displayState(now: now, staleAfter: staleAfter, lastOutputAt: lastOutput(a)).sortRank
            let rb = b.displayState(now: now, staleAfter: staleAfter, lastOutputAt: lastOutput(b)).sortRank
            if ra != rb { return ra < rb }
            if a.stateSince != b.stateSince { return a.stateSince < b.stateSince }
            return a.id < b.id
        }
    }
}
