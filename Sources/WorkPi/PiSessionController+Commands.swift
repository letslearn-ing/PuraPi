import Foundation
import PiDomain
import PiRPC

/// Runtime 相关的用户命令：新建/继续会话、压缩、Abort 和命令活动。
extension PiSessionController {
    /// 启动一个不继承当前对话的新 Pi Session。
    func startNewSession(preservingCommandItemID: UUID? = nil) {
        guard let workspace,
              projectAuthorizationState != .needsDecision,
              projectAuthorizationState != .denied,
              !runSettlementPending,
              !sessionRebuildInFlight,
              !sessionOperationInFlight,
              phase == .idle || phase == .failed
        else { return }
        guard draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Composer 中仍有草稿；请先发送或显式丢弃后再新建会话。"
            return
        }
        draftPrompt = ""
        composerCloseBlocked = false
        recentSessionRestoreState = .available
        let discardedQueuedCount = queuedPrompts.count
        let discardedAttachmentCount = pendingAttachments.count + activePromptAttachments.count
        queuedPrompts.removeAll()
        revokeUnusedMarkdownApprovalTokens()
        pendingAttachments.removeAll()
        let restartNotice: String?
        if discardedQueuedCount > 0 || discardedAttachmentCount > 0 {
            let parts = [
                discardedQueuedCount > 0 ? "排队任务 \(discardedQueuedCount) 条" : nil,
                discardedAttachmentCount > 0 ? "附件 \(discardedAttachmentCount) 个" : nil,
            ].compactMap { $0 }
            restartNotice = "新会话不会发送旧会话的\(parts.joined(separator: "、"))。"
        } else {
            restartNotice = nil
        }
        var preservedCommandItem = preservingCommandItemID.flatMap { commandItemID in
            conversation.first(where: { $0.id == commandItemID })
        }
        if let restartNotice {
            preservedCommandItem?.detail = restartNotice
        }
        restartRuntime(
            for: workspace.rootURL,
            launchMode: projectAuthorizationState == .approved ? .freshApproved : .fresh,
            preservedConversationItem: preservedCommandItem,
            preservedRuntimeNotice: restartNotice
        )
    }

    /// 通过 RPC 请求 Pi 压缩当前上下文。
    func compactSession(
        customInstructions: String? = nil,
        commandItemID: UUID? = nil
    ) {
        guard !runtimeAuthenticationChanged else {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；上下文压缩未发送。"
            if let commandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = "认证已更新，请先重新连接 Runtime。"
                }
            }
            return
        }
        guard let transport,
              runtimeReady,
              !runSettlementPending,
              !runtimeSettlementQuarantined,
              !sessionRebuildInFlight,
              !sessionOperationInFlight,
              phase == .idle || phase == .failed
        else {
            if let commandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = "当前 Agent 正在运行，暂时不能压缩上下文。"
                }
            }
            return
        }
        phase = .settling
        cancelledAgentRunID = nil
        runOutcome = .running
        runSettlementHandled = false
        terminalRunStatus = nil
        runtimeStatus = "正在压缩上下文…"
        if let commandItemID {
            updateConversation(id: commandItemID) { item in item.status = .streaming }
        }
        let compactCommand = PiRPCCommand.compact(customInstructions: customInstructions)
        activeCompactCommandItemID = commandItemID
        activeCompactRPCID = compactCommand.id
        registerRuntimeRequest(compactCommand, purpose: .operation, timeout: .seconds(60))
        let generation = self.generation
        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.sendRuntimeCommand(
                    compactCommand,
                    using: transport,
                    generation: generation
                )
            } catch {
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: self.activeCompactRPCID)
                self.phase = .failed
                self.runtimeStatus = "上下文压缩请求失败"
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = safeError
                self.noteAuthenticationFailure(safeError)
                if let commandItemID {
                    self.updateConversation(id: commandItemID) { item in
                        item.status = .failed
                        item.detail = "发送失败：\(safeError)"
                    }
                }
                self.activeCompactCommandItemID = nil
                self.activeCompactRPCID = nil
                self.runOutcome = .failed
                self.terminalRunStatus = .failed
                self.runSettlementHandled = true
                self.setActivity(nil)
            }
        }
    }

    /// 使用 Pi CLI 的 `--continue` 语义恢复当前项目最近的持久化 Session。
    /// 文件树、选中文件和 FSEvents 监视器保持不变，只替换 Pi Runtime 和对话快照。
    func continueRecentSession(preservingCommandItemID: UUID? = nil) {
        guard let workspace,
              projectAuthorizationState != .needsDecision,
              projectAuthorizationState != .denied,
              !runSettlementPending,
              !sessionRebuildInFlight,
              !sessionOperationInFlight,
              recentSessionRestoreState == .available || recentSessionRestoreState == .failed
        else { return }
        recentSessionRestoreState = .loading
        composerCloseBlocked = false
        let launchMode: PiRuntimeLaunchMode = projectAuthorizationState == .approved
            ? .continueRecentApproved
            : .continueRecent
        let preservedCommandItem = preservingCommandItemID.flatMap { commandItemID in
            conversation.first(where: { $0.id == commandItemID })
        }
        restartRuntime(
            for: workspace.rootURL,
            launchMode: launchMode,
            preservedConversationItem: preservedCommandItem
        )
    }

    /// Runtime 意外断开后的显式重连入口。始终恢复最近持久化会话，避免用
    /// fresh 模式覆盖刚刚已经写入磁盘的对话；本地队列和 Composer 输入由
    /// `restartRuntime` 按恢复语义保留。
    var canReconnectRuntime: Bool {
        guard workspace != nil,
              projectAuthorizationState != .needsDecision,
              projectAuthorizationState != .denied,
              !sessionRebuildInFlight,
              !sessionOperationInFlight,
              !runSettlementPending
        else { return false }

        let disconnected = !runtimeReady && phase == .failed
        let authenticationRestart = runtimeAuthenticationChanged
            && runtimeReady
            && (phase == .idle || phase == .failed)
            && !bashActivityActive
            && activeAgentRunID == nil
        return disconnected || authenticationRestart
    }

    func reconnectRuntime() {
        guard canReconnectRuntime, let workspace else { return }
        recentSessionRestoreState = .loading
        composerCloseBlocked = false
        let launchMode: PiRuntimeLaunchMode = projectAuthorizationState == .approved
            ? .continueRecentApproved
            : .continueRecent
        restartRuntime(
            for: workspace.rootURL,
            launchMode: launchMode
        )
    }

    /// 连续的 `--continue` 恢复失败时，允许用户显式放弃本次恢复并启动新会话。
    /// 旧 Session 仍保留在磁盘中；这里不自动切换，避免无提示地丢失上下文。
    var canStartNewSessionAfterRestoreFailure: Bool {
        workspace != nil
            && recentSessionRestoreState == .failed
            && phase == .failed
            && !runtimeAuthenticationChanged
            && !hasUnsentComposerInput
            && !sessionRebuildInFlight
            && !sessionOperationInFlight
            && !runSettlementPending
            && projectAuthorizationState != .needsDecision
            && projectAuthorizationState != .denied
    }

    /// Runtime 安装/发现成功后只重试明确因可执行文件缺失而失败的标签。
    /// 普通崩溃仍需用户自己点击“重新连接”，避免安装器改变用户意图。
    func retryAfterRuntimeProvisioning() {
        guard runtimeProvisioningRequired else { return }
        reconnectRuntime()
    }

    func abort() {
        abort(commandItemID: nil)
    }

    func abort(commandItemID: UUID?) {
        guard let transport, runtimeReady,
              activeAbortCommandID == nil,
              !sessionRebuildInFlight,
              !sessionOperationInFlight,
              (!runtimeSettlementQuarantined || activeAgentRunID != nil),
              phase != .cancelled
        else { return }
        let pendingExtensionRequestIDs = drainPendingExtensionUIRequests()
        runOutcome = .cancelled
        abortRequested = true
        if let activeAgentRunID {
            cancelledAgentRunID = activeAgentRunID
        }
        abortRequestedRunID = activeAgentRunID
        terminalRunStatus = .cancelled
        phase = .cancelled
        runtimeStatus = "正在停止…"
        setActivity(.stopping)
        // 停止意图覆盖整个队列：否则用户点了停止，后续任务仍会自动开跑。
        cancelAllQueuedPrompts()
        let generation = self.generation
        let sessionEpoch = self.sessionEpoch
        let command = PiRPCCommand.abort()
        activeAbortCommandItemID = commandItemID
        activeAbortCommandID = command.id
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(20))
        scheduleAbortTimeout(for: generation)
        Task { [weak self] in
            do {
                guard let self else { return }
                await self.sendExtensionUICancellations(
                    pendingExtensionRequestIDs,
                    using: transport,
                    generation: generation,
                    sessionEpoch: sessionEpoch
                )
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
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                self.finishAbortFailure(message: error.localizedDescription)
            }
        }
    }

    func clearError() {
        lastError = nil
        if canStartNewSessionAfterRestoreFailure {
            runtimeNotice = "最近会话恢复失败；可以重新连接，或启动新会话。"
        }
    }

    /// 内部可见：提交分流在 `+Submit` 扩展里调用它。
    func executeWorkPiCommand(
        _ action: WorkPiCommandAction,
        text: String,
        commandItemID: UUID
    ) {
        switch action {
        case .newSession:
            guard !runSettlementPending,
                  !sessionRebuildInFlight,
                  !sessionOperationInFlight,
                  phase == .idle || phase == .failed
            else {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = "当前 Agent 正在运行，暂时不能新建会话。"
                }
                return
            }
            updateConversation(id: commandItemID) { item in item.status = .completed }
            startNewSession(preservingCommandItemID: commandItemID)
        case .continueRecent:
            guard !runSettlementPending,
                  !sessionRebuildInFlight,
                  !sessionOperationInFlight,
                  phase == .idle || phase == .failed
            else {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = "当前 Agent 正在运行，暂时不能继续最近会话。"
                }
                return
            }
            updateConversation(id: commandItemID) { item in item.status = .completed }
            continueRecentSession(preservingCommandItemID: commandItemID)
        case .compact:
            compactSession(
                customInstructions: WorkPiCommandCatalog.customInstructions(from: text),
                commandItemID: commandItemID
            )
        case .abort:
            guard transport != nil,
                  runtimeReady,
                  activeAbortCommandID == nil,
                  phase != .cancelled,
                  !sessionRebuildInFlight,
                  !sessionOperationInFlight,
                  (!runtimeSettlementQuarantined || activeAgentRunID != nil)
            else {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = phase == .cancelled
                        ? "正在停止 Agent，请稍候。"
                        : "Pi Runtime 尚未连接，无法停止 Agent。"
                }
                return
            }
            activeAbortCommandItemID = commandItemID
            updateConversation(id: commandItemID) { item in
                item.status = .streaming
                item.detail = "正在等待 Pi 停止…"
            }
            abort(commandItemID: commandItemID)
        case .trustProject:
            guard let workspace else {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = "尚未打开项目。"
                }
                return
            }
            guard WorkPiProjectAuthorization.requiresAuthorization(for: workspace.rootURL) else {
                updateConversation(id: commandItemID) { item in
                    item.status = .completed
                    item.detail = "当前项目没有需要授权的本地资源。"
                }
                return
            }
            updateConversation(id: commandItemID) { item in item.status = .completed }
            requestProjectAuthorization()
        case .status:
            presentStatusPanel(commandItemID: commandItemID)
        }
    }

    @discardableResult
    func appendCommandActivity(
        _ text: String,
        status: ConversationItem.Status = .pending,
        detail: String? = nil
    ) -> UUID {
        let item = ConversationItem(
            kind: .command,
            text: text,
            detail: detail,
            status: status
        )
        appendConversation(item)
        return item.id
    }
}
