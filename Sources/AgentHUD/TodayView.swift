import AgentHUDCore
import SwiftUI

/// Where today's agent time went, by project: the numbers a timesheet needs, in the list's place.
/// Active time comes from the transcripts (like the dashboard), so parallel sessions in a project count once.
struct TodayView: View {
    let model: AppModel
    var forSnapshot = false
    @State private var expanded: Set<String> = []
    @State private var copied = false

    private static let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .cyan, .mint, .brown]

    var body: some View {
        let report = model.history.today
        let projects = (report?.projects ?? []).filter { $0.active >= 60 }
        VStack(spacing: 0) {
            header(report)
            Divider().opacity(0.5)
            Group {
                if forSnapshot {
                    content(report, projects)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical) { content(report, projects) }
                }
            }
            Divider().opacity(0.5)
            footer(report, projects)
        }
        .onAppear { if !forSnapshot { model.history.refreshIfOlder(than: 30) } }
        .task {
            while !Task.isCancelled && !forSnapshot {
                try? await Task.sleep(for: .seconds(60))
                model.history.refresh()
            }
        }
    }

    private func header(_ report: HistoryReport?) -> some View {
        HStack(spacing: 7) {
            Button { model.mode = .list } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Back to sessions")
            .accessibilityLabel("Back to sessions")
            Text("Today's time").font(.system(size: 13, weight: .semibold))
            if model.history.indexing && report == nil { ProgressView().controlSize(.small).scaleEffect(0.7) }
            Spacer(minLength: 4)
            Text(model.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ report: HistoryReport?, _ projects: [HistoryReport.Project]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report {
                summary(report, projects)
                if projects.isEmpty {
                    Text("No agent time yet today.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                            projectRow(p, color: Self.palette[i % Self.palette.count], total: report.active, report: report)
                        }
                    }
                }
            } else {
                Text("Reading transcripts…").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding(12)
    }

    private func summary(_ r: HistoryReport, _ projects: [HistoryReport.Project]) -> some View {
        let waiting = model.today().waiting
        let sessions = Set(r.sessions.filter { $0.active > 0 }.map(\.id)).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(longDuration(r.active)).font(.system(size: 26, weight: .bold).monospacedDigit())
                Text(hours(r.active)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("\(projects.count) project\(projects.count == 1 ? "" : "s") · \(sessions) session\(sessions == 1 ? "" : "s")"
                 + (waiting >= 60 ? " · \(shortDuration(waiting)) waiting on you" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            // One bar for the day, split by project in the same colors as the rows.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.palette[i % Self.palette.count])
                            .frame(width: max(3, (geo.size.width - CGFloat(projects.count - 1) * 2) * share(p.active, of: projectTotal(projects))))
                    }
                }
            }
            .frame(height: 8)
            .opacity(projects.isEmpty ? 0 : 1)
        }
    }

    private func projectRow(_ p: HistoryReport.Project, color: Color, total: TimeInterval, report: HistoryReport) -> some View {
        let open = expanded.contains(p.root)
        let sessions = report.sessions.filter { $0.root == p.root && $0.active > 0 }.sorted { $0.start < $1.start }
        let waited = model.today().projects.first { $0.project == (p.root as NSString).lastPathComponent }?.waiting ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { expanded.remove(p.root) } else { expanded.insert(p.root) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 10)
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                        Text(p.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(longDuration(p.active)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .lineLimit(1).fixedSize()
                        Text(hours(p.active)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(0.85))
                            .frame(width: max(3, geo.size.width * share(p.active, of: total)))
                    }
                    .frame(height: 4)
                    .padding(.leading, 26)
                    Text(detailLine(p, sessions: sessions.count, waited: waited))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, 26)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(p.root)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(sessions) { s in sessionLine(s) }
                }
                .padding(.leading, 26)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(open ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sessionLine(_ s: HistoryReport.SessionRow) -> some View {
        HStack(spacing: 6) {
            Text("\(s.start.formatted(date: .omitted, time: .shortened))–\(s.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            AgentBadge(agent: s.agent)
            Text(s.title ?? "Untitled conversation").font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(longDuration(s.active)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
        }
        .help(s.sessionId)
        .contextMenu {
            Button("Copy Session ID") { copy(s.sessionId) }
            Button("Copy Resume Command") {
                let cmd = Launcher.shellCommand(agent: s.agent, sessionId: s.sessionId)
                copy("cd \(Launcher.quote(s.launchDir ?? s.root)) && \(cmd)")
            }
        }
    }

    private func footer(_ report: HistoryReport?, _ projects: [HistoryReport.Project]) -> some View {
        HStack(spacing: 8) {
            Button { copyTimesheet(report, projects) } label: {
                Label(copied ? "Copied" : "Copy as text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(projects.isEmpty)
            .help("Each project's time, one per line, for a timesheet or standup")
            Spacer()
            Button("Dashboard") { model.openDashboard() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.leading, 12)
        .padding(.trailing, 22) // clear of the resize grip
        .padding(.vertical, 7)
    }

    private func detailLine(_ p: HistoryReport.Project, sessions: Int, waited: TimeInterval) -> String {
        var parts = ["\(sessions) session\(sessions == 1 ? "" : "s")"]
        if p.tokens.total > 0 { parts.append("\(compactTokens(p.tokens.total)) tokens") }
        if waited >= 60 { parts.append("waited \(shortDuration(waited))") }
        parts.append("\(p.first.formatted(date: .omitted, time: .shortened))–\(p.last.formatted(date: .omitted, time: .shortened))")
        return parts.joined(separator: " · ")
    }

    private func projectTotal(_ projects: [HistoryReport.Project]) -> TimeInterval { projects.reduce(0) { $0 + $1.active } }

    private func share(_ part: TimeInterval, of whole: TimeInterval) -> CGFloat {
        whole > 0 ? CGFloat(min(1, part / whole)) : 0
    }

    /// Decimal hours, the way timesheets want them: "3.1 h".
    private func hours(_ t: TimeInterval) -> String { String(format: "%.1f h", t / 3600) }

    private func compactTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fk", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    private func copyTimesheet(_ report: HistoryReport?, _ projects: [HistoryReport.Project]) {
        guard let report else { return }
        let width = projects.map(\.name.count).max() ?? 0
        var lines = ["Agent time, \(model.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): \(longDuration(report.active)) (\(hours(report.active)))"]
        for p in projects {
            lines.append(p.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + longDuration(p.active)
                         + "  (\(hours(p.active)))")
        }
        copy(lines.joined(separator: "\n"))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
