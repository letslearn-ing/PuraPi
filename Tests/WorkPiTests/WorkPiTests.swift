import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi
import WorkspaceKit

@MainActor
final class WorkPiTests: XCTestCase {
    func testProjectTabsDeduplicateAndSelectNeighborAfterClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-tabs-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = TestTransportCollector()
        let manager = WorkPiTabManager(makeTransport: { collector.make() })

        manager.openProject(at: first)
        manager.openProject(at: second)
        try await waitUntil { collector.count == 2 }
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTab?.rootURL, second.standardizedFileURL)

        manager.openProject(at: first)
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTab?.rootURL, first.standardizedFileURL)

        let firstTab = try XCTUnwrap(manager.selectedTab)
        manager.close(firstTab)
        try await waitUntil { await collector.runningCount() == 1 }
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTab?.rootURL, second.standardizedFileURL)

        manager.closeAll()
        try await waitUntil { await collector.allStopped() }
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertNil(manager.selectedTab)
        XCTAssertEqual(collector.count, 2)
    }

    func testStreamingDeltasAreMergedWithoutLosingText() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "stream"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        await transport.emit(.record(Self.messageStartRecord()))
        for index in 0..<100 {
            await transport.emit(.record(Self.textDeltaRecord("片段\(index)-")))
        }
        await transport.emit(.record(Self.messageEndRecord(text: nil, stopReason: "stop")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))

        try await waitUntil { session.phase == .idle }
        let expected = (0..<100).map { "片段\($0)-" }.joined()
        XCTAssertEqual(session.conversation.last?.text, expected)
    }

    func testMessageEndUsageUpdatesContextImmediately() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "usage"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        await transport.emit(.record(Self.messageStartRecord()))
        await transport.emit(.record(Self.messageEndRecord(
            text: "done",
            stopReason: "stop",
            usage: ["totalTokens": .integer(12_345)]
        )))

        try await waitUntil { session.runtimeMetadata.contextTokens == 12_345 }
        XCTAssertEqual(session.runtimeMetadata.contextPercent, 12.345)
    }

    func testAgentSettledRequestsFreshSessionStats() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let before = await transport.sentCommands.filter { $0.type == "get_session_stats" }.count
        session.draftPrompt = "stats"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        await transport.emit(.record(Self.messageEndRecord(text: "done", stopReason: "stop")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))

        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "get_session_stats" }.count > before
        }
    }

    func testContinueRecentSessionLoadsHistoryAndSettlesAfterMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-continue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = ModeTransportCollector()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { mode in collector.make(mode) }
        )

        session.openWorkspace(root)
        try await waitUntil { collector.count == 1 }
        let fresh = try XCTUnwrap(collector.transport(at: 0))
        try await waitUntil {
            let types = await fresh.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await fresh.emit(.record(Self.stateRecord()))
        await fresh.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }
        XCTAssertEqual(session.recentSessionRestoreState, .available)

        session.continueRecentSession()
        try await waitUntil { collector.count == 2 }
        let continued = try XCTUnwrap(collector.transport(at: 1))
        XCTAssertEqual(collector.mode(at: 1), .continueRecent)
        try await waitUntil {
            let types = await continued.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats", "get_messages"])
        }
        let continuedCommandTypes = await continued.sentCommands.map(\.type)
        XCTAssertEqual(
            continuedCommandTypes,
            ["get_state", "get_session_stats", "get_messages"]
        )
        XCTAssertEqual(session.recentSessionRestoreState, .loading)

        await continued.emit(.record(Self.stateRecord()))
        await continued.emit(.record(Self.statsRecord()))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(session.runtimeReady)
        XCTAssertEqual(session.phase, .preparing)

        let history = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_messages"),
            "success": .bool(true),
            "data": .object([
                "messages": .array([
                    .object([
                        "role": .string("user"),
                        "content": .string("历史用户请求"),
                    ]),
                    .object([
                        "role": .string("assistant"),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("历史助手回答"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        await continued.emit(.record(history))

        try await waitUntil {
            session.recentSessionRestoreState == .loaded && session.runtimeReady
        }
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.runtimeStatus, "已继续最近会话")
        XCTAssertEqual(
            session.conversation.map(\.text),
            ["历史用户请求", "历史助手回答"]
        )

        let fileAfterRestart = root.appendingPathComponent("after-continue.txt")
        try "发现新文件".write(to: fileAfterRestart, atomically: true, encoding: .utf8)
        try await waitUntil(timeout: 5) {
            Self.tree(session.fileTree, contains: fileAfterRestart)
        }
    }

    func testContinueRecentSessionWithEmptyHistoryHidesEntryState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-continue-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = ModeTransportCollector()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { mode in collector.make(mode) }
        )
        session.openWorkspace(root)
        try await waitUntil { collector.count == 1 }
        let fresh = try XCTUnwrap(collector.transport(at: 0))
        try await waitUntil {
            let types = await fresh.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await emitHandshake(fresh)
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }

        session.continueRecentSession()
        try await waitUntil { collector.count == 2 }
        let continued = try XCTUnwrap(collector.transport(at: 1))
        try await waitUntil {
            let types = await continued.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats", "get_messages"])
        }
        await emitHandshake(continued)
        XCTAssertEqual(session.recentSessionRestoreState, .loading)
        await continued.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_messages"),
            "success": .bool(true),
            "data": .object(["messages": .array([])]),
        ])))

        try await waitUntil {
            session.recentSessionRestoreState == .loaded && session.runtimeReady
        }
        XCTAssertTrue(session.conversation.isEmpty)
        // UI 入口由该状态而非 conversation.count 决定，因此空 Session 成功恢复后
        // 也不会再次显示“继续最近会话”。
        XCTAssertNotEqual(session.recentSessionRestoreState, .available)
    }

    func testSessionHandshakeAndStreamingCompletion() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        session.openWorkspace(root)

        try await waitUntil { await transport.workspaceURL != nil }
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        let startupCommands = await transport.sentCommands
        XCTAssertEqual(Array(startupCommands.prefix(2)).map(\.type), ["get_state", "get_session_stats"])

        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }

        session.draftPrompt = "hello"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }

        await transport.emit(.record(Self.messageStartRecord()))
        await transport.emit(.record(Self.textDeltaRecord("hello")))
        await transport.emit(.record(Self.messageEndRecord(text: "hello", stopReason: "stop")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle && session.conversation.last?.status == .completed }
        XCTAssertEqual(session.conversation.last?.text, "hello")
    }

    func testAbortWithStopReasonStopRemainsCancelledAndClearsError() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "stop me"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        session.abort()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "abort" }) }

        await transport.emit(.record(Self.messageEndRecord(text: nil, stopReason: "stop")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle }

        XCTAssertEqual(session.conversation.last?.status, .cancelled)
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertNil(session.lastError)
    }

    func testAbortResponseSettlesWithoutAgentSettledEvent() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "long task"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        session.submitCommand("/abort")
        try await waitUntil {
            await transport.sentCommands.contains(where: { $0.type == "abort" })
        }
        let sentCommands = await transport.sentCommands
        let abortCommand = try XCTUnwrap(
            sentCommands.last(where: { $0.type == "abort" })
        )
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(abortCommand.id ?? ""),
            "command": .string("abort"),
            "success": .bool(true),
        ])))

        try await waitUntil { session.phase == .idle }
        let commandItem = try XCTUnwrap(session.conversation.last(where: { $0.kind == .command }))
        XCTAssertEqual(commandItem.status, .cancelled)
        XCTAssertEqual(commandItem.detail, "Agent 已停止")
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertNil(session.activity)
        XCTAssertNil(session.lastError)
    }

    func testAbortSettledBeforeResponseIgnoresLateSuccess() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "long task"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        session.submitCommand("/abort")
        try await waitUntil { await transport.sentCommands.contains(where: { $0.type == "abort" }) }
        let sentCommands = await transport.sentCommands
        let abortCommand = try XCTUnwrap(sentCommands.last(where: { $0.type == "abort" }))

        await transport.emit(.record(Self.messageEndRecord(text: nil, stopReason: "error")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle }
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(abortCommand.id ?? ""),
            "command": .string("abort"),
            "success": .bool(true),
        ])))
        try await Task.sleep(for: .milliseconds(40))

        let commandItem = try XCTUnwrap(session.conversation.last(where: { $0.kind == .command }))
        XCTAssertEqual(commandItem.status, .cancelled)
        XCTAssertEqual(commandItem.detail, "Agent 已停止")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertNil(session.lastError)
    }

    func testAbortRemainsCancelledAfterAgentSettled() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "long task"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        session.abort()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "abort" }) }

        await transport.emit(.record(Self.messageEndRecord(text: nil, stopReason: "aborted")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle }
        XCTAssertEqual(session.runtimeStatus, "Agent 已停止")
        XCTAssertTrue(session.conversation.contains(where: { $0.status == .cancelled }))
    }

    func testPromptRejectionMarksAssistantFailed() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "rejected"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        let commands = await transport.sentCommands
        let prompt = try XCTUnwrap(commands.first(where: { $0.type == "prompt" }))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(prompt.id ?? ""),
            "command": .string("prompt"),
            "success": .bool(false),
            "error": .string("rejected by runtime"),
        ])))
        try await waitUntil { session.phase == .failed }
        XCTAssertEqual(session.conversation.last?.status, .failed)
        XCTAssertNil(session.activity)
        XCTAssertEqual(session.lastError, "rejected by runtime")
    }

    func testStoppedToolIsCancelledInsteadOfFailed() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "run and stop"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        await transport.emit(.record(Self.messageStartRecord()))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("tool_execution_start"),
            "toolCallId": .string("tool-stop"),
            "toolName": .string("bash"),
            "args": .object(["command": .string("sleep 10")]),
        ])))
        session.abort()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "abort" }) }
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("tool_execution_end"),
            "toolCallId": .string("tool-stop"),
            "result": .object(["content": .array([])]),
            "isError": .bool(true),
        ])))
        await transport.emit(.record(Self.messageEndRecord(text: nil, stopReason: "aborted")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle }

        let tool = try XCTUnwrap(session.conversation.first(where: { $0.kind == .tool }))
        XCTAssertEqual(tool.status, .cancelled)
        XCTAssertNil(session.lastError)
    }

    func testToolUseStartsANewAssistantTurn() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "use a tool"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }

        await transport.emit(.record(Self.messageStartRecord()))
        await transport.emit(.record(Self.textDeltaRecord("before tool")))
        await transport.emit(.record(Self.messageEndRecord(text: "before tool", stopReason: "toolUse")))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("tool_execution_start"),
            "toolCallId": .string("tool-1"),
            "toolName": .string("read"),
            "args": .object(["path": .string("README.md")]),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("tool_execution_end"),
            "toolCallId": .string("tool-1"),
            "toolName": .string("read"),
            "result": .object(["content": .array([])]),
            "isError": .bool(false),
        ])))
        await transport.emit(.record(Self.messageStartRecord()))
        await transport.emit(.record(Self.textDeltaRecord("after tool")))
        await transport.emit(.record(Self.messageEndRecord(text: "after tool", stopReason: "stop")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle }

        let assistants = session.conversation.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.map(\.text), ["before tool", "after tool"])
        XCTAssertTrue(session.conversation.contains(where: { $0.kind == .tool && $0.title == "read" }))
    }

    func testRetryAndCompactionFailuresRemainVisibleAfterSettled() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "retry"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("auto_retry_start")])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("auto_retry_end"),
            "success": .bool(false),
            "finalError": .string("retry exhausted"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .failed }
        XCTAssertEqual(session.lastError, "retry exhausted")
        XCTAssertEqual(session.conversation.last?.status, .failed)

        session.draftPrompt = "compact"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).filter { $0.type == "prompt" }.count == 2 }
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("compaction_start")])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("compaction_end"),
            "errorMessage": .string("compact failed"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.lastError == "compact failed" }
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.conversation.last?.status, .failed)
    }

    func testEOFBecomesVisibleRuntimeFailure() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.finish()
        try await waitUntil { session.phase == .failed }
        XCTAssertEqual(session.runtimeStatus, "Pi Runtime 连接已结束")
        XCTAssertNotNil(session.lastError)
    }

    /// 进程在用户 Abort 后退出属于取消路径，不能把回合改写成失败。
    func testProcessExitAfterAbortPreservesCancellation() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "请停止这个任务"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        session.abort()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "abort" }) }

        await transport.emit(.processExited(status: 143))
        try await waitUntil { session.runtimeTerminationHandled }

        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertEqual(session.terminalRunStatus, .cancelled)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.lastError)
        XCTAssertNil(session.activity)
        XCTAssertTrue(session.conversation.contains(where: { $0.status == .cancelled }))
    }

    /// EOF 必须一次性收束所有 Runtime 请求，但不能丢弃尚未发送的输入。
    func testRuntimeTerminationCleansPendingStateAndRetainsUserInput() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let attachmentURL = root.appendingPathComponent("待发送.txt")
        try "待发送内容".write(to: attachmentURL, atomically: true, encoding: .utf8)
        session.attachFiles([attachmentURL])
        session.queuedPrompts = [
            WorkPiQueuedPrompt(text: "排队任务", attachments: session.pendingAttachments)
        ]
        session.bashExecutions = [BashExecution(id: "bash-1", command: "sleep 10")]
        session.setBashActivity(true)
        session.activeExportCommandID = "export-1"
        session.activeAutoCompactionCommandID = "compact-toggle-1"
        session.activeStatsCommandID = "stats-1"
        session.activeSessionCommandID = "session-1"
        session.extensionUIRequest = try XCTUnwrap(
            PiExtensionUIRequest(record: PiRPCRecord(fields: [
                "type": .string("extension_ui_request"),
                "id": .string("ui-active"),
                "method": .string("confirm"),
            ]))
        )
        session.queuedExtensionUIRequests = [
            try XCTUnwrap(
                PiExtensionUIRequest(record: PiRPCRecord(fields: [
                    "type": .string("extension_ui_request"),
                    "id": .string("ui-queued"),
                    "method": .string("input"),
                ]))
            ),
        ]
        session.extensionUIResponseInFlight = true
        session.modelSwitchInFlight = true
        session.activeModelCommandID = "model-1"

        await transport.finish()
        try await waitUntil { session.runtimeTerminationHandled }

        XCTAssertEqual(session.bashExecutions[0].state, .failed(message: "Pi Runtime 的 RPC 输出已结束。"))
        XCTAssertNil(session.activeExportCommandID)
        XCTAssertNil(session.activeAutoCompactionCommandID)
        XCTAssertNil(session.activeStatsCommandID)
        XCTAssertNil(session.activeSessionCommandID)
        XCTAssertNil(session.extensionUIRequest)
        XCTAssertTrue(session.queuedExtensionUIRequests.isEmpty)
        XCTAssertFalse(session.extensionUIResponseInFlight)
        XCTAssertFalse(session.modelSwitchInFlight)
        XCTAssertNil(session.activeModelCommandID)
        XCTAssertTrue(session.queuedPrompts.count == 1)
        XCTAssertEqual(session.pendingAttachments.map(\.displayName), ["待发送.txt"])
        XCTAssertNil(session.activity)
    }

    /// 收束后到达的旧事件不能重新打开已经失败的回合。
    func testLateSettledEventsCannotReopenFailedRun() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "会失败的任务"
        session.submitPrompt()
        try await waitUntil { (await transport.sentCommands).contains(where: { $0.type == "prompt" }) }
        await transport.emit(.record(Self.messageStartRecord()))
        await transport.emit(.record(Self.messageEndRecord(
            text: "失败内容",
            stopReason: "error"
        )))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil { session.runSettlementHandled }
        let before = session.conversation

        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_start")])))
        await transport.emit(.record(Self.textDeltaRecord("迟到内容")))
        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.runOutcome, .failed)
        XCTAssertEqual(session.conversation, before)
    }

    func testPreviewReadFailureHasDedicatedInspectorError() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let missingFile = root.appendingPathComponent("missing.txt")
        session.selectFile(missingFile)
        try await waitUntil { session.previewError != nil }
        XCTAssertEqual(session.selectedFileURL, missingFile.standardizedFileURL)
        XCTAssertNil(session.selectedPreview)
        XCTAssertNil(session.lastError)

        session.clearFileSelection()
        XCTAssertNil(session.previewError)
        XCTAssertNil(session.selectedFileURL)
    }

    func testFileMonitorRefreshesTreeAndSelectedPreview() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let file = root.appendingPathComponent("watched.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil(timeout: 5) { Self.tree(session.fileTree, contains: file) }

        session.selectFile(file)
        try await waitUntil { session.selectedPreview?.text == "before" }
        try "after".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil(timeout: 5) { session.selectedPreview?.text == "after" }
    }

    func testStatusPanelReadsRuntimeStateWithoutChangingHandshakeState() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.submitPrompt("/status")
        let stateCommand = try await waitForNthCommand(type: "get_state", occurrence: 2, in: transport)
        let statsCommand = try await waitForNthCommand(type: "get_session_stats", occurrence: 2, in: transport)
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(stateCommand.id ?? ""),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "provider": .string("test"),
                    "id": .string("model-2"),
                    "name": .string("Status Model"),
                ]),
                "isStreaming": .bool(false),
                "isCompacting": .bool(false),
                "sessionId": .string("session-2"),
                "sessionName": .string("Status session"),
                "messageCount": .integer(4),
                "pendingMessageCount": .integer(1),
            ]),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(statsCommand.id ?? ""),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object(["totalMessages": .integer(4)]),
        ])))

        try await waitUntil {
            session.runtimeStatusSnapshot?.modelName == "Status Model"
                && session.sessionStats != nil
        }
        XCTAssertTrue(session.runtimeStatusPanelPresented)
        XCTAssertEqual(session.runtimeStatusSnapshot?.pendingMessageCount, 1)
        XCTAssertEqual(session.runtimeStatusSnapshot?.sessionID, "session-2")
        XCTAssertEqual(session.sessionStats?.totalMessages, 4)
    }

    func testAutoRetryControlsDoNotUseFullAbortAndCancellationSettlesRun() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.setAutoRetry(enabled: false)
        let setCommand = try await waitForCommand(type: "set_auto_retry", in: transport)
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(setCommand.id ?? ""),
            "command": .string("set_auto_retry"),
            "success": .bool(true),
        ])))
        try await waitUntil { session.autoRetryEnabled == false }

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("auto_retry_start"),
            "attempt": .integer(1),
            "maxAttempts": .integer(3),
            "delayMs": .integer(500),
        ])))
        try await waitUntil { session.retryWaitState != nil }
        session.abortRetry()
        let abortRetryCommand = try await waitForCommand(type: "abort_retry", in: transport)
        let sentAfterAbortRequest = await transport.sentCommands
        XCTAssertFalse(sentAfterAbortRequest.contains(where: { $0.type == "abort" }))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(abortRetryCommand.id ?? ""),
            "command": .string("abort_retry"),
            "success": .bool(true),
        ])))
        XCTAssertNotNil(session.retryWaitState)
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("auto_retry_end"),
            "success": .bool(false),
            "finalError": .string("Retry cancelled"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))

        try await waitUntil { session.phase == .idle }
        XCTAssertNil(session.retryWaitState)
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertEqual(session.runtimeStatus, "Agent 已停止")
    }

    func testTurnStartAndEndAreRecordedWithoutReplacingAgentSettlement() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: ["type": .string("agent_start")])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("turn_start"),
            "turnIndex": .integer(2),
            "timestamp": .integer(1_000),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("turn_end"),
            "turnIndex": .integer(2),
            "message": .object(["stopReason": .string("stop")]),
            "toolResults": .array([.object([:])]),
        ])))

        try await waitUntil {
            session.turnRecords.count == 1
                && session.turnRecords[0].endedAt != nil
        }
        XCTAssertEqual(session.turnRecords[0].index, 2)
        XCTAssertEqual(session.turnRecords[0].outcome, .completed)
        XCTAssertEqual(session.turnRecords[0].toolResultCount, 1)
        XCTAssertNotNil(session.turnRecords[0].endedAt)
    }

    private func waitForNthCommand(
        type: String,
        occurrence: Int,
        in transport: FakePiRPCTransport
    ) async throws -> PiRPCCommand {
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == type }.count >= occurrence
        }
        let commands = await transport.sentCommands.filter { $0.type == type }
        return try XCTUnwrap(commands[occurrence - 1])
    }

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = FakePiRPCTransport()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { transport }
        )
        return (session, transport, root)
    }

    private func startAndHandshake(
        _ session: PiSessionController,
        _ transport: FakePiRPCTransport,
        _ root: URL
    ) async throws {
        session.openWorkspace(root)
        try await waitUntil { await transport.workspaceURL != nil }
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await emitHandshake(transport)
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }
    }

    private func emitHandshake(_ transport: FakePiRPCTransport) async {
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
    }

    private func waitForCommand(
        type: String,
        in transport: FakePiRPCTransport
    ) async throws -> PiRPCCommand {
        try await waitUntil {
            await transport.sentCommands.contains(where: { $0.type == type })
        }
        let commands = await transport.sentCommands
        return try XCTUnwrap(commands.last(where: { $0.type == type }))
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for WorkPi state")
    }

    private static func tree(_ node: FileNode?, contains url: URL) -> Bool {
        guard let node else { return false }
        let target = url.standardizedFileURL
        if node.url == target { return true }
        return node.children?.contains(where: { tree($0, contains: target) }) == true
    }

    private static func stateRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "name": .string("Test Model"),
                    "contextWindow": .integer(100_000),
                ]),
                "thinkingLevel": .string("medium"),
                "messageCount": .integer(0),
            ]),
        ])
    }

    private static func statsRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object([
                "contextUsage": .object([
                    "tokens": .integer(0),
                    "contextWindow": .integer(100_000),
                    "percent": .integer(0),
                ]),
            ]),
        ])
    }

    private static func messageStartRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("message_start"),
            "message": .object(["role": .string("assistant")]),
        ])
    }

    private static func textDeltaRecord(_ text: String) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string(text),
            ]),
        ])
    }

    private static func messageEndRecord(
        text: String?,
        stopReason: String,
        usage: [String: JSONValue]? = nil
    ) -> PiRPCRecord {
        var content: [JSONValue] = []
        if let text { content = [.object(["type": .string("text"), "text": .string(text)])] }
        var message: [String: JSONValue] = [
            "role": .string("assistant"),
            "stopReason": .string(stopReason),
            "content": .array(content),
        ]
        if let usage {
            message["usage"] = .object(usage)
        }
        return PiRPCRecord(fields: [
            "type": .string("message_end"),
            "message": .object(message),
        ])
    }
}
