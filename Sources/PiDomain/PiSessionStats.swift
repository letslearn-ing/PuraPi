import Foundation

/// `get_session_stats` 的统计快照。
///
/// 字段与实测响应对齐（Pi 0.84.1）：token 与 cost 覆盖整个会话，
/// 包含工具上报的用量以及压缩/分支摘要的生成开销。
public struct PiSessionStats: Equatable, Sendable {
    public var sessionID: String?
    public var sessionFile: String?
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int
    public var toolResults: Int
    public var totalMessages: Int
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var totalTokens: Int64
    public var cost: Double
    /// 压缩刚结束时 Pi 会把这两个值报成 null，直到新的回答提供有效用量。
    public var contextTokens: Int64?
    public var contextWindow: Int64?
    public var contextPercent: Double?

    public init(
        sessionID: String? = nil,
        sessionFile: String? = nil,
        userMessages: Int = 0,
        assistantMessages: Int = 0,
        toolCalls: Int = 0,
        toolResults: Int = 0,
        totalMessages: Int = 0,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        cost: Double = 0,
        contextTokens: Int64? = nil,
        contextWindow: Int64? = nil,
        contextPercent: Double? = nil
    ) {
        self.sessionID = sessionID
        self.sessionFile = sessionFile
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.totalMessages = totalMessages
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
    }

    /// 缓存命中率：读取缓存占总输入的比例。
    ///
    /// 这是判断"上下文是否被有效复用"的关键指标——比率低意味着每轮都在
    /// 全价重算历史。
    public var cacheHitRatio: Double? {
        let denominator = inputTokens + cacheReadTokens
        guard denominator > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denominator)
    }
}
