import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi

/// 上下文压缩的终态收束。
///
/// 事件形状取自真实 Pi 0.84.1 实测。手动压缩的完整序列只有三条，
/// **没有 `agent_settled`**：
/// ```
/// {"type":"compaction_start","reason":"manual"}
/// {"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false,
///  "errorMessage":"Compaction failed: Nothing to compact (session too small)"}
/// {"id":"2","type":"response","command":"compact","success":false,
///  "error":"Nothing to compact (session too small)"}
/// ```
/// 因为 `setActivity(nil)` 主要挂在 `agent_settled` 上，压缩必须自己清活动，
/// 否则转圈会永久停留——实测曾出现 18 分 59 秒仍在转的情况。
@MainActor
final class PuraPiCompactionTests: XCTestCase {
    // MARK: - 活动指示必须消失

    func testManualCompactionSuccessClearsActivity() {
        let session = makeCompactingSession()

        session.consumeCompactionEnd(compactionEnd())

        XCTAssertNil(session.activity)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.activeCompactRPCID)
    }

    func testCompactionFailureClearsActivity() {
        let session = makeCompactingSession()

        session.consumeCompactionEnd(compactionEnd(errorMessage: "API quota exceeded"))

        XCTAssertNil(session.activity)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.lastError, "API quota exceeded")
    }

    func testAbortedCompactionClearsActivity() {
        let session = makeCompactingSession()

        session.consumeCompactionEnd(compactionEnd(aborted: true))

        XCTAssertNil(session.activity)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.runOutcome, .cancelled)
    }

    /// 会话太小：Pi 用 errorMessage 表达，但这不是故障。
    func testSessionTooSmallIsTreatedAsNoOpNotFailure() {
        let session = makeCompactingSession()

        session.consumeCompactionEnd(
            compactionEnd(errorMessage: "Compaction failed: Nothing to compact (session too small)")
        )

        XCTAssertNil(session.activity)
        // 关键：不能是 failed，否则用户以为出错了。
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.runtimeStatus, "当前上下文还很小，不需要压缩")
    }

    func testAlreadyCompactedIsTreatedAsNoOp() {
        let session = makeCompactingSession()

        session.consumeCompactionEnd(compactionEnd(errorMessage: "Already compacted"))

        XCTAssertNil(session.activity)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.runtimeStatus, "当前会话已经压缩，无需重复操作")
    }

    /// 溢出触发的压缩之后 Pi 会自动重试原 prompt，回合尚未结束，
    /// 活动指示必须保留，由后续 `agent_settled` 收束。
    func testWillRetryKeepsActivity() {
        let session = makeCompactingSession()

        session.consumeCompactionEnd(compactionEnd(willRetry: true))

        XCTAssertNotNil(session.activity)
    }

    /// 自动压缩返回“无需压缩”时，当前 Agent 回合仍未结束。
    func testAutomaticNoOpKeepsAgentRunActive() {
        let session = PiSessionController()
        session.runOutcome = .running
        session.phase = .settling
        session.setActivity(.compacting(isAutomatic: true))

        session.consumeCompactionEnd(
            compactionEnd(errorMessage: "Nothing to compact (session too small)")
        )

        XCTAssertEqual(session.runOutcome, .running)
        XCTAssertEqual(session.phase, .settling)
        XCTAssertNotNil(session.activity)
        XCTAssertNil(session.lastError)
    }

    /// 自动压缩发生在回合内部，之后还有模型输出，不能提前清活动。
    func testAutomaticCompactionKeepsActivityForRemainingTurn() {
        let session = PiSessionController()
        session.setActivity(.compacting(isAutomatic: true))
        // 没有 activeCompactCommandItemID 即为自动压缩。
        session.consumeCompactionEnd(compactionEnd())

        XCTAssertNotNil(session.activity)
    }

    // MARK: - 幂等消息识别

    func testNothingToCompactRecognition() {
        let session = PiSessionController()
        XCTAssertTrue(session.isNothingToCompactMessage("Already compacted"))
        XCTAssertTrue(
            session.isNothingToCompactMessage("Compaction failed: Nothing to compact (session too small)")
        )
        XCTAssertFalse(session.isNothingToCompactMessage("API quota exceeded"))
        XCTAssertFalse(session.isNothingToCompactMessage("network error"))
    }

    // MARK: - 按钮门控

    /// 没有任何上下文时不该让用户点压缩。
    func testCompactUnavailableWithoutContext() {
        let session = PiSessionController()
        XCTAssertFalse(session.canCompactContext)
    }

    // MARK: - 辅助

    private func makeCompactingSession() -> PiSessionController {
        let session = PiSessionController()
        let itemID = UUID()
        session.conversation = [
            ConversationItem(id: itemID, kind: .command, text: "/compact", status: .streaming),
        ]
        session.activeCompactCommandItemID = itemID
        session.activeCompactRPCID = "req-compact"
        session.setActivity(.compacting(isAutomatic: false))
        // 幂等分支的状态文案区分 Runtime 是否可用，这里模拟已连接。
        session.runtimeReady = true
        return session
    }

    private func compactionEnd(
        errorMessage: String? = nil,
        aborted: Bool = false,
        willRetry: Bool = false
    ) -> PiRPCRecord {
        var fields: [String: JSONValue] = [
            "type": .string("compaction_end"),
            "reason": .string("manual"),
            "aborted": .bool(aborted),
            "willRetry": .bool(willRetry),
        ]
        if let errorMessage {
            fields["errorMessage"] = .string(errorMessage)
        } else if !aborted {
            fields["result"] = .object([
                "summary": .string("摘要"),
                "firstKeptEntryId": .string("abc123"),
                "tokensBefore": .integer(150_000),
                "estimatedTokensAfter": .integer(32_000),
            ])
        }
        return PiRPCRecord(fields: fields)
    }
}
