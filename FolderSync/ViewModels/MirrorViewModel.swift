import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MirrorViewModel {
    var leftRoot: URL?
    var rightRoot: URL?
    var leftNodes: [FileNode] = []
    var rightNodes: [FileNode] = []
    var overwrite = false
    var keepBackup = true
    var isBusy = false
    var statusText = "Select a root folder on each side."
    var logLines: [String] = []
    var selectedPath: String?
    var alignRequest: AlignRequest?

    private let engine = RecursiveCopyEngine()
    private var scopes: [SecurityScope] = []
    private var alignToken = 0

    var canPushLeftToRight: Bool { canPush(from: .left) }
    var canPushRightToLeft: Bool { canPush(from: .right) }

    func chooseRoot(_ side: BrowserSide) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as \(side.title) Root"
        panel.message = "Choose the \(side.title.lowercased()) root. Checked items keep this relative path on the other side."
        if side == .left, let cloud = ICloudPathMapper.iCloudDriveRoot() {
            panel.directoryURL = cloud
        } else if side == .right {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setRoot(url, side: side) }
    }

    func setRoot(_ url: URL, side: BrowserSide) async {
        scopes.removeAll { $0.url == url }
        scopes.append(SecurityScope(url))
        switch side {
        case .left:
            leftRoot = url
            leftNodes = (try? TreeLoader.loadChildren(of: url, root: url)) ?? []
        case .right:
            rightRoot = url
            rightNodes = (try? TreeLoader.loadChildren(of: url, root: url)) ?? []
        }
        statusText = "\(side.title) root: \(url.path)"
        append("\(side.title) root \(url.path)")
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
            let url = root.appending(path: path)
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

    /// Expand this path on both sides, then ask both scroll views to place the row at `fraction` of the viewport height.
    func focus(_ path: String, fraction: CGFloat) {
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
    }

    func toggleCheck(_ side: BrowserSide, path: String) {
        var nodes = nodes(for: side)
        _ = update(&nodes, path: path) { node in
            node.isChecked.toggle()
            if var children = node.children {
                markAll(&children, checked: node.isChecked)
                node.children = children
            }
        }
        setNodes(nodes, side: side)
    }

    func push(from sourceSide: BrowserSide) async {
        guard let sourceRoot = root(for: sourceSide), let destRoot = root(for: sourceSide.opposite) else { return }
        let selected = checkedNodes(in: nodes(for: sourceSide))
        let jobs = jobsCovering(selected)
        guard jobs.isEmpty == false else { return }

        isBusy = true
        defer { isBusy = false }
        let options = CopyOptions(overwrite: overwrite, keepBackup: keepBackup)
        append("Push \(sourceSide.title) → \(sourceSide.opposite.title): \(jobs.count) item(s)")

        var total = CopySummary()
        for job in jobs {
            let source = sourceRoot.appending(path: job.relativePath)
            let destination = destRoot.appending(path: job.relativePath)
            do {
                let result = try await engine.copy(source: source, destination: destination, options: options) { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                }
                total.filesCopied += result.filesCopied
                total.directoriesCreated += result.directoriesCreated
                total.skipped += result.skipped
                total.backedUp += result.backedUp
                total.bytesCopied += result.bytesCopied
                total.failures.append(contentsOf: result.failures)
            } catch {
                total.failures.append(error.localizedDescription)
                append("Error: \(error.localizedDescription)")
            }
        }
        statusText = "Pushed \(total.filesCopied) file(s), folders created \(total.directoriesCreated), skipped \(total.skipped), backups \(total.backedUp)."
        append(statusText)
        await reloadExpanded(sourceSide.opposite)
    }

    func root(forDisplay side: BrowserSide) -> URL? {
        side == .left ? leftRoot : rightRoot
    }

    func clearLog() { logLines.removeAll() }

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
        let checked = checkedNodes(in: nodes)
        return checked.filter { node in
            let parts = node.relativePath.split(separator: "/")
            guard parts.count > 1 else { return true }
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                if checked.contains(where: { $0.relativePath == prefix && $0.isDirectory && $0.isChecked }) {
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
                var children = (try? TreeLoader.loadChildren(of: root.appending(path: fresh[index].relativePath), root: root)) ?? []
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
                    node.children = (try? TreeLoader.loadChildren(of: root.appending(path: built), root: root)) ?? []
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
    init(_ url: URL) {
        self.url = url
        _ = url.startAccessingSecurityScopedResource()
    }
    deinit { url.stopAccessingSecurityScopedResource() }
}
