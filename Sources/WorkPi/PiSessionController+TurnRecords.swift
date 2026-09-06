import Foundation
import PiRPC

/// 记录 Pi Extension API 的 `turn_start`/`turn_end`，但不拿它们替代
/// `message_end`、`agent_settled` 的回合终态判定。
extension PiSessionController {
    func consumeTurnStart(_ record: PiRPCRecord) {
        guard let index = record.turnIndex,
              !runSettlementHandled,
              !runtimeSettlementQuarantined
        else { return }
        if let activeTurnRecordID,
           turnRecords.contains(where: { $0.id == activeTurnRecordID && $0.endedAt == nil }) {
            // Pi 的事件有序；重复 start 只可能是重复输入或兼容层重放。
            return
        }
        let turn = WorkPiTurnRecord(
            id: UUID(),
            index: index,
            startedAt: record.turnTimestamp ?? Date(),
            endedAt: nil,
            toolResultCount: nil,
            outcome: .running
        )
        turnRecords.append(turn)
        if turnRecords.count > 100 {
            turnRecords.removeFirst(turnRecords.count - 100)
        }
        activeTurnRecordID = turn.id
    }

    func consumeTurnEnd(_ record: PiRPCRecord) {
        guard let index = record.turnIndex,
              let recordIndex = turnRecords.lastIndex(where: {
                  $0.index == index && $0.endedAt == nil
              })
        else { return }

        let stopReason = record.turnMessageStopReason?.lowercased()
        let isCancelled = currentAgentRunWasCancelled()
            || stopReason == "aborted"
            || stopReason == "cancelled"
            || stopReason == "canceled"
        let isFailed = !isCancelled
            && (record.turnMessageErrorMessage != nil || stopReason == "error")
        turnRecords[recordIndex].endedAt = Date()
        turnRecords[recordIndex].toolResultCount = record.turnToolResultCount
        turnRecords[recordIndex].outcome = isCancelled
            ? .cancelled
            : (isFailed ? .failed : .completed)
        if activeTurnRecordID == turnRecords[recordIndex].id {
            activeTurnRecordID = nil
        }
    }

    func finishActiveTurnIfNeeded(outcome: WorkPiTurnOutcome) {
        guard let activeTurnRecordID,
              let index = turnRecords.firstIndex(where: {
                  $0.id == activeTurnRecordID && $0.endedAt == nil
              })
        else { return }
        turnRecords[index].endedAt = Date()
        turnRecords[index].outcome = outcome
        self.activeTurnRecordID = nil
    }
}
