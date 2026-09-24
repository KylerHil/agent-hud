import Foundation

/// Follows ~/.agentwatch/events.jsonl: replays recent history once, then delivers new lines as they land.
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
