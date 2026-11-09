import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class PortTests: XCTestCase {
    private func owner(_ pid: pid_t = 4242, path: String = "/usr/local/bin/node") -> PortProcessIdentity {
        .init(pid: pid, started: Date(timeIntervalSince1970: 100), executable: path, userID: geteuid())
    }

    func testDuplicateDescriptorsAndAddressFamiliesCoalesceWithoutLosingBindings() {
        let a = PortBinding(address: "127.0.0.1", port: 3003), b = PortBinding(address: "::1", port: 3003)
        let rows = PortScanner.group([.init(binding: a, owner: owner(), directory: nil),
                                      .init(binding: a, owner: owner(), directory: nil),
                                      .init(binding: b, owner: owner(), directory: nil)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(rows[0].bindings), [a, b])
        XCTAssertEqual(rows[0].owners.count, 1)
    }

    func testSharedListenerRetainsEveryOwnerAndIndependentBindingsRemainSeparate() {
        let shared = PortBinding(address: "127.0.0.1", port: 3003)
        let other = PortBinding(address: "192.168.1.4", port: 3003)
        let rows = PortScanner.group([.init(binding: shared, owner: owner(10), directory: nil),
                                      .init(binding: shared, owner: owner(11), directory: nil),
                                      .init(binding: other, owner: owner(12), directory: nil)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.bindings == [shared] }?.owners.map(\.pid), [10, 11])
        XCTAssertEqual(rows.first { $0.bindings == [other] }?.owners.map(\.pid), [12])
    }

    func testProjectAttributionFindsGitRootAboveManifestAndRejectsBackgroundDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = base.appendingPathComponent("packages/mobile/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent(".git"))
        try Data("{}".utf8).write(to: base.appendingPathComponent("packages/mobile/package.json"))
        XCTAssertEqual(PortScanner.project(directory: nested.path)?.path, base.path)
        XCTAssertNil(PortScanner.project(directory: "/"))
        XCTAssertNil(PortScanner.project(directory: Paths.userHome.path + "/Library/Application Support/Postgres/var"))
        XCTAssertNil(PortScanner.project(directory: "/opt/homebrew/var/db/redis"))
        let known = PortProject(name: "Named workspace", path: base.path, evidence: "Agent project folder")
        XCTAssertEqual(PortScanner.project(directory: nested.path, known: [known])?.name, "Named workspace")
    }

    func testDockerMappingsRetainIPv6AndUDPAndIgnoreUnpublishedPorts() throws {
        let output = #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"/sample-db-1","image":"postgres:16","running":true,"project":"sample","service":"db","directory":"/missing/compose/path","ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5433"},{"HostIp":"::","HostPort":"5433"}],"9999/tcp":null,"53/udp":[{"HostIp":"127.0.0.1","HostPort":"5353"}]}}"#
        let tcp = try DockerPorts.parse(output, context: "desktop-linux", includeUDP: false)
        XCTAssertEqual(tcp.count, 1)
        XCTAssertEqual(tcp[0].port, 5433)
        XCTAssertEqual(Set(tcp[0].bindings.map(\.address)), ["0.0.0.0", "::"])
        XCTAssertEqual(tcp[0].container?.internalPort, 5432)
        XCTAssertEqual(tcp[0].title, "sample / db")
        XCTAssertNil(tcp[0].project?.path)
        let all = try DockerPorts.parse(output, context: "desktop-linux", includeUDP: true)
        XCTAssertEqual(Set(all.map(\.transport)), [.tcp, .udp])
        XCTAssertEqual(all.count, 2)
        let unrelated = PortEndpoint(bindings: [.init(address: "127.0.0.1", port: 9999)],
                                     container: .init(id: String(repeating: "b", count: 64), name: "unrelated", image: "node", context: "desktop-linux", internalPort: 80))
        let request = PortStopRequest(endpoint: tcp[0], endpoints: all + [unrelated])
        XCTAssertEqual(Set(request.affectedBindings.map(\.transport)), [.tcp, .udp])
        XCTAssertFalse(request.affectedBindings.contains { $0.port == 9999 })
    }

    func testStandaloneAndStoppedContainersDoNotInventProjects() throws {
        let output = #"{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"/standalone","image":"redis:7","running":true,"ports":{"6379/tcp":[{"HostIp":"127.0.0.1","HostPort":"6379"}]}}"#
        let rows = try DockerPorts.parse(output, context: "local", includeUDP: false)
        XCTAssertNil(rows[0].project)
        XCTAssertEqual(rows[0].title, "standalone")
        XCTAssertTrue(try DockerPorts.parse(output.replacingOccurrences(of: "true", with: "false"), context: "local", includeUDP: false).isEmpty)
    }

    func testAddressTargetsPreserveSpecificInterfacesAndBracketIPv6() {
        XCTAssertEqual(PortBinding(address: "::1", port: 3003).connectAddress, "[::1]:3003")
        XCTAssertEqual(PortBinding(address: "::", port: 3003).connectAddress, "[::1]:3003")
        XCTAssertEqual(PortBinding(address: "0.0.0.0", port: 3003).connectAddress, "127.0.0.1:3003")
        XCTAssertEqual(PortBinding(address: "192.168.1.4", port: 3003).connectAddress, "192.168.1.4:3003")
        XCTAssertFalse(PortBinding(address: "::", port: 3003).overlaps(.init(address: "127.0.0.1", port: 3003)))
    }

    func testProtectedTargetsCannotBeStopped() {
        for pid in [pid_t(-1), 0, 1, getpid()] { XCTAssertNotNil(owner(pid).stopUnavailableReason) }
        XCTAssertNotNil(owner(path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter").stopUnavailableReason)
        XCTAssertNotNil(owner(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend").stopUnavailableReason)
        var anotherUser = owner(); anotherUser.userID = geteuid() + 1
        XCTAssertNotNil(anotherUser.stopUnavailableReason)
    }

    func testStopReleasesDisposableTCPAndUDPListeners() throws {
        let server = try PortTestServer()
        defer { server.cleanup() }
        let snapshot = PortScanner.native(includeUDP: true)
        let row = try XCTUnwrap(snapshot.endpoints.first { $0.port == server.tcp && $0.owners.contains { $0.pid == server.process.processIdentifier } })
        let request = PortStopRequest(endpoint: row, endpoints: snapshot.endpoints)
        XCTAssertTrue(request.affectedBindings.contains { $0.port == server.udp && $0.transport == .udp })
        XCTAssertEqual(PortTermination.perform(request, grace: 1), .stopped)
        server.process.waitUntilExit()
        let after = PortScanner.native(includeUDP: true)
        XCTAssertFalse(after.endpoints.contains { $0.owners.contains { $0.pid == server.process.processIdentifier } })
        XCTAssertEqual(bindTo(server.tcp, type: SOCK_STREAM), 0)
        XCTAssertEqual(bindTo(server.udp, type: SOCK_DGRAM), 0)
    }

    func testIgnoredGracefulStopRequiresSeparateForceRequest() throws {
        let server = try PortTestServer(ignoreTerm: true)
        defer { server.cleanup() }
        var snapshot = PortScanner.native(includeUDP: true)
        var row = try XCTUnwrap(snapshot.endpoints.first { $0.port == server.tcp && $0.transport == .tcp && $0.owners.contains { $0.pid == server.process.processIdentifier } })
        XCTAssertEqual(PortTermination.perform(.init(endpoint: row, endpoints: snapshot.endpoints), grace: 0.1), .stillRunning)
        XCTAssertTrue(server.process.isRunning)
        snapshot = PortScanner.native(includeUDP: true)
        row = try XCTUnwrap(snapshot.endpoints.first { $0.id == row.id })
        XCTAssertEqual(PortTermination.perform(.init(endpoint: row, endpoints: snapshot.endpoints, force: true), grace: 1), .stopped)
        server.process.waitUntilExit()
        XCTAssertEqual(server.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(server.process.terminationStatus, SIGKILL)
    }

    func testStaleIdentityAndUnreviewedAdditionalPortsAreRejectedWithoutSignaling() throws {
        let server = try PortTestServer()
        defer { server.cleanup() }
        let snapshot = PortScanner.native(includeUDP: true)
        let actual = try XCTUnwrap(snapshot.endpoints.first { $0.port == server.tcp && $0.transport == .tcp && $0.owners.contains { $0.pid == server.process.processIdentifier } })
        var stale = actual; stale.owners[0].started.addTimeInterval(-1)
        if case .failed = PortTermination.perform(.init(endpoint: stale, endpoints: [stale]), grace: 0) {} else { XCTFail("Stale identity accepted") }
        XCTAssertTrue(server.process.isRunning)
        if case .failed = PortTermination.perform(.init(endpoint: actual, endpoints: [actual]), grace: 0) {} else { XCTFail("Unreviewed UDP port accepted") }
        XCTAssertTrue(server.process.isRunning)
    }

    func testNativeUDPIsOptIn() throws {
        let server = try PortTestServer(); defer { server.cleanup() }
        let tcp = PortScanner.native()
        XCTAssertTrue(tcp.endpoints.contains { $0.port == server.tcp })
        XCTAssertFalse(tcp.endpoints.contains { $0.port == server.udp && $0.transport == .udp })
        XCTAssertTrue(PortScanner.native(includeUDP: true).endpoints.contains { $0.port == server.udp && $0.transport == .udp })
    }

    func testCommandTimeoutAndOutputAreBounded() {
        let start = Date()
        let timed = PortCommand.run("/bin/sleep", ["30"], timeout: 0.1)
        XCTAssertEqual(timed.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let flooded = PortCommand.run("/usr/bin/python3", ["-c", "import sys; sys.stdout.write('x' * 4000000)"], timeout: 3)
        XCTAssertEqual(flooded.status, -2)
        XCTAssertLessThanOrEqual(flooded.output.utf8.count, 2_097_152)
    }

    private func bindTo(_ port: UInt16, type: Int32) -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return -1 }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }
}

/// Only sockets and processes created by this test are ever terminated.
private final class PortTestServer {
    let process = Process()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-port-test-" + UUID().uuidString)
    var tcp: UInt16 = 0, udp: UInt16 = 0
    init(ignoreTerm: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = folder.appendingPathComponent("ready.json")
        let script = """
        import socket, signal, sys, json, time, os
        if sys.argv[2] == 'ignore': signal.signal(signal.SIGTERM, signal.SIG_IGN)
        tcp = socket.socket(); tcp.bind(('127.0.0.1', 0)); tcp.listen()
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.bind(('127.0.0.1', 0))
        with open(sys.argv[1], 'w') as f: json.dump({'tcp':tcp.getsockname()[1], 'udp':udp.getsockname()[1]}, f)
        while True: time.sleep(1)
        """
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, metadata.path, ignoreTerm ? "ignore" : "normal"]
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let data = try? Data(contentsOf: metadata), let ports = try? JSONDecoder().decode([String: UInt16].self, from: data),
                   let tcp = ports["tcp"], let udp = ports["udp"] { self.tcp = tcp; self.udp = udp; return }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw NSError(domain: "PortTestServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disposable listener did not start"])
        } catch { cleanup(); throw error }
    }
    func cleanup() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: folder)
    }
}
