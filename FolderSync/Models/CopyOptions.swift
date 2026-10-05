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

    /// Seconds to wait for a single ubiquitous item to finish downloading.
    var downloadTimeout: TimeInterval = 120
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
