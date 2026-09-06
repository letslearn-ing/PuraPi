import Foundation

/// `/status` 展示的 Pi `get_state` 快照。它是一次采样，不冒充持续轮询状态。
struct WorkPiRuntimeStatusSnapshot: Equatable {
    let modelName: String?
    let modelProvider: String?
    let modelID: String?
    let thinkingLevel: String?
    let isStreaming: Bool?
    let isCompacting: Bool?
    let steeringMode: String?
    let followUpMode: String?
    let sessionID: String?
    let sessionFile: String?
    let sessionName: String?
    let messageCount: Int?
    let pendingMessageCount: Int?
    let autoCompactionEnabled: Bool?
    let sampledAt: Date
}

enum WorkPiTurnOutcome: String, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

/// 一次 `turn_start` 到 `turn_end` 的本地记录；不参与 Agent 终态收敛。
struct WorkPiTurnRecord: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let startedAt: Date
    var endedAt: Date?
    var toolResultCount: Int?
    var outcome: WorkPiTurnOutcome

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// Pi 正在等待自动重试退避；只有这个状态存在时才显示 `abort_retry` 入口。
struct WorkPiRetryWaitState: Equatable {
    let id: UUID
    let attempt: Int?
    let maxAttempts: Int?
    let delayMilliseconds: Int?
    let startedAt: Date
}
