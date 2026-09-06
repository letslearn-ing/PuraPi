import Foundation

/// Agent 正在进行的具体活动。
///
/// `AgentPhase` 只描述 Runtime 所处的粗粒度阶段，压缩、重试、摘要都会落到
/// `.settling`，无法区分。活动指示需要告诉用户「现在到底在做什么」，因此这里
/// 保留一份更细的、由 Pi 事件直接驱动的活动类型。
///
/// 只有 Pi 明确发出对应事件时才切换；不猜测、不用阶段反推。
public enum AgentActivity: Equatable, Sendable {
    /// 已提交请求，等待模型开始响应。
    case waitingForModel
    /// 模型正在生成推理内容。
    case thinking
    /// 模型正在输出正文。
    case responding
    /// 正在执行工具；带工具名以便显示。
    case runningTool(name: String?)
    /// 正在执行直接 bash 命令。
    case runningCommand
    /// 手动或自动压缩上下文。
    case compacting(isAutomatic: Bool)
    /// 自动重试；带当前次数与上限。
    case retrying(attempt: Int?, maxAttempts: Int?)
    /// 上下文摘要重试。
    case summarizing
    /// 正在恢复历史会话。
    case restoringSession
    /// 用户已请求停止，等待 Pi 收尾。
    case stopping

    /// 是否属于「Pi 正在忙」的活动。用于决定是否显示指示器。
    public var isBusy: Bool { true }
}

/// 活动指示的双语文案。
///
/// 与 Pi TUI 对齐：一个旋转指示符加一句短说明。文案随界面语言切换，
/// 不混用中英文。
public enum AgentActivityText {
    /// 界面语言。放在 PiDomain 是为了让文案与活动模型同层，避免 UI 层散落字符串。
    public enum Language: String, Sendable {
        case chinese
        case english
    }

    public static func label(
        for activity: AgentActivity,
        language: Language
    ) -> String {
        language == .english
            ? englishLabel(for: activity)
            : chineseLabel(for: activity)
    }

    private static func chineseLabel(for activity: AgentActivity) -> String {
        switch activity {
        case .waitingForModel:
            return "等待模型响应"
        case .thinking:
            return "思考中"
        case .responding:
            return "生成回答"
        case .runningTool(let name):
            guard let name, !name.isEmpty else { return "执行工具" }
            return "执行 \(name)"
        case .runningCommand:
            return "执行命令"
        case .compacting(let isAutomatic):
            return isAutomatic ? "自动压缩上下文" : "压缩上下文"
        case .retrying(let attempt, let maxAttempts):
            if let attempt, let maxAttempts {
                return "重试中（\(attempt)/\(maxAttempts)）"
            }
            return "重试中"
        case .summarizing:
            return "生成上下文摘要"
        case .restoringSession:
            return "恢复会话"
        case .stopping:
            return "正在停止"
        }
    }

    private static func englishLabel(for activity: AgentActivity) -> String {
        switch activity {
        case .waitingForModel:
            return "Waiting for model"
        case .thinking:
            return "Thinking"
        case .responding:
            return "Responding"
        case .runningTool(let name):
            guard let name, !name.isEmpty else { return "Running tool" }
            return "Running \(name)"
        case .runningCommand:
            return "Running command"
        case .compacting(let isAutomatic):
            return isAutomatic ? "Auto-compacting" : "Compacting context"
        case .retrying(let attempt, let maxAttempts):
            if let attempt, let maxAttempts {
                return "Retrying (\(attempt)/\(maxAttempts))"
            }
            return "Retrying"
        case .summarizing:
            return "Summarizing context"
        case .restoringSession:
            return "Restoring session"
        case .stopping:
            return "Stopping"
        }
    }
}
