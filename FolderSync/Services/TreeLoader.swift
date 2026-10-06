import Foundation

enum TreeLoader {
    static func loadChildren(of directory: URL, root: URL, fileManager: FileManager = .default) throws -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        var urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )

        #if os(iOS)
        // Some File Provider folders can report an empty first enumeration immediately
        // after selection/restoration. Retry once before treating the folder as empty.
        if urls.isEmpty {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            )
        }
        #endif

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
                url: url,
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
