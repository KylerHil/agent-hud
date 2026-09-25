import XCTest
@testable import AgentHUDCore

final class HistoryIndexTests: XCTestCase {
    var base: URL!
    var claude: URL!
    var codex: URL!
    let t0 = 1_790_000_000 // a fixed instant; tests use UTC days

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        claude = base.appendingPathComponent("projects")
        codex = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
    }

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func iso(_ t: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    func claudeLine(_ t: Int, cwd: String, sid: String, type: String = "user", msg: String? = nil, out: Int = 0) -> String {
        var s = #"{"type":"\#(type)","timestamp":"\#(iso(t))","cwd":"\#(cwd)","sessionId":"\#(sid)""#
        if let msg {
            s += #","message":{"id":"\#(msg)","model":"claude-test","content":[{"type":"text","text":"say \"input_tokens\":999"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":\#(out)}}"#
        }
        return s + "}"
    }

    func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func index() -> HistoryIndex {
        HistoryIndex(claudeProjects: claude, codexSessions: codex, indexFile: base.appendingPathComponent("index.json"))
    }

    func testClaudeScanDedupesMessagesAndCountsActiveTime() throws {
        let repo = base.appendingPathComponent("repo").path
        let dir = claude.appendingPathComponent(ProjectRoot.encode(repo))
        try write([
            claudeLine(t0, cwd: repo, sid: "a"),
            // One API message written as three lines (one per content block): counted once.
            claudeLine(t0 + 60, cwd: repo + "/sub", sid: "a", type: "assistant", msg: "msg_1", out: 7),
            claudeLine(t0 + 61, cwd: repo + "/sub", sid: "a", type: "assistant", msg: "msg_1", out: 7),
            claudeLine(t0 + 62, cwd: repo + "/sub", sid: "a", type: "assistant", msg: "msg_1", out: 7),
            claudeLine(t0 + 3600, cwd: repo, sid: "a"),          // an hour of silence: not active
            claudeLine(t0 + 3900, cwd: repo, sid: "a"),          // 5 min later: active
        ], to: dir.appendingPathComponent("a.jsonl"))
        let idx = index()
        XCTAssertTrue(idx.refresh())
        XCTAssertFalse(idx.refresh(), "unchanged files aren't re-read")
        let r = idx.report(from: Date(timeIntervalSince1970: TimeInterval(t0 - 10)),
                           to: Date(timeIntervalSince1970: TimeInterval(t0 + 5000)), idleGap: 600, calendar: utc)
        XCTAssertEqual(r.active, 62 + 300)
        XCTAssertEqual(r.tokens, TokenCounts(input: 10, output: 7, cacheWrite: 5, cacheRead: 100))
        XCTAssertEqual(r.projects.map(\.name), ["repo"])
        XCTAssertEqual(r.sessions.first?.model, "claude-test")
        XCTAssertEqual(r.sessions.count, 1)
        // The index persists: a fresh instance has the same data without the files.
        try FileManager.default.removeItem(at: dir)
        let again = index().report(from: Date(timeIntervalSince1970: TimeInterval(t0 - 10)),
                                   to: Date(timeIntervalSince1970: TimeInterval(t0 + 5000)), idleGap: 600, calendar: utc)
        XCTAssertEqual(again.active, r.active)
    }

    func testParallelSessionsInOneProjectCountOnce() throws {
        let repo = base.appendingPathComponent("repo").path
        let dir = claude.appendingPathComponent(ProjectRoot.encode(repo))
        try write([0, 120, 240].map { claudeLine(t0 + $0, cwd: repo, sid: "a") }, to: dir.appendingPathComponent("a.jsonl"))
        try write([60, 180].map { claudeLine(t0 + $0, cwd: repo, sid: "b") }, to: dir.appendingPathComponent("b.jsonl"))
        let idx = index()
        idx.refresh()
        let r = idx.report(from: Date(timeIntervalSince1970: TimeInterval(t0)),
                           to: Date(timeIntervalSince1970: TimeInterval(t0 + 1000)), idleGap: 600, calendar: utc)
        XCTAssertEqual(r.projects.first?.active, 240)
        XCTAssertEqual(r.projects.first?.sessions, 2)
        XCTAssertEqual(r.sessions.map(\.active).sorted(), [120, 240])
    }

    func testCodexTokenDeltas() throws {
        let lines = [
            #"{"timestamp":"\#(iso(t0))","type":"session_meta","payload":{"id":"cx1","cwd":"/w/app","originator":"codex_cli_rs"}}"#,
            #"{"timestamp":"\#(iso(t0 + 10))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50},"last_token_usage":{"input_tokens":1000}}}}"#,
            #"{"timestamp":"\#(iso(t0 + 20))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":900,"output_tokens":80},"last_token_usage":{"input_tokens":500}}}}"#,
        ]
        try write(lines, to: codex.appendingPathComponent("2026/09/25/rollout-x-cx1.jsonl"))
        let idx = index()
        idx.refresh()
        let r = idx.report(from: Date(timeIntervalSince1970: TimeInterval(t0)),
                           to: Date(timeIntervalSince1970: TimeInterval(t0 + 100)), idleGap: 600, calendar: utc)
        XCTAssertEqual(r.tokens, TokenCounts(input: 600, output: 80, cacheRead: 900))
        XCTAssertEqual(r.sessions.first?.sessionId, "cx1")
        XCTAssertEqual(r.projects.first?.name, "app")
        XCTAssertTrue(r.csv().contains("app,codex,cx1,"))
    }

    func testSameNamedProjectsAreTellable() {
        let names = HistoryReport.displayNames(["/a/Norco/bay-electric", "/b/bay-electric", "/c/solo"])
        XCTAssertEqual(names["/a/Norco/bay-electric"], "Norco/bay-electric")
        XCTAssertEqual(names["/b/bay-electric"], "b/bay-electric")
        XCTAssertEqual(names["/c/solo"], "solo")
    }

    func testTimestampParsing() {
        let line = Array(#"{"timestamp":"2026-09-25T12:08:59.397Z"}"#.utf8)
        let t = line.withUnsafeBytes { Bytes.timestamp($0) }
        XCTAssertEqual(t, Int(ISO8601DateFormatter().date(from: "2026-09-25T12:08:59Z")!.timeIntervalSince1970))
    }
}
