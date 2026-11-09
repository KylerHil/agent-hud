import Darwin
import Foundation

/// A bounded, cancellable subprocess runner. No shell; stdout/stderr are drained independently.
enum PortCommand {
    struct Result { var status: Int32; var output: String; var error: String }
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var exceeded = false
        func append(_ bytes: Data, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            let remaining = max(0, limit - data.count)
            data.append(bytes.prefix(remaining))
            if bytes.count > remaining { exceeded = true }
        }
        func read() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, exceeded) }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 6) -> Result {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        do { try process.run() } catch { return .init(status: -1, output: "", error: error.localizedDescription) }
        let group = DispatchGroup(), output = Capture(), errors = Capture()
        for (pipe, capture, limit) in [(out, output, 2_097_152), (err, errors, 32_768)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while let bytes = try? pipe.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty {
                    capture.append(bytes, limit: limit)
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var failure: String?
        while process.isRunning {
            if Task.isCancelled { failure = "Cancelled" }
            else if Date() >= deadline { failure = "The Docker command timed out." }
            else if output.read().1 || errors.read().1 { failure = "The Docker response was too large." }
            if failure != nil {
                process.terminate()
                let grace = Date().addingTimeInterval(0.15)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        // Descendants should not keep us waiting forever with an inherited pipe open.
        _ = group.wait(timeout: .now() + 0.5)
        let stdout = output.read(), stderr = errors.read()
        if stdout.1 || stderr.1 { failure = "The Docker response was too large." }
        return .init(status: failure == nil ? process.terminationStatus : -2,
                     output: String(decoding: stdout.0, as: UTF8.self),
                     error: failure ?? String(decoding: stderr.0, as: UTF8.self))
    }
}

public enum DockerPorts {
    public struct Discovery: Sendable {
        public var endpoints: [PortEndpoint]
        public var status: DockerPortStatus
    }
    struct Inspect: Decodable {
        var id: String; var name: String; var image: String; var running: Bool
        var project: String?; var service: String?; var directory: String?
        var ports: [String: [Binding]?]?
        struct Binding: Decodable { var HostIp: String; var HostPort: String }
    }
    static let inspectFormat = #"{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"running":{{json .State.Running}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"directory":{{json (index .Config.Labels "com.docker.compose.project.working_dir")}},"ports":{{json .NetworkSettings.Ports}}}"#

    static func executable() -> String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", Paths.userHome.path + "/.docker/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func context(_ executable: String) -> Result<String, PortActionError> {
        let environment = ProcessInfo.processInfo.environment
        if (environment["DOCKER_CONTEXT"] ?? "").isEmpty, let host = environment["DOCKER_HOST"], !host.isEmpty {
            return host.hasPrefix("unix://") ? .success(host) : .failure(.init("remote:DOCKER_HOST"))
        }
        let selected = PortCommand.run(executable, ["context", "show"], timeout: 3)
        let name = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.status == 0, name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,255}$"#, options: .regularExpression) != nil else {
            return .failure(.init("Could not read the local Docker context."))
        }
        let inspected = PortCommand.run(executable, ["context", "inspect", name, "--format", "{{json .Endpoints.docker.Host}}"], timeout: 3)
        guard inspected.status == 0, let endpoint = try? JSONDecoder().decode(String.self, from: Data(inspected.output.utf8)) else {
            return .failure(.init("Could not inspect the Docker context."))
        }
        guard endpoint.hasPrefix("unix://") else { return .failure(.init("remote:\(name)")) }
        return .success(name)
    }

    static func connectionArguments(_ context: String) -> [String] {
        context.hasPrefix("unix://") ? ["--host", context] : ["--context", context]
    }

    public static func discover(includeUDP: Bool = false) -> Discovery {
        let deadline = Date().addingTimeInterval(18)
        guard let executable = executable() else { return .init(endpoints: [], status: .notInstalled) }
        let name: String
        switch context(executable) {
        case .success(let value): name = value
        case .failure(let error):
            return .init(endpoints: [], status: error.message.hasPrefix("remote:")
                         ? .remoteContext(String(error.message.dropFirst(7))) : .unavailable(error.message))
        }
        let list = PortCommand.run(executable, connectionArguments(name) + ["ps", "--quiet", "--no-trunc"],
                                   timeout: max(0.1, min(6, deadline.timeIntervalSinceNow)))
        guard list.status == 0 else { return .init(endpoints: [], status: .unavailable(connectionError(list))) }
        let ids = list.output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard ids.allSatisfy(validID), ids.count <= 1024 else {
            return .init(endpoints: [], status: .unavailable("The container list could not be read."))
        }
        if ids.isEmpty { return .init(endpoints: [], status: .connected(name)) }
        var endpoints: [PortEndpoint] = []
        for offset in stride(from: 0, to: ids.count, by: 64) {
            if Task.isCancelled { return .init(endpoints: [], status: .unavailable("Cancelled")) }
            guard Date() < deadline else { return .init(endpoints: [], status: .unavailable("Discovery took too long. Refresh to try again.")) }
            let batch = Array(ids[offset..<min(offset + 64, ids.count)])
            let inspected = PortCommand.run(executable, connectionArguments(name) + ["inspect", "--type", "container", "--format", inspectFormat] + batch,
                                            timeout: max(0.1, min(6, deadline.timeIntervalSinceNow)))
            guard inspected.status == 0 else { return .init(endpoints: [], status: .unavailable(connectionError(inspected))) }
            do { endpoints += try parse(inspected.output, context: name, includeUDP: includeUDP) }
            catch { return .init(endpoints: [], status: .unavailable("The container port mappings could not be read.")) }
        }
        return .init(endpoints: endpoints, status: .connected(name))
    }

    static func parse(_ output: String, context: String, includeUDP: Bool) throws -> [PortEndpoint] {
        var endpoints: [PortEndpoint] = []
        for line in output.split(separator: "\n") {
            let container = try JSONDecoder().decode(Inspect.self, from: Data(line.utf8))
            guard validID(container.id), container.running else { continue }
            let project: PortProject?
            if let name = container.project, !name.isEmpty {
                let local = PortScanner.project(directory: container.directory)
                project = .init(name: name, path: local?.path, evidence: "Docker Compose project")
            } else { project = nil }
            for (key, value) in container.ports ?? [:] {
                let pieces = key.split(separator: "/")
                guard pieces.count == 2, let internalPort = UInt16(pieces[0]), internalPort > 0,
                      let transport = PortTransport(rawValue: String(pieces[1])), transport == .tcp || includeUDP else { continue }
                let bindings = (value ?? []).compactMap { binding -> PortBinding? in
                    guard let port = UInt16(binding.HostPort), port > 0 else { return nil }
                    return .init(address: binding.HostIp.isEmpty ? "0.0.0.0" : binding.HostIp, port: port, transport: transport)
                }
                for (_, bound) in Dictionary(grouping: bindings, by: \.port) {
                    let identity = PortContainer(id: container.id, name: container.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                                 image: container.image, context: context, service: container.service, internalPort: internalPort)
                    endpoints.append(.init(bindings: Array(Set(bound)), project: project, container: identity))
                }
            }
        }
        return endpoints
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    private static func connectionError(_ result: PortCommand.Result) -> String {
        // Do not surface arbitrary CLI stderr (which can include private configuration).
        if result.error.contains("timed out") { return "The Docker command timed out." }
        if result.error.contains("permission denied") { return "Access to the Docker socket was denied." }
        return "Start Docker or check the selected local context, then refresh."
    }

    static func stop(_ request: PortStopRequest) -> PortStopResult {
        guard !request.force else { return .failed("Use Stop Container to let Docker stop this container.") }
        guard let container = request.endpoint.container, validID(container.id), let executable = executable() else {
            return .failed("The container is no longer available.")
        }
        guard case .success(let currentContext) = context(executable), currentContext == container.context else {
            return .failed("The Docker context changed. Refresh before stopping this container.")
        }
        let current = discover(includeUDP: true)
        guard case .connected(let name) = current.status, name == container.context else {
            return .failed("Docker could not be reached. No container was stopped.")
        }
        let rows = current.endpoints.filter { $0.container?.id == container.id }
        guard rows.contains(where: { $0.id == request.endpoint.id }),
              Set(rows.flatMap(\.bindings)) == Set(request.affectedBindings) else {
            return .failed("The container’s port mappings changed. Refresh and review them before stopping it.")
        }
        let stopped = PortCommand.run(executable, connectionArguments(container.context) + ["stop", "--timeout", "10", container.id], timeout: 15)
        guard stopped.status == 0 else { return .failed("Docker did not confirm that the container stopped. Refresh to check its state.") }
        let verified = PortCommand.run(executable, connectionArguments(container.context) + ["inspect", "--type", "container", "--format", "{{json .State.Running}}", container.id])
        if verified.status == 0, verified.output.trimmingCharacters(in: .whitespacesAndNewlines) == "false" { return .stopped }
        // `docker run --rm` removes the container when it stops. Confirm absence with a successful list,
        // rather than interpreting an arbitrary inspect/connection failure as success.
        let remaining = PortCommand.run(executable, connectionArguments(container.context) + ["ps", "--all", "--quiet", "--no-trunc", "--filter", "id=\(container.id)"])
        if remaining.status == 0, remaining.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .stopped }
        return .failed("The container is still running or its state could not be confirmed.")
    }
}
