import Darwin
import Foundation

public struct TokenCounts: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite + cacheRead }

    public static func += (a: inout TokenCounts, b: TokenCounts) {
        a.input += b.input
        a.output += b.output
        a.cacheWrite += b.cacheWrite
        a.cacheRead += b.cacheRead
    }
}

/// What one transcript file holds, reduced to what history needs: when things happened and what they cost.
public struct TranscriptRecord: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var sessionId: String
    /// The folder the session started in (Claude: from the transcript's project folder; Codex: session_meta).
    public var launchDir: String?
    public var model: String?
    /// Subagent transcripts share their parent's time; they add tokens, not hours.
    public var isSubagent = false
    /// Every event's time, in seconds since 1970, sorted and unique.
    public var times: [Int] = []
    public var usage: [Usage] = []

    public struct Usage: Codable, Equatable, Sendable {
        public var t: Int
        /// Hash of the API message id: Claude writes one line per content block, all with the same usage.
        public var key: Int64
        public var tokens: TokenCounts

        public init(t: Int, key: Int64, tokens: TokenCounts) {
            self.t = t
            self.key = key
            self.tokens = tokens
        }

        // Compact on disk: [t, key, in, out, cacheWrite, cacheRead].
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            t = try c.decode(Int.self)
            key = try c.decode(Int64.self)
            tokens = TokenCounts(input: try c.decode(Int.self), output: try c.decode(Int.self),
                                 cacheWrite: try c.decode(Int.self), cacheRead: try c.decode(Int.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(t); try c.encode(key)
            try c.encode(tokens.input); try c.encode(tokens.output)
            try c.encode(tokens.cacheWrite); try c.encode(tokens.cacheRead)
        }
    }
}

/// Long-term history from the agents' own transcripts (~/.claude/projects, ~/.codex/sessions), which go back
/// weeks, unlike AgentHUD's 24 h event log. Indexed incrementally into ~/.agenthud/history-index.json;
/// records outlive their transcripts, so history survives Claude's cleanup of old sessions.
public final class HistoryIndex: @unchecked Sendable {
    struct Entry: Codable {
        var mtime: Double
        var size: UInt64
        var record: TranscriptRecord?
    }

    struct Stored: Codable {
        var v: Int
        var files: [String: Entry]
    }

    static let version = 1
    private let claudeRoot: URL
    private let codexRoot: URL
    private let indexFile: URL
    private let lock = NSLock()
    private var files: [String: Entry] = [:]
    private var dirty = false

    public init(claudeProjects: URL = Paths.claudeProjects, codexSessions: URL = Paths.codexSessions,
                indexFile: URL = Paths.home.appendingPathComponent("history-index.json")) {
        claudeRoot = claudeProjects
        codexRoot = codexSessions
        self.indexFile = indexFile
        if let data = try? Data(contentsOf: indexFile),
           let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.v == Self.version {
            files = stored.files
        }
    }

    public var fileCount: Int { lock.withLock { files.count } }

    /// Re-reads new or changed transcripts. Slow the first time (it reads everything); cheap after.
    @discardableResult
    public func refresh() -> Bool {
        var changed = false
        for (url, agent) in transcripts() {
            let path = url.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if let e = lock.withLock({ files[path] }), e.mtime == mtime, e.size == size { continue }
            let record = agent == .claude ? Self.scanClaude(url) : Self.scanCodex(url)
            lock.withLock { files[path] = Entry(mtime: mtime, size: size, record: record) }
            changed = true
        }
        if changed {
            dirty = true
            save()
        }
        return changed
    }

    public func save() {
        guard dirty else { return }
        let snapshot = lock.withLock { Stored(v: Self.version, files: files) }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        Paths.ensureDir(indexFile.deletingLastPathComponent())
        if (try? data.write(to: indexFile, options: .atomic)) != nil { dirty = false }
    }

    private func transcripts() -> [(URL, AgentKind)] {
        var out: [(URL, AgentKind)] = []
        let fm = FileManager.default
        for (root, agent) in [(claudeRoot, AgentKind.claude), (codexRoot, .codex)] {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                if agent == .codex && !url.lastPathComponent.hasPrefix("rollout-") { continue }
                out.append((url, agent))
            }
        }
        return out
    }

    // MARK: - Scanning

    // Transcripts are large (tool output lives in them), so lines are searched for a few byte patterns
    // instead of being JSON-parsed. JSON escapes quotes inside strings, so `"key":` only matches real keys.

    static func scanClaude(_ url: URL) -> TranscriptRecord? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let components = url.pathComponents
        let isSub = components.contains("subagents")
        // …/projects/<encoded launch dir>/<id>.jsonl, or …/<encoded>/<session>/subagents/agent-x.jsonl
        let encoded = isSub ? components[components.count - 4] : components[components.count - 2]
        var r = TranscriptRecord(agent: .claude, sessionId: "", isSubagent: isSub)
        var cwd: String?
        var times: [Int] = []
        lines(data) { line in
            guard let t = Bytes.timestamp(line) else { return }
            times.append(t)
            if cwd == nil { cwd = Bytes.string(line, key: Bytes.cwd) }
            if r.sessionId.isEmpty { r.sessionId = Bytes.string(line, key: Bytes.sessionId) ?? "" }
            guard Bytes.find(line, Bytes.assistant) != nil, let u = Bytes.find(line, Bytes.usage) else { return }
            let usage = UnsafeRawBufferPointer(rebasing: line[u...])
            let tokens = TokenCounts(input: Bytes.int(usage, key: Bytes.inputTokens) ?? 0,
                                     output: Bytes.int(usage, key: Bytes.outputTokens) ?? 0,
                                     cacheWrite: Bytes.int(usage, key: Bytes.cacheCreation) ?? 0,
                                     cacheRead: Bytes.int(usage, key: Bytes.cacheRead) ?? 0)
            guard tokens.total > 0 else { return }
            let id = Bytes.string(line, key: Bytes.messageId).map { "msg_" + $0 } ?? "\(url.path)#\(t)"
            r.usage.append(.init(t: t, key: fnv(id), tokens: tokens))
            if let m = Bytes.string(line, key: Bytes.model), !m.hasPrefix("<") { r.model = m }
        }
        guard !times.isEmpty else { return nil }
        if r.sessionId.isEmpty { r.sessionId = url.deletingPathExtension().lastPathComponent }
        r.launchDir = cwd.map { ProjectRoot.launchDir(cwd: $0, encodedDir: encoded) }
        r.times = Array(Set(times)).sorted()
        return r
    }

    static func scanCodex(_ url: URL) -> TranscriptRecord? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var r = TranscriptRecord(agent: .codex, sessionId: "")
        var times: [Int] = []
        var last = TokenCounts()
        lines(data) { line in
            guard let t = Bytes.timestamp(line) else { return }
            times.append(t)
            if r.sessionId.isEmpty, Bytes.find(line, Bytes.sessionMeta) != nil {
                r.sessionId = Bytes.string(line, key: Bytes.id) ?? ""
                r.launchDir = Bytes.string(line, key: Bytes.cwd)
                if Bytes.find(line, Bytes.subagentSource) != nil { r.isSubagent = true }
            }
            if r.model == nil, Bytes.find(line, Bytes.turnContext) != nil { r.model = Bytes.string(line, key: Bytes.model) }
            // token_count carries running totals; history wants what each one added.
            guard Bytes.find(line, Bytes.tokenCount) != nil, let u = Bytes.find(line, Bytes.totalUsage) else { return }
            let usage = UnsafeRawBufferPointer(rebasing: line[u...])
            let input = Bytes.int(usage, key: Bytes.inputTokens) ?? 0
            let cached = Bytes.int(usage, key: Bytes.cachedInput) ?? 0
            let now = TokenCounts(input: max(0, input - cached), output: Bytes.int(usage, key: Bytes.outputTokens) ?? 0,
                                  cacheRead: cached)
            let delta = TokenCounts(input: max(0, now.input - last.input), output: max(0, now.output - last.output),
                                    cacheRead: max(0, now.cacheRead - last.cacheRead))
            last = now
            if delta.total > 0 { r.usage.append(.init(t: t, key: 0, tokens: delta)) }
        }
        guard !times.isEmpty else { return nil }
        if r.sessionId.isEmpty { r.sessionId = url.deletingPathExtension().lastPathComponent }
        r.times = Array(Set(times)).sorted()
        return r
    }

    private static func lines(_ data: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            let n = raw.count
            while start < n {
                let end: Int
                if let p = memchr(base + start, 0x0A, n - start) { end = base.distance(to: p) } else { end = n }
                if end > start { body(UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
                start = end + 1
            }
        }
    }

    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func fnv(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return Int64(bitPattern: h)
    }

    // MARK: - Reports

    public func report(from start: Date, to end: Date, idleGap: TimeInterval, calendar: Calendar = .current) -> HistoryReport {
        let records = lock.withLock { files.values.compactMap(\.record) }
        return HistoryReport.build(records: records, from: start, to: end, idleGap: idleGap, calendar: calendar)
    }
}

/// Byte-pattern helpers for transcript lines.
enum Bytes {
    static let timestampKey = Array(#""timestamp":""#.utf8)
    static let cwd = Array(#""cwd":""#.utf8)
    static let sessionId = Array(#""sessionId":""#.utf8)
    static let id = Array(#""id":""#.utf8)
    static let messageId = Array(#""id":"msg_"#.utf8)
    static let model = Array(#""model":""#.utf8)
    static let assistant = Array(#""type":"assistant""#.utf8)
    static let usage = Array(#""usage":{"#.utf8)
    static let inputTokens = Array(#""input_tokens":"#.utf8)
    static let outputTokens = Array(#""output_tokens":"#.utf8)
    static let cacheCreation = Array(#""cache_creation_input_tokens":"#.utf8)
    static let cacheRead = Array(#""cache_read_input_tokens":"#.utf8)
    static let cachedInput = Array(#""cached_input_tokens":"#.utf8)
    static let sessionMeta = Array(#""type":"session_meta""#.utf8)
    static let subagentSource = Array(#""subagent""#.utf8)
    static let turnContext = Array(#""type":"turn_context""#.utf8)
    static let tokenCount = Array(#""type":"token_count""#.utf8)
    static let totalUsage = Array(#""total_token_usage":{"#.utf8)

    static func find(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Int? {
        guard let base = hay.baseAddress, hay.count >= needle.count else { return nil }
        return needle.withUnsafeBytes { n in
            memmem(base, hay.count, n.baseAddress, n.count).map { base.distance(to: UnsafeRawPointer($0)) }
        }
    }

    /// The string value after `key` (which ends with the opening quote), up to the closing quote.
    static func string(_ line: UnsafeRawBufferPointer, key: [UInt8]) -> String? {
        guard let k = find(line, key) else { return nil }
        let start = k + key.count
        var i = start
        while i < line.count, line[i] != 0x22 {
            if line[i] == 0x5C { i += 1 } // skip escaped character
            i += 1
        }
        guard i > start, i <= line.count else { return nil }
        let raw = String(decoding: UnsafeRawBufferPointer(rebasing: line[start..<i]), as: UTF8.self)
        return raw.contains("\\") ? (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? raw : raw
    }

    static func int(_ buf: UnsafeRawBufferPointer, key: [UInt8]) -> Int? {
        guard let k = find(buf, key) else { return nil }
        var i = k + key.count
        while i < buf.count, buf[i] == 0x20 { i += 1 }
        var v = 0
        var any = false
        while i < buf.count, buf[i] >= 0x30, buf[i] <= 0x39 {
            v = v * 10 + Int(buf[i] - 0x30)
            any = true
            i += 1
        }
        return any ? v : nil
    }

    /// `"timestamp":"2026-09-25T12:08:59.397Z"` → seconds since 1970 (UTC).
    static func timestamp(_ line: UnsafeRawBufferPointer) -> Int? {
        guard let k = find(line, timestampKey) else { return nil }
        let s = k + timestampKey.count
        guard s + 19 <= line.count else { return nil }
        func num(_ a: Int, _ len: Int) -> Int32? {
            var v: Int32 = 0
            for i in 0..<len {
                let c = line[s + a + i]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int32(c - 0x30)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              let sec = num(17, 2) else { return nil }
        var tm = Darwin.tm()
        tm.tm_year = y - 1900
        tm.tm_mon = mo - 1
        tm.tm_mday = d
        tm.tm_hour = h
        tm.tm_min = mi
        tm.tm_sec = sec
        return Int(timegm(&tm))
    }
}

/// History over a date range: active time (from event timestamps), tokens, sessions, by project and day.
///
/// Active time: consecutive events in a project up to `idleGap` apart count as time spent; a longer silence
/// doesn't. Events from every session in a project are merged first, so parallel sessions count once.
public struct HistoryReport: Sendable {
    public struct Project: Identifiable, Sendable {
        public var id: String { root }
        public var root: String
        public var name: String
        public var active: TimeInterval
        public var sessions: Int
        public var tokens: TokenCounts
        public var days: Int
        public var first: Date
        public var last: Date
    }

    public struct Day: Identifiable, Sendable {
        public var id: Date { day }
        public var day: Date
        public var active: TimeInterval
        public var tokens: TokenCounts
        /// Project name → active time that day, largest first.
        public var projects: [(name: String, active: TimeInterval)]
    }

    public struct SessionRow: Identifiable, Sendable {
        public var id: String
        public var agent: AgentKind
        public var sessionId: String
        public var project: String
        public var root: String
        public var start: Date
        public var end: Date
        public var active: TimeInterval
        public var tokens: TokenCounts
        public var model: String?
    }

    public var active: TimeInterval
    public var tokens: TokenCounts
    public var projects: [Project]
    public var days: [Day]
    public var sessions: [SessionRow]

    static func build(records: [TranscriptRecord], from requestedStart: Date, to end: Date, idleGap: TimeInterval,
                      calendar: Calendar) -> HistoryReport {
        // "All time" starts at the oldest record, not 1970.
        let earliest = records.compactMap { $0.times.first }.min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let start = max(requestedStart, earliest.map { calendar.startOfDay(for: $0) } ?? end)
        let lo = Int(start.timeIntervalSince1970), hi = Int(end.timeIntervalSince1970)
        let names = displayNames(Set(records.compactMap { $0.launchDir.map(ProjectRoot.root(of:)) }))
        let gap = Int(idleGap)
        var projectTimes: [String: [Int]] = [:]
        var sessionTimes: [String: [Int]] = [:]
        var sessionInfo: [String: (TranscriptRecord, String)] = [:]
        var sessionTokens: [String: TokenCounts] = [:]
        var projectTokens: [String: TokenCounts] = [:]
        var projectSessions: [String: Set<String>] = [:]
        var dayTokens: [Date: TokenCounts] = [:]
        var total = TokenCounts()
        var seen = Set<Int64>()
        var allTimes: [Int] = []

        for r in records {
            let root = r.launchDir.map(ProjectRoot.root(of:)) ?? "(unknown)"
            let inRange = r.times.filter { $0 >= lo && $0 <= hi }
            let usage = r.usage.filter { $0.t >= lo && $0.t <= hi }
            guard !inRange.isEmpty || !usage.isEmpty else { continue }
            let key = "\(r.agent.rawValue):\(r.sessionId)"
            projectTimes[root, default: []] += inRange
            sessionTimes[key, default: []] += inRange
            allTimes += inRange
            if sessionInfo[key] == nil || !r.isSubagent { sessionInfo[key] = (r, root) }
            projectSessions[root, default: []].insert(key)
            for u in usage {
                if u.key != 0 { guard seen.insert(u.key).inserted else { continue } }
                sessionTokens[key, default: TokenCounts()] += u.tokens
                projectTokens[root, default: TokenCounts()] += u.tokens
                dayTokens[calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(u.t))), default: TokenCounts()] += u.tokens
                total += u.tokens
            }
        }

        func tidy(_ t: [Int]) -> [Int] { Array(Set(t)).sorted() }
        /// Sums gaps ≤ idleGap, attributing each to the day it started on.
        func active(_ times: [Int]) -> (total: TimeInterval, byDay: [Date: TimeInterval]) {
            var sum = 0
            var byDay: [Date: TimeInterval] = [:]
            for (a, b) in zip(times, times.dropFirst()) where b - a <= gap {
                sum += b - a
                byDay[calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(a))), default: 0] += TimeInterval(b - a)
            }
            return (TimeInterval(sum), byDay)
        }

        var projects: [Project] = []
        var dayProjects: [Date: [(String, TimeInterval)]] = [:]
        for (root, times) in projectTimes {
            let t = tidy(times)
            let a = active(t)
            let name = names[root] ?? root
            for (day, secs) in a.byDay { dayProjects[day, default: []].append((name, secs)) }
            projects.append(Project(root: root, name: name, active: a.total, sessions: projectSessions[root]?.count ?? 0,
                                    tokens: projectTokens[root] ?? TokenCounts(), days: a.byDay.count,
                                    first: Date(timeIntervalSince1970: TimeInterval(t.first ?? lo)),
                                    last: Date(timeIntervalSince1970: TimeInterval(t.last ?? lo))))
        }
        projects.sort { $0.active != $1.active ? $0.active > $1.active : $0.tokens.total > $1.tokens.total }

        let overall = active(tidy(allTimes))
        var days: [Day] = []
        var day = calendar.startOfDay(for: start)
        while day <= end {
            days.append(Day(day: day, active: overall.byDay[day] ?? 0, tokens: dayTokens[day] ?? TokenCounts(),
                            projects: (dayProjects[day] ?? []).sorted { $0.1 > $1.1 }.map { (name: $0.0, active: $0.1) }))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let sessions: [SessionRow] = sessionTimes.compactMap { key, times in
            guard let (r, root) = sessionInfo[key] else { return nil }
            let t = tidy(times)
            guard let first = t.first, let last = t.last else { return nil }
            return SessionRow(id: key, agent: r.agent, sessionId: r.sessionId,
                              project: names[root] ?? root, root: root,
                              start: Date(timeIntervalSince1970: TimeInterval(first)),
                              end: Date(timeIntervalSince1970: TimeInterval(last)), active: active(t).total,
                              tokens: sessionTokens[key] ?? TokenCounts(), model: r.model)
        }.sorted { $0.start > $1.start }

        return HistoryReport(active: overall.total, tokens: total, projects: projects, days: days, sessions: sessions)
    }

    /// Folder names, with the parent added where two projects share one ("Norco/bay-electric").
    static func displayNames(_ roots: Set<String>) -> [String: String] {
        let base = Dictionary(grouping: roots) { ($0 as NSString).lastPathComponent }
        var out: [String: String] = ["(unknown)": "(unknown)"]
        for (name, group) in base {
            for root in group {
                let parent = ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent
                out[root] = group.count > 1 && !parent.isEmpty ? "\(parent)/\(name)" : name
            }
        }
        return out
    }

    /// One row per session: for checking project time against a timesheet.
    public func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out = "project,agent,session_id,start,end,active_minutes,input_tokens,output_tokens,cache_write_tokens,cache_read_tokens,model\n"
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let fields = [s.project, s.agent.rawValue, s.sessionId, iso.string(from: s.start), iso.string(from: s.end),
                          String(format: "%.1f", s.active / 60), "\(s.tokens.input)", "\(s.tokens.output)",
                          "\(s.tokens.cacheWrite)", "\(s.tokens.cacheRead)", s.model ?? ""]
            out += fields.map { f in f.contains(",") || f.contains("\"") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
                .joined(separator: ",") + "\n"
        }
        return out
    }
}
