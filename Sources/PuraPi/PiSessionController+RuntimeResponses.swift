import Foundation
import PiDomain
import PiRPC

/// Runtime response（响应）与 request registry 的关联处理。
extension PiSessionController {
    func consumeResponse(_ record: PiRPCRecord) {
        if shouldIgnoreRuntimeResponse(record) {
            // 超时或主动取消后的响应已经退休；必须等 generation 变化后再接受
            // 同类无 id 响应，避免迟到旧结果越过请求边界。
            return
        }
        // 模型与推理级别的响应（含失败分支）统一由 ModelControl 消费，
        // 避免 in-flight 标记在失败时永久卡住。
        if record.command == "set_model"
            || record.command == "cycle_model"
            || record.command == "set_thinking_level"
            || record.command == "cycle_thinking_level"
            || record.command == "get_available_models"
            || record.command == "get_available_thinking_levels" {
            let isCurrentRequest = consumeModelControlResponse(record)
            if isCurrentRequest, record.success == false {
                let message = PuraPiSensitiveText.redacted(
                    record.string(at: "error") ?? "Pi 拒绝了模型或推理级别请求。"
                )
                lastError = message
                noteAuthenticationFailure(message)
            }
            return
        }

        if consumeRuntimeStatusResponse(record) { return }
        if consumeRuntimeControlResponse(record) { return }
        if consumeExportResponse(record) { return }
        if consumeAutoCompactionResponse(record) { return }
        if consumeBashResponse(record) { return }
        if consumeSessionStatsResponse(record) { return }

        // 会话树类命令（切换/分叉/复制/命名）同样需要在失败时清掉
        // in-flight 标记，否则按钮会永久卡在禁用状态。
        if record.command == "switch_session"
            || record.command == "fork"
            || record.command == "clone"
            || record.command == "set_session_name" {
            let isCurrentRequest = consumeSessionTreeResponse(record)
            if isCurrentRequest, record.success == false {
                let message = PuraPiSensitiveText.redacted(
                    record.string(at: "error") ?? "Pi 拒绝了会话操作。"
                )
                lastError = message
                noteAuthenticationFailure(message)
            }
            return
        }

        if record.success == true {
            switch record.command {
            case "get_state":
                guard let request = runtimeRequest(
                    for: record,
                    command: "get_state",
                    purposes: [.bootstrap, .refresh, .rebuild]
                ) else { break }
                _ = settleRuntimeRequest(request)
                // 重建期间旧 generation 内的其它请求即使已经在传输层排队，
                // 也不能改写当前会话身份或 Runtime 元数据。
                guard !(sessionRebuildInFlight && request.purpose != .rebuild),
                      !(sessionOperationInFlight && request.purpose != .rebuild)
                else { break }
                updateRuntimeMetadata(from: record)
                updateActiveSessionIdentity(from: record)
                receivedStateResponse = true
                markRuntimeReadyIfBootstrapped()
            case "get_session_stats":
                // `/status` 请求由专用逻辑先消费；其余统计响应必须命中
                // bootstrap/refresh/rebuild 的登记项，不能用旧响应推进握手。
                if consumeSessionStatsResponse(record) { break }
                // 无 id 时若同时存在 `/status` 候选，无法安全判断归属，
                // 宁可等待带 id 的响应，也不能把状态面板响应当成 HUD 刷新。
                guard !(record.id == nil && hasRuntimeRequest(
                    for: "get_session_stats",
                    purposes: [.status]
                )) else { break }
                guard let request = runtimeRequest(
                    for: record,
                    command: "get_session_stats",
                    purposes: [.bootstrap, .refresh, .rebuild]
                ) else { break }
                _ = settleRuntimeRequest(request)
                guard !(sessionRebuildInFlight && request.purpose != .rebuild),
                      !(sessionOperationInFlight && request.purpose != .rebuild)
                else { break }
                updateRuntimeMetadata(from: record)
                receivedStatsResponse = true
                markRuntimeReadyIfBootstrapped()
            case "get_messages":
                guard let request = runtimeRequest(
                    for: record,
                    command: "get_messages",
                    purposes: [.bootstrap, .rebuild]
                ) else { break }
                // 历史映射异步进行；请求本身在响应到达时已经完成。
                _ = settleRuntimeRequest(request)
                beginHistoryMapping(from: record.responseData, generation: generation)
            case "get_commands":
                guard let activeID = activeCommandsRequestID,
                      record.id == nil || record.id == activeID,
                      let request = runtimeRequest(
                          for: record,
                          command: "get_commands",
                          purposes: [.operation]
                      )
                else { break }
                _ = settleRuntimeRequest(request)
                commandsRequestInFlight = false
                activeCommandsRequestID = nil
                piCommands = record.commandInfos ?? []
            case "prompt", "steer", "follow_up":
                let request = runtimeRequest(
                    for: record,
                    command: record.command ?? "prompt",
                    purposes: [.operation]
                )
                let isLegacyNormalPrompt = request == nil
                    && !hasRuntimeRequest(for: "prompt", purposes: [.operation])
                    && record.command == "prompt"
                    && activePromptCommandID != nil
                    && record.id == nil
                    && !activePromptResponseAccepted
                guard request != nil || isLegacyNormalPrompt else { break }
                if let request {
                    _ = settleRuntimeRequest(request)
                    if record.id == nil { idlessResponseQuarantine.insert("prompt") }
                    if request.id == activePromptCommandID {
                        activePromptResponseAccepted = true
                        // 只有 Pi 明确接受 prompt 后才推进 Markdown 协作基线；
                        // 写入失败/超时/取消都由失败路径保留 pending 快照。
                        acknowledgeActiveMarkdownDiff()
                        discardActivePromptAttachments()
                        discardActiveQueuedPrompt()
                    }
                    let wasStartedWhileBusy = commandStartedWhileBusy[request.id] == true
                    if let commandItemID = activeCommandItemIDs.removeValue(forKey: request.id) {
                        activeCommandSources.removeValue(forKey: request.id)
                        commandStartedWhileBusy.removeValue(forKey: request.id)
                        updateConversation(id: commandItemID) { item in
                            item.status = .completed
                            item.detail = "Pi 已接受命令"
                        }
                    } else if let itemID = request.itemID {
                        updateConversation(id: itemID) { item in
                            if item.status == .pending {
                                item.status = .completed
                                item.detail = "Pi 已接受命令"
                            }
                        }
                    }
                    if wasStartedWhileBusy, activeAgentRunID == nil {
                        // 旧回合可能已经先收到 agent_settled；该命令的后续
                        // Agent 事件属于新回合，不能继续受旧终态屏障拦截。
                        runSettlementHandled = false
                        terminalRunStatus = nil
                        runOutcome = .running
                    }
                } else {
                    idlessResponseQuarantine.insert("prompt")
                    activePromptResponseAccepted = true
                    // 兼容没有 request id 的旧版 Pi：命中当前 Prompt 响应时，
                    // 同样把已接受的 Markdown 快照推进基线。
                    acknowledgeActiveMarkdownDiff()
                    discardActivePromptAttachments()
                }
            case "compact":
                if let activeID = activeCompactRPCID,
                   record.id == nil || record.id == activeID {
                    let request = runtimeRequest(
                        for: record,
                        command: "compact",
                        purposes: [.operation]
                    )
                    guard request != nil || !hasRuntimeRequest(
                        for: "compact",
                        purposes: [.operation]
                    ) else { break }
                    if let commandItemID = activeCompactCommandItemID {
                        updateConversation(id: commandItemID) { item in
                            item.status = .streaming
                            item.detail = "Pi 已接受压缩请求"
                        }
                    }
                    // 保留 request id，直到 compaction_end；这样 response 与事件
                    // 的先后顺序变化时仍能正确关联同一次压缩。
                }
            case "abort":
                guard let abortID = activeAbortCommandID,
                      record.id == nil || record.id == abortID
                else {
                    break
                }
                let request = settleRuntimeRequest(
                    for: record,
                    command: "abort",
                    purposes: [.operation]
                )
                guard request != nil || !hasRuntimeRequest(
                    for: "abort",
                    purposes: [.operation]
                ) else { break }
                finishAbort(commandItemID: activeAbortCommandItemID)

            default:
                break
            }
            return
        }

        guard record.success == false else { return }

        let message = PuraPiSensitiveText.redacted(
            record.string(at: "error") ?? "Pi RPC 命令失败"
        )
        noteAuthenticationFailure(message)

        if record.command == "get_commands" {
            guard let activeID = activeCommandsRequestID,
                  record.id == nil || record.id == activeID,
                  let request = runtimeRequest(
                      for: record,
                      command: "get_commands",
                      purposes: [.operation]
                  )
            else { return }
            _ = settleRuntimeRequest(request)
            // 命令发现是可选能力；失败不应让已连接 Runtime 进入失败态。
            commandsRequestInFlight = false
            activeCommandsRequestID = nil
            piCommands.removeAll()
            return
        }

        if record.command == "prompt"
            || record.command == "steer"
            || record.command == "follow_up" {
            let request = runtimeRequest(
                for: record,
                command: record.command ?? "prompt",
                purposes: [.operation]
            )
            let legacyNormalPrompt = request == nil
                && !hasRuntimeRequest(for: "prompt", purposes: [.operation])
                && record.command == "prompt"
                && activePromptCommandID != nil
                && record.id == nil
                && !activePromptResponseAccepted
            guard let request = request ?? (legacyNormalPrompt
                ? PuraPiRuntimeRequest(
                    registrationID: UUID(),
                    id: activePromptCommandID ?? "",
                    command: "prompt",
                    purpose: .operation,
                    generation: generation,
                    sessionEpoch: sessionEpoch,
                    itemID: nil,
                    queuedPrompt: nil
                )
                : nil)
            else { return }
            _ = settleRuntimeRequest(request)
            if record.id == nil { idlessResponseQuarantine.insert("prompt") }

            if request.id == activePromptCommandID {
                activePromptResponseAccepted = true
                discardActiveMarkdownDiff()
                restoreActivePromptAttachments()
                lastError = message
                runtimeStatus = "指令未被 Pi 接受"
                runOutcome = .failed
                phase = .failed
                terminalRunStatus = .failed
                markCurrentAssistant(status: .failed)
                activePromptCommandID = nil
                setActivity(nil)
                finalizeCurrentItemsAfterSettled(wasCancelled: false, failed: true)
            } else if let commandItemID = activeCommandItemIDs.removeValue(forKey: request.id) {
                let wasBusy = commandStartedWhileBusy.removeValue(forKey: request.id) ?? false
                activeCommandSources.removeValue(forKey: request.id)
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = message
                }
                if !wasBusy { runtimeStatus = "命令未被 Pi 接受" }
                lastError = message
            }
            return
        }

        if record.command == "compact" {
            guard let activeID = activeCompactRPCID,
                  record.id == nil || record.id == activeID,
                  let request = runtimeRequest(
                      for: record,
                      command: "compact",
                      purposes: [.operation]
                  )
            else {
                // compaction_end 可能先于 response 到达；完成后的响应是迟到确认，
                // 不能再次清除终态屏障。
                return
            }
            _ = settleRuntimeRequest(request)
            if isNothingToCompactMessage(message) {
                finishCompactionAsNoOp(message: message)
                return
            }
            if let commandItemID = activeCompactCommandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = message
                }
            }
            activeCompactCommandItemID = nil
            activeCompactRPCID = nil
            runOutcome = .failed
            phase = .failed
            runtimeStatus = "上下文压缩请求失败"
            runSettlementHandled = true
            setActivity(nil)
            lastError = message
            return
        }

        if record.command == "get_state"
            || record.command == "get_session_stats"
            || record.command == "get_messages" {
            guard !(record.command == "get_session_stats"
                && record.id == nil
                && hasRuntimeRequest(
                    for: "get_session_stats",
                    purposes: [.status]
                )) else { return }
            let purposes: Set<PuraPiRuntimeRequestPurpose> =
                record.command == "get_messages"
                    ? [.bootstrap, .rebuild]
                    : [.bootstrap, .refresh, .rebuild]
            guard let request = runtimeRequest(
                for: record,
                command: record.command ?? "",
                purposes: purposes
            ) else { return }
            _ = settleRuntimeRequest(request)
            guard !(sessionRebuildInFlight && request.purpose != .rebuild) else { return }
            if request.purpose == .refresh {
                // 状态/统计刷新是校正信息；单次失败不代表 Runtime 已断开，
                // 不能把可继续对话的连接误标成 failed。
                lastError = message
                return
            }
            runtimeReady = false
            if request.purpose == .rebuild {
                failSessionRebuild(message: message)
            } else if request.purpose == .bootstrap, expectsMessagesResponse {
                failRecentSessionRestore(message: message)
            } else {
                runtimeStatus = "Pi Runtime 初始化失败"
                phase = .failed
                runOutcome = .failed
                terminalRunStatus = .failed
                runSettlementHandled = true
                setActivity(nil)
                lastError = message
            }
            return
        }

        if record.command == "abort",
           let abortID = activeAbortCommandID,
           (record.id == nil || record.id == abortID) {
            guard runtimeRequest(
                for: record,
                command: "abort",
                purposes: [.operation]
            ) != nil else { return }
            _ = settleRuntimeRequest(
                for: record,
                command: "abort",
                purposes: [.operation]
            )
            finishAbortFailure(message: message)
        }
    }
}
