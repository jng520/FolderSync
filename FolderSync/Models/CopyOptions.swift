import Foundation

/// How an existing destination item is treated.
struct CopyOptions: Sendable, Equatable {
    /// Replace an existing file. Ignored for the backup path when `keepBackup` is true:
    /// the existing item is moved aside first, then the source is copied.
    var overwrite: Bool = false

    /// Rename an existing destination to `name.bak-yyyyMMdd-HHmmss` before copying.
    var keepBackup: Bool = true

    /// Do not copy Finder metadata files.
    var skipDSStore: Bool = true

    /// Wait for iCloud to download evicted items before copying them.
    var downloadFromICloud: Bool = true
}

struct CopySummary: Sendable, Equatable {
    var filesCopied: Int = 0
    var directoriesCreated: Int = 0
    var skipped: Int = 0
    var backedUp: Int = 0
    var bytesCopied: Int64 = 0
    var failures: [String] = []

    var succeeded: Bool { failures.isEmpty }
}

struct CopyWorkload: Sendable, Equatable {
    var itemCount: Int = 0
    var byteCount: Int64 = 0

    static func + (lhs: CopyWorkload, rhs: CopyWorkload) -> CopyWorkload {
        CopyWorkload(
            itemCount: lhs.itemCount + rhs.itemCount,
            byteCount: lhs.byteCount + rhs.byteCount
        )
    }
}

struct CopyProgressEvent: Sendable, Equatable {
    var path: String
    var completedItems: Int = 1
    var bytesCopied: Int64 = 0
    var filesCopied: Int = 0
    var directoriesCreated: Int = 0
    var skipped: Int = 0
    var backedUp: Int = 0
}

struct ICloudSyncProgress: Sendable, Equatable {
    var currentPath: String
    var completedItems: Int
    var totalItems: Int
    var completedBytes: Int64
    var totalBytes: Int64
    var downloadsRequested: Int
}

struct ICloudSyncSummary: Sendable, Equatable {
    var totalItems: Int = 0
    var downloadsRequested: Int = 0
    var bytesPrepared: Int64 = 0
}

struct OperationProgress: Sendable, Equatable {
    enum Kind: String, Sendable {
        case syncing = "iCloud Sync"
        case copying = "Copy"
        case deleting = "Delete"
    }

    var kind: Kind
    var title: String
    var detail: String
    var completedItems: Int = 0
    var totalItems: Int = 0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var filesCopied: Int = 0
    var directoriesCreated: Int = 0
    var skipped: Int = 0
    var backedUp: Int = 0
    var downloadsRequested: Int = 0
    var isCancelling: Bool = false

    var fractionCompleted: Double? {
        guard totalItems > 0 else { return nil }
        return min(max(Double(completedItems) / Double(totalItems), 0), 1)
    }
}

struct TransferSourceItem: Sendable, Equatable {
    var relativePath: String
    var sourceURL: URL
    var isDirectory: Bool
}

enum TransferFileStatus: String, Sendable, Equatable {
    case pending = "Pending"
    case copying = "Copying"
    case done = "Done"
    case error = "Error"
}

struct TransferFileItem: Identifiable, Sendable, Equatable {
    var id: String { relativePath }
    var relativePath: String
    /// Preserve the exact URL returned by enumeration/File Provider. Rebuilding a URL
    /// from root + relative path can lose provider-specific coordination information.
    var sourceURL: URL
    var destinationURL: URL
    var sourceSize: Int64
    var destinationSize: Int64?
    var modifiedDate: Date?
    var isSelected: Bool = true
    var status: TransferFileStatus = .pending
    var errorMessage: String?
}

struct TransferReviewState: Identifiable, Sendable, Equatable {
    var id = UUID()
    var sourceSide: BrowserSide
    var sourceRoot: URL
    var destinationRoot: URL
    var items: [TransferFileItem]
    var isRunning: Bool = false

    var selectedPendingCount: Int {
        items.filter { $0.isSelected && ($0.status == .pending || $0.status == .error) }.count
    }

    var pendingCount: Int {
        items.filter { $0.status == .pending }.count
    }

    var errorCount: Int {
        items.filter { $0.status == .error }.count
    }
}

struct MappedPath: Sendable, Equatable {
    /// iCloud Drive root used as the path anchor, when the selection lives under it.
    var iCloudRoot: URL?
    /// Path relative to the anchor, using `/` separators, no leading slash.
    var relativePath: String
    /// Absolute destination under the user's home directory.
    var destination: URL
    /// Why this mapping was chosen. Shown in the UI.
    var explanation: String
}
