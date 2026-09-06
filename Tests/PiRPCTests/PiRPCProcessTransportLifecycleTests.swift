import Foundation
import XCTest
@testable import PiRPC

/// 真实进程传输的停止合同测试：`stop()` 返回时必须已经可以再次 `start()`。
final class PiRPCProcessTransportLifecycleTests: XCTestCase {
    func testStopCanInterruptAStalledStdinWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-pi-rpc-stalled-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = PiRPCProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", "sleep 30"]
        )
        _ = try await transport.start(in: root)
        let sendTask = Task {
            try await transport.send(.prompt(String(repeating: "x", count: 1_000_000)))
        }
        try await Task.sleep(for: .milliseconds(50))
        await transport.stop()
        _ = try? await sendTask.value
    }

    func testCancellingStalledWriteStopsTransportAndReleasesSendTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-pi-rpc-cancel-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = PiRPCProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", "sleep 30"]
        )
        _ = try await transport.start(in: root)
        let sendTask = Task {
            try await transport.send(.prompt(String(repeating: "x", count: 4_000_000)))
        }
        try await Task.sleep(for: .milliseconds(50))
        sendTask.cancel()
        _ = try? await sendTask.value
        await transport.stop()
    }

    func testStopWaitsUntilProcessCanBeStartedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-pi-rpc-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = PiRPCProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            processArguments: ["30"]
        )
        _ = try await transport.start(in: root)
        await transport.stop()

        // 如果 stop 只发 SIGTERM 而没有等待 terminationHandler，这里会得到
        // alreadyRunning；该测试不调用 Pi，也不产生模型或网络请求。
        _ = try await transport.start(in: root)
        await transport.stop()
    }
}
