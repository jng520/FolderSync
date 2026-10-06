import Foundation
import Observation

@MainActor
@Observable
final class MirrorViewModel {
    var leftRoot: URL?
    var rightRoot: URL?
    var leftNodes: [FileNode] = []
    var rightNodes: [FileNode] = []
    var overwrite: Bool {
        didSet { UserDefaults.standard.set(overwrite, forKey: Self.overwriteKey) }
    }
    var keepBackup: Bool {
        didSet { UserDefaults.standard.set(keepBackup, forKey: Self.keepBackupKey) }
    }
    var isBusy = false
    var statusText = "Select a root folder on each side."
    var logLines: [String] = []
    var selectedPath: String?
    var alignRequest: AlignRequest?
    var progress: OperationProgress?
    var transferReview: TransferReviewState?

    private let engine = RecursiveCopyEngine()
    private var leftScope: SecurityScope?
    private var rightScope: SecurityScope?
    private var alignToken = 0
    private var operationTask: Task<Void, Never>?

    private static let overwriteKey = "FolderSync.settings.overwrite"
    private static let keepBackupKey = "FolderSync.settings.keepBackup"

    init() {
        let defaults = UserDefaults.standard
        overwrite = defaults.object(forKey: Self.overwriteKey) as? Bool ?? false
        keepBackup = defaults.object(forKey: Self.keepBackupKey) as? Bool ?? true
        restoreBookmarkedRoots()
    }

    var canPushLeftToRight: Bool { canPush(from: .left) }
    var canPushRightToLeft: Bool { canPush(from: .right) }

    func canDelete(_ side: BrowserSide) -> Bool {
        isBusy == false && root(for: side) != nil && checkedNodes(in: nodes(for: side)).isEmpty == false
    }

    func setRoot(_ url: URL, side: BrowserSide) async {
        let scope = SecurityScope(url)
        setScope(scope, side: side)

        do {
            try FolderBookmarkStore.save(url, for: side)
        } catch {
            append("Could not bookmark \(side.title) root: \(error.localizedDescription)")
        }

        loadRoot(url, side: side)
        statusText = "\(side.title) root: \(url.path)"
        append("\(side.title) root \(url.path)")
    }

    func reportPickerError(_ error: Error) {
        statusText = "Folder selection failed: \(error.localizedDescription)"
        append(statusText)
    }

    func toggleExpand(_ side: BrowserSide, path: String) {
        guard let root = root(for: side) else { return }
        var nodes = nodes(for: side)
        guard let node = find(path, in: nodes) else { return }
        if node.isExpanded {
            _ = update(&nodes, path: path) { $0.isExpanded = false }
        } else if node.isLoaded {
            _ = update(&nodes, path: path) { $0.isExpanded = true }
        } else {
            let url = node.url
            let children = (try? TreeLoader.loadChildren(of: url, root: root)) ?? []
            _ = update(&nodes, path: path) {
                $0.children = children
                $0.isExpanded = true
                if $0.isChecked {
                    markAll(&($0.children!), checked: true)
                }
            }
        }
        setNodes(nodes, side: side)
    }

    /// Align this path on both sides. Clicking an individual iCloud file also prefetches that file only.
    func focus(_ path: String, on side: BrowserSide, fraction: CGFloat) {
        selectedPath = path
        let leftTarget = reveal(path, on: .left)
        let rightTarget = reveal(path, on: .right)
        alignToken += 1
        alignRequest = AlignRequest(
            token: alignToken,
            path: path,
            leftTarget: leftTarget,
            rightTarget: rightTarget,
            fraction: min(max(fraction, 0), 1)
        )
        if leftTarget != path || rightTarget != path {
            statusText = "No matching item for \(path) on the other side. Showing \(leftTarget == path ? rightTarget : leftTarget)."
        }
        startICloudSyncForClickedItem(path, on: side)
    }

    func toggleCheck(_ side: BrowserSide, path: String) {
        var nodes = nodes(for: side)
        let isDirectory = find(path, in: nodes)?.isDirectory == true
        var becameChecked = false
        _ = update(&nodes, path: path) { node in
            node.isChecked.toggle()
            becameChecked = node.isChecked
            if var children = node.children {
                markAll(&children, checked: node.isChecked)
                node.children = children
            }
        }
        setNodes(nodes, side: side)
        if becameChecked, isDirectory == false {
            startICloudSyncForClickedItem(path, on: side)
        }
    }

    /// Build a file-by-file transfer review. No copy starts until the user confirms the checked rows.
    func startPush(from sourceSide: BrowserSide) {
        guard isBusy == false else { return }
        guard root(for: sourceSide) != nil, root(for: sourceSide.opposite) != nil else { return }
        let selected = jobsCovering(checkedNodes(in: nodes(for: sourceSide)))
        guard selected.isEmpty == false else { return }

        isBusy = true
        progress = OperationProgress(
            kind: .copying,
            title: "Preparing transfer list",
            detail: "Scanning selected files…"
        )
        let selectedSources = selected.map {
            TransferSourceItem(
                relativePath: $0.relativePath,
                sourceURL: $0.url,
                isDirectory: $0.isDirectory
            )
        }
        let viewModel = self
        operationTask = Task { @MainActor [viewModel] in
            await viewModel.prepareTransferReview(from: sourceSide, selectedSources: selectedSources)
            viewModel.finishOperation()
        }
    }

    func setTransferSelected(_ id: String, selected: Bool) {
        guard isBusy == false, var review = transferReview else { return }
        guard let index = review.items.firstIndex(where: { $0.id == id }),
              review.items[index].status == .pending || review.items[index].status == .error else { return }
        review.items[index].isSelected = selected
        transferReview = review
    }

    func confirmTransfer() {
        guard isBusy == false, var review = transferReview else { return }
        let pending = review.items.filter { $0.isSelected && ($0.status == .pending || $0.status == .error) }
        guard pending.isEmpty == false else { return }

        isBusy = true
        review.isRunning = true
        transferReview = review
        progress = OperationProgress(
            kind: .copying,
            title: "Copying selected files",
            detail: "Starting…",
            totalItems: pending.count,
            totalBytes: pending.reduce(Int64(0)) { $0 + $1.sourceSize }
        )
        let viewModel = self
        operationTask = Task { @MainActor [viewModel] in
            await viewModel.performConfirmedTransfer()
            viewModel.finishOperation()
        }
    }

    func dismissTransferReview() {
        guard isBusy == false else { return }
        transferReview = nil
        progress = nil
    }

    func startDelete(on side: BrowserSide) {
        guard canDelete(side) else { return }
        isBusy = true
        progress = OperationProgress(
            kind: .deleting,
            title: "Delete selected",
            detail: "Preparing…"
        )
        let viewModel = self
        operationTask = Task { @MainActor [viewModel] in
            await viewModel.performDeleteSelected(on: side)
            viewModel.finishOperation()
        }
    }

    func cancelCurrentOperation() {
        guard isBusy else { return }
        if var progress {
            progress.isCancelling = true
            progress.detail = "Cancelling…"
            self.progress = progress
        }
        statusText = "Cancelling current operation…"
        operationTask?.cancel()
    }

    func root(forDisplay side: BrowserSide) -> URL? {
        side == .left ? leftRoot : rightRoot
    }

    func clearLog() { logLines.removeAll() }

    private func startICloudSyncForClickedItem(_ path: String, on side: BrowserSide) {
        guard isBusy == false else { return }
        guard let node = find(path, in: nodes(for: side)), node.isDirectory == false else { return }
        let url = node.url
        guard needsICloudDownload(url) else { return }

        isBusy = true
        progress = OperationProgress(
            kind: .syncing,
            title: "Syncing \(url.lastPathComponent)",
            detail: "Requesting this file from iCloud…"
        )
        let viewModel = self
        operationTask = Task { @MainActor [viewModel] in
            await viewModel.performSelectionSync(url: url, side: side)
            viewModel.finishOperation()
        }
    }

    private func performSelectionSync(url: URL, side: BrowserSide) async {
        append("iCloud sync on click: \(url.path)")
        do {
            let summary = try await engine.syncICloudFile(
                url: url,
                onProgress: { [viewModel = self] sync in
                    await viewModel.applySyncProgress(sync, title: "Syncing \(url.lastPathComponent)")
                },
                onLog: { [viewModel = self] line in
                    await viewModel.append(line)
                }
            )
            try Task.checkCancellation()
            if summary.downloadsRequested == 0 {
                statusText = "\(url.lastPathComponent) is already local or its iCloud download is already in progress."
            } else {
                statusText = "iCloud download requested: \(url.lastPathComponent)."
            }
            append(statusText)
        } catch is CancellationError {
            markCancelled("iCloud sync cancelled.")
        } catch {
            statusText = "iCloud sync failed: \(error.localizedDescription)"
            append(statusText)
            if var progress {
                progress.detail = statusText
                self.progress = progress
            }
        }
    }

    private func prepareTransferReview(from sourceSide: BrowserSide, selectedSources: [TransferSourceItem]) async {
        guard let sourceRoot = root(for: sourceSide),
              let destinationRoot = root(for: sourceSide.opposite) else { return }
        let options = CopyOptions(overwrite: overwrite, keepBackup: keepBackup)

        do {
            let items = try await engine.transferPlan(
                destinationRoot: destinationRoot,
                selectedSources: selectedSources,
                options: options
            )
            try Task.checkCancellation()
            if items.isEmpty {
                statusText = "No files found in the selected items."
                append(statusText)
                progress = nil
                return
            }

            transferReview = TransferReviewState(
                sourceSide: sourceSide,
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                items: items
            )
            statusText = "Review \(items.count) file(s), choose what to transfer, then confirm."
            append("Prepared transfer list: \(items.count) file(s)")
            progress = nil
        } catch is CancellationError {
            markCancelled("Transfer list cancelled.")
        } catch {
            statusText = "Could not build transfer list: \(error.localizedDescription)"
            append(statusText)
            progress = nil
        }
    }

    private func performConfirmedTransfer() async {
        guard let review = transferReview else { return }
        let sourceSide = review.sourceSide
        let options = CopyOptions(overwrite: overwrite, keepBackup: keepBackup)
        let ids = review.items
            .filter { $0.isSelected && ($0.status == .pending || $0.status == .error) }
            .map(\.id)
        guard ids.isEmpty == false else { return }

        var total = CopySummary()
        var currentID: String?
        append("Confirmed \(ids.count) file(s) for transfer")

        do {
            for id in ids {
                try Task.checkCancellation()
                currentID = id
                guard let transferItem = transferReview?.items.first(where: { $0.id == id }) else { continue }
                setTransferStatus(id, .copying)
                clearTransferError(id)
                if var progress {
                    progress.detail = "Downloading/copying \(id)"
                    self.progress = progress
                }
                let source = transferItem.sourceURL
                let destination = transferItem.destinationURL

                do {
                    let result = try await engine.copy(
                        source: source,
                        destination: destination,
                        options: options,
                        onProgress: { [viewModel = self] event in
                            await viewModel.applyCopyProgress(event)
                        },
                        onLog: { [viewModel = self] line in
                            await viewModel.append(line)
                        }
                    )
                    total.filesCopied += result.filesCopied
                    total.directoriesCreated += result.directoriesCreated
                    total.skipped += result.skipped
                    total.backedUp += result.backedUp
                    total.bytesCopied += result.bytesCopied
                    total.failures.append(contentsOf: result.failures)
                    markTransferDone(id, copied: result.filesCopied > 0)
                } catch is CancellationError {
                    setTransferStatus(id, .pending)
                    throw CancellationError()
                } catch {
                    let reason = detailedErrorMessage(error)
                    setTransferError(id, message: reason)
                    total.failures.append("\(id): \(reason)")
                    append("Error \(id): \(reason)")
                    if var progress {
                        progress.completedItems = min(progress.completedItems + 1, progress.totalItems)
                        progress.detail = "Error: \(id)"
                        self.progress = progress
                    }
                }
            }

            setTransferRunning(false)
            statusText = "Processed \(ids.count) file(s): copied \(total.filesCopied), skipped \(total.skipped), backups \(total.backedUp), failed \(total.failures.count)."
            append(statusText)
            if var progress {
                progress.detail = statusText
                self.progress = progress
            }
            await reloadExpanded(sourceSide.opposite)
        } catch is CancellationError {
            if let currentID { setTransferStatus(currentID, .pending) }
            setTransferRunning(false)
            markCancelled("Copy cancelled.")
            await reloadExpanded(sourceSide.opposite)
        } catch {
            if let currentID { setTransferStatus(currentID, .pending) }
            setTransferRunning(false)
            statusText = "Copy failed: \(error.localizedDescription)"
            append(statusText)
            await reloadExpanded(sourceSide.opposite)
        }
    }

    private func setTransferStatus(_ id: String, _ status: TransferFileStatus) {
        guard var review = transferReview,
              let index = review.items.firstIndex(where: { $0.id == id }) else { return }
        review.items[index].status = status
        transferReview = review
    }

    private func setTransferError(_ id: String, message: String) {
        guard var review = transferReview,
              let index = review.items.firstIndex(where: { $0.id == id }) else { return }
        review.items[index].status = .error
        review.items[index].errorMessage = message
        transferReview = review
    }

    private func clearTransferError(_ id: String) {
        guard var review = transferReview,
              let index = review.items.firstIndex(where: { $0.id == id }) else { return }
        review.items[index].errorMessage = nil
        transferReview = review
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason, reason.isEmpty == false {
            parts.append(reason)
        }
        if let suggestion = nsError.localizedRecoverySuggestion, suggestion.isEmpty == false {
            parts.append(suggestion)
        }
        if nsError.domain.isEmpty == false {
            parts.append("\(nsError.domain) (\(nsError.code))")
        }
        return parts.joined(separator: " · ")
    }

    private func markTransferDone(_ id: String, copied: Bool) {
        guard var review = transferReview,
              let index = review.items.firstIndex(where: { $0.id == id }) else { return }
        review.items[index].status = .done
        review.items[index].errorMessage = nil
        if copied {
            review.items[index].destinationSize = review.items[index].sourceSize
        }
        transferReview = review
    }

    private func setTransferRunning(_ running: Bool) {
        guard var review = transferReview else { return }
        review.isRunning = running
        transferReview = review
    }

    private func performDeleteSelected(on side: BrowserSide) async {
        guard let _ = root(for: side) else { return }
        let selected = jobsCovering(checkedNodes(in: nodes(for: side)))
        guard selected.isEmpty == false else { return }

        progress = OperationProgress(
            kind: .deleting,
            title: "Delete from \(side.title)",
            detail: "Starting…",
            totalItems: selected.count
        )
        append("Delete from \(side.title): \(selected.count) selected item(s)")

        var deleted = 0
        var failures = 0
        do {
            for item in selected {
                try Task.checkCancellation()
                let url = item.url
                if var progress {
                    progress.detail = item.relativePath
                    self.progress = progress
                }
                do {
                    try await engine.delete(
                        url: url,
                        onLog: { [viewModel = self] line in
                            await viewModel.append(line)
                        }
                    )
                    deleted += 1
                    if var progress {
                        progress.completedItems += 1
                        self.progress = progress
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures += 1
                    append("Delete error for \(item.relativePath): \(error.localizedDescription)")
                    if var progress {
                        progress.completedItems += 1
                        self.progress = progress
                    }
                }
            }

            statusText = failures == 0
                ? "Deleted \(deleted) selected item(s) from \(side.title)."
                : "Deleted \(deleted) item(s) from \(side.title); \(failures) failed."
            append(statusText)
            if var progress {
                progress.detail = statusText
                self.progress = progress
            }
            await reloadExpanded(side)
        } catch is CancellationError {
            markCancelled("Delete cancelled.")
            await reloadExpanded(side)
        } catch {
            statusText = "Delete failed: \(error.localizedDescription)"
            append(statusText)
            await reloadExpanded(side)
        }
    }

    private func applyCopyProgress(_ event: CopyProgressEvent) {
        guard var progress, progress.kind == .copying else { return }
        progress.detail = event.path
        progress.completedItems += event.completedItems
        if progress.totalItems > 0 {
            progress.completedItems = min(progress.completedItems, progress.totalItems)
        }
        progress.completedBytes += event.bytesCopied
        progress.filesCopied += event.filesCopied
        progress.directoriesCreated += event.directoriesCreated
        progress.skipped += event.skipped
        progress.backedUp += event.backedUp
        self.progress = progress
    }

    private func applySyncProgress(_ sync: ICloudSyncProgress, title: String) {
        progress = OperationProgress(
            kind: .syncing,
            title: title,
            detail: sync.currentPath,
            completedItems: sync.completedItems,
            totalItems: sync.totalItems,
            completedBytes: sync.completedBytes,
            totalBytes: sync.totalBytes,
            downloadsRequested: sync.downloadsRequested,
            isCancelling: progress?.isCancelling ?? false
        )
    }

    private func finishOperation() {
        isBusy = false
        operationTask = nil
        if var progress {
            progress.isCancelling = false
            self.progress = progress
        }
    }

    private func markCancelled(_ text: String) {
        statusText = text
        append(text)
        if var progress {
            progress.detail = text
            progress.isCancelling = false
            self.progress = progress
        }
    }

    private func needsICloudDownload(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadRequestedKey
        ]),
        values.isDirectory != true,
        values.isUbiquitousItem == true else {
            return false
        }
        let status = values.ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded { return false }
        return values.ubiquitousItemDownloadRequested != true
    }

    private func restoreBookmarkedRoots() {
        var restored: [String] = []
        for side in [BrowserSide.left, .right] {
            do {
                guard let bookmark = try FolderBookmarkStore.restore(for: side) else { continue }
                let scope = SecurityScope(bookmark.url)
                setScope(scope, side: side)
                loadRoot(bookmark.url, side: side)
                restored.append(side.title)

                if bookmark.isStale {
                    do {
                        try FolderBookmarkStore.save(bookmark.url, for: side)
                    } catch {
                        append("Could not refresh \(side.title) bookmark: \(error.localizedDescription)")
                    }
                }
            } catch {
                FolderBookmarkStore.remove(for: side)
                append("Could not restore \(side.title) folder bookmark: \(error.localizedDescription)")
            }
        }

        if restored.isEmpty == false {
            statusText = "Restored \(restored.joined(separator: " and ")) root folder\(restored.count == 1 ? "" : "s")."
        }
    }

    private func loadRoot(_ url: URL, side: BrowserSide) {
        let loaded = (try? TreeLoader.loadChildren(of: url, root: url)) ?? []
        switch side {
        case .left:
            leftRoot = url
            leftNodes = loaded
        case .right:
            rightRoot = url
            rightNodes = loaded
        }
    }

    private func setScope(_ scope: SecurityScope, side: BrowserSide) {
        switch side {
        case .left: leftScope = scope
        case .right: rightScope = scope
        }
    }

    private func canPush(from side: BrowserSide) -> Bool {
        isBusy == false && root(for: side) != nil && root(for: side.opposite) != nil && checkedNodes(in: nodes(for: side)).isEmpty == false
    }

    private func root(for side: BrowserSide) -> URL? {
        side == .left ? leftRoot : rightRoot
    }

    private func nodes(for side: BrowserSide) -> [FileNode] {
        side == .left ? leftNodes : rightNodes
    }

    private func setNodes(_ nodes: [FileNode], side: BrowserSide) {
        if side == .left { leftNodes = nodes } else { rightNodes = nodes }
    }

    private func jobsCovering(_ nodes: [FileNode]) -> [FileNode] {
        nodes.filter { node in
            let parts = node.relativePath.split(separator: "/")
            guard parts.count > 1 else { return true }
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                if nodes.contains(where: { $0.relativePath == prefix && $0.isDirectory && $0.isChecked }) {
                    return false
                }
            }
            return true
        }
    }

    private func checkedNodes(in nodes: [FileNode]) -> [FileNode] {
        var found: [FileNode] = []
        for node in nodes {
            if node.isChecked { found.append(node) }
            if let children = node.children {
                found.append(contentsOf: checkedNodes(in: children))
            }
        }
        return found
    }

    private func reloadExpanded(_ side: BrowserSide) async {
        guard let root = root(for: side) else { return }
        var fresh = (try? TreeLoader.loadChildren(of: root, root: root)) ?? []
        let previous = nodes(for: side)
        restoreExpansion(from: previous, into: &fresh, root: root)
        setNodes(fresh, side: side)
    }

    private func restoreExpansion(from previous: [FileNode], into fresh: inout [FileNode], root: URL) {
        for index in fresh.indices {
            guard let old = previous.first(where: { $0.relativePath == fresh[index].relativePath }) else { continue }
            fresh[index].isChecked = old.isChecked
            fresh[index].isExpanded = old.isExpanded
            if old.isExpanded, fresh[index].isDirectory {
                var children = (try? TreeLoader.loadChildren(of: fresh[index].url, root: root)) ?? []
                restoreExpansion(from: old.children ?? [], into: &children, root: root)
                fresh[index].children = children
            }
        }
    }

    private func find(_ path: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.relativePath == path { return node }
            if let children = node.children, let found = find(path, in: children) { return found }
        }
        return nil
    }

    @discardableResult
    private func update(_ nodes: inout [FileNode], path: String, body: (inout FileNode) -> Void) -> Bool {
        for index in nodes.indices {
            if nodes[index].relativePath == path {
                body(&nodes[index])
                return true
            }
            if var children = nodes[index].children, update(&children, path: path, body: body) {
                nodes[index].children = children
                return true
            }
        }
        return false
    }

    /// Expands every ancestor, and the node itself when it is a directory. Returns the deepest path that exists on this side.
    private func reveal(_ path: String, on side: BrowserSide) -> String {
        guard let root = root(for: side) else { return path }
        var nodes = nodes(for: side)
        let parts = path.split(separator: "/").map(String.init)
        var built = ""
        var deepest = ""
        for (index, part) in parts.enumerated() {
            built = built.isEmpty ? part : built + "/" + part
            guard var node = find(built, in: nodes) else { break }
            deepest = built
            let isLeaf = index == parts.count - 1
            if node.isDirectory, isLeaf || node.isExpanded == false || node.children == nil {
                if node.children == nil {
                    node.children = (try? TreeLoader.loadChildren(of: node.url, root: root)) ?? []
                }
                node.isExpanded = true
                _ = update(&nodes, path: built) { $0 = node }
            }
        }
        setNodes(nodes, side: side)
        return deepest.isEmpty ? path : deepest
    }

    private func markAll(_ nodes: inout [FileNode], checked: Bool) {
        for index in nodes.indices {
            nodes[index].isChecked = checked
            if var children = nodes[index].children {
                markAll(&children, checked: checked)
                nodes[index].children = children
            }
        }
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }
}

private final class SecurityScope: @unchecked Sendable {
    let url: URL
    private let didStart: Bool

    init(_ url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
