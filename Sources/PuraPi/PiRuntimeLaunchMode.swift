import Foundation
import PiRPC

/// Pi Runtime 的启动意图。
///
/// `fresh` 保持现有 `pi --mode rpc` 行为；`continueRecent` 对应 Pi CLI 的
/// `--continue`，由 Pi 自己根据当前工作目录选择最近持久化 Session。
enum PiRuntimeLaunchMode: Equatable, Sendable {
    case fresh
    case continueRecent
    case freshApproved
    case continueRecentApproved

    var requiresMessageRestore: Bool {
        switch self {
        case .continueRecent, .continueRecentApproved:
            return true
        case .fresh, .freshApproved:
            return false
        }
    }

    var isApproved: Bool {
        switch self {
        case .freshApproved, .continueRecentApproved:
            return true
        case .fresh, .continueRecent:
            return false
        }
    }

    var processArguments: [String] {
        var arguments = ["--mode", "rpc"]
        switch self {
        case .fresh, .freshApproved:
            break
        case .continueRecent, .continueRecentApproved:
            arguments.append("--continue")
        }
        if isApproved {
            arguments.append("--approve")
        }
        return arguments
    }
}

/// 当前项目最近会话恢复入口的 UI 状态。
///
/// `loaded` 表示 `get_messages` 已成功返回；即使该 Session 没有消息，
/// 也不再重复显示恢复入口。`failed` 允许用户重新尝试。
enum PiRecentSessionRestoreState: Equatable, Sendable {
    case available
    case loading
    case loaded
    case failed
}

typealias PiTransportFactory = @Sendable (PiRuntimeLaunchMode) -> any PiRPCTransport

func makeDefaultPiTransport(
    for mode: PiRuntimeLaunchMode,
    executableURL: URL? = nil,
    environmentOverrides: [String: String] = [:]
) -> any PiRPCTransport {
    PiRPCProcessTransport(
        executableURL: executableURL,
        processArguments: mode.processArguments,
        environmentOverrides: environmentOverrides
    )
}
