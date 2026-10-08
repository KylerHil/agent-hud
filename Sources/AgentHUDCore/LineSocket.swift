import Darwin
import Foundation

/// One end of a newline-delimited JSON connection over a Unix domain socket. Reads arrive on `queue`.
public final class LineConnection: @unchecked Sendable {
    public let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private let writeLock = NSLock()
    private var closed = false
    private let writer = DispatchQueue(label: "agenthud.socket.writer")
    private let pendingLock = NSLock()
    private var pendingBytes = 0
    public var onLine: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.readAvailable() }
        s.setCancelHandler { [fd] in Darwin.close(fd) }
        source = s
        s.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 { close(); return }
        buffer.append(contentsOf: chunk[0..<n])
        guard buffer.count <= 4 * 1024 * 1024 else { close(); return }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { onLine?(Data(line)) }
        }
    }

    /// Writes one line. Returns false once the other end has gone.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return false }
        var out = data
        out.append(0x0A)
        return out.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
    }

    public func send<T: Encodable>(_ value: T) {
        guard let data = try? BrokerCoding.encoder.encode(value) else { return }
        pendingLock.lock()
        guard pendingBytes + data.count <= 4 * 1024 * 1024 else {
            pendingLock.unlock()
            queue.async { [weak self] in self?.close() }
            return
        }
        pendingBytes += data.count
        pendingLock.unlock()
        writer.async { [weak self] in
            guard let self else { return }
            let ok = self.send(data)
            self.pendingLock.lock(); self.pendingBytes -= data.count; self.pendingLock.unlock()
            if !ok { self.queue.async { self.close() } }
        }
    }

    public func close() {
        writeLock.lock()
        let wasClosed = closed
        closed = true
        writeLock.unlock()
        guard !wasClosed else { return }
        source?.cancel()
        source = nil
        onClose?()
    }
}

public enum LineSocket {
    /// Listens on `path` (owner-only), calling `accept` for each client. Returns nil if it can't bind.
    public static func listen(path: String, queue: DispatchQueue, accept: @escaping (LineConnection) -> Void) -> DispatchSourceRead? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = address(path) else { Darwin.close(fd); return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); return nil }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); return nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            // Only this user's processes may talk to the broker.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); return }
            let c = LineConnection(fd: client, queue: queue)
            accept(c)
            c.start()
        }
        source.setCancelHandler { Darwin.close(fd); unlink(path) }
        source.resume()
        return source
    }

    /// Connects to `path`; nil when nothing is listening.
    public static func connect(path: String, queue: DispatchQueue) -> LineConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = address(path) else { Darwin.close(fd); return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        return LineConnection(fd: fd, queue: queue)
    }

    /// Starts reading on a connection made by `connect`, after its handlers are set.
    public static func start(_ c: LineConnection) { c.start() }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }
}
