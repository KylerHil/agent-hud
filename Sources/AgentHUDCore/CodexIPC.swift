import Darwin
import Foundation

/// Compatibility adapter for the installed Codex IDE/desktop owner/follower IPC protocol.
/// This is an internal, versioned Codex protocol, not a public VS Code extension API.
/// It only asks an existing owner to act; it never resumes, forks or takes over a thread.
/// All methods block with bounded deadlines. Call from a background queue.
public enum CodexIPC {
    public struct Owner: Equatable, Sendable {
        public let endpoint: String
        public let clientID: String
        /// Only delivery fetches a full live snapshot; the lightweight probe leaves this nil.
        public let busy: Bool?
        public let model: String?
        public let cwd: String?
    }

    public enum SendMode: Sendable { case auto, steer, queue }
    public enum Delivery: String, Sendable { case sent, steered, queued }

    public struct Failure: LocalizedError, Sendable {
        public let message: String
        /// The owner may have accepted the message. Never automatically send it again.
        public let uncertain: Bool
        public var errorDescription: String? { message }
        public init(_ message: String, uncertain: Bool = false) {
            self.message = message
            self.uncertain = uncertain
        }
    }
    public typealias Error = Failure

    public static func probe(threadID: String) throws -> Owner? {
        try probe(threadID: threadID, endpoints: defaultEndpoints())
    }

    public static func send(threadID: String, text: String, mode: SendMode = .auto) throws -> Delivery {
        try send(threadID: threadID, text: text, mode: mode, endpoints: defaultEndpoints())
    }

    // Endpoint injection is intentionally internal, for isolated fake-owner tests.
    static func probe(threadID: String, endpoints: [String]) throws -> Owner? {
        guard !threadID.isEmpty else { throw Failure("The Codex thread ID is missing.") }
        guard let connection = try connect(endpoints: endpoints) else { return nil }
        defer { connection.close() }
        return try findOwner(threadID: threadID, connection: connection, includeSnapshot: false)
    }

    static func send(threadID: String, text: String, mode: SendMode, endpoints: [String]) throws -> Delivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("Enter a message before sending.")
        }
        guard text.utf8.count <= 1024 * 1024 else { throw Failure("This message is too large to send to Codex.") }
        guard let connection = try connect(endpoints: endpoints) else {
            throw Failure("Codex is disconnected. Open this chat in VS Code and try again.")
        }
        defer { connection.close() }
        guard let owner = try findOwner(threadID: threadID, connection: connection, includeSnapshot: true) else {
            throw Failure("No live Codex window owns this chat. Open the original chat in VS Code and try again.")
        }
        if owner.busy == true && mode == .queue {
            // The IDE queue IPC replaces whole queue state; using it would race with real user messages.
            throw Failure("Codex is running. Use Send to running turn, or wait for the turn to finish.")
        }

        let messageID = UUID().uuidString.lowercased()
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        let method: String
        let version: Int
        let params: [String: Any]
        let outcome: Delivery
        if owner.busy == true {
            method = "thread-follower-steer-turn"
            version = 1
            outcome = .steered
            guard let cwd = owner.cwd, !cwd.isEmpty else { throw Failure("Codex did not report this chat's workspace.") }
            let restored: [String: Any] = [
                "id": messageID, "text": text, "cwd": cwd,
                "createdAt": Date().timeIntervalSince1970 * 1000,
                "context": ["prompt": text, "addedFiles": [], "fileAttachments": [],
                            "ideContext": NSNull(), "imageAttachments": [], "workspaceRoots": [cwd]],
            ]
            params = ["conversationId": threadID, "input": input, "restoreMessage": restored,
                      "clientUserMessageId": messageID, "attachments": []]
        } else {
            method = "thread-follower-start-turn"
            version = 2
            outcome = .sent
            params = ["conversationId": threadID,
                      "turnStart": ["request": ["threadId": threadID, "input": input,
                                               "clientUserMessageId": messageID],
                                    "context": ["inheritThreadSettings": true]]]
        }
        let response = try connection.request(method, params: params, version: version,
                                              target: owner.clientID, mutating: true, timeout: 15)
        guard let result = response["result"] as? [String: Any],
              let details = result["result"] as? [String: Any] else {
            throw Failure("Codex returned an unfamiliar delivery acknowledgment. Check the chat before retrying.", uncertain: true)
        }
        if let status = details["status"] as? String {
            if status == "queued", let id = details["messageId"] as? String, !id.isEmpty { return .queued }
            if ["not-ready", "paused", "not-sent", "rejected"].contains(status) {
                throw Failure("Codex returned \(details["reason"] as? String ?? status). Check the chat before retrying.", uncertain: true)
            }
            guard ["sent", "steered"].contains(status) else {
                throw Failure("Codex returned an unknown delivery status. Check the chat before retrying.", uncertain: true)
            }
        }
        if outcome == .steered {
            guard let turnID = details["turnId"] as? String, !turnID.isEmpty else {
                throw Failure("Codex did not confirm which turn received the reply. Check the chat before retrying.", uncertain: true)
            }
        } else {
            guard let turn = details["turn"] as? [String: Any], let turnID = turn["id"] as? String, !turnID.isEmpty,
                  let status = turn["status"] as? String, ["inProgress", "completed", "interrupted", "failed"].contains(status) else {
                throw Failure("Codex did not confirm a turn for this reply. Check the chat before retrying.", uncertain: true)
            }
        }
        return outcome
    }

    private static func defaultEndpoints() -> [String] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return [URL(fileURLWithPath: home).appendingPathComponent("ipc/ipc.sock").path,
                FileManager.default.temporaryDirectory.appendingPathComponent("codex-ipc/ipc-\(getuid()).sock").path]
    }

    private static func connect(endpoints: [String]) throws -> Connection? {
        for path in endpoints {
            guard let connection = try Connection.open(path: path) else { continue }
            do {
                let response = try connection.request("initialize", params: ["clientType": "agenthud"], version: 0)
                guard let result = response["result"] as? [String: Any], let id = result["clientId"] as? String,
                      !id.isEmpty else { throw Failure("Codex IPC initialization is incompatible with this bridge.") }
                connection.clientID = id
                return connection
            } catch { connection.close(); throw error }
        }
        return nil
    }

    private static func findOwner(threadID: String, connection: Connection, includeSnapshot: Bool) throws -> Owner? {
        let discovered: [String: Any]
        do {
            discovered = try connection.request("thread-owner-discovery",
                params: ["hostId": "local", "conversationId": threadID], version: 1)
        } catch let error as Failure where error.message.contains("no-client-found") { return nil }
        guard let id = discovered["handledByClientId"] as? String,
              let support = discovered["result"] as? [String: Any], support["supportsUntrustedAppInput"] as? Bool == true else {
            throw Failure("This Codex version does not expose the compatible live-thread bridge.")
        }
        let metadata = try connection.request("thread-follower-read-model-settings",
            params: ["conversationId": threadID], version: 1, target: id)
        guard let result = metadata["result"] as? [String: Any],
              let settings = result["settings"] as? [String: Any], settings["resumeState"] as? String == "resumed" else {
            throw Failure("The original Codex chat is reconnecting. Wait for it to reconnect before sending.")
        }
        if !includeSnapshot {
            return Owner(endpoint: connection.path, clientID: id, busy: nil,
                         model: settings["model"] as? String, cwd: nil)
        }
        // A short-lived follower subscription supplies observable state without acquiring ownership.
        // Closing the socket unregisters the follower automatically from the owning app.
        try connection.broadcast("thread-stream-following-changed", params:
            ["conversationId": threadID, "hostId": "local", "following": true], version: 1, target: id)
        let snapshot = try connection.snapshot(threadID: threadID, ownerID: id)
        let runtime = snapshot["threadRuntimeStatus"] as? [String: Any]
        let turns = snapshot["turns"] as? [[String: Any]] ?? []
        let busy: Bool
        if let type = runtime?["type"] as? String, ["active", "idle"].contains(type) {
            busy = type == "active"
        } else if runtime == nil, let status = turns.last?["status"] as? String,
                  ["inProgress", "completed", "interrupted", "failed"].contains(status) {
            busy = status == "inProgress"
        } else {
            throw Failure("Codex did not report usable execution state. Reconnect the original chat before sending.")
        }
        return Owner(endpoint: connection.path, clientID: id, busy: busy,
                     model: settings["model"] as? String, cwd: snapshot["cwd"] as? String)
    }

    private final class Connection {
        let fd: Int32
        let path: String
        var clientID = "initializing-client"
        private var closed = false
        private static let frameLimit = 16 * 1024 * 1024

        init(fd: Int32, path: String) { self.fd = fd; self.path = path }
        deinit { close() }
        func close() { if !closed { closed = true; Darwin.close(fd) } }

        static func open(path: String) throws -> Connection? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), info.st_uid == getuid(),
                  info.st_mode & 0o022 == 0 else { throw Failure("Codex IPC socket permissions are unsafe.") }
            var parent = stat()
            guard lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &parent) == 0,
                  parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
                throw Failure("Codex IPC directory is not private to this user.")
            }
            let bytes = Array(path.utf8)
            var address = sockaddr_un()
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { storage in
                for (index, byte) in bytes.enumerated() { storage[index] = byte }
                storage[bytes.count] = 0
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            // Nonblocking connect and deadline-based poll bound even a wedged socket backlog.
            fcntl(fd, F_SETFL, O_NONBLOCK)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { Darwin.close(fd); return nil }
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard Darwin.poll(&poller, 1, 1000) > 0 else { Darwin.close(fd); return nil }
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                    Darwin.close(fd); return nil
                }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(fd); throw Failure("Codex IPC peer is not the current user.")
            }
            return Connection(fd: fd, path: path)
        }

        func request(_ method: String, params: [String: Any], version: Int, target: String? = nil,
                     mutating: Bool = false, timeout: TimeInterval = 4) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            let requestID = UUID().uuidString.lowercased()
            var request: [String: Any] = ["type": "request", "requestId": requestID, "sourceClientId": clientID,
                                        "method": method, "params": params, "version": version,
                                        "timeoutMs": Int(timeout * 1000)]
            if let target { request["targetClientId"] = target }
            var beganWrite = false
            do {
                beganWrite = true
                try write(request, deadline: deadline)
                while true {
                    let message = try read(deadline: deadline)
                    if try handleDiscovery(message, deadline: deadline) { continue }
                    guard message["type"] as? String == "response", message["requestId"] as? String == requestID else { continue }
                    if message["resultType"] as? String == "error" {
                        let reason = message["error"] as? String ?? "unknown error"
                        // Router errors prove there was no accepting owner; timeouts and owner failures may follow delivery.
                        let knownUnsent = ["no-client-found", "client-not-found", "request-version-mismatch", "no-handler-for-request"].contains(reason)
                        throw Failure("Codex: \(reason)", uncertain: mutating && !knownUnsent)
                    }
                    guard message["resultType"] as? String == "success", message["method"] as? String == method,
                          target == nil || message["handledByClientId"] as? String == target else {
                        throw Failure("Codex returned an incompatible response.", uncertain: mutating)
                    }
                    return message
                }
            } catch let failure as Failure {
                if mutating && beganWrite && !failure.message.hasPrefix("Codex:") {
                    throw Failure("Delivery is unconfirmed. Check the original chat before retrying. \(failure.message)", uncertain: true)
                }
                throw failure
            } catch {
                throw Failure("Codex connection failed: \(error.localizedDescription)", uncertain: mutating && beganWrite)
            }
        }

        func broadcast(_ method: String, params: [String: Any], version: Int, target: String) throws {
            try write(["type": "broadcast", "method": method, "sourceClientId": clientID,
                       "version": version, "targetClientIds": [target], "params": params], deadline: Date().addingTimeInterval(4))
        }

        func snapshot(threadID: String, ownerID: String) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(4)
            while true {
                let message = try read(deadline: deadline)
                if try handleDiscovery(message, deadline: deadline) { continue }
                guard message["type"] as? String == "broadcast", message["method"] as? String == "thread-stream-state-changed",
                      message["sourceClientId"] as? String == ownerID,
                      let params = message["params"] as? [String: Any], params["conversationId"] as? String == threadID else { continue }
                guard message["version"] as? Int == 11, params["hostId"] as? String == "local",
                      let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                      let state = change["conversationState"] as? [String: Any], state["id"] as? String == threadID else {
                    throw Failure("Codex live-thread state is incompatible with this bridge. Update Agent HUD.")
                }
                return state
            }
        }

        private func handleDiscovery(_ message: [String: Any], deadline: Date) throws -> Bool {
            guard message["type"] as? String == "client-discovery-request", let id = message["requestId"] as? String else { return false }
            try write(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]], deadline: deadline)
            return true
        }

        private func wait(_ events: Int16, deadline: Date) throws {
            while true {
                let milliseconds = Int32(min(15_000, max(0, deadline.timeIntervalSinceNow * 1000)))
                guard milliseconds > 0 else { throw Failure("Codex did not respond before the connection deadline.") }
                var poller = pollfd(fd: fd, events: events, revents: 0)
                let result = Darwin.poll(&poller, 1, milliseconds)
                if result < 0 && errno == EINTR { continue }
                guard result > 0, poller.revents & events != 0 else { throw Failure("Codex disconnected or timed out.") }
                return
            }
        }

        private func write(_ object: [String: Any], deadline: Date) throws {
            let payload = try JSONSerialization.data(withJSONObject: object)
            guard payload.count <= Self.frameLimit else { throw Failure("Codex IPC message exceeds the frame limit.") }
            var size = UInt32(payload.count).littleEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }
            frame.append(payload)
            try frame.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(Int16(POLLOUT), deadline: deadline)
                    let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    guard count > 0 else { throw Failure("Codex disconnected while writing.") }
                    offset += count
                }
            }
        }

        private func read(deadline: Date) throws -> [String: Any] {
            let header = try readBytes(4, deadline: deadline)
            let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            guard length > 0, length <= Self.frameLimit else { throw Failure("Codex IPC frame size is incompatible with this bridge.") }
            guard let object = try JSONSerialization.jsonObject(with: readBytes(Int(length), deadline: deadline)) as? [String: Any] else {
                throw Failure("Codex IPC returned malformed JSON.")
            }
            return object
        }

        private func readBytes(_ count: Int, deadline: Date) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < count {
                    try wait(Int16(POLLIN), deadline: deadline)
                    let read = Darwin.read(fd, bytes.baseAddress! + offset, count - offset)
                    if read < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    guard read > 0 else { throw Failure("Codex disconnected while reading.") }
                    offset += read
                }
            }
            return data
        }
    }
}
