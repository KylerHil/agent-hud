import AgentHUDCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Replying to a Claude session that runs in VS Code (or Cursor, Windsurf). The Claude Code extension
/// handles `<scheme>://anthropic.claude-code/open?session=<id>&prompt=<text>`: it opens that conversation and
/// fills its input box (it never sends). When the conversation is already open in a tab, though, it only
/// brings the tab forward and says "Session is already open. Your prompt was not applied".
///
/// So the reply also goes on the clipboard, and with Accessibility Agent HUD checks the editor's focused
/// field before touching it: if it holds the reply, Return sends it; if it's an empty field inside a webview
/// (the Claude panel, never a code editor), the reply is pasted there first. Anything else is left alone.
enum EditorReply {
    enum Outcome: Equatable, Codable {
        /// Return was pressed with the reply in Claude's input.
        case sent
        /// The reply is in Claude's input; you press Return.
        case typed
        /// It couldn't be placed (the conversation was already open, or no Accessibility): it's on the clipboard.
        case clipboard
    }

    /// The editor's URL scheme when this session can take a reply this way.
    static func scheme(_ s: Session) -> String? {
        guard s.agent == .claude, !s.isChat, UUID(uuidString: s.sessionId) != nil else { return nil }
        switch s.hostKind {
        case "vscode": return "vscode"
        case "cursor": return "cursor"
        case "windsurf": return "windsurf"
        default: return nil
        }
    }

    static func url(_ s: Session, text: String) -> URL? {
        guard let scheme = scheme(s) else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = "anthropic.claude-code"
        c.path = "/open"
        c.queryItems = [URLQueryItem(name: "session", value: s.sessionId), URLQueryItem(name: "prompt", value: text)]
        return c.url
    }

    static var canPressReturn: Bool { ChatWatcher.isTrusted }

    /// Brings the session's editor window forward, opens the conversation with `text`, and places and (when
    /// `pressReturn`) sends it where that can be done safely.
    static func deliver(_ s: Session, text: String, pressReturn: Bool, done: @escaping (Outcome) -> Void) {
        guard let url = url(s, text: text) else { return done(.clipboard) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // The right window first: the extension opens the conversation in whichever window gets the URL.
        Focuser.focus(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            if let app = s.hostApp, FileManager.default.fileExists(atPath: app) {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: config)
            } else {
                NSWorkspace.shared.open(url)
            }
            guard canPressReturn else { return done(.clipboard) }
            // Give the webview a moment to show the conversation (and fill its input, when it does).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { place(s, text: text, pressReturn: pressReturn, done: done) }
        }
    }

    private static func place(_ s: Session, text: String, pressReturn: Bool, done: @escaping (Outcome) -> Void) {
        guard let app = frontEditor(s) else { return done(.clipboard) }
        let pid = app.processIdentifier
        let probe = String(text.prefix(40))
        let field = focusedField(pid)
        if field.value?.contains(probe) == true {
            // The extension filled it in.
            if pressReturn { key(kVK_Return, pid: pid); return done(.sent) }
            return done(.typed)
        }
        // Already open: the input is empty. Paste only into a text field inside a webview (the Claude panel).
        guard field.isText, field.inWebview, (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return done(.clipboard)
        }
        key(kVK_ANSI_V, flags: .maskCommand, pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard focusedField(pid).value?.contains(probe) == true else { return done(.clipboard) }
            if pressReturn { key(kVK_Return, pid: pid); done(.sent) } else { done(.typed) }
        }
    }

    /// The session's editor, only while it's the frontmost app: a keystroke must never land anywhere else.
    private static func frontEditor(_ s: Session) -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let expected = s.hostApp.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard let path = front.bundleURL?.standardizedFileURL.path, expected == nil || path == expected else { return nil }
        return front
    }

    struct Field {
        var value: String?
        var isText: Bool
        /// Inside a webview nested in VS Code's own web content: the Claude panel, not a code editor.
        var inWebview: Bool
    }

    static func focusedField(_ pid: pid_t) -> Field {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let el = ref, CFGetTypeID(el) == AXUIElementGetTypeID() else { return Field(value: nil, isText: false, inWebview: false) }
        let element = el as! AXUIElement
        let role = string(element, kAXRoleAttribute)
        let value = string(element, kAXValueAttribute)
        // Count the web areas above it: VS Code's UI is one; a webview panel adds another.
        var webAreas = 0
        var node: AXUIElement? = element
        for _ in 0..<60 {
            guard let n = node else { break }
            if string(n, kAXRoleAttribute) == "AXWebArea" { webAreas += 1 }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(n, kAXParentAttribute as CFString, &parent) == .success, let p = parent else { break }
            node = (p as! AXUIElement)
        }
        return Field(value: value, isText: role == "AXTextArea" || role == "AXTextField", inWebview: webAreas >= 2)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func key(_ code: Int, flags: CGEventFlags = [], pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
