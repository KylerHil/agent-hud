import Foundation

/// Evidence from an extension host, not the editor's recently-opened history.
public struct EditorWorkspace: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var folders: [String]
    public var workspaceFile: String?
    public var remote: String?
    public var trusted: Bool
    public var focused: Bool
    public var connected: Bool
    public var lastSeen: Date

    public init(id: String, name: String, folders: [String], workspaceFile: String? = nil,
                remote: String? = nil, trusted: Bool = true, focused: Bool = false,
                connected: Bool = true, lastSeen: Date = Date()) {
        self.id = id; self.name = name; self.folders = folders; self.workspaceFile = workspaceFile
        self.remote = remote; self.trusted = trusted; self.focused = focused
        self.connected = connected; self.lastSeen = lastSeen
    }

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Never match remote paths to local folders, or similar prefix names to each other.
    public func contains(_ path: String) -> Bool {
        remote == nil && folders.contains { ProjectRoot.contains(Self.canonical($0), Self.canonical(path)) }
    }

    public static func best(in editors: [EditorWorkspace], for path: String) -> EditorWorkspace? {
        editors.filter { $0.connected && $0.contains(path) }.sorted {
            let a = $0.folders.filter { ProjectRoot.contains(canonical($0), canonical(path)) }.map(\.count).max() ?? 0
            let b = $1.folders.filter { ProjectRoot.contains(canonical($0), canonical(path)) }.map(\.count).max() ?? 0
            if a != b { return a > b }
            if $0.focused != $1.focused { return $0.focused }
            return $0.lastSeen > $1.lastSeen
        }.first
    }
}

/// A deliberately small allowlist: no arbitrary VS Code commands or keystrokes over IPC.
public struct EditorCommand: Codable, Sendable {
    public var id: String
    public var editorID: String
    public var action: String
    public var cwd: String
    public var text: String?
    public init(id: String, editorID: String, action: String, cwd: String, text: String? = nil) {
        self.id = id; self.editorID = editorID; self.action = action; self.cwd = cwd; self.text = text
    }
    public static let actions: Set<String> = ["reveal", "review", "result"]
}

public enum CoordinationStatus: String, Sendable {
    case running, idle, waiting, completed, disconnected, failed, stopped
    public var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .waiting: "Waiting on you"
        case .completed: "Completed"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

extension ManagedSession {
    public func coordinationStatus(connected: Bool = true) -> CoordinationStatus {
        if !connected { return .disconnected }
        if !pending.isEmpty && status != .exited && status != .failed { return .waiting }
        switch status {
        case .starting, .busy: return .running
        case .waiting: return .waiting
        case .failed: return .failed
        case .exited: return .stopped
        case .idle:
            if error != nil { return .failed }
            return lastTurnStatus == "completed" ? .completed : .idle
        }
    }
}
