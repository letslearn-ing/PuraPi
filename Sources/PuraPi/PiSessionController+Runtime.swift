import Foundation
import PiDomain
import PiRPC

/// Pi Runtime 生命周期、RPC 事件映射和对话状态收敛。
///
/// `message_end`、retry/compaction 失败和用户 abort 决定回合终态；
/// `agent_settled` 只结束运行生命周期，不能覆盖失败或取消。
extension PiSessionController {
    func restartRuntime(
        for workspaceURL: URL,
        launchMode: PiRuntimeLaunchMode,
        preservedConversationItem: ConversationItem? = nil,
        preservedRuntimeNotice: String? = nil
    ) {
        let oldTransport = transport
        // 重新连接会让新 Pi 进程重新读取官方 auth.json。
        runtimeAuthenticationChanged = false
        let pendingRuntimeStopTask = runtimeStopTask
        let pendingRuntimeStartTask = runtimeStartTask
        let pendingExtensionRequestIDs = drainPendingExtensionUIRequests()
        cancelAllRuntimeRequests()
        var effectiveRuntimeNotice = preservedRuntimeNotice
        if launchMode.requiresMessageRestore {
            // continue 仍属于同一项目的恢复意图，保留尚未确认的队列任务。
            restoreActiveQueuedPrompt()
        } else {
            // fresh Session 不得把旧 Session 的队列、Composer 附件或 in-flight
            // Prompt 发送过去；丢弃前留下可见说明，而不是静默消失。
            let queuedCount = queuedPrompts.count + (activeQueuedPrompt == nil ? 0 : 1)
            let attachmentCount = pendingAttachments.count
            queuedPrompts.removeAll()
            pendingAttachments.removeAll()
            if queuedCount > 0 || attachmentCount > 0 {
                let parts = [
                    queuedCount > 0 ? "排队任务 \(queuedCount) 条" : nil,
                    attachmentCount > 0 ? "附件 \(attachmentCount) 个" : nil,
                ].compactMap { $0 }
                effectiveRuntimeNotice = effectiveRuntimeNotice
                    ?? "新会话不会发送旧会话的\(parts.joined(separator: "、"))。"
            } else if activeQueuedPrompt != nil {
                effectiveRuntimeNotice = effectiveRuntimeNotice
                    ?? "新会话不会发送旧会话中尚未确认的排队任务。"
            }
            discardActiveQueuedPrompt()
            revokeUnusedMarkdownApprovalTokens()
            composerCloseBlocked = false
        }
        // 旧 Prompt 尚未得到 Pi 接受确认；重启不能把它误记为 Agent 已知。
        discardActiveMarkdownDiff()
        // 重启 Runtime 会使旧的直接 bash 失去归属，但不能把正在执行的
        // 命令静默从 UI 删除；先留下明确的 cancelled 终态，用户可稍后手动清理。
        for index in bashExecutions.indices where bashExecutions[index].isRunning {
            bashExecutions[index].state = .cancelled
        }
        bashAbortRequested = false
        activeBashAbortCommandID = nil
        resetActivityState()
        preservedConversationItemForRestore = preservedConversationItem
        generation = UUID()
        sessionEpoch = UUID()
        idlessResponseQuarantine.removeAll()
        retiredRuntimeRequestIDs.removeAll()
        ambiguousRuntimeRequestIDs.removeAll()
        runtimeRequestSessionEpochs.removeAll()
        let runtimeGeneration = generation

        // Runtime 重启会切换 generation；同步重建 FSEvents 监视器，避免
        // 新 Runtime 下的磁盘变化继续携带旧 generation 而被丢弃。
        monitorTask?.cancel()
        monitorTask = nil
        monitor?.stop()
        monitor = nil
        // Runtime generation 切换时，旧代际的目录刷新任务不能继续占用
        // treeRefreshTask 槽位；否则新监视器收到文件事件后可能只把目录加入
        // 旧任务的 pending 集合，最终表现为 /continue 后文件树偶发不刷新。
        treeRefreshTask?.cancel()
        treeRefreshTask = nil
        pendingTreeRefreshDirectories.removeAll()
        pendingDirectoryLoads.removeAll()
        startFileMonitor(for: workspaceURL, generation: runtimeGeneration)

        runtimeStartTask?.cancel()
        runtimeStartTask = nil
        eventTask?.cancel()
        eventTask = nil
        runtimeDiagnostic = nil
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingAssistantText = ""
        pendingThinkingText = ""
        // continue/reconnect 保留尚未确认的附件；fresh Session 明确切换上下文，
        // 不把旧 Prompt 的附件带入新会话。
        if launchMode.requiresMessageRestore {
            restoreActivePromptAttachments()
        } else {
            discardActivePromptAttachments()
        }
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        activeAgentRunID = nil
        activeAgentRunStarted = false
        cancelledAgentRunID = nil
        abortRequestedRunID = nil
        runSettlementPending = false
        runtimeSettlementQuarantined = false
        ignoreSettledUntilAgentStart = false
        sessionRebuildInFlight = false
        extensionNotifications.removeAll()
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        resetSubagentPanelState()
        // The old response write remains part of the stop barrier; its task
        // clears this flag only after the transport send has finished.
        completedExtensionUIRequestIDs.removeAll()
        completedExtensionUIRequestOrder.removeAll()
        commandsRequestInFlight = false
        activeCommandsRequestID = nil
        piCommands.removeAll()
        currentAssistantItemID = nil
        currentThinkingItemID = nil
        toolItemIDs.removeAll()
        activePromptCommandID = nil
        activePromptResponseAccepted = false
        activePromptInspectorChange = nil
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil
        activeAbortCommandItemID = nil
        activeAbortCommandID = nil
        abortRequestedRunID = nil
        activeBashAbortCommandID = nil
        bashAbortRequested = false
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
        sessionStats = nil
        resetRuntimeStatusState()
        conversationScrollTarget = nil
        pendingTurnLocation = nil
        resetModelControlState()
        runOutcome = .completed
        runSettlementHandled = false
        abortRequested = false
        abortRequestedRunID = nil
        activeAgentRunID = nil
        activeAgentRunStarted = false
        cancelledAgentRunID = nil
        runSettlementPending = false
        runtimeSettlementQuarantined = false
        ignoreSettledUntilAgentStart = false
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        terminalRunStatus = nil
        runtimeTerminationHandled = false
        runtimeReady = false
        receivedStateResponse = false
        receivedStatsResponse = false
        if launchMode.requiresMessageRestore {
            recentSessionRestoreState = .loading
        }
        receivedMessagesResponse = !launchMode.requiresMessageRestore
        expectsMessagesResponse = launchMode.requiresMessageRestore
        processExitObserved = false
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()
        if launchMode.requiresMessageRestore {
            conversation = []
        } else {
            conversation = preservedConversationItem.map { [$0] } ?? []
            preservedConversationItemForRestore = nil
        }
        runtimeMetadata = AgentRuntimeMetadata()
        lastError = nil
        runtimeNotice = effectiveRuntimeNotice
        phase = .preparing
        runtimeStatus = launchMode.requiresMessageRestore
            ? "正在继续最近会话…"
            : "正在启动 Pi Runtime…"
        // 恢复历史会话可能耗时较长，需要给用户可见反馈；
        // 普通启动很快完成，不显示指示器避免闪一下。
        setActivity(launchMode.requiresMessageRestore ? .restoringSession : nil)
        transport = nil

        if let stop = scheduleRuntimeStop(
            pending: pendingRuntimeStopTask,
            transport: oldTransport,
            startTask: pendingRuntimeStartTask,
            extensionRequestIDs: pendingExtensionRequestIDs
        ) {
            startRuntimeAfterStop(
                stop,
                workspaceURL: workspaceURL,
                generation: runtimeGeneration,
                launchMode: launchMode
            )
        } else {
            startRuntime(
                for: workspaceURL,
                generation: runtimeGeneration,
                launchMode: launchMode
            )
        }
    }

    func startRuntime(
        for workspaceURL: URL,
        generation: UUID,
        launchMode: PiRuntimeLaunchMode
    ) {
        guard self.generation == generation else { return }
        // 同一 generation 已经有当前 transport 时，重复的生命周期回调不能
        // 替换它并遗留一个无法归属的旧进程；真正重启必须先走 restartRuntime。
        guard transport == nil else { return }
        if let pendingRuntimeStopTask = runtimeStopTask,
           let runtimeStopToken {
            startRuntimeAfterStop(
                (token: runtimeStopToken, task: pendingRuntimeStopTask),
                workspaceURL: workspaceURL,
                generation: generation,
                launchMode: launchMode
            )
            return
        }
        let newTransport = makeTransport(launchMode)
        transport = newTransport
        runtimeAuthenticationChanged = false
        runtimeProvisioningRequired = false
        runtimeReady = false
        receivedStateResponse = false
        receivedStatsResponse = false
        if launchMode.requiresMessageRestore {
            recentSessionRestoreState = .loading
        }
        receivedMessagesResponse = !launchMode.requiresMessageRestore
        expectsMessagesResponse = launchMode.requiresMessageRestore
        sessionRebuildInFlight = false
        processExitObserved = false
        runtimeTerminationHandled = false
        runtimeDiagnostic = nil
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()
        terminalRunStatus = nil
        activeAgentRunID = nil
        activeAgentRunStarted = false
        cancelledAgentRunID = nil
        abortRequestedRunID = nil
        runSettlementPending = false
        runtimeSettlementQuarantined = false
        ignoreSettledUntilAgentStart = false
        runSettlementTimeoutTask?.cancel()
        runSettlementTimeoutTask = nil
        runOutcome = .completed
        runSettlementHandled = false
        phase = .preparing

        let stateCommand = PiRPCCommand.getState()
        let statsCommand = PiRPCCommand.getSessionStats()
        let messagesCommand = launchMode.requiresMessageRestore
            ? PiRPCCommand.getMessages()
            : nil
        registerRuntimeRequest(
            stateCommand,
            purpose: .bootstrap,
            timeout: .seconds(20)
        )
        registerRuntimeRequest(
            statsCommand,
            purpose: .bootstrap,
            timeout: .seconds(20)
        )
        if let messagesCommand {
            registerRuntimeRequest(
                messagesCommand,
                purpose: .bootstrap,
                timeout: .seconds(25)
            )
        }

        let startTask = Task { [weak self] in
            defer {
                if let self, self.generation == generation {
                    self.runtimeStartTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let stream = try await newTransport.start(in: workspaceURL)
                guard !Task.isCancelled,
                      let self,
                      self.generation == generation else {
                    // 生命周期调用方已经把该 transport 登记到 stop barrier；
                    // 这里不能再次 stop，尤其不能在 Fake transport 复用时误停新代。
                    return
                }
                let eventTask = Task { [weak self] in
                    do {
                        for try await event in stream {
                            guard !Task.isCancelled else { break }
                            self?.consume(event, generation: generation)
                        }
                        guard !Task.isCancelled else { return }
                        self?.handleTransportEOF(generation: generation)
                    } catch {
                        self?.handleTransportError(error, generation: generation)
                    }
                }
                self.eventTask = eventTask
                try await self.sendRuntimeCommand(
                    stateCommand,
                    using: newTransport,
                    generation: generation
                )
                try await self.sendRuntimeCommand(
                    statsCommand,
                    using: newTransport,
                    generation: generation
                )
                if let messagesCommand {
                    scheduleRestoreTimeout(for: generation)
                    try await self.sendRuntimeCommand(
                        messagesCommand,
                        using: newTransport,
                        generation: generation
                    )
                }
                guard self.generation == generation else { return }
            } catch {
                self?.handleTransportError(error, generation: generation)
            }
        }
        runtimeStartTask = startTask
    }

    func consume(_ event: PiRPCTransportEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .record(let record):
            consume(record)
        case .diagnostic(let text):
            guard !runtimeTerminationHandled else { return }
            // stderr 只作为诊断摘要；运行中的 Agent 状态不能被普通警告覆盖。
            let trimmed = PuraPiSensitiveText.redacted(
                text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            rememberRuntimeDiagnostic(trimmed)
            if !trimmed.isEmpty, phase == .preparing || phase == .idle {
                runtimeStatus = "Pi：\(trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed)"
            }
        case .processExited(let status):
            handleRuntimeTermination(
                .processExited(status),
                generation: generation
            )
        case .processExitedWithDiagnostic(let status, let diagnostic):
            handleRuntimeTermination(
                .processExitedWithDiagnostic(status, diagnostic),
                generation: generation
            )
        }
    }

    func consume(_ record: PiRPCRecord) {
        guard !runtimeTerminationHandled,
              !(expectsMessagesResponse
                && recentSessionRestoreState == .failed
                && !sessionRebuildInFlight)
        else { return }
        if runtimeSettlementQuarantined && activeAgentRunID == nil {
            switch record.type {
            case "agent_start", "message_start", "message_update", "message_end",
                 "tool_execution_start", "tool_execution_update", "tool_execution_end",
                 "agent_end", "auto_retry_start", "auto_retry_end",
                 "turn_start", "turn_end",
                 "compaction_start", "compaction_end",
                 "summarization_retry_scheduled", "summarization_retry_attempt_start",
                 "summarization_retry_finished":
                // 请求确认或 settled 超时后，任何没有当前 run 归属的事件都
                // 可能来自旧 Prompt；先等 settled 解除隔离。
                return
            default:
                break
            }
        }
        switch record.type {
        case "turn_start":
            consumeTurnStart(record)
        case "turn_end":
            consumeTurnEnd(record)
        case "response":
            consumeResponse(record)
        case "agent_start":
            guard !runSettlementHandled,
                  !runSettlementPending,
                  runOutcome != .cancelled,
                  !(runOutcome == .failed && terminalRunStatus == .failed)
            else { break }
            _ = ensureAgentRun()
            activeAgentRunStarted = true
            ignoreSettledUntilAgentStart = false
            runOutcome = .running
            phase = .requesting
            runtimeStatus = "Agent 正在处理…"
            setActivity(.waitingForModel)
        case "message_start":
            guard !runSettlementHandled,
                  runOutcome != .cancelled,
                  !(runOutcome == .failed && terminalRunStatus == .failed)
            else { break }
            guard resumeAgentRunForLateMessage() else { break }
            activeAgentRunStarted = true
            if record.messageRole == "assistant" {
                _ = ensureAgentRun()
                ensureAssistantItem()
                if phase != .streaming { phase = .streaming }
            }
        case "message_update":
            guard !runSettlementHandled,
                  runOutcome != .cancelled,
                  !(runOutcome == .failed && terminalRunStatus == .failed)
            else { break }
            guard resumeAgentRunForLateMessage() else { break }
            activeAgentRunStarted = true
            if let delta = record.textDelta {
                ensureAssistantItem()
                pendingAssistantText.append(delta)
                if phase != .streaming { phase = .streaming }
                setActivity(.responding)
                scheduleStreamingFlush()
            }
            if let delta = record.thinkingDelta {
                ensureThinkingItem()
                pendingThinkingText.append(delta)
                if phase != .streaming { phase = .streaming }
                setActivity(.thinking)
                scheduleStreamingFlush()
            }
        case "message_end":
            // abort response 或 agent_settled 已经收束后，Provider 可能仍把一条
            // 迟到的 message_end 写入 stdout；不能因此重新创建一个空的 Assistant 行。
            guard !runSettlementHandled,
                  currentAssistantItemID != nil || runOutcome == .running || abortRequested
            else {
                break
            }
            guard resumeAgentRunForLateMessage() else { break }
            activeAgentRunStarted = true
            flushStreamingBuffers()
            consumeAssistantMessageEnd(record)
        case "tool_execution_start":
            guard !runSettlementHandled, !runSettlementPending else { break }
            _ = ensureAgentRun()
            activeAgentRunStarted = true
            // Abort 与 RPC 事件可能并发到达：已经由 Pi 发出的工具开始事件
            // 不能被静默丢弃，否则用户只看到 Assistant 状态而看不到被停止的工具。
            // 终态屏障只阻止它重新把 Runtime 切回 executingTool。
            let id = record.toolCallID ?? UUID().uuidString
            guard toolItemIDs[id] == nil else { break }
            let isCancelled = currentAgentRunWasCancelled()
            let isFailed = runOutcome == .failed && terminalRunStatus == .failed
            let item = ConversationItem(
                kind: .tool,
                title: record.toolName ?? "tool",
                text: isCancelled ? "已停止" : (isFailed ? "执行失败" : "执行中…"),
                detail: formattedArguments(record.value(at: "args")),
                status: isCancelled ? .cancelled : (isFailed ? .failed : .streaming)
            )
            toolItemIDs[id] = item.id
            appendConversation(item)
            if !isCancelled && !isFailed {
                phase = .executingTool
                setActivity(.runningTool(name: record.toolName))
            }
        case "tool_execution_update":
            guard !runSettlementHandled,
                  !runSettlementPending,
                  !currentAgentRunWasCancelled()
            else { break }
            activeAgentRunStarted = true
            updateTool(record)
        case "tool_execution_end":
            guard !runSettlementHandled, !runSettlementPending else { break }
            activeAgentRunStarted = true
            updateTool(record, completed: true)
        case "agent_end":
            guard !runSettlementHandled,
                  !runSettlementPending,
                  runOutcome != .cancelled,
                  !(runOutcome == .failed && terminalRunStatus == .failed)
            else { break }
            activeAgentRunStarted = true
            phase = .settling
            markRunAwaitingSettlement()
        case "agent_settled":
            if ignoreSettledUntilAgentStart {
                // quarantine 解除后，新 Prompt 可能已经写入 stdin，但在收到
                // `agent_start` 前无法证明这条 settled 属于新回合；保守丢弃。
                guard activeAgentRunID != nil, activeAgentRunStarted else { break }
                ignoreSettledUntilAgentStart = false
            }
            if runtimeSettlementQuarantined, activeAgentRunID == nil {
                // 这是 settlement 超时后到达的旧终态；只解除隔离，不能
                // 让它结算一个不存在的或未来的 Agent run。
                runtimeSettlementQuarantined = false
                ignoreSettledUntilAgentStart = true
                if runOutcome == .cancelled {
                    if runtimeReady {
                        phase = .idle
                        runtimeStatus = "Agent 已停止"
                        clearRuntimeNotice()
                    } else {
                        // 失联 Runtime 即使收到了迟到 settled，也不能回到
                        // idle；否则用户会失去唯一的 reconnect 入口。
                        phase = .failed
                        runtimeStatus = "Pi Runtime 不可用"
                        runtimeNotice = "Agent 已停止，但 Pi Runtime 已退出。请重新连接后再发送。"
                    }
                }
                if !queuedPrompts.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.dispatchNextQueuedPromptIfNeeded()
                    }
                }
                return
            }
            guard !runSettlementHandled,
                  activeAgentRunID != nil,
                  activeAgentRunStarted
            else { break }
            flushStreamingBuffers()
            // 回合结束：无论成功、失败还是取消，活动指示必须消失。
            setActivity(nil)
            let wasCancelled = currentAgentRunWasCancelled()
            let failed = !wasCancelled && (runOutcome == .failed || terminalRunStatus == .failed)
            if failed {
                runOutcome = .failed
                phase = .failed
                runtimeStatus = runtimeReady ? "Agent 执行失败" : "Pi Runtime 不可用"
            } else {
                if !wasCancelled {
                    runOutcome = .completed
                }
                phase = .idle
                runtimeStatus = runtimeReady
                    ? (wasCancelled ? "Agent 已停止" : "Pi Runtime 已连接")
                    : "Pi Runtime 不可用"
            }
            if bashActivityActive {
                runtimeStatus = "正在执行命令…"
            }
            refreshRuntimeMetadata()
            runtimeSettlementQuarantined = false
            ignoreSettledUntilAgentStart = false
            finalizeCurrentItemsAfterSettled(wasCancelled: wasCancelled, failed: failed)
            // 回合结束后自动接上下一条待执行任务。
            //
            // 放到下一个主线程循环：此时 phase 已经落定，否则
            // `isAgentBusy` 仍会读到旧值而拒绝发送。
            if !wasCancelled, !queuedPrompts.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.dispatchNextQueuedPromptIfNeeded()
                }
            }
        case "auto_retry_start":
            guard !runSettlementHandled,
                  runOutcome != .cancelled
            else { break }
            activeAgentRunStarted = true
            runSettlementPending = false
            runSettlementTimeoutTask?.cancel()
            runSettlementTimeoutTask = nil
            _ = ensureAgentRun()
            runOutcome = .running
            terminalRunStatus = nil
            retryWaitState = PuraPiRetryWaitState(
                id: UUID(),
                attempt: record.retryAttempt,
                maxAttempts: record.retryMaxAttempts,
                delayMilliseconds: record.retryDelayMilliseconds,
                startedAt: Date()
            )
            activeAbortRetryCommandID = nil
            activeAbortRetryWaitID = nil
            phase = .settling
            runtimeStatus = "正在重试…"
            setActivity(.retrying(
                attempt: record.retryAttempt,
                maxAttempts: record.retryMaxAttempts
            ))
        case "auto_retry_end":
            consumeRetryEnd(record)
        case "compaction_start":
            guard !runSettlementHandled, runOutcome != .cancelled else { break }
            activeAgentRunStarted = true
            runSettlementPending = false
            runSettlementTimeoutTask?.cancel()
            runSettlementTimeoutTask = nil
            phase = .settling
            runtimeStatus = "正在压缩上下文…"
            // Pi 在自动压缩时给出 `reason`；manual 以外都归为自动。
            setActivity(.compacting(
                isAutomatic: (record.string(at: "reason") ?? "manual") != "manual"
            ))
        case "compaction_end":
            consumeCompactionEnd(record)
        case "summarization_retry_scheduled", "summarization_retry_attempt_start":
            guard !runSettlementHandled, runOutcome != .cancelled else { break }
            activeAgentRunStarted = true
            runSettlementPending = false
            runSettlementTimeoutTask?.cancel()
            runSettlementTimeoutTask = nil
            phase = .settling
            runtimeStatus = "上下文摘要正在重试…"
            setActivity(.summarizing)
        case "summarization_retry_finished":
            guard !runSettlementHandled, runOutcome != .cancelled else { break }
            runtimeStatus = "Agent 正在处理…"
            setActivity(.waitingForModel)
        case "extension_error":
            let message = PuraPiSensitiveText.redacted(
                record.eventErrorMessage ?? "Pi Extension 运行失败"
            )
            lastError = message
            noteAuthenticationFailure(message)
        case "extension_ui_request":
            handleExtensionUIRequest(record)
        case "bash_execution_update":
            _ = consumeBashOutputEvent(record)
        default:
            // 未知事件按 I-05 忽略，不中断 Runtime。
            break
        }
    }

    func markRuntimeReadyIfBootstrapped() {
        guard receivedStateResponse,
              receivedStatsResponse,
              receivedMessagesResponse
        else { return }
        let wasSessionRebuild = sessionRebuildInFlight
        runtimeReady = true
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
        if expectsMessagesResponse {
            // 无论是 `--continue` 还是会话切换后的重建，消息快照已经
            // 明确落地；空历史也不应再次显示“继续最近会话”入口。
            recentSessionRestoreState = .loaded
        }
        if wasSessionRebuild {
            sessionRebuildInFlight = false
            expectsMessagesResponse = false
            runSettlementHandled = false
        }
        // Runtime 就绪：恢复会话的指示到此结束。
        if activity == .restoringSession {
            setActivity(nil)
        }
        // 启动阶段的诊断只服务于本次握手；连接成功后不应污染下一次错误。
        runtimeDiagnostic = nil
        if phase == .preparing {
            phase = .idle
            runtimeStatus = wasSessionRebuild
                ? "会话已重新加载"
                : (recentSessionRestoreState == .loaded
                    ? "已继续最近会话"
                    : "Pi Runtime 已连接")
        }
        requestPiCommands()
        requestModelCatalog()
        if wasSessionRebuild {
            presentNextExtensionUIDialog(after: generation)
        }
        reloadSessionList()
        if !wasSessionRebuild, !queuedPrompts.isEmpty {
            // Runtime 失联时保留的任务在重新连接后继续等待发送；延后一轮，
            // 确保启动握手已完成且 `isAgentBusy` 读到空闲状态。
            DispatchQueue.main.async { [weak self] in
                self?.dispatchNextQueuedPromptIfNeeded()
            }
        }
    }

    func requestPiCommands() {
        guard let transport,
              runtimeReady,
              !commandsRequestInFlight
        else { return }

        let command = PiRPCCommand.getCommands()
        commandsRequestInFlight = true
        activeCommandsRequestID = command.id
        registerRuntimeRequest(
            command,
            purpose: .operation,
            timeout: .seconds(20)
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
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                self.commandsRequestInFlight = false
                self.activeCommandsRequestID = nil
                self.piCommands.removeAll()
                self.lastError = "无法读取 Pi 命令目录：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    func finishAbort(commandItemID: UUID?) {
        let resolvedCommandItemID = commandItemID ?? activeAbortCommandItemID
        runOutcome = .cancelled
        runtimeSettlementQuarantined = false
        abortRequested = true
        terminalRunStatus = .cancelled
        lastError = nil
        clearRuntimeNotice()
        if let resolvedCommandItemID {
            updateConversation(id: resolvedCommandItemID) { item in
                item.status = .cancelled
                item.detail = "Agent 已停止"
            }
        }
        abortTimeoutTask?.cancel()
        abortTimeoutTask = nil
        activeAbortCommandID = nil
        activeAbortCommandItemID = nil
        flushStreamingBuffers()
        finalizeCurrentItemsAfterSettled(wasCancelled: true, failed: false)
        setActivity(nil)
        phase = .idle
        runtimeStatus = bashActivityActive
            ? "正在执行命令…"
            : (runtimeReady ? "Agent 已停止" : "Pi Runtime 不可用")
        lastError = nil
    }

    /// 停止请求不能无限期把 Composer 留在“正在停止”状态；Pi 正常情况下会在
    /// `abort` response 前等待 Agent 空闲，这个超时只覆盖 Runtime 失联或协议异常。
    func scheduleAbortTimeout(
        for generation: UUID,
        timeout: Duration = .seconds(15)
    ) {
        abortTimeoutTask?.cancel()
        abortTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                  self.generation == generation,
                  self.activeAbortCommandID != nil
            else { return }
            let commandItemID = self.activeAbortCommandItemID
            _ = self.settleRuntimeRequest(id: self.activeAbortCommandID)
            self.abortTimeoutTask = nil
            self.abortRequested = false
            self.runOutcome = .failed
            self.terminalRunStatus = .failed
            self.phase = .failed
            self.runtimeStatus = "停止请求超时"
            self.lastError = "Pi Runtime 没有在规定时间内确认停止请求。"
            // abort 响应丢失时，远端仍可能继续发出旧回合事件；在 settled
            // 或 Runtime 换代前不得让用户重试并接收这些事件。
            self.runtimeSettlementQuarantined = true
            self.updateConversation(id: commandItemID) { item in
                item.status = .failed
                item.detail = "停止请求超时"
            }
            self.markCurrentAssistant(status: .failed)
            self.finalizeCurrentItemsAfterSettled(
                wasCancelled: false,
                failed: true
            )
            self.setActivity(nil)
        }
    }

}
