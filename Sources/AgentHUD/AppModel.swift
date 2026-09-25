import AgentHUDCore
import Foundation
import Observation

/// What the panel is showing. Everything lives in the one panel; nothing opens a window of its own.
enum PanelMode: Equatable {
    case list, today, dashboard, settings

    /// The dashboard and settings are roomier than the list, so the panel grows for them.
    var isLarge: Bool { self == .dashboard || self == .settings }
}

enum SettingsTab: Hashable {
    case general, sources, notifications, permissions, hooks
}

/// One line in the ⌃⌥Space palette: a live session to jump to, a project to start a session in, or an
/// earlier conversation to resume.
enum PaletteItem: Identifiable {
    case session(Session)
    case start(root: String, name: String, host: Launcher.Host)
    case resume(HistoryReport.SessionRow, host: Launcher.Host)

    var id: String {
        switch self {
        case .session(let s): "session:" + s.id
        case .start(let root, _, _): "start:" + root
        case .resume(let r, _): "resume:" + r.id
        }
    }
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

    /// Sessions that just finished a turn (id → when), shown as cards above the list for `cardLifetime`.
    private(set) var finishedAt: [String: Date] = AppModel.loadDates("justFinished")
    static let cardLifetime: TimeInterval = 120
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
    /// The most context each session has used, which tells a 1M-token Claude window from a 200K one.
    @ObservationIgnored private var contextPeak: [String: Int] = [:]
    @ObservationIgnored private var contextProbed: Set<String> = []
    @ObservationIgnored private var longContextModels: Set<String> = []
    /// Approved permission prompts, and the allow rules they add up to.
    @ObservationIgnored let permissions = PermissionTally()
    private(set) var suggestions: [PermissionSuggestion] = []
    @ObservationIgnored private var suggestionsStale = true

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

    /// Opens the panel on a session's detail view (from a notification's Show Details).
    func showDetail(_ s: Session) {
        searching = false
        mode = .list
        settings.collapsed = false
        detailID = s.id
        actions.showPanel()
    }

    func beginSearch() {
        detailID = nil
        mode = .list
        settings.collapsed = false
        query = ""
        searchSelection = 0
        searching = true
        history.refreshIfOlder(than: 120)
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

    /// The palette: matching live sessions, then (once you type) projects to start a session in and earlier
    /// conversations to resume, newest first.
    var paletteItems: [PaletteItem] {
        let live = searchResults.map(PaletteItem.session)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return live }
        let recent = history.recent
        var projects: [String: (name: String, last: Date)] = [:]
        for p in recent?.projects ?? [] where p.root != "(unknown)" { projects[p.root] = (p.name, p.last) }
        for s in store.sessions.values where !s.isChat {
            guard let root = s.root, root != "/" else { continue }
            let last = max(projects[root]?.last ?? .distantPast, s.lastEventAt)
            projects[root] = (projects[root]?.name ?? s.projectName, last)
        }
        let starts = projects.filter { $0.value.name.lowercased().contains(q) }
            .sorted { $0.value.last > $1.value.last }.prefix(3)
            .map { PaletteItem.start(root: $0.key, name: $0.value.name, host: launchHost(root: $0.key)) }
        let liveIDs = Set(store.sessions.values.filter { $0.state != .ended }.map(\.sessionId))
        let resumes = (recent?.sessions ?? []).filter { r in
            r.root != "(unknown)" && !liveIDs.contains(r.sessionId) && r.active > 0
                && ((r.title?.lowercased().contains(q) ?? false) || r.project.lowercased().contains(q))
        }
        .sorted { $0.end > $1.end }.prefix(6)
        .map { r in PaletteItem.resume(r, host: resumeHost(r)) }
        return live + starts + resumes
    }

    func activate(_ item: PaletteItem) {
        endSearch()
        switch item {
        case .session(let s): jump(s)
        case .start(let root, _, let host):
            Launcher.open(agent: .claude, dir: root, sessionId: nil, host: host, terminal: preferredTerminal)
        case .resume(let r, let host):
            Launcher.open(agent: r.agent, dir: r.launchDir ?? r.root, sessionId: r.sessionId, host: host,
                          terminal: preferredTerminal)
        }
    }

    /// The app to start a session in for `root`: the setting, else where the project was last used.
    func launchHost(root: String) -> Launcher.Host {
        if let h = Launcher.Host(rawValue: settings.launchHost), h != .automatic { return h }
        let live = store.sessions.values.filter { $0.root == root }.sorted { $0.lastEventAt > $1.lastEventAt }
        if let h = live.lazy.compactMap({ Launcher.Host(hostKind: $0.hostKind) }).first { return h }
        let past = (history.recent?.sessions ?? []).filter { $0.root == root }.sorted { $0.end > $1.end }
        if let h = past.lazy.compactMap({ Launcher.Host(entrypoint: $0.entrypoint) }).first {
            return h == .terminal ? preferredTerminal : h
        }
        return preferredTerminal
    }

    /// A conversation reopens where it ran (an editor, or your terminal), unless the setting says otherwise.
    func resumeHost(_ r: HistoryReport.SessionRow) -> Launcher.Host {
        // Only Claude has an editor link; other agents reopen in your terminal.
        if r.agent != .claude { return preferredTerminal }
        if let h = Launcher.Host(rawValue: settings.launchHost), h != .automatic { return h }
        switch Launcher.Host(entrypoint: r.entrypoint) {
        case .vscode?: return .vscode
        case .terminal?: return preferredTerminal
        default: return launchHost(root: r.root)
        }
    }

    /// The terminal you use most recently: the host of the latest terminal session, else Terminal.
    var preferredTerminal: Launcher.Host {
        store.sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }.lazy
            .compactMap { Launcher.Host(hostKind: $0.hostKind) }.first { !$0.isEditor } ?? .terminal
    }

    // MARK: Allowlist suggestions

    /// The list's suggestion banner stays hidden until a suggestion you haven't hidden it for appears.
    var suggestionBannerHidden: Bool {
        _ = bannerTick
        let seen = Set(UserDefaults.standard.stringArray(forKey: "suggestionBannerSeen") ?? [])
        return suggestions.allSatisfy { seen.contains($0.id) }
    }

    func hideSuggestionBanner() {
        UserDefaults.standard.set(suggestions.map(\.id), forKey: "suggestionBannerSeen")
        bannerTick += 1
    }

    /// Bumped to redraw the list when the banner is hidden (the seen set lives in UserDefaults).
    private(set) var bannerTick = 0

    func refreshSuggestions() {
        suggestionsStale = false
        permissions.save()
        let next = permissions.suggestions(dismissed: settings.dismissedSuggestions)
        if next != suggestions { suggestions = next }
    }

    func accept(_ s: PermissionSuggestion) throws {
        try PermissionRules.add(s.rule, root: s.root)
        refreshSuggestions()
    }

    func dismissSuggestion(_ s: PermissionSuggestion) {
        settings.dismissedSuggestions.insert(s.id)
        refreshSuggestions()
    }

    // MARK: Context

    /// Bumped when the known 1M models change, so rows redraw.
    private(set) var contextTick = 0

    /// How full a session's context is, 0–1, when it can be told.
    func contextFraction(_ s: Session) -> Double? {
        _ = contextTick
        guard s.state != .ended, let u = context[s.id] else { return nil }
        if let f = u.fraction { return f }
        guard s.agent == .claude, let w = contextWindow(s) else { return nil }
        return min(1, Double(u.tokens) / Double(w))
    }

    func contextWindow(_ s: Session) -> Int? {
        guard let u = context[s.id] else { return nil }
        if let w = u.window { return w }
        guard s.agent == .claude else { return nil }
        if settings.claudeContextWindow > 0 { return settings.claudeContextWindow }
        // Past 200K it can only be the 1M window; otherwise it's 1M if that's how you run this model.
        if max(u.tokens, contextPeak[s.id] ?? 0) > 200_000 { return 1_000_000 }
        if let m = u.model, longContextModels.contains(m) { return 1_000_000 }
        return 200_000
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
            if permissions.observe(e) { suggestionsStale = true }
            guard let tr = store.apply(e), let s = store.sessions[tr.sessionID] else { continue }
            activity.record(tr, session: s)
            trackFinished(tr, replay: replay)
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
        if suggestionsStale || tickCount % 300 == 2 { refreshSuggestions() }
        if tickCount % 300 == 3 {
            let models = TranscriptProbe.longContextModels()
            if models != longContextModels { longContextModels = models; contextTick += 1 }
        }
        if tickCount % 300 == 150 { history.refreshIfOlder(than: 240) }
        if detailID.map({ store.sessions[$0] == nil }) == true { detailID = nil }
        pruneFinished()
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
        for s in store.sessions.values where s.state == .running || s.id == detailID || !contextProbed.contains(s.id) {
            guard let path = s.transcriptPath else { continue }
            // Idle sessions are read once, so their rows can show context too.
            if s.state != .running && s.id != detailID {
                contextProbed.insert(s.id)
                refreshContext(s)
                continue
            }
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
        contextPeak[s.id] = max(contextPeak[s.id] ?? 0, usage.tokens)
        if context[s.id] != usage { context[s.id] = usage }
    }

    // MARK: - View data

    func displayState(_ s: Session) -> SessionState {
        s.displayState(now: now, staleAfter: settings.staleAfter, lastOutputAt: lastOutput[s.id])
    }

    /// Whether the Sources settings let this session show anywhere (panel, menu bar, notifications).
    func isShown(_ s: Session) -> Bool {
        guard kindShown(s) else { return false }
        if s.isChat { return settings.watchChats }
        switch s.hostKind {
        case "claude-desktop": return settings.watchClaudeDesktop
        case "chatgpt", "codex-desktop": return settings.watchChatGPT
        default: return true
        }
    }

    /// The General settings' "Show sessions from" toggles. Sessions with no known host always show.
    private func kindShown(_ s: Session) -> Bool {
        if s.isChat || s.isDesktop { return settings.showAppSessions }
        switch s.hostKind {
        case "tmux": return settings.showTmuxSessions
        case "vscode", "cursor", "windsurf": return settings.showEditorSessions
        case "terminal", "iterm", "ghostty", "warp", "wezterm": return settings.showTerminalSessions
        default: return true
        }
    }

    private var sorted: [Session] {
        store.sorted(now: now, staleAfter: settings.staleAfter) { [lastOutput] in lastOutput[$0.id] }
            .filter { isShown($0) && !$0.neverActive }
    }

    /// Every session the panel may list, before the filter tab.
    var rows: [Session] {
        sorted.filter { settings.showIdle || ![.idle, .unknown].contains(displayState($0)) }
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
        // Just-finished sessions show as cards above the list instead.
        let listed = rows.filter { !isJustFinished($0) }
        return settings.groupByProject ? projectUnits(listed) : listed.map { Unit(id: $0.id, sessions: [$0]) }
    }

    func state(_ u: Unit) -> SessionState { displayState(u.primary) }

    /// Needs you / Working / Idle, after the filter tab; empty groups dropped.
    var groups: [Group] {
        let units = units
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
        for s in store.sessions.values where isShown(s) && !s.neverActive {
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

    // MARK: Just finished

    func jump(_ s: Session) { Focuser.focus(s) }

    /// The card's ×: straight to Idle.
    func clearFinished(_ id: String) {
        guard finishedAt[id] != nil else { return }
        finishedAt[id] = nil
        saveFinished()
    }

    /// Finished its turn less than `cardLifetime` ago and hasn't started another.
    func isJustFinished(_ s: Session) -> Bool {
        guard let f = finishedAt[s.id], displayState(s) == .idle else { return false }
        return now.timeIntervalSince(f) < Self.cardLifetime
    }

    /// Seconds before a session's card leaves.
    func cardTimeLeft(_ s: Session) -> TimeInterval {
        max(0, Self.cardLifetime - now.timeIntervalSince(finishedAt[s.id] ?? .distantPast))
    }

    /// Cards, newest first.
    var finishedCards: [Session] {
        rows.filter(isJustFinished).sorted { (finishedAt[$0.id] ?? .distantPast) > (finishedAt[$1.id] ?? .distantPast) }
    }

    /// Only a turn finishing while the app watches makes a card; replayed history can only clear one
    /// (a session that went back to work after its card was made).
    private func trackFinished(_ tr: Transition, replay: Bool) {
        let id = tr.sessionID
        switch tr.to {
        case .idle where !replay && (tr.from == .running || tr.from == .needsInput):
            finishedAt[id] = tr.at
            saveFinished()
        case .running, .needsInput, .ended:
            guard let f = finishedAt[id], tr.at > f else { return }
            finishedAt[id] = nil
            saveFinished()
        default:
            break
        }
    }

    private func pruneFinished() {
        let gone = finishedAt.keys.filter { id in
            guard let s = store.sessions[id] else { return true }
            return s.state == .ended || now.timeIntervalSince(finishedAt[id]!) >= Self.cardLifetime
        }
        guard !gone.isEmpty else { return }
        for id in gone { finishedAt[id] = nil }
        saveFinished()
    }

    private func saveFinished() {
        UserDefaults.standard.set(finishedAt.mapValues(\.timeIntervalSince1970), forKey: "justFinished")
    }

    private static func loadDates(_ key: String) -> [String: Date] {
        ((UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// For `--snapshot`: show a session as having finished `ago` seconds back.
    func markFinishedForSnapshot(_ id: String, ago: TimeInterval) {
        finishedAt[id] = now.addingTimeInterval(-ago)
    }

    func dismiss(_ s: Session) {
        store.remove(s.id)
        if detailID == s.id { detailID = nil }
    }

    func isMuted(_ s: Session) -> Bool { muted.contains(s.id) }
    func toggleMute(_ s: Session) { if muted.contains(s.id) { muted.remove(s.id) } else { muted.insert(s.id) } }
}
