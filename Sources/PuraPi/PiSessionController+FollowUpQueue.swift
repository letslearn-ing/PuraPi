import Foundation
import PiRPC

/// 待执行任务队列。
///
/// Agent 忙时用户按下 Return，任务进入这个队列，等当前回合结束后自动发出。
///
/// 队列由 PuraPi 维护，而不是立刻发 Pi 的 `follow_up`：Pi 的 RPC 接口没有
/// 撤回单条排队消息的命令（TUI 能取消是因为它在同进程内直接调用
/// `session.clearQueue()`，RPC 没有暴露）。要支持用户点击取消，就必须在本地
/// 暂存，到时机成熟再作为普通 `prompt` 发出。
extension PiSessionController {
    /// 当前是否处于「Agent 正在忙」的状态。
    ///
    /// 只有忙的时候才排队；空闲时应当直接发送，不要让用户多等一个回合。
    var isAgentBusy: Bool {
        if runSettlementPending
            || runtimeSettlementQuarantined
            || sessionRebuildInFlight
            || sessionOperationInFlight {
            return true
        }
        switch phase {
        case .preparing, .requesting, .streaming, .executingTool, .settling, .cancelled:
            return true
        case .idle, .failed:
            return false
        }
    }

    /// 把一条任务排入队列。
    ///
    /// 调用方需保证已经处于忙状态；空闲时请走 `submitPrompt`。
    /// 附件必须由调用方在排队瞬间传入，避免之后的 Composer 状态串入这条任务。
    @discardableResult
    func enqueueFollowUp(
        _ text: String,
        attachments: [PuraPiAttachment] = [],
        inspectorChange: PuraPiMarkdownDiffContext? = nil,
        inspectorChanges: [PuraPiMarkdownDiffContext]? = nil
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let changes = inspectorChanges ?? inspectorChange.map { [$0] } ?? []
        for change in changes {
            guard let token = change.approvalToken,
                  issuedMarkdownApprovalTokens[token] == change.approvalFingerprint
            else {
                lastError = "Markdown 差异尚未经过当前确认流程，不能排队发送。"
                return nil
            }
        }
        let queuedBytes = queuedPrompts.reduce(0) { total, item in
            total
                + item.attachments.reduce(0) { $0 + $1.estimatedMemoryByteCount }
                + item.inspectorChangeMemoryByteCount
        }
        let activeBytes = activeQueuedPrompt.map {
            $0.attachments.reduce(0) { $0 + $1.estimatedMemoryByteCount }
                + $0.inspectorChangeMemoryByteCount
        } ?? 0
        let existingBytes = queuedBytes + activeBytes
        let newBytes = attachments.reduce(0) { $0 + $1.estimatedMemoryByteCount }
            + changes.reduce(0) { $0 + $1.estimatedMemoryByteCount }
        guard existingBytes + newBytes <= PiSessionController.maximumQueuedAttachmentBytes else {
            lastError = "排队内容（附件和 Markdown 快照）预计占用超过 128 MB，任务未加入队列。"
            return nil
        }

        let item = PuraPiQueuedPrompt(
            text: trimmed,
            attachments: attachments,
            inspectorChanges: changes
        )
        queuedPrompts.append(item)
        draftPrompt = ""
        lastError = nil
        return item.id
    }

    /// 取消一条尚未发出的任务。
    ///
    /// 只能取消仍在本地队列里的条目；已经交给 Pi 的任务无法撤回。
    func cancelQueuedPrompt(_ id: UUID) {
        queuedPrompts.removeAll { $0.id == id }
        revokeUnusedMarkdownApprovalTokens()
    }

    func cancelAllQueuedPrompts() {
        queuedPrompts.removeAll()
        revokeUnusedMarkdownApprovalTokens()
    }

    /// 回合结束后取出下一条任务并发送。
    ///
    /// 每次只发一条，与 Pi `one-at-a-time` 的默认语义一致：下一条要等这条
    /// 也跑完。用户取消当前回合时不继续队列，避免「停不下来」。
    func dispatchNextQueuedPromptIfNeeded() {
        guard !queuedPrompts.isEmpty else { return }
        guard runtimeReady, transport != nil else {
            // Runtime 已不可用：保留队列内容并说明原因，不静默丢弃用户输入。
            lastError = "Pi Runtime 不可用，排队的任务未发送。"
            return
        }
        guard runOutcome != .cancelled, !abortRequested else {
            // 用户刚刚停止了 Agent；此时自动继续会违背停止意图。
            return
        }
        guard !isAgentBusy else { return }
        guard !runtimeAuthenticationChanged else {
            runtimeNotice = "Pi 认证已更新；重新连接 Runtime 后才会派发排队任务。"
            return
        }

        let next = queuedPrompts.removeFirst()
        if !submitPrompt(next) {
            // 状态在取出后发生竞态时保留整条快照；尤其不能丢失已确认的
            // Markdown 差异或排队时冻结的附件。
            queuedPrompts.insert(next, at: 0)
        }
    }
}

/// 队列中的一条待执行任务。
struct PuraPiQueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    /// 排队时已经读入内存的附件快照；不能等到 dispatch 时重新读取当前输入框。
    let attachments: [PuraPiAttachment]
    /// 用户确认后冻结的 Markdown 差异；排队时不能读取未来的编辑内容。
    let inspectorChanges: [PuraPiMarkdownDiffContext]

    init(
        id: UUID = UUID(),
        text: String,
        attachments: [PuraPiAttachment] = [],
        inspectorChange: PuraPiMarkdownDiffContext? = nil,
        inspectorChanges: [PuraPiMarkdownDiffContext]? = nil
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.inspectorChanges = inspectorChanges
            ?? inspectorChange.map { [$0] }
            ?? []
    }

    /// 兼容单文件调用方和旧测试；新的发送路径使用 inspectorChanges。
    var inspectorChange: PuraPiMarkdownDiffContext? {
        inspectorChanges.first
    }

    var inspectorChangeByteCount: Int {
        inspectorChanges.reduce(0) { $0 + $1.byteCount }
    }

    var inspectorChangeMemoryByteCount: Int {
        inspectorChanges.reduce(0) { $0 + $1.estimatedMemoryByteCount }
    }

    var attachmentNames: [String] {
        attachments.map(\.displayName)
    }
}
