import AppKit
import PiDomain
import PiRPC
import SwiftUI

struct ConversationPane: View {
    @Environment(\.puraPiTheme) private var theme

    let items: [ConversationItem]
    /// 会话树双击某一轮时要定位到的消息。
    let scrollTarget: UUID?
    let onScrollTargetConsumed: () -> Void
    let phase: AgentPhase
    /// Runtime 错误与 Inspector 的 `previewError` 分离；只在对话底部呈现。
    let runtimeError: String?
    let onDismissRuntimeError: () -> Void
    let canDiscardComposerInput: Bool
    let onDiscardComposerInput: () -> Void
    let runtimeNotice: String?
    let onDismissRuntimeNotice: () -> Void
    let canReconnectRuntime: Bool
    let onReconnectRuntime: () -> Void
    let canStartNewSessionAfterRestoreFailure: Bool
    let onStartNewSession: () -> Void
    let runtimeAuthenticationChanged: Bool
    let onOpenAccountSettings: () -> Void
    @Binding var draft: String
    /// 当前被选中的子会话查看器；绑定由工作区 Session 控制器持有。
    @Binding var selectedSubagentTask: SubagentTaskSnapshot?
    let commands: [PuraPiCommandItem]
    let language: PuraPiInterfaceLanguage
    /// Native 三栏中用于与 Inspector 可见间距对称的前导留白；只作用于
    /// Composer/恢复提示等底部浮动内容，真实对话 ScrollView 保持 edge-to-edge；legacy 为 0。
    let leadingContentInset: CGFloat
    /// Native AppKit 容器把真实 viewport 移到 SwiftUI 宿主之外；此时这里只渲染
    /// viewport 之外的活动状态、队列和 Composer。
    let omitsConversationViewport: Bool
    /// 是否由本视图在 viewport 顶部绘制搜索条；Native AppKit 路径把搜索条
    /// 放到独立的 overlay hosting view，避免它进入底部控件的布局流。
    let showsSearchBar: Bool
    let metadata: AgentRuntimeMetadata
    let workspacePath: String
    let isFileSelected: Bool
    let activity: AgentActivity?
    let activityStartedAt: Date
    let queuedPrompts: [PuraPiQueuedPrompt]
    let onCancelQueuedPrompt: (UUID) -> Void
    let sessionStats: PiSessionStats?
    let onDismissStats: () -> Void
    let runtimeStatusPanelPresented: Bool
    let runtimeStatusSnapshot: PuraPiRuntimeStatusSnapshot?
    let runtimeStatusLoading: Bool
    let runtimeStatusPanelError: String?
    let runtimeControlError: String?
    let autoRetryEnabled: Bool?
    let retryWaitState: PuraPiRetryWaitState?
    let turnRecords: [PuraPiTurnRecord]
    let canSetAutoRetry: Bool
    let isSettingAutoRetry: Bool
    let canAbortRetry: Bool
    let isAbortingRetry: Bool
    let onRefreshRuntimeStatus: () -> Void
    let onSetAutoRetry: (Bool) -> Void
    let onAbortRetry: () -> Void
    let onDismissRuntimeStatus: () -> Void
    @ObservedObject var searchState: PuraPiConversationSearchState
    @ObservedObject var markdownEditor: PuraPiMarkdownEditorState
    /// 在本视图每次重绘时读取最新协作状态；编辑器对象本身负责触发重绘。
    let markdownCollaboration: () -> PuraPiMarkdownCollaborationDisplayState
    let onReviewMarkdownChanges: (URL) -> Void
    let onCancelMarkdownChangeApproval: (URL) -> Void
    let onDiscardPendingMarkdownChanges: (URL) -> Void
    let attachments: [PuraPiAttachment]
    let onAttachFiles: ([URL]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onPasteImage: () -> Bool
    let bashExecutions: [BashExecution]
    let onAbortBash: () -> Void
    let onCopyBashOutput: (BashExecution) -> Void
    let onRevealBashOutput: (String) -> Void
    let onClearBashExecutions: () -> Void
    let availableModels: [PiRPCModelInfo]
    let availableThinkingLevels: [String]
    let isModelSwitching: Bool
    let isThinkingLevelSwitching: Bool
    let supportsThinkingLevelSelection: Bool
    let onSelectModel: (PiRPCModelInfo) -> Void
    let onSelectThinkingLevel: (String) -> Void
    let onCompactContext: () -> Void
    let canCompactContext: Bool
    let onToggleAutoCompaction: (Bool) -> Void
    let canToggleAutoCompaction: Bool
    let onExportSession: () -> Void
    let isExporting: Bool
    let onSubmit: () -> Void
    let onSubmitCommand: (String) -> Void
    let onAbort: () -> Void
    let recentSessionRestoreState: PiRecentSessionRestoreState
    let onContinueRecentSession: () -> Void
    let extensionNotifications: [PuraPiExtensionNotification]
    let extensionStatuses: [String: String]
    let extensionWidgets: [PuraPiExtensionWidget]
    let subagentTasks: [SubagentTaskSnapshot]
    let onOpenSubagent: (SubagentTaskSnapshot) -> Void
    let onDismissExtensionNotification: (UUID) -> Void

    var body: some View {
        let markdownState = markdownCollaboration()
        return VStack(spacing: 0) {
            if omitsConversationViewport {
                Color.clear
                    .frame(height: 0)
            } else {
                conversationScrollRegion
            }

            // 活动指示紧跟对话尾部。
            //
            // 行内容在 viewport 里被限制到最大宽度后是居中的，所以正文左边界
            // 是一个随窗口宽度变化的动态值。指示器在 viewport 外，必须用
            // `PuraPiConversationLayout` 的同一公式算偏移，否则会错位。
            // 它在滚动区外，因此逐帧重绘不会触发正文重排。
            if let activity {
                GeometryReader { proxy in
                    PuraPiActivityIndicator(
                        activity: activity,
                        language: language,
                        startedAt: activityStartedAt
                    )
                    .padding(
                        .leading,
                        PuraPiConversationLayout.rowLeadingOffset(
                            availableWidth: proxy.size.width
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: PuraPiActivityIndicator.preferredHeight)
                .padding(.bottom, 6)
                .transition(.opacity)
            }

            if items.isEmpty, recentSessionRestoreState != .loaded {
                ContinueRecentSessionPrompt(
                    state: recentSessionRestoreState,
                    action: onContinueRecentSession
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
            }

            PuraPiExtensionStatusStack(
                notifications: extensionNotifications,
                statuses: extensionStatuses,
                widgets: extensionWidgets,
                widgetPlacement: "aboveEditor",
                onDismissNotification: onDismissExtensionNotification
            )
            .padding(.leading, leadingContentInset)

            if markdownState.isVisible {
                PuraPiMarkdownCollaborationBanner(
                    state: markdownState,
                    language: language,
                    onReview: onReviewMarkdownChanges,
                    onCancelApproval: onCancelMarkdownChangeApproval,
                    onDiscardPending: onDiscardPendingMarkdownChanges
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            if let retryWaitState {
                PuraPiRetryWaitingBanner(
                    wait: retryWaitState,
                    language: language,
                    isCancelling: isAbortingRetry,
                    canCancel: canAbortRetry,
                    onCancel: onAbortRetry
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            // 待执行任务紧贴输入框上方，与 Composer 共用宽度基准。
            if !queuedPrompts.isEmpty {
                PuraPiQueuedPromptList(
                    items: queuedPrompts,
                    language: language,
                    onCancel: onCancelQueuedPrompt
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            if runtimeStatusPanelPresented {
                PuraPiRuntimeStatusPanel(
                    snapshot: runtimeStatusSnapshot,
                    loading: runtimeStatusLoading,
                    error: runtimeStatusPanelError,
                    controlError: runtimeControlError,
                    autoRetryEnabled: autoRetryEnabled,
                    retryWait: retryWaitState,
                    turns: turnRecords,
                    language: language,
                    canSetAutoRetry: canSetAutoRetry,
                    isSettingAutoRetry: isSettingAutoRetry,
                    canAbortRetry: canAbortRetry,
                    isAbortingRetry: isAbortingRetry,
                    onRefresh: onRefreshRuntimeStatus,
                    onSetAutoRetry: onSetAutoRetry,
                    onAbortRetry: onAbortRetry,
                    onDismiss: onDismissRuntimeStatus
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            if let sessionStats {
                PuraPiSessionStatsPanel(
                    stats: sessionStats,
                    language: language,
                    onDismiss: onDismissStats
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            // shell 执行块与待执行任务同区：两者都是尚未进入模型上下文的内容。
            if !bashExecutions.isEmpty {
                PuraPiBashExecutionList(
                    executions: bashExecutions,
                    language: language,
                    onAbort: onAbortBash,
                    onCopy: onCopyBashOutput,
                    onRevealFullOutput: onRevealBashOutput,
                    onClear: onClearBashExecutions
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            if let runtimeNotice, !runtimeNotice.isEmpty {
                RuntimeNoticeBanner(
                    text: runtimeNotice,
                    onDismiss: onDismissRuntimeNotice,
                    actionTitle: canReconnectRuntime
                        ? (language == .english ? "Reconnect" : "重新连接")
                        : nil,
                    onAction: canReconnectRuntime ? onReconnectRuntime : nil,
                    secondaryActionTitle: runtimeAuthenticationChanged
                        ? (language == .english ? "Account settings" : "账号设置")
                        : (canStartNewSessionAfterRestoreFailure && runtimeError?.isEmpty != false
                            ? (language == .english ? "Start new session" : "启动新会话")
                            : nil),
                    onSecondaryAction: runtimeAuthenticationChanged
                        ? onOpenAccountSettings
                        : (canStartNewSessionAfterRestoreFailure && runtimeError?.isEmpty != false
                            ? onStartNewSession
                            : nil),
                    isDismissible: !runtimeAuthenticationChanged
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            if let runtimeError, !runtimeError.isEmpty {
                ErrorBanner(
                    text: runtimeError,
                    onDismiss: onDismissRuntimeError,
                    actionTitle: canDiscardComposerInput
                        ? (language == .english ? "Discard unsent" : "丢弃未发送内容")
                        : (canReconnectRuntime
                            ? (language == .english ? "Reconnect" : "重新连接")
                            : (canStartNewSessionAfterRestoreFailure
                                ? (language == .english ? "Start new session" : "启动新会话")
                                : nil)),
                    onAction: canDiscardComposerInput
                        ? onDiscardComposerInput
                        : (canReconnectRuntime
                            ? onReconnectRuntime
                            : (canStartNewSessionAfterRestoreFailure ? onStartNewSession : nil)),
                    secondaryActionTitle: !canDiscardComposerInput
                        && canReconnectRuntime
                        && canStartNewSessionAfterRestoreFailure
                        ? (language == .english ? "Start new session" : "启动新会话")
                        : nil,
                    onSecondaryAction: !canDiscardComposerInput
                        && canReconnectRuntime
                        && canStartNewSessionAfterRestoreFailure
                        ? onStartNewSession
                        : nil
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            if canDiscardComposerInput, runtimeError?.isEmpty != false {
                ErrorBanner(
                    text: language == .english
                        ? "Composer still has unsent content; send it or discard it explicitly."
                        : "仍有未发送的 Composer 内容；请先发送或显式丢弃。",
                    onDismiss: {},
                    actionTitle: language == .english ? "Discard unsent" : "丢弃未发送内容",
                    onAction: onDiscardComposerInput
                )
                .frame(maxWidth: Composer.maximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, surfaceLeadingPadding)
                .padding(.trailing, surfaceTrailingPadding)
                .padding(.bottom, 7)
                .transition(.opacity)
            }

            Composer(
                text: $draft,
                phase: phase,
                commands: commands,
                language: language,
                metadata: metadata,
                workspacePath: workspacePath,
                isFileSelected: isFileSelected,
                availableModels: availableModels,
                availableThinkingLevels: availableThinkingLevels,
                isModelSwitching: isModelSwitching,
                isThinkingLevelSwitching: isThinkingLevelSwitching,
                supportsThinkingLevelSelection: supportsThinkingLevelSelection,
                onSelectModel: onSelectModel,
                onSelectThinkingLevel: onSelectThinkingLevel,
                onCompactContext: onCompactContext,
                canCompactContext: canCompactContext,
                onToggleAutoCompaction: onToggleAutoCompaction,
                canToggleAutoCompaction: canToggleAutoCompaction,
                onExportSession: onExportSession,
                isExporting: isExporting,
                attachments: attachments,
                onAttachFiles: onAttachFiles,
                onRemoveAttachment: onRemoveAttachment,
                onPasteImage: onPasteImage,
                onSubmit: onSubmit,
                onSubmitCommand: onSubmitCommand,
                onAbort: onAbort,
                subagentTasks: subagentTasks,
                onOpenSubagent: onOpenSubagent
            )
            .padding(.leading, leadingContentInset)

            PuraPiExtensionStatusStack(
                notifications: [],
                statuses: [:],
                widgets: extensionWidgets,
                widgetPlacement: "belowEditor",
                onDismissNotification: onDismissExtensionNotification
            )
            .padding(.leading, leadingContentInset)
        }
        .background {
            PuraPiAdaptiveContentBackground(legacyColor: theme.contentBackground)
        }
        // 搜索状态必须挂在整个 Pane 上，而不是只挂在 SwiftUI viewport 上；
        // Native AppKit 路径会把 viewport 移出这个宿主，但搜索仍需响应 ⌘F 和命中变化。
        .onChange(of: searchState.query) { _, _ in
            searchState.update(items: items)
        }
        .onChange(of: items.count) { _, _ in
            if searchState.isPresented { searchState.update(items: items) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .puraPiFindInConversation)) { _ in
            searchState.isPresented = true
        }
        .sheet(item: $selectedSubagentTask) { task in
            PuraPiSubagentSessionViewer(task: task, language: language)
        }
    }

    private var surfaceLeadingPadding: CGFloat {
        (isFileSelected ? 18 : 42) + leadingContentInset
    }

    private var surfaceTrailingPadding: CGFloat {
        isFileSelected ? 18 : 42
    }

    private var conversationScrollRegion: some View {
        PuraPiConversationViewport(
            items: items,
            language: language,
            theme: theme,
            // 搜索命中优先于会话树的定位请求：两者共用滚动通道，
            // 用户正在搜索时不该被别的来源抢走视图。
            scrollTarget: searchState.currentMatch ?? scrollTarget,
            onScrollTargetConsumed: onScrollTargetConsumed
        )
        .overlay(alignment: .top) {
            if showsSearchBar, searchState.isPresented {
                PuraPiConversationSearchBar(state: searchState, language: language)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContinueRecentSessionPrompt: View {
    @Environment(\.puraPiTheme) private var theme

    let state: PiRecentSessionRestoreState
    let action: () -> Void

    private var title: String {
        state == .failed ? "最近会话恢复失败" : "继续最近会话"
    }

    private var subtitle: String {
        switch state {
        case .loading:
            return "正在加载这个项目最近一次保存的 Pi 会话…"
        case .failed:
            return "Pi 没有完成会话恢复，可以重新尝试"
        case .available, .loaded:
            return "恢复这个项目最近一次保存的 Pi 会话"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if state == .loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: state == .failed ? "exclamationmark.arrow.circlepath" : "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundStyle(state == .failed ? theme.warning : theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if state != .loading {
                PuraPiGlassButton(prominent: true, action: action) {
                    Text(state == .failed ? "重试" : "继续")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 46)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .puraPiGlassSurface(
            role: .glass,
            cornerRadius: 11,
            interactive: true,
            tint: theme.accent.opacity(0.08)
        )
    }
}

@MainActor
struct ConversationItemView: View {
    @Environment(\.puraPiTheme) private var theme

    let item: ConversationItem
    let language: PuraPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    var body: some View {
        switch item.kind {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 80)
                PuraPiMarkdownMessageView(
                    text: item.text,
                    isStreaming: false
                )
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .frame(maxWidth: 620, alignment: .leading)
                .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .puraPiMessageActions(
                    text: item.text,
                    createdAt: item.createdAt,
                    allowsRetry: true,
                    alignment: .trailing
                )
            }
        case .command:
            CommandActivityView(item: item, language: language)
        case .assistant:
            AssistantMessageView(item: item, language: language)
        case .thinking:
            ThinkingActivityView(item: item, language: language)
        case .tool:
            ToolActivityView(item: item, language: language)
        case .system:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                PuraPiMarkdownMessageView(
                    text: item.text,
                    isStreaming: false
                )
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 780, alignment: .leading)
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.error)
                    .padding(.top, 2)
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.error)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CommandActivityView: View {
    @Environment(\.puraPiTheme) private var theme

    let item: ConversationItem
    let language: PuraPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "command.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.status == .failed ? theme.error : theme.accent)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(isEnglish ? "Command" : "命令")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if item.status == .pending || item.status == .streaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else if item.status == .failed {
                        Text("未执行")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.error)
                    } else if item.status == .cancelled {
                        Text(isEnglish ? "Stopped" : "已停止")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if item.status == .completed {
                        Text("已发送")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.text)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(item.status == .failed ? theme.error : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: 780, alignment: .leading)
        .background(
            theme.accent.opacity(item.status == .failed ? 0.06 : 0.09),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

private struct AssistantMessageView: View {
    @Environment(\.puraPiTheme) private var theme

    let item: ConversationItem
    let language: PuraPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                Text("Pi")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                if item.status == .streaming {
                    ProgressView()
                        .controlSize(.mini)
                } else if item.status == .failed {
                    Text(isEnglish ? "Response failed" : "回答失败")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.error)
                } else if item.status == .cancelled {
                    Text(isEnglish ? "Stopped" : "已停止")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if item.text.isEmpty, item.status == .streaming {
                Text(isEnglish ? "Composing a response…" : "正在组织回答…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.tertiary)
            } else {
                PuraPiMarkdownMessageView(
                    text: item.text,
                    isStreaming: item.status == .streaming,
                    streamingText: item.status == .streaming ? item.text : nil
                )
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
        // 流式期间不提供操作：内容还在变，复制到一半的文本没有意义。
        .puraPiMessageActions(
            text: item.status == .streaming ? "" : item.text,
            createdAt: item.createdAt,
            alignment: .leading
        )
    }
}

private struct ThinkingActivityView: View {
    let item: ConversationItem
    let language: PuraPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    /// 折叠状态。默认折叠以免思考过程淹没答案，但必须能展开——
    /// 原先硬限 2 行且没有出口，内容多的思考过程等于被吞掉。
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            if item.text.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 3)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(isEnglish ? "Thinking" : "思考过程")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        // 流式期间不给展开入口：内容还在增长，展开会不断跳动。
                        if item.status != .streaming {
                            Button {
                                isExpanded.toggle()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 7.5, weight: .bold))
                                    Text(isExpanded ? (isEnglish ? "Less" : "收起") : (isEnglish ? "More" : "展开"))
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    PuraPiMarkdownMessageView(
                        text: item.text,
                        isStreaming: item.status == .streaming,
                        streamingText: item.status == .streaming ? item.text : nil
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(thinkingLineLimit)
                    .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
        .opacity(item.status == .completed ? 0.78 : 1)
    }

    private var thinkingLineLimit: Int? {
        if item.status == .streaming { return 4 }
        return isExpanded ? nil : 2
    }
}

private struct ToolActivityView: View {
    @Environment(\.puraPiTheme) private var theme

    let item: ConversationItem
    let language: PuraPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.status == .failed ? theme.error : .secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.title ?? (isEnglish ? "Tool" : "工具"))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    if item.status == .streaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else if item.status == .failed {
                        Text("失败")
                            .font(.caption2)
                            .foregroundStyle(theme.error)
                    } else if item.status == .cancelled {
                        Text(isEnglish ? "Stopped" : "已停止")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if !item.text.isEmpty, item.text != "执行中…" {
                    Text(item.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: 780, alignment: .leading)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

/// 底部对话 HUD：macOS 26 使用局部系统 Liquid Glass，旧系统使用 HUDWindow 语义材质降级；不把整个工作区做成玻璃卡片。
