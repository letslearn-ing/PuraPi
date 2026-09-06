import AppKit
import PiDomain
import SwiftUI

struct FileInspectorPane: View {
    @Environment(\.workPiInspectorTint) private var inspectorTint
    @Environment(\.workPiTheme) private var theme
    let preview: FilePreview?
    /// 只读图片预览的工作区根目录；用于安全的逐级路径和数据读取。
    var workspaceRoot: URL? = nil
    /// Markdown 文件由编辑器接管；为 nil 时走只读预览。
    @ObservedObject var editorState: WorkPiMarkdownEditorState
    @ObservedObject var layoutState: WorkPiLayoutState
    let language: WorkPiInterfaceLanguage
    let error: String?
    let onRetry: () -> Void
    let onClose: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void
    /// 是否由自己绘制悬浮圆角表面。
    ///
    /// 原生 macOS 26 与 legacy macOS 14–25 路径都默认自行绘制；只有嵌入到
    /// 已提供外壳的特殊父容器时才传入 false。
    var providesOwnSurface: Bool = true
    /// 当前是否位于独立 Inspector 窗口；菜单文案据此显示“挂回主栏”。
    var isDetached: Bool = false
    /// 只改变展示位置，不关闭当前文件。
    var onToggleDetached: () -> Void = {}
    /// 分离前的短暂边缘提示，不参与命中测试或布局。
    var isLiftHintActive: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 自绘表面时不再铺内容底色，否则会盖住玻璃材质。
            if !providesOwnSurface {
                WorkPiAdaptiveContentBackground(legacyColor: theme.contentBackground)
            }

            if editorState.isEditing {
                // 编辑器即使暂时没有只读 preview（例如文件刚被删除或仍在读取），
                // 也必须继续显示，才能让冲突条提供“放弃/恢复”选择。
                WorkPiMarkdownEditorView(
                    state: editorState,
                    language: language,
                    inspectorTopInset: inspectorTopInset
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    // 加载错误仍属于正文，不能把它放到固定标题上方。
                    if let loadError = editorState.loadError {
                        Text(loadError)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.warning)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }
                    FilePreviewContent(
                        preview: preview,
                        workspaceRoot: workspaceRoot ?? editorState.workspaceRootURL,
                        inspectorTopInset: inspectorTopInset
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let error {
                FileInspectorErrorView(error: error, onRetry: onRetry)
                    .overlay(alignment: .topTrailing) {
                        InspectorCloseButton(action: onClose)
                            .padding(10)
                    }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取预览…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    InspectorCloseButton(action: onClose)
                        .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workPiInspectorSurface(enabled: providesOwnSurface, tint: inspectorTint)
        // 仅在父容器已经提供圆角外壳的嵌入场景补主题色薄膜；原生 Inspector
        // 自己拥有完整表面，不重复叠加材质。
        .workPiInspectorAccentWash(enabled: !providesOwnSurface, tint: inspectorTint)
        .overlay {
            if isLiftHintActive {
                InspectorLiftEffect()
                    .allowsHitTesting(false)
            }
        }
    }

    /// Apple 的 scroll-edge effect 需要一个明确的固定顶部区域作为安全区内嵌，
    /// 而不是在滚动区上方另放一个会遮挡正文的矩形。
    private var inspectorTopInset: AnyView {
        guard let headerPreview else { return AnyView(EmptyView()) }
        return AnyView(
            WorkPiInspectorTopInsetView(
                preview: headerPreview,
                editorState: editorState,
                theme: theme,
                tint: inspectorTint,
                isMaximized: layoutState.inspectorMaximized,
                isDetached: isDetached,
                onToggleMaximize: {
                    layoutState.inspectorMaximized.toggle()
                },
                onToggleDetached: onToggleDetached,
                language: language,
                onClose: onClose,
                onReveal: onReveal,
                onOpen: onOpen,
                onCopyPath: onCopyPath,
                onCopyRelativePath: onCopyRelativePath
            )
        )
    }

    /// 编辑器保留本地文档时，即使磁盘 preview 暂时不可用也要保留标题和操作入口。
    private var headerPreview: FilePreview? {
        if let preview { return preview }
        guard let document = editorState.document else { return nil }
        return FilePreview(
            url: document.url,
            relativePath: document.url.lastPathComponent,
            kind: .markdown,
            text: nil,
            byteCount: 0,
            modificationDate: nil
        )
    }
}

private struct InspectorLiftEffect: View {
    @Environment(\.workPiInspectorTint) private var inspectorTint
    @Environment(\.workPiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isElevated = false

    var body: some View {
        let color = inspectorTint.resolvedColor(using: theme) ?? theme.accent
        RoundedRectangle(
            cornerRadius: WorkPiLayoutState.chromeCornerRadius,
            style: .continuous
        )
        .stroke(
            color.opacity(isElevated ? 0.92 : 0.48),
            lineWidth: isElevated ? 2.0 : 1.0
        )
        .shadow(
            color: color.opacity(isElevated ? 0.42 : 0.12),
            radius: isElevated ? 13 : 4
        )
        .scaleEffect(isElevated ? 1.008 : 1)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 0.18).repeatForever(autoreverses: true),
            value: isElevated
        )
        .onAppear {
            isElevated = true
        }
    }
}

private struct FileInspectorErrorView: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text("无法读取文件预览")
                .font(.system(size: 13, weight: .medium))
            Text(error)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 360)
            Button("重新读取", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileInspectorHeader: View {
    let preview: FilePreview
    /// 编辑器的保存状态；只读预览时为 nil。
    let saveState: WorkPiMarkdownEditorState.SaveState?
    let isMaximized: Bool
    let isDetached: Bool
    let onToggleMaximize: () -> Void
    let onToggleDetached: () -> Void
    let language: WorkPiInterfaceLanguage
    let onClose: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(preview.url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let saveState {
                WorkPiSaveStateBadge(state: saveState, language: language)
            }
            InspectorDetachButton(
                isDetached: isDetached,
                language: language,
                action: onToggleDetached
            )
            if !isDetached {
                Button(action: onToggleMaximize) {
                    Image(
                        systemName: isMaximized
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(
                    isMaximized
                        ? (language == .english ? "Restore width" : "恢复宽度")
                        : (language == .english ? "Maximize editor" : "最大化编辑区")
                )
            }
            Menu {
                Button("复制绝对路径") { onCopyPath(preview.url) }
                Button("复制相对路径") { onCopyRelativePath(preview.url) }
                Divider()
                Button("在 Finder 中显示") { onReveal(preview.url) }
                Button("用默认应用打开") { onOpen(preview.url) }
                Divider()
                Button(
                    isDetached
                        ? (language == .english ? "Reattach to Main Window" : "挂回主窗口")
                        : (language == .english ? "Open in Separate Window" : "在独立窗口中打开")
                ) {
                    onToggleDetached()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .help(isDetached ? "挂回主窗口" : "更多操作（含独立窗口）")

            InspectorCloseButton(action: onClose)
        }
        .padding(.horizontal, WorkPiInspectorHeaderMetrics.horizontalPadding)
        // 标题栏内容需要与中间项目标签的文字基线对齐；上下采用对称的 6pt
        // 间距，让标题到圆角表面上边缘和到下方分隔线的距离保持一致。
        .padding(.top, WorkPiInspectorHeaderMetrics.verticalPadding)
        .padding(.bottom, WorkPiInspectorHeaderMetrics.verticalPadding)
        .contextMenu {
            Button("复制绝对路径") { onCopyPath(preview.url) }
            Button("复制相对路径") { onCopyRelativePath(preview.url) }
            Divider()
            Button("在 Finder 中显示") { onReveal(preview.url) }
            Button("用默认应用打开") { onOpen(preview.url) }
            Divider()
            Button(
                isDetached
                    ? (language == .english ? "Reattach to Main Window" : "挂回主窗口")
                    : (language == .english ? "Open in Separate Window" : "在独立窗口中打开")
            ) {
                onToggleDetached()
            }
        }
    }

    private var iconName: String {
        switch preview.kind {
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        default: return "doc.text"
        }
    }
}

private struct InspectorDetachButton: View {
    let isDetached: Bool
    let language: WorkPiInterfaceLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDetached ? "arrow.uturn.backward" : "rectangle.on.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isDetached
                ? (language == .english ? "Reattach to main window" : "挂回主窗口")
                : (language == .english ? "Open in separate window" : "在独立窗口中打开")
        )
        .accessibilityLabel(
            isDetached
                ? (language == .english ? "Reattach to main window" : "挂回主窗口")
                : (language == .english ? "Open in separate window" : "在独立窗口中打开")
        )
    }
}

private struct InspectorCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("关闭文件检查器")
        .accessibilityLabel("关闭文件检查器")
    }
}

private struct FilePreviewContent: View {
    let preview: FilePreview
    let workspaceRoot: URL?
    let inspectorTopInset: AnyView?

    init(
        preview: FilePreview,
        workspaceRoot: URL? = nil,
        inspectorTopInset: AnyView? = nil
    ) {
        self.preview = preview
        self.workspaceRoot = workspaceRoot
        self.inspectorTopInset = inspectorTopInset
    }

    var body: some View {
        // Markdown/图片预览是阅读流，采用单一纵向滚动轴；双轴 ScrollView 会给
        // Markdown 内容一个无限宽度提案，macOS 26 随之把 edge pocket 错算成巨型区域。
        ScrollView(.vertical) {
            WorkPiScrollViewConfiguration(
                managesTitlebarContentInsets: false,
                edgeToEdgeContent: true
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            WorkPiLegacyScrollEdgeEffectMarker()

            Group {
                switch preview.kind {
                case .markdown:
                    if let text = preview.text {
                        WorkPiMarkdownMessageView(text: text, isStreaming: false)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        plainText
                    }
                case .text:
                    plainText
                case .image:
                    WorkPiSafeImageView(
                        url: preview.url,
                        workspaceRoot: workspaceRoot
                    )
                    .frame(maxWidth: .infinity)
                case .binary:
                    inspectorMessage("二进制文件暂不提供文本预览")
                case .tooLarge:
                    inspectorMessage("文件超过当前版本的预览大小限制")
                case .unreadable:
                    inspectorMessage("无法以文本方式读取此文件")
                }
            }
            .padding(.horizontal, 17)
            // 固定标题已经由 safeAreaInset 保留；带标题的预览只保留 6pt
            // 顶部呼吸间距，避免正文看起来与标题脱节。无标题调用保持 17pt。
            .padding(.top, previewTopPadding)
            .padding(.bottom, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 与 Sidebar 一样隐藏 SwiftUI 默认的内容背板，让系统 pocket 能采样到
        // 实际滚动正文；否则 `_NSScrollViewContentBackgroundView` 会把模糊层盖住。
        .scrollContentBackground(.hidden)
        // safeAreaInset 是 SwiftUI 对“固定控件覆盖滚动内容”的正式表达；系统
        // 会据此创建与 Sidebar 相同的系统滚动边缘效果，而不是让一个独立色带盖住正文。
        .safeAreaInset(edge: .top, spacing: 0) {
            if let inspectorTopInset {
                inspectorTopInset
            }
        }
        .workPiTopOnlyScrollEdgeEffect()
    }

    private var previewTopPadding: CGFloat {
        guard inspectorTopInset != nil else { return 17 }
        // macOS 26 的固定标题已经占据安全区；legacy 保持原有预览留白。
        if #available(macOS 26.0, *) { return 6 }
        return 17
    }

    private var plainText: some View {
        Text(preview.text ?? "")
            .font(.system(size: 12.5, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inspectorMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
    }
}

/// 保存状态指示。
///
/// 编辑器有自动保存，用户需要明确知道内容是否已落盘——否则不敢关窗口。
@MainActor
struct WorkPiSaveStateBadge: View {
    @Environment(\.workPiTheme) private var theme

    let state: WorkPiMarkdownEditorState.SaveState
    let language: WorkPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .clean, .saved:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(theme.success)
                Text(isEnglish ? "Saved" : "已保存")
                    .foregroundStyle(.secondary)
            case .dirty:
                Circle()
                    .fill(theme.warning)
                    .frame(width: 5, height: 5)
                Text(isEnglish ? "Unsaved" : "未保存")
                    .foregroundStyle(.secondary)
            case .saving:
                ProgressView().controlSize(.mini).scaleEffect(0.55)
                Text(isEnglish ? "Saving…" : "保存中…")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                Text(isEnglish ? "Save failed" : "保存失败")
                    .foregroundStyle(theme.warning)
                    .help(message)
            }
        }
        .font(.system(size: 10))
    }
}

/// Inspector 的固定顶部内容；作为滚动区的安全区内嵌使用，不是独立遮罩层。
@MainActor
struct WorkPiInspectorTopInsetView: View {
    let preview: FilePreview
    @ObservedObject var editorState: WorkPiMarkdownEditorState
    let theme: WorkPiTheme
    let tint: WorkPiPaneTint
    let isMaximized: Bool
    let isDetached: Bool
    let onToggleMaximize: () -> Void
    let onToggleDetached: () -> Void
    let language: WorkPiInterfaceLanguage
    let onClose: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FileInspectorHeader(
                preview: preview,
                saveState: editorState.isEditing ? editorState.saveState : nil,
                isMaximized: isMaximized,
                isDetached: isDetached,
                onToggleMaximize: onToggleMaximize,
                onToggleDetached: onToggleDetached,
                language: language,
                onClose: onClose,
                onReveal: onReveal,
                onOpen: onOpen,
                onCopyPath: onCopyPath,
                onCopyRelativePath: onCopyRelativePath
            )
            // 保留原有的 0.5pt 几何占位，确保按钮命中层与标题高度一致；
            // 不再绘制横线，避免把固定标题渲染成独立的顶部栏。
            Color.clear
                .frame(height: WorkPiInspectorHeaderMetrics.separatorHeight)
        }
        // 标题区使用与 Inspector clear glass 相同的语义底色，滚动时可遮住
        // 正文，但不会引入未着色的系统灰色顶部栏。
        .background {
            if let color = tint.resolvedColor(using: theme) {
                theme.contentBackground
                    .overlay(color.opacity(theme.metrics.paneTintOpacity))
            } else {
                theme.workspaceBackground
            }
        }
        .zIndex(1)
        .frame(height: WorkPiInspectorHeaderMetrics.totalHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .workPiTheme(theme)
    }
}
