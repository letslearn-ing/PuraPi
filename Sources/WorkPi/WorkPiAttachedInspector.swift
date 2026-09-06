import AppKit
import PiDomain
import SwiftUI

/// macOS 14–25 的右侧 Inspector：悬浮圆角、左边缘拖拽和宽度持久化。
///
/// macOS 26 由 `WorkPiWorkspaceSplitViewController` 管理原生三栏；这条 legacy
/// 路径只负责在 SwiftUI HStack 中装配同一份 Inspector 内容。
@MainActor
struct WorkPiAttachedInspector: View {
    @Environment(\.workPiTheme) private var theme
    @ObservedObject var session: PiSessionController
    @ObservedObject var layoutState: WorkPiLayoutState
    let language: WorkPiInterfaceLanguage
    let onToggleDetached: () -> Void

    @State private var isDraggingResizeEdge = false
    @State private var isHoveringResizeEdge = false

    var body: some View {
        FileInspectorPane(
            preview: session.selectedPreview,
            workspaceRoot: session.workspace?.rootURL,
            editorState: session.markdownEditor,
            layoutState: layoutState,
            language: language,
            error: session.previewError,
            onRetry: session.retryFilePreview,
            onClose: session.clearFileSelection,
            onReveal: session.revealInFinder,
            onOpen: session.openWithDefaultApplication,
            onCopyPath: { session.copyPath($0, relative: false) },
            onCopyRelativePath: { session.copyPath($0, relative: true) },
            onToggleDetached: onToggleDetached,
            isLiftHintActive: session.inspectorLiftHint
        )
        .frame(width: layoutState.inspectorMaximized ? nil : layoutState.inspectorWidth)
        .frame(maxWidth: layoutState.inspectorMaximized ? .infinity : nil)
        // 圆角表面与窗口外框四边都保留 8pt 悬浮间距；内容本身不再额外
        // 保留顶部安全区，因此表面内的文件标题可以与其他栏内容自然对齐。
        .padding(.leading, WorkPiLayoutState.inspectorInset)
        .padding(.trailing, WorkPiLayoutState.inspectorInset)
        .padding(.bottom, WorkPiLayoutState.inspectorInset)
        .padding(.top, WorkPiLayoutState.inspectorSurfaceTopInset)
        .overlay(alignment: .leading) {
            // 最大化时没有可拖的边界，隐藏手柄避免误操作。
            if !layoutState.inspectorMaximized {
                inspectorResizeEdge
                    .offset(x: WorkPiLayoutState.inspectorInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            // legacy 路径同样使用真实 AppKit 命中代理：SwiftUI 的预览 ScrollView
            // 可能覆盖标题栏内部按钮，但不应牺牲正文滚动来换取按钮可点。
            WorkPiInspectorHeaderInteractionStack(
                previewURL: session.selectedPreview?.url ?? session.selectedFileURL,
                showsFileActions: session.selectedPreview != nil || session.selectedFileURL != nil,
                isDetached: false,
                language: language,
                onToggleMaximize: { layoutState.inspectorMaximized.toggle() },
                onToggleDetached: onToggleDetached,
                onClose: session.clearFileSelection,
                onReveal: session.revealInFinder,
                onOpen: session.openWithDefaultApplication,
                onCopyPath: { session.copyPath($0, relative: false) },
                onCopyRelativePath: { session.copyPath($0, relative: true) }
            )
            .padding(.top, WorkPiLayoutState.inspectorSurfaceTopInset)
            .padding(
                .trailing,
                WorkPiLayoutState.inspectorInset + WorkPiInspectorHeaderMetrics.trailingPadding
            )
        }
    }

    private var inspectorResizeEdge: some View {
        ZStack {
            WorkPiSidebarResizeHandle(
                width: layoutState.inspectorWidth,
                edge: .leadingEdgeOfTrailingPane,
                onResizeStart: { isDraggingResizeEdge = true },
                onResize: { layoutState.resizeInspector(to: $0) },
                onResizeEnd: {
                    isDraggingResizeEdge = false
                    layoutState.persistInspectorWidth()
                },
                onHover: { isHoveringResizeEdge = $0 }
            )

            Capsule()
                .fill(
                    theme.accent.opacity(
                        isHoveringResizeEdge || isDraggingResizeEdge ? 0.52 : 0
                    )
                )
                .frame(width: 2, height: 42)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: isHoveringResizeEdge)
        }
        .frame(width: 10)
        .help(language == .english ? "Drag to resize inspector" : "拖动以调整检查器宽度")
        .accessibilityLabel(language == .english ? "Resize inspector" : "调整检查器宽度")
    }
}
