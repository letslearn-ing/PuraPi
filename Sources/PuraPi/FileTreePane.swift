import PiDomain
import SwiftUI

/// Finder/Xcode 风格的项目 Sidebar（侧边栏）。
///
/// 项目根目录本身是滚动树的第一行；它不再是独立的固定标题栏。这样根目录、
/// 子目录和文件始终属于同一个真实 ScrollView，向上滚动时不会发生标题遮挡。
struct FileTreePane: View {
    @Environment(\.puraPiSidebarTint) private var sidebarTint
    let root: FileNode?
    let selectedURL: URL?
    let onSelect: (URL) -> Void
    let onToggleDirectory: (URL, Bool) -> Void
    let onClearSelection: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void
    /// macOS 26 的真实 ScrollView 是否启用系统 soft scroll-edge effect；全高 Sidebar
    /// 的外层几何由 Split item 管理，材质和滚动树内容由本视图负责。
    /// 新建文件/文件夹。anchor 为 nil 表示在空白处创建（落在项目根下）。
    let onCreateFile: (FileNode?) -> Void
    let onCreateDirectory: (FileNode?) -> Void
    /// 新建后需要展开的目录；由 pane 消费一次后清空。
    let directoryToReveal: URL?
    let usesNativeSidebarChrome: Bool
    /// 是否自行保留交通灯安全区。
    ///
    /// 放进 `PuraPiSidebarPane` 后安全区由容器统一保留；子视图再加一次会把
    /// 模式切换标签推出可视区。
    let reservesTopSafeArea: Bool
    /// 是否自行绘制 Sidebar 紫色表面。放进统一容器时交由容器绘制。
    let providesOwnSurface: Bool

    init(
        root: FileNode?,
        selectedURL: URL?,
        onSelect: @escaping (URL) -> Void,
        onToggleDirectory: @escaping (URL, Bool) -> Void,
        onClearSelection: @escaping () -> Void,
        onReveal: @escaping (URL) -> Void,
        onOpen: @escaping (URL) -> Void,
        onCopyPath: @escaping (URL) -> Void,
        onCopyRelativePath: @escaping (URL) -> Void,
        onCreateFile: @escaping (FileNode?) -> Void = { _ in },
        onCreateDirectory: @escaping (FileNode?) -> Void = { _ in },
        directoryToReveal: URL? = nil,
        usesNativeSidebarChrome: Bool = false,
        reservesTopSafeArea: Bool = true,
        providesOwnSurface: Bool = true
    ) {
        self.root = root
        self.selectedURL = selectedURL
        self.onSelect = onSelect
        self.onToggleDirectory = onToggleDirectory
        self.onClearSelection = onClearSelection
        self.onReveal = onReveal
        self.onOpen = onOpen
        self.onCopyPath = onCopyPath
        self.onCopyRelativePath = onCopyRelativePath
        self.onCreateFile = onCreateFile
        self.onCreateDirectory = onCreateDirectory
        self.directoryToReveal = directoryToReveal
        self.usesNativeSidebarChrome = usesNativeSidebarChrome
        self.reservesTopSafeArea = reservesTopSafeArea
        self.providesOwnSurface = providesOwnSurface
        _expandedURLs = State(initialValue: root.map { [$0.url] } ?? [])
    }

    @State private var expandedURLs: Set<URL>

    var body: some View {
        contentBody
            // 放进 `PuraPiSidebarPane` 时表面由容器统一提供，覆盖交通灯安全区并与
            // 会话树保持一致；这里再画一层会让顶部安全区露出不同底色。
            .puraPiSidebarSurface(enabled: providesOwnSurface, tint: sidebarTint)
            .onChange(of: directoryToReveal) { _, url in
                // 新建项所在目录必须展开，否则用户看不到刚创建的东西。
                guard let url else { return }
                expandedURLs.insert(url.standardizedFileURL)
            }
            .onChange(of: root?.url) { oldRootURL, newRootURL in
                guard oldRootURL != newRootURL else { return }
                expandedURLs = newRootURL.map { [$0] } ?? []
            }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let root {
            VStack(spacing: 0) {
                // Split item 提供全高外层表面；本视图提供与内容边界对齐的局部紫色表面，
                // 只在树内容顶部保留交通灯安全区。根目录行位于同一个 ScrollView 中，
                // 会和所有子项一起滚动。
                if reservesTopSafeArea {
                    Color.clear
                        .frame(height: PuraPiLayoutState.sidebarContentTopInset)
                }

                sidebarScroll(root)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sidebarScroll(_ root: FileNode) -> some View {
        ScrollView {
            PuraPiScrollViewConfiguration(
                managesTitlebarContentInsets: false,
                edgeToEdgeContent: usesNativeSidebarChrome
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            PuraPiLegacyScrollEdgeEffectMarker()

            LazyVStack(alignment: .leading, spacing: 1) {
                if visibleRows.isEmpty {
                    Text("文件夹为空")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                } else {
                    ForEach(visibleRows) { row in
                        FileTreeRowView(
                            row: row,
                            selectedURL: selectedURL,
                            isExpanded: expandedURLs.contains(row.node.url),
                            onToggleExpansion: { toggleExpansion(for: row.node) },
                            onSelect: onSelect,
                            onClearSelection: onClearSelection,
                            onReveal: onReveal,
                            onOpen: onOpen,
                            onCreateFile: onCreateFile,
                            onCreateDirectory: onCreateDirectory,
                            onCopyPath: onCopyPath,
                            onCopyRelativePath: onCopyRelativePath
                        )
                    }
                }
            }
            .padding(.horizontal, 7)
            // 原生 Sidebar 的标题栏安全区已经由外层统一处理；这里只保留
            // 交通灯下方的最小间距。legacy 保持原有 9pt。
            .padding(.top, usesNativeSidebarChrome ? 0 : 9)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.automatic)
        .scrollClipDisabled(false)
        .puraPiSidebarScrollEdgeEffect(enabled: usesNativeSidebarChrome)
        // 空白处右键：anchor 传 nil，新建项落在项目根目录下。
        .contextMenu {
            Button("在项目根目录新建文件") { onCreateFile(nil) }
            Button("在项目根目录新建文件夹") { onCreateDirectory(nil) }
        }
    }

    private var visibleRows: [VisibleFileTreeRow] {
        guard let root else { return [] }
        var result: [VisibleFileTreeRow] = []
        result.reserveCapacity(min((root.children?.count ?? 0) + 1, 257))

        func append(_ node: FileNode, depth: Int) {
            result.append(VisibleFileTreeRow(node: node, depth: depth))
            guard node.isDirectory,
                  expandedURLs.contains(node.url),
                  let children = node.children
            else { return }
            for child in children {
                append(child, depth: depth + 1)
            }
        }

        append(root, depth: 0)
        return result
    }

    private func toggleExpansion(for node: FileNode) {
        guard node.isExpandable else { return }
        if expandedURLs.contains(node.url) {
            expandedURLs.remove(node.url)
            onToggleDirectory(node.url, false)
        } else {
            expandedURLs.insert(node.url)
            onToggleDirectory(node.url, true)
        }
    }
}

private struct VisibleFileTreeRow: Identifiable {
    let node: FileNode
    let depth: Int

    var id: URL { node.url }
}

private struct FileTreeRowView: View {
    @Environment(\.puraPiTheme) private var theme

    let row: VisibleFileTreeRow
    let selectedURL: URL?
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onSelect: (URL) -> Void
    let onClearSelection: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCreateFile: (FileNode?) -> Void
    let onCreateDirectory: (FileNode?) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void

    private var node: FileNode { row.node }
    private var isSelected: Bool {
        selectedURL?.standardizedFileURL == node.url.standardizedFileURL
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            if node.isExpandable {
                Button(action: onToggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .frame(width: 15, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "收起 \(node.name)" : "展开 \(node.name)")
            } else {
                Color.clear
                    .frame(width: 15, height: 22)
            }

            Image(systemName: iconName)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 17)

            Text(node.name)
                .font(.system(size: row.depth == 0 ? 13 : 12.5, weight: row.depth == 0 ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 15 + 5)
        .padding(.trailing, 5)
        .frame(height: 23)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.accent.opacity(0.23))
            } else if isHovering {
                // 悬停反馈告知用户“现在点击会选中哪一行”。
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.accent.opacity(0.10))
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture {
            activateRow()
        }
        // `.onTapGesture` 本身不会给 VoiceOver 暴露选择动作；为整行补一个
        // primary accessibility action，同时保留独立的展开按钮。
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(node.name)
        .accessibilityValue(isSelected ? "已选中" : "")
        .accessibilityAction {
            activateRow()
        }
        .contextMenu {
            // 在文件夹上新建 → 落在文件夹内；在文件上新建 → 落在同级。
            Button(node.isDirectory ? "在此文件夹中新建文件" : "新建文件") {
                onCreateFile(node)
            }
            Button(node.isDirectory ? "在此文件夹中新建文件夹" : "新建文件夹") {
                onCreateDirectory(node)
            }
            Divider()
            Button("复制绝对路径") { onCopyPath(node.url) }
            Button("复制相对路径") { onCopyRelativePath(node.url) }
            Divider()
            Button("在 Finder 中显示") { onReveal(node.url) }
            if !node.isDirectory {
                Button("用默认应用打开") { onOpen(node.url) }
            }
        }
    }

    private func activateRow() {
        if node.isDirectory {
            onClearSelection()
            onToggleExpansion()
        } else {
            onSelect(node.url)
        }
    }

    private var iconName: String {
        if node.isDirectory { return isExpanded ? "folder.fill" : "folder" }
        if node.kind == .symbolicLink { return "arrow.turn.up.right" }
        switch node.url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": return "doc.richtext"
        case "swift": return "swift"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        case "html", "css", "js", "ts": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if node.isDirectory { return theme.accent }
        switch node.url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": return theme.warning
        case "swift": return theme.error
        case "png", "jpg", "jpeg", "gif", "webp": return theme.info
        default: return .secondary
        }
    }
}
