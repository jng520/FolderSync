import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = MirrorViewModel()
    @State private var rootPickerSide: BrowserSide?
    @State private var isRootPickerPresented = false
    @State private var pendingDeleteSide: BrowserSide?
    @AppStorage("FolderSync.ui.headerExpanded") private var isHeaderExpanded = true
    @AppStorage("FolderSync.ui.leftPaneExpanded") private var isLeftPaneExpanded = true
    @AppStorage("FolderSync.ui.rightPaneExpanded") private var isRightPaneExpanded = true
    @AppStorage("FolderSync.ui.logExpanded") private var isLogExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            browserPanes
                .frame(maxHeight: .infinity)
            log
        }
        .padding(contentPadding)
        #if os(macOS)
        .frame(minWidth: 980, minHeight: 640)
        #endif
        .fileImporter(
            isPresented: $isRootPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let side = rootPickerSide else { return }
            rootPickerSide = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.setRoot(url, side: side) }
            case .failure(let error):
                model.reportPickerError(error)
            }
        }
        .sheet(isPresented: transferReviewBinding) {
            TransferReviewView(model: model)
                .interactiveDismissDisabled(model.isBusy)
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy {
                isHeaderExpanded = true
            }
        }
        .confirmationDialog(
            "Delete selected items?",
            isPresented: deleteDialogBinding
        ) {
            if let side = pendingDeleteSide {
                Button("Delete from \(side.title)", role: .destructive) {
                    pendingDeleteSide = nil
                    model.startDelete(on: side)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSide = nil
            }
        } message: {
            if let side = pendingDeleteSide {
                Text("This permanently deletes the checked files and folders from the \(side.title.lowercased()) root.")
            }
        }
    }

    private var header: some View {
        DisclosureGroup(isExpanded: $isHeaderExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.statusText)
                    .font(.callout)

                options

                progressDetails
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text("FolderSync")
                    .font(.title2.weight(.semibold))
                Spacer()
                if model.isBusy, let progress = model.progress {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress.kind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var options: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                optionControls
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var optionControls: some View {
        Toggle("Overwrite existing files", isOn: $model.overwrite)
        Toggle("Keep backup of existing items", isOn: $model.keepBackup)
        Text(policyText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var progressDetails: some View {
        if let progress = model.progress {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progress.title)
                                .font(.headline)
                            Text(progress.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isBusy {
                            Button("Cancel", role: .cancel) {
                                model.cancelCurrentOperation()
                            }
                            .disabled(progress.isCancelling)
                        }
                    }

                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                    } else if model.isBusy {
                        ProgressView()
                    } else {
                        ProgressView(value: 1)
                    }

                    Text(progress.detail)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 14) {
                        if progress.totalItems > 0 {
                            Text("Items: \(progress.completedItems)/\(progress.totalItems)")
                        }
                        if progress.totalBytes > 0 {
                            Text("Data: \(formatBytes(progress.completedBytes))/\(formatBytes(progress.totalBytes))")
                        }
                        if progress.downloadsRequested > 0 {
                            Text("Downloads: \(progress.downloadsRequested)")
                        }
                        if progress.filesCopied > 0 {
                            Text("Files: \(progress.filesCopied)")
                        }
                        if progress.directoriesCreated > 0 {
                            Text("Folders: \(progress.directoriesCreated)")
                        }
                        if progress.skipped > 0 {
                            Text("Skipped: \(progress.skipped)")
                        }
                        if progress.backedUp > 0 {
                            Text("Backups: \(progress.backedUp)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var browserPanes: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                pane(
                    .left,
                    title: "Left",
                    root: model.leftRoot,
                    nodes: model.leftNodes,
                    isExpanded: $isLeftPaneExpanded
                )
                .frame(minWidth: 280)

                pushColumn

                pane(
                    .right,
                    title: "Right",
                    root: model.rightRoot,
                    nodes: model.rightNodes,
                    isExpanded: $isRightPaneExpanded
                )
                .frame(minWidth: 280)
            }

            VStack(spacing: 10) {
                pane(
                    .left,
                    title: "Up",
                    root: model.leftRoot,
                    nodes: model.leftNodes,
                    isExpanded: $isLeftPaneExpanded
                )
                .frame(minHeight: isLeftPaneExpanded ? 180 : 0)

                pushRow

                pane(
                    .right,
                    title: "Down",
                    root: model.rightRoot,
                    nodes: model.rightNodes,
                    isExpanded: $isRightPaneExpanded
                )
                .frame(minHeight: isRightPaneExpanded ? 180 : 0)
            }
        }
    }

    private var pushColumn: some View {
        VStack(spacing: 10) {
            Spacer()
            Button {
                model.startPush(from: .left)
            } label: {
                Label("Push", systemImage: "arrow.right")
            }
            .disabled(model.canPushLeftToRight == false)

            Button {
                model.startPush(from: .right)
            } label: {
                Label("Push", systemImage: "arrow.left")
            }
            .disabled(model.canPushRightToLeft == false)
            Spacer()
        }
        .frame(width: 110)
    }

    private var pushRow: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                model.startPush(from: .left)
            } label: {
                Label("Up → Down", systemImage: "arrow.down")
            }
            .disabled(model.canPushLeftToRight == false)

            Button {
                model.startPush(from: .right)
            } label: {
                Label("Down → Up", systemImage: "arrow.up")
            }
            .disabled(model.canPushRightToLeft == false)
            Spacer()
        }
    }

    private var log: some View {
        DisclosureGroup("Log", isExpanded: $isLogExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.logLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear
                            .frame(height: 1)
                            .id("log-bottom")
                    }
                    .padding(4)
                }
                .onChange(of: model.logLines.count) { _, _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .frame(height: 120)
            .padding(.top, 4)
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

    private func pane(
        _ side: BrowserSide,
        title: String,
        root: URL?,
        nodes: [FileNode],
        isExpanded: Binding<Bool>
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        isExpanded.wrappedValue.toggle()
                    } label: {
                        Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")

                    Text(title)
                        .font(.headline)
                    Spacer()
                    Button("Delete Selected", role: .destructive) {
                        pendingDeleteSide = side
                    }
                    .disabled(model.canDelete(side) == false)
                    Button("Select Root") {
                        rootPickerSide = side
                        isRootPickerPresented = true
                    }
                    .disabled(model.isBusy)
                }

                if isExpanded.wrappedValue {
                    Text(root?.path ?? "No root selected")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Divider()
                    TreePane(side: side, nodes: nodes, model: model)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: isExpanded.wrappedValue ? .infinity : nil,
                alignment: .topLeading
            )
        }
    }

    private var transferReviewBinding: Binding<Bool> {
        Binding(
            get: { model.transferReview != nil },
            set: { presented in
                if presented == false {
                    model.dismissTransferReview()
                }
            }
        )
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteSide != nil },
            set: { presented in
                if presented == false { pendingDeleteSide = nil }
            }
        )
    }

    private var contentPadding: CGFloat {
        #if os(macOS)
        16
        #else
        12
        #endif
    }
}

private struct TransferReviewView: View {
    private enum SortField: String, CaseIterable, Identifiable {
        case name = "Name"
        case date = "Date"
        var id: Self { self }
    }

    var model: MirrorViewModel
    @State private var sortField: SortField = .name
    @State private var sortAscending = true
    @State private var errorItem: TransferFileItem?

    private let columns: [GridItem] = [
        GridItem(.fixed(64), spacing: 8),
        GridItem(.fixed(90), spacing: 8),
        GridItem(.fixed(360), spacing: 8),
        GridItem(.fixed(110), spacing: 8),
        GridItem(.fixed(110), spacing: 8)
    ]

    var body: some View {
        if let review = model.transferReview {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transfer Review")
                        .font(.title2.weight(.semibold))
                    Text("Choose the files to transfer, then confirm.")
                        .foregroundStyle(.secondary)
                    Text("Source: \(review.sourceRoot.path)")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text("Destination: \(review.destinationRoot.path)")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Picker("Sort", selection: $sortField) {
                        ForEach(SortField.allCases) { field in
                            Text(field.rawValue).tag(field)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Button {
                        sortAscending.toggle()
                    } label: {
                        Label(
                            sortAscending ? "Ascending" : "Descending",
                            systemImage: sortAscending ? "arrow.up" : "arrow.down"
                        )
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }

                Divider()

                ScrollView([.horizontal, .vertical]) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                        transferHeader("Select")
                        transferHeader("Status")
                        transferHeader("Relative file name")
                        transferHeader("Source size", alignment: .trailing)
                        transferHeader("Dest size", alignment: .trailing)

                        ForEach(sortedItems(review.items)) { item in
                            transferCheck(item)
                            transferStatus(item)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.relativePath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if let modifiedDate = item.modifiedDate {
                                    Text(modifiedDate, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)

                            Text(formatBytes(item.sourceSize))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.vertical, 7)

                            Text(item.destinationSize.map(formatBytes) ?? "—")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(item.destinationSize == nil ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.vertical, 7)
                        }
                    }
                    .frame(minWidth: 766)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }

                if model.isBusy, let progress = model.progress, progress.kind == .copying {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: progress.fractionCompleted ?? 0)
                        Text(progress.detail)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        HStack {
                            Text("\(progress.completedItems)/\(progress.totalItems) files")
                            if progress.totalBytes > 0 {
                                Text("\(formatBytes(progress.completedBytes))/\(formatBytes(progress.totalBytes))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Text("\(review.selectedPendingCount) selected · \(review.pendingCount) pending · \(review.errorCount) error · \(review.items.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()

                    if model.isBusy {
                        Button("Cancel", role: .cancel) {
                            model.cancelCurrentOperation()
                        }
                    } else {
                        Button("Close") {
                            model.dismissTransferReview()
                        }
                        Button("Confirm") {
                            model.confirmTransfer()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(review.selectedPendingCount == 0)
                    }
                }
            }
            .padding(16)
            #if os(macOS)
            .frame(minWidth: 860, minHeight: 560)
            #else
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            .alert(
                "Transfer Error",
                isPresented: Binding(
                    get: { errorItem != nil },
                    set: { if $0 == false { errorItem = nil } }
                ),
                presenting: errorItem
            ) { _ in
                Button("OK", role: .cancel) { errorItem = nil }
            } message: { item in
                Text(item.errorMessage ?? "Unknown transfer error.")
            }
        } else {
            EmptyView()
        }
    }

    private func transferHeader(_ text: String, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.vertical, 7)
    }

    private func sortedItems(_ items: [TransferFileItem]) -> [TransferFileItem] {
        items.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField {
            case .name:
                comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
            case .date:
                switch (lhs.modifiedDate, rhs.modifiedDate) {
                case let (left?, right?):
                    if left == right {
                        comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        comparison = left < right ? .orderedAscending : .orderedDescending
                    }
                case (.none, .some):
                    comparison = .orderedAscending
                case (.some, .none):
                    comparison = .orderedDescending
                case (.none, .none):
                    comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                }
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    @ViewBuilder
    private func transferStatus(_ item: TransferFileItem) -> some View {
        if item.status == .error {
            Button {
                errorItem = item
            } label: {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .accessibilityHint("Shows the transfer error reason")
        } else {
            Text(item.status.rawValue)
                .font(.caption)
                .foregroundStyle(item.status == .done ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
        }
    }

    private func transferCheck(_ item: TransferFileItem) -> some View {
        Button {
            model.setTransferSelected(item.id, selected: item.isSelected == false)
        } label: {
            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || (item.status != .pending && item.status != .error))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 3)
        .accessibilityLabel(item.isSelected ? "Unselect \(item.relativePath)" : "Select \(item.relativePath)")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                            model.focus(path, on: side, fraction: alignFraction(for: path))
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
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
