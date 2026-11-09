import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class EditorPortTests: XCTestCase {
    private let bundle = "/Applications/Visual Studio Code.app"
    private var helper: String { bundle + "/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)" }
    private var parent: String { bundle + "/Contents/MacOS/Code" }
    private func owner(_ pid: pid_t = 200) -> PortProcessIdentity {
        .init(pid: pid, started: Date(timeIntervalSince1970: 100), executable: helper, userID: geteuid())
    }
    private func entry(_ pid: pid_t, parent: pid_t, started: TimeInterval = 100) -> ProcTools.Entry {
        .init(pid: pid, ppid: parent, comm: "Code", tty: nil, started: Date(timeIntervalSince1970: started), userID: geteuid())
    }
    private var table: [ProcTools.Entry] { [entry(100, parent: 1, started: 50), entry(200, parent: 100), entry(201, parent: 100)] }
    private func row(_ port: UInt16 = 11979, pid: pid_t = 200, address: String = "127.0.0.1") -> PortEndpoint {
        .init(bindings: [.init(address: address, port: port)], owners: [owner(pid)])
    }
    private func annotate(_ rows: [PortEndpoint], folder: URL, table: [ProcTools.Entry]? = nil) -> [PortEndpoint] {
        EditorPorts.annotate(rows, table: table ?? self.table, directory: folder) { pid in
            pid == 100 ? self.parent : self.helper
        }
    }
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-editor-port-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func workspace(_ folder: URL, name: String = "load-traxx") throws -> String {
        let path = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path.path
    }
    private func write(_ folder: URL, port: UInt16 = 11979, pid: pid_t = 100, folders: [String],
                       editor: String = "Visual Studio Code", modified: TimeInterval = 200) throws {
        let file = folder.appendingPathComponent("\(port).lock")
        let data = try JSONSerialization.data(withJSONObject: ["pid": pid, "ideName": editor, "workspaceFolders": folders,
                                                              "authToken": "ignored-fixture-field"])
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
    }

    func testClaudeBridgeMatchesLiveEditorAncestryAndWorkspace() throws {
        let folder = try fixture(), path = try workspace(folder)
        try write(folder, folders: [path])
        let original = row()
        let enriched = try XCTUnwrap(annotate([original], folder: folder).first)
        XCTAssertEqual(enriched.title, "load-traxx")
        XCTAssertEqual(enriched.subtitle, "Claude IDE bridge · VS Code")
        XCTAssertEqual(enriched.project?.path, path)
        XCTAssertEqual(enriched.source, .editor)
        XCTAssertEqual(enriched.id, original.id)
        XCTAssertEqual(enriched.owners, original.owners)
        XCTAssertNil(enriched.browserURL)
    }

    func testWorkspacePropagatesToSameHostButNotSiblingWindow() throws {
        let folder = try fixture(), path = try workspace(folder)
        try write(folder, folders: [path])
        let rows = annotate([row(), row(63099), row(63111, pid: 201)], folder: folder)
        XCTAssertEqual(rows[1].title, "load-traxx")
        XCTAssertEqual(rows[1].subtitle, "Extension host · VS Code")
        XCTAssertEqual(rows[1].project?.evidence, "Editor host workspace")
        XCTAssertEqual(rows[2].title, "VS Code")
        XCTAssertNil(rows[2].project)
        XCTAssertEqual(rows[2].editor?.workspaceFolders, [])
    }

    func testStaleRecordsCannotAttributeAReusedPortOrPID() throws {
        let folder = try fixture(), path = try workspace(folder)
        try write(folder, pid: 999, folders: [path])
        XCTAssertNil(annotate([row()], folder: folder)[0].project)
        try write(folder, folders: [path], modified: 75)
        XCTAssertEqual(annotate([row()], folder: folder)[0].editor?.role, .extensionHost)
        try write(folder, folders: [path])
        let reusedParent = [entry(100, parent: 1, started: 250), entry(200, parent: 100)]
        XCTAssertNil(annotate([row()], folder: folder, table: reusedParent)[0].project)
    }

    func testMultiRootWorkspaceDoesNotChooseAnArbitraryProject() throws {
        let folder = try fixture(), one = try workspace(folder, name: "api"), two = try workspace(folder, name: "mobile")
        try write(folder, folders: [two, one, one])
        let result = annotate([row()], folder: folder)[0]
        XCTAssertNil(result.project)
        XCTAssertEqual(result.title, "VS Code · 2 workspaces")
        XCTAssertEqual(result.editor?.workspaceFolders, [one, two].sorted())
    }

    func testWrongEditorNonLoopbackAndMissingMetadataRemainGenericInternals() throws {
        let folder = try fixture(), path = try workspace(folder)
        XCTAssertEqual(annotate([row()], folder: folder)[0].source, .editor)
        try write(folder, folders: [path], editor: "Cursor")
        XCTAssertNil(annotate([row()], folder: folder)[0].project)
        try write(folder, folders: [path])
        let exposed = annotate([row(address: "0.0.0.0")], folder: folder)[0]
        XCTAssertEqual(exposed.editor?.role, .extensionHost)
        XCTAssertNil(exposed.project)
    }

    func testMalformedAndOversizedRecordsAreIgnored() throws {
        let folder = try fixture()
        let file = folder.appendingPathComponent("11979.lock")
        try Data("not JSON".utf8).write(to: file)
        XCTAssertEqual(annotate([row()], folder: folder)[0].editor?.role, .extensionHost)
        try Data(repeating: 65, count: 70_000).write(to: file)
        XCTAssertNil(annotate([row()], folder: folder)[0].project)
        try write(folder, folders: [folder.appendingPathComponent("missing-folder").path])
        let result = annotate([row()], folder: folder)[0]
        XCTAssertEqual(result.editor?.role, .claudeBridge)
        XCTAssertNil(result.project)
    }

    func testHelpersAreRecognizedByAppPathNotProcessNameAlone() throws {
        let folder = try fixture()
        var namedLikeEditor = row()
        namedLikeEditor.owners[0].executable = "/usr/local/bin/Code Helper (Plugin)"
        let result = annotate([namedLikeEditor], folder: folder)[0]
        XCTAssertNil(result.editor)
        XCTAssertEqual(result.source, .other)
        var mixed = row()
        mixed.owners.append(namedLikeEditor.owners[0])
        XCTAssertNil(annotate([mixed], folder: folder)[0].editor)
    }

    func testDefaultInventoryExcludesEditorPortsEvenWithAProject() {
        var editor = row()
        editor.editor = .init(appName: "VS Code", role: .claudeBridge)
        editor.project = .init(name: "mobile", path: "/work/mobile", evidence: "Claude IDE workspace")
        var local = row(3003); local.owners[0].executable = "/opt/homebrew/bin/node"
        local.project = .init(name: "mobile", path: "/work/mobile", evidence: "Git project folder")
        var docker = row(5433); docker.owners = []
        docker.container = .init(id: String(repeating: "a", count: 64), name: "db", image: "postgres", context: "local", internalPort: 5432)
        var other = row(7000); other.owners[0].executable = "/usr/local/bin/server"
        let rows = [editor, local, docker, other]
        XCTAssertEqual(rows.filter { PortFilter.all.includes($0) }.map(\.port), [3003, 5433, 7000])
        XCTAssertEqual(rows.filter { PortFilter.editor.includes($0) }.map(\.port), [11979])
        XCTAssertEqual(rows.filter { PortFilter.local.includes($0) }.map(\.port), [3003])
        XCTAssertEqual(rows.filter { PortFilter.other.includes($0) }.map(\.port), [7000])
    }
}
