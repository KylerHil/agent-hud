import Foundation

/// Finds the VS Code-family window (VS Code, Cursor, Windsurf…) that already has a session's folder open.
/// Asking the editor to open a subfolder of an open window makes a new window; asking it to open the
/// window's own folder (or workspace file) focuses that window instead.
public enum EditorWindows {
    /// `~/Library/Application Support/<CFBundleName>/User/globalStorage/storage.json`, where the editor
    /// records its open windows.
    public static func storageFile(appPath: String) -> URL? {
        let info = Bundle(url: URL(fileURLWithPath: appPath))?.infoDictionary
        guard let name = info?["CFBundleName"] as? String else { return nil }
        return Paths.userHome.appendingPathComponent("Library/Application Support/\(name)/User/globalStorage/storage.json")
    }

    /// The folder or `.code-workspace` to open so the editor focuses the window holding `path`:
    /// the open window whose folder contains `path` most closely. Nil when no open window does.
    public static func target(storage: Data, containing path: String,
                              workspaceFolders: (URL) -> [String] = workspaceFolders(of:)) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: storage) as? [String: Any],
              let state = obj["windowsState"] as? [String: Any] else { return nil }
        var windows = (state["openedWindows"] as? [[String: Any]]) ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        var best: (url: URL, depth: Int)?
        for w in windows {
            var candidates: [(URL, [String])] = []
            if let s = w["folder"] as? String, let url = URL(string: s), url.isFileURL {
                candidates.append((url, [url.path]))
            }
            if let ws = w["workspaceIdentifier"] as? [String: Any], let s = ws["configPath"] as? String,
               let url = URL(string: s), url.isFileURL {
                candidates.append((url, workspaceFolders(url)))
            }
            for (url, folders) in candidates {
                for f in folders where ProjectRoot.contains(f, path) {
                    let depth = f.split(separator: "/").count
                    if depth > (best?.depth ?? -1) { best = (url, depth) }
                }
            }
        }
        return best?.url
    }

    /// Folders listed in a `.code-workspace` file (JSON with comments), resolved against its directory.
    public static func workspaceFolders(of file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let stripped = text.replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any],
              let folders = obj["folders"] as? [[String: Any]] else { return [] }
        let base = file.deletingLastPathComponent()
        return folders.compactMap { $0["path"] as? String }.map { p in
            p.hasPrefix("/") ? p : base.appendingPathComponent(p).standardizedFileURL.path
        }
    }
}
