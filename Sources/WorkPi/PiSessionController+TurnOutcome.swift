import Foundation
import PiDomain
import PiRPC

/// 回合终态收敛：assistant 消息结束、自动重试与压缩的收尾。
///
/// 这些路径共同决定一个回合是完成、失败还是取消。它们与 Runtime 生命周期
/// （见 `PiSessionController+Runtime.swift`）共享同一个 `generation`，
/// 用来丢弃旧 Runtime 的迟到事件。
extension PiSessionController {
    func consumeAssistantMessageEnd(_ record: PiRPCRecord) {
        guard !runSettlementHandled,
              record.messageRole == "assistant"
        else { return }
        _ = ensureAgentRun()
        activeAgentRunStarted = true
        ensureAssistantItem()

        let stopReason = record.messageStopReason
        let abortError = record.messageErrorMessage.map(isAbortMessage) ?? false
        let normalizedStopReason = stopReason?.lowercased()
        let providerCancelled = normalizedStopReason == "aborted"
            || normalizedStopReason == "cancelled"
            || normalizedStopReason == "canceled"
        let wasCancelled = currentAgentRunWasCancelled() || abortError || providerCancelled
        let status: ConversationItem.Status
        if wasCancelled {
            if let activeAgentRunID {
                cancelledAgentRunID = activeAgentRunID
            }
            // 用户取消优先于 stopReason 的具体编码。不同 Pi/provider 版本可能
            // 把 abort 表达成 `aborted`、`error` 或普通 `stop`，UI 语义都必须是“已停止”。
            status = .cancelled
            runOutcome = .cancelled
            terminalRunStatus = .cancelled
            phase = .cancelled
            runtimeStatus = "Agent 已停止"
            setActivity(nil)
            lastError = nil
        } else if stopReason == "error"
                    || runOutcome == .failed
                    || terminalRunStatus == .failed {
            status = .failed
            runOutcome = .failed
            terminalRunStatus = .failed
            phase = .failed
            let message = WorkPiSensitiveText.redacted(
                record.messageErrorMessage
                    ?? lastError
                    ?? "Agent 返回了错误响应。"
            )
            lastError = message
            noteAuthenticationFailure(message)
            runtimeStatus = "Agent 执行失败"
            setActivity(nil)
        } else {
            status = .completed
            if runOutcome == .running {
                runOutcome = .completed
            }
        }

        updateConversation(id: currentAssistantItemID) { item in
            if let text = record.messageText {
                item.text = text
            }
            item.status = status
        }
        if let contextTokens = record.messageContextTokens,
           let contextWindow = runtimeMetadata.contextWindow,
           contextWindow > 0 {
            var metadata = runtimeMetadata
            metadata.contextTokens = contextTokens
            metadata.contextPercent = Double(contextTokens) / Double(contextWindow) * 100
            runtimeMetadata = metadata
        }
        if let thinkingID = currentThinkingItemID {
            updateConversation(id: thinkingID) { item in item.status = status }
        }

        // 工具调用结束后的 assistant turn 必须单独创建，不能拼到上一轮。
        if stopReason == "toolUse" || stopReason == "tool_use" {
            currentAssistantItemID = nil
            currentThinkingItemID = nil
        } else {
            // `agent_settled` 仍可能稍后到达；在此期间禁止启动新回合，
            // 防止迟到的 settled 事件收束错误的 Assistant。
            markRunAwaitingSettlement()
        }
    }

    func consumeRetryEnd(_ record: PiRPCRecord) {
        guard !runSettlementHandled else { return }
        _ = ensureAgentRun()
        activeAgentRunStarted = true
        let retryWaitID = retryWaitState?.id
        retryWaitState = nil
        if activeAbortRetryWaitID == retryWaitID || retryWaitID == nil {
            _ = settleRuntimeRequest(id: activeAbortRetryCommandID)
            activeAbortRetryCommandID = nil
            activeAbortRetryWaitID = nil
        }

        if record.retrySucceeded == false {
            let message = WorkPiSensitiveText.redacted(
                record.retryErrorMessage ?? "Pi 自动重试失败。"
            )
            let wasCancelled = message.localizedCaseInsensitiveContains("retry cancelled")
                || message.localizedCaseInsensitiveContains("retry canceled")
            if wasCancelled {
                if let activeAgentRunID {
                    cancelledAgentRunID = activeAgentRunID
                }
                runOutcome = .cancelled
                lastError = nil
                terminalRunStatus = .cancelled
                phase = .cancelled
                runtimeStatus = "自动重试已取消"
                markCurrentAssistant(status: .cancelled)
                setActivity(nil)
            } else {
                noteAuthenticationFailure(message)
                runOutcome = .failed
                lastError = message
                terminalRunStatus = .failed
                runtimeStatus = "自动重试失败"
                markCurrentAssistant(status: .failed)
                setActivity(nil)
            }
            // Pi 通常随后会发 agent_settled；在它缺失时也保留终态屏障，
            // 并阻止用户在旧 settled 到达前开启新回合。
            markRunAwaitingSettlement()
            runSettlementHandled = false
        } else if runOutcome != .cancelled && runOutcome != .failed {
            runOutcome = .running
            terminalRunStatus = nil
            runtimeStatus = "Agent 正在处理…"
        }
    }

    /// 收束一次压缩。
    ///
    /// 手动压缩**不会**发出 `agent_settled`（真实 Pi 实测：`compaction_start`、
    /// `compaction_end`、`response` 三条即结束）。而 `setActivity(nil)` 主要挂在
    /// `agent_settled` 上，因此这里每条终态分支都必须自己清活动指示，
    /// 否则转圈动画与计时器会一直跑下去。
    func consumeCompactionEnd(_ record: PiRPCRecord) {
        guard !runSettlementHandled else { return }
        if let message = record.eventErrorMessage {
            let message = WorkPiSensitiveText.redacted(message)
            noteAuthenticationFailure(message)
            // Pi 用错误信息表达两种「无需压缩」：已经压过，以及会话太小。
            // 两者都不是故障，不能让界面显示失败。
            if isNothingToCompactMessage(message) {
                finishCompactionAsNoOp(message: message)
                return
            }
            runOutcome = .failed
            terminalRunStatus = .failed
            lastError = message
            phase = .failed
            runtimeStatus = "上下文压缩失败"
            markCurrentAssistant(status: .failed)
            if let commandItemID = activeCompactCommandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = message
                }
            }
            _ = settleRuntimeRequest(id: activeCompactRPCID)
            activeCompactCommandItemID = nil
            activeCompactRPCID = nil
            finalizeCurrentItemsAfterSettled(
                wasCancelled: false,
                failed: true
            )
            setActivity(nil)
        } else if record.compactionAborted {
            runOutcome = .cancelled
            terminalRunStatus = .cancelled
            // 手动压缩没有后续 agent_settled；操作已结束，不能把 Composer
            // 永久留在“正在停止”的 cancelled 阶段。
            phase = .idle
            runtimeStatus = "上下文压缩已取消"
            if let commandItemID = activeCompactCommandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .cancelled
                    item.detail = "压缩已取消"
                }
            }
            _ = settleRuntimeRequest(id: activeCompactRPCID)
            activeCompactCommandItemID = nil
            activeCompactRPCID = nil
            runSettlementHandled = true
            setActivity(nil)
        } else if record.compactionWillRetry {
            // 溢出触发的压缩成功后 Pi 会自动重试原 prompt，回合还没结束，
            // 活动指示要留着，由后续的 agent_settled 收束。
            runtimeStatus = "上下文已压缩，正在重试…"
        } else {
            let manualCompaction = activeCompactCommandItemID != nil
            runtimeStatus = manualCompaction
                ? "上下文压缩完成"
                : (phase == .settling ? "Agent 正在处理…" : "Pi Runtime 已连接")
            if let commandItemID = activeCompactCommandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .completed
                    item.detail = "上下文压缩完成"
                }
                _ = settleRuntimeRequest(id: activeCompactRPCID)
                activeCompactCommandItemID = nil
                activeCompactRPCID = nil
                phase = .idle
                runOutcome = .completed
                runSettlementHandled = true
            }
            // 自动压缩发生在回合内部，之后还有模型输出；只有手动压缩到这里就结束了。
            if manualCompaction {
                setActivity(nil)
            }
        }
    }

    /// Pi 表示「无需压缩」的两种说法。
    ///
    /// 实测 Pi 0.84.1 对上下文过小返回：
    /// `Compaction failed: Nothing to compact (session too small)`
    /// 这是幂等确认而非故障，按失败处理会让用户以为出错了。
    func isNothingToCompactMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("already compacted")
            || message.localizedCaseInsensitiveContains("nothing to compact")
    }

    func finishCompactionAsNoOp(message: String? = nil) {
        let manualCompaction = activeCompactCommandItemID != nil
        // 区分两种「无需压缩」，否则用户会困惑于「我明明没压过」。
        let tooSmall = message.map {
            $0.localizedCaseInsensitiveContains("nothing to compact")
        } ?? false
        let detail = tooSmall
            ? "当前上下文还很小，不需要压缩"
            : "当前会话已经压缩，无需重复操作"
        if let commandItemID = activeCompactCommandItemID {
            updateConversation(id: commandItemID) { item in
                item.status = .completed
                item.detail = detail
            }
        }
        _ = settleRuntimeRequest(id: activeCompactRPCID)
        activeCompactCommandItemID = nil
        activeCompactRPCID = nil
        if manualCompaction {
            runOutcome = .completed
            terminalRunStatus = nil
            runSettlementHandled = true
            phase = .idle
            runtimeStatus = runtimeReady ? detail : "Pi Runtime 不可用"
            setActivity(nil)
        } else {
            // 自动压缩属于当前 Agent 回合内部的步骤；“无需压缩”不能把
            // 回合伪造为 completed，也不能提前清掉模型活动。
            runtimeStatus = "Agent 正在处理…"
        }
        // 这是 Pi 对当前 Session 的幂等确认，不是 Runtime 错误。
        lastError = nil
    }

}
