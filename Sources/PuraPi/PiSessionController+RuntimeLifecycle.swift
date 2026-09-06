import Foundation
import PiRPC

/// Runtime 停止与下一次启动之间的串行屏障。
///
/// `PiRPCTransport` 可以被测试替身复用，真实 transport 也可能在 stop 完成前
/// 仍持有进程或管道。所有替换 Runtime 的路径都必须把停止任务登记在同一个槽位，
/// 并在 transport 停止后等待旧启动任务收束；较早的启动意图若已被更新，则自动失效。
extension PiSessionController {
    @discardableResult
    func scheduleRuntimeStop(
        pending: Task<Void, Never>?,
        transport: (any PiRPCTransport)?,
        startTask: Task<Void, Never>? = nil,
        extensionRequestIDs: [String] = []
    ) -> (token: UUID, task: Task<Void, Never>)? {
        guard pending != nil || transport != nil || startTask != nil else {
            runtimeStopTask = nil
            runtimeStopToken = nil
            return nil
        }

        let token = UUID()
        let task = Task { [pending, transport, startTask, extensionRequestIDs] in
            if let pending {
                await pending.value
            }
            if let transport {
                // 先以有界等待发送取消记录，让对端尽快结束悬挂的 UI 请求；
                // 若 stdin 被旧写入卡住，超时后立即 stop()，不能把生命周期
                // 障碍变成无限等待。这里直接使用旧 transport，因为调用方已经
                // 将 controller.transport 置空，不能再走带身份校验的 controller API。
                // Cancellation responses are best-effort. Treat the whole
                // batch as one bounded barrier; doing one 500 ms wait per
                // queued request would let an extension delay shutdown for
                // minutes. `transport.stop()` below remains authoritative.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for requestID in extensionRequestIDs {
                            do {
                                try await transport.send(
                                    .extensionUIResponse(
                                        requestID: requestID,
                                        cancelled: true
                                    )
                                )
                            } catch {
                                return
                            }
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
                await transport.stop()
            }
            if let startTask {
                await startTask.value
            }
        }
        runtimeStopToken = token
        runtimeStopTask = task
        return (token, task)
    }

    /// 应用退出或标签移除时等待旧 transport 真正释放进程和管道。
    func waitForRuntimeStop() async {
        let stop = runtimeStopTask
        await stop?.value
    }

    /// 等待一个已经登记的停止任务，然后只允许最新的启动意图继续。
    func startRuntimeAfterStop(
        _ stop: (token: UUID, task: Task<Void, Never>),
        workspaceURL: URL,
        generation: UUID,
        launchMode: PiRuntimeLaunchMode
    ) {
        Task { [weak self, stop] in
            await stop.task.value
            guard let self,
                  self.generation == generation,
                  self.runtimeStopToken == stop.token
            else { return }
            self.runtimeStopTask = nil
            self.runtimeStopToken = nil
            self.startRuntime(
                for: workspaceURL,
                generation: generation,
                launchMode: launchMode
            )
        }
    }
}
