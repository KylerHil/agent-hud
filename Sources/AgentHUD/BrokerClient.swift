import AgentHUDCore
import Darwin
import Foundation
import Observation

/// Agent HUD's connection to `agenthud-broker`, which owns the sessions and pairs the Coordinator starts.
/// The broker is launched on first use and outlives the app; reconnecting picks up where it left off.
@MainActor
@Observable
final class BrokerClient {
    private(set) var connected = false
    private(set) var sessions: [String: ManagedSession] = [:]
    private(set) var editors: [EditorWorkspace] = []
    private(set) var pairs: [String: PairState] = [:]
    /// Shown in the Coordinator when the broker can't be reached or a request failed.
    var lastError: String?

    @ObservationIgnored private var connection: LineConnection?
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "agenthud.broker.client")
    @ObservationIgnored private var waiting: [String: (BrokerMessage) -> Void] = [:]
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var retryTimer: Timer?
    /// Called when a pair changes (not for the snapshot on connect), for notifications.
    @ObservationIgnored var onPairChange: ((_ old: PairState?, _ new: PairState) -> Void)?

    /// Connects if a broker is already running (it has sessions from before this launch). Doesn't start one.
    func attachIfRunning() {
        guard !connected, FileManager.default.fileExists(atPath: BrokerInfo.socketPath) else { return }
        connect(launch: false) { _ in }
    }

    /// Connects, launching the broker if needed. `done(nil)` once connected, else the error.
    func connect(launch: Bool = true, done: @escaping (String?) -> Void) {
        if connected { return done(nil) }
        if let c = LineSocket.connect(path: BrokerInfo.socketPath, queue: ioQueue) {
            attach(c)
            return done(nil)
        }
        guard launch else { return done("The broker isn't running.") }
        guard !connecting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect(launch: false, done: done) }
            return
        }
        connecting = true
        if let error = Self.launchBroker() {
            connecting = false
            return done(error)
        }
        // Give it a moment to bind its socket.
        var tries = 0
        func attempt() {
            tries += 1
            if let c = LineSocket.connect(path: BrokerInfo.socketPath, queue: ioQueue) {
                connecting = false
                attach(c)
                done(nil)
            } else if tries < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { attempt() }
            } else {
                connecting = false
                done("Agent HUD's broker didn't start. See \(BrokerInfo.logFile.path).")
            }
        }
        attempt()
    }

    private func attach(_ c: LineConnection) {
        connection = c
        c.onLine = { [weak self] data in
            guard let m = try? BrokerCoding.decoder.decode(BrokerMessage.self, from: data) else { return }
            DispatchQueue.main.async { self?.receive(m) }
        }
        c.onClose = { [weak self] in
            DispatchQueue.main.async { self?.disconnected() }
        }
        LineSocket.start(c)
        connected = true
        lastError = nil
        var hello = BrokerRequest(op: "hello")
        hello.version = BrokerInfo.protocolVersion
        send(hello, done: nil)
    }

    private func disconnected() {
        connected = false
        lastError = "Disconnected from the broker. Task state is preserved; reconnect to check progress."
        connection = nil
        let pending = waiting
        waiting = [:]
        var failure = BrokerMessage(kind: "reply")
        failure.ok = false
        failure.error = "Lost the connection to Agent HUD's broker."
        pending.values.forEach { $0(failure) }
        // Sessions keep running in the broker; reconnect quietly while it's there.
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                if self.connected { return t.invalidate() }
                if !FileManager.default.fileExists(atPath: BrokerInfo.socketPath) {
                    // The broker exited (idle). Its sessions had all stopped; keep showing them as stopped.
                    for (k, var s) in self.sessions where s.status != .exited && s.status != .failed {
                        s.status = .exited
                        s.error = "The broker is no longer connected. Review the last output, then Resume."
                        self.sessions[k] = s
                    }
                    return t.invalidate()
                }
                self.attachIfRunning()
            }
        }
    }

    private func receive(_ m: BrokerMessage) {
        switch m.kind {
        case "snapshot":
            sessions = Dictionary((m.sessions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            editors = m.editors ?? []
            pairs = Dictionary((m.pairs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            if let v = m.version, v < BrokerInfo.protocolVersion { restartOutdatedBroker() }
            else if let v = m.version, v > BrokerInfo.protocolVersion {
                lastError = "A newer broker is running. Update Agent HUD to use it; its work has been left running."
            }
        case "editors":
            editors = m.editors ?? []
        case "session":
            if let s = m.session { sessions[s.id] = s }
        case "removed":
            if let k = m.removed { sessions[k] = nil }
        case "pair":
            if let p = m.pair {
                let old = pairs[p.id]
                pairs[p.id] = p
                onPairChange?(old, p)
            }
        case "pairRemoved":
            if let k = m.removed { pairs[k] = nil }
        case "reply":
            if let id = m.replyTo, let done = waiting.removeValue(forKey: id) { done(m) }
        default:
            break
        }
    }

    /// A broker from an older Agent HUD speaks another protocol: ask it to exit once idle, then start ours.
    private func restartOutdatedBroker() {
        send(BrokerRequest(op: "shutdown")) { [weak self] reply in
            guard reply.ok == true else {
                self?.lastError = "An older broker is still running sessions. Agent HUD will switch once they finish."
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.connect { _ in } }
        }
    }

    // MARK: Requests

    func send(_ request: BrokerRequest, done: ((BrokerMessage) -> Void)?) {
        guard let connection, connected else {
            var r = BrokerMessage(kind: "reply")
            r.ok = false
            r.error = "Agent HUD's broker isn't connected."
            done?(r)
            return
        }
        if let done {
            waiting[request.id] = done
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let callback = self?.waiting.removeValue(forKey: request.id) else { return }
                var failure = BrokerMessage(kind: "reply"); failure.ok = false
                failure.error = "The broker didn't acknowledge the action. Check task state before retrying; delivery may have succeeded."
                self?.lastError = failure.error
                callback(failure)
            }
        }
        ioQueue.async { connection.send(request) }
    }

    /// Connects (launching the broker if needed), sends, and reports the reply's error or key.
    func perform(_ request: BrokerRequest, done: @escaping (_ error: String?, _ key: String?) -> Void = { _, _ in }) {
        connect { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastError = error
                return done(error, nil)
            }
            self.send(request) { reply in
                if let e = reply.error { self.lastError = e }
                done(reply.ok == true ? nil : (reply.error ?? "The broker refused that."), reply.key)
            }
        }
    }

    func start(_ options: StartOptions, done: @escaping (String?, String?) -> Void) {
        var r = BrokerRequest(op: "start")
        r.start = options
        perform(r, done: done)
    }

    func message(_ session: String, _ text: String, steer: Bool, done: @escaping (String?) -> Void = { _ in }) {
        var r = BrokerRequest(op: "send")
        r.session = session
        r.text = text
        r.steer = steer
        perform(r) { error, _ in done(error) }
    }

    func editorAction(_ action: String, cwd: String, session: String? = nil, done: @escaping (String?) -> Void = { _ in }) {
        var r = BrokerRequest(op: "editorAction"); r.action = action; r.text = cwd; r.session = session
        perform(r) { error, _ in done(error) }
    }

    func interrupt(_ session: String) {
        var r = BrokerRequest(op: "interrupt")
        r.session = session
        perform(r)
    }

    func answer(_ session: String, request: String, decision: String, answers: [String: [String]]? = nil, message: String? = nil) {
        var r = BrokerRequest(op: "answer")
        r.session = session
        r.requestId = request
        r.decision = decision
        r.answers = answers
        r.message = message
        perform(r)
    }

    func setMode(_ session: String, _ mode: String) {
        var r = BrokerRequest(op: "mode")
        r.session = session
        r.text = mode
        perform(r)
    }

    func stop(_ session: String) {
        var r = BrokerRequest(op: "stop")
        r.session = session
        perform(r)
    }

    func forget(_ session: String) {
        var r = BrokerRequest(op: "forget")
        r.session = session
        perform(r)
    }

    func startPair(_ config: PairConfig, done: @escaping (String?, String?) -> Void) {
        var r = BrokerRequest(op: "pairStart")
        r.pair = config
        perform(r, done: done)
    }

    func pairAction(_ pair: String, _ action: String, text: String? = nil, done: @escaping (String?) -> Void = { _ in }) {
        var r = BrokerRequest(op: "pairAction")
        r.pairID = pair
        r.action = action
        r.text = text
        perform(r) { error, _ in done(error) }
    }

    // MARK: Lookups

    /// The managed session behind a store session (same agent and conversation id).
    func managed(storeID: String) -> ManagedSession? {
        sessions.values.first { $0.storeID == storeID && $0.status != .exited && $0.status != .failed }
            ?? sessions.values.filter { $0.storeID == storeID }.max { $0.lastActivity < $1.lastActivity }
    }

    // MARK: Launch

    /// Starts `agenthud-broker` in its own session, so it isn't tied to the app's process group.
    static func launchBroker() -> String? {
        guard let exe = brokerExecutable() else { return "Couldn't find agenthud-broker next to Agent HUD." }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), nil]
        defer { argv.forEach { free($0) } }
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { env.forEach { free($0) } }
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, env)
        return rc == 0 ? nil : "Couldn't start agenthud-broker (error \(rc))."
    }

    static func brokerExecutable() -> String? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agenthud-broker").path,
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("agenthud-broker").path,
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
