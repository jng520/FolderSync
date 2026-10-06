import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    var id: String { relativePath.isEmpty ? "/" : relativePath }
    var name: String
    /// Exact URL returned by Foundation/File Provider. Keep this instead of rebuilding
    /// the URL later from path strings.
    var url: URL
    /// Path under the side's root, `/`-separated. Empty string is the root itself and is not shown as a row.
    var relativePath: String
    var isDirectory: Bool
    var children: [FileNode]?
    var isExpanded: Bool = false
    var isChecked: Bool = false

    var isLoaded: Bool { children != nil }
}

enum BrowserSide: String, Hashable, Sendable {
    case left
    case right

    var opposite: BrowserSide { self == .left ? .right : .left }
    var title: String { self == .left ? "Left" : "Right" }
}

struct AlignRequest: Equatable, Sendable {
    var token: Int
    var path: String
    var leftTarget: String
    var rightTarget: String
    var fraction: CGFloat

    func target(for side: BrowserSide) -> String {
        side == .left ? leftTarget : rightTarget
    }
}
