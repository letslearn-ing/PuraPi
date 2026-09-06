import Foundation

/// SubAgent 任务的可视化生命周期。
public enum SubagentTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case retrying
    case completed
    case failed
    case cancelled
}

/// 一个由主 Agent 委派的、拥有独立 Pi Session 的任务快照。
///
/// 这是 Pi RPC 与 WorkPi UI 之间的稳定领域模型。`sessionFilePath` 是查看子会话
/// 的唯一地址；状态和预览文本只用于即时展示，完整内容仍以该 Session 文件为准。
public struct SubagentTaskSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sessionFilePath: String
    /// 子 Session 所在的持久化目录；为空时使用默认 Pi Session 根目录。
    public let sessionRootPath: String?
    public let agentName: String
    public let task: String
    public let status: SubagentTaskStatus
    /// `provider/model` 形式的实际模型标识。
    public let model: String?
    /// 是否已经从首选 Terra 切换到 Sol 重试。
    public let fallbackUsed: Bool
    public let detail: String?
    public let outputPreview: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    /// 链式工作流中的步骤序号；并行/单任务为 nil。
    public let step: Int?

    public init(
        id: String,
        sessionFilePath: String,
        agentName: String,
        task: String,
        status: SubagentTaskStatus,
        sessionRootPath: String? = nil,
        model: String? = nil,
        fallbackUsed: Bool = false,
        detail: String? = nil,
        outputPreview: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        step: Int? = nil
    ) {
        self.id = id
        self.sessionFilePath = sessionFilePath
        self.sessionRootPath = sessionRootPath
        self.agentName = agentName
        self.task = task
        self.status = status
        self.model = model
        self.fallbackUsed = fallbackUsed
        self.detail = detail
        self.outputPreview = outputPreview
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.step = step
    }
}
