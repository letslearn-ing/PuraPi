import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi

/// 直接执行 shell 命令。
///
/// 事件与响应的形状取自真实 Pi 0.84.1 的实测输出，不是按文档臆造：
/// `{"type":"bash_execution_update","id":"b1","delta":"hello\n"}`
/// `{"id":"b1","type":"response","command":"bash","success":true,
///   "data":{"output":"hello\nerr\n","exitCode":3,"cancelled":false,"truncated":false}}`
@MainActor
final class WorkPiBashTests: XCTestCase {
    // MARK: - 协议层

    func testBashCommandEncoding() {
        let command = PiRPCCommand.bash("ls -la")
        XCTAssertEqual(command.type, "bash")
        XCTAssertEqual(command.fields["command"]?.stringValue, "ls -la")
        XCTAssertNotNil(command.id)
        XCTAssertEqual(PiRPCCommand.abortBash().type, "abort_bash")
    }

    func testOutputDeltaParsing() {
        let event = PiRPCRecord(fields: [
            "type": .string("bash_execution_update"),
            "id": .string("b1"),
            "delta": .string("hello\n"),
        ])
        XCTAssertEqual(event.bashOutputDelta, "hello\n")

        // 非 bash 事件不能被误读成输出增量。
        let other = PiRPCRecord(fields: [
            "type": .string("tool_execution_update"),
            "delta": .string("x"),
        ])
        XCTAssertNil(other.bashOutputDelta)
    }

    /// 非零退出码仍是 `success: true`，判断失败必须看 exitCode。
    func testNonZeroExitCodeStillReportsSuccess() {
        let record = bashResponse(id: "b1", output: "hello\nerr\n", exitCode: 3)
        XCTAssertEqual(record.success, true)
        XCTAssertEqual(record.bashExitCode, 3)
        XCTAssertFalse(record.bashWasCancelled)
        XCTAssertFalse(record.bashOutputTruncated)
    }

    func testTruncationPathParsing() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("bash"),
            "id": .string("b1"),
            "success": .bool(true),
            "data": .object([
                "output": .string("partial"),
                "exitCode": .integer(0),
                "truncated": .bool(true),
                "fullOutputPath": .string("/tmp/pi-bash-abc.log"),
            ]),
        ])
        XCTAssertTrue(record.bashOutputTruncated)
        XCTAssertEqual(record.bashFullOutputPath, "/tmp/pi-bash-abc.log")
    }

    // MARK: - 输入分流

    /// `!` 前缀走 shell，不发给模型。
    func testShellPrefixDetection() {
        XCTAssertEqual(WorkPiCommandCatalog.shellCommand(for: "!ls -la"), "ls -la")
        XCTAssertEqual(WorkPiCommandCatalog.shellCommand(for: "  ! git status "), "git status")
        // 只有 `!` 没有命令时不触发。
        XCTAssertNil(WorkPiCommandCatalog.shellCommand(for: "!"))
        XCTAssertNil(WorkPiCommandCatalog.shellCommand(for: "/compact"))
        XCTAssertNil(WorkPiCommandCatalog.shellCommand(for: "解释一下 ! 的用法"))
    }

    /// 中文输入法打出的是全角 `！`，必须同样识别。
    ///
    /// 只认半角时那条消息会被当成普通提问发给模型——实测中文输入下就是这样，
    /// Pi 把它当成需求转成了 bash 工具调用，绕了一大圈。
    func testFullWidthExclamationIsRecognized() {
        XCTAssertEqual(WorkPiCommandCatalog.shellCommand(for: "！ls"), "ls")
        XCTAssertEqual(WorkPiCommandCatalog.shellCommand(for: "！ ls -a"), "ls -a")
        XCTAssertNil(WorkPiCommandCatalog.shellCommand(for: "！"))
    }

    /// 命令模式判定：只输前缀时也要成立，界面才能立刻反馈。
    func testShellCommandModeDetection() {
        XCTAssertTrue(WorkPiCommandCatalog.isShellCommandMode("!"))
        XCTAssertTrue(WorkPiCommandCatalog.isShellCommandMode("！"))
        XCTAssertTrue(WorkPiCommandCatalog.isShellCommandMode("!ls"))
        XCTAssertFalse(WorkPiCommandCatalog.isShellCommandMode(""))
        XCTAssertFalse(WorkPiCommandCatalog.isShellCommandMode("/compact"))
        XCTAssertFalse(WorkPiCommandCatalog.isShellCommandMode("你好"))
    }

    // MARK: - 状态机

    /// 输出增量按 id 归属到对应的执行块。
    func testOutputDeltaAppendsToMatchingExecution() {
        let session = PiSessionController()
        session.bashExecutions = [
            BashExecution(id: "b1", command: "echo hi"),
            BashExecution(id: "b2", command: "echo other"),
        ]

        _ = session.consumeBashOutputEvent(PiRPCRecord(fields: [
            "type": .string("bash_execution_update"),
            "id": .string("b2"),
            "delta": .string("other\n"),
        ]))

        XCTAssertEqual(session.bashExecutions[0].output, "")
        XCTAssertEqual(session.bashExecutions[1].output, "other\n")
    }

    /// 响应到达后必须写入终态；否则界面会一直显示执行中。
    func testResponseFinishesExecutionWithExitCode() {
        let session = PiSessionController()
        session.bashExecutions = [BashExecution(id: "b1", command: "exit 3")]

        _ = session.consumeBashResponse(bashResponse(id: "b1", output: "hello\nerr\n", exitCode: 3))

        XCTAssertEqual(session.bashExecutions[0].state, .finished(exitCode: 3))
        XCTAssertTrue(session.bashExecutions[0].failed)
        XCTAssertEqual(session.bashExecutions[0].output, "hello\nerr\n")
        XCTAssertFalse(session.hasRunningBashExecution)
    }

    /// bash 不属于 Agent 回合、不会有 `agent_settled`，
    /// 因此活动指示必须在响应处清掉，否则会像压缩那样永久转圈。
    func testActivityClearedWhenAllCommandsFinish() {
        let session = PiSessionController()
        session.bashExecutions = [BashExecution(id: "b1", command: "echo hi")]
        session.setBashActivity(true)
        XCTAssertEqual(session.activity, .runningCommand)

        _ = session.consumeBashResponse(bashResponse(id: "b1", output: "hi\n", exitCode: 0))

        XCTAssertNil(session.activity)
    }

    /// Bash 完成时不能清掉仍在生成的 Agent 活动；两种活动必须独立归属。
    func testBashCompletionPreservesAgentActivity() {
        let session = PiSessionController()
        session.bashExecutions = [BashExecution(id: "b1", command: "echo hi")]
        session.setActivity(.responding)
        session.setBashActivity(true)

        _ = session.consumeBashResponse(bashResponse(id: "b1", output: "hi\n", exitCode: 0))

        XCTAssertEqual(session.activity, .responding)
    }

    /// 还有命令在跑时不能清活动。
    func testActivityKeptWhileAnotherCommandRuns() {
        let session = PiSessionController()
        session.bashExecutions = [
            BashExecution(id: "b1", command: "fast"),
            BashExecution(id: "b2", command: "slow"),
        ]
        session.setBashActivity(true)

        _ = session.consumeBashResponse(bashResponse(id: "b1", output: "", exitCode: 0))

        XCTAssertTrue(session.hasRunningBashExecution)
        XCTAssertNotNil(session.activity)
    }

    func testCancelledExecutionIsNotTreatedAsFailure() {
        let session = PiSessionController()
        session.bashExecutions = [BashExecution(id: "b1", command: "sleep 100")]

        _ = session.consumeBashResponse(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("bash"),
            "id": .string("b1"),
            "success": .bool(true),
            "data": .object([
                "output": .string(""),
                "exitCode": .integer(130),
                "cancelled": .bool(true),
            ]),
        ]))

        XCTAssertEqual(session.bashExecutions[0].state, .cancelled)
        XCTAssertFalse(session.bashExecutions[0].failed)
    }

    func testLiveOutputIsBoundedAndMarkedTruncated() {
        let session = PiSessionController()
        session.bashExecutions = [BashExecution(id: "b1", command: "generate")]
        let huge = String(repeating: "输出", count: 1_100_000)

        _ = session.consumeBashOutputEvent(PiRPCRecord(fields: [
            "type": .string("bash_execution_update"),
            "id": .string("b1"),
            "delta": .string(huge),
        ]))

        XCTAssertTrue(session.bashExecutions[0].outputTruncated)
        XCTAssertLessThanOrEqual(
            session.bashExecutions[0].output.utf8.count,
            PiSessionController.maximumBashOutputBytes
        )
        let before = session.bashExecutions[0].output
        _ = session.consumeBashOutputEvent(PiRPCRecord(fields: [
            "type": .string("bash_execution_update"),
            "id": .string("b1"),
            "delta": .string("更多输出"),
        ]))
        XCTAssertEqual(session.bashExecutions[0].output, before)
    }

    /// Runtime 未就绪时不发命令，也不留下悬空的执行块。
    func testClearDoesNotDropRunningExecution() {
        let session = PiSessionController()
        session.bashExecutions = [BashExecution(id: "b1", command: "sleep 10")]
        session.setBashActivity(true)

        session.clearBashExecutions()

        XCTAssertTrue(session.hasRunningBashExecution)
        XCTAssertEqual(session.bashExecutions.count, 1)
        XCTAssertNotNil(session.lastError)
        XCTAssertEqual(session.activity, .runningCommand)
    }

    func testCommandRejectedBeforeRuntimeReady() {
        let session = PiSessionController()
        session.runBashCommand("ls")
        XCTAssertTrue(session.bashExecutions.isEmpty)
        XCTAssertNotNil(session.lastError)
    }

    // MARK: - 辅助

    private func bashResponse(id: String, output: String, exitCode: Int) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("bash"),
            "id": .string(id),
            "success": .bool(true),
            "data": .object([
                "output": .string(output),
                "exitCode": .integer(Int64(exitCode)),
                "cancelled": .bool(false),
                "truncated": .bool(false),
            ]),
        ])
    }
}
