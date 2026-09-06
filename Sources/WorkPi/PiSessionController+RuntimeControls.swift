import Foundation
import PiRPC

/// 自动重试控制与 `/status` 的 Runtime 快照查询。
///
/// `set_auto_retry` 与 `abort_retry` 都是普通 RPC 操作；它们不复用完整
/// `abort` 的回合收束路径，尤其不能把“取消退避等待”误记成“停止 Agent”。
extension PiSessionController {
    var canSetAutoRetry: Bool {
        runtimeReady
            && !runtimeAuthenticationChanged
            && !runtimeSettlementQuarantined
            && activeAutoRetryCommandID == nil
    }

    var isSettingAutoRetry: Bool {
        activeAutoRetryCommandID != nil
    }

    var canAbortRetry: Bool {
        runtimeReady
            && retryWaitState != nil
            && activeAbortRetryCommandID == nil
            && activeAbortRetryWaitID == nil
            && !runtimeTerminationHandled
    }

    var isAbortingRetry: Bool {
        activeAbortRetryCommandID != nil || activeAbortRetryWaitID != nil
    }

    func resetRuntimeStatusState() {
        runtimeStatusSnapshot = nil
        runtimeStatusPanelPresented = false
        runtimeStatusLoading = false
        runtimeStatusPanelError = nil
        turnRecords.removeAll()
        activeTurnRecordID = nil
        retryWaitState = nil
        autoRetryEnabled = nil
        runtimeControlError = nil
        activeRuntimeStatusRequestID = nil
        activeAutoRetryCommandID = nil
        pendingAutoRetryValue = nil
        activeAbortRetryCommandID = nil
        activeAbortRetryWaitID = nil
    }

    func presentStatusPanel(commandItemID: UUID? = nil) {
        runtimeStatusPanelPresented = true
        runtimeStatusPanelError = nil
        runtimeStatusLoading = true
        requestRuntimeStatus()
        requestSessionStats(commandItemID: commandItemID)
    }

    func refreshStatusPanel() {
        guard runtimeStatusPanelPresented else { return }
        runtimeStatusPanelError = nil
        runtimeStatusLoading = true
        requestRuntimeStatus()
        requestSessionStats()
    }

    func dismissStatusPanel() {
        cancelRuntimeRequests(purpose: .status, generation: generation)
        activeRuntimeStatusRequestID = nil
        activeStatsCommandID = nil
        activeStatsRequestIDs.removeAll()
        statsRequestItemIDs.removeAll()
        statsCommandItemID = nil
        sessionStats = nil
        runtimeStatusSnapshot = nil
        runtimeStatusPanelPresented = false
        runtimeStatusLoading = false
        runtimeStatusPanelError = nil
    }

    func requestRuntimeStatus() {
        guard let transport, runtimeReady, !runtimeSettlementQuarantined else {
            runtimeStatusLoading = false
            runtimeStatusPanelError = "Pi Runtime 尚未就绪。"
            return
        }

        if let previousID = activeRuntimeStatusRequestID {
            _ = settleRuntimeRequest(id: previousID)
        }
        let command = PiRPCCommand.getState()
        activeRuntimeStatusRequestID = command.id
        registerRuntimeRequest(command, purpose: .status, timeout: .seconds(20))
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
                      !self.runtimeTerminationHandled,
                      self.activeRuntimeStatusRequestID == command.id
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                self.activeRuntimeStatusRequestID = nil
                self.runtimeStatusLoading = false
                self.runtimeStatusPanelError = WorkPiSensitiveText.redacted(
                    "无法获取 Runtime 状态：\(error.localizedDescription)"
                )
            }
        }
    }

    func setAutoRetry(enabled: Bool) {
        guard canSetAutoRetry, let transport else { return }
        let command = PiRPCCommand.setAutoRetry(enabled: enabled)
        activeAutoRetryCommandID = command.id
        pendingAutoRetryValue = enabled
        runtimeControlError = nil
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(20))
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
                      self.activeAutoRetryCommandID == command.id,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                self.activeAutoRetryCommandID = nil
                self.pendingAutoRetryValue = nil
                self.runtimeControlError = WorkPiSensitiveText.redacted(
                    "设置自动重试失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func abortRetry() {
        guard canAbortRetry, let transport, let wait = retryWaitState else { return }
        let command = PiRPCCommand.abortRetry()
        activeAbortRetryCommandID = command.id
        activeAbortRetryWaitID = wait.id
        runtimeControlError = nil
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(20))
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
                      self.activeAbortRetryCommandID == command.id,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                self.activeAbortRetryCommandID = nil
                self.activeAbortRetryWaitID = nil
                self.runtimeControlError = WorkPiSensitiveText.redacted(
                    "取消自动重试失败：\(error.localizedDescription)"
                )
            }
        }
    }

    /// 消费 `/status` 专用的 `get_state` 响应；不能让它推进启动握手标记。
    func consumeRuntimeStatusResponse(_ record: PiRPCRecord) -> Bool {
        guard record.command == "get_state",
              let request = runtimeRequest(
                  for: record,
                  command: "get_state",
                  purposes: [.status]
              )
        else { return false }
        _ = settleRuntimeRequest(request)
        guard activeRuntimeStatusRequestID == request.id else { return true }
        activeRuntimeStatusRequestID = nil
        runtimeStatusLoading = false
        guard record.success == true else {
            runtimeStatusPanelError = WorkPiSensitiveText.redacted(
                record.string(at: "error") ?? "Runtime 状态获取失败。"
            )
            return true
        }
        runtimeStatusSnapshot = WorkPiRuntimeStatusSnapshot(
            modelName: record.modelName,
            modelProvider: record.modelIdentity?.provider,
            modelID: record.modelIdentity?.id,
            thinkingLevel: record.thinkingLevel,
            isStreaming: record.stateIsStreaming,
            isCompacting: record.stateIsCompacting,
            steeringMode: record.stateSteeringMode,
            followUpMode: record.stateFollowUpMode,
            sessionID: record.stateSessionID,
            sessionFile: record.sessionFilePath,
            sessionName: record.sessionName,
            messageCount: record.messageCount,
            pendingMessageCount: record.statePendingMessageCount,
            autoCompactionEnabled: record.autoCompactionEnabled,
            sampledAt: Date()
        )
        runtimeStatusPanelError = nil
        return true
    }

    /// 消费两个设置命令的成功/失败响应。两者都不改变 Agent 回合状态。
    func consumeRuntimeControlResponse(_ record: PiRPCRecord) -> Bool {
        guard record.command == "set_auto_retry" || record.command == "abort_retry",
              let request = runtimeRequest(
                  for: record,
                  command: record.command ?? "",
                  purposes: [.operation]
              )
        else { return false }
        _ = settleRuntimeRequest(request)
        let message = WorkPiSensitiveText.redacted(
            record.string(at: "error") ?? "Pi 拒绝了 Runtime 控制请求。"
        )
        if record.command == "set_auto_retry" {
            guard activeAutoRetryCommandID == request.id else { return true }
            activeAutoRetryCommandID = nil
            if record.success == true {
                autoRetryEnabled = pendingAutoRetryValue
                runtimeControlError = nil
            } else {
                runtimeControlError = message
            }
            pendingAutoRetryValue = nil
        } else {
            guard activeAbortRetryCommandID == request.id else { return true }
            activeAbortRetryCommandID = nil
            if record.success == true {
                // 等待 `auto_retry_end` 才清除 waiting token；成功响应本身只
                // 说明 Pi 接受了取消请求，不能提前伪造回合终态。
                runtimeControlError = nil
            } else {
                activeAbortRetryWaitID = nil
                runtimeControlError = message
            }
        }
        return true
    }
}
