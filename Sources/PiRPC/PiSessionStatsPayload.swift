import Foundation

/// `get_session_stats` 的解析结果。
///
/// `PiRPC` 不能依赖 `PiDomain`（同层不互相导入），因此这里给出中性载荷，
/// 由 WorkPi 层转成 `PiSessionStats`。
public struct PiSessionStatsPayload: Equatable, Sendable {
    public let sessionID: String?
    public let sessionFile: String?
    public let userMessages: Int
    public let assistantMessages: Int
    public let toolCalls: Int
    public let toolResults: Int
    public let totalMessages: Int
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let totalTokens: Int64
    public let cost: Double
    public let contextTokens: Int64?
    public let contextWindow: Int64?
    public let contextPercent: Double?
}
