import Foundation

enum CopyEngineError: LocalizedError {
    case destinationInsideSource
    case sourceMissing
    case downloadTimedOut(URL)

    var errorDescription: String? {
        switch self {
        case .destinationInsideSource:
            return "Refusing to copy: the destination is inside the source."
        case .sourceMissing:
            return "The selected file or folder no longer exists."
        case .downloadTimedOut(let url):
            return "Timed out waiting for iCloud to download \(url.lastPathComponent)."
        }
    }
}

/// Recursively copies a file or directory, creating parent folders and applying overwrite / backup policy.
actor RecursiveCopyEngine {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func copy(
        source: URL,
        destination: URL,
        options: CopyOptions,
        onLog: @Sendable (String) -> Void
    ) async throws -> CopySummary {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        var summary = CopySummary()

        guard fileManager.fileExists(atPath: source.path) else {
            throw CopyEngineError.sourceMissing
        }
        if ICloudPathMapper.isDescendant(destination, of: source), destination.path != source.path {
            throw CopyEngineError.destinationInsideSource
        }

        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            try await copyDirectory(source, to: destination, options: options, summary: &summary, onLog: onLog)
        } else {
            try await copyOneFile(source, to: destination, options: options, summary: &summary, onLog: onLog)
        }
        return summary
    }

    private func copyDirectory(
        _ source: URL,
        to destination: URL,
        options: CopyOptions,
        summary: inout CopySummary,
        onLog: @Sendable (String) -> Void
    ) async throws {
        try createDirectoryIfNeeded(destination, summary: &summary, onLog: onLog)

        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
            options: [.skipsPackageDescendants]
        ) else {
            summary.failures.append("Could not read \(source.path)")
            return
        }

        let rootPath = source.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for case let item as URL in enumerator {
            let itemPath = item.standardizedFileURL.path
            if options.skipDSStore, item.lastPathComponent == ".DS_Store" {
                summary.skipped += 1
                continue
            }
            let relative = itemPath.hasPrefix(prefix) ? String(itemPath.dropFirst(prefix.count)) : item.lastPathComponent
            let target = destination.appending(path: relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values.isSymbolicLink == true {
                try copySymlink(item, to: target, options: options, summary: &summary, onLog: onLog)
                continue
            }
            if values.isDirectory == true {
                try createDirectoryIfNeeded(target, summary: &summary, onLog: onLog)
                continue
            }
            try await copyOneFile(item, to: target, options: options, summary: &summary, onLog: onLog)
        }
    }

    private func copyOneFile(
        _ source: URL,
        to destination: URL,
        options: CopyOptions,
        summary: inout CopySummary,
        onLog: @Sendable (String) -> Void
    ) async throws {
        if options.skipDSStore, source.lastPathComponent == ".DS_Store" {
            summary.skipped += 1
            return
        }
        try await ensureDownloaded(source, options: options, onLog: onLog)
        try createDirectoryIfNeeded(destination.deletingLastPathComponent(), summary: &summary, onLog: onLog)

        if fileManager.fileExists(atPath: destination.path) {
            if options.keepBackup {
                let backup = try makeBackup(of: destination)
                onLog("Backup \(destination.path) → \(backup.path)")
                summary.backedUp += 1
            } else if options.overwrite {
                try fileManager.removeItem(at: destination)
                onLog("Overwrite \(destination.path)")
            } else {
                onLog("Skip existing \(destination.path)")
                summary.skipped += 1
                return
            }
        }

        try fileManager.copyItem(at: source, to: destination)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        summary.bytesCopied += size
        summary.filesCopied += 1
        onLog("Copied \(source.lastPathComponent) → \(destination.path)")
    }

    private func copySymlink(
        _ source: URL,
        to destination: URL,
        options: CopyOptions,
        summary: inout CopySummary,
        onLog: @Sendable (String) -> Void
    ) throws {
        try createDirectoryIfNeeded(destination.deletingLastPathComponent(), summary: &summary, onLog: onLog)
        if fileManager.fileExists(atPath: destination.path) {
            if options.keepBackup {
                let backup = try makeBackup(of: destination)
                summary.backedUp += 1
                onLog("Backup \(destination.path) → \(backup.path)")
            } else if options.overwrite {
                try fileManager.removeItem(at: destination)
            } else {
                summary.skipped += 1
                onLog("Skip existing symlink \(destination.path)")
                return
            }
        }
        let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: linkTarget)
        summary.filesCopied += 1
        onLog("Linked \(destination.lastPathComponent) → \(linkTarget)")
    }

    private func createDirectoryIfNeeded(
        _ url: URL,
        summary: inout CopySummary,
        onLog: @Sendable (String) -> Void
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        summary.directoriesCreated += 1
        onLog("Created \(url.path)")
    }

    private func makeBackup(of url: URL) throws -> URL {
        let stamp = Self.backupStamp.string(from: Date())
        var candidate = url.appendingPathExtension("bak-\(stamp)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathExtension("bak-\(stamp)-\(counter)")
            counter += 1
        }
        try fileManager.moveItem(at: url, to: candidate)
        return candidate
    }

    private func ensureDownloaded(
        _ url: URL,
        options: CopyOptions,
        onLog: @Sendable (String) -> Void
    ) async throws {
        guard options.downloadFromICloud else { return }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }

        onLog("Downloading from iCloud: \(url.lastPathComponent)")
        try fileManager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(options.downloadTimeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(400))
            let status = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == .current { return }
        }
        throw CopyEngineError.downloadTimedOut(url)
    }

    private static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
