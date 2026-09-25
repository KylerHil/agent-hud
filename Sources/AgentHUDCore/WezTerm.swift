import Foundation

/// WezTerm's tabs, through its CLI: `wezterm cli list --format json` gives each pane's tty, and
/// `wezterm cli activate-pane` selects its tab. (It has no AppleScript, unlike Terminal and iTerm2.)
public enum WezTerm {
    public struct Pane: Equatable, Sendable {
        public var paneID: Int
        public var tabID: Int
        public var windowID: Int
        public var tty: String?
    }

    public static var binary: String? {
        ["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func parse(_ data: Data) -> [Pane] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let pane = r["pane_id"] as? Int else { return nil }
            return Pane(paneID: pane, tabID: r["tab_id"] as? Int ?? 0, windowID: r["window_id"] as? Int ?? 0,
                        tty: r["tty_name"] as? String)
        }
    }

    /// Each running WezTerm window listens on `~/.local/share/wezterm/gui-sock-<pid>`. Outside WezTerm,
    /// `wezterm cli` doesn't know which one to use, and without `--no-auto-start` it would start a separate,
    /// invisible mux server instead; so every call names a GUI socket explicitly.
    public static func guiSockets() -> [String] {
        let dir = Paths.userHome.appendingPathComponent(".local/share/wezterm")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> String? in
            guard name.hasPrefix("gui-sock-"), let pid = Int32(name.dropFirst("gui-sock-".count)),
                  ProcTools.isAlive(pid) else { return nil }
            return dir.appendingPathComponent(name).path
        }
    }

    /// Selects the tab and pane running on `tty`. False when WezTerm isn't installed or no window has it.
    public static func activate(tty: String) -> Bool {
        guard let bin = binary else { return false }
        for socket in guiSockets() {
            guard let out = run(bin, ["cli", "--no-auto-start", "list", "--format", "json"], socket: socket),
                  let pane = parse(out).first(where: { $0.tty == tty }) else { continue }
            return run(bin, ["cli", "--no-auto-start", "activate-pane", "--pane-id", String(pane.paneID)],
                       socket: socket) != nil
        }
        return false
    }

    private static func run(_ bin: String, _ args: [String], socket: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["WEZTERM_UNIX_SOCKET"] = socket
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
