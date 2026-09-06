import Foundation

/// 一次直接 `bash` 执行。
///
/// 与工具调用不同：`bash` 的输出不会立刻进入模型上下文，Pi 把它存为
/// `BashExecutionMessage`，等**下一次 prompt** 时才转成用户消息发给模型。
/// 因此界面需要明确表达「已执行、将随下次提问带上」这个中间状态。
public struct BashExecution: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case finished(exitCode: Int)
        case cancelled
        /// Runtime 在命令完成前失联；与用户主动取消区分，便于显示真实原因。
        case failed(message: String)
        /// Pi 拒绝了命令本身（例如 Runtime 未就绪），没有产生执行。
        case rejected(message: String)
    }

    /// 与 `bash` 命令的 RPC id 一致，用于关联 `bash_execution_update`。
    public let id: String
    public let command: String
    public let startedAt: Date
    public var output: String
    public var state: State
    /// 输出被截断时，完整日志的路径。
    public var fullOutputPath: String?
    /// WorkPi 为保护内存而在实时流阶段截断了本地显示内容。
    public var outputTruncated: Bool

    public init(
        id: String,
        command: String,
        startedAt: Date = Date(),
        output: String = "",
        state: State = .running,
        fullOutputPath: String? = nil,
        outputTruncated: Bool = false
    ) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
        self.output = output
        self.state = state
        self.fullOutputPath = fullOutputPath
        self.outputTruncated = outputTruncated
    }

    public var isRunning: Bool { state == .running }

    /// 命令是否以失败告终。
    ///
    /// 退出码非零即失败，即便 RPC 的 `success` 是 true——那只表示命令被成功执行。
    public var failed: Bool {
        switch state {
        case .finished(let exitCode): return exitCode != 0
        case .failed, .rejected: return true
        case .running, .cancelled: return false
        }
    }

    public func statusText(isEnglish: Bool) -> String {
        switch state {
        case .running:
            return isEnglish ? "Running…" : "执行中…"
        case .finished(let exitCode):
            if exitCode == 0 {
                return isEnglish ? "Exit 0" : "退出码 0"
            }
            return isEnglish ? "Exit \(exitCode)" : "退出码 \(exitCode)"
        case .cancelled:
            return isEnglish ? "Cancelled" : "已中止"
        case .failed:
            return isEnglish ? "Failed" : "执行失败"
        case .rejected:
            return isEnglish ? "Rejected" : "未执行"
        }
    }
}
