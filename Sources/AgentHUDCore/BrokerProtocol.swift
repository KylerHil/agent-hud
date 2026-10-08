import Foundation

// The broker is a small helper process that owns the agent sessions the Coordinator starts, so they keep
// running while Agent HUD quits, relaunches or updates. Agent HUD talks to it over a Unix socket, one JSON
// object per line: `BrokerRequest` in, `BrokerMessage` out. See docs/Coordinator-Plan.md §9.7.

public enum BrokerInfo {
    /// Bumped when the wire format changes; an app and a broker that disagree restart the broker once idle.
    public static let protocolVersion = 2

    public static var socketPath: String {
        let p = Paths.home.appendingPathComponent("broker.sock").path
        // sockaddr_un holds 104 bytes; a long AGENTHUD_HOME (tests) falls back to /tmp.
        return p.utf8.count < 100 ? p : "/tmp/agenthud-\(getuid())-\(abs(HistoryIndex.fnv(p)) % 1_000_000).sock"
    }
    public static var stateFile: URL { Paths.home.appendingPathComponent("broker-state.json") }
    public static var logFile: URL { Paths.home.appendingPathComponent("broker.log") }
    public static var lockFile: URL { Paths.home.appendingPathComponent("broker.lock") }
}

public enum BrokerCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - Sessions

public enum DeliveryState: String, Codable, Sendable {
    /// Accepted by the broker, not yet written to the agent.
    case queued
    /// Written to the agent's input.
    case forwarded
    /// The agent echoed it back or started a turn with it.
    case observed
    case failed
}

public struct OutboxMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var state: DeliveryState
    public var at: Date
    public var steer: Bool
    public var error: String?

    public init(id: String, text: String, state: DeliveryState, at: Date, steer: Bool = false, error: String? = nil) {
        self.id = id; self.text = text; self.state = state; self.at = at; self.steer = steer; self.error = error
    }
}

public struct PendingQuestion: Codable, Equatable, Sendable {
    public var id: String
    public var header: String?
    public var question: String
    public var options: [String]
    public var multiSelect: Bool

    public init(id: String, header: String?, question: String, options: [String], multiSelect: Bool) {
        self.id = id; self.header = header; self.question = question; self.options = options; self.multiSelect = multiSelect
    }
}

/// Something a managed agent is blocked on: a permission prompt or a question.
public struct PendingRequest: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case permission, question }
    public var id: String
    public var kind: Kind
    /// The tool asking (Bash, Edit, a Codex command or file change).
    public var tool: String
    /// One line for the card: the command, the file.
    public var summary: String
    public var detail: String?
    public var questions: [PendingQuestion]
    public var since: Date

    public init(id: String, kind: Kind, tool: String, summary: String, detail: String? = nil,
                questions: [PendingQuestion] = [], since: Date) {
        self.id = id; self.kind = kind; self.tool = tool; self.summary = summary; self.detail = detail
        self.questions = questions; self.since = since
    }
}

public enum ManagedStatus: String, Codable, Sendable {
    case starting, idle, busy, waiting, exited, failed
}

/// A session the broker owns.
public struct ManagedSession: Codable, Equatable, Identifiable, Sendable {
    /// The broker's key for it; stable across restarts of the agent process.
    public var id: String
    public var agent: AgentKind
    public var cwd: String
    /// Claude's session id or Codex's thread id, once the agent reports it.
    public var sessionId: String?
    public var transcriptPath: String?
    public var status: ManagedStatus
    public var pending: [PendingRequest] = []
    public var outbox: [OutboxMessage] = []
    public var capabilities: SessionCapabilities
    public var permissionMode: String?
    public var model: String?
    public var pid: Int32?
    public var error: String?
    public var startedAt: Date
    public var lastActivity: Date
    /// The agent's last reply, when its last turn finished.
    public var lastReply: String?
    public var turns: Int = 0
    public var lastTurnStatus: String?
    public var turnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?
    public var currentDetail: String?
    /// Set when the session belongs to a pair.
    public var pairID: String?
    public var title: String?

    public init(id: String, agent: AgentKind, cwd: String, status: ManagedStatus, capabilities: SessionCapabilities,
                startedAt: Date) {
        self.id = id; self.agent = agent; self.cwd = cwd; self.status = status; self.capabilities = capabilities
        self.startedAt = startedAt; self.lastActivity = startedAt
    }

    /// The `Session.id` the hook-driven store uses for the same conversation.
    public var storeID: String? { sessionId.map { "\(agent.rawValue):\($0)" } }

    /// What a managed session can do, by agent: Codex can steer a running turn; Claude queues instead.
    public static func capabilities(for agent: AgentKind) -> SessionCapabilities {
        SessionCapabilities(observe: true, sendNextTurn: true, sendAtCompletion: false,
                            steerActiveTurn: agent == .codex, interruptTurn: true, answerPermission: true,
                            answerQuestion: true, reconnect: true)
    }
}

public struct StartOptions: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var cwd: String
    public var prompt: String?
    /// Continue this conversation (Claude session id / Codex thread id).
    public var resume: String?
    /// With `resume`: continue a copy, leaving the original untouched.
    public var fork: Bool
    /// Claude: default, acceptEdits, auto, plan, bypassPermissions. Codex: read-only, workspace-write.
    public var permissionMode: String?
    public var model: String?
    public var title: String?
    public var pairID: String?

    public init(agent: AgentKind, cwd: String, prompt: String? = nil, resume: String? = nil, fork: Bool = false,
                permissionMode: String? = nil, model: String? = nil, title: String? = nil, pairID: String? = nil) {
        self.agent = agent; self.cwd = cwd; self.prompt = prompt; self.resume = resume; self.fork = fork
        self.permissionMode = permissionMode; self.model = model; self.title = title; self.pairID = pairID
    }
}

// MARK: - Pairs

public struct PairConfig: Codable, Equatable, Sendable {
    public var goal: String
    /// The project's git root.
    public var root: String
    public var planner: AgentKind
    public var builder: AgentKind
    public var reviewer: AgentKind
    /// Stop after the plan is reviewed so you can approve it before anything is built.
    public var approvePlan: Bool
    public var maxRounds: Int
    public var useWorktree: Bool
    /// Run after every build and fix; failing twice in a row stops the pair.
    public var testCommand: String?
    /// The builder's Claude permission mode (acceptEdits, auto, default).
    public var builderMode: String
    /// Stop if a change lands outside this folder (relative to the root), e.g. "src".
    public var pathGuard: String?

    public init(goal: String, root: String, planner: AgentKind = .claude, builder: AgentKind = .claude,
                reviewer: AgentKind = .codex, approvePlan: Bool = true, maxRounds: Int = 3, useWorktree: Bool = true,
                testCommand: String? = nil, builderMode: String = "acceptEdits", pathGuard: String? = nil) {
        self.goal = goal; self.root = root; self.planner = planner; self.builder = builder; self.reviewer = reviewer
        self.approvePlan = approvePlan; self.maxRounds = maxRounds; self.useWorktree = useWorktree
        self.testCommand = testCommand; self.builderMode = builderMode; self.pathGuard = pathGuard
    }
}

public enum PairPhase: String, Codable, Sendable {
    case plan, reviewPlan, revisePlan, approvePlan, build, review, fix, done

    public var label: String {
        switch self {
        case .plan: "Plan"
        case .reviewPlan: "Review plan"
        case .revisePlan: "Revise plan"
        case .approvePlan: "You approve"
        case .build: "Build"
        case .review: "Review"
        case .fix: "Fix"
        case .done: "Done"
        }
    }

    /// Phases where the agent holding the turn may change files.
    public var writes: Bool { self == .build || self == .fix }
}

public enum PairStatus: String, Codable, Sendable {
    case running, waitingOnYou, paused, done, stopped, failed
}

public struct PairEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case handoff, reply, verdict, tests, commit, you, warning, note }
    public var id: String
    public var at: Date
    public var kind: Kind
    public var agent: AgentKind?
    public var phase: PairPhase?
    public var round: Int
    public var text: String

    public init(id: String = UUID().uuidString, at: Date, kind: Kind, agent: AgentKind? = nil, phase: PairPhase? = nil,
                round: Int, text: String) {
        self.id = id; self.at = at; self.kind = kind; self.agent = agent; self.phase = phase; self.round = round; self.text = text
    }
}

public struct ReviewVerdict: Codable, Equatable, Sendable {
    public struct Finding: Codable, Equatable, Sendable {
        public var file: String?
        public var line: Int?
        public var issue: String
        public var severity: String?

        public init(file: String? = nil, line: Int? = nil, issue: String, severity: String? = nil) {
            self.file = file; self.line = line; self.issue = issue; self.severity = severity
        }
    }
    public var verdict: String
    public var sha: String?
    public var findings: [Finding]

    public init(verdict: String, sha: String? = nil, findings: [Finding] = []) {
        self.verdict = verdict; self.sha = sha; self.findings = findings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decode(String.self, forKey: .verdict)
        sha = try c.decodeIfPresent(String.self, forKey: .sha)
        findings = (try? c.decodeIfPresent([Finding].self, forKey: .findings)) ?? []
    }

    public var approved: Bool { verdict.lowercased() == "approve" }
}

public struct PairState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var config: PairConfig
    public var status: PairStatus
    public var phase: PairPhase
    /// Review rounds started (the first diff review is round 1).
    public var round: Int
    public var branch: String?
    public var worktree: String?
    public var baseSHA: String?
    /// The commit the current review is about.
    public var buildSHA: String?
    public var plan: String?
    /// What the builder is asked to fix next: review findings or failing test output.
    public var fixNotes: String?
    public var lastVerdict: ReviewVerdict?
    public var testsPassed: Bool?
    public var testFailuresInARow: Int
    /// Why it's waiting on you or stopped.
    public var reason: String?
    /// Session keys by agent ("claude", "codex").
    public var sessions: [String: String]
    public var events: [PairEvent]
    /// A reviewer that gave no usable verdict is asked once more before the pair stops.
    public var verdictRetries: Int
    public var pauseRequested: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, config: PairConfig, now: Date) {
        self.id = id; self.config = config; status = .running; phase = .plan; round = 0
        testFailuresInARow = 0; sessions = [:]; events = []; verdictRetries = 0; pauseRequested = false
        createdAt = now; updatedAt = now
    }

    /// Where the agents work: the worktree, or the project itself.
    public var workDir: String { worktree ?? config.root }

    public var slug: String { branch.map { ($0 as NSString).lastPathComponent } ?? id }

    /// Which agent holds the turn in a phase.
    public func agent(for phase: PairPhase) -> AgentKind? {
        switch phase {
        case .plan, .revisePlan: config.planner
        case .reviewPlan, .review: config.reviewer
        case .build, .fix: config.builder
        case .approvePlan, .done: nil
        }
    }
}

// MARK: - Wire

public struct BrokerRequest: Codable, Sendable {
    public var id: String
    /// hello, start, send, interrupt, answer, stop, forget, pairStart, pairAction
    public var op: String
    public var start: StartOptions?
    public var session: String?
    public var text: String?
    public var steer: Bool?
    public var requestId: String?
    /// allow, allowSession, deny
    public var decision: String?
    public var answers: [String: [String]]?
    public var message: String?
    public var pair: PairConfig?
    public var pairID: String?
    /// pause, resume, stop, approvePlan, keepGoing, retry, remove
    public var action: String?
    public var version: Int?
    public var editor: EditorWorkspace?
    public var editorID: String?
    public var commandID: String?
    public var ok: Bool?
    public var error: String?

    public init(op: String, id: String = UUID().uuidString) { self.op = op; self.id = id }
}

public struct BrokerMessage: Codable, Sendable {
    /// snapshot, session, removed, pair, pairRemoved, reply
    public var kind: String
    public var version: Int?
    public var brokerPID: Int32?
    public var editors: [EditorWorkspace]?
    public var editorCommand: EditorCommand?
    public var sessions: [ManagedSession]?
    public var session: ManagedSession?
    public var pairs: [PairState]?
    public var pair: PairState?
    public var removed: String?
    public var replyTo: String?
    public var ok: Bool?
    public var error: String?
    /// The session or pair a reply created.
    public var key: String?

    public init(kind: String) { self.kind = kind }
}
