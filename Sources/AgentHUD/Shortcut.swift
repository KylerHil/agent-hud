import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut: a virtual key code plus Carbon modifiers, with a label for display.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    /// Carbon modifier mask (controlKey, optionKey, shiftKey, cmdKey).
    var modifiers: Int
    /// What the key prints ("A", "Space", "F5"), captured when recorded.
    var key: String

    static let findDefault = Shortcut(keyCode: kVK_Space, modifiers: controlKey | optionKey, key: "Space")
    static let panelDefault = Shortcut(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey, key: "A")
    static let collapseDefault = Shortcut(keyCode: kVK_ANSI_2, modifiers: optionKey, key: "2")

    /// "⌃⌥Space", in the order macOS menus use.
    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    /// For NSMenuItem: the key equivalent string and modifier mask, when the key has a simple one.
    var menuEquivalent: (String, NSEvent.ModifierFlags)? {
        let k: String
        switch keyCode {
        case kVK_Space: k = " "
        default:
            guard key.count == 1 else { return nil }
            k = key.lowercased()
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return (k, flags)
    }

    /// From a key press while recording. Needs ⌃, ⌥ or ⌘ (a bare letter would steal typing everywhere),
    /// except for function keys.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        let code = Int(event.keyCode)
        let name = Self.specialKeys[code]
        guard mods & (controlKey | optionKey | cmdKey) != 0 || (name?.hasPrefix("F") ?? false) else { return nil }
        let printed = event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard let label = name ?? (printed.isEmpty ? nil : printed) else { return nil }
        self.init(keyCode: code, modifiers: mods, key: label)
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]
}

/// Click, then press the new shortcut. Esc cancels; the reset button restores the default.
struct ShortcutRecorder: View {
    let model: AppModel
    @Binding var shortcut: Shortcut
    let fallback: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            if let hint { Text(hint).font(.caption).foregroundStyle(.orange) }
            Button(recording ? "Press a shortcut…" : shortcut.display) { recording ? stop() : start() }
                .frame(minWidth: 110)
                .help(recording ? "Esc to cancel" : "Click to change")
            if shortcut != fallback && !recording {
                Button { shortcut = fallback } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(fallback.display)")
                    .accessibilityLabel("Reset to \(fallback.display)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        hint = nil
        recording = true
        // Global hotkeys would swallow the very combination being recorded, so pause them.
        model.recordingShortcut = true
        model.actions.focusPanel()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let s = Shortcut(event: event) {
                shortcut = s
                stop()
            } else {
                hint = "Include ⌃, ⌥ or ⌘"
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        model.recordingShortcut = false
    }
}
