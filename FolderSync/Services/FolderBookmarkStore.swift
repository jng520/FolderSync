import Foundation

struct RestoredFolderBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

enum FolderBookmarkStore {
    static func save(_ url: URL, for side: BrowserSide) throws {
        let data: Data
        #if os(macOS)
        data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        // iOS does not expose `.withSecurityScope`. A bookmark created from the
        // security-scoped URL returned by the folder picker preserves that access.
        data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        UserDefaults.standard.set(data, forKey: key(for: side))
    }

    static func restore(for side: BrowserSide) throws -> RestoredFolderBookmark? {
        guard let data = UserDefaults.standard.data(forKey: key(for: side)) else { return nil }

        var stale = false
        let url: URL
        #if os(macOS)
        url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #else
        url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #endif
        return RestoredFolderBookmark(url: url, isStale: stale)
    }

    static func remove(for side: BrowserSide) {
        UserDefaults.standard.removeObject(forKey: key(for: side))
    }

    private static func key(for side: BrowserSide) -> String {
        "FolderSync.rootBookmark.\(side.rawValue)"
    }
}
