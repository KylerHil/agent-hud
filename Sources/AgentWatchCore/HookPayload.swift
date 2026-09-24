import Foundation

/// Turns a raw hook stdin payload (Claude Code or Codex; both use the same field names) into an `AgentEvent`.
public enum HookPayload {
    public static func makeEvent(payload: [String: Any], agent: AgentKind, eventOverride: String?,
                                 now: Date = Date()) -> AgentEvent {
        func str(_ key: String) -> String? {
            if let s = payload[key] as? String, !s.isEmpty { return s }
            return nil
        }

        let eventName = eventOverride ?? str("hook_event_name") ?? "Unknown"
        let sessionId = str("session_id") ?? str("thread_id") ?? "unknown"
        var e = AgentEvent(ts: now.timeIntervalSince1970, agent: agent, event: eventName, sessionId: sessionId)
        e.cwd = str("cwd")
        e.transcriptPath = str("transcript_path")
        e.agentId = str("agent_id") ?? str("subagent_id")
        e.agentType = str("agent_type")
        e.toolName = str("tool_name")
        e.toolUseId = str("tool_use_id")
        e.notificationType = str("notification_type")
        e.source = str("source") ?? str("reason") ?? str("error_type")
        e.origin = "hook"

        let message = str("notification_text") ?? str("message") ?? str("error_message")
            ?? str("last_assistant_message") ?? str("prompt_text")
        e.message = message?.preview(240)

        if eventName == "UserPromptSubmit" {
            e.prompt = (str("user_input") ?? str("prompt"))?.preview(120)
        }
        if let input = payload["tool_input"] {
            e.detail = toolSummary(tool: e.toolName, input: input)?.preview(120)
        }
        return e
    }

    /// The most human-meaningful bit of a tool input: a command, a file path, a question.
    static func toolSummary(tool: String?, input: Any) -> String? {
        if let s = input as? String { return s }
        guard let dict = input as? [String: Any] else { return nil }
        for key in ["command", "cmd", "file_path", "path", "pattern", "url", "query", "description"] {
            if let v = dict[key] as? String, !v.isEmpty { return v }
            if let arr = dict[key] as? [String], !arr.isEmpty { return arr.joined(separator: " ") }
        }
        if let questions = dict["questions"] as? [[String: Any]], let q = questions.first?["question"] as? String {
            return q
        }
        return nil
    }
}

/// Append-only writer for the shared event log.
public enum EventLog {
    /// One `write(2)` with O_APPEND per event, so concurrent reporters never interleave lines.
    @discardableResult
    public static func append(_ event: AgentEvent, to url: URL = Paths.eventsFile) -> Bool {
        guard let line = event.jsonLine() else { return false }
        Paths.ensureDir(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == line.count
    }
}
