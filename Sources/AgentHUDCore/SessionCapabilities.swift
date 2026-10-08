import Foundation

/// How the Coordinator can reach a session. Where a session runs (terminal, VS Code) is display metadata;
/// what the Coordinator may do with it comes from the bridge it has, so the composer and buttons are drawn
/// from `SessionCapabilities`, never from "launched here". See docs/Coordinator-Plan.md §9.6.
public enum ControlMode: String, Codable, Sendable {
    /// Hooks, process scan and transcript only.
    case observed
    /// An opted-in Claude channel delivers messages into the interactive session.
    case channelConnected
    /// A Stop hook picks up a queued message at the session's next completion.
    case hookConnected
    /// The agent process (or app-server thread) is owned by Agent HUD's broker.
    case brokerManaged
    /// A live Codex thread owner accepts messages through its native local IPC protocol.
    case nativeConnected
    /// An opt-in UI adapter (tmux, Accessibility) types into the host.
    case automationConnected
}

public struct SessionCapabilities: Equatable, Codable, Sendable {
    public var observe: Bool
    public var sendNextTurn: Bool
    public var sendAtCompletion: Bool
    public var steerActiveTurn: Bool
    public var interruptTurn: Bool
    public var answerPermission: Bool
    public var answerQuestion: Bool
    public var reconnect: Bool

    public init(observe: Bool = true, sendNextTurn: Bool = false, sendAtCompletion: Bool = false,
                steerActiveTurn: Bool = false, interruptTurn: Bool = false, answerPermission: Bool = false,
                answerQuestion: Bool = false, reconnect: Bool = false) {
        self.observe = observe
        self.sendNextTurn = sendNextTurn
        self.sendAtCompletion = sendAtCompletion
        self.steerActiveTurn = steerActiveTurn
        self.interruptTurn = interruptTurn
        self.answerPermission = answerPermission
        self.answerQuestion = answerQuestion
        self.reconnect = reconnect
    }

    /// What every session has today: read its transcript and state, nothing more.
    public static let observed = SessionCapabilities()

    /// True when the Coordinator can put text in front of the agent in any way.
    public var canSend: Bool { sendNextTurn || sendAtCompletion || steerActiveTurn }
}

/// One session's connection as the Coordinator sees it.
public struct SessionControl: Equatable, Sendable {
    public var mode: ControlMode
    public var capabilities: SessionCapabilities
    /// The broker connection that owns it, when there is one.
    public var connectionID: String?
    public var cliVersion: String?

    public init(mode: ControlMode, capabilities: SessionCapabilities, connectionID: String? = nil, cliVersion: String? = nil) {
        self.mode = mode
        self.capabilities = capabilities
        self.connectionID = connectionID
        self.cliVersion = cliVersion
    }

    public static let observed = SessionControl(mode: .observed, capabilities: .observed)
}
