import Foundation

enum ICloudPathMapper {
    /// Standard iCloud Drive folder inside the home directory.
    static let cloudDocsMarker = "Library/Mobile Documents/com~apple~CloudDocs"

    /// Resolve the iCloud Drive root for the current user.
    /// Prefers the ubiquity container when the system can see it, then falls back to the well-known path.
    static func iCloudDriveRoot(fileManager: FileManager = .default) -> URL? {
        if let container = fileManager.url(forUbiquityContainerIdentifier: nil) {
            // `forUbiquityContainerIdentifier: nil` is the app's own container when entitled.
            // The Drive root the Finder shows is the sibling CloudDocs folder, so prefer that when present.
            let cloudDocs = fileManager
                .homeDirectoryForCurrentUser
                .appending(path: cloudDocsMarker, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: cloudDocs.path) {
                return cloudDocs.standardizedFileURL
            }
            return container.standardizedFileURL
        }
        let cloudDocs = fileManager
            .homeDirectoryForCurrentUser
            .appending(path: cloudDocsMarker, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: cloudDocs.path) {
            return cloudDocs.standardizedFileURL
        }
        return nil
    }

    /// Map a selected file or folder onto the home directory, preserving the path under iCloud Drive.
    ///
    /// `iCloud Drive/Work/Clients/Acme/brief.pdf` becomes `~/Work/Clients/Acme/brief.pdf`.
    /// Parent folders are not created here; the copy engine does that.
    static func mapToHome(
        source: URL,
        home: URL? = nil,
        iCloudRoot explicitRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> MappedPath {
        let source = source.standardizedFileURL
        let home = (home ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        let root = (explicitRoot ?? iCloudDriveRoot(fileManager: fileManager))?.standardizedFileURL

        if let root, isDescendant(source, of: root) {
            let relative = relativePath(from: root, to: source)
            return MappedPath(
                iCloudRoot: root,
                relativePath: relative,
                destination: home.appending(path: relative),
                explanation: "Path is relative to iCloud Drive and will be recreated under your home directory."
            )
        }

        // Selection is already under home but not inside iCloud Drive. Mirroring would be a no-op,
        // so place it under ~/iCloudMirror/<last path components> only when it is outside home.
        if isDescendant(source, of: home) {
            let relative = relativePath(from: home, to: source)
            return MappedPath(
                iCloudRoot: root,
                relativePath: relative,
                destination: home.appending(path: relative),
                explanation: "Selection is already under your home directory (not inside iCloud Drive). Destination matches the source path."
            )
        }

        let relative = source.lastPathComponent
        return MappedPath(
            iCloudRoot: root,
            relativePath: relative,
            destination: home.appending(path: relative),
            explanation: "Selection is outside iCloud Drive and outside your home directory. Only the file or folder name is used under home."
        )
    }

    static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let child = url.standardizedFileURL.path
        var parent = ancestor.standardizedFileURL.path
        if parent.hasSuffix("/") == false { parent += "/" }
        if child == ancestor.standardizedFileURL.path { return true }
        return child.hasPrefix(parent)
    }

    static func relativePath(from root: URL, to url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full == rootPath { return url.lastPathComponent }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }
}
