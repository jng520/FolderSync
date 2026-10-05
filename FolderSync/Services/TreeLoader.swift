import Foundation

enum TreeLoader {
    static func loadChildren(of directory: URL, root: URL, fileManager: FileManager = .default) throws -> [FileNode] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        )
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        return urls.compactMap { url -> FileNode? in
            if url.lastPathComponent == ".DS_Store" { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isLink = values?.isSymbolicLink == true
            let isDirectory = values?.isDirectory == true && isLink == false
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
            return FileNode(
                name: url.lastPathComponent,
                relativePath: relative,
                isDirectory: isDirectory,
                children: isDirectory ? nil : []
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
