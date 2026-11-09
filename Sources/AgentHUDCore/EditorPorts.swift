import Darwin
import Foundation

/// Editor helper listeners belong in a separate inventory. Claude's IDE records can identify the
/// workspace even when an extension host's cwd is `/`. Decode only attribution fields, never tokens.
enum EditorPorts {
    private struct Record: Decodable {
        var pid: pid_t
        var ideName: String
        var workspaceFolders: [String]
    }
    private struct App: Equatable {
        var path: String
        var name: String
        var role: PortEditor.Role
    }

    static func annotate(_ endpoints: [PortEndpoint], table: [ProcTools.Entry],
                         directory: URL = Paths.userHome.appendingPathComponent(".claude/ide"),
                         executablePath: (pid_t) -> String? = ProcTools.executablePath) -> [PortEndpoint] {
        let entries = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) })
        var result = endpoints.map { endpoint -> PortEndpoint in
            guard endpoint.container == nil, !endpoint.owners.isEmpty else { return endpoint }
            let apps = endpoint.owners.compactMap { app(for: $0.executable) }
            guard apps.count == endpoint.owners.count, let first = apps.first,
                  apps.allSatisfy({ $0.path == first.path }) else { return endpoint }
            var row = endpoint
            row.editor = PortEditor(appName: first.name, role: apps.allSatisfy { $0.role == first.role } ? first.role : .helper)
            guard row.transport == .tcp, row.bindings.allSatisfy({ isLoopback($0.address) }) else { return row }
            let file = directory.appendingPathComponent("\(row.port).lock")
            guard let record = record(at: file), record.value.pid > 1,
                  endpoint.owners.allSatisfy({ owner in
                      owner.userID == geteuid() && record.modified >= owner.started
                          && belongs(record.value.pid, to: owner, app: first, entries: entries,
                                     modified: record.modified, executablePath: executablePath)
                  }), editorName(record.value.ideName, matches: first) else { return row }
            let folders = Array(Set(record.value.workspaceFolders.filter { folder in
                guard folder.hasPrefix("/"), folder.count <= 4096 else { return false }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
            }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
            row.editor = .init(appName: first.name, role: .claudeBridge, workspaceFolders: folders)
            if folders.count == 1, let folder = folders.first {
                row.project = .init(name: (folder as NSString).lastPathComponent, path: folder, evidence: "Claude IDE workspace")
            } else if folders.count > 1 {
                row.project = nil // A multi-root window must not be assigned to an arbitrary first folder.
            }
            return row
        }

        // Other listeners in the same extension-host process share its workspace. Do not propagate
        // that information to sibling hosts merely because they have the same VS Code parent PID.
        var workspaces: [PortProcessIdentity: Set<[String]>] = [:]
        for row in result where row.editor?.role == .claudeBridge {
            guard let folders = row.editor?.workspaceFolders, !folders.isEmpty else { continue }
            for owner in row.owners { workspaces[owner, default: []].insert(folders) }
        }
        for index in result.indices {
            guard var editor = result[index].editor, editor.role != .claudeBridge, !result[index].owners.isEmpty else { continue }
            let candidates = result[index].owners.compactMap { owner -> [String]? in
                guard let found = workspaces[owner], found.count == 1 else { return nil }
                return found.first
            }
            guard candidates.count == result[index].owners.count, Set(candidates).count == 1, let folders = candidates.first else { continue }
            editor.workspaceFolders = folders; result[index].editor = editor
            if folders.count == 1, let folder = folders.first {
                result[index].project = .init(name: (folder as NSString).lastPathComponent, path: folder, evidence: "Editor host workspace")
            } else { result[index].project = nil }
        }
        return result
    }

    private static func app(for path: String) -> App? {
        guard let bundle = ProcTools.outerAppBundle(of: path) else { return nil }
        let name = (bundle as NSString).lastPathComponent.lowercased()
        let display: String
        if name.contains("visual studio code") { display = name.contains("insiders") ? "VS Code Insiders" : "VS Code" }
        else if name == "cursor.app" { display = "Cursor" }
        else if name == "windsurf.app" { display = "Windsurf" }
        else { return nil }
        let executable = (path as NSString).lastPathComponent
        if path.contains("/Contents/Frameworks/"), executable.contains("Helper") {
            return App(path: bundle, name: display, role: executable.contains("(Plugin)") ? .extensionHost : .helper)
        }
        if path.hasPrefix(bundle + "/Contents/MacOS/") { return App(path: bundle, name: display, role: .service) }
        return nil
    }

    private static func editorName(_ name: String, matches app: App) -> Bool {
        let value = name.lowercased()
        if app.name.hasPrefix("VS Code") { return value.contains("visual studio code") || value == "vscode" || value == "vs code" }
        return value == app.name.lowercased()
    }

    private static func record(at file: URL) -> (value: Record, modified: Date)? {
        guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              attributes.isRegularFile == true, let size = attributes.fileSize, size <= 65_536,
              let modified = attributes.contentModificationDate,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let value = try? JSONDecoder().decode(Record.self, from: data), value.workspaceFolders.count <= 64 else { return nil }
        return (value, modified)
    }

    private static func belongs(_ pid: pid_t, to owner: PortProcessIdentity, app: App,
                                entries: [pid_t: ProcTools.Entry], modified: Date,
                                executablePath: (pid_t) -> String?) -> Bool {
        var cursor = owner.pid
        var visited = Set<pid_t>()
        for _ in 0..<32 {
            guard cursor > 1, visited.insert(cursor).inserted, let entry = entries[cursor], !entry.zombie else { return false }
            if cursor == pid {
                guard let started = entry.started, modified >= started, entry.userID == owner.userID,
                      let path = executablePath(cursor), path.hasPrefix(app.path + "/") else { return false }
                return true
            }
            cursor = entry.ppid
        }
        return false
    }

    private static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.")
    }
}
