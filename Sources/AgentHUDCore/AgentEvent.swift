import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex
    /// Ordinary ChatGPT conversations, seen through Accessibility (experimental).
    case chatgpt

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .chatgpt: "ChatGPT"
        }
    }
}

/// One line in ~/.agenthud/events.jsonl. Hook payloads are reduced to these fields so lines stay small.
public struct AgentEvent: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var ts: Double
    public var agent: AgentKind
    /// Hook event name (`PreToolUse`, `Stop`, …) or a synthetic one (`ProcessExited`, `RolloutRunning`, …).
    public var event: String
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    /// Subagent identity when the event came from inside a subagent.
    public var agentId: String?
    public var agentType: String?
    public var toolName: String?
    public var toolUseId: String?
    public var notificationType: String?
    /// Notification text, error message, or last assistant message (truncated).
    public var message: String?
    /// Short summary of tool input, e.g. the Bash command (truncated).
    public var detail: String?
    /// Preview of the user prompt (UserPromptSubmit only, truncated).
    public var prompt: String?
    /// SessionStart source / SessionEnd reason / StopFailure error type.
    public var source: String?
    public var pid: Int32?
    public var tty: String?
    /// Path of the .app bundle hosting the agent (VS Code, Terminal, iTerm2, …).
    public var hostApp: String?
    public var hostKind: String?
    /// Conversation title, when the host app names it (Claude desktop, chat windows).
    public var title: String?
    /// A URL that opens this exact session in its host app (Claude desktop: claude://code/continue?session=…).
    public var openURL: String?
    /// `hook`, `fake`, `scanner`, `rollout`, `desktop`, `chat`, `probe`.
    public var origin: String?

    public init(ts: Double = Date().timeIntervalSince1970, agent: AgentKind, event: String, sessionId: String) {
        self.ts = ts
        self.agent = agent
        self.event = event
        self.sessionId = sessionId
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public func jsonLine() -> Data? {
        guard var data = try? AgentEvent.encoder.encode(self) else { return nil }
        data.append(0x0A)
        return data
    }

    public static func parse(line: Data) -> AgentEvent? {
        try? decoder.decode(AgentEvent.self, from: line)
    }
}

extension String {
    /// Single-line, length-capped preview.
    public func preview(_ max: Int) -> String {
        let flat = split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max - 1)) + "…"
    }
}

/// "42s", "4m", "1h 12m", "2d".
public func shortDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86400)d"
}

/// "4m 12s" under an hour, else "1h 12m": for elapsed times where seconds still matter.
public func longDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
