import Darwin
import XCTest
@testable import AgentHUDCore

final class ProcToolsTests: XCTestCase {
    private func process(_ pid: pid_t, device: dev_t) -> kinfo_proc {
        var info = kinfo_proc()
        info.kp_proc.p_pid = pid
        info.kp_eproc.e_tdev = device
        return info
    }

    func testSharedTerminalResolvesOncePerSnapshot() {
        let infos = [process(10, device: 42), process(11, device: 42), process(12, device: -1)]
        var calls = 0
        let entries = ProcTools.makeEntries(infos[...]) { device in
            XCTAssertEqual(device, 42)
            calls += 1
            return "ttys012"
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(entries.map(\.tty), ["ttys012", "ttys012", nil])
        XCTAssertEqual(entries.map(\.pid), [10, 11, 12])
    }

    func testUnresolvedTerminalIsCachedWithinSnapshot() {
        let infos = [process(10, device: 42), process(11, device: 42)]
        var calls = 0
        let entries = ProcTools.makeEntries(infos[...]) { _ in
            calls += 1
            return nil
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(entries.allSatisfy { $0.tty == nil })
    }

    func testTerminalMappingsDoNotSurviveNewSnapshot() {
        let infos = [process(10, device: 42), process(11, device: 42)]
        var calls = 0
        let missing = ProcTools.makeEntries(infos[...]) { _ in
            calls += 1
            return nil
        }
        let reconnected = ProcTools.makeEntries(infos[...]) { _ in
            calls += 1
            return "ttys099"
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(missing.allSatisfy { $0.tty == nil })
        XCTAssertEqual(reconnected.map(\.tty), ["ttys099", "ttys099"])
    }
}
