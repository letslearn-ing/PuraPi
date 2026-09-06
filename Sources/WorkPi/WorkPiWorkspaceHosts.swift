import PiDomain
import SwiftUI

@available(macOS 26.0, *)
@MainActor
struct WorkPiNativeSidebarHostView: View {
    @ObservedObject var session: PiSessionController
    @ObservedObject var layoutState: WorkPiLayoutState
    let language: WorkPiInterfaceLanguage
    let theme: WorkPiTheme
    let sidebarTint: WorkPiPaneTint

    var body: some View {
        WorkPiSidebarPane(
            session: session,
            layoutState: layoutState,
            language: language,
            usesNativeSidebarChrome: true
        )
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workPiTheme(theme)
        .workPiPaneTints(sidebar: sidebarTint, inspector: .purple)
    }
}

@MainActor
struct WorkPiConversationHostView: View {
    @ObservedObject var session: PiSessionController
    let isFileSelected: Bool
    let language: WorkPiInterfaceLanguage
    let theme: WorkPiTheme
    /// Native Sidebar 保持完整宽度后，中心可见内容需要增加的前导留白。
    /// 默认值保持 legacy 和独立测试的原有布局。
    let leadingContentInset: CGFloat
    /// Native AppKit 控制器把真实滚动 viewport 放在 SwiftUI 宿主之外；
    /// SwiftUI 宿主只保留 viewport 之外的底部控件。
    let usesExternalViewport: Bool
    /// 搜索状态由工作区控制器持有，确保 viewport 移出 SwiftUI 宿主后 ⌘F 仍
    /// 与同一个会话上下文共享。
    @ObservedObject var searchState: WorkPiConversationSearchState
    @ObservedObject var markdownEditor: WorkPiMarkdownEditorState

    init(
        session: PiSessionController,
        isFileSelected: Bool,
        language: WorkPiInterfaceLanguage,
        theme: WorkPiTheme,
        leadingContentInset: CGFloat,
        usesExternalViewport: Bool,
        searchState: WorkPiConversationSearchState? = nil
    ) {
        self.session = session
        self.isFileSelected = isFileSelected
        self.language = language
        self.theme = theme
        self.leadingContentInset = leadingContentInset
        self.usesExternalViewport = usesExternalViewport
        self.searchState = searchState ?? WorkPiConversationSearchState()
        self.markdownEditor = session.markdownEditor
    }

    var body: some View {
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
                NotificationCenter.default.post(name: .workPiOpenAccountSettings, object: nil)
            },
            draft: Binding(
                get: { session.draftPrompt },
                set: { session.draftPrompt = $0 }
            ),
            selectedSubagentTask: Binding(
                get: { session.selectedSubagentTask },
                set: { session.selectedSubagentTask = $0 }
            ),
            commands: WorkPiCommandCatalog.items(
                piCommands: session.piCommands,
                language: language
            ),
            language: language,
            leadingContentInset: leadingContentInset,
            omitsConversationViewport: usesExternalViewport,
            showsSearchBar: !usesExternalViewport,
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
            markdownEditor: markdownEditor,
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
        .frame(
            maxWidth: .infinity,
            maxHeight: usesExternalViewport ? nil : .infinity,
            alignment: .top
        )
        .workPiTheme(theme)
    }
}

@MainActor
struct WorkPiInspectorHostView: View {
    @ObservedObject var session: PiSessionController
    @ObservedObject var layoutState: WorkPiLayoutState
    let language: WorkPiInterfaceLanguage
    let theme: WorkPiTheme
    let inspectorTint: WorkPiPaneTint
    let isDetached: Bool
    let onToggleDetached: () -> Void

    init(
        session: PiSessionController,
        layoutState: WorkPiLayoutState,
        language: WorkPiInterfaceLanguage,
        theme: WorkPiTheme = .default,
        inspectorTint: WorkPiPaneTint = .purple,
        isDetached: Bool = false,
        onToggleDetached: @escaping () -> Void = {}
    ) {
        self.session = session
        self.layoutState = layoutState
        self.language = language
        self.theme = theme
        self.inspectorTint = inspectorTint
        self.isDetached = isDetached
        self.onToggleDetached = onToggleDetached
    }

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
            providesOwnSurface: true,
            isDetached: isDetached,
            onToggleDetached: onToggleDetached,
            isLiftHintActive: session.inspectorLiftHint
        )
        // 圆角表面与窗口外框四边都保留 8pt 悬浮间距；内容本身不再额外
        // 保留顶部安全区，因此表面内的文件标题可以与其他栏内容自然对齐。
        .padding(.leading, WorkPiLayoutState.inspectorInset)
        .padding(.trailing, WorkPiLayoutState.inspectorInset)
        .padding(.bottom, WorkPiLayoutState.inspectorInset)
        .padding(
            .top,
            WorkPiLayoutState.inspectorSurfaceTopInset
        )
        // 普通 NSSplitViewItem 不提供系统 Sidebar 外壳；由 Inspector 自己绘制与
        // Sidebar 同指标的悬浮圆角表面。
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workPiTheme(theme)
        .workPiPaneTints(sidebar: .purple, inspector: inspectorTint)
    }
}
