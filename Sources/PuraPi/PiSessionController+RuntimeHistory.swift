import Foundation
import PiRPC

/// Runtime 启动/重建期间的历史快照映射与恢复超时。
extension PiSessionController {
    /// 在后台线程完成历史显示映射，避免大 Session 阻塞 AppKit 主线程。
    func beginHistoryMapping(from responseData: JSONValue?, generation: UUID) {
        historyMappingTask?.cancel()
        let mappingID = UUID()
        historyMappingRequestID = mappingID
        let budget = PiSessionHistoryDisplayBudget.restoredSession
        historyMappingTask = Task { [weak self] in
            let mapped = await Task.detached(priority: .utility) {
                PiSessionHistoryMapper.conversation(from: responseData, budget: budget)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.generation == generation,
                  self.historyMappingRequestID == mappingID,
                  !self.runtimeTerminationHandled
            else { return }
            self.historyMappingTask = nil
            let preservedCommand = self.preservedConversationItemForRestore
            self.conversation = mapped
            if let preservedCommand {
                self.conversation.insert(preservedCommand, at: 0)
                self.preservedConversationItemForRestore = nil
            }
            self.receivedMessagesResponse = true
            self.markRuntimeReadyIfBootstrapped()
            // 会话树双击某一轮触发的切换：历史已就位，现在才能定位。
            if let pending = self.pendingTurnLocation {
                self.pendingTurnLocation = nil
                self.locateTurn(matching: pending)
            }
        }
    }

    /// 恢复必须有明确终态；不能让 UI 永久停留在 loading。
    func scheduleRestoreTimeout(for generation: UUID) {
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self,
                  self.generation == generation,
                  self.expectsMessagesResponse,
                  self.recentSessionRestoreState == .loading
            else { return }
            self.failRecentSessionRestore(
                message: "最近会话恢复超时。请重试；Pi Runtime 的历史读取没有在规定时间内完成。"
            )
        }
    }

    func failRecentSessionRestore(
        message: String = "Pi 没有完成最近会话恢复。"
    ) {
        guard expectsMessagesResponse else { return }
        cancelRuntimeRequests(purpose: .bootstrap, generation: generation)
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
        historyMappingTask?.cancel()
        historyMappingTask = nil
        historyMappingRequestID = UUID()
        recentSessionRestoreState = .failed
        runtimeReady = false
        receivedStateResponse = false
        receivedStatsResponse = false
        receivedMessagesResponse = false
        phase = .failed
        runOutcome = .failed
        terminalRunStatus = .failed
        runtimeStatus = "最近会话恢复失败"
        runSettlementHandled = true
        setActivity(nil)
        lastError = message
    }
}
