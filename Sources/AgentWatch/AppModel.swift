import AgentWatchCore
import Foundation
import Observation

/// Glue between the event log, the state machine, and the UI.
@MainActor
@Observable
final class AppModel {
    let store = SessionStore()
    let settings: AppSettings
    private(set) var now = Date()

    /// Called for live (not replayed) state changes. Wired to notifications.
    @ObservationIgnored var onTransition: ((Transition, Session) -> Void)?
    /// Called every tick, for re-reminders.
    @ObservationIgnored var onTick: (() -> Void)?

    @ObservationIgnored private var tailer: EventTailer?
    @ObservationIgnored private var timer: Timer?
    /// Last write to each session's transcript; a transcript still growing means the agent is still working.
    private var lastOutput: [String: Date] = [:]
    @ObservationIgnored private var lastProbe: [String: Date] = [:]
    @ObservationIgnored private let rollouts = RolloutScanner()
    @ObservationIgnored private var tickCount = 0

    init(settings: AppSettings) {
        self.settings = settings
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
        for e in events {
            guard let tr = store.apply(e) else { continue }
            // Replayed history and events that are old news should update state silently.
            if !replay, Date().timeIntervalSince(e.date) < 60, let s = store.sessions[tr.sessionID] {
                onTransition?(tr, s)
            }
        }
    }

    /// Scanner and probes post synthetic events through the log so a restart replays the same history.
    func post(_ event: AgentEvent) {
        EventLog.append(event)
        tailer?.poll()
    }

    private func tick() {
        now = Date()
        tickCount += 1
        if settings.trackProcesses, tickCount % 3 == 1 { scan() }
        probeTranscripts()
        store.prune(now: now, endedRetention: settings.endedRetention)
        onTick?()
    }

    /// Liveness from the process table, plus Codex state from rollout logs for sessions without hooks.
    func scan() {
        let procs = ProcessScanner.agentProcesses()
        var events = ProcessScanner.reconcile(store: store, processes: procs, now: now)
        let codexAlive = procs.contains { $0.agent == .codex }
        events += RolloutScanner.reconcile(store: store, rollouts: rollouts.recent(now: now),
                                           codexAlive: codexAlive, now: now)
        for e in events { EventLog.append(e) }
        if !events.isEmpty { tailer?.poll() }
    }

    /// Every few seconds, for running sessions: note transcript growth, and catch Claude's silent Esc-interrupts.
    private func probeTranscripts() {
        for s in store.sessions.values where s.state == .running {
            guard let path = s.transcriptPath else { continue }
            if let last = lastProbe[s.id], now.timeIntervalSince(last) < 5 { continue }
            lastProbe[s.id] = now
            if let m = TranscriptProbe.modificationDate(path), m != lastOutput[s.id] { lastOutput[s.id] = m }
            let quietFor = now.timeIntervalSince(max(s.lastEventAt, lastOutput[s.id] ?? .distantPast))
            if s.agent == .claude, quietFor > 3, TranscriptProbe.claudeWasInterrupted(transcript: path) {
                var e = AgentEvent(agent: s.agent, event: "Interrupted", sessionId: s.sessionId)
                e.origin = "probe"
                post(e)
            }
        }
    }

    // MARK: - View data

    func displayState(_ s: Session) -> SessionState {
        s.displayState(now: now, staleAfter: settings.staleAfter, lastOutputAt: lastOutput[s.id])
    }

    var rows: [Session] {
        store.sorted(now: now, staleAfter: settings.staleAfter) { [lastOutput] in lastOutput[$0.id] }
            .filter { settings.showIdle || ![.idle, .unknown].contains(displayState($0)) }
    }

    var counts: (attention: Int, running: Int, idle: Int) {
        var a = 0, r = 0, i = 0
        for s in store.sessions.values {
            switch displayState(s) {
            case .needsInput: a += 1
            case .running, .stale: r += 1
            case .idle, .unknown: i += 1
            case .ended: break
            }
        }
        return (a, r, i)
    }

    /// When the state began, for "waiting 3m". Stale counts from the last sign of life.
    func since(_ s: Session) -> Date {
        if displayState(s) == .stale { return max(s.lastEventAt, lastOutput[s.id] ?? .distantPast) }
        if let p = s.primaryPending, s.state == .needsInput { return p.since }
        return s.stateSince
    }

    func dismiss(_ s: Session) { store.remove(s.id) }
}

func shortDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86400)d"
}
