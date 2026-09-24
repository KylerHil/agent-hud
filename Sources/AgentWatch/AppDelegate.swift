import AgentWatchCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var model = AppModel(settings: settings)
    var panel: PanelController!
    var statusItem: NSStatusItem!
    var notifier: Notifier!
    lazy var settingsWindow = SettingsWindowController { [unowned self] in
        AnyView(SettingsView(settings: settings, hooks: HooksPane()))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        notifier = Notifier(model: model)
        model.onTransition = { [unowned self] t, s in notifier.handle(t, s) }
        model.onTick = { [unowned self] in notifier.tick() }
        setUpStatusItem()
        model.start()
        if settings.panelVisible { panel.show() }
    }

    /// Opening the app again (Finder, Spotlight) while it runs brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        observeCounts()
    }

    private func observeCounts() {
        withObservationTracking { _ = model.counts } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeCounts()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let n = model.counts.attention
        let symbol = n > 0 ? "exclamationmark.bubble.fill" : "eye"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AgentWatch")
        image?.isTemplate = n == 0
        button.image = n > 0 ? image?.withSymbolConfiguration(.init(paletteColors: [.white, .systemOrange])) : image
        button.title = n > 0 ? " \(n)" : ""
        button.imagePosition = .imageLeading
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = model.counts
        let summary = NSMenuItem(title: "\(c.attention) need input · \(c.running) running · \(c.idle) idle",
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        // Sessions waiting on you, one click away.
        let waiting = model.rows.filter { model.displayState($0) == .needsInput }
        for s in waiting {
            let item = NSMenuItem(title: "\(s.projectName) — \(s.primaryPending?.reason ?? "needs input")",
                                  action: #selector(focusSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, panel.isVisible ? "Hide Panel" : "Show Panel", #selector(togglePanel), "p")
        add(menu, settings.collapsed ? "Expand Panel" : "Collapse to Pill", #selector(toggleCollapsed), "")
        add(menu, "Show Idle Sessions", #selector(toggleShowIdle), "").state = settings.showIdle ? .on : .off
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "Open Event Log", #selector(openLog), "")
        menu.addItem(.separator())
        add(menu, "Quit AgentWatch", #selector(quit), "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = model.store.sessions[id] else { return }
        Focuser.focus(s)
    }

    @objc func togglePanel() { panel.toggle() }
    @objc func toggleCollapsed() { settings.collapsed.toggle(); panel.show() }
    @objc func toggleShowIdle() { settings.showIdle.toggle() }
    @objc func openSettings() { settingsWindow.show() }
    @objc func openLog() { NSWorkspace.shared.activateFileViewerSelecting([Paths.eventsFile]) }
    @objc func quit() { NSApp.terminate(nil) }
}
