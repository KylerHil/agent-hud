import AgentHUDCore
import AppKit
import Observation
import UniformTypeIdentifiers

/// Reads only local coding transcripts and explicitly associated Markdown; never sends an answer.
@MainActor
@Observable
final class QuickAnswersModel {
    private(set) var sources: [QuickQuestionSource] = []
    var selection: QuickQuestionSource?
    var sessionFilter: String?
    var showHandled = false
    private(set) var refreshing = false
    var message: String?
    var persistenceError: String?
    private(set) var drafts = QuickAnswerDrafts()
    @ObservationIgnored private var lastRefresh = Date.distantPast
    private struct CachedScan: Sendable {
        var signature: String
        var sources: [QuickQuestionSource]
        var checkedAt: Date
    }
    @ObservationIgnored private var scanCache: [String: CachedScan] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let draftURL: URL
    @ObservationIgnored private var readableDrafts = true

    init(home: URL = Paths.home) {
        draftURL = home.appendingPathComponent("quick-answer-drafts.json")
        do { drafts = try QuickAnswerDrafts.load(from: draftURL) }
        catch {
            readableDrafts = false
            persistenceError = "Saved drafts could not be read. New drafts stay in memory to preserve the existing file."
        }
    }

    /// Deterministic fixture entry point for the image-rendering command, never used by live polling.
    func loadSnapshot(_ sources: [QuickQuestionSource]) {
        self.sources = sources
        selection = sources.first
    }

    var visible: [QuickQuestionSource] {
        sources.filter { (sessionFilter == nil || $0.sessionID == sessionFilter) && (showHandled || !drafts.isHandled($0.id)) }
    }

    /// The header badge: structured questions only, so an offer like "Want me to ship it?" doesn't light it.
    var count: Int { sources.filter { !$0.loose && !drafts.isHandled($0.id) }.reduce(0) { $0 + $1.questions.count } }
    var selectionIsCurrent: Bool { selection.map { chosen in sources.contains { $0.id == chosen.id } } ?? false }

    func choose(_ source: QuickQuestionSource) { selection = source; message = nil }

    func answer(_ question: QuickQuestion, in source: QuickQuestionSource) -> String {
        drafts.answer(sourceID: source.id, questionID: question.id)
    }

    func setAnswer(_ value: String, question: QuickQuestion, source: QuickQuestionSource) {
        drafts.setAnswer(value, sourceID: source.id, questionID: question.id)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func handle(_ source: QuickQuestionSource) {
        drafts.setHandled(!drafts.isHandled(source.id), sourceID: source.id)
        save()
        selection = visible.first
        message = nil
    }

    func save() {
        guard readableDrafts else { return }
        do { try drafts.save(to: draftURL); persistenceError = nil }
        catch { persistenceError = "Drafts could not be saved: \(error.localizedDescription)" }
    }

    func reply(for source: QuickQuestionSource) -> String? {
        QuickAnswerComposer.reply(source: source, answers: drafts.entries[source.id]?.answers ?? [:])
    }

    func refresh(sessions: [Session], force: Bool = false) {
        guard !refreshing, force || Date().timeIntervalSince(lastRefresh) >= 5 else { return }
        if let filter = sessionFilter, !sessions.contains(where: { $0.id == filter && $0.state != .ended }) {
            sessionFilter = nil
        }
        refreshing = true
        lastRefresh = Date()
        let imports = drafts.attachedPlans
        let previous = scanCache
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                var results: [QuickQuestionSource] = []
                var cache: [String: CachedScan] = [:]
                for session in sessions where !session.isChat && session.state != .ended {
                    let old = previous[session.id]
                    // Questions only matter once a turn ends; a working session keeps what it had.
                    if !force, session.state == .running, let old {
                        results += old.sources
                        cache[session.id] = old
                        continue
                    }
                    let paths = [session.transcriptPath].compactMap { $0 }
                        + (imports[session.id] ?? [])
                        + (old?.sources.filter { $0.kind == .markdown }.map(\.path) ?? [])
                    let stamps = Set(paths).sorted().map { path -> String in
                        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        return "\(path):\(modified):\(attrs?[.size] ?? 0)"
                    }
                    let signature = (stamps + session.turnFiles + [session.cwd ?? "", session.lastPrompt ?? ""]).joined(separator: "\n")
                    if !force, let old, old.signature == signature {
                        results += old.sources
                        cache[session.id] = old
                        continue
                    }
                    var current = QuickQuestionScanner.scan(session: session)
                    for path in imports[session.id] ?? [] {
                        if let source = QuickQuestionScanner.file(path: path, sessionID: session.id) { current.append(source) }
                    }
                    cache[session.id] = CachedScan(signature: signature, sources: current, checkedAt: Date())
                    results += current
                }
                var seen = Set<String>()
                return (sources: results.filter { seen.insert($0.id).inserted }.sorted { $0.updatedAt > $1.updatedAt }, cache: cache)
            }.value
            guard let self else { return }
            self.sources = found.sources
            self.scanCache = found.cache
            self.refreshing = false
            // Keep an edited selection if its source changes, so text never jumps to another question.
            if self.selection == nil { self.selection = self.visible.first }
        }
    }

    func attachPlan(to session: Session) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Markdown plan for \(session.projectName)"
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = (session.root ?? session.cwd).map { URL(fileURLWithPath: $0) }
        panel.begin { [weak self] result in
            MainActor.assumeIsolated {
                guard result == .OK, let url = panel.url, let self else { return }
                guard let source = QuickQuestionScanner.file(path: url.path, sessionID: session.id) else {
                    self.message = "No open questions found. Use a Questions or Open questions heading with numbered questions, and keep the file under 512 KB."
                    return
                }
                self.drafts.attach(path: url.path, sessionID: session.id)
                self.save()
                if !self.sources.contains(where: { $0.id == source.id }) { self.sources.append(source) }
                self.selection = source
                self.sessionFilter = session.id
                self.message = nil
            }
        }
    }

    /// Refresh the exact source before copying. A follow-up user turn or edited plan invalidates old answers.
    /// The check rereads a transcript of up to 4 MB, so it runs off the main thread.
    func copyReply(_ source: QuickQuestionSource, session: Session?, openSession: Bool) {
        guard let text = reply(for: source) else { return }
        Task { [weak self] in
            let current = await Task.detached(priority: .userInitiated) { () -> Bool in
                if source.kind == .markdown {
                    return QuickQuestionScanner.file(path: source.path, sessionID: source.sessionID)?.id == source.id
                }
                guard let session, session.state != .ended else { return false }
                return QuickQuestionScanner.scan(session: session).contains { $0.id == source.id }
            }.value
            self?.finishCopy(text, current: current, session: session, openSession: openSession)
        }
    }

    private func finishCopy(_ text: String, current: Bool, session: Session?, openSession: Bool) {
        guard current else {
            message = "The source changed or the session ended. Refresh and select the current questions before copying. Your draft has been kept."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            message = "The clipboard could not be updated. Try Copy answers again."
            return
        }
        save()
        message = "Copied. Choose this conversation in the agent, paste and send, then mark these questions handled."
        if openSession, let session, session.state != .ended { Focuser.focus(session) }
    }
}
