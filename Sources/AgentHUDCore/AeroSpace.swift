import Foundation

/// Reads the order of editor windows in AeroSpace's tree, so the menu bar dots can follow it.
/// AeroSpace's CLI lists windows sorted by app and title, not by layout, and exposes no tree query.
/// The only way to learn the order is to step focus through `focus --dfs-index 0, 1, 2…` and note
/// which window each index lands on, then put focus back.
public enum AeroSpace {
    public struct Window: Decodable, Equatable, Sendable {
        public var id: Int
        public var bundleID: String?
        public var workspace: String?
        public var title: String

        enum CodingKeys: String, CodingKey {
            case id = "window-id", bundleID = "app-bundle-id", workspace, title = "window-title"
        }
    }

    public static var binary: String? {
        ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace", "/run/current-system/sw/bin/aerospace"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// VS Code-family editors, whose window titles end in the open folder's name.
    static let editorBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
    ]

    /// Folder names of the open editor windows, in tree order: workspaces in AeroSpace's order, then
    /// depth-first within each. Moves focus through every window on those workspaces, then restores it.
    /// Nil when AeroSpace isn't running.
    public static func editorWindowOrder() -> [String]? {
        guard let all = windows() else { return nil }
        let editors = all.filter { $0.bundleID.map(editorBundleIDs.contains) == true }
        guard !editors.isEmpty else { return [] }
        let spaces = Set(editors.compactMap(\.workspace))
        let ordered = (workspaces() ?? []).filter(spaces.contains)
        let startWindow = focusedWindowID()
        let startSpace = run(["list-workspaces", "--focused"])?.trimmingCharacters(in: .whitespacesAndNewlines)

        var treeOrder: [Int] = []
        var current = startSpace
        for space in ordered {
            if space != current { run(["workspace", space]) }
            current = space
            treeOrder += dfsOrder()
        }
        if let startWindow { run(["focus", "--window-id", String(startWindow)]) } else if let startSpace {
            run(["workspace", startSpace])
        }
        let byID = Dictionary(editors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return treeOrder.compactMap { byID[$0] }.map { folderName(fromTitle: $0.title) }
    }

    /// Window ids of the focused workspace in depth-first order.
    static func dfsOrder() -> [Int] {
        var ids: [Int] = []
        for i in 0..<100 {
            guard run(["focus", "--dfs-index", String(i)]) != nil, let id = focusedWindowID() else { break }
            ids.append(id)
        }
        return ids
    }

    static func windows() -> [Window]? {
        let format = "%{window-id} %{app-bundle-id} %{workspace} %{window-title}"
        guard let out = run(["list-windows", "--all", "--json", "--format", format]) else { return nil }
        return try? JSONDecoder().decode([Window].self, from: Data(out.utf8))
    }

    static func workspaces() -> [String]? {
        struct W: Decodable { var workspace: String }
        guard let out = run(["list-workspaces", "--all", "--json"]) else { return nil }
        return (try? JSONDecoder().decode([W].self, from: Data(out.utf8)))?.map(\.workspace)
    }

    static func focusedWindowID() -> Int? {
        run(["list-windows", "--focused", "--format", "%{window-id}"])
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// "main.ts — agent-hud [SSH: box]" → "agent-hud": VS Code's default title ends in the folder name.
    public static func folderName(fromTitle title: String) -> String {
        var name = title.components(separatedBy: " — ").last ?? title
        if let bracket = name.range(of: " [", options: .backwards), name.hasSuffix("]") {
            name = String(name[..<bracket.lowerBound])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Position of the window holding a session: its project root's name, else the nearest folder above
    /// its working directory (below home) that names a window. Nil when no window matches.
    public static func rank(root: String?, cwd: String?, in names: [String], home: String = Paths.userHome.path) -> Int? {
        guard !names.isEmpty else { return nil }
        var candidates: [String] = []
        if let root { candidates.append((root as NSString).lastPathComponent) }
        var dir = cwd ?? root ?? ""
        while !dir.isEmpty, dir != "/", dir != home {
            candidates.append((dir as NSString).lastPathComponent)
            dir = (dir as NSString).deletingLastPathComponent
        }
        for c in candidates {
            if let i = names.firstIndex(of: c) { return i }
        }
        return nil
    }

    @discardableResult
    static func run(_ args: [String]) -> String? {
        guard let bin = binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
