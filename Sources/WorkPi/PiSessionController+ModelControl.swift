import Foundation
import PiRPC

/// 模型与推理强度的可用列表拉取和切换。
///
/// 可用集合完全来自 Pi：模型来自 `get_available_models`，推理级别来自
/// `get_available_thinking_levels`。客户端不写死级别全集，因为 `xhigh` 与 `max`
/// 只在部分模型上暴露；换模型后必须重新拉取级别。
///
/// 切换成功后不在本地推断新状态，而是重新读取 `get_state`，让 HUD 始终显示
/// Pi 的事实。
extension PiSessionController {
    /// Runtime 就绪后拉取一次可用模型与当前模型支持的推理级别。
    func requestModelCatalog() {
        requestAvailableModels()
        requestAvailableThinkingLevels()
    }

    func requestAvailableModels() {
        guard let transport, runtimeReady, !availableModelsRequestInFlight else { return }

        let command = PiRPCCommand.getAvailableModels()
        availableModelsRequestInFlight = true
        activeAvailableModelsCommandID = command.id
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
                self.availableModelsRequestInFlight = false
                _ = self.settleRuntimeRequest(id: self.activeAvailableModelsCommandID)
                self.activeAvailableModelsCommandID = nil
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = "无法读取可用模型：\(safeError)"
                self.noteAuthenticationFailure(safeError)
            }
        }
    }

    func requestAvailableThinkingLevels() {
        guard let transport, runtimeReady, !thinkingLevelsRequestInFlight else { return }

        let command = PiRPCCommand.getAvailableThinkingLevels()
        thinkingLevelsRequestInFlight = true
        activeAvailableThinkingLevelsCommandID = command.id
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
                self.thinkingLevelsRequestInFlight = false
                _ = self.settleRuntimeRequest(id: self.activeAvailableThinkingLevelsCommandID)
                self.activeAvailableThinkingLevelsCommandID = nil
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = "无法读取可用推理强度：\(safeError)"
                self.noteAuthenticationFailure(safeError)
            }
        }
    }

    /// 切换模型。已是当前模型时不发命令。
    func selectModel(provider: String, modelID: String) {
        guard !runtimeAuthenticationChanged else {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；模型切换未发送。"
            return
        }
        guard !modelSwitchInFlight, !isRuntimeTransitioning else { return }
        if metadataMatchesModel(provider: provider, modelID: modelID) { return }
        guard let transport, runtimeReady else {
            lastError = "Pi Runtime 尚未就绪，无法切换模型。"
            return
        }

        modelSwitchInFlight = true
        let command = PiRPCCommand.setModel(provider: provider, modelID: modelID)
        activeModelCommandID = command.id
        registerRuntimeRequest(
            command,
            purpose: .operation,
            timeout: .seconds(30)
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
                self.modelSwitchInFlight = false
                _ = self.settleRuntimeRequest(id: self.activeModelCommandID)
                self.activeModelCommandID = nil
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = "无法切换模型：\(safeError)"
                self.noteAuthenticationFailure(safeError)
            }
        }
    }

    /// 切换推理强度。模型不支持推理时拒绝，避免无效往返。
    func selectThinkingLevel(_ level: String) {
        guard !runtimeAuthenticationChanged else {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；推理强度切换未发送。"
            return
        }
        guard !thinkingLevelSwitchInFlight, !isRuntimeTransitioning else { return }
        guard level != runtimeMetadata.thinkingLevel else { return }
        guard supportsThinkingLevelSelection else {
            lastError = "当前模型不支持切换推理强度。"
            return
        }
        guard let transport, runtimeReady else {
            lastError = "Pi Runtime 尚未就绪，无法切换推理强度。"
            return
        }

        thinkingLevelSwitchInFlight = true
        let command = PiRPCCommand.setThinkingLevel(level)
        activeThinkingLevelCommandID = command.id
        registerRuntimeRequest(
            command,
            purpose: .operation,
            timeout: .seconds(30)
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
                self.thinkingLevelSwitchInFlight = false
                _ = self.settleRuntimeRequest(id: self.activeThinkingLevelCommandID)
                self.activeThinkingLevelCommandID = nil
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = "无法切换推理强度：\(safeError)"
                self.noteAuthenticationFailure(safeError)
            }
        }
    }

    /// 只有拿到 Pi 明确的 `reasoning` 标记且级别多于一个时才允许切换。
    var supportsThinkingLevelSelection: Bool {
        guard runtimeMetadata.modelSupportsReasoning != false else { return false }
        return availableThinkingLevels.count > 1
    }

    // MARK: - 响应处理

    func consumeModelControlResponse(_ record: PiRPCRecord) -> Bool {
        guard !shouldIgnoreRuntimeResponse(record) else { return true }
        switch record.command {
        case "get_available_models":
            guard let activeID = activeAvailableModelsCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = runtimeRequest(
                for: record,
                command: "get_available_models",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: "get_available_models",
                purposes: [.operation]
            ) else { return false }
            availableModelsRequestInFlight = false
            if let request { _ = settleRuntimeRequest(request) }
            activeAvailableModelsCommandID = nil
            if let models = record.availableModels {
                availableModels = models
            }
            return true

        case "get_available_thinking_levels":
            guard let activeID = activeAvailableThinkingLevelsCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = runtimeRequest(
                for: record,
                command: "get_available_thinking_levels",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: "get_available_thinking_levels",
                purposes: [.operation]
            ) else { return false }
            thinkingLevelsRequestInFlight = false
            if let request { _ = settleRuntimeRequest(request) }
            activeAvailableThinkingLevelsCommandID = nil
            if let levels = record.availableThinkingLevels {
                availableThinkingLevels = levels
            } else if record.success == true {
                // Pi 对无推理能力的模型返回 ["off"]；解析为空说明确实没有可选项。
                availableThinkingLevels = []
            }
            return true

        case "set_model", "cycle_model":
            guard let activeID = activeModelCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = runtimeRequest(
                for: record,
                command: record.command ?? "set_model",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: record.command ?? "set_model",
                purposes: [.operation]
            ) else { return false }
            modelSwitchInFlight = false
            if let request { _ = settleRuntimeRequest(request) }
            activeModelCommandID = nil
            if record.success == true {
                applyModelChange(from: record)
            }
            return true

        case "set_thinking_level", "cycle_thinking_level":
            guard let activeID = activeThinkingLevelCommandID,
                  record.id == nil || record.id == activeID
            else { return false }
            let request = runtimeRequest(
                for: record,
                command: record.command ?? "set_thinking_level",
                purposes: [.operation]
            )
            guard request != nil || !hasRuntimeRequest(
                for: record.command ?? "set_thinking_level",
                purposes: [.operation]
            ) else { return false }
            thinkingLevelSwitchInFlight = false
            if let request { _ = settleRuntimeRequest(request) }
            activeThinkingLevelCommandID = nil
            if record.success == true {
                if let level = record.cycledThinkingLevel {
                    runtimeMetadata.thinkingLevel = level
                }
                refreshRuntimeState()
            }
            return true

        default:
            return false
        }
    }

    /// 切模型会同时改变上下文窗口与推理能力，因此必须重新拉级别和状态。
    private func applyModelChange(from record: PiRPCRecord) {
        if let name = record.modelName {
            runtimeMetadata.modelName = name
        }
        if let identity = record.modelIdentity {
            runtimeMetadata.modelProvider = identity.provider
            runtimeMetadata.modelID = identity.id
        }
        if let reasoning = record.modelSupportsReasoning {
            runtimeMetadata.modelSupportsReasoning = reasoning
        }
        availableThinkingLevels = []
        thinkingLevelsRequestInFlight = false
        requestAvailableThinkingLevels()
        refreshRuntimeState()
    }

    /// 切换后以 Pi 的 `get_state` 为准回填 HUD，不在本地推断。
    func refreshRuntimeState() {
        guard let transport, runtimeReady else { return }
        let generation = self.generation
        let stateCommand = PiRPCCommand.getState()
        let statsCommand = PiRPCCommand.getSessionStats()
        registerRuntimeRequest(
            stateCommand,
            purpose: .refresh,
            timeout: .seconds(20)
        )
        registerRuntimeRequest(
            statsCommand,
            purpose: .refresh,
            timeout: .seconds(20)
        )
        Task { [weak self] in
            do {
                guard let self else { return }
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
            } catch {
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: stateCommand.id)
                _ = self.settleRuntimeRequest(id: statsCommand.id)
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = "无法刷新 Runtime 状态：\(safeError)"
                self.noteAuthenticationFailure(safeError)
            }
        }
    }

    private func metadataMatchesModel(provider: String, modelID: String) -> Bool {
        runtimeMetadata.modelProvider == provider && runtimeMetadata.modelID == modelID
    }
}
