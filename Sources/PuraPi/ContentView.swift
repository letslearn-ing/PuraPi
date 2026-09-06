import AppKit
import PiDomain
import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject private var tabs: PuraPiTabManager
    @ObservedObject private var layoutState: PuraPiLayoutState
    @ObservedObject private var appearanceState: PuraPiAppearanceState
    @ObservedObject private var runtimeProvisioner: PuraPiRuntimeProvisioner
    @ObservedObject private var authCoordinator: PuraPiAuthCoordinator
    private let inspectorCoordinator: PuraPiInspectorWindowCoordinator
    @State private var isPresentingProjectPanel = false

    init(
        tabs: PuraPiTabManager,
        layoutState: PuraPiLayoutState,
        appearanceState: PuraPiAppearanceState,
        runtimeProvisioner: PuraPiRuntimeProvisioner,
        authCoordinator: PuraPiAuthCoordinator? = nil,
        inspectorCoordinator: PuraPiInspectorWindowCoordinator? = nil
    ) {
        _tabs = ObservedObject(wrappedValue: tabs)
        _layoutState = ObservedObject(wrappedValue: layoutState)
        _appearanceState = ObservedObject(wrappedValue: appearanceState)
        _runtimeProvisioner = ObservedObject(wrappedValue: runtimeProvisioner)
        _authCoordinator = ObservedObject(
            wrappedValue: authCoordinator ?? PuraPiAuthCoordinator(
                selection: runtimeProvisioner.selection
            )
        )
        self.inspectorCoordinator = inspectorCoordinator ?? PuraPiInspectorWindowCoordinator(
            tabs: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
    }

    @MainActor
    init(
        tabs: PuraPiTabManager,
        layoutState: PuraPiLayoutState,
        appearanceState: PuraPiAppearanceState
    ) {
        self.init(
            tabs: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState,
            runtimeProvisioner: PuraPiRuntimeProvisioner()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.selectedTab != nil, runtimeProvisioner.needsUserAction {
                PuraPiRuntimeProvisioningView(
                    provisioner: runtimeProvisioner,
                    language: appearanceState.language,
                    compact: true,
                    showsManualChoice: true
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            if let tab = tabs.selectedTab {
                ProjectWorkspaceView(
                    tab: tab,
                    layoutState: layoutState,
                    language: appearanceState.language,
                    sidebarTint: appearanceState.sidebarTint,
                    inspectorTint: appearanceState.inspectorTint,
                    inspectorCoordinator: inspectorCoordinator
                )
                    .id(tab.id)
            } else {
                PuraPiEmptyWorkspaceView(
                    runtimeProvisioner: runtimeProvisioner,
                    authCoordinator: authCoordinator,
                    language: appearanceState.language,
                    onCreateProject: presentCreatePanel,
                    onOpenProject: presentOpenPanel,
                    onOpenAccountSettings: {
                        NotificationCenter.default.post(
                            name: .puraPiOpenAccountSettings,
                            object: nil
                        )
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .puraPiTheme(appearanceState.theme)
        .background(PuraPiWindowBackdrop())
        .onChange(of: runtimeProvisioner.availability) { _, availability in
            guard availability.isAvailable else { return }
            tabs.retryRuntimesWaitingForProvisioning()
            if !authCoordinator.hasLoadedStatus, !authCoordinator.isBusy {
                authCoordinator.refreshStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiAuthenticationChanged)) { _ in
            tabs.markRuntimeAuthenticationChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiNewWorkspace)) { _ in
            presentCreatePanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiOpenWorkspace)) { _ in
            presentOpenPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiCloseSelectedTab)) { _ in
            tabs.closeSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiCloseAllProjects)) { _ in
            tabs.closeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiToggleInspectorDetached)) { _ in
            if let tab = tabs.selectedTab {
                inspectorCoordinator.toggle(tab: tab)
            }
        }
    }

    private func presentCreatePanel() {
        guard !isPresentingProjectPanel else { return }
        isPresentingProjectPanel = true
        defer { isPresentingProjectPanel = false }

        let panel = NSSavePanel()
        panel.title = "新建项目文件夹"
        panel.message = "选择保存位置并输入项目文件夹名称"
        panel.prompt = "创建"
        panel.nameFieldLabel = "名称："
        panel.nameFieldStringValue = "未命名项目"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try createProjectDirectory(at: url)
            tabs.openProject(at: url)
        } catch {
            presentCreationError(error)
        }
    }

    private func presentOpenPanel() {
        guard !isPresentingProjectPanel else { return }
        isPresentingProjectPanel = true
        defer { isPresentingProjectPanel = false }

        let panel = NSOpenPanel()
        panel.title = "打开项目文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "打开"
        panel.message = "选择一个项目文件夹"

        if panel.runModal() == .OK, let url = panel.url {
            tabs.openProject(at: url)
        }
    }

    private func createProjectDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw CocoaError(.fileWriteFileExists)
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: nil
        )
    }

    private func presentCreationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法创建项目文件夹"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private struct ProjectWorkspaceView: View {
    let tab: PuraPiProjectTab
    @ObservedObject var layoutState: PuraPiLayoutState
    let language: PuraPiInterfaceLanguage
    let sidebarTint: PuraPiPaneTint
    let inspectorTint: PuraPiPaneTint
    let inspectorCoordinator: PuraPiInspectorWindowCoordinator

    var body: some View {
        SessionWorkspaceView(
            session: tab.session,
            layoutState: layoutState,
            language: language,
            sidebarTint: sidebarTint,
            inspectorTint: inspectorTint,
            onToggleInspectorDetached: {
                inspectorCoordinator.toggle(tab: tab)
            }
        )
    }
}

private struct SessionWorkspaceView: View {
    @Environment(\.puraPiTheme) private var theme
    @ObservedObject var session: PiSessionController
    @ObservedObject var layoutState: PuraPiLayoutState
    let language: PuraPiInterfaceLanguage
    let sidebarTint: PuraPiPaneTint
    let inspectorTint: PuraPiPaneTint
    let onToggleInspectorDetached: () -> Void

    /// 搜索状态按工作区持有：每个项目标签有自己的搜索上下文。
    @StateObject private var searchState = PuraPiConversationSearchState()

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                PuraPiNativeWorkspaceSplitView(
                    session: session,
                    layoutState: layoutState,
                    isFileSelected: session.selectedFileURL != nil,
                    inspectorDetached: session.inspectorDetached,
                    onToggleInspectorDetached: onToggleInspectorDetached,
                    sidebarVisible: layoutState.sidebarVisible,
                    sidebarWidth: layoutState.sidebarWidth,
                    inspectorWidth: layoutState.inspectorWidth,
                    inspectorMaximized: layoutState.inspectorMaximized,
                    language: language,
                    theme: theme,
                    sidebarTint: sidebarTint,
                    inspectorTint: inspectorTint
                )
                .frame(minWidth: 980, maxWidth: .infinity, maxHeight: .infinity)
                // 原生 Split 需要覆盖统一标题栏区域；Sidebar item 的系统表面从窗口
                // 顶部开始，文件树只在内容层保留交通灯安全区。
                .ignoresSafeArea(.container, edges: .top)
            } else {
                legacyWorkspaceLayout
            }
        }
        // legacy 视图在同一个 SwiftUI 子树内通过 Environment（环境值）读取颜色；
        // 原生三栏会把同一份值显式传入独立的 NSHostingController。
        .puraPiPaneTints(sidebar: sidebarTint, inspector: inspectorTint)
        .background {
            PuraPiAdaptiveContentBackground(legacyColor: theme.workspaceBackground)
        }
        .sheet(
            isPresented: Binding(
                get: { session.projectAuthorizationState == .needsDecision },
                set: { presented in
                    if !presented,
                       session.projectAuthorizationState == .needsDecision {
                        session.denyProjectAuthorization()
                    }
                }
            )
        ) {
            PuraPiProjectAuthorizationView(
                rootURL: session.workspace?.rootURL ?? URL(fileURLWithPath: "/"),
                language: language,
                onAllowOnce: { session.approveProjectAuthorization() },
                onAllowAndRemember: { session.approveProjectAuthorization(remember: true) },
                onDeny: { session.denyProjectAuthorization() }
            )
        }
        .sheet(
            item: Binding(
                get: { session.extensionUIRequest },
                // 对话视图的 `onDisappear` 携带具体 request id 并负责取消。
                // 这里忽略 SwiftUI 的回写，避免旧 sheet 的迟到回调误取消新请求。
                set: { _ in }
            )
        ) { request in
            PuraPiExtensionUIDialog(
                request: request,
                onResolve: { requestID, result in
                    session.resolveExtensionUI(requestID, result)
                }
            )
            .id(request.id)
        }
        .sheet(
            item: Binding(
                get: { session.markdownDiffReview },
                set: { review in
                    if review == nil { session.dismissMarkdownDiffReview() }
                }
            )
        ) { review in
            PuraPiMarkdownDiffReviewSheet(
                review: review,
                language: language,
                onApprove: {
                    session.approveMarkdownDiffReview(id: review.id)
                }
            )
            .id(review.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                layoutState.toggleSidebar()
            }
        }
        // 「编辑」把原文填回输入框，用户改完自己发。
        .onReceive(NotificationCenter.default.publisher(for: .puraPiEditMessage)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            session.draftPrompt = text
        }
        // 「重试」原样立即重发。Agent 忙时走既有排队逻辑，不会丢。
        .onReceive(NotificationCenter.default.publisher(for: .puraPiRetryMessage)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            session.retryMessage(text)
        }
    }

    @ViewBuilder
    private var legacyWorkspaceLayout: some View {
        HStack(spacing: 0) {
            if layoutState.sidebarVisible {
                ResizableSidebar(
                    layoutState: layoutState,
                    root: session.fileTree,
                    selectedURL: session.selectedFileURL,
                    onSelect: session.selectFile,
                    onToggleDirectory: session.toggleDirectory,
                    onClearSelection: session.clearFileSelection,
                    onReveal: session.revealInFinder,
                    onOpen: session.openWithDefaultApplication,
                    onCopyPath: { session.copyPath($0, relative: false) },
                    onCopyRelativePath: { session.copyPath($0, relative: true) }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            legacyWorkspaceContent
        }
    }

    @ViewBuilder
    private var legacyWorkspaceContent: some View {
        if session.selectedFileURL != nil && !session.inspectorDetached {
            // 用 HStack + 自绘手柄而不是 HSplitView：
            // HSplitView 自己管理分栏位置，宽度无法与 `layoutState.inspectorWidth`
            // 双向同步（拖完读不到值，也无法持久化），且最大化时没法压缩工作区。
            HStack(spacing: 0) {
                if !layoutState.inspectorMaximized {
                    conversation(isFileSelected: true)
                        .frame(minWidth: 420, maxWidth: .infinity)
                }

                PuraPiAttachedInspector(
                    session: session,
                    layoutState: layoutState,
                    language: language,
                    onToggleDetached: onToggleInspectorDetached
                )
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            // Inspector 挂到独立窗口后，主窗口只保留左侧目录树和中心对话；
            // 仍把“已选中文件”传给 Composer，使输入态保持紧凑而不改变语义。
            conversation(isFileSelected: session.selectedFileURL != nil)
                .frame(minWidth: 420, maxWidth: .infinity)
        }
    }

    private func conversation(isFileSelected: Bool) -> some View {
        ConversationPane(
            items: session.conversation,
            scrollTarget: session.conversationScrollTarget,
            onScrollTargetConsumed: { session.clearConversationScrollTarget() },
            phase: session.phase,
            runtimeError: session.lastError,
            onDismissRuntimeError: session.clearError,
            canDiscardComposerInput: session.composerCloseBlocked && session.hasUnsentComposerInput,
            onDiscardComposerInput: session.discardComposerInput,
            runtimeNotice: session.runtimeNotice,
            onDismissRuntimeNotice: session.clearRuntimeNotice,
            canReconnectRuntime: session.canReconnectRuntime,
            onReconnectRuntime: session.reconnectRuntime,
            canStartNewSessionAfterRestoreFailure: session.canStartNewSessionAfterRestoreFailure,
            onStartNewSession: { session.startNewSession() },
            runtimeAuthenticationChanged: session.runtimeAuthenticationChanged,
            onOpenAccountSettings: {
                NotificationCenter.default.post(name: .puraPiOpenAccountSettings, object: nil)
            },
            draft: $session.draftPrompt,
            selectedSubagentTask: Binding(
                get: { session.selectedSubagentTask },
                set: { session.selectedSubagentTask = $0 }
            ),
            commands: PuraPiCommandCatalog.items(
                piCommands: session.piCommands,
                language: language
            ),
            language: language,
            leadingContentInset: 0,
            omitsConversationViewport: false,
            showsSearchBar: true,
            metadata: session.runtimeMetadata,
            workspacePath: session.workspace?.rootURL.path ?? "",
            isFileSelected: isFileSelected,
            activity: session.activity,
            activityStartedAt: session.activityStartedAt,
            queuedPrompts: session.queuedPrompts,
            onCancelQueuedPrompt: session.cancelQueuedPrompt,
            sessionStats: session.sessionStats,
            onDismissStats: { session.dismissSessionStats() },
            runtimeStatusPanelPresented: session.runtimeStatusPanelPresented,
            runtimeStatusSnapshot: session.runtimeStatusSnapshot,
            runtimeStatusLoading: session.runtimeStatusLoading,
            runtimeStatusPanelError: session.runtimeStatusPanelError,
            runtimeControlError: session.runtimeControlError,
            autoRetryEnabled: session.autoRetryEnabled,
            retryWaitState: session.retryWaitState,
            turnRecords: session.turnRecords,
            canSetAutoRetry: session.canSetAutoRetry,
            isSettingAutoRetry: session.isSettingAutoRetry,
            canAbortRetry: session.canAbortRetry,
            isAbortingRetry: session.isAbortingRetry,
            onRefreshRuntimeStatus: { session.refreshStatusPanel() },
            onSetAutoRetry: { session.setAutoRetry(enabled: $0) },
            onAbortRetry: { session.abortRetry() },
            onDismissRuntimeStatus: { session.dismissStatusPanel() },
            searchState: searchState,
            markdownEditor: session.markdownEditor,
            markdownCollaboration: { session.markdownCollaborationDisplayState },
            onReviewMarkdownChanges: { session.presentMarkdownDiffReview(for: $0) },
            onCancelMarkdownChangeApproval: { session.cancelApprovedMarkdownDiff(for: $0) },
            onDiscardPendingMarkdownChanges: { session.discardPendingMarkdownCollaboration(for: $0) },
            attachments: session.pendingAttachments,
            onAttachFiles: { session.attachFiles($0) },
            onRemoveAttachment: { session.removeAttachment(id: $0) },
            onPasteImage: { session.attachImageFromPasteboard() },
            bashExecutions: session.bashExecutions,
            onAbortBash: { session.abortBashCommand() },
            onCopyBashOutput: { session.copyBashOutput($0) },
            onRevealBashOutput: { session.revealBashFullOutput($0) },
            onClearBashExecutions: { session.clearBashExecutions() },
            availableModels: session.availableModels,
            availableThinkingLevels: session.availableThinkingLevels,
            isModelSwitching: session.modelSwitchInFlight,
            isThinkingLevelSwitching: session.thinkingLevelSwitchInFlight,
            supportsThinkingLevelSelection: session.supportsThinkingLevelSelection,
            onSelectModel: { session.selectModel(provider: $0.provider, modelID: $0.id) },
            onSelectThinkingLevel: session.selectThinkingLevel,
            onCompactContext: { session.compactSession() },
            canCompactContext: session.canCompactContext,
            onToggleAutoCompaction: { session.setAutoCompaction(enabled: $0) },
            canToggleAutoCompaction: session.runtimeReady && !session.runtimeAuthenticationChanged,
            onExportSession: { session.exportSessionHTML() },
            isExporting: session.isExporting,
            onSubmit: session.submitPrompt,
            onSubmitCommand: session.submitCommand,
            onAbort: session.abort,
            recentSessionRestoreState: session.recentSessionRestoreState,
            onContinueRecentSession: { session.continueRecentSession() },
            extensionNotifications: session.extensionNotifications,
            extensionStatuses: session.extensionStatuses,
            extensionWidgets: Array(session.extensionWidgets.values),
            subagentTasks: session.subagentTasks,
            onOpenSubagent: session.openSubagentTask,
            onDismissExtensionNotification: session.dismissExtensionNotification
        )
    }
}

private struct ResizableSidebar: View {
    @Environment(\.puraPiTheme) private var theme
    @ObservedObject var layoutState: PuraPiLayoutState
    let root: FileNode?
    let selectedURL: URL?
    let onSelect: (URL) -> Void
    let onToggleDirectory: (URL, Bool) -> Void
    let onClearSelection: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void

    @State private var isDraggingResizeEdge = false
    @State private var isHoveringResizeEdge = false

    var body: some View {
        FileTreePane(
            root: root,
            selectedURL: selectedURL,
            onSelect: onSelect,
            onToggleDirectory: onToggleDirectory,
            onClearSelection: onClearSelection,
            onReveal: onReveal,
            onOpen: onOpen,
            onCopyPath: onCopyPath,
            onCopyRelativePath: onCopyRelativePath
        )
        .frame(width: layoutState.sidebarWidth)
        .padding(PuraPiLayoutState.sidebarInset)
        .overlay(alignment: .trailing) {
            sidebarResizeEdge
                .offset(x: -PuraPiLayoutState.sidebarInset)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarResizeEdge: some View {
        ZStack {
            PuraPiSidebarResizeHandle(
                width: layoutState.sidebarWidth,
                onResizeStart: { isDraggingResizeEdge = true },
                onResize: { layoutState.resizeSidebar(to: $0) },
                onResizeEnd: {
                    isDraggingResizeEdge = false
                    layoutState.persistSidebarWidth()
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
        .help("拖动以调整侧边栏宽度")
        .accessibilityLabel("调整侧边栏宽度")
    }
}

/// 标题栏中的项目标签状态桥。它观察同一个 `PuraPiTabManager`，
/// 因此标签栏移动到 AppKit 标题栏后，仍与主内容共享完全相同的状态。
struct PuraPiTitlebarTabs: View {
    @ObservedObject var manager: PuraPiTabManager
    @ObservedObject var appearanceState: PuraPiAppearanceState

    static let tabWidth: CGFloat = 190
    static let addButtonWidth: CGFloat = 34
    static let tabBarLeadingInset: CGFloat = 4
    static let tabBarHeight: CGFloat = 34

    /// 项目标签胶囊只覆盖真正的标签内容。
    static func tabBarWidth(tabCount: Int) -> CGFloat {
        tabBarLeadingInset + CGFloat(tabCount) * tabWidth + addButtonWidth
    }

    static func toolbarWidth(for manager: PuraPiTabManager) -> CGFloat {
        tabBarWidth(tabCount: manager.tabs.count)
    }

    var body: some View {
        ProjectTabBar(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabID,
            onSelect: manager.select,
            onClose: manager.close,
            onAdd: {
                NotificationCenter.default.post(name: .puraPiOpenWorkspace, object: nil)
            }
        )
        .frame(
            width: Self.toolbarWidth(for: manager),
            height: Self.tabBarHeight,
            alignment: .leading
        )
        .puraPiTheme(appearanceState.theme)
    }
}

struct ProjectTabBar: View {
    let tabs: [PuraPiProjectTab]
    let selectedTabID: UUID?
    let onSelect: (PuraPiProjectTab) -> Void
    let onClose: (PuraPiProjectTab) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                ProjectTabItem(
                    tab: tab,
                    isSelected: selectedTabID == tab.id,
                    onSelect: { onSelect(tab) },
                    onClose: { onClose(tab) }
                )
            }

            ProjectAddButton(action: onAdd)
        }
        .padding(.leading, PuraPiTitlebarTabs.tabBarLeadingInset)
        .frame(
            width: PuraPiTitlebarTabs.tabBarWidth(tabCount: tabs.count),
            height: PuraPiTitlebarTabs.tabBarHeight,
            alignment: .leading
        )
        // 原生全高 Sidebar 已让 Toolbar 前导边界跟随 divider；单个系统
        // .space 只保留固定间距。macOS 26 的 NSToolbarItem 自己已经绘制
        // 系统胶囊；这里不能再叠加
        // 一层 SwiftUI glassEffect，否则会出现上下错位的双重轮廓。
        .modifier(ProjectTabBarSurfaceModifier())
        .contentShape(Capsule())
    }
}

/// macOS 26 的自定义 NSToolbarItem 已经提供系统胶囊；旧系统才需要
/// 使用 PuraPi 的语义化材质作为降级。把两个路径隔离，避免在新系统上重复绘制玻璃。
private struct ProjectTabBarSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.puraPiGlassSurface(
                role: .glass,
                cornerRadius: PuraPiTitlebarTabs.tabBarHeight / 2,
                interactive: true
            )
        }
    }
}

private enum ProjectTabContentAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let projectTabContent = VerticalAlignment(ProjectTabContentAlignmentID.self)
}

private struct ProjectTabItem: View {
    @Environment(\.puraPiTheme) private var theme

    let tab: PuraPiProjectTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @ObservedObject private var session: PiSessionController
    @State private var isHovering = false

    init(tab: PuraPiProjectTab, isSelected: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.tab = tab
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onClose = onClose
        _session = ObservedObject(wrappedValue: tab.session)
    }

    private static let iconColumnWidth: CGFloat = 20
    private static let trailingColumnWidth: CGFloat = 18
    private static let contentRowHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .projectTabContent, spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: Self.iconColumnWidth, height: Self.contentRowHeight, alignment: .center)
                .alignmentGuide(.projectTabContent) { dimensions in
                    dimensions[VerticalAlignment.center]
                }

            Text(tab.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: Self.contentRowHeight, alignment: .leading)
                .alignmentGuide(.projectTabContent) { dimensions in
                    dimensions[VerticalAlignment.center]
                }

            trailingAccessory
                .frame(width: Self.trailingColumnWidth, height: Self.contentRowHeight, alignment: .center)
                .alignmentGuide(.projectTabContent) { dimensions in
                    dimensions[VerticalAlignment.center]
                }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: PuraPiTitlebarTabs.tabWidth, height: PuraPiTitlebarTabs.tabBarHeight)
        .background {
            if isSelected {
                // macOS 26 外层系统胶囊是唯一的 Toolbar chrome。
                // 选中态使用同心的内层 Capsule，不再叠加另一套小圆角矩形。
                Capsule()
                    .fill(theme.accent.opacity(0.18))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 3)
            } else if isHovering {
                Rectangle()
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.hairline)
                .frame(width: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("关闭标签页", action: onClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isHovering {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭标签页")
        } else if tab.hasError {
            Circle()
                .fill(theme.error)
                .frame(width: 6, height: 6)
                .frame(width: 18, height: 18)
        } else if tab.isWorking {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18, height: 18)
        } else if session.inspectorDetached {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .help("检查器已在独立窗口中")
        } else {
            Color.clear
                .frame(width: 18, height: 18)
        }
    }
}

private struct ProjectAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("打开项目文件夹")
        .accessibilityLabel("打开项目文件夹")
    }
}
