import Foundation

/// Follows ~/.agenthud/events.jsonl: replays recent history once, then delivers new lines as they land.
/// Polling a stat() twice a second is cheaper than it sounds and survives rotation/truncation for free.
public final class EventTailer {
    public typealias Handler = (_ events: [AgentEvent], _ isReplay: Bool) -> Void

    private let url: URL
    private let handler: Handler
    private let maxReplayBytes: UInt64
    private let replayWindow: TimeInterval
    private let rotateAtBytes: UInt64
    private var handle: FileHandle?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var partial = Data()
    private var timer: Timer?

    public init(url: URL = Paths.eventsFile, maxReplayBytes: UInt64 = 8 << 20,
                replayWindow: TimeInterval = 24 * 3600, rotateAtBytes: UInt64 = 20 << 20,
                handler: @escaping Handler) {
        self.url = url
        self.handler = handler
        self.maxReplayBytes = maxReplayBytes
        self.replayWindow = replayWindow
        self.rotateAtBytes = rotateAtBytes
    }

    public func start(interval: TimeInterval = 0.4) {
        Paths.ensureDir(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        replay()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        try? handle?.close()
        handle = nil
    }

    private func open() -> Bool {
        try? handle?.close()
        guard let h = try? FileHandle(forReadingFrom: url) else { handle = nil; return false }
        handle = h
        inode = Self.inode(of: url) ?? 0
        offset = 0
        partial.removeAll()
        return true
    }

    private func replay() {
        guard open(), let h = handle else { return }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > maxReplayBytes ? size - maxReplayBytes : 0
        try? h.seek(toOffset: start)
        offset = start
        var data = (try? h.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data[(nl + 1)...] } // skip partial first line
        let cutoff = Date().timeIntervalSince1970 - replayWindow
        let events = split(data).filter { $0.ts >= cutoff }
        handler(events, true)
    }

    public func poll() {
        let currentInode = Self.inode(of: url)
        if currentInode == nil { return } // file vanished; wait for a reporter to recreate it
        let size = Self.size(of: url) ?? 0
        if currentInode != inode || size < offset {
            if let h = handle { drain(h) } // finish whatever the old file still holds
            guard open() else { return }
        }
        guard let h = handle, size > offset else { return }
        drain(h)
        if offset > rotateAtBytes { rotate() }
    }

    private func drain(_ h: FileHandle) {
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        let events = split(data)
        if !events.isEmpty { handler(events, false) }
    }

    /// Complete lines become events; a trailing partial line waits for the next read.
    private func split(_ chunk: Data) -> [AgentEvent] {
        var buffer = partial + chunk
        partial.removeAll()
        var events: [AgentEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty, let e = AgentEvent.parse(line: Data(line)) { events.append(e) }
            buffer = buffer[(nl + 1)...]
        }
        partial = Data(buffer)
        return events
    }

    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.rotatedEventsFile)
        try? fm.moveItem(at: url, to: Paths.rotatedEventsFile)
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    static func inode(of url: URL) -> UInt64? {
        var st = stat()
        return stat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    static func size(of url: URL) -> UInt64? {
        var st = stat()
        return stat(url.path, &st) == 0 ? UInt64(st.st_size) : nil
    }
}

/// Cheap peeks at an agent's transcript file.
public enum TranscriptProbe {
    public static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    /// Last `bytes` of a file, split into complete lines.
    public static func tailLines(_ path: String, bytes: Int = 16 * 1024) -> [Substring] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    public struct ContextUsage: Equatable, Sendable {
        public var tokens: Int
        /// Known for Codex (its logs record it); nil for Claude, whose window depends on the plan and model.
        public var window: Int?
        /// The model that wrote the last reply (Claude), which tells whether it runs with the 1M window.
        public var model: String? = nil
        public var fraction: Double? { window.map { $0 > 0 ? min(1, Double(tokens) / Double($0)) : 0 } }
    }

    /// Models you run with the 1M-token window. Transcripts only say `claude-opus-5-5`, but Claude Code's
    /// per-project usage in ~/.claude.json names them `claude-opus-5-5[1m]`.
    public static func longContextModels(stateFile: URL = Paths.claudeState) -> Set<String> {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = obj["projects"] as? [String: Any] else { return [] }
        var out = Set<String>()
        for case let p as [String: Any] in projects.values {
            for key in (p["lastModelUsage"] as? [String: Any])?.keys ?? [:].keys where key.hasSuffix("[1m]") {
                out.insert(String(key.dropLast(4)))
            }
        }
        return out
    }

    /// How much context the conversation is using, from the last usage record in the transcript.
    public static func contextUsage(_ path: String, agent: AgentKind) -> ContextUsage? {
        for line in tailLines(path, bytes: 256 * 1024).reversed() {
            switch agent {
            case .claude:
                guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\""),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { continue }
                let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                if n > 0 { return ContextUsage(tokens: n, window: nil, model: msg["model"] as? String) }
            case .codex:
                guard line.contains("\"token_count\""),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let p = obj["payload"] as? [String: Any], let info = p["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let n = last["input_tokens"] as? Int else { continue }
                return ContextUsage(tokens: n, window: info["model_context_window"] as? Int)
            case .chatgpt:
                return nil
            }
        }
        return nil
    }

    /// Whether the last Claude turn in a transcript has ended (true), is still going (false), or can't be told (nil).
    /// A trailing user entry is a prompt or a tool result, so the agent still owes a reply.
    public static func claudeTurnEnded(transcript path: String) -> Bool? {
        for line in tailLines(path, bytes: 256 * 1024).reversed() {
            let isUser = line.contains("\"type\":\"user\"")
            let isAssistant = line.contains("\"type\":\"assistant\"")
            guard isUser || isAssistant else { continue }
            if isUser { return line.contains("[Request interrupted by user") }
            return line.contains("\"stop_reason\":\"end_turn\"") || line.contains("\"stop_reason\":\"stop_sequence\"")
        }
        return nil
    }

    /// Claude writes "[Request interrupted by user…]" as the last user entry when you press Esc.
    /// No hook fires for that, so without this the session would sit on RUNNING.
    public static func claudeWasInterrupted(transcript path: String) -> Bool {
        for line in tailLines(path).reversed() {
            let isUser = line.contains("\"type\":\"user\"")
            let isAssistant = line.contains("\"type\":\"assistant\"")
            guard isUser || isAssistant else { continue }
            return isUser && line.contains("[Request interrupted by user")
        }
        return false
    }
}
