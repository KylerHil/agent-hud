import Foundation

/// Finds which tmux pane an agent runs in, and which terminal is showing it.
/// An agent inside tmux descends from the tmux server, not from Terminal, so the pane has to be looked up
/// by its tty: `tmux list-panes -a` names each pane's tty, and `list-clients` says which terminal tty
/// is attached to which session.
public enum Tmux {
    public struct Pane: Equatable, Sendable {
        public var tty: String
        public var session: String
        public var windowID: String
        public var paneID: String
    }

    public struct Client: Equatable, Sendable {
        public var tty: String
        public var session: String
        public var pid: Int32
        public var activity: Int
    }

    public static var binary: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/run/current-system/sw/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let sep = "\u{1F}" // unit separator: never in session names or paths

    public static func panes() -> [Pane] {
        parsePanes(run(["list-panes", "-a", "-F", ["#{pane_tty}", "#{session_name}", "#{window_id}", "#{pane_id}"].joined(separator: sep)]) ?? "")
    }

    public static func clients() -> [Client] {
        parseClients(run(["list-clients", "-F", ["#{client_tty}", "#{client_session}", "#{client_pid}", "#{client_activity}"].joined(separator: sep)]) ?? "")
    }

    static func parsePanes(_ out: String) -> [Pane] {
        out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: sep)
            guard f.count == 4 else { return nil }
            return Pane(tty: f[0], session: f[1], windowID: f[2], paneID: f[3])
        }
    }

    static func parseClients(_ out: String) -> [Client] {
        out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: sep)
            guard f.count == 4, let pid = Int32(f[2]) else { return nil }
            return Client(tty: f[0], session: f[1], pid: pid, activity: Int(f[3]) ?? 0)
        }
    }

    /// The pane for `tty`, and the terminal client to show it in: one already on that session, else the
    /// most recently used client (which gets switched to it).
    public static func locate(tty: String, panes: [Pane], clients: [Client]) -> (pane: Pane, client: Client?)? {
        guard let pane = panes.first(where: { $0.tty == tty }) else { return nil }
        let client = clients.filter { $0.session == pane.session }.max { $0.activity < $1.activity }
            ?? clients.max { $0.activity < $1.activity }
        return (pane, client)
    }

    /// Selects the pane (switching the client's session if needed). Returns the client showing it.
    @discardableResult
    public static func select(tty: String) -> Client?? {
        guard binary != nil, let hit = locate(tty: tty, panes: panes(), clients: clients()) else { return nil }
        if let c = hit.client, c.session != hit.pane.session {
            run(["switch-client", "-c", c.tty, "-t", hit.pane.session])
        }
        run(["select-window", "-t", hit.pane.windowID])
        run(["select-pane", "-t", hit.pane.paneID])
        return .some(hit.client)
    }

    @discardableResult
    public static func run(_ args: [String]) -> String? {
        guard let bin = binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
