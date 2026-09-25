import XCTest
@testable import AgentHUDCore

/// Timeline, counters, wait accounting, and the Today summary built from transitions.
final class HistoryTests: XCTestCase {
    var store: SessionStore!
    var log: ActivityLog!
    var t: Double = 1000

    override func setUp() { store = SessionStore(); log = ActivityLog(); t = 1000 }

    func ev(_ name: String, after: Double = 1, sid: String = "s1", cwd: String = "/work/proj",
            _ configure: (inout AgentEvent) -> Void = { _ in }) {
        t += after
        var e = AgentEvent(ts: t, agent: .claude, event: name, sessionId: sid)
        e.cwd = cwd
        e.origin = "hook"
        configure(&e)
        if let tr = store.apply(e), let s = store.sessions[tr.sessionID] { log.record(tr, session: s) }
    }

    var session: Session { store.sessions["claude:s1"]! }

    func testTimelineCountersAndFiles() {
        ev("UserPromptSubmit") { $0.prompt = "fix auth" }
        ev("PreToolUse") { $0.toolName = "Read"; $0.detail = "/work/proj/a.swift" }
        ev("PreToolUse") { $0.toolName = "Edit"; $0.detail = "/work/proj/a.swift" }
        ev("PreToolUse") { $0.toolName = "Edit"; $0.detail = "/work/proj/a.swift" }
        ev("PreToolUse") { $0.toolName = "Write"; $0.detail = "/work/proj/b.swift" }
        ev("PostToolUseFailure") { $0.toolName = "Bash"; $0.message = "exit 1" }
        ev("Stop", after: 30) { $0.message = "Done." }
        XCTAssertEqual(session.toolCalls, 4)
        XCTAssertEqual(session.filesChanged, ["/work/proj/a.swift", "/work/proj/b.swift"])
        XCTAssertEqual(session.timeline.map(\.kind), ["Prompt", "Read", "Edit", "Edit", "Write", "Bash", "Finished"])
        XCTAssertEqual(session.timeline[5].tone, .error)
        XCTAssertEqual(session.lastTurnDuration, 35)
    }

    func testTimelineIsCapped() {
        ev("UserPromptSubmit")
        for i in 0..<(Session.timelineLimit + 10) { ev("PreToolUse") { $0.toolName = "Read"; $0.detail = "f\(i)" } }
        XCTAssertEqual(session.timeline.count, Session.timelineLimit)
        XCTAssertEqual(session.timeline.last?.detail, "f\(Session.timelineLimit + 9)")
    }

    func testWaitAccounting() {
        ev("UserPromptSubmit")
        ev("PermissionRequest") { $0.toolName = "Bash"; $0.toolUseId = "t1" }
        ev("PostToolUse", after: 20) { $0.toolUseId = "t1" }
        ev("PermissionRequest") { $0.toolName = "Bash"; $0.toolUseId = "t2" }
        ev("PostToolUse", after: 5) { $0.toolUseId = "t2" }
        XCTAssertEqual(session.waits, 2)
        XCTAssertEqual(session.waitedTotal, 25)
    }

    func testTitleUpdateIsNotActivity() {
        ev("UserPromptSubmit")
        let before = session.lastEventAt
        ev("SessionTitle", after: 100) { $0.title = "Fix the build" }
        XCTAssertEqual(session.title, "Fix the build")
        XCTAssertEqual(session.lastEventAt, before)
        XCTAssertEqual(session.lastActivityEvent, "UserPromptSubmit")
    }

    func testSummary() {
        let start = Date(timeIntervalSince1970: t)
        ev("UserPromptSubmit")                                                 // running from +1
        ev("PermissionRequest", after: 99) { $0.toolName = "Bash"; $0.toolUseId = "p" } // wait from +100
        ev("PostToolUse", after: 30) { $0.toolUseId = "p" }                    // answered at +130
        ev("Stop", after: 70)                                                  // idle at +200
        ev("UserPromptSubmit", after: 1, sid: "s2", cwd: "/work/other")        // other project, still running
        let now = Date(timeIntervalSince1970: t + 50)
        let sum = log.summary(from: start, to: now)
        XCTAssertEqual(sum.lanes.count, 2)
        XCTAssertEqual(sum.waits.map(\.duration), [30])
        XCTAssertEqual(sum.waits.first?.reason, "Permission: Bash")
        XCTAssertEqual(sum.medianWait, 30)
        let proj = sum.projects.first { $0.project == "proj" }!
        XCTAssertEqual(proj.working, 99 + 70)
        XCTAssertEqual(proj.waiting, 30)
        XCTAssertEqual(sum.projects.first { $0.project == "other" }?.working, 50) // open segment runs to now
        // A session that only ever sat idle gets no lane.
        ev("SessionStart", sid: "s3", cwd: "/work/idle")
        XCTAssertNil(log.summary(from: start, to: Date(timeIntervalSince1970: t)).lanes.first { $0.project == "idle" })
        // Clipping: a window starting mid-wait counts only the part inside it.
        let late = log.summary(from: start.addingTimeInterval(110), to: now)
        XCTAssertEqual(late.projects.first { $0.project == "proj" }?.waiting, 20)
    }

    func testResumeCommand() {
        ev("UserPromptSubmit", cwd: "/work/my proj")
        XCTAssertEqual(session.resumeCommand, "cd '/work/my proj' && claude --resume s1")
    }
}

final class DesktopSourceTests: XCTestCase {
    func testHostKinds() {
        XCTAssertEqual(ProcTools.hostKind(app: "/Applications/Claude.app", termProgram: nil), "claude-desktop")
        XCTAssertEqual(ProcTools.hostKind(app: "/Applications/ChatGPT.app", termProgram: nil), "chatgpt")
        XCTAssertEqual(RolloutScanner.host(originator: "codex_vscode"), "vscode")
        XCTAssertEqual(RolloutScanner.host(originator: "Codex Desktop"), "chatgpt")
        XCTAssertNil(RolloutScanner.host(originator: "codex_cli_rs"))
    }

    func testDesktopBundledClaudeIsNotAHost() {
        let inner = "/Users/x/Library/Application Support/Claude/claude-code/2.1.281/claude.app/Contents/MacOS/claude"
        XCTAssertEqual(ProcTools.outerAppBundle(of: inner),
                       "/Users/x/Library/Application Support/Claude/claude-code/2.1.281/claude.app")
    }

    func testDesktopScannerParseAndReconcile() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = base.appendingPathComponent("sessions/acct/org")
        let projects = base.appendingPathComponent("projects")
        let projDir = projects.appendingPathComponent("-w-web-app")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        let now = Date()
        let meta = #"{"cliSessionId":"cli-1","cwd":"/w/web-app","title":"Fix the build","lastActivityAt":\#(now.timeIntervalSince1970 * 1000),"isArchived":false}"#
        try meta.write(to: sessions.appendingPathComponent("local_1.json"), atomically: true, encoding: .utf8)
        try #"{"cliSessionId":"old","isArchived":true}"#.write(to: sessions.appendingPathComponent("local_2.json"),
                                                                 atomically: true, encoding: .utf8)
        let transcript = projDir.appendingPathComponent("cli-1.jsonl")
        try (#"{"type":"user","message":{"role":"user","content":"go"}}"# + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let scanner = ClaudeDesktopScanner(root: base.appendingPathComponent("sessions"), projects: projects)
        let found = scanner.recent(now: now)
        XCTAssertEqual(found.map(\.sessionId), ["cli-1"])
        XCTAssertEqual(found.first?.transcriptPath, transcript.path)
        XCTAssertEqual(found.first?.title, "Fix the build")

        let store = SessionStore()
        var evs = ClaudeDesktopScanner.reconcile(store: store, sessions: found, appRunning: true, now: now)
        XCTAssertEqual(evs.map(\.event), ["RolloutRunning"])
        XCTAssertEqual(evs.first?.hostKind, "claude-desktop")
        evs.forEach { store.apply($0) }
        let s = store.sessions["claude:cli-1"]!
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(s.title, "Fix the build")
        XCTAssertEqual(s.hostLabel, "Claude app")
        XCTAssertEqual(ClaudeDesktopScanner.reconcile(store: store, sessions: found, appRunning: true, now: now), [])

        // The assistant ends its turn.
        let end = #"{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":5,"cache_read_input_tokens":1000}}}"#
        let h = try FileHandle(forWritingTo: transcript); try h.seekToEnd(); try h.write(contentsOf: Data((end + "\n").utf8)); try h.close()
        evs = ClaudeDesktopScanner.reconcile(store: store, sessions: found, appRunning: true, now: now)
        XCTAssertEqual(evs.map(\.event), ["RolloutIdle"])
        evs.forEach { store.apply($0) }
        XCTAssertEqual(TranscriptProbe.contextUsage(transcript.path, agent: .claude)?.tokens, 1005)

        // Hooks take over: only the title is kept in sync.
        var hook = AgentEvent(ts: now.timeIntervalSince1970, agent: .claude, event: "UserPromptSubmit", sessionId: "cli-1")
        hook.origin = "hook"
        store.apply(hook)
        store.update("claude:cli-1") { $0.title = nil }
        XCTAssertEqual(ClaudeDesktopScanner.reconcile(store: store, sessions: found, appRunning: true, now: now)
            .map(\.event), ["SessionTitle"])

        // Claude.app quits: sessions it alone reported end.
        let store2 = SessionStore()
        ClaudeDesktopScanner.reconcile(store: store2, sessions: found, appRunning: true, now: now).forEach { store2.apply($0) }
        XCTAssertEqual(ClaudeDesktopScanner.reconcile(store: store2, sessions: found, appRunning: false, now: now)
            .map(\.event), ["ProcessExited"])
    }

    func testShortLivedHelperProcessesGetNoRow() {
        let store = SessionStore()
        let now = Date()
        func proc(_ pid: Int32, age: TimeInterval) -> ProcessScanner.AgentProcess {
            .init(pid: pid, agent: .claude, cwd: "/w/p", tty: nil, hostApp: nil, hostKind: "vscode",
                  started: now.addingTimeInterval(-age))
        }
        let evs = ProcessScanner.reconcile(store: store, processes: [proc(1, age: 5), proc(2, age: 90)], now: now)
        XCTAssertEqual(evs.map(\.sessionId), ["pid-2"])
        evs.forEach { store.apply($0) }
        // When the placeholder's process exits, the row goes away instead of lingering as "ended".
        let exit = ProcessScanner.reconcile(store: store, processes: [], now: now)
        XCTAssertEqual(exit.map(\.event), ["ProcessExited"])
        exit.forEach { store.apply($0) }
        XCTAssertNil(store.sessions["claude:pid-2"])
    }

    func testProcessStartTime() throws {
        let started = try XCTUnwrap(ProcTools.entry(getpid())?.started)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3600)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0)
    }

    func testCodexContextUsage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":200000,"last_token_usage":{"input_tokens":50000}}}}"#
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let u = TranscriptProbe.contextUsage(file.path, agent: .codex)
        XCTAssertEqual(u?.tokens, 50000)
        XCTAssertEqual(u?.fraction, 0.25)
    }
}

final class ProjectRootTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/apps/mobile"), withIntermediateDirectories: true)
    }

    func testRootStaysPutWhenTheAgentCds() {
        let repo = base.appendingPathComponent("repo").path
        let store = SessionStore()
        var e = AgentEvent(ts: 1, agent: .claude, event: "UserPromptSubmit", sessionId: "s")
        e.cwd = repo
        e.transcriptPath = "/x/projects/\(ProjectRoot.encode(repo))/s.jsonl"
        e.origin = "hook"
        store.apply(e)
        var cd = AgentEvent(ts: 2, agent: .claude, event: "PreToolUse", sessionId: "s")
        cd.cwd = repo + "/apps/mobile"
        cd.origin = "hook"
        store.apply(cd)
        let s = store.sessions["claude:s"]!
        XCTAssertEqual(s.projectName, "repo")
        XCTAssertEqual(s.subpath, "apps/mobile")
        XCTAssertEqual(s.resumeCommand, "cd \(repo) && claude --resume s")
    }

    func testLaunchDirFromTranscriptWhenFirstSeenInSubfolder() {
        let repo = base.appendingPathComponent("repo").path
        let sub = repo + "/apps/mobile"
        XCTAssertEqual(ProjectRoot.launchDir(cwd: sub, transcriptPath: "/p/\(ProjectRoot.encode(repo))/id.jsonl"), repo)
        // Started inside the repo's subfolder: the name is still the repo.
        XCTAssertEqual(ProjectRoot.root(of: sub), repo)
        XCTAssertEqual(ProjectRoot.root(of: base.path), base.path)
    }

    func testEditorWindowMatch() {
        let storage = #"""
        {"windowsState":{"lastActiveWindow":{"folder":"file:///w/Norco/Norco"},
         "openedWindows":[{"folder":"file:///w/agent-watch"},{"folder":"file:///w/Norco"},
                          {"workspaceIdentifier":{"id":"x","configPath":"file:///w/all.code-workspace"}}]}}
        """#
        let data = Data(storage.utf8)
        let folders: (URL) -> [String] = { _ in ["/w/other"] }
        XCTAssertEqual(EditorWindows.target(storage: data, containing: "/w/Norco/Norco/norco-mobile",
                                            workspaceFolders: folders)?.path, "/w/Norco/Norco")
        XCTAssertEqual(EditorWindows.target(storage: data, containing: "/w/other/pkg", workspaceFolders: folders)?.path,
                       "/w/all.code-workspace")
        XCTAssertNil(EditorWindows.target(storage: data, containing: "/w/elsewhere", workspaceFolders: folders))
    }

    func testWorkspaceFoldersParseCommentsAndRelativePaths() throws {
        let file = base.appendingPathComponent("x.code-workspace")
        try """
        {
          // comment
          "folders": [ { "path": "repo" }, { "path": "/abs/elsewhere" }, ],
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(EditorWindows.workspaceFolders(of: file), [base.appendingPathComponent("repo").path, "/abs/elsewhere"])
    }
}

final class MigrationTests: XCTestCase {
    func testLegacyHomeMovesAndOldFilesWinOverAFreshFolder() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = home.appendingPathComponent(".agentwatch"), new = home.appendingPathComponent(".agenthud")
        try fm.createDirectory(at: old.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "real log\n".write(to: old.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try "old".write(to: old.appendingPathComponent("bin/agentwatch-report"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: new.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "new".write(to: new.appendingPathComponent("bin/agenthud-report"), atomically: true, encoding: .utf8)
        try "".write(to: new.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        setenv("AGENTHUD_USER_HOME", home.path, 1)
        defer { unsetenv("AGENTHUD_USER_HOME") }
        XCTAssertTrue(Paths.migrateLegacyHome())
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("events.jsonl"), encoding: .utf8), "real log\n")
        // Folders merge: the new reporter survives next to the old one.
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("bin/agenthud-report").path))
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("bin/agentwatch-report").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: old.path), new.path)
        // Old hooks write through the symlink into the new folder.
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("events.jsonl").path))
        XCTAssertFalse(Paths.migrateLegacyHome(), "runs once")
    }
}
