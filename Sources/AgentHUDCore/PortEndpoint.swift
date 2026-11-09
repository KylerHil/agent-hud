import Darwin
import Foundation

public enum PortTransport: String, Codable, CaseIterable, Sendable { case tcp, udp }
public enum PortSource: String, CaseIterable, Sendable { case local, docker, other, editor }

/// The default inventory excludes editor infrastructure even when its workspace is identified.
public enum PortFilter: String, CaseIterable, Sendable {
    case all = "All", local = "Local", docker = "Docker", other = "Other", editor = "Editor internals"
    public func includes(_ endpoint: PortEndpoint) -> Bool {
        switch self {
        case .all: endpoint.source != .editor
        case .local: endpoint.source == .local
        case .docker: endpoint.source == .docker
        case .other: endpoint.source == .other
        case .editor: endpoint.source == .editor
        }
    }
}

public struct PortEditor: Hashable, Sendable {
    public enum Role: String, Sendable { case claudeBridge = "Claude IDE bridge", extensionHost = "Extension host", helper = "Editor helper", service = "Editor service" }
    public var appName: String
    public var role: Role
    public var workspaceFolders: [String]
    public init(appName: String, role: Role, workspaceFolders: [String] = []) {
        self.appName = appName; self.role = role; self.workspaceFolders = workspaceFolders
    }
}

public struct PortBinding: Hashable, Sendable {
    public var address: String
    public var port: UInt16
    public var transport: PortTransport

    public init(address: String, port: UInt16, transport: PortTransport = .tcp) {
        self.address = address; self.port = port; self.transport = transport
    }

    public var display: String { "\(address.contains(":") ? "[\(address)]" : address):\(port)" }
    public var connectAddress: String {
        let host = ["0.0.0.0", "*"].contains(address) ? "127.0.0.1" : address == "::" ? "::1" : address
        return "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
    public func overlaps(_ other: Self) -> Bool {
        guard port == other.port, transport == other.transport else { return false }
        if address == other.address { return true }
        let v6 = address.contains(":"), otherV6 = other.address.contains(":")
        return v6 == otherV6 && (address == (v6 ? "::" : "0.0.0.0") || other.address == (v6 ? "::" : "0.0.0.0"))
    }
}

/// PID alone is not an identity: macOS can reuse it after a process exits.
public struct PortProcessIdentity: Hashable, Sendable {
    public var pid: pid_t
    public var started: Date
    public var executable: String
    public var userID: uid_t

    public init(pid: pid_t, started: Date, executable: String, userID: uid_t) {
        self.pid = pid; self.started = started; self.executable = executable; self.userID = userID
    }
    public var key: String { "\(pid):\(started.timeIntervalSince1970):\(executable):\(userID)" }
    public static func read(_ pid: pid_t) -> Self? {
        guard pid > 0, let e = ProcTools.entry(pid), !e.zombie, let started = e.started,
              let uid = e.userID, let path = ProcTools.executablePath(pid) else { return nil }
        return .init(pid: pid, started: started, executable: path, userID: uid)
    }
    public var processName: String { (executable as NSString).lastPathComponent }
    public var stopUnavailableReason: String? {
        if pid <= 1 || pid == getpid() { return "Agent HUD and essential system processes cannot be stopped here." }
        if userID != geteuid() { return "This process belongs to another user." }
        if Self.isSystemExecutable(executable) { return "This process is managed by macOS." }
        if processName == "com.docker.backend" { return "Stop the individual container through Docker instead." }
        return nil
    }
    static func isSystemExecutable(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { path.hasPrefix($0) }
    }
}

public struct PortProject: Hashable, Sendable {
    public var name: String
    public var path: String?
    public var evidence: String
    public init(name: String, path: String?, evidence: String) {
        self.name = name; self.path = path; self.evidence = evidence
    }
}

public struct PortContainer: Hashable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var context: String
    public var service: String?
    public var internalPort: UInt16
    public init(id: String, name: String, image: String, context: String, service: String? = nil, internalPort: UInt16) {
        self.id = id; self.name = name; self.image = image; self.context = context
        self.service = service; self.internalPort = internalPort
    }
}

public struct PortEndpoint: Identifiable, Hashable, Sendable {
    public var bindings: [PortBinding]
    public var owners: [PortProcessIdentity]
    public var project: PortProject?
    public var container: PortContainer?
    public var workingDirectory: String?
    public var editor: PortEditor?

    public init(bindings: [PortBinding], owners: [PortProcessIdentity] = [], project: PortProject? = nil,
                container: PortContainer? = nil, workingDirectory: String? = nil, editor: PortEditor? = nil) {
        self.bindings = bindings.sorted { $0.display < $1.display }
        self.owners = owners.sorted { $0.pid < $1.pid }
        self.project = project; self.container = container; self.workingDirectory = workingDirectory
        self.editor = editor
    }
    public var port: UInt16 { bindings.first?.port ?? 0 }
    public var transport: PortTransport { bindings.first?.transport ?? .tcp }
    public var source: PortSource { container != nil ? .docker : editor != nil ? .editor : project != nil ? .local : .other }
    public var actionID: String {
        container.map { "docker:\($0.context):\($0.id)" } ?? "process:" + owners.map(\.key).joined(separator: ",")
    }
    public var id: String { actionID + ":" + bindings.map { "\($0.transport.rawValue):\($0.display)" }.joined(separator: ",") }
    public var title: String {
        if let container {
            if let project { return project.name + (container.service.map { " / " + $0 } ?? "") }
            return container.name
        }
        if let project { return project.name }
        if let editor {
            return editor.workspaceFolders.count > 1 ? "\(editor.appName) · \(editor.workspaceFolders.count) workspaces" : editor.appName
        }
        return owners.first?.processName ?? "Unknown process"
    }
    public var subtitle: String {
        if let c = container { return "\(c.image) · → \(c.internalPort)" }
        if let editor { return "\(editor.role.rawValue) · \(editor.appName)" }
        if owners.count > 1 { return "\(owners.count) processes sharing this port" }
        guard let owner = owners.first else { return "Process details unavailable" }
        return project == nil ? "\(owner.processName) · Project not identified" : owner.processName
    }
    public var stopUnavailableReason: String? {
        if container != nil { return nil }
        if owners.isEmpty { return "Process identity is unavailable." }
        return owners.compactMap(\.stopUnavailableReason).first
    }
    public var browserURL: URL? {
        // Known conventional web ports only. All TCP rows also offer explicit HTTP/HTTPS in their menu.
        guard editor == nil, transport == .tcp, [3000, 3001, 3002, 3003, 3004, 3005, 4173, 5173, 8000, 8080, 8081, 8888, 9000].contains(Int(port)) else { return nil }
        return url(scheme: "http")
    }
    public func url(scheme: String) -> URL? {
        guard transport == .tcp, let binding = bindings.first else { return nil }
        return URL(string: "\(scheme)://\(binding.connectAddress)")
    }
}

public enum DockerPortStatus: Equatable, Sendable {
    case connected(String), notInstalled, unavailable(String), remoteContext(String)
    public var message: String? {
        switch self {
        case .connected: nil
        case .notInstalled: "Docker CLI not found. Local ports are still shown."
        case .unavailable(let detail): "Docker unavailable. \(detail)"
        case .remoteContext(let name): "Docker context ‘\(name)’ is remote. Choose a local context to see this Mac’s container ports."
        }
    }
}

public struct PortSnapshot: Sendable {
    public var endpoints: [PortEndpoint]
    public var docker: DockerPortStatus
    public var restrictedProcesses: Int
    public var capturedAt: Date
    public init(endpoints: [PortEndpoint] = [], docker: DockerPortStatus = .notInstalled,
                restrictedProcesses: Int = 0, capturedAt: Date = Date()) {
        self.endpoints = endpoints; self.docker = docker
        self.restrictedProcesses = restrictedProcesses; self.capturedAt = capturedAt
    }
}
