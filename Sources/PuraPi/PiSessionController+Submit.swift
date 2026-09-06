import AppKit
import Foundation
import PiDomain
import PiRPC
import WorkspaceKit

/// 提交入口：普通提问、斜杠命令、shell 命令与 Pi 发现的命令。
///
/// 从 `PiSessionController.swift` 拆出（该文件曾到 812 行触发 800 预警）。
/// 这里集中处理「用户按下发送后走哪条路」的分流逻辑。
extension PiSessionController {
    func submitPrompt() {
        let text = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !sessionRebuildInFlight else {
            // 保留 draftPrompt/附件在 Composer，不把它们塞进将被替换的会话队列。
            lastError = "会话正在重新加载，输入已保留；请稍候再发送。"
            return
        }
        guard !sessionOperationInFlight else {
            lastError = "会话操作正在等待 Pi 确认，输入已保留；请稍候再发送。"
            return
        }
        guard phase != .cancelled else {
            lastError = "Agent 正在停止，输入已保留；请稍候再发送。"
            return
        }
        if runtimeAuthenticationChanged,
           !canSubmitWhileAuthenticationChanged(text) {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；当前输入已保留。"
            return
        }

        // Agent 正在工作时，普通任务排入待执行队列，而不是静默丢弃。
        // 命令（斜杠开头）仍然立即执行：/abort、/trust 这类动作的意义
        // 就在于当下生效，排队会让它们失去作用。
        // shell 命令不占用 Agent 回合，忙时也能直接执行，不该排队。
        if isAgentBusy,
           PuraPiCommandCatalog.slashQuery(for: text) == nil,
           PuraPiCommandCatalog.shellCommand(for: text) == nil {
            let inspectorChanges: [PuraPiMarkdownDiffContext]
            switch markdownChangeForNextPrompt() {
            case .none:
                inspectorChanges = []
            case .ready(let contexts):
                inspectorChanges = contexts
            case .needsReview:
                return
            }
            // 必须在进入队列的瞬间复制附件和多个 Markdown 差异；否则它们会读取到
            // 用户等待期间的后续输入，或在排队时悄悄丢失。
            if enqueueFollowUp(
                text,
                attachments: pendingAttachments,
                inspectorChanges: inspectorChanges
            ) != nil {
                clearAttachments()
                if !inspectorChanges.isEmpty {
                    consumeApprovedMarkdownDiff(for: inspectorChanges)
                }
            }
            return
        }

        submitPromptText(text)
    }

    /// 重试一条消息：原样重新发送。
    ///
    /// 走 `submitPrompt(_:)` 而不是直接 `submitPromptText`，这样 Agent 忙时
    /// 会进入既有的排队逻辑，不会被静默丢弃。
    func retryMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !sessionOperationInFlight else {
            lastError = "会话操作正在等待 Pi 确认，重试未发送。"
            return
        }
        guard !runtimeAuthenticationChanged || canSubmitWhileAuthenticationChanged(trimmed) else {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；重试内容已保留。"
            return
        }
        if isAgentBusy {
            let inspectorChanges: [PuraPiMarkdownDiffContext]
            switch markdownChangeForNextPrompt() {
            case .none:
                inspectorChanges = []
            case .ready(let contexts):
                inspectorChanges = contexts
            case .needsReview:
                return
            }
            if enqueueFollowUp(trimmed, inspectorChanges: inspectorChanges) != nil,
               !inspectorChanges.isEmpty {
                consumeApprovedMarkdownDiff(for: inspectorChanges)
            }
            return
        }
        submitPromptText(trimmed)
    }

    /// 队列调度与命令确认共用的直接发送入口。
    func submitPrompt(_ text: String) {
        submitPromptText(text)
    }

    /// 发送本地队列取出的快照，不读取当前 Composer 的附件或 Markdown 内容。
    @discardableResult
    func submitPrompt(_ queuedPrompt: PuraPiQueuedPrompt) -> Bool {
        submitPromptText(
            queuedPrompt.text,
            attachments: queuedPrompt.attachments,
            queuedPromptID: queuedPrompt.id,
            explicitInspectorChanges: queuedPrompt.inspectorChanges
        )
    }

    /// Return 确认命令时直接执行，不要求用户再按一次发送按钮。
    func submitCommand(_ text: String) {
        submitPromptText(text)
    }

    @discardableResult
    func submitPromptText(
        _ rawText: String,
        attachments explicitAttachments: [PuraPiAttachment]? = nil,
        queuedPromptID: UUID? = nil,
        inspectorChange explicitInspectorChange: PuraPiMarkdownDiffContext? = nil,
        explicitInspectorChanges: [PuraPiMarkdownDiffContext]? = nil
    ) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !sessionRebuildInFlight else {
            lastError = "会话正在重新加载，命令暂时未发送。"
            return false
        }
        guard !sessionOperationInFlight else {
            lastError = "会话操作正在等待 Pi 确认，命令暂时未发送。"
            return false
        }
        guard !runtimeSettlementQuarantined else {
            lastError = "上一回合收束超时；请先重新连接 Runtime。"
            return false
        }
        guard phase != .cancelled else {
            lastError = "Agent 正在停止，命令暂时未发送。"
            return false
        }

        // `!cmd` 直接执行 shell，不发给模型。
        if let shellCommand = PuraPiCommandCatalog.shellCommand(for: text) {
            if runBashCommand(shellCommand) {
                draftPrompt = ""
                return true
            }
            return false
        }

        guard !runtimeAuthenticationChanged || canSubmitWhileAuthenticationChanged(text) else {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；当前输入已保留。"
            return false
        }

        if let action = PuraPiCommandCatalog.action(for: text) {
            draftPrompt = ""
            let itemID = appendCommandActivity(text)
            executePuraPiCommand(action, text: text, commandItemID: itemID)
            return true
        }

        if let discovered = PuraPiCommandCatalog.discoveredCommand(
            for: text,
            piCommands: piCommands
        ) {
            draftPrompt = ""
            submitDiscoveredCommand(text, info: discovered)
            return true
        }

        // 命令目录是异步发现的；用户也可能在 `get_commands` 返回前按下 Return。
        // 只要输入是斜杠命令，就按命令路径发送，而不是静默地受普通 Prompt 门控。
        if let query = PuraPiCommandCatalog.slashQuery(for: text), !query.isEmpty {
            draftPrompt = ""
            submitDiscoveredCommand(
                text,
                info: PiRPCCommandInfo(name: query, source: "unknown")
            )
            return true
        }

        guard !idlessResponseQuarantine.contains("prompt") else {
            lastError = "Pi Runtime 的 Prompt 响应缺少 id；为避免迟到响应污染新回合，请重新连接 Runtime。"
            return false
        }
        guard transport != nil,
              runtimeReady,
              !sessionRebuildInFlight,
              !runSettlementPending,
              phase == .idle || phase == .failed
        else { return false }
        guard let transport else { return false }

        let inspectorChanges: [PuraPiMarkdownDiffContext]
        let explicitChanges = explicitInspectorChanges
            ?? explicitInspectorChange.map { [$0] }
        if let explicitChanges {
            // 只有从已确认队列快照进入的路径才允许传入 explicit context；
            // 普通即时发送必须重新从 approval 状态取得，不接受任意构造的载荷。
            guard queuedPromptID != nil,
                  canSendExplicitMarkdownChanges(
                      explicitChanges,
                      requireCurrentSnapshot: false
                  )
            else {
                return false
            }
            inspectorChanges = explicitChanges
        } else if queuedPromptID != nil {
            // 队列项在入队时已经冻结了“无差异”语义；不能把用户后来
            // 审阅的另一份 Markdown 修改串进这条旧任务。
            inspectorChanges = []
        } else {
            switch markdownChangeForNextPrompt() {
            case .none:
                inspectorChanges = []
            case .ready(let contexts):
                inspectorChanges = contexts
            case .needsReview:
                return false
            }
        }

        draftPrompt = ""
        lastError = nil
        runtimeNotice = nil
        // 附件在这里定型：图片走 prompt.images，文本拼进正文。
        // 从队列 dispatch 时使用快照，不能读取用户此刻新加到 Composer 的附件。
        let outgoingAttachments = explicitAttachments ?? pendingAttachments
        let images = promptImages(from: outgoingAttachments)
        let messageWithAttachments = messageWithTextAttachments(
            text,
            attachments: outgoingAttachments
        )
        let outgoingMessage: String
        if inspectorChanges.isEmpty {
            outgoingMessage = messageWithAttachments
        } else {
            outgoingMessage = inspectorChanges.map(\.promptFragment).joined(separator: "\n\n")
                + "\n\n[User request follows]\n"
                + messageWithAttachments
        }
        let attachmentSummary = outgoingAttachments.map(\.displayName)
        if let queuedPromptID {
            activeQueuedPrompt = PuraPiQueuedPrompt(
                id: queuedPromptID,
                text: text,
                attachments: explicitAttachments ?? [],
                inspectorChanges: inspectorChanges
            )
        } else {
            activeQueuedPrompt = nil
        }
        activePromptMarkdownChanges = inspectorChanges
        if explicitChanges == nil, !inspectorChanges.isEmpty {
            consumeApprovedMarkdownDiff(for: inspectorChanges)
        }
        if explicitAttachments == nil {
            // 先保存快照再清空 Composer；只有 Pi 接受请求后才真正丢弃，
            // 发送失败或 Runtime 断开时由 RuntimeState 恢复。
            activePromptAttachments = outgoingAttachments
            clearAttachments()
        }

        // 对话里显示用户原文加附件名，不显示拼接后的全文：
        // 附件内容可能很长，铺在气泡里会淹没用户实际说的话。
        var userText = text
        if !attachmentSummary.isEmpty {
            userText += "\n\n附件：" + attachmentSummary.joined(separator: "、")
        }
        let userItem = ConversationItem(kind: .user, text: userText)
        let userItemID = userItem.id
        appendConversation(userItem)
        let assistant = ConversationItem(kind: .assistant, text: "", status: .streaming)
        currentAssistantItemID = assistant.id
        appendConversation(assistant)
        currentThinkingItemID = nil
        toolItemIDs.removeAll()
        runOutcome = .running
        abortRequested = false
        abortRequestedRunID = nil
        terminalRunStatus = nil
        pendingAssistantText = ""
        pendingThinkingText = ""
        let runID = beginAgentRun()
        phase = .requesting
        setActivity(.waitingForModel)
        runtimeStatus = "Agent 正在处理…"
        let generation = self.generation
        let command = PiRPCCommand.prompt(outgoingMessage, images: images)
        runSettlementHandled = false
        activePromptCommandID = command.id
        activePromptResponseAccepted = false
        registerRuntimeRequest(
            command,
            purpose: .operation,
            itemID: userItemID,
            queuedPrompt: activeQueuedPrompt,
            timeout: .seconds(120)
        )

        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.sendRuntimeCommand(
                    command,
                    using: transport,
                    generation: generation
                )
            } catch {
                guard let self, self.generation == generation else { return }
                _ = self.settleRuntimeRequest(id: command.id)
                guard self.activePromptCommandID == command.id || queuedPromptID != nil else {
                    return
                }
                if queuedPromptID == nil {
                    self.restoreActivePromptAttachments()
                }
                if queuedPromptID != nil,
                   self.runOutcome != .cancelled,
                   !self.abortRequested {
                    // 队列项已从本地取出，但发送遇到传输竞态；放回队首，
                    // 不让用户的任务、附件和 Markdown 差异无声消失。
                    self.restoreActiveQueuedPrompt()
                }
                self.discardActiveMarkdownDiff()
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                guard !self.runtimeTerminationHandled else { return }
                guard self.activeAgentRunID == runID else { return }
                self.phase = .failed
                self.runtimeStatus = "发送失败"
                self.markCurrentAssistant(status: .failed)
                self.finalizeCurrentItemsAfterSettled(
                    wasCancelled: false,
                    failed: true
                )
                self.setActivity(nil)
                let safeError = PuraPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = safeError
                self.noteAuthenticationFailure(safeError)
            }
        }
        return true
    }

    /// Pi RPC 允许 Extension 命令在 Agent 工作期间立即执行。普通 Prompt 仍由
    /// 上面的 idle/failed 门控保护，避免误把第二条自然语言消息并发发送。
    private func submitDiscoveredCommand(_ text: String, info: PiRPCCommandInfo) {
        guard let transport,
              runtimeReady,
              !sessionRebuildInFlight,
              !runSettlementPending,
              !runtimeSettlementQuarantined,
              phase != .cancelled,
              phase != .settling
        else {
            let detail = isRuntimeTransitioning
                ? "Pi Runtime 正在切换或停止，命令未发送。"
                : "Pi Runtime 尚未连接，命令未发送。"
            let itemID = appendCommandActivity(
                text,
                status: .failed,
                detail: detail
            )
            updateConversation(id: itemID) { item in item.status = .failed }
            return
        }

        // 这是新的 Runtime 命令活动，不能继承上一个 Agent run 的取消终态。
        cancelledAgentRunID = nil
        let itemID = appendCommandActivity(text)
        let command = PiRPCCommand.prompt(text)
        let wasBusy = phase != .idle && phase != .failed
        registerRuntimeRequest(
            command,
            purpose: .operation,
            itemID: itemID,
            timeout: .seconds(120)
        )
        if let commandID = command.id {
            activeCommandItemIDs[commandID] = itemID
            activeCommandSources[commandID] = info.source
            commandStartedWhileBusy[commandID] = wasBusy
        }
        lastError = nil
        // 上一个回合可能已经进入失败/取消终态；新的命令拥有自己的事件窗口。
        runSettlementHandled = false
        terminalRunStatus = nil
        if !wasBusy {
            runOutcome = .completed
            // Extension 命令可能只发出 notify/setStatus，也可能随后启动一轮
            // Agent。不要在尚未收到 `agent_start` 前把空闲 UI 锁成“暂停”。
            runtimeStatus = "正在发送命令…"
        }

        let generation = self.generation
        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.sendRuntimeCommand(
                    command,
                    using: transport,
                    generation: generation
                )
                guard self.generation == generation else { return }
                self.updateConversation(id: itemID) { item in
                    if item.status == .pending { item.status = .streaming }
                }
            } catch {
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                if let commandID = command.id {
                    self.activeCommandItemIDs.removeValue(forKey: commandID)
                    self.activeCommandSources.removeValue(forKey: commandID)
                    self.commandStartedWhileBusy.removeValue(forKey: commandID)
                }
                let safeError = PuraPiSensitiveText.redacted(error.localizedDescription)
                self.updateConversation(id: itemID) { item in
                    item.status = .failed
                    item.detail = "发送失败：\(safeError)"
                }
                self.lastError = safeError
                self.noteAuthenticationFailure(safeError)
                if !wasBusy {
                    self.phase = .failed
                    self.runtimeStatus = "命令发送失败"
                }
            }
        }
    }
}
