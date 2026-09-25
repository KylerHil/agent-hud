import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef] = []
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x4157_5448 // "AWTH"

    /// A virtual key code (kVK_Space, kVK_ANSI_A, …) with Carbon modifiers (controlKey | optionKey …).
    func register(id: UInt32, keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Agent HUD: could not register hotkey \(id) (status \(status)); another app may own it")
            return
        }
        refs.append(ref)
        handlers[id] = action
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
