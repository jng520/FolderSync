import SwiftUI

struct ContentView: View {
    @State private var model = MirrorViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            options
            HStack(alignment: .top, spacing: 12) {
                pane(.left, root: model.leftRoot, nodes: model.leftNodes)
                pushColumn
                pane(.right, root: model.rightRoot, nodes: model.rightNodes)
            }
            .frame(maxHeight: .infinity)
            log
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FolderSync")
                .font(.title2.weight(.semibold))
            Text("Pick two root folders. Click a row to expand that path on both sides and line the same file or folder up at the same height. Check items, then push either way.")
                .foregroundStyle(.secondary)
            Text(model.statusText)
                .font(.callout)
        }
    }

    private var options: some View {
        HStack(spacing: 16) {
            Toggle("Overwrite existing files", isOn: $model.overwrite)
            Toggle("Keep backup of existing items", isOn: $model.keepBackup)
            Text(policyText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var pushColumn: some View {
        VStack(spacing: 10) {
            Spacer()
            Button {
                Task { await model.push(from: .left) }
            } label: {
                Label("Push", systemImage: "arrow.right")
            }
            .disabled(model.canPushLeftToRight == false)
            Button {
                Task { await model.push(from: .right) }
            } label: {
                Label("Push", systemImage: "arrow.left")
            }
            .disabled(model.canPushRightToLeft == false)
            Spacer()
        }
        .frame(width: 110)
    }

    private var log: some View {
        GroupBox("Log") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.logLines.count) { _, _ in
                    if let last = model.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .frame(height: 140)
        }
    }

    private var policyText: String {
        switch (model.overwrite, model.keepBackup) {
        case (_, true):
            return "Backup renames the existing item to name.bak-yyyyMMdd-HHmmss, then copies."
        case (true, false):
            return "Existing files are replaced."
        case (false, false):
            return "Existing files are skipped."
        }
    }

    private func pane(_ side: BrowserSide, root: URL?, nodes: [FileNode]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(side.title)
                        .font(.headline)
                    Spacer()
                    Button("Select Root") { model.chooseRoot(side) }
                }
                Text(root?.path ?? "No root selected")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Divider()
                TreePane(side: side, nodes: nodes, model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct TreePane: View {
    let side: BrowserSide
    let nodes: [FileNode]
    var model: MirrorViewModel
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 1

    private var spaceName: String { "tree-\(side.rawValue)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if nodes.isEmpty {
                    Text(model.root(forDisplay: side) == nil ? "Choose a folder." : "This folder is empty.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FileTreeView(
                        nodes: nodes,
                        selectedPath: model.selectedPath,
                        coordinateSpace: spaceName,
                        onToggleExpand: { model.toggleExpand(side, path: $0) },
                        onToggleCheck: { model.toggleCheck(side, path: $0) },
                        onFocus: { path in
                            model.focus(path, fraction: alignFraction(for: path))
                        }
                    )
                }
            }
            .coordinateSpace(name: spaceName)
            .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
            .onChange(of: model.alignRequest) { _, request in
                guard let request else { return }
                let target = request.target(for: side)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: request.fraction))
                }
            }
        }
    }

    private func alignFraction(for path: String) -> CGFloat {
        guard viewportHeight > 1, let frame = rowFrames[path] else { return 0 }
        return min(max(frame.minY / viewportHeight, 0), 1)
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
