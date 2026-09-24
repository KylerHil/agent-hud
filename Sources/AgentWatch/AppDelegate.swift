import AgentWatchCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var model = AppModel(settings: settings)
    var panel: PanelController!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        setUpStatusItem()
        model.start()
        if settings.panelVisible { panel.show() }
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
        menu.addItem(.separator())
        add(menu, panel.isVisible ? "Hide Panel" : "Show Panel", #selector(togglePanel), "p")
        add(menu, settings.collapsed ? "Expand Panel" : "Collapse to Pill", #selector(toggleCollapsed), "")
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

    @objc func togglePanel() { panel.toggle() }
    @objc func toggleCollapsed() { settings.collapsed.toggle(); panel.show() }
    @objc func quit() { NSApp.terminate(nil) }
}
