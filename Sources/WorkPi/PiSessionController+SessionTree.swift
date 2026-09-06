import Foundation
import PiDomain
import PiRPC
import WorkspaceKit

/// 会话树：项目内的多个会话、会话内的多轮对话，以及分支与命名操作。
///
/// 会话列表来自磁盘扫描而非 RPC：Pi 只暴露「当前会话」的能力，不提供同项目
/// 其他会话的列表。预览其他会话同样只读文件，不发 `switch_session`，因为用户
/// 点开看看不应该打断正在运行的任务。
extension PiSessionController {
    /// 会改变当前 Session 身份或分支的 RPC 尚未完成；在其确认前不能发送
    /// Prompt，否则 Prompt 可能落入旧会话或被重建历史覆盖。
    var sessionOperationInFlight: Bool {
        activeSessionCommandID != nil
            || activeForkCommandID != nil
            || activeCloneCommandID != nil
            || activeRenameCommandID != nil
    }

    /// 重新扫描当前项目的会话列表。
    ///
    /// 在后台线程解析：最大的真实会话接近 2MB，目录里可能有几十个文件。
    func reloadSessionList() {
        guard let workspace else {
            sessionSummaries = []
            return
        }

        sessionListLoadTask?.cancel()
        let store = PiSessionStore()
        let root = workspace.rootURL
        let generation = self.generation
        sessionListLoadTask = Task { [weak self] in
            let summaries = await Task.detached(priority: .utility) {
                store.listSessions(for: root)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.generation == generation
                else { return }
                self.sessionSummaries = summaries
            }
        }
    }

    /// 展开某个会话，加载它的轮次列表。
    ///
    /// 当前会话与其他会话都走文件解析，保证展开行为一致且不产生副作用。
    func loadTurns(for summary: PiSessionSummary) {
        guard sessionTurns[summary.id] == nil else { return }

        let fileURL = summary.fileURL
        let key = summary.id
        let generation = self.generation
        Task { [weak self] in
            let turns = await Task.detached(priority: .utility) {
                PiSessionTurnParser.turns(in: fileURL)
            }.value
            await MainActor.run {
                guard let self,
                      self.generation == generation
                else { return }
                self.sessionTurns[key] = turns
            }
        }
    }

    /// 当前会话对应的文件路径；用于在列表中高亮。
    var activeSessionPath: String? {
        activeSessionFilePath
    }

    /// 双击切换到另一个会话。
    ///
    /// 切换会替换整条对话历史，因此必须走 Pi 的 `switch_session`，
    /// 由后续的 `get_messages` 重建界面。
    @discardableResult
    func switchToSession(_ summary: PiSessionSummary) -> Bool {
        guard let transport, let workspace, runtimeReady else {
            lastError = "Pi Runtime 尚未就绪，无法切换会话。"
            return false
        }
        guard summary.fileURL.path != activeSessionFilePath else { return true }
        // 会话列表是异步快照；在把路径交给 Pi 前重新确认文件身份和 cwd，
        // 避免扫描后被替换成另一个项目的 JSONL。测试/导入的虚拟摘要若
        // 尚无文件则仍由 Runtime 负责最终处理。
        if FileManager.default.fileExists(atPath: summary.fileURL.path) {
            guard let current = PiSessionStore().summary(
                of: summary.fileURL,
                expectedWorkspacePath: workspace.rootURL.path
            ), current.sessionID == summary.sessionID else {
                lastError = "会话文件已改变，无法安全切换。"
                return false
            }
        }
        guard !isAgentBusy,
              !hasRunningBashExecution,
              !sessionRebuildInFlight,
              !sessionOperationInFlight
        else {
            lastError = hasRunningBashExecution
                ? "命令正在运行，请先完成或中止后再切换会话。"
                : "Agent 正在运行，请先停止再切换会话。"
            return false
        }

        let command = PiRPCCommand.switchSession(sessionPath: summary.fileURL.path)
        activeSessionCommandID = command.id
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(30))
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
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: self.activeSessionCommandID)
                self.activeSessionCommandID = nil
                self.pendingTurnLocation = nil
                self.lastError = "无法切换会话：\(WorkPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
        return true
    }

    /// 从某一轮重新开始（fork）。
    ///
    /// fork 在当前会话内改变活动分支，旧分支仍留在树里。成功后必须重新拉取
    /// 消息，否则界面还显示已被抛弃的历史。
    func forkSession(from turn: PiSessionTurn) {
        guard let transport, runtimeReady else {
            lastError = "Pi Runtime 尚未就绪，无法分叉会话。"
            return
        }
        guard !isAgentBusy,
              !hasRunningBashExecution,
              !sessionRebuildInFlight,
              !sessionOperationInFlight
        else {
            lastError = hasRunningBashExecution
                ? "命令正在运行，请先完成或中止后再分叉会话。"
                : "Agent 正在运行，请先停止再分叉会话。"
            return
        }

        let command = PiRPCCommand.fork(entryID: turn.entryID)
        activeForkCommandID = command.id
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(30))
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
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: self.activeForkCommandID)
                self.activeForkCommandID = nil
                self.lastError = "无法分叉会话：\(WorkPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    /// 把当前分支复制为新会话（clone）。
    func cloneCurrentSession() {
        guard let transport, runtimeReady else {
            lastError = "Pi Runtime 尚未就绪，无法复制会话。"
            return
        }
        guard !isAgentBusy,
              !hasRunningBashExecution,
              !sessionRebuildInFlight,
              !sessionOperationInFlight
        else {
            lastError = hasRunningBashExecution
                ? "命令正在运行，请先完成或中止后再复制会话。"
                : "Agent 正在运行，请先停止再复制会话。"
            return
        }

        let command = PiRPCCommand.clone()
        activeCloneCommandID = command.id
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(30))
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
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: self.activeCloneCommandID)
                self.activeCloneCommandID = nil
                self.lastError = "无法复制会话：\(WorkPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    /// 重命名当前会话。当前 Pi RPC 版本要求名称非空。
    func renameCurrentSession(to name: String) {
        guard let transport, runtimeReady else {
            lastError = "Pi Runtime 尚未就绪，无法重命名会话。"
            return
        }
        guard !isAgentBusy,
              !sessionRebuildInFlight,
              !sessionOperationInFlight
        else {
            lastError = "Agent 正在运行，请先停止再重命名会话。"
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Pi 0.84.x 的 RPC 合约拒绝空名称；不要发送一个必然失败的请求，
            // 也不要让 UI 看起来像已经清除了名称。
            lastError = "Pi 当前版本不支持空会话名称；请填写名称。"
            return
        }
        guard activeRenameCommandID == nil else { return }
        let command = PiRPCCommand.setSessionName(trimmed)
        activeRenameCommandID = command.id
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(30))
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
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: self.activeRenameCommandID)
                self.activeRenameCommandID = nil
                self.lastError = "无法重命名会话：\(WorkPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    /// 双击会话树里的某一轮：定位到它。
    ///
    /// 已经是当前会话时直接定位；否则先 `switch_session`，等历史重建完成后
    /// 再定位（`pendingTurnLocation` 记录意图，由 `get_messages` 的响应兑现）。
    func openTurn(_ turn: PiSessionTurn, in summary: PiSessionSummary) {
        guard summary.fileURL.path == activeSessionFilePath else {
            pendingTurnLocation = turn.text
            if !switchToSession(summary) {
                pendingTurnLocation = nil
            }
            return
        }
        locateTurn(matching: turn.text)
    }

    /// 在当前对话里找到这一轮的用户消息并滚动过去。
    ///
    /// 历史映射不保留 entry id，因此按用户消息正文匹配。这是目前唯一可用的
    /// 对应关系；如果将来 `get_messages` 暴露 entry id，应改为按 id 精确定位。
    func locateTurn(matching text: String) {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let match = conversation.first { item in
            item.kind == .user
                && item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(
                    String(needle.prefix(80))
                )
        }
        guard let match else { return }
        conversationScrollTarget = match.id
    }

    func clearConversationScrollTarget() {
        conversationScrollTarget = nil
    }

    // MARK: - 响应处理

    /// 返回 true 表示该响应已由会话树逻辑消费。
    func consumeSessionTreeResponse(_ record: PiRPCRecord) -> Bool {
        guard !shouldIgnoreRuntimeResponse(record) else { return true }
        switch record.command {
        case "switch_session":
            guard let activeID = activeSessionCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = settleRuntimeRequest(
                for: record,
                command: "switch_session",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: "switch_session",
                purposes: [.operation]
            ) else { return false }
            let wasCancelled = record.operationWasCancelled
            activeSessionCommandID = nil
            if record.success == true, !wasCancelled {
                // Pi 已切换会话；重新读取状态与消息以重建界面。
                invalidateSessionCaches()
                requestSessionRebuild()
            } else {
                pendingTurnLocation = nil
            }
            return true

        case "fork":
            guard let activeID = activeForkCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = settleRuntimeRequest(
                for: record,
                command: "fork",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: "fork",
                purposes: [.operation]
            ) else { return false }
            activeForkCommandID = nil
            if record.success == true {
                if record.operationWasCancelled {
                    lastError = "扩展取消了这次分叉。"
                } else {
                    // 活动分支已改变，旧的对话内容不再有效。
                    invalidateSessionCaches()
                    requestSessionRebuild()
                }
            }
            return true

        case "clone":
            guard let activeID = activeCloneCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = settleRuntimeRequest(
                for: record,
                command: "clone",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: "clone",
                purposes: [.operation]
            ) else { return false }
            activeCloneCommandID = nil
            if record.success == true {
                if record.operationWasCancelled {
                    lastError = "扩展取消了这次复制。"
                } else {
                    // clone 产生新会话文件，列表需要刷新。
                    invalidateSessionCaches()
                    requestSessionRebuild()
                }
            }
            return true

        case "set_session_name":
            guard let activeID = activeRenameCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = settleRuntimeRequest(
                for: record,
                command: "set_session_name",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: "set_session_name",
                purposes: [.operation]
            ) else { return false }
            activeRenameCommandID = nil
            if record.success == true {
                // 名字写入的是会话文件里的 session_info 条目，重扫才能看到。
                invalidateSessionCaches()
                refreshRuntimeState()
                reloadSessionList()
            }
            return true

        default:
            return false
        }
    }

    /// 记录 `get_state` 报告的会话身份，用于在列表中高亮当前会话。
    func updateActiveSessionIdentity(from record: PiRPCRecord) {
        if let path = record.sessionFilePath, !path.isEmpty {
            activeSessionFilePath = path
        }
        activeSessionName = record.sessionName
    }

    /// 丢弃缓存的轮次，让下次展开重新解析。
    func invalidateSessionCaches() {
        sessionTurns.removeAll()
    }

    /// 切换分支或会话后重建对话区。
    private func requestSessionRebuild() {
        guard let transport,
              runtimeReady,
              !sessionRebuildInFlight,
              !runSettlementPending
        else { return }

        let generation = self.generation
        let rebuildEpoch = UUID()
        sessionEpoch = rebuildEpoch
        sessionRebuildTask?.cancel()
        let pendingExtensionRequestIDs = drainPendingExtensionUIRequests()
        resetSubagentPanelState()
        extensionNotifications.removeAll()
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        let stateCommand = PiRPCCommand.getState()
        let statsCommand = PiRPCCommand.getSessionStats()
        let messagesCommand = PiRPCCommand.getMessages()

        // 会话重建拥有独立事实快照；丢弃同一代际中尚未完成的所有旧请求，
        // 防止旧模型、统计或历史结果在新会话加载期间反写状态。
        cancelAllRuntimeRequests()
        commandsRequestInFlight = false
        activeCommandsRequestID = nil
        piCommands.removeAll()
        resetModelControlState()
        activeSessionCommandID = nil
        activeForkCommandID = nil
        activeCloneCommandID = nil
        activeRenameCommandID = nil
        activeExportCommandID = nil
        activeAutoCompactionCommandID = nil
        activeStatsCommandID = nil
        activeStatsRequestIDs.removeAll()
        statsRequestItemIDs.removeAll()
        statsCommandItemID = nil
        sessionStats = nil
        resetRuntimeStatusState()

        // 先使任何旧的异步历史映射失效；即使它不响应取消，也不能在新的
        // rebuild 期间把旧快照写回对话。
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()

        // 必须先进入准备态再发送请求；否则用户可以在历史尚未替换时提交
        // 新 Prompt，旧的 get_messages 返回后会覆盖新回合。
        sessionRebuildInFlight = true
        runtimeReady = false
        clearRuntimeNotice()
        phase = .preparing
        runSettlementHandled = true
        receivedStateResponse = false
        receivedStatsResponse = false
        receivedMessagesResponse = false
        expectsMessagesResponse = true
        if !queuedPrompts.isEmpty {
            let count = queuedPrompts.count
            queuedPrompts.removeAll()
            revokeUnusedMarkdownApprovalTokens()
            runtimeNotice = "会话已切换；旧会话的排队任务（\(count) 条）未发送。"
        }
        // 历史新快照成功前保留旧内容，避免网络/协议失败时把可见对话清空；
        // `beginHistoryMapping` 完成后再原子替换。
        setActivity(.restoringSession)

        registerRuntimeRequest(
            stateCommand,
            purpose: .rebuild,
            timeout: .seconds(20)
        )
        registerRuntimeRequest(
            statsCommand,
            purpose: .rebuild,
            timeout: .seconds(20)
        )
        registerRuntimeRequest(
            messagesCommand,
            purpose: .rebuild,
            timeout: .seconds(25)
        )

        sessionRebuildTask = Task { [weak self] in
            do {
                guard let self else { return }
                defer {
                    if self.sessionEpoch == rebuildEpoch {
                        self.sessionRebuildTask = nil
                    }
                }
                // A response that was already accepted by the sheet still has
                // bytes in flight.  Do not let rebuild commands overtake it.
                await self.waitForExtensionUIResponseBarrier()
                try Task.checkCancellation()
                guard self.generation == generation,
                      self.sessionEpoch == rebuildEpoch,
                      self.sessionRebuildInFlight,
                      !self.runtimeTerminationHandled
                else { return }
                if !pendingExtensionRequestIDs.isEmpty {
                    await self.sendExtensionUICancellations(
                        pendingExtensionRequestIDs,
                        using: transport,
                        generation: generation,
                        sessionEpoch: rebuildEpoch
                    )
                }
                try await self.sendRuntimeCommand(
                    stateCommand,
                    using: transport,
                    generation: generation
                )
                try await self.sendRuntimeCommand(
                    statsCommand,
                    using: transport,
                    generation: generation
                )
                try await self.sendRuntimeCommand(
                    messagesCommand,
                    using: transport,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.generation == generation,
                      self.sessionEpoch == rebuildEpoch,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: stateCommand.id)
                _ = self.settleRuntimeRequest(id: statsCommand.id)
                _ = self.settleRuntimeRequest(id: messagesCommand.id)
                self.failSessionRebuild(
                    message: "无法重建会话内容：\(WorkPiSensitiveText.redacted(error.localizedDescription))"
                )
            }
        }
        reloadSessionList()
    }

    func failSessionRebuild(message: String) {
        guard sessionRebuildInFlight else { return }
        sessionRebuildTask?.cancel()
        sessionRebuildTask = nil
        cancelRuntimeRequests(purpose: .rebuild, generation: generation)
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()
        sessionRebuildInFlight = false
        expectsMessagesResponse = false
        receivedStateResponse = false
        receivedStatsResponse = false
        receivedMessagesResponse = false
        runtimeReady = false
        phase = .failed
        runOutcome = .failed
        terminalRunStatus = .failed
        runSettlementHandled = true
        setActivity(nil)
        lastError = message
    }
}
