import Foundation

/// A folder or note in the sidebar tree. Children are listed lazily.
final class FileNode {
    static let noteExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    private static let ignoredNames: Set<String> = ["node_modules", ".git"]

    var url: URL
    let isFolder: Bool
    weak var parent: FileNode?
    private var loaded: [FileNode]?

    init(url: URL, isFolder: Bool, parent: FileNode? = nil) {
        self.url = url
        self.isFolder = isFolder
        self.parent = parent
    }

    /// Display name: folders as-is, files without extension.
    var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }

    var isLoaded: Bool { loaded != nil }

    var children: [FileNode] {
        if let loaded { return loaded }
        let list = list()
        loaded = list
        return list
    }

    /// Re-lists the folder, keeping existing node objects. Returns true if the listing changed.
    @discardableResult
    func reload() -> Bool {
        guard isFolder, let old = loaded else { return false }
        var existing: [String: FileNode] = [:]
        for node in old { existing[node.url.path] = node }
        let fresh = list(reusing: existing)
        let changed = fresh.count != old.count || zip(fresh, old).contains { $0 !== $1 }
        loaded = fresh
        return changed
    }

    func child(named component: String) -> FileNode? {
        children.first { $0.url.lastPathComponent == component }
    }

    private func list(reusing existing: [String: FileNode] = [:]) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var folders: [FileNode] = []
        var files: [FileNode] = []
        for u in urls {
            let name = u.lastPathComponent
            if Self.ignoredNames.contains(name) { continue }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir && !Self.noteExtensions.contains(u.pathExtension.lowercased()) { continue }
            let node = existing[u.path].flatMap { $0.isFolder == isDir ? $0 : nil }
                ?? FileNode(url: u, isFolder: isDir, parent: self)
            if isDir { folders.append(node) } else { files.append(node) }
        }
        let order: (FileNode, FileNode) -> Bool = {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return folders.sorted(by: order) + files.sorted(by: order)
    }
}

extension URL {
    /// Path with symlinks resolved via realpath (what FSEvents reports), without the `/private` stripping quirk.
    var realPathURL: URL {
        guard let p = realpath(path, nil) else { return standardizedFileURL }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: hasDirectoryPath)
    }

    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
}
