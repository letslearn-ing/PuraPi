import AppKit
import Foundation
import PiRPC

/// 文件系统与剪贴板动作，以及 Pi 的两种排队消息封装。
///
/// 这些动作不参与 Runtime 状态机，只把用户在目录树上的操作转成系统调用，
/// 因此与会话控制逻辑分开存放。
extension PiSessionController {
    /// 在 Agent 工作期间排队一条 steering 消息（转向消息）。
    ///
    /// 与 PuraPi 自己维护的待执行队列不同：steering 由 Pi 在当前回合内投递，
    /// 一旦发出就无法撤回。
    func sendSteeringPrompt(_ text: String) {
        sendQueuedPrompt(text, command: .steer(text))
    }

    /// 在当前 Agent 完全结束后排队一条 follow-up 消息（后续消息）。
    func sendFollowUpPrompt(_ text: String) {
        sendQueuedPrompt(text, command: .followUp(text))
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    func openWithDefaultApplication(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyPath(_ url: URL, relative: Bool = false) {
        let path: String
        if relative, let workspace {
            path = relativePath(of: url, root: workspace.rootURL)
        } else {
            path = url.path
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
