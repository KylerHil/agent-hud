import Foundation

/// A child process spoken to one JSON line at a time: lines from its stdout arrive on `queue`, and the
/// last lines of its stderr are kept for error messages.
public final class AgentProcess: @unchecked Sendable {
    public let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let queue: DispatchQueue
    private let writeLock = NSLock()
    private var stderrTail: [String] = []
    private let stderrLock = NSLock()
    private let readers = DispatchGroup()

    public var onLine: (([String: Any], Data) -> Void)?
    public var onExit: ((Int32, String) -> Void)?

    public init(executable: String, arguments: [String], cwd: String, environment: [String: String], queue: DispatchQueue) {
        self.queue = queue
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    public var pid: Int32? { process.isRunning ? process.processIdentifier : nil }
    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            DispatchQueue.global().async {
                _ = self.readers.wait(timeout: .now() + 3)
                let tail = self.lastErrors()
                self.queue.async { self.onExit?(p.terminationStatus, tail) }
            }
        }
        try process.run()
        readers.enter(); readers.enter()
        Thread.detachNewThread { [self] in readLoop(); readers.leave() }
        Thread.detachNewThread { [self] in errLoop(); readers.leave() }
    }

    private func readLoop() {
        let h = stdout.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                queue.async { [weak self] in self?.onLine?(obj, line) }
            }
        }
    }

    private func errLoop() {
        let h = stderr.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            let text = String(decoding: chunk, as: UTF8.self)
            stderrLock.lock()
            stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
            if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
            stderrLock.unlock()
        }
    }

    public func lastErrors() -> String {
        stderrLock.lock(); defer { stderrLock.unlock() }
        return stderrTail.suffix(8).joined(separator: "\n")
    }

    /// Writes one JSON object as a line. False when the process has gone.
    @discardableResult
    public func write(_ object: [String: Any]) -> Bool {
        guard process.isRunning, let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            return true
        } catch {
            return false
        }
    }

    public func closeInput() { try? stdin.fileHandleForWriting.close() }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }
}

/// `git` in a folder, with its exit status and output.
public enum Git {
    public struct Result: Sendable {
        public var status: Int32
        public var out: String
        public var err: String
        public var ok: Bool { status == 0 }
    }

    public static func run(_ args: [String], in dir: String, timeout: TimeInterval = 60) -> Result {
        shell("/usr/bin/git", args, in: dir, timeout: timeout)
    }

    /// Runs a command line through the login shell (for test commands like `pnpm test`).
    public static func sh(_ command: String, in dir: String, timeout: TimeInterval = 900) -> Result {
        let shell = AgentBinaries.environment["SHELL"] ?? "/bin/zsh"
        return Git.shell(shell, ["-l", "-c", command], in: dir, timeout: timeout)
    }

    public static func shell(_ exe: String, _ args: [String], in dir: String, timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = AgentBinaries.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        var o = Data(), e = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return Result(status: -2, out: String(decoding: o, as: UTF8.self), err: "timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }
}
