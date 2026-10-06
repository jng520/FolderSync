import Foundation

/// Keeps file coordination off the main actor and makes cancellation safe to capture
/// from Swift concurrency cancellation handlers.
private final class FileCoordinationHandle: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    let queue: OperationQueue

    init() {
        let queue = OperationQueue()
        queue.name = "FolderSync.FileCoordination"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.queue = queue
    }
}

enum CopyEngineError: LocalizedError {
    case destinationInsideSource
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .destinationInsideSource:
            return "Refusing to copy: the destination is inside the source."
        case .sourceMissing:
            return "The selected file or folder no longer exists."
        }
    }
}

/// Recursively copies a file or directory, creating parent folders and applying overwrite / backup policy.
actor RecursiveCopyEngine {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func delete(
        url: URL,
        onLog: @Sendable (String) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let url = url.standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            throw CopyEngineError.sourceMissing
        }
        try fileManager.removeItem(at: url)
        try Task.checkCancellation()
        await onLog("Deleted \(url.path)")
    }

    func workload(source: URL, options: CopyOptions) throws -> CopyWorkload {
        try Task.checkCancellation()
        let source = source.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw CopyEngineError.sourceMissing
        }

        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue == false {
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return CopyWorkload(itemCount: 1, byteCount: size)
        }

        guard let items = directoryItems(at: source) else {
            return CopyWorkload(itemCount: 1, byteCount: 0)
        }

        var workload = CopyWorkload(itemCount: 1, byteCount: 0) // the selected directory itself
        for item in items {
            try Task.checkCancellation()
            if options.skipDSStore, item.lastPathComponent == ".DS_Store" { continue }
            workload.itemCount += 1
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory != true {
                workload.byteCount += Int64(values?.fileSize ?? 0)
            }
        }
        return workload
    }

    /// Builds the confirmation list without downloading file contents.
    /// Directories are expanded into individual files so the user can choose exactly what transfers.
    func transferPlan(
        destinationRoot: URL,
        selectedSources: [TransferSourceItem],
        options: CopyOptions
    ) throws -> [TransferFileItem] {
        try Task.checkCancellation()
        let destinationRoot = destinationRoot.standardizedFileURL
        var result: [TransferFileItem] = []
        var seen = Set<String>()

        for selection in selectedSources {
            try Task.checkCancellation()
            let source = selection.sourceURL

            if selection.isDirectory {
                guard let children = directoryItems(at: source) else { continue }
                let selectedPath = source.path
                let selectedPrefix = selectedPath.hasSuffix("/") ? selectedPath : selectedPath + "/"

                for child in children {
                    try Task.checkCancellation()
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                    guard values?.isDirectory != true else { continue }
                    if options.skipDSStore, child.lastPathComponent == ".DS_Store" { continue }

                    let childPath = child.path
                    let childRelative: String
                    if childPath.hasPrefix(selectedPrefix) {
                        childRelative = String(childPath.dropFirst(selectedPrefix.count))
                    } else {
                        childRelative = child.lastPathComponent
                    }
                    let relativePath = selection.relativePath.isEmpty
                        ? childRelative
                        : selection.relativePath + "/" + childRelative
                    try appendTransferItem(
                        source: child,
                        relativePath: relativePath,
                        destinationRoot: destinationRoot,
                        seen: &seen,
                        result: &result
                    )
                }
            } else {
                if options.skipDSStore, source.lastPathComponent == ".DS_Store" { continue }
                try appendTransferItem(
                    source: source,
                    relativePath: selection.relativePath,
                    destinationRoot: destinationRoot,
                    seen: &seen,
                    result: &result
                )
            }
        }

        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Requests the download of one exact iCloud file when needed.
    ///
    /// Important: this deliberately does not wait for
    /// `ubiquitousItemDownloadingStatus` to change. File Provider metadata can lag
    /// behind the actual file state on iOS. Waiting on that metadata made tiny files
    /// appear to hang for the full timeout. The real copy uses NSFileCoordinator,
    /// which materializes the file as part of the coordinated read.
    func syncICloudFile(
        url: URL,
        onProgress: @Sendable (ICloudSyncProgress) async -> Void,
        onLog: @Sendable (String) async -> Void
    ) async throws -> ICloudSyncSummary {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey
        ])
        guard values.isDirectory != true, values.isUbiquitousItem == true else {
            return ICloudSyncSummary()
        }

        let size = Int64(values.fileSize ?? 0)
        if Self.isDownloaded(values.ubiquitousItemDownloadingStatus) {
            return ICloudSyncSummary(totalItems: 1, downloadsRequested: 0, bytesPrepared: size)
        }

        await onProgress(
            ICloudSyncProgress(
                currentPath: url.path,
                completedItems: 0,
                totalItems: 1,
                completedBytes: 0,
                totalBytes: size,
                downloadsRequested: 0
            )
        )

        let requested = try await requestDownloadIfNeeded(url, onLog: onLog)
        let summary = ICloudSyncSummary(
            totalItems: 1,
            downloadsRequested: requested ? 1 : 0,
            bytesPrepared: 0
        )
        await onProgress(
            ICloudSyncProgress(
                currentPath: url.path,
                completedItems: 1,
                totalItems: 1,
                completedBytes: 0,
                totalBytes: size,
                downloadsRequested: summary.downloadsRequested
            )
        )
        return summary
    }

    func copy(
        source: URL,
        destination: URL,
        options: CopyOptions,
        onProgress: @Sendable (CopyProgressEvent) async -> Void,
        onLog: @Sendable (String) async -> Void
    ) async throws -> CopySummary {
        try Task.checkCancellation()
        // Keep the exact source URL supplied by File Provider. Standardizing or
        // reconstructing it can turn a valid provider item into a path that is not
        // currently materialized. The destination is a normal writable path.
        let destination = destination.standardizedFileURL
        var summary = CopySummary()

        // Do not reject a File Provider/iCloud placeholder just because fileExists is
        // temporarily false. A coordinated read below is allowed to materialize it.
        if ICloudPathMapper.isDescendant(destination, of: source), destination.path != source.path {
            throw CopyEngineError.destinationInsideSource
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if exists == false,
           let values = try? source.resourceValues(forKeys: [.isDirectoryKey]) {
            isDirectory = ObjCBool(values.isDirectory == true)
        }

        if isDirectory.boolValue {
            try await copyDirectory(
                source,
                to: destination,
                options: options,
                summary: &summary,
                onProgress: onProgress,
                onLog: onLog
            )
        } else {
            let event = try await copyOneFile(
                source,
                to: destination,
                options: options,
                summary: &summary,
                onLog: onLog
            )
            await onProgress(event)
        }
        return summary
    }

    private func copyDirectory(
        _ source: URL,
        to destination: URL,
        options: CopyOptions,
        summary: inout CopySummary,
        onProgress: @Sendable (CopyProgressEvent) async -> Void,
        onLog: @Sendable (String) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let rootCreated = try createDirectoryIfNeeded(destination, summary: &summary)
        if rootCreated { await onLog("Created \(destination.path)") }
        await onProgress(
            CopyProgressEvent(
                path: source.path,
                directoriesCreated: rootCreated ? 1 : 0
            )
        )

        guard let items = directoryItems(at: source) else {
            summary.failures.append("Could not read \(source.path)")
            return
        }

        let rootPath = source.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        // Snapshot the directory enumerator synchronously before any `await`.
        // NSDirectoryEnumerator.makeIterator() is unavailable from async contexts
        // in Swift 6 because the enumerator itself is not concurrency-safe.
        for item in items {
            try Task.checkCancellation()
            let itemPath = item.standardizedFileURL.path
            if options.skipDSStore, item.lastPathComponent == ".DS_Store" {
                summary.skipped += 1
                await onProgress(CopyProgressEvent(path: item.path, completedItems: 0, skipped: 1))
                continue
            }
            let relative = itemPath.hasPrefix(prefix) ? String(itemPath.dropFirst(prefix.count)) : item.lastPathComponent
            let target = destination.appending(path: relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values.isSymbolicLink == true {
                let event = try await copySymlink(
                    item,
                    to: target,
                    options: options,
                    summary: &summary,
                    onLog: onLog
                )
                await onProgress(event)
                continue
            }
            if values.isDirectory == true {
                let created = try createDirectoryIfNeeded(target, summary: &summary)
                if created { await onLog("Created \(target.path)") }
                await onProgress(
                    CopyProgressEvent(
                        path: item.path,
                        directoriesCreated: created ? 1 : 0
                    )
                )
                continue
            }
            let event = try await copyOneFile(
                item,
                to: target,
                options: options,
                summary: &summary,
                onLog: onLog
            )
            await onProgress(event)
        }
    }

    private func appendTransferItem(
        source: URL,
        relativePath: String,
        destinationRoot: URL,
        seen: inout Set<String>,
        result: inout [TransferFileItem]
    ) throws {
        guard relativePath.isEmpty == false, seen.insert(relativePath).inserted else { return }

        let sourceValues = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sourceSize = Int64(sourceValues?.fileSize ?? 0)
        let destination = destinationRoot.appending(path: relativePath)
        var destinationSize: Int64?
        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
           destinationIsDirectory.boolValue == false {
            destinationSize = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        result.append(
            TransferFileItem(
                relativePath: relativePath,
                sourceURL: source,
                destinationURL: destination,
                sourceSize: sourceSize,
                destinationSize: destinationSize,
                modifiedDate: sourceValues?.contentModificationDate
            )
        )
    }

    private func directoryItems(at source: URL) -> [URL]? {
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ],
            options: [.skipsPackageDescendants]
        ) else {
            return nil
        }

        var items: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            items.append(item)
        }
        return items
    }

    private func copyOneFile(
        _ source: URL,
        to destination: URL,
        options: CopyOptions,
        summary: inout CopySummary,
        onLog: @Sendable (String) async -> Void
    ) async throws -> CopyProgressEvent {
        try Task.checkCancellation()
        if options.skipDSStore, source.lastPathComponent == ".DS_Store" {
            summary.skipped += 1
            return CopyProgressEvent(path: source.path, skipped: 1)
        }
        if options.downloadFromICloud {
            do {
                _ = try await requestDownloadIfNeeded(source, onLog: onLog)
            } catch {
                // A File Provider placeholder may report metadata/start-download errors
                // even though a coordinated read can still materialize it. Do not fail
                // the transfer before the real coordinated read gets a chance.
                await onLog("iCloud prefetch warning for \(source.lastPathComponent): \(error.localizedDescription). Continuing with coordinated read.")
            }
        }
        try Task.checkCancellation()

        let parentCreated = try createDirectoryIfNeeded(destination.deletingLastPathComponent(), summary: &summary)
        if parentCreated { await onLog("Created \(destination.deletingLastPathComponent().path)") }

        var backedUp = 0
        if fileManager.fileExists(atPath: destination.path) {
            if options.keepBackup {
                let backup = try makeBackup(of: destination)
                await onLog("Backup \(destination.path) → \(backup.path)")
                summary.backedUp += 1
                backedUp = 1
            } else if options.overwrite {
                try fileManager.removeItem(at: destination)
                await onLog("Overwrite \(destination.path)")
            } else {
                await onLog("Skip existing \(destination.path)")
                summary.skipped += 1
                return CopyProgressEvent(
                    path: source.path,
                    directoriesCreated: parentCreated ? 1 : 0,
                    skipped: 1,
                    backedUp: backedUp
                )
            }
        }

        try Task.checkCancellation()
        try await coordinatedCopyItem(from: source, to: destination)
        try Task.checkCancellation()
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        summary.bytesCopied += size
        summary.filesCopied += 1
        await onLog("Copied \(source.lastPathComponent) → \(destination.path)")
        return CopyProgressEvent(
            path: source.path,
            bytesCopied: size,
            filesCopied: 1,
            directoriesCreated: parentCreated ? 1 : 0,
            backedUp: backedUp
        )
    }

    private func copySymlink(
        _ source: URL,
        to destination: URL,
        options: CopyOptions,
        summary: inout CopySummary,
        onLog: @Sendable (String) async -> Void
    ) async throws -> CopyProgressEvent {
        try Task.checkCancellation()
        let parentCreated = try createDirectoryIfNeeded(destination.deletingLastPathComponent(), summary: &summary)
        if parentCreated { await onLog("Created \(destination.deletingLastPathComponent().path)") }

        var backedUp = 0
        if fileManager.fileExists(atPath: destination.path) {
            if options.keepBackup {
                let backup = try makeBackup(of: destination)
                summary.backedUp += 1
                backedUp = 1
                await onLog("Backup \(destination.path) → \(backup.path)")
            } else if options.overwrite {
                try fileManager.removeItem(at: destination)
            } else {
                summary.skipped += 1
                await onLog("Skip existing symlink \(destination.path)")
                return CopyProgressEvent(
                    path: source.path,
                    directoriesCreated: parentCreated ? 1 : 0,
                    skipped: 1,
                    backedUp: backedUp
                )
            }
        }
        try Task.checkCancellation()
        let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: linkTarget)
        summary.filesCopied += 1
        await onLog("Linked \(destination.lastPathComponent) → \(linkTarget)")
        return CopyProgressEvent(
            path: source.path,
            filesCopied: 1,
            directoriesCreated: parentCreated ? 1 : 0,
            backedUp: backedUp
        )
    }

    @discardableResult
    private func createDirectoryIfNeeded(
        _ url: URL,
        summary: inout CopySummary
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return false }
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        summary.directoriesCreated += 1
        return true
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

    /// Ask iCloud/File Provider for this exact file, but do not poll metadata waiting
    /// for the request to finish. The coordinated read below is the source of truth.
    @discardableResult
    private func requestDownloadIfNeeded(
        _ url: URL,
        onLog: @Sendable (String) async -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadRequestedKey,
                .ubiquitousItemDownloadingErrorKey
            ])
        } catch {
            await onLog("Could not read iCloud metadata for \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        guard values.isUbiquitousItem == true else { return false }
        if let error = values.ubiquitousItemDownloadingError {
            throw error
        }
        if Self.isDownloaded(values.ubiquitousItemDownloadingStatus) { return false }
        if values.ubiquitousItemDownloadRequested == true { return false }

        await onLog("Requested iCloud download: \(url.lastPathComponent)")
        try fileManager.startDownloadingUbiquitousItem(at: url)
        return true
    }

    /// Coordinate the source read on a utility queue. For an iCloud/File Provider
    /// placeholder, Foundation can materialize the file before entering the accessor.
    /// Always copy from the URL supplied to the accessor: File Provider is allowed to
    /// substitute a different URL from the one originally requested.
    private func coordinatedCopyItem(from source: URL, to destination: URL) async throws {
        let handle = FileCoordinationHandle()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handle.queue.addOperation {
                    var coordinationError: NSError?
                    var accessorError: Error?
                    var accessorRan = false

                    handle.coordinator.coordinate(
                        readingItemAt: source,
                        options: [],
                        error: &coordinationError
                    ) { coordinatedSource in
                        accessorRan = true
                        do {
                            try FileManager.default.copyItem(at: coordinatedSource, to: destination)
                        } catch {
                            accessorError = error
                        }
                    }

                    if let accessorError {
                        continuation.resume(throwing: accessorError)
                    } else if let coordinationError {
                        continuation.resume(throwing: coordinationError)
                    } else if accessorRan == false {
                        continuation.resume(throwing: CopyEngineError.sourceMissing)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        } onCancel: {
            handle.coordinator.cancel()
        }
    }

    private static func isDownloaded(_ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .current || status == .downloaded
    }

    private static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
