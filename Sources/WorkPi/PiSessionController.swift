import AppKit
import Combine
import Foundation
import PiDomain
import PiRPC
import SwiftUI
import WorkspaceKit

/// 一个项目工作区对应的 UI 状态协调器。
///
/// 公共生命周期和用户动作保留在本文件；Pi Runtime 事件状态机见
/// `PiSessionController+Runtime.swift`，目录树/预览/FSEvents 见
/// `PiSessionController+Workspace.swift`。三部分共享同一个 `generation`，
/// 用来丢弃旧 Runtime 或旧异步任务的迟到事件。
@MainActor
final class PiSessionController: ObservableObject {
    // 这些属性对模块外仍是内部实现细节；去掉 private(set) 是为了让同一类型的
    // Runtime/Workspace 扩展共享发布状态，而不是把近千行逻辑重新塞回一个文件。
    @Published var workspace: WorkspaceDescriptor?
    @Published var fileTree: FileNode?
    @Published var selectedFileURL: URL?
    @Published var selectedPreview: FilePreview?
    @Published var previewError: String?
    /// Inspector 是否已经从主工作区栏位挂到独立窗口。
    ///
    /// 这是每个项目 Session 自己的展示状态，不放进全局布局状态；不同标签可以
    /// 同时拥有不同的 Inspector 展示位置。预览和 Markdown 编辑内容仍只存在于
    /// 本控制器中。
    @Published private(set) var inspectorDetached = false
    /// 点击独立窗口按钮后短暂显示的边缘抬升提示；它只影响视觉反馈。
    @Published private(set) var inspectorLiftHint = false
    @Published var conversation: [ConversationItem] = []
    @Published var phase: AgentPhase = .idle
    @Published var runOutcome: AgentRunOutcome = .completed
    @Published var runtimeStatus = "未打开项目"
    @Published var runtimeMetadata = AgentRuntimeMetadata()
    /// 当前正在进行的具体活动；nil 表示空闲，不显示指示器。
    /// 只由 Pi 事件驱动，不从 phase 反推。
    @Published var activity: AgentActivity?
    /// 当前活动的开始时刻，用于显示已耗时。
    @Published var activityStartedAt = Date()
    /// 待执行的任务队列。由 WorkPi 维护，以便支持取消。
    @Published var queuedPrompts: [WorkPiQueuedPrompt] = []
    /// 当前项目的会话列表，来自磁盘扫描。
    @Published var sessionSummaries: [PiSessionSummary] = []
    /// 已展开会话的轮次缓存，键为会话文件路径。
    @Published var sessionTurns: [String: [PiSessionTurn]] = [:]
    /// 当前会话的文件路径与显示名，由 `get_state` 报告。
    @Published var activeSessionFilePath: String?
    @Published var activeSessionName: String?
    /// 对话区需要滚动到的消息；由会话树双击某一轮触发。
    @Published var conversationScrollTarget: UUID?
    /// in-flight 的 `export_html` 请求 id；非 nil 表示正在导出。
    @Published var activeExportCommandID: String?
    /// in-flight 的 `set_auto_compaction` 请求 id。
    @Published var activeAutoCompactionCommandID: String?
    /// 直接执行的 shell 命令块，按发起顺序排列。
    @Published var bashExecutions: [BashExecution] = []
    /// 待随下一条消息发送的附件。
    @Published var pendingAttachments: [WorkPiAttachment] = []
    /// `/status` 查询到的会话统计；nil 表示当前没有可显示的统计结果。
    @Published var sessionStats: PiSessionStats?
    /// `/status` 的一次性 Runtime 状态区块；不放入常驻 HUD。
    @Published var runtimeStatusSnapshot: WorkPiRuntimeStatusSnapshot?
    @Published var runtimeStatusPanelPresented = false
    @Published var runtimeStatusLoading = false
    @Published var runtimeStatusPanelError: String?
    @Published var turnRecords: [WorkPiTurnRecord] = []
    @Published var retryWaitState: WorkPiRetryWaitState?
    /// Pi 0.84.4 没有通过 `get_state` 回读 auto retry 的字段；nil 表示本连接尚未成功设置。
    @Published var autoRetryEnabled: Bool?
    @Published var runtimeControlError: String?
    /// 右栏 Markdown 编辑器状态。生命周期跟随文件选择。
    let markdownEditor = WorkPiMarkdownEditorState()
    /// Markdown 差异审阅 sheet 当前显示的快照；不会自动打开或自动发送。
    @Published var markdownDiffReview: WorkPiMarkdownDiffReview?
    @Published var markdownDiffReviewError: String?
    @Published var isBuildingMarkdownDiffReview = false
    /// 已保存但尚未确认给 Agent 的文件快照。键按标准化 URL 隔离，切换文件不会
    /// 丢掉前一个文件的协作差异。
    @Published var pendingMarkdownSnapshots: [URL: WorkPiMarkdownChangeSnapshot] = [:]
    /// 用户已经审阅并选择“附加到下一条消息”的多个文件差异。
    @Published var approvedMarkdownChanges: [URL: WorkPiMarkdownApprovedChange] = [:]
    /// 关闭文件因未确认 Markdown 协作差异被阻止时，提示用户审阅或显式放弃同步。
    @Published var markdownCollaborationCloseBlocked = false
    /// 新建文件/文件夹后需要展开的目录，供文件树消费一次。
    @Published var directoryToReveal: URL?
    var activeStatsCommandID: String?
    var activeRuntimeStatusRequestID: String?
    var activeAutoRetryCommandID: String?
    var pendingAutoRetryValue: Bool?
    var activeAbortRetryCommandID: String?
    /// 绑定到发起取消请求时的退避 token；响应成功后保留到 `auto_retry_end`。
    var activeAbortRetryWaitID: UUID?
    /// `/status` 可与 HUD 的统计刷新并发；按 request id 保存每个可见命令项。
    var activeStatsRequestIDs: Set<String> = []
    var statsRequestItemIDs: [String: UUID] = [:]
    var statsCommandItemID: UUID?
    /// 切换会话后待定位的轮次正文。历史重建完成才能匹配，故先记下意图。
    var pendingTurnLocation: String?
    var activeTurnRecordID: UUID?
    @Published var lastError: String?
    /// Runtime 在用户取消后退出时的非错误提示；与真正的 Runtime 错误分开，
    /// 但仍必须让用户知道 Composer 当前不能发送。
    @Published var runtimeNotice: String?
    /// 认证凭据已改变，但当前 Pi 子进程尚未重启；空闲时可通过“重新连接”应用。
    @Published var runtimeAuthenticationChanged = false
    /// 启动时没有找到可执行的 Pi；安装/发现完成后，标签管理器可以只重试
    /// 这类失败，不会把普通 Runtime 崩溃误当成安装问题。
    @Published var runtimeProvisioningRequired = false
    /// 关闭工作区因未发送 Composer 内容被阻止后，显示一次显式丢弃动作。
    @Published var composerCloseBlocked = false
    @Published var draftPrompt = ""
    @Published var recentSessionRestoreState: PiRecentSessionRestoreState = .available
    @Published var projectAuthorizationState: WorkPiProjectAuthorizationState = .notRequired
    @Published var piCommands: [PiRPCCommandInfo] = []
    /// Pi 报告的可用模型与当前模型支持的推理级别；空集合表示不可切换。
    @Published var availableModels: [PiRPCModelInfo] = []
    @Published var availableThinkingLevels: [String] = []
    @Published var modelSwitchInFlight = false
    @Published var thinkingLevelSwitchInFlight = false
    @Published var extensionUIRequest: PiExtensionUIRequest?
    @Published var extensionNotifications: [WorkPiExtensionNotification] = []
    @Published var extensionStatuses: [String: String] = [:]
    @Published var extensionWidgets: [String: WorkPiExtensionWidget] = [:]
    /// 主 Agent 当前会话下由 SubAgent 扩展发布的任务快照。
    @Published var subagentTasks: [SubagentTaskSnapshot] = []
    /// 当前在独立查看器中打开的子会话；不会替换主 Runtime。
    @Published var selectedSubagentTask: SubagentTaskSnapshot?

    let services: WorkspaceServices
    let makeTransport: PiTransportFactory
    var transport: (any PiRPCTransport)?
    /// 终止闸门发起的异步 stop；重连必须先等待它完成，避免同一个 Fake/真实
    /// transport 仍处于 running 状态时被立即再次 start。
    var runtimeStopTask: Task<Void, Never>?
    /// 标识当前停止屏障；旧的重连启动意图完成时不得清除更新后的屏障。
    var runtimeStopToken: UUID?
    /// 启动任务与事件消费任务分开持有；否则建立 stream 后覆盖引用，
    /// 重连/关闭时无法取消仍在发送握手命令的旧启动任务。
    var runtimeStartTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    /// Runtime 退出前收到的 stderr 摘要；只在内存中保留有界文本，供终止错误展示。
    var runtimeDiagnostic: String?
    var monitorTask: Task<Void, Never>?
    var monitor: (any WorkspaceFileMonitor)?
    var workspaceLoadTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    /// 即使 detached 读取任务不响应取消，也不能让同一 URL 的旧结果覆盖新预览。
    var previewRequestID = UUID()
    /// Agent 与直接 bash 可以并行；`activity` 是两者合成后的展示值。
    var agentActivity: AgentActivity?
    var bashActivityActive = false
    var streamFlushTask: Task<Void, Never>?
    var treeRefreshTask: Task<Void, Never>?
    var historyMappingTask: Task<Void, Never>?
    var historyMappingRequestID = UUID()
    var restoreTimeoutTask: Task<Void, Never>?
    var abortTimeoutTask: Task<Void, Never>?
    /// `message_end` 先于 `agent_settled` 到达时，暂时阻止开启下一回合。
    var runSettlementTimeoutTask: Task<Void, Never>?
    var pendingTreeRefreshDirectories: Set<URL> = []
    var pendingAssistantText = ""
    var pendingThinkingText = ""
    /// 当前普通 Prompt 的附件快照；发送失败或 Runtime 断开时恢复到 Composer。
    var activePromptAttachments: [WorkPiAttachment] = []
    /// 从本地队列取出、但尚未得到 Runtime 接受确认的任务。
    var activeQueuedPrompt: WorkPiQueuedPrompt?
    var generation = UUID()
    /// Pi 的事件没有独立的回合 id；WorkPi 用本地 token 保护异步超时和收束任务。
    var activeAgentRunID: UUID?
    /// 新回合是否已经收到 `agent_start`；quarantine 解除后的迟到 settled
    /// 在该标记建立前不能结算新回合。
    var activeAgentRunStarted = false
    /// quarantine 解除后，等待真实新回合启动事件期间忽略重复 settled。
    var ignoreSettledUntilAgentStart = false
    /// 最近一个已明确取消的 Agent run；在新 run 开始前可用于解释紧随其后的
    /// Runtime 退出，但不会参与独立 Bash 的终态判定。
    var cancelledAgentRunID: UUID?
    var abortRequestedRunID: UUID?
    var runSettlementPending = false
    /// settlement 超时后，Runtime 内可能仍有一条迟到的旧 settled；在它被
    /// 消费或 Runtime 重启前禁止开启新 Agent run。
    var runtimeSettlementQuarantined = false
    var currentAssistantItemID: UUID?
    var currentThinkingItemID: UUID?
    var toolItemIDs: [String: UUID] = [:]
    var activePromptCommandID: String?
    /// 防止无 id 的重复 prompt response 走兼容 fallback，误收束已接受回合。
    var activePromptResponseAccepted = false
    var activeAbortCommandItemID: UUID?
    var activeAbortCommandID: String?
    /// 只有用户明确中止 Bash 时，Runtime 终止才把该 Bash 标为 cancelled。
    var bashAbortRequested = false
    var activeBashAbortCommandID: String?
    /// 已发送的 Extension/Skill/Prompt 命令与其可见命令活动项的关联。
    var activeCommandItemIDs: [String: UUID] = [:]
    var activeCommandSources: [String: String] = [:]
    var commandStartedWhileBusy: [String: Bool] = [:]
    var activeCompactCommandItemID: UUID?
    var activeCompactRPCID: String?
    var preservedConversationItemForRestore: ConversationItem?
    /// `runOutcome` 与 `phase` 分离：前者记录本回合终态，后者记录 Runtime 阶段。
    var abortRequested = false
    /// 防止迟到的 `agent_settled`/事件重新打开已经收束的回合。
    var runSettlementHandled = false
    /// EOF、传输错误和 processExited 只允许其中一条路径收束一次。
    var runtimeTerminationHandled = false
    var runtimeReady = false
    var receivedStateResponse = false
    var receivedStatsResponse = false
    var receivedMessagesResponse = false
    var expectsMessagesResponse = false
    var processExitObserved = false
    var terminalRunStatus: ConversationItem.Status?
    var pendingDirectoryLoads: Set<URL> = []
    var queuedExtensionUIRequests: [PiExtensionUIRequest] = []
    var extensionUIRequestEnqueueDates: [String: Date] = [:]
    var completedExtensionUIRequestIDs: Set<String> = []
    var completedExtensionUIRequestOrder: [String] = []
    /// 丢弃迟到或乱序的 SubAgent 面板更新。
    var subagentPanelSequence: Int64 = -1
    var extensionUIResponseInFlight = false
    /// Prevents a late response-send completion from clearing the flag for a
    /// newer response operation after reconnect or session replacement.
    var extensionUIResponseOperationID = UUID()
    var extensionUITimeoutTask: Task<Void, Never>?
    /// A response write is part of the Runtime stop/rebuild barrier.  It is
    /// intentionally kept separate from the sheet state: the sheet can close
    /// before the JSONL write has reached Pi.
    /// Independent identity for a Session rebuild within one Runtime generation.
    var sessionEpoch = UUID()
    var sessionRebuildTask: Task<Void, Never>?
    var commandsRequestInFlight = false
    var activeCommandsRequestID: String?
    var availableModelsRequestInFlight = false
    var thinkingLevelsRequestInFlight = false
    var activeModelCommandID: String?
    var activeThinkingLevelCommandID: String?
    var activeAvailableModelsCommandID: String?
    var activeAvailableThinkingLevelsCommandID: String?
    var sessionListLoadTask: Task<Void, Never>?
    var activeSessionCommandID: String?
    var activeForkCommandID: String?
    var activeCloneCommandID: String?
    var activeRenameCommandID: String?
    /// 切换/fork/clone 后正在等待 state、stats、messages 重建。
    var sessionRebuildInFlight = false
    /// 当前 generation 内所有带 id RPC 请求的登记表与超时任务。
    var runtimeRequests: [String: WorkPiRuntimeRequest] = [:]
    /// 保留已登记命令的 Session epoch，供尚未完成的 transport.send 任务
    /// 在同一 Runtime generation 内拒绝旧会话命令。键是本地不可变 ticket，
    /// 不依赖可复用的 wire RPC id。
    var runtimeRequestSessionEpochs: [UUID: UUID] = [:]
    var runtimeRequestTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// 同一 generation 中某命令发生超时后，拒绝其后续无 id 响应；否则迟到的
    /// 旧响应可能被误配给用户重试创建的新请求。
    var idlessResponseQuarantine: Set<String> = []
    /// 被取消或超时的带 id 请求的墓碑；防止旧的有 id 响应触发兼容 fallback。
    var retiredRuntimeRequestIDs: Set<String> = []
    /// 同一代复用 RPC id 后，响应无法区分新旧请求；在新请求结束前全部拒绝。
    var ambiguousRuntimeRequestIDs: Set<String> = []

    var hasUnsentComposerInput: Bool {
        !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !queuedPrompts.isEmpty
            || !pendingAttachments.isEmpty
            || !activePromptAttachments.isEmpty
            || activeQueuedPrompt != nil
    }

    /// 当前 Markdown 差异审阅/保存切换任务；同一 Session 内串行，避免快速点击
    /// A.md → B.md → C.md 时多个保存同时操作同一编辑器。
    var markdownTransitionTask: Task<Void, Never>?
    var markdownTransitionRequestID = UUID()

    /// 当前文件的旧单文件兼容入口；真正的协作状态由按 URL 的集合维护。
    var approvedInspectorChange: WorkPiMarkdownApprovedChange? {
        get {
            guard let url = markdownEditor.document?.url.standardizedFileURL else { return nil }
            return approvedMarkdownChanges[url]
        }
        set {
            guard let url = newValue?.context.snapshot.url.standardizedFileURL
                ?? markdownEditor.document?.url.standardizedFileURL
            else { return }
            if let newValue {
                approvedMarkdownChanges[url] = newValue
            } else {
                approvedMarkdownChanges.removeValue(forKey: url)
            }
        }
    }

    /// 当前回合可能同时发送多个文件差异；旧调用方读取第一个兼容值。
    var activePromptMarkdownChanges: [WorkPiMarkdownDiffContext] = []
    var activePromptInspectorChange: WorkPiMarkdownDiffContext? {
        get { activePromptMarkdownChanges.first }
        set { activePromptMarkdownChanges = newValue.map { [$0] } ?? [] }
    }

    /// Prompt 组装器读取的 Inspector 变更入口；只有用户确认后才会被消费。
    var pendingInspectorChangeSnapshot: WorkPiMarkdownChangeSnapshot? {
        currentMarkdownSnapshot()
    }

    /// 兼容旧调用方：确认当前完整协作快照。
    func acknowledgePendingInspectorChange() {
        markdownEditor.acknowledgePendingCollaboration()
    }

    var markdownDiffBuildTask: Task<Void, Never>?
    var markdownDiffCancellationToken: WorkPiMarkdownDiffCancellationToken?
    var markdownDiffBuildURL: URL?
    var markdownDiffBuildToken = UUID()
    var markdownEditorCancellable: AnyCancellable?
    var markdownApprovalReconcileScheduled = false
    /// 当前 Session 签发过的 Markdown 确认票据及其内容指纹；仅“非 nil”不足以证明来源。
    var issuedMarkdownApprovalTokens: [UUID: WorkPiMarkdownApprovalFingerprint] = [:]

    /// 显示 Inspector 即将浮起的短暂视觉提示。
    func showInspectorLiftHint() {
        guard selectedFileURL != nil else { return }
        inspectorLiftHint = true
    }

    /// 结束 Inspector 浮起提示。
    func hideInspectorLiftHint() {
        inspectorLiftHint = false
    }

    /// 将 Inspector 从主工作区分离。没有选中文件时保持 attached，避免出现空窗口。
    func detachInspector() {
        guard selectedFileURL != nil else { return }
        inspectorDetached = true
    }

    /// 将 Inspector 重新挂回主工作区；不关闭当前文件，也不触发保存闸门。
    func reattachInspector() {
        inspectorDetached = false
    }

    init(
        services: WorkspaceServices = WorkspaceServices(),
        makeTransport: @escaping PiTransportFactory = { mode in
            makeDefaultPiTransport(for: mode)
        }
    ) {
        self.services = services
        self.makeTransport = makeTransport
        markdownEditorCancellable = markdownEditor.objectWillChange.sink { [weak self] _ in
            self?.scheduleMarkdownApprovalReconciliation()
        }
    }

    /// 兼容 0.1 早期测试和调用方的无参数注入形式；继续会话时仍使用同一个
    /// transport，由调用方自行决定是否根据启动模式改变实现。
    convenience init(
        services: WorkspaceServices = WorkspaceServices(),
        makeTransport: @escaping @Sendable () -> any PiRPCTransport
    ) {
        self.init(services: services, makeTransport: { _ in makeTransport() })
    }

    deinit {
        workspaceLoadTask?.cancel()
        previewTask?.cancel()
        runtimeStopTask?.cancel()
        runtimeStartTask?.cancel()
        eventTask?.cancel()
        monitorTask?.cancel()
        streamFlushTask?.cancel()
        treeRefreshTask?.cancel()
        historyMappingTask?.cancel()
        restoreTimeoutTask?.cancel()
        abortTimeoutTask?.cancel()
        runSettlementTimeoutTask?.cancel()
        extensionUITimeoutTask?.cancel()
        sessionRebuildTask?.cancel()
        markdownDiffCancellationToken?.cancel()
        markdownDiffBuildTask?.cancel()
        markdownTransitionTask?.cancel()
        for task in runtimeRequestTimeoutTasks.values { task.cancel() }
        monitor?.stop()
    }

    @discardableResult
    func closeWorkspace() -> Bool {
        // 兼容同步调用方；应用退出和文件切换使用下面的 async 入口，避免
        // 在主线程同步等待磁盘保存。
        guard markdownEditor.close() else {
            handleMarkdownCloseFailure()
            return false
        }
        guard !hasPendingMarkdownCollaborationChanges else {
            handleMarkdownCloseFailure()
            return false
        }
        markdownCollaborationCloseBlocked = false
        guard !hasUnsentComposerInput else {
            composerCloseBlocked = true
            lastError = "Composer 中还有未发送的草稿、排队任务或附件；请先发送，或显式丢弃。"
            return false
        }
        return finishCloseWorkspace()
    }

    /// 应用退出、标签关闭和项目切换使用的异步关闭闸门。保存结束前不清理
    /// Runtime/Inspector 状态，保存失败或冲突时保留整个工作区。
    @discardableResult
    func closeWorkspaceAsync() async -> Bool {
        guard await markdownEditor.close() else {
            handleMarkdownCloseFailure()
            return false
        }
        guard !hasPendingMarkdownCollaborationChanges else {
            handleMarkdownCloseFailure()
            return false
        }
        markdownCollaborationCloseBlocked = false
        guard !hasUnsentComposerInput else {
            composerCloseBlocked = true
            lastError = "Composer 中还有未发送的草稿、排队任务或附件；请先发送，或显式丢弃。"
            return false
        }
        return finishCloseWorkspace()
    }

    @discardableResult
    private func finishCloseWorkspace() -> Bool {
        resetMarkdownCollaborationIntent()

        let oldTransport = transport
        let pendingRuntimeStopTask = runtimeStopTask
        let pendingRuntimeStartTask = runtimeStartTask
        let pendingExtensionRequestIDs = drainPendingExtensionUIRequests()
        cancelAllRuntimeRequests()
        generation = UUID()
        idlessResponseQuarantine.removeAll()
        retiredRuntimeRequestIDs.removeAll()
        ambiguousRuntimeRequestIDs.removeAll()
        runtimeRequestSessionEpochs.removeAll()
        workspaceLoadTask?.cancel()
        workspaceLoadTask = nil
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = UUID()
        streamFlushTask?.cancel()
        streamFlushTask = nil
        treeRefreshTask?.cancel()
        treeRefreshTask = nil
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        runtimeStartTask?.cancel()
        runtimeStartTask = nil
        sessionRebuildTask?.cancel()
        sessionRebuildTask = nil
        eventTask?.cancel()
        eventTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        monitor?.stop()
        monitor = nil
        pendingTreeRefreshDirectories.removeAll()
        pendingAssistantText = ""
        pendingThinkingText = ""
        activePromptAttachments.removeAll()
        activeQueuedPrompt = nil
        pendingDirectoryLoads.removeAll()

        _ = scheduleRuntimeStop(
            pending: pendingRuntimeStopTask,
            transport: oldTransport,
            startTask: pendingRuntimeStartTask,
            extensionRequestIDs: pendingExtensionRequestIDs
        )
        transport = nil
        workspace = nil
        fileTree = nil
        projectAuthorizationState = .notRequired
        piCommands.removeAll()
        selectedFileURL = nil
        selectedPreview = nil
        previewError = nil
        inspectorDetached = false
        inspectorLiftHint = false
        conversation = []
        conversationScrollTarget = nil
        phase = .idle
        runtimeStatus = "未打开项目"
        resetActivityState()
        activityStartedAt = Date()
        queuedPrompts.removeAll()
        revokeUnusedMarkdownApprovalTokens()
        bashExecutions.removeAll()
        pendingAttachments.removeAll()
        sessionStats = nil
        directoryToReveal = nil
        draftPrompt = ""
        sessionSummaries.removeAll()
        sessionTurns.removeAll()
        activeSessionFilePath = nil
        activeSessionName = nil
        sessionListLoadTask?.cancel()
        sessionListLoadTask = nil
        runtimeMetadata = AgentRuntimeMetadata()
        runtimeDiagnostic = nil
        recentSessionRestoreState = .available
        lastError = nil
        runtimeNotice = nil
        runtimeAuthenticationChanged = false
        runtimeProvisioningRequired = false
        composerCloseBlocked = false
        currentAssistantItemID = nil
        currentThinkingItemID = nil
        toolItemIDs.removeAll()
        activePromptCommandID = nil
        activePromptResponseAccepted = false
        activePromptInspectorChange = nil
        activeAbortCommandItemID = nil
        activeAbortCommandID = nil
        abortRequestedRunID = nil
        cancelledAgentRunID = nil
        activeAgentRunID = nil
        activeAgentRunStarted = false
        runSettlementPending = false
        runtimeSettlementQuarantined = false
        ignoreSettledUntilAgentStart = false
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        bashAbortRequested = false
        activeBashAbortCommandID = nil
        activeCommandItemIDs.removeAll()
        activeCommandSources.removeAll()
        commandStartedWhileBusy.removeAll()
        activeCompactCommandItemID = nil
        activeCompactRPCID = nil
        activeExportCommandID = nil
        activeAutoCompactionCommandID = nil
        activeStatsCommandID = nil
        activeStatsRequestIDs.removeAll()
        statsRequestItemIDs.removeAll()
        statsCommandItemID = nil
        activeSessionCommandID = nil
        activeForkCommandID = nil
        activeCloneCommandID = nil
        activeRenameCommandID = nil
        pendingTurnLocation = nil
        preservedConversationItemForRestore = nil
        runOutcome = .completed
        runSettlementHandled = false
        abortRequested = false
        sessionRebuildInFlight = false
        runtimeTerminationHandled = false
        runtimeReady = false
        receivedStateResponse = false
        receivedStatsResponse = false
        receivedMessagesResponse = false
        expectsMessagesResponse = false
        processExitObserved = false
        terminalRunStatus = nil
        extensionNotifications.removeAll()
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        resetSubagentPanelState()
        // Do not clear extensionUIResponseInFlight here: closeWorkspace has
        // already scheduled the stop barrier, which must wait for its write.
        completedExtensionUIRequestIDs.removeAll()
        completedExtensionUIRequestOrder.removeAll()
        commandsRequestInFlight = false
        activeCommandsRequestID = nil
        resetModelControlState()
        return true
    }

    /// 用户明确确认丢弃尚未发送的 Composer 内容后，关闭闸门才会放行。
    func discardComposerInput() {
        queuedPrompts.removeAll()
        pendingAttachments.removeAll()
        activePromptAttachments.removeAll()
        activeQueuedPrompt = nil
        revokeUnusedMarkdownApprovalTokens()
        draftPrompt = ""
        composerCloseBlocked = false
        lastError = nil
        clearRuntimeNotice()
    }

    /// 切 Runtime 或切项目时丢弃旧的模型目录；列表与级别都属于具体 Runtime。
    func resetModelControlState() {
        availableModels.removeAll()
        availableThinkingLevels.removeAll()
        availableModelsRequestInFlight = false
        thinkingLevelsRequestInFlight = false
        modelSwitchInFlight = false
        thinkingLevelSwitchInFlight = false
        activeModelCommandID = nil
        activeThinkingLevelCommandID = nil
        activeAvailableModelsCommandID = nil
        activeAvailableThinkingLevelsCommandID = nil
    }

    /// 用户明确允许当前项目加载本地 Extension/配置后启动 Runtime。
    func approveProjectAuthorization(remember: Bool = false) {
        guard let workspace,
              projectAuthorizationState == .needsDecision || projectAuthorizationState == .denied
        else { return }

        if remember {
            WorkPiProjectAuthorization.remember(workspace.rootURL)
        }
        projectAuthorizationState = .approved
        lastError = nil
        runtimeNotice = nil
        runtimeStatus = "正在启动已授权的 Pi Runtime…"
        guard fileTree != nil else { return }
        restartRuntime(
            for: workspace.rootURL,
            launchMode: .freshApproved
        )
    }

    /// 拒绝当前项目的本地资源；不修改 Pi 全局 trust.json。
    func denyProjectAuthorization() {
        guard projectAuthorizationState == .needsDecision || projectAuthorizationState == .denied else { return }
        stopRuntimeForAuthorization()
        projectAuthorizationState = .denied
        runtimeReady = false
        runtimeProvisioningRequired = false
        phase = .failed
        runtimeStatus = "项目未授权，扩展未加载"
        lastError = "当前项目包含本地 Extension 或配置；未授权时 Pura Pi 不会加载它们。"
    }

    func requestProjectAuthorization() {
        guard WorkPiProjectAuthorization.requiresAuthorization(for: workspace?.rootURL ?? URL(fileURLWithPath: "/")) else {
            return
        }
        stopRuntimeForAuthorization()
        projectAuthorizationState = .needsDecision
        runtimeReady = false
        phase = .failed
        runtimeStatus = "等待项目授权…"
        lastError = nil
    }

    /// 停止当前 Runtime，但保留工作区、目录树和文件监视器，供授权决定继续使用。
    private func stopRuntimeForAuthorization() {
        let oldTransport = transport
        let pendingRuntimeStopTask = runtimeStopTask
        let pendingRuntimeStartTask = runtimeStartTask
        let pendingRequestIDs = drainPendingExtensionUIRequests()
        cancelAllRuntimeRequests()
        let hasRuntimeLifecycle = oldTransport != nil
            || pendingRuntimeStopTask != nil
            || runtimeStartTask != nil
            || eventTask != nil
            || runtimeReady
        let workspaceURL = workspace?.rootURL

        if hasRuntimeLifecycle {
            generation = UUID()
            idlessResponseQuarantine.removeAll()
            retiredRuntimeRequestIDs.removeAll()
            ambiguousRuntimeRequestIDs.removeAll()
            runtimeRequestSessionEpochs.removeAll()
            runtimeStartTask?.cancel()
            runtimeStartTask = nil
            sessionRebuildTask?.cancel()
            sessionRebuildTask = nil
            eventTask?.cancel()
            eventTask = nil
            streamFlushTask?.cancel()
            streamFlushTask = nil
            historyMappingTask?.cancel()
            historyMappingTask = nil
            historyMappingRequestID = UUID()
            restoreTimeoutTask?.cancel()
            restoreTimeoutTask = nil
            transport = nil

            monitorTask?.cancel()
            monitorTask = nil
            monitor?.stop()
            monitor = nil
            if let workspaceURL {
                startFileMonitor(for: workspaceURL, generation: generation)
            }
        }

        // 授权切换也可能发生在旧 Runtime 尚有未完成输出时；先保留未确认
        // Prompt 的附件，再把可见项收束，不能留下永远转圈的 Assistant 或命令块。
        restoreActivePromptAttachments()
        let queuedPromptForAuthorization = activeQueuedPrompt
        flushStreamingBuffers()
        finalizeCurrentItemsAfterSettled(
            wasCancelled: true,
            failed: false
        )
        pendingAssistantText = ""
        pendingThinkingText = ""
        if let queuedPromptForAuthorization {
            if !queuedPrompts.contains(where: { $0.id == queuedPromptForAuthorization.id }) {
                queuedPrompts.insert(queuedPromptForAuthorization, at: 0)
            }
            for context in queuedPromptForAuthorization.inspectorChanges {
                if let token = context.approvalToken {
                    // finalizeCurrentItemsAfterSettled 会先清理发送中票据；这里把
                    // 明确保留的授权快照重新登记，供重连后派发。
                    issuedMarkdownApprovalTokens[token] = context.approvalFingerprint
                }
            }
        }
        activeQueuedPrompt = nil
        activePromptCommandID = nil
        activePromptResponseAccepted = false
        discardActiveMarkdownDiff()
        runtimeReady = false
        runtimeProvisioningRequired = false
        resetActivityState()
        runSettlementHandled = true
        runtimeTerminationHandled = true
        runtimeDiagnostic = nil
        for index in bashExecutions.indices where bashExecutions[index].isRunning {
            bashExecutions[index].state = .cancelled
        }
        activeBashAbortCommandID = nil
        bashAbortRequested = false
        runSettlementPending = false
        runtimeSettlementQuarantined = false
        ignoreSettledUntilAgentStart = false
        activeAgentRunID = nil
        activeAgentRunStarted = false
        cancelledAgentRunID = nil
        abortRequestedRunID = nil
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        sessionRebuildInFlight = false
        runtimeNotice = nil
        commandsRequestInFlight = false
        activeCommandsRequestID = nil
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil
        activeAbortCommandItemID = nil
        activeAbortCommandID = nil
        activeCommandItemIDs.removeAll()
        activeCommandSources.removeAll()
        commandStartedWhileBusy.removeAll()
        activeCompactCommandItemID = nil
        activeCompactRPCID = nil
        activeExportCommandID = nil
        activeAutoCompactionCommandID = nil
        activeStatsCommandID = nil
        activeStatsRequestIDs.removeAll()
        statsRequestItemIDs.removeAll()
        statsCommandItemID = nil
        activeSessionCommandID = nil
        activeForkCommandID = nil
        activeCloneCommandID = nil
        activeRenameCommandID = nil
        preservedConversationItemForRestore = nil
        terminalRunStatus = nil
        runOutcome = .completed
        abortRequested = false
        processExitObserved = false
        piCommands.removeAll()
        sessionStats = nil
        resetModelControlState()
        extensionNotifications.removeAll()
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        resetSubagentPanelState()
        completedExtensionUIRequestIDs.removeAll()
        completedExtensionUIRequestOrder.removeAll()
        _ = scheduleRuntimeStop(
            pending: pendingRuntimeStopTask,
            transport: oldTransport,
            startTask: pendingRuntimeStartTask,
            extensionRequestIDs: pendingRequestIDs
        )
    }
}
