import SwiftUI

struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct FileTreeView: View {
    let nodes: [FileNode]
    var depth: Int = 0
    var selectedPath: String?
    var coordinateSpace: String
    let onToggleExpand: (String) -> Void
    let onToggleCheck: (String) -> Void
    let onFocus: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                row(node)
                if node.isDirectory, node.isExpanded, let children = node.children {
                    FileTreeView(
                        nodes: children,
                        depth: depth + 1,
                        selectedPath: selectedPath,
                        coordinateSpace: coordinateSpace,
                        onToggleExpand: onToggleExpand,
                        onToggleCheck: onToggleCheck,
                        onFocus: onFocus
                    )
                }
            }
        }
    }

    private func row(_ node: FileNode) -> some View {
        HStack(spacing: 6) {
            Button {
                onToggleCheck(node.relativePath)
            } label: {
                Image(systemName: node.isChecked ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.isChecked ? "Unselect \(node.name)" : "Select \(node.name)")

            if node.isDirectory {
                Button {
                    onToggleExpand(node.relativePath)
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(node.isDirectory ? .secondary : .tertiary)
            Text(node.name)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(node.relativePath == selectedPath ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .id(node.relativePath)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramesKey.self,
                    value: [node.relativePath: geo.frame(in: .named(coordinateSpace))]
                )
            }
        )
        .onTapGesture {
            onFocus(node.relativePath)
        }
    }
}
