import AgentHUDCore
import Foundation
import Observation

/// The panel's filter tabs.
enum PanelFilter: String, CaseIterable {
    case all, needs, working, idle

    var title: String {
        switch self {
        case .all: "All"
        case .needs: "You"
        case .working: "Busy"
        case .idle: "Idle"
        }
    }

    func includes(_ state: SessionState) -> Bool {
        switch self {
        case .all: true
        case .needs: state == .needsInput
        case .working: state == .running || state == .stale
        case .idle: state == .idle || state == .unknown || state == .ended
        }
    }
}

/// What the panel is showing. Everything lives in the one panel; nothing opens a window of its own.
enum PanelMode: Equatable {
    case list, dashboard, settings

    /// The dashboard and settings are roomier than the list, so the panel grows for them.
    var isLarge: Bool { self != .list }
}

enum SettingsTab: Hashable {
    case general, sources, notifications, hooks
}

/// Glue between the event log, the state machine, and the UI.
@MainActor
@Observable
final class AppModel {
    let store = SessionStore()
    let activity = ActivityLog()
    let settings: AppSettings
    private(set) var now = Date()

    /// Session shown in the panel's detail view, if any.
    var detailID: String?
    var mode: PanelMode = .list
    var settingsTab: SettingsTab = .general
    /// Search over the list (⌃⌥Space or the magnifying glass): typing filters, ↑↓ selects, Return jumps.
    var searching = false
    var query = ""
    var searchSelection = 0
    /// True while Settings records a new shortcut; global hotkeys pause so the keys reach the recorder.
    var recordingShortcut = false
    /// Hooks still pointing at AgentWatch's reporter, from before the rename.
    private(set) var legacyHooks = false
    let history: HistoryModel
    let updater: Updater
    /// Sessions whose notifications are muted until the app quits.
    private(set) var muted: Set<String> = []
    private(set) var context: [String: TranscriptProbe.ContextUsage] = [:]

    /// Called for live (not replayed) state changes. Wired to notifications.
    @ObservationIgnored var onTransition: ((Transition, Session) -> Void)?
    /// Called every tick, for re-reminders.
    @ObservationIgnored var onTick: (() -> Void)?
    /// What the panel's header buttons open.
    @ObservationIgnored var actions = PanelActions()

    @ObservationIgnored private var tailer: EventTailer?
    @ObservationIgnored private var timer: Timer?
    /// Last write to each session's transcript; a transcript still growing means the agent is still working.
    private var lastOutput: [String: Date] = [:]
    @ObservationIgnored private var lastProbe: [String: Date] = [:]
    @ObservationIgnored private let rollouts = RolloutScanner()
    @ObservationIgnored private let desktop = ClaudeDesktopScanner()
    @ObservationIgnored private let chats = ChatWatcher()
    @ObservationIgnored private var tickCount = 0

    init(settings: AppSettings) {
        self.settings = settings
        history = HistoryModel(settings: settings)
        updater = Updater(settings: settings)
    }

    func openDashboard() { open(.dashboard) }

    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        open(.settings)
    }

    func open(_ m: PanelMode) {
        detailID = nil
        searching = false
        settings.collapsed = false
        mode = m
    }

    func beginSearch() {
        detailID = nil
        mode = .list
        settings.collapsed = false
        query = ""
        searchSelection = 0
        searching = true
    }

    func endSearch() {
        searching = false
        query = ""
    }

    /// Live sessions matching the search, in panel order.
    var searchResults: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = menuBarSessions
        guard !q.isEmpty else { return all }
        return all.filter { s in
            [s.projectName, s.subpath, s.title, s.hostLabel, s.agent.displayName, s.cwd].compactMap { $0?.lowercased() }
                .contains { $0.contains(q) }
        }
    }

    func refreshLegacyHooks() {
        let legacy = HookInstaller.Target.allCases.contains { HookInstaller.hasLegacyHooks($0) }
        if legacy != legacyHooks { legacyHooks = legacy }
    }

    func start() {
        let tailer = EventTailer { [weak self] events, replay in
            MainActor.assumeIsolated { self?.ingest(events, replay: replay) }
        }
        self.tailer = tailer
        tailer.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func ingest(_ events: [AgentEvent], replay: Bool) {
        // Hooks run async, so two near-simultaneous events can land out of order; their timestamps don't.
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            guard let tr = store.apply(e), let s = store.sessions[tr.sessionID] else { continue }
            activity.record(tr, session: s)
            // Replayed history and events that are old news should update state silently.
            if !replay, Date().timeIntervalSince(e.date) < 60, isShown(s) {
                onTransition?(tr, s)
            }
        }
    }

    /// Scanner and probes post synthetic events through the log so a restart replays the same history.
    func post(_ event: AgentEvent) {
        EventLog.append(event)
        tailer?.poll()
    }

    private func post(_ events: [AgentEvent]) {
        for e in events { EventLog.append(e) }
        if !events.isEmpty { tailer?.poll() }
    }

    private func tick() {
        now = Date()
        tickCount += 1
        if settings.trackProcesses, tickCount % 3 == 1 { scan() }
        if tickCount % 3 == 2 { pollChats() }
        probeTranscripts()
        store.prune(now: now, endedRetention: settings.endedRetention)
        if tickCount % 600 == 0 { activity.prune(before: now.addingTimeInterval(-36 * 3600)) }
        if tickCount % 30 == 1 { refreshLegacyHooks() }
        if detailID.map({ store.sessions[$0] == nil }) == true { detailID = nil }
        onTick?()
    }

    /// Liveness from the process table, Codex state from rollout logs, and Claude desktop sessions.
    func scan() {
        let procs = ProcessScanner.agentProcesses()
        var events = ProcessScanner.reconcile(store: store, processes: procs, now: now)
        let codexAlive = procs.contains { $0.agent == .codex }
        events += RolloutScanner.reconcile(store: store, rollouts: rollouts.recent(now: now),
                                           codexAlive: codexAlive, now: now)
        if settings.watchClaudeDesktop {
            let running = ProcTools.isAppRunning(executableName: "Claude", bundleName: "Claude.app")
            events += ClaudeDesktopScanner.reconcile(store: store, sessions: running ? desktop.recent(now: now) : [],
                                                     appRunning: running, now: now)
        }
        post(events)
    }

    /// Experimental chat watching. Accessibility calls are slow, so they run off the main thread.
    private func pollChats() {
        let enabled = settings.watchChats
        guard enabled || store.sessions.values.contains(where: { $0.isChat && $0.state != .ended }) else { return }
        // Accessibility isn't available to sandboxed (App Store) builds.
        guard !Paths.isSandboxed else { return }
        chats.observe(enabled: enabled) { [weak self] seen in
            guard let self else { return }
            self.post(ChatWatcher.reconcile(store: self.store, seen: seen, now: Date()))
        }
    }

    /// Every few seconds, for running sessions: note transcript growth, refresh context use,
    /// and catch Claude's silent Esc-interrupts.
    private func probeTranscripts() {
        for s in store.sessions.values where s.state == .running || s.id == detailID {
            guard let path = s.transcriptPath else { continue }
            if let last = lastProbe[s.id], now.timeIntervalSince(last) < 5 { continue }
            lastProbe[s.id] = now
            if let m = TranscriptProbe.modificationDate(path), m != lastOutput[s.id] {
                lastOutput[s.id] = m
                refreshContext(s)
            } else if context[s.id] == nil {
                refreshContext(s)
            }
            guard s.state == .running else { continue }
            let quietFor = now.timeIntervalSince(max(s.lastEventAt, lastOutput[s.id] ?? .distantPast))
            if s.agent == .claude, quietFor > 3, TranscriptProbe.claudeWasInterrupted(transcript: path) {
                var e = AgentEvent(agent: s.agent, event: "Interrupted", sessionId: s.sessionId)
                e.origin = "probe"
                post(e)
            }
        }
    }

    func refreshContext(_ s: Session) {
        guard let path = s.transcriptPath, let usage = TranscriptProbe.contextUsage(path, agent: s.agent) else { return }
        if context[s.id] != usage { context[s.id] = usage }
    }

    // MARK: - View data

    func displayState(_ s: Session) -> SessionState {
        s.displayState(now: now, staleAfter: settings.staleAfter, lastOutputAt: lastOutput[s.id])
    }

    /// Whether the Sources settings let this session show anywhere (panel, menu bar, notifications).
    func isShown(_ s: Session) -> Bool {
        if s.isChat { return settings.watchChats }
        switch s.hostKind {
        case "claude-desktop": return settings.watchClaudeDesktop
        case "chatgpt", "codex-desktop": return settings.watchChatGPT
        default: return true
        }
    }

    private var sorted: [Session] {
        store.sorted(now: now, staleAfter: settings.staleAfter) { [lastOutput] in lastOutput[$0.id] }
            .filter(isShown)
    }

    /// Every session the panel may list, before the filter tab.
    var rows: [Session] {
        sorted.filter { settings.showIdle || ![.idle, .unknown].contains(displayState($0)) }
    }

    var filter: PanelFilter {
        get { PanelFilter(rawValue: settings.panelFilter) ?? .all }
        set { settings.panelFilter = newValue.rawValue }
    }

    /// One row of the list: a single session, or (with "Group sessions by project") every session in a
    /// project, most urgent first. The row shows its primary session, the most urgent one.
    struct Unit: Identifiable {
        var id: String
        var sessions: [Session]
        var primary: Session { sessions[0] }
        var isProject: Bool { sessions.count > 1 }
    }

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var units: [Unit]
    }

    /// Sessions in `ordered` (already most urgent first) collected by project, keeping that order.
    /// Chats and sessions with no folder stay on their own.
    func projectUnits(_ ordered: [Session]) -> [Unit] {
        Session.groupedByProject(ordered).map { Unit(id: "project:" + $0[0].projectKey, sessions: $0) }
    }

    /// Every row the panel may list, before the filter tab.
    var units: [Unit] {
        settings.groupByProject ? projectUnits(rows) : rows.map { Unit(id: $0.id, sessions: [$0]) }
    }

    func state(_ u: Unit) -> SessionState { displayState(u.primary) }

    /// Needs you / Working / Idle, after the filter tab; empty groups dropped.
    var groups: [Group] {
        let units = units.filter { filter.includes(state($0)) }
        let defs: [(String, (SessionState) -> Bool)] = [
            ("Needs you", { $0 == .needsInput }),
            ("Working", { $0 == .running || $0 == .stale }),
            ("Idle", { ![.needsInput, .running, .stale].contains($0) }),
        ]
        return defs.map { title, match in Group(title: title, units: units.filter { match(state($0)) }) }
            .filter { !$0.units.isEmpty }
    }

    /// Projects whose rows are open to show all their sessions. They start collapsed.
    var expandedProjects: Set<String> = []

    func toggleExpanded(_ u: Unit) {
        if expandedProjects.contains(u.id) { expandedProjects.remove(u.id) } else { expandedProjects.insert(u.id) }
    }

    /// Live sessions for the menu bar and switcher, in panel order (ended ones left out).
    var menuBarSessions: [Session] {
        sorted.filter { displayState($0) != .ended }
    }

    /// One dot per session, or per project when grouping (colored by its most urgent session).
    var menuBarStates: [SessionState] {
        settings.groupByProject ? projectUnits(menuBarSessions).map(state) : menuBarSessions.map(displayState)
    }

    var counts: (attention: Int, running: Int, idle: Int) {
        var a = 0, r = 0, i = 0
        for s in store.sessions.values where isShown(s) {
            switch displayState(s) {
            case .needsInput: a += 1
            case .running, .stale: r += 1
            case .idle, .unknown: i += 1
            case .ended: break
            }
        }
        return (a, r, i)
    }

    /// The session that has waited longest, for "Jump to Next Waiting" and the pill.
    var nextWaiting: Session? { menuBarSessions.first { displayState($0) == .needsInput } }

    /// When the state began, for "waiting 3m". Stale counts from the last sign of life.
    func since(_ s: Session) -> Date {
        if displayState(s) == .stale { return max(s.lastEventAt, lastOutput[s.id] ?? .distantPast) }
        if let p = s.primaryPending, s.state == .needsInput { return p.since }
        return s.stateSince
    }

    func today() -> ActivitySummary {
        let summary = activity.summary(from: Calendar.current.startOfDay(for: now), to: now)
        let hidden = Set(store.sessions.values.filter { !isShown($0) }.map(\.id))
        guard !hidden.isEmpty else { return summary }
        return ActivitySummary(lanes: summary.lanes.filter { !hidden.contains($0.sessionID) },
                               waits: summary.waits, projects: summary.projects)
    }

    func dismiss(_ s: Session) {
        store.remove(s.id)
        if detailID == s.id { detailID = nil }
    }

    func isMuted(_ s: Session) -> Bool { muted.contains(s.id) }
    func toggleMute(_ s: Session) { if muted.contains(s.id) { muted.remove(s.id) } else { muted.insert(s.id) } }
}
