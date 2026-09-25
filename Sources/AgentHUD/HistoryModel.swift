import AgentHUDCore
import Foundation
import Observation

enum DashboardRange: String, CaseIterable {
    case today, week, month, all

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .all: "All"
        }
    }

    func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all: return .distantPast
        }
    }
}

/// Transcript history for the dashboard, indexed and summarized off the main thread.
@MainActor
@Observable
final class HistoryModel {
    private let settings: AppSettings
    private(set) var report: HistoryReport?
    private(set) var indexing = false
    private(set) var updatedAt: Date?
    @ObservationIgnored private var index: HistoryIndex?
    @ObservationIgnored private let queue = DispatchQueue(label: "agenthud.history", qos: .utility)
    @ObservationIgnored private var pending = false

    init(settings: AppSettings) { self.settings = settings }

    var range: DashboardRange {
        get { DashboardRange(rawValue: settings.dashboardRange) ?? .today }
        set { settings.dashboardRange = newValue.rawValue; refresh(reindex: false) }
    }

    var idleGapMinutes: Double {
        get { settings.idleGapMinutes }
        set { settings.idleGapMinutes = newValue; refresh(reindex: false) }
    }

    /// Picks up new transcript lines (cheap after the first run) and rebuilds the report for the range.
    func refresh(reindex: Bool = true) {
        guard !indexing else { pending = true; return }
        indexing = true
        let start = range.start(now: Date()), gap = settings.idleGapMinutes * 60
        let existing = index
        queue.async { [weak self] in
            let index = existing ?? HistoryIndex()
            if reindex || existing == nil { index.refresh() }
            let report = index.report(from: start, to: Date(), idleGap: gap)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.index = index
                    self.report = report
                    self.updatedAt = Date()
                    self.indexing = false
                    if self.pending { self.pending = false; self.refresh(reindex: false) }
                }
            }
        }
    }

    /// Synchronous, for `--snapshot`.
    func loadNow() {
        let index = self.index ?? HistoryIndex()
        index.refresh()
        self.index = index
        report = index.report(from: range.start(now: Date()), to: Date(), idleGap: settings.idleGapMinutes * 60)
    }
}
