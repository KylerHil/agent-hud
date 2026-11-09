import Darwin
import Foundation

struct PortActionError: Error { var message: String; init(_ message: String) { self.message = message } }

public struct PortStopRequest: Identifiable, Sendable {
    public let endpoint: PortEndpoint
    public let affectedBindings: [PortBinding]
    public let force: Bool
    public var id: String { endpoint.id + (force ? ":force" : ":stop") }
    public init(endpoint: PortEndpoint, endpoints: [PortEndpoint], force: Bool = false) {
        self.endpoint = endpoint; self.force = force
        let affected = endpoints.filter { row in
            if let container = endpoint.container { return row.container?.id == container.id && row.container?.context == container.context }
            return !Set(row.owners).isDisjoint(with: endpoint.owners)
        }
        self.affectedBindings = Array(Set(affected.flatMap(\.bindings))).sorted { $0.display < $1.display }
    }
}

public enum PortStopResult: Equatable, Sendable { case stopped, stillRunning, failed(String) }

public enum PortTermination {
    public static func perform(_ request: PortStopRequest, grace: TimeInterval = 3) -> PortStopResult {
        let endpoint = request.endpoint
        if endpoint.container != nil { return DockerPorts.stop(request) }
        guard endpoint.stopUnavailableReason == nil else { return .failed(endpoint.stopUnavailableReason!) }
        let current = PortScanner.native(includeUDP: true)
        guard current.endpoints.contains(where: { $0.id == endpoint.id }) else {
            return .failed("Port ownership changed. Refresh and review the process before stopping it.")
        }
        let affected = current.endpoints.filter { !Set($0.owners).isDisjoint(with: endpoint.owners) }.flatMap(\.bindings)
        guard Set(affected) == Set(request.affectedBindings) else {
            return .failed("This process’s ports changed. Review its current ports before stopping it.")
        }
        var errors: [String] = []
        for identity in endpoint.owners {
            // Revalidate immediately before each positive-PID signal; never kill a process group.
            guard identity.pid > 1, identity.stopUnavailableReason == nil,
                  PortProcessIdentity.read(identity.pid) == identity else {
                errors.append("Process \(identity.pid) changed or is no longer available."); continue
            }
            let bound = PortScanner.sockets(pid: identity.pid, includeUDP: true).0
            guard endpoint.bindings.contains(where: { selected in bound.contains { $0 == selected } }) else {
                errors.append("Process \(identity.pid) no longer owns this port."); continue
            }
            if kill(identity.pid, request.force ? SIGKILL : SIGTERM) != 0, errno != ESRCH {
                errors.append(errno == EPERM ? "macOS did not permit stopping process \(identity.pid)." : "Process \(identity.pid) could not be stopped.")
            }
        }
        let deadline = Date().addingTimeInterval(max(0, grace))
        while Date() < deadline {
            if endpoint.owners.allSatisfy({ !stillAlive($0) }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !errors.isEmpty { return .failed(errors.joined(separator: " ")) }
        return endpoint.owners.contains(where: stillAlive) ? .stillRunning : .stopped
    }

    private static func stillAlive(_ identity: PortProcessIdentity) -> Bool {
        guard let entry = ProcTools.entry(identity.pid) else { return ProcTools.isAlive(identity.pid) }
        // An exec or a new inspection restriction is not evidence that the process exited.
        guard let started = entry.started else { return ProcTools.isAlive(identity.pid) }
        guard started == identity.started else { return false }
        return !entry.zombie
    }
}
