import AgentHUDCore
import Foundation
import Observation

@MainActor
@Observable
final class PortsModel {
    typealias Source = PortFilter
    enum OperationState: Equatable { case stopping(Bool), stillRunning, failed(String) }
    struct Operation { var target: PortEndpoint; var state: OperationState }

    private(set) var snapshot = PortSnapshot()
    private(set) var hasLoaded = false
    private(set) var refreshing = false
    var query = ""
    var source: Source = .all
    var includeUDP = UserDefaults.standard.bool(forKey: "portsIncludeUDP") {
        didSet {
            if oldValue != includeUDP {
                UserDefaults.standard.set(includeUDP, forKey: "portsIncludeUDP")
                cancelRefresh()
            }
        }
    }
    var expanded: Set<String> = []
    var pendingStop: PortStopRequest?
    private(set) var preparing: PortEndpoint?
    private(set) var operations: [String: Operation] = [:]
    var message: String?
    var messageIsError = false
    var projects: [PortProject] = []
    @ObservationIgnored private var refreshWorker: Task<PortSnapshot, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var preparation = UUID()
    @ObservationIgnored private var actionTasks: [String: Task<Void, Never>] = [:]

    var rows: [PortEndpoint] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot.endpoints.filter { endpoint in
            (includeUDP || endpoint.transport == .tcp) && matchesSource(endpoint)
                && (q.isEmpty || searchText(endpoint).contains(q))
        }.sorted { $0.port == $1.port ? $0.id < $1.id : $0.port < $1.port }
    }

    func count(_ source: Source) -> Int {
        snapshot.endpoints.filter { (includeUDP || $0.transport == .tcp) && matchesSource($0, source) }.count
    }

    var hiddenEditorMatches: Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard source != .editor, !q.isEmpty else { return 0 }
        return snapshot.endpoints.filter {
            $0.source == .editor && (includeUDP || $0.transport == .tcp) && searchText($0).contains(q)
        }.count
    }

    private func matchesSource(_ row: PortEndpoint, _ selection: Source? = nil) -> Bool {
        (selection ?? source).includes(row)
    }

    private func searchText(_ row: PortEndpoint) -> String {
        ([String(row.port), row.title, row.subtitle, row.workingDirectory ?? "", row.project?.path ?? "",
          row.container?.name ?? "", row.container?.context ?? "", row.transport.rawValue]
         + row.bindings.map(\.display) + row.owners.map { String($0.pid) }
         + (row.editor?.workspaceFolders ?? [])).joined(separator: " ").lowercased()
    }

    func operation(_ endpoint: PortEndpoint) -> OperationState? {
        operations[endpoint.actionID]?.state
    }

    func busy(_ endpoint: PortEndpoint) -> Bool {
        if let preparing, overlaps(preparing, endpoint) { return true }
        return operations.values.contains { operation in
            if case .stopping = operation.state { return overlaps(operation.target, endpoint) }
            return false
        }
    }

    private func overlaps(_ lhs: PortEndpoint, _ rhs: PortEndpoint) -> Bool {
        lhs.actionID == rhs.actionID || !Set(lhs.owners).isDisjoint(with: rhs.owners)
    }

    func watch() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

    private func cancelRefresh() {
        generation += 1
        refreshWorker?.cancel(); refreshWorker = nil; refreshing = false
    }

    func refresh() async {
        guard refreshWorker == nil, preparing == nil else { return }
        refreshing = true; generation += 1
        let version = generation, udp = includeUDP, known = projects
        let worker = Task.detached(priority: .utility) { PortScanner.scan(includeUDP: udp, projects: known) }
        refreshWorker = worker
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard version == generation else { return }
        refreshWorker = nil; refreshing = false
        guard !Task.isCancelled else { return }
        snapshot = result; hasLoaded = true
        expanded.formIntersection(Set(result.endpoints.map(\.id)))
        operations = operations.filter { key, operation in
            if case .stopping = operation.state { return true }
            return result.endpoints.contains { $0.actionID == key }
        }
    }

    func prepareStop(_ endpoint: PortEndpoint, force: Bool = false) {
        guard pendingStop == nil, preparing == nil, !busy(endpoint), endpoint.stopUnavailableReason == nil else { return }
        cancelRefresh()
        let token = UUID(); preparation = token; preparing = endpoint
        let known = projects
        Task {
            // Discover every affected port, including UDP hidden by the default filter, before confirmation.
            let current = await Task.detached(priority: .utility) {
                endpoint.container == nil ? PortScanner.native(includeUDP: true, projects: known)
                    : PortScanner.scan(includeUDP: true, projects: known)
            }.value
            guard preparation == token else { return }
            preparing = nil
            guard let fresh = current.endpoints.first(where: { $0.id == endpoint.id }) else {
                message = "This port’s owner changed or is no longer available. Refresh and review it again."
                messageIsError = true
                await refresh(); return
            }
            pendingStop = PortStopRequest(endpoint: fresh, endpoints: current.endpoints, force: force)
        }
    }

    func confirmStop(_ selected: PortStopRequest? = nil) {
        guard let request = selected ?? pendingStop else { return }
        pendingStop = nil
        let target = request.endpoint, key = target.actionID
        guard !busy(target) else { return }
        operations[key] = Operation(target: target, state: .stopping(request.force))
        message = nil
        actionTasks[key] = Task {
            let result = await Task.detached(priority: .userInitiated) { PortTermination.perform(request) }.value
            switch result {
            case .stopped: operations.removeValue(forKey: key)
            case .stillRunning: operations[key]?.state = request.force
                    ? .failed("The process is still present. Refresh to check its state.") : .stillRunning
            case .failed(let error): operations[key]?.state = .failed(error)
            }
            cancelRefresh(); await refresh()
            switch result {
            case .stopped:
                let stillUsed = snapshot.endpoints.contains { row in row.bindings.contains { binding in
                    target.bindings.contains { $0.overlaps(binding) }
                } }
                message = "\(target.title) stopped." + (stillUsed ? " Port \(target.port) is still in use." : "")
                messageIsError = false
            case .stillRunning:
                let canForce = !request.force && snapshot.endpoints.contains { $0.actionID == key }
                message = request.force ? "The process is still present. Refresh to check its state."
                    : "\(target.title) is still running." + (canForce ? " Force quit is available on its row."
                        : " Review its current identity before trying again.")
                messageIsError = true
            case .failed(let error): message = error; messageIsError = true
            }
            actionTasks.removeValue(forKey: key)
        }
    }

    /// Snapshot rendering uses the same native views without starting discovery or stop actions.
    func loadSnapshot(_ snapshot: PortSnapshot) { self.snapshot = snapshot; hasLoaded = true }
}
