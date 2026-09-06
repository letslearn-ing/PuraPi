import Foundation
import PiDomain
import PiRPC

/// Runtime 事件映射使用的对话快照、流式缓冲、HUD 元数据和传输失败辅助逻辑。
///
/// 这里不启动或重启进程；生命周期与回合终态仍由
/// `PiSessionController+Runtime.swift` 统一收敛。
enum PuraPiRuntimeTerminationReason {
    case eof
    case transportError(String)
    case processExited(Int32)
    case processExitedWithDiagnostic(Int32, String)

    var statusText: String {
        switch self {
        case .eof:
            return "Pi Runtime 连接已结束"
        case .transportError:
            return "Pi Runtime 不可用"
        case .processExited(let status), .processExitedWithDiagnostic(let status, _):
            return status == 0
                ? "Pi Runtime 已退出"
                : "Pi Runtime 异常退出（\(status)）"
        }
    }

    var errorMessage: String {
        switch self {
        case .eof:
            return "Pi Runtime 的 RPC 输出已结束。"
        case .transportError(let message):
            return message.isEmpty ? "Pi Runtime 传输失败。" : message
        case .processExited(let status):
            return status == 0
                ? "Pi Runtime 已意外退出。"
                : "Pi Runtime 异常退出，状态码：\(status)。"
        case .processExitedWithDiagnostic(let status, let diagnostic):
            let base = status == 0
                ? "Pi Runtime 已意外退出。"
                : "Pi Runtime 异常退出，状态码：\(status)。"
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? base : "\(base)\nPi 输出：\(trimmed)"
        }
    }
}

extension PiSessionController {
    /// Runtime 正在换代、停止或等待旧回合 settled；此时不能启动会改变
    /// 当前会话上下文的并发操作。
    var isRuntimeTransitioning: Bool {
        phase == .preparing
            || phase == .settling
            || phase == .cancelled
            || runSettlementPending
            || runtimeSettlementQuarantined
            || sessionRebuildInFlight
            || sessionOperationInFlight
    }

    /// 开始一个新的 Agent 回合。Pi 的事件本身没有回合 id，PuraPi 用本地
    /// token 关联超时、Abort 和异步发送任务，避免上一回合的终态污染下一回合。
    @discardableResult
    func beginAgentRun() -> UUID {
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        let runID = UUID()
        activeAgentRunID = runID
        activeAgentRunStarted = false
        // 新回合拥有独立的取消归属，不能继承上一回合的取消结果。
        cancelledAgentRunID = nil
        runSettlementPending = false
        abortRequested = false
        abortRequestedRunID = nil
        terminalRunStatus = nil
        return runID
    }

    /// 发送前从 Composer 取出的附件在请求成功前仍属于用户输入；失败时只把
    /// 原快照放回去，不覆盖用户在等待期间新加入的附件。
    func restoreActivePromptAttachments() {
        guard !activePromptAttachments.isEmpty else { return }
        var restored = activePromptAttachments
        let existingIDs = Set(pendingAttachments.map(\.id))
        restored.removeAll { existingIDs.contains($0.id) }
        pendingAttachments = restored + pendingAttachments
        activePromptAttachments.removeAll()
    }

    func discardActivePromptAttachments() {
        activePromptAttachments.removeAll()
    }

    func restoreActiveQueuedPrompt() {
        guard let queuedPrompt = activeQueuedPrompt else { return }
        if !queuedPrompts.contains(where: { $0.id == queuedPrompt.id }) {
            queuedPrompts.insert(queuedPrompt, at: 0)
        }
        activeQueuedPrompt = nil
    }

    func discardActiveQueuedPrompt() {
        activeQueuedPrompt = nil
    }

    /// 没有显式 Prompt（例如 Extension 触发 Agent）时，在首个 Agent 事件处
    /// 建立回合 token。
    @discardableResult
    func ensureAgentRun() -> UUID {
        activeAgentRunID ?? beginAgentRun()
    }

    /// `message_end`/`agent_end` 可能早于 `agent_settled`。在这段窗口内禁止
    /// 新回合，并提供兜底超时；否则旧的 settled 事件可能结束新回合。
    func markRunAwaitingSettlement() {
        guard let runID = activeAgentRunID, !runSettlementHandled else { return }
        runSettlementPending = true
        scheduleRunSettlementTimeout(for: runID)
    }

    /// `agent_end` 理论上晚于最终 `message_end`，但不同 Pi/provider 版本可能
    /// 反过来发送。仅允许仍处于 running/completed 的当前回合恢复处理；失败
    /// 终态的迟到消息必须继续丢弃。
    func resumeAgentRunForLateMessage() -> Bool {
        guard runSettlementPending,
              (runOutcome == .running || runOutcome == .completed),
              !runSettlementHandled
        else { return !runSettlementPending }
        runSettlementPending = false
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        return true
    }

    func currentAgentRunWasCancelled() -> Bool {
        if let runID = activeAgentRunID {
            return (runOutcome == .cancelled && terminalRunStatus == .cancelled)
                || (abortRequested && abortRequestedRunID == runID)
        }
        // Abort 成功后 `finalizeCurrentItemsAfterSettled` 会清除 active run token；
        // 在下一回合开始前仍保留这次取消，保证随后的进程退出不会改写它。
        return cancelledAgentRunID != nil
            && runOutcome == .cancelled
            && terminalRunStatus == .cancelled
    }

    /// Abort 请求本身失败时也必须走与 EOF/timeout 相同的终态收束路径。
    func finishAbortFailure(message: String) {
        let message = PuraPiSensitiveText.redacted(message)
        let commandItemID = activeAbortCommandItemID
        cancelledAgentRunID = nil
        // Pi 拒绝 abort 不代表远端回合已经停止；在收到 settled 或换代前
        // 不能让用户的下一条 Prompt 与可能仍在运行的旧回合交叉。
        runtimeSettlementQuarantined = true
        abortRequested = false
        abortRequestedRunID = nil
        runOutcome = .failed
        terminalRunStatus = .failed
        phase = .failed
        runtimeStatus = "停止请求失败"
        clearRuntimeNotice()
        lastError = message
        updateConversation(id: commandItemID) { item in
            item.status = .failed
            item.detail = "停止请求失败：\(message)"
        }
        markCurrentAssistant(status: .failed)
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil
        activeAbortCommandID = nil
        activeAbortCommandItemID = nil
        finalizeCurrentItemsAfterSettled(wasCancelled: false, failed: true)
        setActivity(nil)
    }

    func scheduleRunSettlementTimeout(for runID: UUID) {
        runSettlementTimeoutTask?.cancel()
        let generation = self.generation
        runSettlementTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  self.generation == generation,
                  self.activeAgentRunID == runID,
                  self.runSettlementPending,
                  !self.runSettlementHandled
            else { return }

            self.runSettlementTimeoutTask = nil
            self.runSettlementPending = false
            let wasCancelled = self.currentAgentRunWasCancelled()
            // 未收到 settled 不能安全开启队列中的下一回合；把它视为本回合
            // 收束失败，保留队列等待用户重试/重连。
            let failed = !wasCancelled
            if failed {
                self.phase = .failed
                self.runtimeStatus = self.runtimeReady
                    ? "Agent 收束超时"
                    : "Pi Runtime 不可用"
                if self.lastError == nil {
                    self.lastError = "Agent 没有在规定时间内完成收束。"
                }
            } else {
                // 即使本回合是取消，缺少 settled 也意味着 Runtime 协议
                // 仍处于不确定状态；保持 failed 以展示可操作的重连入口。
                self.phase = .failed
                self.runtimeStatus = self.runtimeReady
                    ? "Agent 收束超时"
                    : "Pi Runtime 不可用"
                self.runtimeNotice = "Agent 已停止，但 Runtime 未确认收束。请重新连接。"
            }
            self.finalizeCurrentItemsAfterSettled(
                wasCancelled: wasCancelled,
                failed: failed
            )
            self.runtimeSettlementQuarantined = true
            self.ignoreSettledUntilAgentStart = false
            self.setActivity(nil)
        }
    }

    func finalizeCurrentItemsAfterSettled(wasCancelled: Bool, failed: Bool) {
        // 所有终态入口都必须先发布并清掉待刷新的 delta；否则 Abort 失败或
        // settlement 超时后，迟到的 flush task 仍可能把文字写进下一回合。
        flushStreamingBuffers()
        finishActiveTurnIfNeeded(
            outcome: wasCancelled ? .cancelled : (failed ? .failed : .completed)
        )
        pendingAssistantText.removeAll(keepingCapacity: true)
        pendingThinkingText.removeAll(keepingCapacity: true)

        let commandIDsToKeep: Set<String> = (!failed && !wasCancelled)
            ? Set(activeCommandItemIDs.keys.filter {
                commandStartedWhileBusy[$0] == true
            })
            : []
        let commandItemIDsToFinalize: Set<UUID> = {
            var ids = Set(activeCommandItemIDs.compactMap { commandID, itemID in
                commandIDsToKeep.contains(commandID) ? nil : itemID
            })
            if let activePromptCommandID,
               let promptItemID = runtimeRequests[activePromptCommandID]?.itemID {
                ids.insert(promptItemID)
            }
            return ids
        }()
        _ = settleRuntimeRequest(id: activePromptCommandID)
        _ = settleRuntimeRequest(id: activeAbortCommandID)
        for commandID in activeCommandItemIDs.keys
            where !commandIDsToKeep.contains(commandID) {
            _ = settleRuntimeRequest(id: commandID)
        }
        if failed {
            restoreActivePromptAttachments()
            restoreActiveQueuedPrompt()
        } else {
            discardActivePromptAttachments()
            discardActiveQueuedPrompt()
        }
        // 终止/取消不等于 Agent 已确认 Markdown 变更；只清理发送中引用。
        discardActiveMarkdownDiff()
        let fallbackStatus: ConversationItem.Status = failed
            ? .failed
            : (wasCancelled ? .cancelled : .completed)
        updateConversation(id: currentAssistantItemID) { item in
            if item.status == .streaming || item.status == .pending {
                item.status = fallbackStatus
            }
        }
        updateConversation(id: currentThinkingItemID) { item in
            if item.status == .streaming || item.status == .pending {
                item.status = fallbackStatus
            }
        }
        for itemID in toolItemIDs.values {
            updateConversation(id: itemID) { item in
                if item.status == .streaming || item.status == .pending {
                    item.status = fallbackStatus
                }
            }
        }

        activePromptCommandID = nil
        activePromptResponseAccepted = false
        runSettlementPending = false
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        if !wasCancelled {
            cancelledAgentRunID = nil
        }
        activeAgentRunID = nil
        activeAgentRunStarted = false
        abortRequestedRunID = nil
        if let commandItemID = activeAbortCommandItemID {
            updateConversation(id: commandItemID) { item in
                if item.status == .pending || item.status == .streaming {
                    item.status = failed ? .failed : (wasCancelled ? .cancelled : .completed)
                    item.detail = failed
                        ? "停止请求失败"
                        : (wasCancelled ? "Agent 已停止" : "命令已完成")
                }
            }
        }
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil
        activeAbortCommandItemID = nil
        activeAbortCommandID = nil
        for commandItemID in commandItemIDsToFinalize {
            updateConversation(id: commandItemID) { item in
                if item.status == .pending || item.status == .streaming {
                    item.status = failed ? .failed : (wasCancelled ? .cancelled : .completed)
                    if failed {
                        item.detail = "命令执行失败。"
                    } else if wasCancelled {
                        item.detail = "命令已取消。"
                    }
                }
            }
        }
        for commandID in Array(activeCommandItemIDs.keys)
            where !commandIDsToKeep.contains(commandID) {
            activeCommandItemIDs.removeValue(forKey: commandID)
            activeCommandSources.removeValue(forKey: commandID)
            commandStartedWhileBusy.removeValue(forKey: commandID)
        }
        abortRequested = false
        currentAssistantItemID = nil
        currentThinkingItemID = nil
        toolItemIDs.removeAll()
        runOutcome = failed
            ? .failed
            : (wasCancelled ? .cancelled : .completed)
        // 失败/取消是当前回合的持久终态；只有正常完成才清除终态标记。
        terminalRunStatus = failed
            ? .failed
            : (wasCancelled ? .cancelled : nil)
        runSettlementHandled = true
    }

    func sendQueuedPrompt(_ text: String, command: PiRPCCommand) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimeAuthenticationChanged else {
            if !trimmed.isEmpty {
                _ = enqueueFollowUp(trimmed)
                runtimeNotice = "Pi 认证已更新；重新连接 Runtime 后才会发送追问。"
            }
            return
        }
        guard !sessionOperationInFlight else {
            if !trimmed.isEmpty {
                lastError = "会话操作正在等待 Pi 确认，追问未发送。"
            }
            return
        }
        guard !trimmed.isEmpty,
              let transport,
              runtimeReady,
              !runSettlementPending,
              !runtimeSettlementQuarantined,
              phase == .requesting || phase == .streaming || phase == .executingTool
        else {
            if !trimmed.isEmpty {
                // 任何门控窗口都不能静默丢掉 steering/follow-up；改放入
                // 本地不可变队列，待 Runtime 恢复且状态安全时再派发。
                _ = enqueueFollowUp(trimmed)
            }
            return
        }
        let item = ConversationItem(kind: .user, text: trimmed, status: .pending)
        let itemID = item.id
        appendConversation(item)
        if let commandID = command.id {
            activeCommandItemIDs[commandID] = itemID
            activeCommandSources[commandID] = command.type
            commandStartedWhileBusy[commandID] = true
        }
        registerRuntimeRequest(
            command,
            purpose: .operation,
            itemID: itemID,
            timeout: .seconds(120)
        )
        let generation = self.generation
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
                guard !self.runtimeTerminationHandled else { return }
                self.lastError = safeError
            }
        }
    }

    func refreshRuntimeMetadata() {
        guard let transport else { return }
        let generation = self.generation
        let command = PiRPCCommand.getSessionStats()
        registerRuntimeRequest(
            command,
            purpose: .refresh,
            timeout: .seconds(20)
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
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                _ = self.settleRuntimeRequest(id: command.id)
                // HUD 保留 message_end 或上一次统计；刷新失败不打断对话。
            }
        }
    }

    func scheduleStreamingFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(33))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.streamFlushTask = nil
            self.flushStreamingBuffers()
        }
    }

    func flushStreamingBuffers() {
        streamFlushTask?.cancel()
        streamFlushTask = nil

        if !pendingAssistantText.isEmpty {
            let delta = pendingAssistantText
            pendingAssistantText.removeAll(keepingCapacity: true)
            updateConversation(id: currentAssistantItemID) { item in
                item.text.append(contentsOf: delta)
                item.status = .streaming
            }
        }
        if !pendingThinkingText.isEmpty {
            let delta = pendingThinkingText
            pendingThinkingText.removeAll(keepingCapacity: true)
            updateConversation(id: currentThinkingItemID) { item in
                item.text.append(contentsOf: delta)
                item.status = .streaming
            }
        }
    }

    /// 设置 Agent 活动。直接 bash 使用独立的 `setBashActivity`，避免 bash
    /// 完成时把仍在生成的 Agent 活动清掉。
    func setActivity(_ next: AgentActivity?) {
        agentActivity = next
        refreshDisplayedActivity()
        if next == nil, bashActivityActive {
            runtimeStatus = "正在执行命令…"
        }
    }

    func setBashActivity(_ isActive: Bool) {
        bashActivityActive = isActive
        refreshDisplayedActivity()
    }

    /// 展示优先保留 Agent 的细粒度活动；Agent 空闲时才显示直接 bash。
    /// 活动语义发生变化时才重置计时，因此连续 delta 不会把耗时归零。
    func refreshDisplayedActivity() {
        let next = agentActivity ?? (bashActivityActive ? .runningCommand : nil)
        guard activity != next else { return }
        activity = next
        if next != nil {
            activityStartedAt = Date()
        }
    }

    func resetActivityState() {
        agentActivity = nil
        bashActivityActive = false
        activity = nil
    }

    /// 在内存中保留有界、已脱敏的 stderr 尾部；跨 chunk 合并，避免启动错误
    /// 只显示最后半句或因多字节字符切分而无法阅读。
    func rememberRuntimeDiagnostic(_ text: String) {
        guard !text.isEmpty else { return }
        let combined = runtimeDiagnostic.map { "\($0)\n\(text)" } ?? text
        runtimeDiagnostic = String(combined.suffix(2_000))
    }

    func updateRuntimeMetadata(from record: PiRPCRecord) {
        var metadata = runtimeMetadata
        if let modelName = record.modelName { metadata.modelName = modelName }
        if let identity = record.modelIdentity {
            metadata.modelProvider = identity.provider
            metadata.modelID = identity.id
        }
        if let reasoning = record.modelSupportsReasoning {
            metadata.modelSupportsReasoning = reasoning
        }
        if let thinkingLevel = record.thinkingLevel { metadata.thinkingLevel = thinkingLevel }
        if let contextWindow = record.contextWindow { metadata.contextWindow = contextWindow }
        if let messageCount = record.messageCount { metadata.messageCount = messageCount }
        // 自动压缩状态以 Pi 回读为准，不在本地推断。
        if let autoCompaction = record.autoCompactionEnabled {
            metadata.autoCompactionEnabled = autoCompaction
        }
        if record.command == "get_session_stats",
           record.value(at: "data", "contextUsage", "tokens") == .null {
            metadata.contextTokens = nil
        } else if let contextTokens = record.contextTokens {
            metadata.contextTokens = contextTokens
        }
        if record.command == "get_session_stats",
           record.value(at: "data", "contextUsage", "percent") == .null {
            metadata.contextPercent = nil
        } else if let contextPercent = record.contextPercent {
            metadata.contextPercent = contextPercent
        }
        runtimeMetadata = metadata
    }

    func handleTransportEOF(generation: UUID) {
        handleRuntimeTermination(.eof, generation: generation)
    }

    /// `send` 发现 stdin/进程已经失效时，不能只把单个命令标红；否则控制器
    /// 仍会保留一个实际上不可用的 Runtime。可恢复的业务拒绝仍由调用方处理。
    /// 在真正写入前再次确认 Runtime 代际，避免关闭/重启后的悬空 Task
    /// 把命令写进旧进程。写入本身仍由传输层串行化。
    func sendRuntimeCommand(
        _ command: PiRPCCommand,
        using transport: any PiRPCTransport,
        generation: UUID,
        sessionEpoch expectedSessionEpochOverride: UUID? = nil
    ) async throws {
        let expectedSessionEpoch = expectedSessionEpochOverride
            ?? runtimeRequestSessionEpochs[command.runtimeTicketID]
            ?? sessionEpoch
        guard self.generation == generation,
              self.sessionEpoch == expectedSessionEpoch,
              !runtimeTerminationHandled,
              let current = self.transport,
              (current as AnyObject) === (transport as AnyObject)
        else {
            throw PiRPCError.notRunning
        }
        try await transport.send(command)
    }

    @discardableResult
    func handleTerminalTransportSendFailure(
        _ error: Error,
        generation: UUID
    ) -> Bool {
        guard self.generation == generation,
              !runtimeTerminationHandled,
              let rpcError = error as? PiRPCError,
              rpcError == .notRunning || rpcError == .stdinClosed
        else { return false }
        handleRuntimeTermination(
            .transportError(PuraPiSensitiveText.redacted(error.localizedDescription)),
            generation: generation
        )
        return true
    }

    func handleTransportError(_ error: Error, generation: UUID) {
        if let rpcError = error as? PiRPCError,
           case .executableNotFound = rpcError {
            runtimeProvisioningRequired = true
        }
        handleRuntimeTermination(
            .transportError(PuraPiSensitiveText.redacted(error.localizedDescription)),
            generation: generation
        )
    }

    /// 收束所有依赖当前 Runtime 的工作。
    ///
    /// stdout EOF、传输解码错误和进程退出可能从不同异步路径到达；它们共享
    /// 这一个闸门，保证活动、命令标记、Extension UI、Bash 和回合终态不会
    /// 只清掉其中一部分。排队 Prompt 与 Composer 附件刻意保留，避免失去用户
    /// 尚未发送的输入。
    func handleRuntimeTermination(
        _ reason: PuraPiRuntimeTerminationReason,
        generation: UUID
    ) {
        guard self.generation == generation,
              !runtimeTerminationHandled
        else { return }

        runtimeTerminationHandled = true
        processExitObserved = true
        cancelAllRuntimeRequests()
        let pendingRuntimeStartTask = runtimeStartTask
        runtimeStartTask?.cancel()
        runtimeStartTask = nil
        eventTask?.cancel()
        eventTask = nil
        let wasCancelled = currentAgentRunWasCancelled()
        let bashWasCancelled = bashAbortRequested
        let failed = !wasCancelled
        let reasonWithDiagnostic: PuraPiRuntimeTerminationReason = {
            guard let diagnostic = runtimeDiagnostic,
                  !diagnostic.isEmpty
            else { return reason }
            switch reason {
            case .processExited(let status):
                return .processExitedWithDiagnostic(status, diagnostic)
            case .processExitedWithDiagnostic:
                return reason
            case .eof:
                return .transportError(
                    "Pi Runtime 的 RPC 输出已结束。\nPi 输出：\(diagnostic)"
                )
            case .transportError(let message):
                return .transportError(
                    message.isEmpty
                        ? "Pi 输出：\(diagnostic)"
                        : "\(message)\nPi 输出：\(diagnostic)"
                )
            }
        }()
        let message = PuraPiSensitiveText.redacted(reasonWithDiagnostic.errorMessage)
        runtimeDiagnostic = nil

        // 未得到 Runtime 确认的普通 Prompt 仍是用户输入；主动 Abort 则不重复
        // 放回已经明确提交过的附件快照。
        if failed {
            restoreActivePromptAttachments()
        } else {
            discardActivePromptAttachments()
        }

        // 先把已经收到但尚未发布的 delta 写入对话，再标记未完成项目的终态。
        flushStreamingBuffers()
        if sessionRebuildInFlight {
            failSessionRebuild(message: message)
        } else if expectsMessagesResponse {
            failRecentSessionRestore(message: message)
        }
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil

        // Runtime 已经失联，不能再向旧 transport 发送取消响应；清掉本地请求
        // 并让 sheet 消失即可。正常关闭/Abort 路径仍会显式发送取消响应。
        // 旧 transport 会由停止屏障负责终止，不能让这条已经失效的响应
        // 写入继续阻塞下一次连接。
        _ = drainPendingExtensionUIRequests()
        extensionUIResponseOperationID = UUID()
        extensionUIResponseInFlight = false

        // /status 和手动压缩有独立的可见命令项，不能让它们永久停在转圈。
        var statsItemIDs = Set(statsRequestItemIDs.values)
        if let statsCommandItemID { statsItemIDs.insert(statsCommandItemID) }
        let compactItemID = activeCompactCommandItemID
        for statsItemID in statsItemIDs {
            updateConversation(id: statsItemID) { item in
                item.status = failed ? .failed : .cancelled
                item.detail = failed ? "Runtime 已断开，统计未完成。" : "Runtime 已停止。"
            }
        }
        if let compactItemID {
            updateConversation(id: compactItemID) { item in
                item.status = failed ? .failed : .cancelled
                item.detail = failed ? "Runtime 已断开，压缩未完成。" : "压缩已停止。"
            }
        }

        // 已启动的直接 bash 要明确区分「Runtime 失败」与用户主动中止。
        for index in bashExecutions.indices where bashExecutions[index].isRunning {
            bashExecutions[index].state = bashWasCancelled
                ? .cancelled
                : .failed(message: message)
        }
        bashAbortRequested = false
        setBashActivity(false)

        // 统一结束 Assistant、工具和已发送的命令活动。
        finalizeCurrentItemsAfterSettled(
            wasCancelled: wasCancelled,
            failed: failed
        )

        activeExportCommandID = nil
        activeAutoCompactionCommandID = nil
        activeBashAbortCommandID = nil
        activeRuntimeStatusRequestID = nil
        activeAutoRetryCommandID = nil
        pendingAutoRetryValue = nil
        activeAbortRetryCommandID = nil
        activeAbortRetryWaitID = nil
        retryWaitState = nil
        autoRetryEnabled = nil
        runtimeStatusLoading = false
        if runtimeStatusPanelPresented {
            runtimeStatusPanelError = "Pi Runtime 已断开，状态快照暂不可刷新。"
        }
        if let activeTurnRecordID,
           let index = turnRecords.firstIndex(where: { $0.id == activeTurnRecordID }) {
            turnRecords[index].endedAt = Date()
            turnRecords[index].outcome = wasCancelled ? .cancelled : .failed
        }
        activeTurnRecordID = nil
        runtimeControlError = nil
        activeStatsCommandID = nil
        statsCommandItemID = nil
        activeCompactCommandItemID = nil
        activeCompactRPCID = nil
        activeStatsRequestIDs.removeAll()
        statsRequestItemIDs.removeAll()
        activeSessionCommandID = nil
        activeForkCommandID = nil
        activeCloneCommandID = nil
        activeRenameCommandID = nil
        commandsRequestInFlight = false
        activeCommandsRequestID = nil
        piCommands.removeAll()
        sessionStats = nil
        resetModelControlState()
        sessionListLoadTask?.cancel()
        sessionListLoadTask = nil
        pendingTurnLocation = nil
        conversationScrollTarget = nil
        preservedConversationItemForRestore = nil
        let terminatedTransport = transport
        let pendingRuntimeStopTask = runtimeStopTask
        transport = nil
        _ = scheduleRuntimeStop(
            pending: pendingRuntimeStopTask,
            transport: terminatedTransport,
            startTask: pendingRuntimeStartTask
        )
        runtimeReady = false
        extensionNotifications.removeAll()
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        resetSubagentPanelState()

        // `phase` 表示 Runtime 是否还能接受新命令；即使本回合是取消，也必须
        // 进入 failed（不可用）而不是继续显示可停止的 cancelled 按钮状态。
        phase = .failed
        runOutcome = wasCancelled ? .cancelled : .failed
        terminalRunStatus = wasCancelled ? .cancelled : .failed
        receivedStateResponse = false
        receivedStatsResponse = false
        receivedMessagesResponse = false
        sessionRebuildInFlight = false
        runtimeSettlementQuarantined = false
        ignoreSettledUntilAgentStart = false
        abortRequested = false
        abortRequestedRunID = nil
        cancelledAgentRunID = nil
        activeAgentRunStarted = false
        agentActivity = nil
        refreshDisplayedActivity()
        runtimeStatus = wasCancelled
            ? "Agent 已停止；Pi Runtime 已退出"
            : reason.statusText
        // 用户主动取消后进程退出是停止路径的一部分，不应伪装成 Agent 失败；
        // 无论哪种终止原因，都通过独立 notice 提供可操作的重连入口。
        runtimeNotice = wasCancelled
            ? "Agent 已停止，但 Pi Runtime 已退出。请重新连接后再发送。"
            : "Pi Runtime 已断开。请重新连接后再发送。"
        lastError = wasCancelled ? nil : message
        if !wasCancelled {
            noteAuthenticationFailure(message)
        }
    }

    func appendConversation(_ item: ConversationItem) {
        conversation.append(item)
    }

    func ensureAssistantItem() {
        _ = ensureAgentRun()
        if currentAssistantItemID != nil { return }
        let item = ConversationItem(kind: .assistant, status: .streaming)
        currentAssistantItemID = item.id
        appendConversation(item)
    }

    func ensureThinkingItem() {
        _ = ensureAgentRun()
        if currentThinkingItemID != nil { return }
        let item = ConversationItem(kind: .thinking, title: "Thinking", status: .streaming)
        currentThinkingItemID = item.id
        appendConversation(item)
    }

    func markCurrentAssistant(status: ConversationItem.Status) {
        updateConversation(id: currentAssistantItemID) { item in item.status = status }
    }

    func updateTool(_ record: PiRPCRecord, completed: Bool = false) {
        guard let toolID = record.toolCallID, let itemID = toolItemIDs[toolID] else { return }
        updateConversation(id: itemID) { item in
            if let text = record.toolResultText { item.text = text }
            item.status = completed
                ? (currentAgentRunWasCancelled()
                    ? .cancelled
                    : (record.toolIsError ? .failed : .completed))
                : .streaming
        }
    }

    func updateConversation(id: UUID?, _ update: (inout ConversationItem) -> Void) {
        guard let id, let index = conversation.firstIndex(where: { $0.id == id }) else { return }
        update(&conversation[index])
    }

    func isAbortMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("aborted")
            || normalized.contains("operation was aborted")
            || normalized.contains("cancelled")
            || normalized.contains("canceled")
    }

    func formattedArguments(_ value: JSONValue?) -> String? {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.count > 800 ? String(text.prefix(800)) + "…" : text
    }
}
