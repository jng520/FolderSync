import Foundation

enum ICloudPathMapper {
    /// Standard iCloud Drive folder inside the home directory.
    static let cloudDocsMarker = "Library/Mobile Documents/com~apple~CloudDocs"

    /// Resolve the iCloud Drive root visible to this app.
    static func iCloudDriveRoot(fileManager: FileManager = .default) -> URL? {
        #if os(macOS)
        if let container = fileManager.url(forUbiquityContainerIdentifier: nil) {
            // On macOS, prefer Finder's iCloud Drive root when it exists.
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
        #else
        // iOS has no macOS-style ~/Library/Mobile Documents path. The app's
        // entitled ubiquity container is the only home-relative iCloud root.
        return fileManager.url(forUbiquityContainerIdentifier: nil)?.standardizedFileURL
        #endif
    }

    private static func platformHomeDirectory(fileManager: FileManager) -> URL {
        #if os(macOS)
        return fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        #else
        // On iOS this is the app sandbox home, not a system-wide user home.
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        #endif
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
        let home = (home ?? platformHomeDirectory(fileManager: fileManager)).standardizedFileURL
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
