import AppKit
import Foundation
import PiDomain
import PiRPC

/// 直接执行 shell 命令（`bash` / `abort_bash`）。
///
/// 语义与工具调用不同：输出不会立刻进入模型上下文。Pi 先存为
/// `BashExecutionMessage`，等下一次 `prompt` 时才转成用户消息一起发给模型。
/// 因此可以连续跑多条命令，输出全部累积。
extension PiSessionController {
    /// 本地 Bash 输出上限；Pi 的完整截断日志仍可通过 fullOutputPath 打开。
    static let maximumBashOutputBytes = 2 * 1024 * 1024

    /// 是否有命令正在运行。用于决定是否显示中止入口。
    var hasRunningBashExecution: Bool {
        bashExecutions.contains { $0.isRunning }
    }

    /// 执行一条 shell 命令。
    @discardableResult
    func runBashCommand(_ rawCommand: String) -> Bool {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return false }
        guard let transport,
              runtimeReady,
              !sessionRebuildInFlight,
              phase != .cancelled,
              phase != .settling,
              !runSettlementPending,
              !runtimeSettlementQuarantined
        else {
            lastError = "Pi Runtime 正在切换或停止，暂时无法执行命令。"
            return false
        }

        // 新的独立 Bash 任务开始后，之前 Agent 的取消不再能解释未来的
        // Runtime 退出；Bash 自己的运行结果必须按失败/取消单独判定。
        cancelledAgentRunID = nil
        let rpcCommand = PiRPCCommand.bash(command)
        let id = rpcCommand.id ?? UUID().uuidString
        registerRuntimeRequest(rpcCommand, purpose: .operation, timeout: .seconds(120))
        bashExecutions.append(BashExecution(id: id, command: command))
        if agentActivity == nil {
            runtimeStatus = "正在执行命令…"
        }
        setBashActivity(true)

        let generation = self.generation
        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.sendRuntimeCommand(
                    rpcCommand,
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
                _ = self.settleRuntimeRequest(id: rpcCommand.id)
                let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
                self.finishBashExecution(
                    id: id,
                    state: .rejected(message: safeError)
                )
                self.lastError = "无法执行命令：\(safeError)"
            }
        }
        return true
    }

    /// 中止正在运行的命令。
    func abortBashCommand() {
        guard let transport,
              hasRunningBashExecution,
              activeBashAbortCommandID == nil,
              !bashAbortRequested
        else { return }
        let command = PiRPCCommand.abortBash()
        bashAbortRequested = true
        activeBashAbortCommandID = command.id
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
                guard let self, self.generation == generation else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                _ = self.settleRuntimeRequest(id: command.id)
                self.activeBashAbortCommandID = nil
                self.bashAbortRequested = false
                guard !self.runtimeTerminationHandled else { return }
                self.lastError = "无法中止命令：\(WorkPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    /// 消费 `bash_execution_update`：把输出增量追加到对应的执行块。
    ///
    /// 返回 true 表示事件已消费。
    func consumeBashOutputEvent(_ record: PiRPCRecord) -> Bool {
        guard let delta = record.bashOutputDelta else { return false }
        // 没有 id 时无法归属，只能忽略；Pi 对 bash 事件总是带 id。
        guard let id = record.id,
              let index = bashExecutions.firstIndex(where: { $0.id == id }),
              bashExecutions[index].isRunning
        else { return true }
        guard !bashExecutions[index].outputTruncated else { return true }
        let bounded = appendBashOutput(
            delta,
            to: bashExecutions[index].output
        )
        bashExecutions[index].output = bounded.text
        bashExecutions[index].outputTruncated = bounded.wasTruncated
        return true
    }

    /// 消费 `bash` / `abort_bash` 的响应。
    func consumeBashResponse(_ record: PiRPCRecord) -> Bool {
        guard !shouldIgnoreRuntimeResponse(record) else { return true }
        switch record.command {
        case "bash":
            let request = runtimeRequest(
                for: record,
                command: "bash",
                purposes: [.operation]
            )
            let id = record.id ?? request?.id
            guard let id,
                  let index = bashExecutions.firstIndex(where: { $0.id == id }),
                  bashExecutions[index].isRunning
            else { return true }
            if let request { _ = settleRuntimeRequest(request) }
            guard record.success == true else {
                finishBashExecution(
                    id: id,
                    state: .rejected(message: WorkPiSensitiveText.redacted(
                        record.string(at: "error") ?? "命令未被执行。"
                    ))
                )
                return true
            }
            // 以响应里的完整输出为准：事件流可能因截断而与它不一致。
            if let index = bashExecutions.firstIndex(where: { $0.id == id }) {
                if let output = record.bashOutput {
                    let bounded = boundedBashOutput(output)
                    bashExecutions[index].output = bounded.text
                    bashExecutions[index].outputTruncated =
                        bashExecutions[index].outputTruncated
                        || record.bashOutputTruncated
                        || bounded.wasTruncated
                } else {
                    bashExecutions[index].outputTruncated =
                        bashExecutions[index].outputTruncated || record.bashOutputTruncated
                }
                bashExecutions[index].fullOutputPath = record.bashFullOutputPath
            }
            if record.bashWasCancelled {
                finishBashExecution(id: id, state: .cancelled)
            } else {
                // 非零退出码仍是 success: true——命令执行成功但返回失败。
                finishBashExecution(id: id, state: .finished(exitCode: record.bashExitCode ?? 0))
            }
            return true

        case "abort_bash":
            // Pi 允许省略响应 id；有 id 时必须匹配当前的中止请求，
            // 迟到的旧响应不能清掉新请求的 in-flight 状态。
            guard let activeID = activeBashAbortCommandID,
                  record.id == nil || record.id == activeID
            else { return true }
            _ = settleRuntimeRequest(
                for: record,
                command: "abort_bash",
                purposes: [.operation]
            )
            if record.success != true {
                bashAbortRequested = false
                activeBashAbortCommandID = nil
                lastError = WorkPiSensitiveText.redacted(
                    record.string(at: "error") ?? "中止命令失败。"
                )
            }
            // 成功响应只表示 Pi 接受了中止；保留请求标记，直到 bash 终态
            // 或 Runtime 终止，避免中间窗口把命令误报为 Runtime 失败。
            if record.success == true {
                activeBashAbortCommandID = nil
            }
            return true

        default:
            return false
        }
    }

    private func appendBashOutput(
        _ delta: String,
        to existing: String
    ) -> (text: String, wasTruncated: Bool) {
        let marker = "\\n…（输出超过 2 MB，已截断）"
        let prefixBudget = max(Self.maximumBashOutputBytes - marker.utf8.count, 0)
        let existingData = Data(existing.utf8)
        var data = Data(existingData.prefix(prefixBudget))
        let remaining = max(prefixBudget - data.count, 0)
        let deltaData = Data(delta.utf8)
        data.append(deltaData.prefix(remaining))
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty {
            data.removeLast()
        }
        let wasTruncated = existingData.count > prefixBudget || deltaData.count > remaining
        let text = String(data: data, encoding: .utf8) ?? ""
        return (wasTruncated ? text + marker : text, wasTruncated)
    }

    private func boundedBashOutput(_ output: String) -> (text: String, wasTruncated: Bool) {
        guard output.utf8.count > Self.maximumBashOutputBytes else {
            return (output, false)
        }
        let marker = "\n…（输出超过 2 MB，已截断）"
        let budget = max(Self.maximumBashOutputBytes - marker.utf8.count, 0)
        var data = Data(output.utf8.prefix(budget))
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty {
            data.removeLast()
        }
        let prefix = String(data: data, encoding: .utf8) ?? ""
        return (prefix + marker, true)
    }

    /// 收束一次执行：写入终态并清理运行中指示。
    ///
    /// `bash` 不属于 Agent 回合，不会有 `agent_settled`，因此活动指示必须在这里清。
    func finishBashExecution(id: String, state: BashExecution.State) {
        if let index = bashExecutions.firstIndex(where: { $0.id == id }),
           bashExecutions[index].isRunning {
            bashExecutions[index].state = state
        }
        setBashActivity(hasRunningBashExecution)
        if !hasRunningBashExecution {
            activeBashAbortCommandID = nil
            bashAbortRequested = false
        }
        guard !hasRunningBashExecution,
              agentActivity == nil,
              phase == .idle
        else { return }
        runtimeStatus = runtimeReady ? "Pi Runtime 已连接" : runtimeStatus
    }

    /// 打开被截断输出的完整日志。
    func revealBashFullOutput(_ path: String) {
        revealInFinder(URL(fileURLWithPath: path))
    }

    func copyBashOutput(_ execution: BashExecution) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(execution.output, forType: .string)
    }

    func clearBashExecutions() {
        guard !hasRunningBashExecution else {
            lastError = "命令仍在执行，请先中止后再清空。"
            return
        }
        bashExecutions.removeAll()
        activeBashAbortCommandID = nil
        bashAbortRequested = false
        setBashActivity(false)
    }
}
