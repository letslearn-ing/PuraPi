import AppKit
import Foundation
import PiDomain
import PiRPC

/// 会话导出。
///
/// `export_html` 只能导出 Pi 当前会话（协议没有 session 参数），因此用户入口
/// 必须放在「当前对话」语境里——放进文件菜单会让用户无法判断导出的是哪个会话。
extension PiSessionController {
    /// 是否正在导出。用于禁用按钮，避免重复触发。
    var isExporting: Bool { activeExportCommandID != nil }

    /// 是否可以压缩上下文。
    ///
    /// 与 `compactSession` 的前置条件保持一致：Runtime 就绪且没有正在跑的回合。
    /// 条件不一致会让按钮可点但请求被静默拒绝。
    var canCompactContext: Bool {
        guard !runtimeAuthenticationChanged,
              runtimeReady,
              phase == .idle || phase == .failed else { return false }
        // 只在「确定没有上下文」时禁用。
        //
        // 不做 token 阈值预判：Pi 的 `Nothing to compact` 取决于切点前是否还有
        // 完整回合，而切点由可配置的 `keepRecentTokens`（默认 20k，可被
        // settings.json 覆盖）与 chars/4 估算共同决定，客户端复现只能靠猜，
        // 猜错会挡掉本来可以压缩的场合。改为让 Pi 权威判定，
        // 无需压缩时按幂等确认给出提示（见 finishCompactionAsNoOp）。
        return (runtimeMetadata.contextTokens ?? 0) > 0
    }

    /// 让用户选择保存位置，然后请求 Pi 导出。
    func exportSessionHTML() {
        guard let transport, runtimeReady, !isRuntimeTransitioning else {
            lastError = "Pi Runtime 尚未就绪，无法导出会话。"
            return
        }
        guard activeExportCommandID == nil else { return }

        let panel = NSSavePanel()
        panel.title = "导出会话"
        panel.message = "把当前会话导出为可离线阅读的 HTML 文件"
        panel.prompt = "导出"
        panel.nameFieldLabel = "文件名："
        panel.nameFieldStringValue = suggestedExportFileName()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.showsTagField = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let command = PiRPCCommand.exportHTML(outputPath: url.path)
        activeExportCommandID = command.id
        registerRuntimeRequest(command, purpose: .operation, timeout: .seconds(60))
        runtimeStatus = "正在导出会话…"
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
                _ = self.settleRuntimeRequest(id: self.activeExportCommandID)
                self.activeExportCommandID = nil
                self.runtimeStatus = "会话导出失败"
                self.lastError = "无法导出会话：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    /// 默认文件名：会话名优先，否则用项目名加时间戳。
    private func suggestedExportFileName() -> String {
        if let name = activeSessionName, !name.isEmpty {
            return "\(sanitizedFileName(name)).html"
        }
        let project = workspace?.rootURL.lastPathComponent ?? "session"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(sanitizedFileName(project))-\(formatter.string(from: Date())).html"
    }

    /// 去掉路径分隔符与冒号，避免生成非法文件名。
    private func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "session" : String(trimmed.prefix(80))
    }

    /// 返回 true 表示该响应已由导出逻辑消费。
    func consumeExportResponse(_ record: PiRPCRecord) -> Bool {
        guard record.command == "export_html" else { return false }
        guard !shouldIgnoreRuntimeResponse(record) else { return true }
        guard let activeID = activeExportCommandID,
              record.id == nil || record.id == activeID
        else { return true }
        let request = settleRuntimeRequest(
            for: record,
            command: "export_html",
            purposes: [.operation]
        )
        guard request != nil || !hasRuntimeRequest(
            for: "export_html",
            purposes: [.operation]
        ) else { return true }
        activeExportCommandID = nil
        guard record.success == true else {
            runtimeStatus = "会话导出失败"
            let message = PuraPiSensitiveText.redacted(
                record.string(at: "error") ?? "导出会话失败。"
            )
            lastError = message
            noteAuthenticationFailure(message)
            return true
        }
        runtimeStatus = "会话已导出"
        // 以 Pi 回传的路径为准：不传 outputPath 时由 Pi 决定位置。
        if let path = record.exportedFilePath {
            revealInFinder(URL(fileURLWithPath: path))
        }
        return true
    }
}

/// 自动压缩开关。
extension PiSessionController {
    /// 切换 Pi 的自动压缩。
    ///
    /// 不在本地推断新状态：发完命令重新拉 `get_state`，以 Pi 回读为准。
    /// 这与模型/推理级别切换保持同一策略，避免界面与 Pi 不一致。
    func setAutoCompaction(enabled: Bool) {
        guard !runtimeAuthenticationChanged else {
            lastError = "Pi 认证已更新，请先重新连接 Runtime；自动压缩设置未发送。"
            return
        }
        guard activeAutoCompactionCommandID == nil else { return }
        guard let transport, runtimeReady, !isRuntimeTransitioning else {
            lastError = "Pi Runtime 尚未就绪，无法切换自动压缩。"
            return
        }

        let command = PiRPCCommand.setAutoCompaction(enabled: enabled)
        activeAutoCompactionCommandID = command.id
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
                _ = self.settleRuntimeRequest(id: self.activeAutoCompactionCommandID)
                self.activeAutoCompactionCommandID = nil
                let safeError = PuraPiSensitiveText.redacted(error.localizedDescription)
                self.lastError = "无法切换自动压缩：\(safeError)"
                self.noteAuthenticationFailure(safeError)
            }
        }
    }

    /// 返回 true 表示该响应已由自动压缩逻辑消费。
    func consumeAutoCompactionResponse(_ record: PiRPCRecord) -> Bool {
        guard record.command == "set_auto_compaction" else { return false }
        guard !shouldIgnoreRuntimeResponse(record) else { return true }
        guard let activeID = activeAutoCompactionCommandID,
              record.id == nil || record.id == activeID
        else { return true }
        let request = settleRuntimeRequest(
            for: record,
            command: "set_auto_compaction",
            purposes: [.operation]
        )
        guard request != nil || !hasRuntimeRequest(
            for: "set_auto_compaction",
            purposes: [.operation]
        ) else { return true }
        activeAutoCompactionCommandID = nil
        guard record.success == true else {
            let message = PuraPiSensitiveText.redacted(
                record.string(at: "error") ?? "切换自动压缩失败。"
            )
            lastError = message
            noteAuthenticationFailure(message)
            return true
        }
        // 回读真实状态，而不是假设命令生效。
        refreshRuntimeState()
        return true
    }
}
