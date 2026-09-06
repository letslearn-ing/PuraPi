import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// 第二阶段 Runtime 生命周期的确定性回归测试。
@MainActor
final class RuntimeSafetyRegressionTests: XCTestCase {
    func testLateSettledAfterMessageErrorCannotFinishNextPrompt() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "第一个会失败的任务"
        session.submitPrompt()
        let firstPrompt = try await waitForCommand(type: "prompt", in: transport)
        await transport.emit(.record(Self.messageStart()))
        await transport.emit(.record(Self.messageEnd(stopReason: "error", text: "失败")))
        try await waitUntil { session.runSettlementPending }

        session.draftPrompt = "第二个任务"
        session.submitPrompt()
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["第二个任务"])
        let promptsBeforeSettled = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(promptsBeforeSettled.count, 1)

        // 这是第一个回合的 settled；它只能收束旧回合并触发队列派发，
        // 不能直接把第二个 Assistant 标记为 completed。
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "prompt" }.count == 2
        }
        let assistants = session.conversation.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual(assistants[0].status, .failed)
        XCTAssertEqual(assistants[1].status, .streaming)
        XCTAssertNotEqual(firstPrompt.id, nil)
    }

    func testShellInputIsRetainedDuringSettlementGate() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.phase = .settling
        session.runSettlementPending = true
        session.draftPrompt = "!echo keep-me"
        session.submitPrompt()

        XCTAssertEqual(session.draftPrompt, "!echo keep-me")
        let sentBash = await transport.sentCommands.contains { $0.type == "bash" }
        XCTAssertFalse(sentBash)
    }

    func testBusyFollowUpIsNotSettledByPreviousAgent() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "主任务"
        session.submitPrompt()
        _ = try await waitForCommand(type: "prompt", in: transport)
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))
        session.sendSteeringPrompt("补充要求")
        let steering = try await waitForCommand(type: "steer", in: transport)
        let steeringItemID = try XCTUnwrap(
            session.activeCommandItemIDs[steering.id ?? ""]
        )

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil { session.runSettlementHandled }
        XCTAssertNotEqual(
            session.conversation.first(where: { $0.id == steeringItemID })?.status,
            .completed
        )

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(steering.id ?? ""),
            "command": .string("steer"),
            "success": .bool(true),
        ])))
        try await waitUntil {
            session.conversation.first(where: { $0.id == steeringItemID })?.status == .completed
        }
    }

    func testPreviousCancellationDoesNotCancelNewBashOnRuntimeLoss() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        // 模拟上一个已完成的 Abort：没有当前 Agent run token。
        session.runOutcome = .cancelled
        session.terminalRunStatus = .cancelled
        session.bashExecutions = [BashExecution(id: "bash-new", command: "sleep 10")]
        session.setBashActivity(true)
        let generation = session.generation

        session.handleRuntimeTermination(.eof, generation: generation)

        XCTAssertEqual(
            session.bashExecutions[0].state,
            .failed(message: "Pi Runtime 的 RPC 输出已结束。")
        )
        XCTAssertNotNil(session.lastError)
        XCTAssertEqual(session.runtimeNotice, "Pi Runtime 已断开。请重新连接后再发送。")
        _ = transport
    }

    func testAbortFailureCleansAllVisibleRunState() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "需要停止的任务"
        session.submitPrompt()
        _ = try await waitForCommand(type: "prompt", in: transport)
        await transport.emit(.record(Self.messageStart()))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("tool_execution_start"),
            "toolCallId": .string("tool-1"),
            "toolName": .string("bash"),
        ])))
        session.abort()
        let abort = try await waitForCommand(type: "abort", in: transport)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(abort.id ?? ""),
            "command": .string("abort"),
            "success": .bool(false),
            "error": .string("abort rejected"),
        ])))

        try await waitUntil { session.phase == .failed && session.activeAbortCommandID == nil }
        XCTAssertNil(session.activity)
        XCTAssertTrue(session.conversation.contains {
            $0.kind == .assistant && $0.status == .failed
        })
        XCTAssertTrue(session.conversation.contains {
            $0.kind == .tool && $0.status != .streaming && $0.status != .pending
        })
        XCTAssertEqual(session.lastError, "abort rejected")
    }

    func testIndependentBashAfterAgentCancellationReportsRuntimeFailure() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "取消 Agent"
        session.submitPrompt()
        _ = try await waitForCommand(type: "prompt", in: transport)
        session.abort()
        let abort = try await waitForCommand(type: "abort", in: transport)
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(abort.id ?? ""),
            "command": .string("abort"),
            "success": .bool(true),
        ])))
        try await waitUntil { session.phase == .idle }

        session.runBashCommand("sleep 10")
        _ = try await waitForCommand(type: "bash", in: transport)
        await transport.emit(.processExited(status: 1))
        try await waitUntil { session.runtimeTerminationHandled }

        XCTAssertEqual(session.bashExecutions.first?.state, .failed(message: "Pi Runtime 异常退出，状态码：1。"))
        XCTAssertNotNil(session.lastError)
    }

    func testPromptSendFailureRestoresAttachments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-attachment-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectiveFailTransport(failingTypes: ["prompt"])
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { transport }
        )
        session.openWorkspace(root)
        try await waitUntil { await transport.workspaceURL != nil }
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "get_state" }.count == 1
        }
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeReady }

        let file = root.appendingPathComponent("context.txt")
        try "important context".write(to: file, atomically: true, encoding: .utf8)
        session.attachFiles([file])
        session.draftPrompt = "请读取附件"
        session.submitPrompt()

        try await waitUntil {
            session.pendingAttachments.map(\.displayName) == ["context.txt"]
        }
        XCTAssertEqual(session.pendingAttachments.count, 1)
        XCTAssertEqual(session.phase, .failed)
    }

    func testFreshSessionDoesNotDispatchOldQueueAndRetainsBashTerminalState() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.queuedPrompts = [PuraPiQueuedPrompt(text: "旧队列")]
        session.bashExecutions = [BashExecution(id: "running", command: "sleep 10")]
        session.startNewSession()

        XCTAssertTrue(session.queuedPrompts.isEmpty)
        XCTAssertEqual(session.bashExecutions.first?.state, .cancelled)
        XCTAssertEqual(session.runtimeNotice, "新会话不会发送旧会话的排队任务 1 条。")
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "get_state" }.count >= 2
        }
        let promptsAfterRestart = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(promptsAfterRestart.count, 0)
    }

    func testSessionRebuildBlocksPromptUntilHistoryIsReady() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)
        session.activeSessionFilePath = root.appendingPathComponent("current.jsonl").path
        let summary = PiSessionSummary(
            fileURL: root.appendingPathComponent("other.jsonl"),
            sessionID: "other",
            createdAt: Date(),
            modifiedAt: Date(),
            cwd: root.path
        )

        session.switchToSession(summary)
        let switchCommand = try await waitForCommand(type: "switch_session", in: transport)
        session.draftPrompt = "不能抢跑"
        session.submitPrompt()
        let promptsDuringRebuild = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(promptsDuringRebuild.count, 0)
        XCTAssertTrue(session.sessionRebuildInFlight == false)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(switchCommand.id ?? ""),
            "command": .string("switch_session"),
            "success": .bool(true),
        ])))
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.filter { $0 == "get_state" }.count >= 2
                && types.filter { $0 == "get_session_stats" }.count >= 2
                && types.filter { $0 == "get_messages" }.count >= 1
        }
        XCTAssertTrue(session.sessionRebuildInFlight)
        session.draftPrompt = "重建期间保留"
        session.submitPrompt()
        XCTAssertEqual(session.draftPrompt, "重建期间保留")
        XCTAssertTrue(session.queuedPrompts.isEmpty)
        let commands = await transport.sentCommands
        let rebuildState = try XCTUnwrap(commands.last(where: { $0.type == "get_state" }))
        let rebuildStats = try XCTUnwrap(commands.last(where: { $0.type == "get_session_stats" }))
        let rebuildMessages = try XCTUnwrap(commands.last(where: { $0.type == "get_messages" }))
        await transport.emit(.record(Self.stateRecord(id: rebuildState.id)))
        await transport.emit(.record(Self.statsRecord(id: rebuildStats.id)))
        await transport.emit(.record(Self.messagesRecord(id: rebuildMessages.id)))
        try await waitUntil { session.runtimeReady && !session.sessionRebuildInFlight }
        XCTAssertEqual(session.phase, .idle)
    }

    func testProcessExitAfterAbortConfirmationKeepsCancellationOutcome() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "先确认停止再退出"
        session.submitPrompt()
        _ = try await waitForCommand(type: "prompt", in: transport)
        session.abort()
        let abort = try await waitForCommand(type: "abort", in: transport)
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(abort.id ?? ""),
            "command": .string("abort"),
            "success": .bool(true),
        ])))
        try await waitUntil { session.phase == .idle && session.activeAbortCommandID == nil }

        await transport.emit(.processExited(status: 143))
        try await waitUntil { session.runtimeTerminationHandled }
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertNil(session.lastError)
    }

    func testCancelledProcessExitHasVisibleRuntimeNotice() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "停止后 Runtime 退出"
        session.submitPrompt()
        _ = try await waitForCommand(type: "prompt", in: transport)
        session.abort()
        _ = try await waitForCommand(type: "abort", in: transport)
        await transport.emit(.processExited(status: 143))

        try await waitUntil { session.runtimeTerminationHandled }
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(
            session.runtimeNotice,
            "Agent 已停止，但 Pi Runtime 已退出。请重新连接后再发送。"
        )
    }

    func testSettlementTimeoutQuarantineRejectsDirectNewRun() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.phase = .failed
        session.runOutcome = .failed
        session.terminalRunStatus = .failed
        session.runtimeSettlementQuarantined = true
        session.draftPrompt = "不能越过隔离"
        session.submitPromptText("不能越过隔离")

        XCTAssertEqual(session.draftPrompt, "不能越过隔离")
        XCTAssertTrue(session.runtimeSettlementQuarantined)
        let sentPrompts = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertTrue(sentPrompts.isEmpty)

        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ]))
        XCTAssertFalse(session.runtimeSettlementQuarantined)
    }

    func testOpeningAnotherWorkspaceWaitsForPreviousTransportStop() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondRoot) }

        session.openWorkspace(secondRoot)
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "get_state" }.count >= 2
        }
        let activeRoot = await transport.workspaceURL
        XCTAssertEqual(activeRoot, secondRoot.standardizedFileURL)
    }

    func testRuntimeDisconnectOffersReconnectAndRestoresHandshake() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.handleRuntimeTermination(.eof, generation: session.generation)
        XCTAssertTrue(session.canReconnectRuntime)
        try await Task.sleep(for: .milliseconds(80))
        session.reconnectRuntime()

        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "get_state" }.count >= 2
        }
        let commands = await transport.sentCommands
        let state = try XCTUnwrap(commands.last(where: { $0.type == "get_state" }))
        let stats = try XCTUnwrap(commands.last(where: { $0.type == "get_session_stats" }))
        let messages = try XCTUnwrap(commands.last(where: { $0.type == "get_messages" }))
        await transport.emit(.record(Self.stateRecord(id: state.id)))
        await transport.emit(.record(Self.statsRecord(id: stats.id)))
        await transport.emit(.record(Self.messagesRecord(id: messages.id)))
        try await waitUntil { session.runtimeReady }
        XCTAssertNil(session.runtimeNotice)
    }

    func testIDlessStatsCannotStealBootstrapRequest() {
        let session = PiSessionController()
        let bootstrap = PiRPCCommand.getSessionStats(id: "bootstrap-stats")
        let status = PiRPCCommand.getSessionStats(id: "status-stats")
        session.registerRuntimeRequest(bootstrap, purpose: .bootstrap)
        session.registerRuntimeRequest(status, purpose: .status)
        session.activeStatsCommandID = status.id

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
        ]))

        XCTAssertNotNil(session.runtimeRequests[bootstrap.id ?? ""])
        XCTAssertNotNil(session.runtimeRequests[status.id ?? ""])
        XCTAssertNil(session.sessionStats)
    }

    func testRebuildIgnoresLateRefreshStateResponse() {
        let session = PiSessionController()
        session.activeSessionFilePath = "/sessions/current.jsonl"
        session.sessionRebuildInFlight = true
        let old = PiRPCCommand.getState(id: "old-refresh")
        let current = PiRPCCommand.getState(id: "current-rebuild")
        session.registerRuntimeRequest(old, purpose: .refresh)
        session.registerRuntimeRequest(current, purpose: .rebuild)

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "id": .string("old-refresh"),
            "success": .bool(true),
            "data": .object([
                "sessionFile": .string("/sessions/old.jsonl"),
                "sessionName": .string("旧会话"),
            ]),
        ]))

        XCTAssertEqual(session.activeSessionFilePath, "/sessions/current.jsonl")
        XCTAssertNotNil(session.runtimeRequests[current.id ?? ""])
    }

    func testClosePreservesAttachmentsWhilePromptSendIsInFlight() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let file = root.appendingPathComponent("in-flight.txt")
        try "must survive".write(to: file, atomically: true, encoding: .utf8)
        session.attachFiles([file])
        session.draftPrompt = "发送后立即关闭"
        session.submitPrompt()
        _ = try await waitForCommand(type: "prompt", in: transport)

        XCTAssertFalse(session.closeWorkspace())
        XCTAssertTrue(session.hasUnsentComposerInput)
        XCTAssertEqual(session.activePromptAttachments.map(\.displayName), ["in-flight.txt"])
        session.discardComposerInput()
        XCTAssertTrue(session.closeWorkspace())
    }

    func testIDlessResponseIsIgnoredWhenRequestsAreAmbiguous() {
        let session = PiSessionController()
        let first = PiRPCCommand.getSessionStats(id: "stats-a")
        let second = PiRPCCommand.getSessionStats(id: "stats-b")
        session.registerRuntimeRequest(first, purpose: .refresh)
        session.registerRuntimeRequest(second, purpose: .refresh)

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
        ]))

        XCTAssertTrue(session.hasRuntimeRequest(for: "get_session_stats", purposes: [.refresh]))
    }

    func testRuntimeRequestTimeoutClearsTrackedOperation() {
        let session = PiSessionController()
        let command = PiRPCCommand.getCommands(id: "commands-timeout")
        session.activeCommandsRequestID = command.id
        session.commandsRequestInFlight = true
        session.registerRuntimeRequest(command, purpose: .operation)
        let request = session.runtimeRequests[command.id ?? ""]
        XCTAssertNotNil(request)

        if let request {
            session.handleRuntimeRequestTimeout(request)
        }

        XCTAssertFalse(session.commandsRequestInFlight)
        XCTAssertNil(session.activeCommandsRequestID)
        XCTAssertNil(session.runtimeRequests[command.id ?? ""])
        XCTAssertNotNil(session.lastError)
    }

    func testUnsolicitedStaleModelResponseIsIgnored() {
        let session = PiSessionController()
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_model"),
            "id": .string("old-model"),
            "success": .bool(true),
            "data": .object([
                "id": .string("unexpected"),
                "provider": .string("unknown"),
                "name": .string("Unexpected"),
            ]),
        ]))

        XCTAssertNil(session.runtimeMetadata.modelID)
        XCTAssertNil(session.lastError)
    }

    func testConcurrentStatusRequestsSettleTheirOwnItems() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let firstID = session.appendCommandActivity("/status 1")
        let secondID = session.appendCommandActivity("/status 2")
        session.requestSessionStats(commandItemID: firstID)
        session.requestSessionStats(commandItemID: secondID)
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "get_session_stats" }.count >= 3
        }
        let statsCommands = await transport.sentCommands.filter { $0.type == "get_session_stats" }
        let statusCommands = Array(statsCommands.dropFirst(1))
        let first = try XCTUnwrap(statusCommands.first)
        let second = try XCTUnwrap(statusCommands.last)
        await transport.emit(.record(Self.statsRecord(id: first.id)))
        await transport.emit(.record(Self.statsRecord(id: second.id)))
        try await waitUntil {
            session.conversation.first(where: { $0.id == firstID })?.status == .completed
                && session.conversation.first(where: { $0.id == secondID })?.status == .completed
        }
    }

    // MARK: - Helpers

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-safety-\(UUID().uuidString)", isDirectory: true)
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
            await transport.sentCommands.contains { $0.type == "get_state" }
        }
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeReady }
    }

    private func waitForCommand(
        type: String,
        in transport: FakePiRPCTransport
    ) async throws -> PiRPCCommand {
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == type }
        }
        let commands = await transport.sentCommands
        return try XCTUnwrap(commands.last(where: { $0.type == type }))
    }

    private func waitUntil(
        timeout: TimeInterval = 4,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for Runtime safety state")
    }

    private static func stateRecord(id: String? = nil) -> PiRPCRecord {
        var fields: [String: JSONValue] = [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "id": .string("gpt-test"),
                    "provider": .string("test"),
                    "name": .string("Test model"),
                    "reasoning": .bool(true),
                ]),
                "thinkingLevel": .string("medium"),
                "messageCount": .integer(0),
            ]),
        ]
        if let id { fields["id"] = .string(id) }
        return PiRPCRecord(fields: fields)
    }

    private static func statsRecord(id: String? = nil) -> PiRPCRecord {
        var fields: [String: JSONValue] = [
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
        ]
        if let id { fields["id"] = .string(id) }
        return PiRPCRecord(fields: fields)
    }

    private static func messagesRecord(id: String? = nil) -> PiRPCRecord {
        var fields: [String: JSONValue] = [
            "type": .string("response"),
            "command": .string("get_messages"),
            "success": .bool(true),
            "data": .object(["messages": .array([])]),
        ]
        if let id { fields["id"] = .string(id) }
        return PiRPCRecord(fields: fields)
    }

    private static func messageStart() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("message_start"),
            "message": .object(["role": .string("assistant")]),
        ])
    }

    private static func messageEnd(stopReason: String, text: String) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"),
                "text": .string(text),
                "stopReason": .string(stopReason),
            ]),
        ])
    }
}

private struct SelectiveTransportError: Error {}

private actor SelectiveFailTransport: PiRPCTransport {
    private let failingTypes: Set<String>
    private var continuation: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
    private(set) var sentCommands: [PiRPCCommand] = []
    private(set) var workspaceURL: URL?
    private var running = false

    init(failingTypes: Set<String>) {
        self.failingTypes = failingTypes
    }

    func start(in workspaceURL: URL) async throws -> AsyncThrowingStream<PiRPCTransportEvent, Error> {
        guard !running else { throw PiRPCError.alreadyRunning }
        running = true
        self.workspaceURL = workspaceURL
        var captured: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<PiRPCTransportEvent, Error> { continuation in
            captured = continuation
        }
        continuation = captured
        return stream
    }

    func send(_ command: PiRPCCommand) async throws {
        guard running else { throw PiRPCError.notRunning }
        sentCommands.append(command)
        if failingTypes.contains(command.type) {
            throw SelectiveTransportError()
        }
    }

    func emit(_ event: PiRPCTransportEvent) {
        continuation?.yield(event)
    }

    func stop() async {
        running = false
        continuation?.finish()
        continuation = nil
    }
}
