import Foundation

/// 认证变化与项目 Runtime 的衔接。
///
/// Pi RPC 进程在启动时解析认证配置，RPC 本身没有“重新载入凭据”命令。
/// 因此认证变化只标记当前 Runtime，等安全的空闲时机由用户显式重新连接；
/// 不在 Agent 工作中强制杀进程，也不丢弃草稿、队列或附件。
extension PiSessionController {
    func markRuntimeAuthenticationChanged() {
        guard workspace != nil else { return }
        runtimeAuthenticationChanged = true
        guard runtimeReady else { return }

        let isIdle = phase == .idle
            && !bashActivityActive
            && activeAgentRunID == nil
            && !runSettlementPending
            && !sessionRebuildInFlight
            && !sessionOperationInFlight
        runtimeNotice = isIdle
            ? "Pi 认证已更新。请点击“重新连接”以应用新的凭据。"
            : "Pi 认证已更新；当前任务结束后，请点击“重新连接”以应用新的凭据。"
    }

    func clearRuntimeAuthenticationChange() {
        runtimeAuthenticationChanged = false
    }

    /// 普通提示可以关闭；认证尚未重新加载时必须保留恢复入口。
    func clearRuntimeNotice() {
        if runtimeAuthenticationChanged {
            runtimeNotice = "Pi 认证已更新；请打开“设置 → 账号”确认凭据，然后重新连接 Runtime。"
        } else {
            runtimeNotice = nil
        }
    }

    /// 认证切换期间仍允许停止 Agent、授权项目和执行会话生命周期动作；
    /// 需要模型调用的普通 Prompt/命令必须等待 Runtime 重连。
    func canSubmitWhileAuthenticationChanged(_ text: String) -> Bool {
        if WorkPiCommandCatalog.shellCommand(for: text) != nil { return true }
        guard let action = WorkPiCommandCatalog.action(for: text) else { return false }
        switch action {
        case .abort, .newSession, .continueRecent, .trustProject, .status:
            return true
        case .compact:
            return false
        }
    }

    /// Provider 返回认证失败时给出可操作提示；不把错误文本或令牌写入认证状态。
    /// 认证失败与外部登录/退出一样，会冻结新的模型请求，直到 Runtime
    /// 重新读取 auth.json；当前回合和本地草稿仍保留。
    func noteAuthenticationFailure(_ message: String) {
        let normalized = message.lowercased()
        let indicators = [
            "unauthorized",
            "authentication failed",
            "authentication required",
            "provider is not configured",
            "invalid api key",
            "认证失败",
            "认证已过期",
            "未配置凭据",
            "invalid_api_key",
            "api key is invalid",
            "token expired",
            "invalid_grant",
            "401",
            "403",
        ]
        guard indicators.contains(where: { normalized.contains($0) }) else { return }
        if workspace != nil {
            runtimeAuthenticationChanged = true
        }
        let provider = runtimeMetadata.modelProvider.map { "（\($0)）" } ?? ""
        runtimeNotice = "Provider\(provider) 认证可能已过期。请到“设置 → 账号”重新登录或配置 API Key，然后重新连接 Runtime。"
    }
}
