import AgentHUDCore
import AppKit
import Charts
import SwiftUI

/// The panel's dashboard: time and tokens by project and day, from the agents' own transcripts,
/// plus today's live timeline with the time sessions spent waiting on you.
struct DashboardView: View {
    let model: AppModel
    var forSnapshot = false
    @State private var selectedProject: String?
    @State private var hoveredDay: Date?
    @State private var exported: URL?

    private var history: HistoryModel { model.history }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            filterBar
            Divider().opacity(0.5)
            if forSnapshot {
                content
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) { content }
            }
        }
        .onAppear { if !forSnapshot { history.refresh() } }
        .task {
            // Keep today's numbers moving while the dashboard is open.
            while !Task.isCancelled && !forSnapshot {
                try? await Task.sleep(for: .seconds(60))
                history.refresh()
            }
        }
    }

    // MARK: Header and filters

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.mode = .list } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Back to sessions")
            .accessibilityLabel("Back to sessions")
            Text("Dashboard").font(.system(size: 13, weight: .semibold))
            if history.indexing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(history.report == nil ? "Reading transcripts…" : "Updating…")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let exported {
                Button { NSWorkspace.shared.activateFileViewerSelecting([exported]) } label: {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.green)
                .help(exported.path)
            }
            Button { export() } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(history.report?.sessions.isEmpty ?? true)
            .help("Save one row per session to your Downloads folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Range and idle gap live in their own strip, apart from the numbers they control.
    private var filterBar: some View {
        HStack(spacing: 14) {
            Text("Range").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Picker("Range", selection: Binding(get: { history.range }, set: { history.range = $0; selectedProject = nil })) {
                ForEach(DashboardRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            Text("Break after").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Picker("Idle gap", selection: Binding(get: { history.idleGapMinutes }, set: { history.idleGapMinutes = $0 })) {
                ForEach([5.0, 10, 15, 30], id: \.self) { Text("\(Int($0)) min").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("A silence longer than this between transcript events counts as a break, not active time")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let r = history.report
        VStack(alignment: .leading, spacing: 16) {
            tiles(r)
            card {
                if history.range == .today {
                    TodayTimeline(model: model)
                } else if let r {
                    dailyChart(r)
                } else {
                    Text("Reading transcripts…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let r {
                card { projectsTable(r) }
                card { sessionsList(r) }
            } else if !history.indexing {
                Text("No transcripts found in ~/.claude/projects or ~/.codex/sessions.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            footnote
        }
        .padding(16)
    }

    private func card(@ViewBuilder _ body: () -> some View) -> some View {
        body()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func sectionTitle(_ title: String, _ detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
    }

    private func tiles(_ r: HistoryReport?) -> some View {
        let t = model.today()
        let busiest = r?.days.max { $0.active < $1.active }
        return HStack(spacing: 10) {
            tile("Active time", r.map { longDuration($0.active) } ?? "—",
                 r.map { "\($0.projects.filter { $0.active > 0 }.count) projects" } ?? " ")
            tile("Sessions", r.map { "\($0.sessions.count)" } ?? "—",
                 r.map { "\(Set($0.sessions.map(\.agent)).map(\.displayName).sorted().joined(separator: " · "))" } ?? " ")
            tile("Tokens", r.map { compact($0.tokens.total) } ?? "—",
                 r.map { "\(compact($0.tokens.input + $0.tokens.cacheWrite)) in · \(compact($0.tokens.output)) out · \(compact($0.tokens.cacheRead)) cached" } ?? " ",
                 help: "Input and cache-write tokens, output tokens, and cache reads, each API message counted once")
            if history.range == .today {
                tile("Waiting on you", shortDuration(t.waiting),
                     t.medianWait.map { "median \(shortDuration($0)) · \(t.waits.count) answered" } ?? "\(t.waits.count) answered")
            } else {
                tile("Busiest day", busiest.map { longDuration($0.active) } ?? "—",
                     busiest.map { $0.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? " ")
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ sub: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .help(help ?? "")
    }

    // MARK: Daily chart

    private func dailyChart(_ r: HistoryReport) -> some View {
        let days = r.days
        let hovered = days.first { $0.day == hoveredDay }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Active time by day")
                Spacer()
                Text(hovered.map(dayCaption) ?? " ")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Chart(days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", d.active / 3600))
                    .foregroundStyle(Color.accentColor.opacity(hoveredDay == nil || hoveredDay == d.day ? 1 : 0.45))
                    .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days.count > 14 ? 7 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 150)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let p) = phase, let frame = proxy.plotFrame.map({ geo[$0] }),
                                  let date: Date = proxy.value(atX: p.x - frame.minX) else { hoveredDay = nil; return }
                            hoveredDay = Calendar.current.startOfDay(for: date)
                        }
                }
            }
        }
    }

    private func dayCaption(_ d: HistoryReport.Day) -> String {
        let top = d.projects.prefix(3).map { "\($0.name) \(shortDuration($0.active))" }.joined(separator: ", ")
        return d.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ": "
            + longDuration(d.active) + (top.isEmpty ? "" : " · " + top)
    }

    // MARK: Tables

    private func projectsTable(_ r: HistoryReport) -> some View {
        let rows = r.projects.filter { $0.active > 0 || $0.tokens.total > 0 }
        let maxActive = rows.map(\.active).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Projects", "click one to see its sessions")
                Spacer()
                if selectedProject != nil {
                    Button("Show all") { selectedProject = nil }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text("Project")
                    Text("Active").gridColumnAlignment(.trailing)
                    Text("")
                    Text("Days").gridColumnAlignment(.trailing)
                    Text("Sessions").gridColumnAlignment(.trailing)
                    Text("Tokens").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { p in
                    GridRow {
                        Text(p.name).fontWeight(.semibold).lineLimit(1)
                        Text(longDuration(p.active))
                        Capsule().fill(Color.accentColor.opacity(0.8))
                            .frame(width: max(2, 120 * p.active / max(maxActive, 1)), height: 5)
                            .frame(width: 120, alignment: .leading)
                        Text("\(p.days)")
                        Text("\(p.sessions)")
                        Text(compact(p.tokens.total))
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .padding(.vertical, 7)
                    .background(selectedProject == p.root ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedProject = selectedProject == p.root ? nil : p.root }
                    .help(p.root)
                    Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private func sessionsList(_ r: HistoryReport) -> some View {
        let rows = r.sessions.filter { (selectedProject == nil || $0.root == selectedProject) && ($0.active > 0 || $0.tokens.total > 0) }
        let shown = Array(rows.prefix(forSnapshot ? 6 : 150))
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(selectedProject.map { "Sessions in \(($0 as NSString).lastPathComponent)" } ?? "Sessions",
                         "\(rows.count) · right-click for the ID or resume command")
            HStack(spacing: 10) {
                Text("When").frame(width: 170, alignment: .leading)
                Text("Project")
                Spacer()
                Text("Session").frame(width: 76, alignment: .leading)
                Text("Tokens").frame(width: 52, alignment: .trailing)
                Text("Active").frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Divider()
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text(s.start.formatted(.dateTime.month(.abbreviated).day())).frame(width: 44, alignment: .leading)
                        Text("\(s.start.formatted(date: .omitted, time: .shortened))–\(s.end.formatted(date: .omitted, time: .shortened))")
                    }
                    .frame(width: 170, alignment: .leading)
                    .foregroundStyle(.secondary)
                    AgentBadge(agent: s.agent)
                    Text(s.project).fontWeight(.medium).lineLimit(1)
                    if let m = s.model { Text(m).foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer(minLength: 6)
                    Text(String(s.sessionId.prefix(8)))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                        .help(s.sessionId)
                    Text(compact(s.tokens.total)).frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
                    Text(longDuration(s.active)).frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 11).monospacedDigit())
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(i % 2 == 1 ? Color.primary.opacity(0.03) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contextMenu {
                    Button("Copy Session ID") { copy(s.sessionId) }
                    Button("Copy Resume Command") {
                        copy(s.agent == .codex ? "codex resume \(s.sessionId)" : "cd '\(s.root)' && claude --resume \(s.sessionId)")
                    }
                }
            }
            if rows.count > shown.count {
                Text("\(rows.count - shown.count) more in the CSV export").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var footnote: some View {
        Text("Active time is the time between an agent's transcript events, merged across a project's sessions so parallel sessions count once; a silence longer than the break setting above isn't counted. It comes from ~/.claude/projects and ~/.codex/sessions, so it covers sessions from before Agent HUD was running.")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fk", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    /// Straight to ~/Downloads (no save dialog: nothing opens outside the panel), then offer to reveal it.
    private func export() {
        guard let r = history.report else { return }
        let name = "AgentHUD-\(history.range.rawValue)-\(Date().formatted(.iso8601.year().month().day())).csv"
        let url = Paths.userHome.appendingPathComponent("Downloads").appendingPathComponent(name)
        do {
            try r.csv().write(to: url, atomically: true, encoding: .utf8)
            exported = url
        } catch {
            exported = nil
            NSLog("Agent HUD: CSV export failed: \(error.localizedDescription)")
        }
    }
}

/// Today's sessions as lanes: green while working, orange while waiting on you (from AgentHUD's own log).
struct TodayTimeline: View {
    let model: AppModel
    @State private var hovered: String?

    private struct Bar: Identifiable {
        var id: String
        var lane: String
        var state: SessionState
        var start: Date
        var end: Date
        var reason: String?
    }

    var body: some View {
        let t = model.today()
        let names = laneNames(t)
        let bars = t.lanes.flatMap { lane in
            lane.segments.enumerated().map { i, seg in
                Bar(id: "\(lane.sessionID)-\(i)", lane: names[lane.sessionID] ?? lane.project, state: seg.state,
                    start: seg.start, end: seg.end ?? model.now, reason: seg.reason)
            }
        }
        let start = t.lanes.map(\.first).min().map { Calendar.current.dateInterval(of: .hour, for: $0)?.start ?? $0 }
            ?? Calendar.current.startOfDay(for: model.now)
        let end = model.now.addingTimeInterval(max(300, model.now.timeIntervalSince(start) * 0.03))
        let span = end.timeIntervalSince(start)
        let tickMinutes = span <= 2 * 3600 ? 15 : span <= 6 * 3600 ? 60 : 120
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Today by session").font(.system(size: 12, weight: .semibold))
                legend(.green, "Working")
                legend(.orange, "Waiting on you")
                Spacer()
                Text(hovered ?? " ").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            if t.lanes.isEmpty {
                Text("No agent activity yet today.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart {
                    ForEach(t.lanes) { lane in
                        RuleMark(xStart: .value("From", lane.first), xEnd: .value("To", lane.last),
                                 y: .value("Session", names[lane.sessionID] ?? lane.project))
                            .foregroundStyle(Color.primary.opacity(0.18))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(bars) { b in
                        BarMark(xStart: .value("From", b.start), xEnd: .value("To", b.end), y: .value("Session", b.lane),
                                height: .fixed(12))
                            .foregroundStyle(b.state == .needsInput ? Color.orange : Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    RuleMark(x: .value("Now", model.now))
                        .foregroundStyle(Color.blue.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartXScale(domain: start...end)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: tickMinutes)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: CGFloat(max(t.lanes.count, 2)) * 24 + 30)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let p) = phase, let frame = proxy.plotFrame.map({ geo[$0] }),
                                      let date: Date = proxy.value(atX: p.x - frame.minX),
                                      let lane: String = proxy.value(atY: p.y - frame.minY) else { hovered = nil; return }
                                if let b = bars.first(where: { $0.lane == lane && $0.start <= date && date <= $0.end }) {
                                    let what = b.state == .needsInput ? "waiting" + (b.reason.map { " · \($0)" } ?? "") : "working"
                                    hovered = "\(lane): \(what) \(shortDuration(b.end.timeIntervalSince(b.start))) from "
                                        + b.start.formatted(date: .omitted, time: .shortened)
                                } else {
                                    hovered = "\(lane): idle"
                                }
                            }
                    }
                }
            }
        }
    }

    private func laneNames(_ t: ActivitySummary) -> [String: String] {
        var seen: [String: Int] = [:]
        var names: [String: String] = [:]
        for lane in t.lanes {
            let n = (seen[lane.project] ?? 0) + 1
            seen[lane.project] = n
            names[lane.sessionID] = n == 1 ? lane.project : "\(lane.project) \(n)"
        }
        return names
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}
