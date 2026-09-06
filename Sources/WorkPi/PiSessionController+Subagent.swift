import Foundation
import PiDomain
import PiRPC

/// SubAgent 面板状态与子会话查看入口。
///
/// 面板状态来自 Extension UI 的结构化 widget；点击任务只打开只读查看器，
/// 不切换主 Runtime 的当前 Session，也不会打断主 Agent。
extension PiSessionController {
    /// 消费保留的 SubAgent 面板 widget。返回 true 表示该 widget 不应再按普通
    /// Extension UI 字符串小组件处理。
    @discardableResult
    func consumeSubagentPanelRequest(_ request: PiExtensionUIRequest) -> Bool {
        guard request.widgetKey == PiSubagentPanelPayload.widgetKey else { return false }

        if let payload = request.subagentPanelPayload {
            guard payload.sequence >= subagentPanelSequence else { return true }
            subagentPanelSequence = payload.sequence
            subagentTasks = payload.tasks
            return true
        }

        // 空 widget 是扩展主动清除面板；非空但格式不正确的载荷保留上一份有效状态。
        if request.widgetLines == nil || request.widgetLines?.isEmpty == true {
            resetSubagentPanelState()
        }
        return true
    }

    /// 清除当前 Runtime 代际的 SubAgent 面板状态。
    func resetSubagentPanelState() {
        subagentPanelSequence = -1
        subagentTasks.removeAll()
        selectedSubagentTask = nil
    }

    /// 打开独立子会话查看器。查看器从 `sessionFilePath` 读取完整历史，
    /// 因此不需要向主 Runtime 发送 `switch_session`。
    func openSubagentTask(_ task: SubagentTaskSnapshot) {
        guard !task.sessionFilePath.isEmpty else {
            lastError = "SubAgent 没有可打开的 Session 路径。"
            return
        }
        selectedSubagentTask = task
    }

    func closeSubagentTaskViewer() {
        selectedSubagentTask = nil
    }
}
