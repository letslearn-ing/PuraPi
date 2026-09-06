import Foundation
import PiDomain
import PiRPC

/// 会话统计（`/status`）。
///
/// 结果用独立面板展示而不是塞进 HUD：HUD 是常驻状态条，放详细统计会挤爆它；
/// 而统计是用户主动查询的一次性信息，与 shell 执行块同类。
extension PiSessionController {
    func requestSessionStats(commandItemID: UUID? = nil) {
        guard let transport, runtimeReady, !runtimeSettlementQuarantined else {
            if let commandItemID {
                updateConversation(id: commandItemID) { item in
                    item.status = .failed
                    item.detail = "Pi Runtime 尚未就绪。"
                }
            }
            return
        }

        let command = PiRPCCommand.getSessionStats()
        activeStatsCommandID = command.id
        if let commandID = command.id {
            activeStatsRequestIDs.insert(commandID)
            if let commandItemID {
                statsRequestItemIDs[commandID] = commandItemID
            }
        }
        statsCommandItemID = commandItemID
        if let commandItemID {
            updateConversation(id: commandItemID) { item in item.status = .streaming }
        }
        registerRuntimeRequest(
            command,
            purpose: .status,
            itemID: commandItemID,
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
                self.activeStatsRequestIDs.remove(command.id ?? "")
                self.statsRequestItemIDs.removeValue(forKey: command.id ?? "")
                if self.activeStatsCommandID == command.id {
                    self.activeStatsCommandID = nil
                    self.statsCommandItemID = nil
                }
                if let commandItemID {
                    self.updateConversation(id: commandItemID) { item in
                        item.status = .failed
                        item.detail = "无法获取统计：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
                    }
                }
            }
        }
    }

    /// 返回 true 表示该响应已由统计逻辑消费。
    ///
    /// 注意不能拦截所有 `get_session_stats`：HUD 的上下文数值也靠它刷新，
    /// 只有 `/status` 主动发起的那次才归这里。
    func consumeSessionStatsResponse(_ record: PiRPCRecord) -> Bool {
        guard record.command == "get_session_stats" else { return false }
        guard !shouldIgnoreRuntimeResponse(record) else { return false }

        // 无 id 响应只有在整个当前 generation 中不存在其它同命令候选时才
        // 能安全归给 `/status`。只看 `.status` 候选会把 bootstrap/refresh
        // 的无 id 响应误认成用户主动查询，进而污染握手状态。
        let allCandidates = runtimeRequestCandidates(for: "get_session_stats")
        let request: PuraPiRuntimeRequest?
        if let responseID = record.id {
            request = allCandidates.first {
                $0.id == responseID && $0.purpose == .status
            }
        } else if allCandidates.count == 1,
                  allCandidates[0].purpose == .status {
            request = allCandidates[0]
        } else {
            request = nil
        }

        if let request {
            _ = settleRuntimeRequest(request)
        } else if !allCandidates.isEmpty {
            // 该响应可能属于 bootstrap/refresh，交给 Runtime 响应分流；若
            // 同时有多个请求且没有 id，则保守忽略，不能猜测归属。
            return false
        } else {
            // 兼容只在测试或旧调用方手动设置 activeStatsCommandID 的路径；
            // 有明确的其它 id 时仍必须拒绝，避免迟到响应清掉当前查询。
            guard let activeID = activeStatsCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
        }

        let requestID = request?.id ?? record.id ?? activeStatsCommandID
        if let requestID {
            activeStatsRequestIDs.remove(requestID)
            statsRequestItemIDs.removeValue(forKey: requestID)
        }
        if activeStatsCommandID == requestID || request == nil {
            activeStatsCommandID = nil
            let itemID = request?.itemID ?? statsCommandItemID
            statsCommandItemID = nil
            return consumeStatsResult(record, itemID: itemID)
        }
        return consumeStatsResult(record, itemID: request?.itemID)
    }

    private func consumeStatsResult(
        _ record: PiRPCRecord,
        itemID: UUID?
    ) -> Bool {

        guard record.success == true, let payload = record.sessionStats else {
            let message = PuraPiSensitiveText.redacted(
                record.string(at: "error") ?? "统计获取失败。"
            )
            noteAuthenticationFailure(message)
            if let itemID {
                updateConversation(id: itemID) { item in
                    item.status = .failed
                    item.detail = message
                }
            }
            return true
        }
        sessionStats = PiSessionStats(
            sessionID: payload.sessionID,
            sessionFile: payload.sessionFile,
            userMessages: payload.userMessages,
            assistantMessages: payload.assistantMessages,
            toolCalls: payload.toolCalls,
            toolResults: payload.toolResults,
            totalMessages: payload.totalMessages,
            inputTokens: payload.inputTokens,
            outputTokens: payload.outputTokens,
            cacheReadTokens: payload.cacheReadTokens,
            cacheWriteTokens: payload.cacheWriteTokens,
            totalTokens: payload.totalTokens,
            cost: payload.cost,
            contextTokens: payload.contextTokens,
            contextWindow: payload.contextWindow,
            contextPercent: payload.contextPercent
        )
        if let itemID {
            updateConversation(id: itemID) { item in
                item.status = .completed
                item.detail = "统计已更新"
            }
        }
        return true
    }

    func dismissSessionStats() {
        sessionStats = nil
    }
}
