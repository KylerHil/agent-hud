import CryptoKit
import Foundation

/// A question keeps its source numbering so a reply remains understandable outside the HUD.
public struct QuickQuestion: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var number: String?
    public var text: String
    public var options: [String]
    /// One-based line in the Markdown file or assistant message.
    public var line: Int

    public init(id: String, number: String? = nil, text: String, options: [String] = [], line: Int) {
        self.id = id; self.number = number; self.text = text; self.options = options; self.line = line
    }
}

public struct QuickQuestionSource: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case chat, markdown, interactive }
    public var id: String
    public var sessionID: String
    public var title: String
    public var path: String
    public var kind: Kind
    public var questions: [QuickQuestion]
    public var sourceText: String
    /// Deterministic fingerprint of the original content, for detecting edits before answering.
    public var sourceVersion: String
    public var updatedAt: Date
    /// Chat questions with no heading, numbering or options ("What should I work on next?"). Listed, not counted.
    public var loose = false

    public init(id: String, sessionID: String, title: String, path: String, kind: Kind,
                questions: [QuickQuestion], sourceText: String, sourceVersion: String, updatedAt: Date) {
        self.id = id; self.sessionID = sessionID; self.title = title; self.path = path; self.kind = kind
        self.questions = questions; self.sourceText = sourceText; self.sourceVersion = sourceVersion
        self.updatedAt = updatedAt
    }
}

/// Local, conservative extraction. These are suggested questions, not permission requests or proof
/// that an agent is blocked. No model calls, recursive directory traversal, or transcript writes.
public enum QuickQuestionScanner {
    private static let maxFileBytes = 512 * 1024
    private static let maxTranscriptBytes = 4 * 1024 * 1024
    private static let maxQuestions = 32

    public static func markdown(text: String) -> [QuickQuestion] { questions(text, requireSection: true) }
    public static func assistant(text: String) -> [QuickQuestion] { questions(text, requireSection: false) }

    /// Explicitly selected files may live outside a project. Automatic discovery uses stricter roots.
    public static func file(path: String, sessionID: String) -> QuickQuestionSource? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        guard isMarkdown(url.path), let text = readBounded(url.path, bytes: maxFileBytes) else { return nil }
        let found = markdown(text: text)
        guard !found.isEmpty else { return nil }
        return source(sessionID: sessionID, title: url.lastPathComponent, path: url.path, kind: .markdown,
                      questions: found, text: text, updatedAt: TranscriptProbe.modificationDate(url.path) ?? .distantPast)
    }

    public static func scan(session: Session) -> [QuickQuestionSource] {
        guard !session.isChat, session.agent != .chatgpt else { return [] }
        var state = TranscriptState()
        var found: [QuickQuestionSource] = []
        if let path = session.transcriptPath {
            state = parse(lines: transcriptLines(path), agent: session.agent)
            found = sources(state, sessionID: session.id, path: path)
            let modified = TranscriptProbe.modificationDate(path) ?? .distantPast
            for i in found.indices { found[i].updatedAt = modified }
        }

        // Only files this turn touched or the latest assistant reply explicitly references are eligible.
        // Older session-wide edits may belong to questions the user has already answered.
        var candidates = state.paths + referencedMarkdown(state.text) + session.turnFiles
        if let started = session.turnStartedAt {
            candidates += session.filesChanged.suffix(8).filter {
                guard let path = automaticPath($0, session: session),
                      let modified = TranscriptProbe.modificationDate(path) else { return false }
                return modified >= started
            }
        }
        var seen = Set<String>()
        for candidate in candidates.prefix(48) {
            guard let path = automaticPath(candidate, session: session), seen.insert(path).inserted,
                  let item = file(path: path, sessionID: session.id) else { continue }
            found.append(item)
            if seen.count >= 12 { break }
        }
        return found
    }

    /// Exposed for fixtures and callers that already have bounded transcript data.
    public static func transcript(lines: [String], agent: AgentKind, sessionID: String, path: String) -> [QuickQuestionSource] {
        sources(parse(lines: lines, agent: agent), sessionID: sessionID, path: path)
    }

    private struct TranscriptState {
        var text = ""
        var messageID: String?
        var turnID: String?
        var paths: [String] = []
        var requests: [(id: String, questions: [QuickQuestion], text: String)] = []
        var updatedAt = Date.distantPast
    }

    private static func parse(lines: [String], agent: AgentKind) -> TranscriptState {
        var state = TranscriptState()
        var lastTimestamp: String?
        guard agent != .chatgpt else { return state }
        for line in lines where !skippable(line, agent: agent, pending: !state.requests.isEmpty) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if let timestamp = object["timestamp"] as? String { lastTimestamp = timestamp }
            if agent == .claude {
                guard let message = object["message"] as? [String: Any] else { continue }
                let blocks = message["content"] as? [[String: Any]] ?? []
                if type == "user" {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        if let id = block["tool_use_id"] as? String { state.requests.removeAll { $0.id == id } }
                    }
                    let text = message["content"] as? String ?? blocks.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty, object["isMeta"] as? Bool != true, !isSystemTurn(text) {
                        let date = state.updatedAt
                        state = TranscriptState(); state.updatedAt = date
                        state.turnID = object["uuid"] as? String ?? message["id"] as? String
                            ?? object["timestamp"] as? String ?? fingerprint(line)
                    }
                } else if type == "assistant" {
                    let text = message["content"] as? String ?? blocks.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty {
                        let id = message["id"] as? String ?? object["uuid"] as? String
                        if let id, id == state.messageID, state.text != text {
                            state.text += "\n" + text
                        } else { state.text = text }
                        state.messageID = id
                    }
                    for block in blocks where block["type"] as? String == "tool_use" {
                        tool(name: block["name"] as? String, id: block["id"] as? String,
                             input: block["input"], state: &state)
                    }
                }
            } else if let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String
                if type == "event_msg" {
                    switch payloadType {
                    case "user_message", "task_started":
                        let date = state.updatedAt
                        state = TranscriptState(); state.updatedAt = date
                        state.turnID = payload["turn_id"] as? String ?? object["timestamp"] as? String ?? fingerprint(line)
                    case "agent_message":
                        if let text = payload["message"] as? String {
                            if state.text != text { state.messageID = object["timestamp"] as? String ?? fingerprint(line) }
                            state.text = text
                        }
                    case "task_complete":
                        if let text = payload["last_agent_message"] as? String { state.text = text }
                    case "turn_aborted": state = TranscriptState()
                    default: break
                    }
                } else if type == "response_item" {
                    switch payloadType {
                    case "message":
                        let role = payload["role"] as? String
                        let blocks = payload["content"] as? [[String: Any]] ?? []
                        let text = blocks.filter { ["input_text", "output_text", "text"].contains($0["type"] as? String ?? "") }
                            .compactMap { $0["text"] as? String }.joined(separator: "\n")
                        if role == "user", !text.isEmpty {
                            let date = state.updatedAt
                            state = TranscriptState(); state.updatedAt = date
                            state.turnID = payload["id"] as? String ?? object["timestamp"] as? String ?? fingerprint(line)
                        } else if role == "assistant", !text.isEmpty {
                            state.text = text
                            state.messageID = payload["id"] as? String ?? object["timestamp"] as? String ?? fingerprint(line)
                        }
                    case "function_call", "custom_tool_call":
                        tool(name: payload["name"] as? String, id: payload["call_id"] as? String,
                             input: payload["arguments"] ?? payload["input"], state: &state)
                    case "function_call_output", "custom_tool_call_output":
                        if let id = payload["call_id"] as? String { state.requests.removeAll { $0.id == id } }
                    default: break
                    }
                }
            }
        }
        state.updatedAt = lastTimestamp.flatMap(timestampDate) ?? .distantPast
        return state
    }

    /// Lines that can't matter, checked without decoding them: most of a transcript is tool output,
    /// reasoning and token counts. Tool results only matter while a structured question is pending.
    private static func skippable(_ line: String, agent: AgentKind, pending: Bool) -> Bool {
        switch agent {
        case .claude:
            if !line.contains(#""type":"user""#) && !line.contains(#""type":"assistant""#) { return true }
            return !pending && line.contains(#""tool_result""#) && !line.contains(#""type":"text""#)
        case .codex:
            for noise in [#""type":"token_count""#, #""type":"reasoning""#, #""type":"turn_context""#]
            where line.contains(noise) { return true }
            return !pending && line.contains(#"_call_output""#)
        case .chatgpt:
            return true
        }
    }

    /// User-side entries the harness adds (a background task finishing, a slash command's output) aren't
    /// your prompts, so they don't end the turn a question belongs to.
    private static func isSystemTurn(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<task-notification>", "<local-command-stdout>", "<local-command-stderr>", "Caveat: "]
            .contains { t.hasPrefix($0) }
    }

    private static func tool(name: String?, id: String?, input: Any?, state: inout TranscriptState) {
        guard let rawName = name else { return }
        let name = rawName.components(separatedBy: ".").last ?? rawName
        var dictionary = input as? [String: Any]
        if let text = input as? String, let data = text.data(using: .utf8) {
            dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if name == "apply_patch" {
                for line in text.components(separatedBy: .newlines) {
                    for prefix in ["*** Add File: ", "*** Update File: "] where line.hasPrefix(prefix) {
                        state.paths.append(String(line.dropFirst(prefix.count)))
                    }
                }
            }
        }
        if ["Write", "Edit", "MultiEdit", "write_file", "edit_file"].contains(name),
           let path = (dictionary?["file_path"] ?? dictionary?["path"]) as? String { state.paths.append(path) }
        guard ["AskUserQuestion", "request_user_input"].contains(name), let id,
              let rawQuestions = dictionary?["questions"] as? [[String: Any]] else { return }
        let found = rawQuestions.prefix(maxQuestions).enumerated().compactMap { index, raw -> QuickQuestion? in
            guard let text = raw["question"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).prefix(12).compactMap { option -> String? in
                guard let label = option["label"] as? String else { return nil }
                if let detail = option["description"] as? String, !detail.isEmpty { return label + " — " + detail }
                return label
            }
            return QuickQuestion(id: fingerprint(id + ":" + String(index) + ":" + text), number: String(index + 1),
                                 text: String(text.prefix(2000)), options: options, line: index + 1)
        }
        guard !found.isEmpty else { return }
        let text = found.map { q in
            (q.number.map { $0 + ". " } ?? "") + q.text + (q.options.isEmpty ? "" : "\n" + q.options.map { "  - " + $0 }.joined(separator: "\n"))
        }.joined(separator: "\n\n")
        state.requests.removeAll { $0.id == id }
        state.requests.append((id, found, text))
    }

    private static func sources(_ state: TranscriptState, sessionID: String, path: String) -> [QuickQuestionSource] {
        var result: [QuickQuestionSource] = []
        let chat = assistant(text: state.text)
        if !chat.isEmpty {
            var item = source(sessionID: sessionID, title: "Assistant reply", path: path, kind: .chat,
                              questions: chat, text: state.text, updatedAt: state.updatedAt)
            item.id += "-" + fingerprint((state.turnID ?? "") + ":" + (state.messageID ?? ""))
            item.loose = markdown(text: state.text).isEmpty && chat.allSatisfy { $0.number == nil && $0.options.isEmpty }
            result.append(item)
        }
        for request in state.requests {
            var item = source(sessionID: sessionID, title: "Interactive question", path: path, kind: .interactive,
                              questions: request.questions, text: request.text, updatedAt: state.updatedAt)
            item.id += "-" + fingerprint(request.id)
            result.append(item)
        }
        return result
    }

    private static func source(sessionID: String, title: String, path: String, kind: QuickQuestionSource.Kind,
                               questions: [QuickQuestion], text: String, updatedAt: Date) -> QuickQuestionSource {
        let version = fingerprint(text)
        return QuickQuestionSource(id: fingerprint(sessionID + "\n" + path + "\n" + kind.rawValue + "\n" + version),
                                   sessionID: sessionID, title: title, path: path, kind: kind, questions: questions,
                                   sourceText: text, sourceVersion: version, updatedAt: updatedAt)
    }

    private static func questions(_ text: String, requireSection: Bool) -> [QuickQuestion] {
        var result: [QuickQuestion] = []
        var fence: Character?
        var sectionDepth: Int?
        var ignoredDepth: Int?
        var current: Int?
        var questionIndent = 0
        var explicitOptions = false
        for (index, original) in text.components(separatedBy: .newlines).enumerated() {
            var line = original.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = line.first!
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            if fence != nil || line.hasPrefix(">") || line.isEmpty { continue }
            let indent = original.prefix { $0 == " " || $0 == "\t" }.count
            var heading = false
            if let parts = captures(#"^(#{1,6})\s+(.+?)\s*#*$"#, line) {
                heading = true
                let depth = parts[0].count
                line = parts[1]
                if let ignored = ignoredDepth, depth <= ignored { ignoredDepth = nil }
                if let active = sectionDepth, depth <= active { sectionDepth = nil; current = nil }
                if isQuestionHeading(line) {
                    sectionDepth = depth; ignoredDepth = nil; current = nil; continue
                }
                if line.lowercased().range(of: #"\b(answered|resolved|closed)\b"#, options: .regularExpression) != nil {
                    ignoredDepth = depth; current = nil; continue
                }
            } else {
                // Plans also commonly use a bold label instead of a Markdown heading.
                let label = line.replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if label.count < 80, isQuestionHeading(label), !label.contains("?"),
                   line.hasPrefix("**") || label.lowercased().hasPrefix("open questions") || label.lowercased() == "questions" {
                    sectionDepth = 7; ignoredDepth = nil; current = nil; continue
                }
            }
            if ignoredDepth != nil || (requireSection && sectionDepth == nil) { continue }
            if line.range(of: #"^(?:[-*+]\s+|\d+[.)]\s+)?\[[xX]\]\s*"#, options: .regularExpression) != nil {
                current = nil; continue
            }
            let answerLine = line.replacingOccurrences(of: "**", with: "")
            if answerLine.range(of: #"^(?:[-*+]\s+)?(?:answer|answered|decision|resolved|chosen|selected)\s*[:—-]"#,
                                options: [.regularExpression, .caseInsensitive]) != nil {
                if let current, current == result.count - 1 { result.removeLast() }
                current = nil; continue
            }
            if line.lowercased() == "options:" || line.lowercased() == "choices:" { explicitOptions = true; continue }
            let list = captures(#"^(?:(\d+)[.)]|([A-Za-z])[.)]|[-*+])\s+(?:\[\s\]\s*)?(.+)$"#, line)
            let number = list.flatMap { $0[0].isEmpty ? nil : $0[0] }
            let letter = list.flatMap { $0[1].isEmpty ? nil : $0[1] }
            let content = list?[2] ?? line
            let nextNumberedQuestion = number != nil && indent <= questionIndent && content.contains("?")
            if let current, list != nil, (indent > questionIndent || letter != nil || explicitOptions),
               !heading, !nextNumberedQuestion {
                if result[current].options.count < 12 { result[current].options.append(String(content.prefix(1000))) }
                continue
            }
            let hasQuestion = content.contains("?")
            let sectionItem = sectionDepth != nil && list != nil && letter == nil
            guard hasQuestion || sectionItem else { continue }
            // Avoid promoting an entire code fragment, URL, or very long prose block to a question.
            guard !content.hasPrefix("http://"), !content.hasPrefix("https://"), content.count <= 2000,
                  !(content.hasPrefix("`") && content.hasSuffix("`")), result.count < maxQuestions else { continue }
            let cleaned = content.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let q = QuickQuestion(id: fingerprint("\(index + 1):\(number ?? ""):\(cleaned)"), number: number,
                                  text: cleaned, line: index + 1)
            result.append(q); current = result.count - 1; questionIndent = indent; explicitOptions = false
        }
        return result
    }

    private static func isQuestionHeading(_ text: String) -> Bool {
        let text = text.lowercased().replacingOccurrences(of: "**", with: "")
        return text.range(of: #"\b(open questions?|unanswered questions?|questions? for (?:you|review)|decisions? (?:needed|required)|pending (?:questions?|decisions?)|clarifying questions?)\b"#,
                          options: .regularExpression) != nil || text.trimmingCharacters(in: .whitespacesAndNewlines) == "questions"
    }

    private static func referencedMarkdown(_ text: String) -> [String] {
        var paths: [String] = []
        for pattern in [#"\]\(([^\n)]+)\)"#, #"`([^`\n]+)`"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                paths.append(ns.substring(with: match.range(at: 1)))
            }
        }
        return paths
    }

    private static func automaticPath(_ input: String, session: Session) -> String? {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("<"), let end = path.firstIndex(of: ">") { path = String(path[path.index(after: path.startIndex)..<end]) }
        path = path.replacingOccurrences(of: #"\s+\"[^\"]*\"$"#, with: "", options: .regularExpression)
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        path = path.removingPercentEncoding ?? path
        path = path.replacingOccurrences(of: #"[#:](?:L)?\d+(?:[-:]\d+)?$"#, with: "", options: .regularExpression)
        guard !path.contains("://"), isMarkdown(path) else { return nil }
        path = (path as NSString).expandingTildeInPath
        let base = session.cwd ?? session.launchDir ?? session.root
        if !path.hasPrefix("/") {
            guard let base else { return nil }
            path = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(path).path
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [session.root ?? session.launchDir ?? session.cwd,
                     Paths.userHome.appendingPathComponent(".claude/plans").path]
            .compactMap { $0 }.filter { $0 != "/" }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path }
        return roots.contains { ProjectRoot.contains($0, canonical) } ? canonical : nil
    }

    private static func isMarkdown(_ path: String) -> Bool { ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) }

    private static func readBounded(_ path: String, bytes: Int) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= bytes,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes + 1), data.count <= bytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func transcriptLines(_ path: String) -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxTranscriptBytes) ? size - UInt64(maxTranscriptBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: maxTranscriptBytes) else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
    }

    private static func timestampDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}
