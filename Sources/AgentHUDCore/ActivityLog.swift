import Foundation

/// A stretch of time one session spent in one state.
public struct ActivitySegment: Equatable, Sendable {
    public var state: SessionState
    public var start: Date
    public var end: Date?
    /// For waits: what the agent asked for.
    public var reason: String?
}

/// Per-session state history built from transitions, for the Today view and the panel footer.
/// Replayed history (the last 24 h of the event log) counts too, so it survives restarts.
public final class ActivityLog {
    public struct Track: Equatable, Sendable {
        public var sessionID: String
        public var project: String
        public var agent: AgentKind
        public var segments: [ActivitySegment] = []
    }

    public private(set) var tracks: [String: Track] = [:]

    public init() {}

    public func record(_ t: Transition, session s: Session) {
        var track = tracks[t.sessionID] ?? Track(sessionID: t.sessionID, project: s.projectName, agent: s.agent)
        track.project = s.projectName
        if let last = track.segments.indices.last, track.segments[last].end == nil {
            track.segments[last].end = t.at
        }
        if t.to != .ended {
            let reason = t.to == .needsInput ? s.primaryPending?.reason : nil
            track.segments.append(ActivitySegment(state: t.to, start: t.at, reason: reason))
        }
        tracks[t.sessionID] = track
    }

    public func remove(_ sessionID: String) { tracks.removeValue(forKey: sessionID) }

    /// Forget anything that ended before `cutoff`.
    public func prune(before cutoff: Date) {
        for (id, var track) in tracks {
            track.segments.removeAll { ($0.end ?? .distantFuture) < cutoff }
            if track.segments.isEmpty { tracks.removeValue(forKey: id) } else { tracks[id] = track }
        }
    }

    public func summary(from start: Date, to now: Date) -> ActivitySummary {
        var lanes: [ActivitySummary.Lane] = []
        var waits: [ActivitySummary.Wait] = []
        var projects: [String: ActivitySummary.ProjectRow] = [:]
        for track in tracks.values {
            var clipped: [ActivitySegment] = []
            for seg in track.segments {
                let a = max(seg.start, start), b = min(seg.end ?? now, now)
                guard b > a else { continue }
                var c = seg
                c.start = a
                c.end = b
                clipped.append(c)
            }
            // Sessions that only sat idle (or were process placeholders) aren't activity.
            let active = clipped.filter { [.running, .needsInput].contains($0.state) }
            guard !active.isEmpty, let first = clipped.first?.start, let last = clipped.last?.end else { continue }
            var row = projects[track.project] ?? .init(project: track.project)
            row.sessions += 1
            for seg in clipped {
                let d = seg.end!.timeIntervalSince(seg.start)
                switch seg.state {
                case .running:
                    row.working += d
                case .needsInput:
                    row.waiting += d
                    row.longestWait = max(row.longestWait, d)
                    // Only answered waits count toward response times; one still open is ongoing.
                    if track.segments.contains(where: { $0.start == seg.start && $0.end != nil }) {
                        waits.append(.init(duration: d, project: track.project, reason: seg.reason))
                    }
                default: break
                }
            }
            projects[track.project] = row
            lanes.append(.init(sessionID: track.sessionID, project: track.project, agent: track.agent,
                               first: first, last: last, segments: active))
        }
        lanes.sort { $0.first < $1.first }
        return ActivitySummary(lanes: lanes, waits: waits,
                               projects: projects.values.sorted { $0.working + $0.waiting > $1.working + $1.waiting })
    }
}

public struct ActivitySummary: Equatable, Sendable {
    public struct Lane: Equatable, Sendable, Identifiable {
        public var id: String { sessionID }
        public var sessionID: String
        public var project: String
        public var agent: AgentKind
        public var first: Date
        public var last: Date
        public var segments: [ActivitySegment]
    }

    public struct Wait: Equatable, Sendable {
        public var duration: TimeInterval
        public var project: String
        public var reason: String?
    }

    public struct ProjectRow: Equatable, Sendable, Identifiable {
        public var id: String { project }
        public var project: String
        public var sessions = 0
        public var working: TimeInterval = 0
        public var waiting: TimeInterval = 0
        public var longestWait: TimeInterval = 0
    }

    public var lanes: [Lane]
    public var waits: [Wait]
    public var projects: [ProjectRow]

    public init(lanes: [Lane], waits: [Wait], projects: [ProjectRow]) {
        self.lanes = lanes
        self.waits = waits
        self.projects = projects
    }

    public var working: TimeInterval { projects.reduce(0) { $0 + $1.working } }
    public var waiting: TimeInterval { projects.reduce(0) { $0 + $1.waiting } }
    public var medianWait: TimeInterval? {
        guard !waits.isEmpty else { return nil }
        let d = waits.map(\.duration).sorted()
        return d.count % 2 == 1 ? d[d.count / 2] : (d[d.count / 2 - 1] + d[d.count / 2]) / 2
    }
    public var longestWait: Wait? { waits.max { $0.duration < $1.duration } }
}
