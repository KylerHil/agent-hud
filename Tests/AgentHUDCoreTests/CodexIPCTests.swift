import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class CodexIPCTests: XCTestCase {
    private let thread = "existing-thread"

    func testProbeIsReadOnlyAndDoesNotSubscribeToTranscript() throws {
        let peer = try IPCPeer { peer in
            try peer.handshake(thread: "existing-thread")
            // Returning closes the fake connection; a probe must already have everything it needs.
        }
        defer { peer.close() }
        let owner = try CodexIPC.probe(threadID: thread, endpoints: [peer.path])
        XCTAssertEqual(owner?.clientID, "real-owner")
        XCTAssertEqual(owner?.model, "test-model")
        XCTAssertNil(owner?.busy)
        try peer.finished()
        XCTAssertEqual(peer.messages.map { $0["method"] as? String }, ["initialize", "thread-owner-discovery", "thread-follower-read-model-settings"])
    }

    func testBusyReplySteersExactOwnerAndPreservesThreadSettings() throws {
        let peer = try deliveryPeer(busy: true)
        defer { peer.close() }
        XCTAssertEqual(try CodexIPC.send(threadID: thread, text: "follow up", mode: .auto, endpoints: [peer.path]), .steered)
        try peer.finished()
        let request = try XCTUnwrap(peer.messages.last)
        XCTAssertEqual(request["method"] as? String, "thread-follower-steer-turn")
        XCTAssertEqual(request["targetClientId"] as? String, "real-owner")
        XCTAssertEqual(request["version"] as? Int, 1)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["conversationId"] as? String, thread)
        XCTAssertNil(params["permissions"])
        XCTAssertNil(params["collaborationMode"])
        let restore = try XCTUnwrap(params["restoreMessage"] as? [String: Any])
        XCTAssertEqual(restore["id"] as? String, params["clientUserMessageId"] as? String)
        XCTAssertEqual(restore["cwd"] as? String, "/tmp/project")
    }

    func testIdleReplyStartsExistingThreadWithInheritedSettings() throws {
        let peer = try deliveryPeer(busy: false)
        defer { peer.close() }
        XCTAssertEqual(try CodexIPC.send(threadID: thread, text: "next turn", mode: .auto, endpoints: [peer.path]), .sent)
        try peer.finished()
        let message = try XCTUnwrap(peer.messages.last)
        XCTAssertEqual(message["method"] as? String, "thread-follower-start-turn")
        XCTAssertEqual(message["version"] as? Int, 2)
        let params = try XCTUnwrap(message["params"] as? [String: Any])
        let start = try XCTUnwrap(params["turnStart"] as? [String: Any])
        let context = try XCTUnwrap(start["context"] as? [String: Any])
        XCTAssertEqual(context["inheritThreadSettings"] as? Bool, true)
        let request = try XCTUnwrap(start["request"] as? [String: Any])
        XCTAssertEqual(request["threadId"] as? String, thread)
        XCTAssertNil(request["approvalPolicy"])
        XCTAssertNil(request["sandboxPolicy"])
        XCTAssertNil(request["model"])
    }

    func testDisconnectedMutationIsUncertainAndNeverRetried() throws {
        let peer = try deliveryPeer(busy: true, acknowledge: false)
        defer { peer.close() }
        XCTAssertThrowsError(try CodexIPC.send(threadID: thread, text: "only once", mode: .auto, endpoints: [peer.path])) { error in
            XCTAssertTrue((error as? CodexIPC.Error)?.uncertain == true)
        }
        try peer.finished()
        XCTAssertEqual(peer.messages.filter { ($0["method"] as? String)?.hasPrefix("thread-follower-steer") == true }.count, 1)
    }

    func testIncompatibleSnapshotDoesNotSendAnything() throws {
        let peer = try IPCPeer { peer in
            try peer.handshake(thread: "existing-thread")
            try peer.snapshot(thread: "existing-thread", busy: true, version: 12)
        }
        defer { peer.close() }
        XCTAssertThrowsError(try CodexIPC.send(threadID: thread, text: "must stay local", mode: .auto, endpoints: [peer.path])) { error in
            XCTAssertFalse((error as? CodexIPC.Error)?.uncertain ?? true)
        }
        try peer.finished()
        XCTAssertEqual(peer.messages.count, 4)
    }

    func testQueueModeRefusesBusyThreadWithoutReplacingUserQueue() throws {
        let peer = try IPCPeer { peer in
            try peer.handshake(thread: "existing-thread")
            try peer.snapshot(thread: "existing-thread", busy: true)
        }
        defer { peer.close() }
        XCTAssertThrowsError(try CodexIPC.send(threadID: thread, text: "wait", mode: .queue, endpoints: [peer.path])) { error in
            XCTAssertFalse((error as? CodexIPC.Error)?.uncertain ?? true)
        }
        try peer.finished()
        XCTAssertFalse(peer.messages.contains { ($0["method"] as? String)?.contains("set-queued") == true })
        XCTAssertEqual(peer.messages.count, 4)
    }

    func testAcknowledgmentFromWrongOwnerIsUncertain() throws {
        let peer = try deliveryPeer(busy: true, respondingOwner: "different-owner")
        defer { peer.close() }
        XCTAssertThrowsError(try CodexIPC.send(threadID: thread, text: "exact thread", mode: .auto, endpoints: [peer.path])) { error in
            XCTAssertTrue((error as? CodexIPC.Error)?.uncertain == true)
        }
        try peer.finished()
    }

    func testUnknownAcknowledgmentStatusIsUncertain() throws {
        let peer = try IPCPeer { peer in
            try peer.handshake(thread: "existing-thread")
            try peer.snapshot(thread: "existing-thread", busy: true)
            let message = try peer.read()
            try peer.reply(message, result: ["result": ["status": "future-status", "turnId": "existing-turn"]])
        }
        defer { peer.close() }
        XCTAssertThrowsError(try CodexIPC.send(threadID: thread, text: "verify ack", mode: .auto, endpoints: [peer.path])) { error in
            XCTAssertTrue((error as? CodexIPC.Error)?.uncertain == true)
        }
        try peer.finished()
    }

    func testMissingOwnerReturnsNilAndDoesNotResume() throws {
        let peer = try IPCPeer { peer in
            let initialize = try peer.read()
            try peer.reply(initialize, result: ["clientId": "test-client"])
            let discovery = try peer.read()
            try peer.write(["type": "response", "requestId": discovery["requestId"]!, "resultType": "error", "error": "no-client-found"])
        }
        defer { peer.close() }
        XCTAssertNil(try CodexIPC.probe(threadID: thread, endpoints: [peer.path]))
        try peer.finished()
        XCTAssertEqual(peer.messages.count, 2)
    }

    private func deliveryPeer(busy: Bool, acknowledge: Bool = true, respondingOwner: String = "real-owner") throws -> IPCPeer {
        try IPCPeer { peer in
            try peer.handshake(thread: "existing-thread")
            try peer.snapshot(thread: "existing-thread", busy: busy)
            let turn = try peer.read()
            if acknowledge {
                let acknowledgment: [String: Any] = busy ? ["turnId": "existing-turn"] : ["turn": ["id": "existing-turn", "status": "inProgress"]]
                try peer.reply(turn, owner: respondingOwner, result: ["result": acknowledgment])
            }
        }
    }
}

/// A real Unix socket exercising framing, identity, disconnection and acknowledgment boundaries.
private final class IPCPeer: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let listener: Int32
    private var client: Int32 = -1
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var seen: [[String: Any]] = []
    private var failure: Swift.Error?
    var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return seen }

    init(_ handler: @escaping (IPCPeer) throws -> Void) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexipc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("ipc.sock").path
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CodexIPC.Error("Test socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            for (index, byte) in bytes.enumerated() { storage[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, Darwin.listen(listener, 2) == 0 else { throw CodexIPC.Error("Cannot listen on test socket") }
        chmod(path, 0o600)
        DispatchQueue(label: "test.codex-ipc").async { [self] in
            defer { if client >= 0 { Darwin.close(client); client = -1 }; done.signal() }
            client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var time = timeval(tv_sec: 4, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            do { try handler(self) } catch { lock.lock(); failure = error; lock.unlock() }
        }
    }

    func finished() throws {
        guard done.wait(timeout: .now() + 5) == .success else { throw CodexIPC.Error("Fake Codex did not finish") }
        lock.lock(); let error = failure; lock.unlock()
        if let error { throw error }
    }

    func close() { Darwin.close(listener); try? FileManager.default.removeItem(at: directory) }

    func handshake(thread: String) throws {
        let initialize = try read()
        guard initialize["method"] as? String == "initialize" else { throw CodexIPC.Error("Expected initialization") }
        try reply(initialize, result: ["clientId": "test-client"])
        let discovery = try read()
        guard discovery["method"] as? String == "thread-owner-discovery",
              (discovery["params"] as? [String: Any])?["conversationId"] as? String == thread else { throw CodexIPC.Error("Wrong thread discovery") }
        try reply(discovery, result: ["supportsUntrustedAppInput": true])
        let settings = try read()
        guard settings["targetClientId"] as? String == "real-owner", settings["version"] as? Int == 1 else { throw CodexIPC.Error("Wrong settings target") }
        try reply(settings, result: ["settings": ["resumeState": "resumed", "model": "test-model"]])
    }

    func snapshot(thread: String, busy: Bool, version: Int = 11) throws {
        let follow = try read()
        guard follow["method"] as? String == "thread-stream-following-changed",
              follow["targetClientIds"] as? [String] == ["real-owner"] else { throw CodexIPC.Error("Wrong snapshot target") }
        try write(["type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "real-owner", "version": version,
                   "params": ["conversationId": thread, "hostId": "local",
                              "change": ["type": "snapshot", "revision": 1,
                                         "conversationState": ["id": thread, "cwd": "/tmp/project", "threadRuntimeStatus": ["type": busy ? "active" : "idle"]]]]])
    }

    func reply(_ request: [String: Any], owner: String = "real-owner", result: [String: Any]) throws {
        try write(["type": "response", "requestId": request["requestId"]!, "resultType": "success",
                   "method": request["method"]!, "handledByClientId": owner, "result": result])
    }

    func write(_ message: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                // Deliberately fragment the four-byte header and JSON body.
                let count = Darwin.write(client, bytes.baseAddress! + offset, min(3, bytes.count - offset))
                guard count > 0 else { throw CodexIPC.Error("Fake socket write failed") }
                offset += count
            }
        }
    }

    func read() throws -> [String: Any] {
        let header = try readBytes(4)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length <= 1024 * 1024 else { throw CodexIPC.Error("Fake socket received oversized frame") }
        let message = try JSONSerialization.jsonObject(with: readBytes(Int(length))) as! [String: Any]
        lock.lock(); seen.append(message); lock.unlock()
        return message
    }

    private func readBytes(_ length: Int) throws -> Data {
        var bytes = Data(count: length)
        try bytes.withUnsafeMutableBytes { data in
            var offset = 0
            while offset < length {
                let count = Darwin.read(client, data.baseAddress! + offset, length - offset)
                guard count > 0 else { throw CodexIPC.Error("Fake socket read failed") }
                offset += count
            }
        }
        return bytes
    }
}
