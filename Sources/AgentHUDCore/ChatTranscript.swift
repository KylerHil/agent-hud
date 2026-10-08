import Foundation

/// One line of a session's conversation, as the Coordinator's chat shows it.
public struct ChatItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user, assistant, tool, interrupted
    }

    public var id: String
    public var kind: Kind
    /// The message text; for a tool, its name.
    public var text: String
    /// A tool's argument, shortened: a file name, a command.
    public var detail: String?
    public var at: Date?

    public init(id: String, kind: Kind, text: String, detail: String? = nil, at: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.at = at
    }
}

/// Turns a Claude or Codex transcript into chat items, reading only what was appended since the last
/// call. The first read starts `initialBytes` from the end, so opening a long session stays cheap, and
/// only the newest `limit` items are kept.
public final class ChatTranscript: @unchecked Sendable {
    public let path: String
    public let agent: AgentKind
    public private(set) var items: [ChatItem] = []
    /// True when older history exists before the first item (the first read skipped it).
    public private(set) var truncated = false

    private let initialBytes: Int
    private let limit: Int
    private var offset: UInt64 = 0
    private var partial = Data()
    private var started = false

    public init(path: String, agent: AgentKind, initialBytes: Int = 8 << 20, limit: Int = 400) {
        self.path = path
        self.agent = agent
        self.initialBytes = initialBytes
        self.limit = limit
    }

    /// Reads what's new. Returns true when `items` changed.
    @discardableResult
    public func update() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { reset() }                      // rewritten or rotated
        var skipFirstLine = false
        if !started {
            started = true
            if size > UInt64(initialBytes) {
                offset = size - UInt64(initialBytes)
                truncated = true
                skipFirstLine = true
            }
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return false }
        offset += UInt64(data.count)
        var buffer = partial + data
        if skipFirstLine, let nl = buffer.firstIndex(of: 0x0A) { buffer = buffer[(nl + 1)...] }
        // Keep an unfinished last line for the next read.
        if let lastNL = buffer.lastIndex(of: 0x0A) {
            partial = Data(buffer[(lastNL + 1)...])
            buffer = buffer[..<lastNL]
        } else {
            partial = Data(buffer)
            return false
        }
        let before = items.count, lastBefore = items.last
        for line in buffer.split(separator: 0x0A) { ingest(Data(line)) }
        if items.count > limit {
            items.removeFirst(items.count - limit)
            truncated = true
        }
        return items.count != before || items.last != lastBefore
    }

    private func reset() {
        items = []
        offset = 0
        partial = Data()
        started = false
        truncated = false
    }

    /// Exposed for tests: parses whole lines without a file.
    public func ingest(lines: [String]) {
        for line in lines { ingest(Data(line.utf8)) }
    }

    private func ingest(_ line: Data) {
        guard !skippable(line), let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let at = (object["timestamp"] as? String).flatMap(Self.date)
        switch agent {
        case .claude: claude(object, at: at)
        case .codex: codex(object, at: at)
        case .chatgpt: break
        }
    }

    /// Lines that can't add a chat item, rejected before decoding: most of a transcript is tool output,
    /// reasoning and token counts.
    private func skippable(_ line: Data) -> Bool {
        func has(_ s: String) -> Bool { line.range(of: Data(s.utf8)) != nil }
        switch agent {
        case .claude:
            if !has(#""type":"user""#) && !has(#""type":"assistant""#) { return true }
            return has(#""tool_result""#) && !has(#""type":"text""#) && !has("[Request interrupted")
        case .codex:
            return [#""type":"reasoning""#, #""type":"token_count""#, #""type":"turn_context""#, #"_call_output""#,
                    #""type":"world_state""#, #""type":"token_usage_record""#].contains(where: has)
        case .chatgpt:
            return true
        }
    }

    // MARK: Claude

    private func claude(_ object: [String: Any], at: Date?) {
        let type = object["type"] as? String
        guard type == "user" || type == "assistant", object["isMeta"] as? Bool != true,
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return }
        let uuid = object["uuid"] as? String ?? UUID().uuidString
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = message["content"] as? String
            ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if type == "user" {
            let t = Self.strippingContext(text)
            if t.hasPrefix("[Request interrupted by user") {
                append(ChatItem(id: uuid, kind: .interrupted, text: "Interrupted", at: at))
            } else if !t.isEmpty, !Self.isHarnessText(t) {
                append(ChatItem(id: uuid, kind: .user, text: t, at: at))
            }
            return
        }
        // One API message arrives as several transcript lines (one per content block); merge its text.
        let messageID = message["id"] as? String
        if !text.isEmpty {
            if let messageID, let last = items.last, last.kind == .assistant, last.id.hasPrefix("msg:" + messageID + "#") {
                items[items.count - 1].text += "\n" + text
            } else {
                append(ChatItem(id: "msg:" + (messageID ?? "") + "#" + uuid, kind: .assistant, text: text, at: at))
            }
        }
        for block in blocks where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? "Tool"
            append(ChatItem(id: block["id"] as? String ?? uuid + name, kind: .tool, text: name,
                            detail: Self.toolDetail(name: name, input: block["input"] as? [String: Any]), at: at))
        }
    }

    // MARK: Codex

    private func codex(_ object: [String: Any], at: Date?) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        let type = object["type"] as? String, payloadType = payload["type"] as? String
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? (object["timestamp"] as? String ?? "") + (payloadType ?? "")
        if type == "event_msg", payloadType == "turn_aborted" {
            append(ChatItem(id: "abort:" + (payload["turn_id"] as? String ?? id), kind: .interrupted, text: "Interrupted", at: at))
            return
        }
        guard type == "response_item" else { return }
        switch payloadType {
        case "message":
            let role = payload["role"] as? String
            let text = (payload["content"] as? [[String: Any]] ?? [])
                .filter { ["input_text", "output_text", "text"].contains($0["type"] as? String ?? "") }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if role == "assistant" {
                append(ChatItem(id: id, kind: .assistant, text: text, at: at))
            } else if role == "user", !Self.isHarnessText(text) {
                append(ChatItem(id: id, kind: .user, text: text, at: at))
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = (payload["name"] as? String).map { $0.components(separatedBy: ".").last ?? $0 } ?? "shell"
            // Code-mode calls wrap the real tool in JavaScript: `tools.exec_command({cmd:"git status"})`.
            if name == "exec", let code = payload["input"] as? String {
                let command = Self.firstMatch(#"cmd:\s*"((?:[^"\\]|\\.)*)""#, in: code)
                    .map { $0.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: " ") }
                let inner = Self.firstMatch(#"tools\.([A-Za-z_]+)\("#, in: code)
                append(ChatItem(id: id, kind: .tool, text: command != nil ? "Shell" : inner ?? "exec",
                                detail: command.map { String($0.prefix(160)) }, at: at))
                return
            }
            var input = payload["arguments"] ?? payload["input"] ?? payload["action"]
            if let s = input as? String, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { input = j }
            var detail = Self.toolDetail(name: name, input: input as? [String: Any])
            if detail == nil, name == "apply_patch", let patch = input as? String {
                detail = patch.components(separatedBy: .newlines)
                    .compactMap { line in ["*** Add File: ", "*** Update File: "].first { line.hasPrefix($0) }.map { String(line.dropFirst($0.count)) } }
                    .map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            }
            append(ChatItem(id: id, kind: .tool, text: name, detail: detail, at: at))
        default:
            break
        }
    }

    // MARK: Helpers

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func append(_ item: ChatItem) {
        if let i = items.lastIndex(where: { $0.id == item.id }), items.count - i < 8 { items[i] = item; return }
        items.append(item)
    }

    /// Your words without the context an editor puts in front of them (`<ide_opened_file>…</ide_opened_file>`).
    public static func strippingContext(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let tag = firstMatch(#"^<(ide_[a-z_]+|system-reminder)>"#, in: t),
              let end = t.range(of: "</\(tag)>") {
            t = String(t[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// Text the harness adds to the user side: injected context, slash-command output, task notices.
    static func isHarnessText(_ t: String) -> Bool {
        let prefixes = ["<environment_context>", "<user_instructions>", "<permissions instructions>", "# AGENTS.md",
                        "<task-notification>", "<local-command-stdout>", "<local-command-stderr>", "<command-name>",
                        "<command-message>", "Caveat: ", "<system-reminder>", "<turn_aborted>", "<skills_instructions>"]
        if prefixes.contains(where: { t.hasPrefix($0) }) { return true }
        // A message that is one wrapping tag (`<external_codex_apps_open_page>…</…>`) is injected context.
        return firstMatch(#"^<([a-z_\-]+)[^>]*>[\s\S]*</\1>$"#, in: t) != nil
    }

    /// A short argument for a tool row: the file it touched, the command it ran, the pattern it searched.
    static func toolDetail(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String {
            return (path as NSString).lastPathComponent
        }
        if let command = input["command"] as? String { return firstLine(command) }
        if let command = input["command"] as? [String] { return String(command.joined(separator: " ").prefix(160)) }
        if let cmd = input["cmd"] as? String { return firstLine(cmd) }
        for key in ["pattern", "query", "url", "description", "prompt"] {
            if let v = input[key] as? String { return firstLine(v) }
        }
        return nil
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        return String(line.prefix(160))
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }
}
