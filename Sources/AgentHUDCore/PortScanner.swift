import Darwin
import Foundation

public enum PortScanner {
    struct Listener: Sendable {
        var binding: PortBinding
        var owner: PortProcessIdentity
        var directory: String?
    }

    public static func native(includeUDP: Bool = false, projects: [PortProject] = []) -> PortSnapshot {
        var listeners: [Listener] = [], restricted = 0
        let table = ProcTools.allProcesses()
        for entry in table where !entry.zombie {
            if Task.isCancelled { break }
            guard let identity = PortProcessIdentity.read(entry.pid) else { continue }
            let (bindings, denied) = sockets(pid: entry.pid, includeUDP: includeUDP)
            if denied { restricted += 1 }
            guard !bindings.isEmpty, PortProcessIdentity.read(entry.pid) == identity else { continue }
            let directory = ProcTools.cwd(entry.pid)
            listeners += bindings.map { Listener(binding: $0, owner: identity, directory: directory) }
        }
        let endpoints = EditorPorts.annotate(group(listeners, projects: projects), table: table)
        return PortSnapshot(endpoints: endpoints, restrictedProcesses: restricted)
    }

    static func sockets(pid: pid_t, includeUDP: Bool) -> ([PortBinding], Bool) {
        errno = 0
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return ([], [EPERM, EACCES].contains(errno)) }
        let count = min(Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32, 262_144)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        errno = 0
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return ([], [EPERM, EACCES].contains(errno)) }
        var result = Set<PortBinding>(), restricted = false
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, Int32(fd.proc_fd), PROC_PIDFDSOCKETINFO, &info, size) == size else {
                if [EPERM, EACCES].contains(errno) { restricted = true }
                continue
            }
            let socket = info.psi
            let transport: PortTransport
            let address: in_sockinfo
            if socket.soi_kind == SOCKINFO_TCP, socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN {
                transport = .tcp; address = socket.soi_proto.pri_tcp.tcpsi_ini
            } else if includeUDP, socket.soi_kind == SOCKINFO_IN, socket.soi_protocol == IPPROTO_UDP {
                transport = .udp; address = socket.soi_proto.pri_in
            } else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport))
            guard port > 0, let host = localAddress(address, family: socket.soi_family) else { continue }
            result.insert(.init(address: host, port: port, transport: transport))
        }
        return (Array(result), restricted)
    }

    private static func localAddress(_ info: in_sockinfo, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if family == AF_INET {
            var address = info.insi_laddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else if family == AF_INET6 {
            var address = info.insi_laddr.ina_6
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else { return nil }
        var host = String(cString: buffer)
        if host.hasPrefix("fe80:"), info.insi_v6.in6_ifindex > 0 { host += "%\(info.insi_v6.in6_ifindex)" }
        return host
    }

    static func group(_ listeners: [Listener], projects: [PortProject] = []) -> [PortEndpoint] {
        let byBinding = Dictionary(grouping: listeners, by: \.binding)
        var merged: [String: PortEndpoint] = [:]
        for (binding, rows) in byBinding {
            let owners = Set(rows.map(\.owner)).sorted { $0.pid < $1.pid }
            let key = "\(binding.transport.rawValue):\(binding.port):" + owners.map(\.key).joined(separator: ",")
            if var existing = merged[key] {
                existing.bindings.append(binding); existing.bindings.sort { $0.display < $1.display }; merged[key] = existing
            } else {
                let matched = Set(rows.compactMap { project(directory: $0.directory, known: projects) })
                merged[key] = PortEndpoint(bindings: [binding], owners: owners, project: matched.count == 1 ? matched.first : nil,
                                           workingDirectory: rows.first?.directory)
            }
        }
        return merged.values.sorted { $0.port == $1.port ? $0.id < $1.id : $0.port < $1.port }
    }

    public static func project(directory: String?, known: [PortProject] = []) -> PortProject? {
        guard let directory, directory.hasPrefix("/") else { return nil }
        let dir = URL(fileURLWithPath: directory).standardizedFileURL.path
        let home = Paths.userHome.path
        guard dir != "/", dir != home, !["/System/", "/Applications/", "/Library/", home + "/Library/", home + "/.vscode/", "/opt/homebrew/var/", "/usr/local/var/"].contains(where: dir.hasPrefix) else { return nil }
        if let match = known.filter({ $0.path.map { $0 != home && $0 != "/" && ProjectRoot.contains($0, dir) } ?? false })
            .max(by: { ($0.path?.count ?? 0) < ($1.path?.count ?? 0) }) { return match }
        var folder = dir
        let markers = [".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift", "compose.yaml", "docker-compose.yml"]
        var nearest: String?
        while folder != "/", folder != home {
            if FileManager.default.fileExists(atPath: folder + "/.git") { return .init(name: (folder as NSString).lastPathComponent, path: folder, evidence: "Git project folder") }
            if nearest == nil, markers.dropFirst().contains(where: { FileManager.default.fileExists(atPath: folder + "/" + $0) }) { nearest = folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nearest.map { .init(name: ($0 as NSString).lastPathComponent, path: $0, evidence: "Project manifest") }
    }

    public static func scan(includeUDP: Bool = false, projects: [PortProject] = []) -> PortSnapshot {
        var snapshot = native(includeUDP: includeUDP, projects: projects)
        guard !Task.isCancelled else { return snapshot }
        let docker = DockerPorts.discover(includeUDP: includeUDP)
        snapshot.docker = docker.status
        // Only hide Docker's own forwarding sockets, and only when metadata explains that binding.
        snapshot.endpoints = snapshot.endpoints.compactMap { endpoint in
            guard endpoint.owners.allSatisfy({ $0.processName == "com.docker.backend" }) else { return endpoint }
            var remaining = endpoint
            remaining.bindings.removeAll { binding in docker.endpoints.contains { $0.bindings.contains { $0.overlaps(binding) } } }
            return remaining.bindings.isEmpty ? nil : remaining
        }
        snapshot.endpoints += docker.endpoints
        snapshot.capturedAt = Date()
        return snapshot
    }
}
