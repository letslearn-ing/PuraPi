import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// Runtime 边界审计：验证停止屏障、请求归属、迟到事件和终态隔离。
@MainActor
final class RuntimeBoundaryAuditTests: XCTestCase {
    func testFreshBootstrapTimeoutCancelsSiblingRequests() {
        let session = PiSessionController()
        session.expectsMessagesResponse = false
        session.runtimeReady = false
        let state = PiRPCCommand.getState(id: "bootstrap-state")
        let stats = PiRPCCommand.getSessionStats(id: "bootstrap-stats")
        session.registerRuntimeRequest(state, purpose: .bootstrap)
        session.registerRuntimeRequest(stats, purpose: .bootstrap)

        let request = session.runtimeRequests[state.id ?? ""]
        XCTAssertNotNil(request)
        if let request {
            session.handleRuntimeRequestTimeout(request)
        }

        XCTAssertTrue(session.runtimeRequests.isEmpty)
        XCTAssertFalse(session.runtimeReady)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.lastError, "Pi RPC 请求超时：get_state")

        // 兄弟请求的迟到响应不能重新推进失败的握手。
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "id": .string("bootstrap-stats"),
            "success": .bool(true),
        ]))
        XCTAssertFalse(session.receivedStatsResponse)
        XCTAssertFalse(session.runtimeReady)
    }

    func testSettledRequestTicketKeepsItsSessionEpochAfterRegistryTrim() {
        let session = PiSessionController()
        let oldEpoch = session.sessionEpoch
        let oldCommand = PiRPCCommand.getState(id: "old-ticket")
        session.registerRuntimeRequest(oldCommand, purpose: .operation)
        session.sessionEpoch = UUID()

        for index in 0...2_048 {
            let command = PiRPCCommand.getState(id: "trim-\(index)")
            session.registerRuntimeRequest(command, purpose: .operation)
            if let request = session.runtimeRequests[command.id ?? ""] {
                _ = session.settleRuntimeRequest(request)
            }
        }

        XCTAssertEqual(session.runtimeRequestSessionEpochs[oldCommand.runtimeTicketID], oldEpoch)
    }

    func testCancelledRequestBlocksLateIDResponseForReplacementRequest() {
        let session = PiSessionController()
        let old = PiRPCCommand.getCommands(id: "commands-old")
        session.commandsRequestInFlight = true
        session.activeCommandsRequestID = old.id
        session.registerRuntimeRequest(old, purpose: .operation)
        session.cancelAllRuntimeRequests()

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_commands"),
            "id": .string("commands-old"),
            "success": .bool(true),
        ]))
        XCTAssertTrue(session.commandsRequestInFlight)
        XCTAssertEqual(session.activeCommandsRequestID, old.id)

        let replacement = PiRPCCommand.getCommands(id: "commands-replacement")
        session.registerRuntimeRequest(replacement, purpose: .operation)
        session.activeCommandsRequestID = replacement.id
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_commands"),
            "id": .string("commands-replacement"),
            "success": .bool(true),
            "data": .object(["commands": .array([])]),
        ]))
        XCTAssertFalse(session.commandsRequestInFlight)
    }

    func testCancelledRequestBlocksLateIDlessResponseForReplacementRequest() {
        let session = PiSessionController()
        let old = PiRPCCommand.getState(id: "state-old")
        session.registerRuntimeRequest(old, purpose: .refresh)
        session.cancelAllRuntimeRequests()

        let replacement = PiRPCCommand.getState(id: "state-replacement")
        session.registerRuntimeRequest(replacement, purpose: .rebuild)
        session.sessionRebuildInFlight = true
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object(["sessionFile": .string("/stale.jsonl")]),
        ]))

        XCTAssertNotNil(session.runtimeRequests[replacement.id ?? ""])
        XCTAssertNil(session.activeSessionFilePath)
    }

    func testIDlessStateResponseIsIgnoredWhenRefreshRequestsAreAmbiguous() {
        let session = PiSessionController()
        let first = PiRPCCommand.getState(id: "state-a")
        let second = PiRPCCommand.getState(id: "state-b")
        session.registerRuntimeRequest(first, purpose: .refresh)
        session.registerRuntimeRequest(second, purpose: .refresh)

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object(["sessionFile": .string("/wrong.jsonl")]),
        ]))

        XCTAssertNotNil(session.runtimeRequests[first.id ?? ""])
        XCTAssertNotNil(session.runtimeRequests[second.id ?? ""])
        XCTAssertNil(session.activeSessionFilePath)
    }

    func testTimedOutSessionOperationRequiresReconnectBeforePrompt() {
        let session = PiSessionController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-boundary-session-timeout-\(UUID().uuidString)", isDirectory: true)
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.runtimeReady = true
        let command = PiRPCCommand.switchSession(
            sessionPath: "/sessions/other.jsonl",
            id: "switch-timeout"
        )
        session.activeSessionCommandID = command.id
        session.registerRuntimeRequest(command, purpose: .operation)
        let request = session.runtimeRequests[command.id ?? ""]
        XCTAssertNotNil(request)
        if let request {
            session.handleRuntimeRequestTimeout(request)
        }

        XCTAssertFalse(session.runtimeReady)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(session.canReconnectRuntime)
        XCTAssertNil(session.activeSessionCommandID)
        session.draftPrompt = "不能抢跑"
        session.submitPrompt()
        XCTAssertEqual(session.draftPrompt, "不能抢跑")
    }

    func testRefreshResponseCannotRewriteIdentityDuringSessionOperation() {
        let session = PiSessionController()
        session.activeSessionFilePath = "/sessions/current.jsonl"
        let switchCommand = PiRPCCommand.switchSession(sessionPath: "/sessions/other.jsonl", id: "switch")
        let refreshCommand = PiRPCCommand.getState(id: "refresh")
        session.activeSessionCommandID = switchCommand.id
        session.registerRuntimeRequest(switchCommand, purpose: .operation)
        session.registerRuntimeRequest(refreshCommand, purpose: .refresh)

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "id": .string("refresh"),
            "success": .bool(true),
            "data": .object(["sessionFile": .string("/sessions/wrong.jsonl")]),
        ]))

        XCTAssertEqual(session.activeSessionFilePath, "/sessions/current.jsonl")
        XCTAssertNotNil(session.runtimeRequests[switchCommand.id ?? ""])
    }

    func testReusedRPCIDCannotLetOldTimeoutSettleNewRegistration() {
        let session = PiSessionController()
        let first = PiRPCCommand.getCommands(id: "reused-id")
        session.registerRuntimeRequest(first, purpose: .operation)
        let oldRequest = session.runtimeRequests["reused-id"]
        let second = PiRPCCommand.getCommands(id: "reused-id")
        session.registerRuntimeRequest(second, purpose: .operation)
        let newRequest = session.runtimeRequests["reused-id"]

        XCTAssertNotEqual(oldRequest?.registrationID, newRequest?.registrationID)
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_commands"),
            "id": .string("reused-id"),
            "success": .bool(true),
        ]))
        XCTAssertEqual(session.runtimeRequests["reused-id"], newRequest)
        if let oldRequest {
            session.handleRuntimeRequestTimeout(oldRequest)
        }
        XCTAssertEqual(session.runtimeRequests["reused-id"], newRequest)

        if let newRequest {
            session.handleRuntimeRequestTimeout(newRequest)
        }
        XCTAssertNil(session.runtimeRequests["reused-id"])
    }

    func testReusedRPCIDAfterSuccessfulSettlementStaysAmbiguous() {
        let session = PiSessionController()
        let first = PiRPCCommand.getCommands(id: "settled-reused")
        session.registerRuntimeRequest(first, purpose: .operation)
        XCTAssertTrue(session.settleRuntimeRequest(id: first.id))

        let second = PiRPCCommand.getCommands(id: "settled-reused")
        session.registerRuntimeRequest(second, purpose: .operation)
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_commands"),
            "id": .string("settled-reused"),
            "success": .bool(true),
        ]))
        XCTAssertNotNil(session.runtimeRequests[second.id ?? ""])
    }

    func testTimedOutOperationIgnoresDuplicateResponse() {
        let session = PiSessionController()
        let command = PiRPCCommand.getCommands(id: "commands-late")
        session.commandsRequestInFlight = true
        session.activeCommandsRequestID = command.id
        session.registerRuntimeRequest(command, purpose: .operation)
        let request = session.runtimeRequests[command.id ?? ""]
        XCTAssertNotNil(request)
        if let request {
            session.handleRuntimeRequestTimeout(request)
        }

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_commands"),
            "id": .string("commands-late"),
            "success": .bool(true),
            "data": .object(["commands": .array([])]),
        ]))

        XCTAssertFalse(session.commandsRequestInFlight)
        XCTAssertNil(session.activeCommandsRequestID)
        XCTAssertTrue(session.piCommands.isEmpty)
    }

    func testPromptIsRetainedWhileSessionOperationAwaitsConfirmation() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)
        session.activeSessionFilePath = root.appendingPathComponent("current.jsonl").path
        let other = PiSessionSummary(
            fileURL: root.appendingPathComponent("other.jsonl"),
            sessionID: "other",
            createdAt: Date(),
            modifiedAt: Date(),
            cwd: root.path
        )
        XCTAssertTrue(session.switchToSession(other))
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "switch_session" }
        }

        session.draftPrompt = "不能落入旧会话"
        session.submitPrompt()

        XCTAssertEqual(session.draftPrompt, "不能落入旧会话")
        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertTrue(prompts.isEmpty)
    }

    func testSettledBeforeNewRunStartsCannotFinishNewPrompt() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "第一回合"
        session.submitPrompt()
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))
        session.consume(PiRPCRecord(fields: [
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"),
                "stopReason": .string("stop"),
            ]),
        ]))
        session.consume(PiRPCRecord(fields: ["type": .string("agent_settled")]))
        XCTAssertEqual(session.phase, .idle)

        session.draftPrompt = "第二回合"
        session.submitPrompt()
        let secondRunID = session.activeAgentRunID
        session.consume(PiRPCRecord(fields: ["type": .string("agent_settled")]))
        XCTAssertEqual(session.activeAgentRunID, secondRunID)
        XCTAssertEqual(session.phase, .requesting)
        XCTAssertEqual(session.runOutcome, .running)

        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))
        session.consume(PiRPCRecord(fields: ["type": .string("agent_settled")]))
        XCTAssertEqual(session.phase, .idle)
    }

    func testDuplicateToolStartDoesNotCreateDuplicateConversationItem() {
        let session = PiSessionController()
        session.activeAgentRunID = UUID()
        session.runOutcome = .running
        session.phase = .requesting
        let event = PiRPCRecord(fields: [
            "type": .string("tool_execution_start"),
            "toolCallId": .string("tool-duplicate"),
            "toolName": .string("read"),
        ])

        session.consume(event)
        session.consume(event)

        XCTAssertEqual(session.conversation.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(session.toolItemIDs.count, 1)
    }

    func testDuplicateAgentSettledCannotChangeCompletedRun() {
        let session = PiSessionController()
        let assistant = ConversationItem(kind: .assistant, status: .streaming)
        session.conversation = [assistant]
        session.currentAssistantItemID = assistant.id
        session.activeAgentRunID = UUID()
        session.runOutcome = .running
        session.phase = .streaming

        session.consume(PiRPCRecord(fields: [
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"),
                "content": .string("完成"),
                "stopReason": .string("stop"),
            ]),
        ]))
        session.consume(PiRPCRecord(fields: ["type": .string("agent_settled")]))
        let count = session.conversation.count
        let outcome = session.runOutcome
        let phase = session.phase
        session.consume(PiRPCRecord(fields: ["type": .string("agent_settled")]))

        XCTAssertEqual(session.conversation.count, count)
        XCTAssertEqual(session.runOutcome, outcome)
        XCTAssertEqual(session.phase, phase)
        XCTAssertEqual(session.runOutcome, .completed)
        XCTAssertEqual(session.phase, .idle)
    }

    func testProviderAbortedStopReasonIsCancelledEvenWithoutLocalAbort() {
        let session = PiSessionController()
        let assistant = ConversationItem(kind: .assistant, status: .streaming)
        session.conversation = [assistant]
        session.currentAssistantItemID = assistant.id
        session.activeAgentRunID = UUID()
        session.runOutcome = .running
        session.phase = .streaming

        session.consume(PiRPCRecord(fields: [
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"),
                "stopReason": .string("aborted"),
            ]),
        ]))

        XCTAssertEqual(session.conversation[0].status, .cancelled)
        XCTAssertEqual(session.runOutcome, .cancelled)
        XCTAssertEqual(session.terminalRunStatus, .cancelled)
    }

    func testRejectedAbortQuarantinesTheStillRunningRemoteRun() {
        let session = PiSessionController()
        let command = PiRPCCommand.abort(id: "abort-rejected")
        session.activeAbortCommandID = command.id
        session.activeAgentRunID = UUID()
        session.activeAgentRunStarted = true
        session.runOutcome = .cancelled
        session.phase = .cancelled
        session.abortRequested = true
        session.registerRuntimeRequest(command, purpose: .operation)

        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("abort"),
            "id": .string("abort-rejected"),
            "success": .bool(false),
            "error": .string("拒绝停止"),
        ]))

        XCTAssertTrue(session.runtimeSettlementQuarantined)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.activeAgentRunID)
    }

    func testAbortTimeoutQuarantinesLateAgentEvents() async throws {
        let session = PiSessionController()
        let command = PiRPCCommand.abort(id: "abort-timeout")
        session.activeAbortCommandID = command.id
        session.activeAgentRunID = UUID()
        session.activeAgentRunStarted = true
        session.runOutcome = .cancelled
        session.phase = .cancelled
        session.abortRequested = true
        session.abortRequestedRunID = session.activeAgentRunID
        session.registerRuntimeRequest(command, purpose: .operation)
        session.scheduleAbortTimeout(for: session.generation, timeout: .milliseconds(20))

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.runtimeSettlementQuarantined)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.activeAgentRunID)
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))
        XCTAssertNil(session.activeAgentRunID)
    }

    func testAbortRemainsAvailableForAnActiveRunDuringQuarantine() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)
        session.activeAgentRunID = UUID()
        session.activeAgentRunStarted = true
        session.runOutcome = .running
        session.phase = .streaming
        session.runtimeSettlementQuarantined = true

        session.abort()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "abort" }
        }
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertNotNil(session.activeAbortCommandID)
    }

    func testTimedOutFollowUpCannotOpenAStaleAgentRun() {
        let session = PiSessionController()
        let command = PiRPCCommand.followUp("旧 follow-up", id: "follow-up-timeout")
        session.registerRuntimeRequest(command, purpose: .operation)
        let request = session.runtimeRequests[command.id ?? ""]
        XCTAssertNotNil(request)
        if let request {
            session.handleRuntimeRequestTimeout(request)
        }

        XCTAssertTrue(session.runtimeSettlementQuarantined)
        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ]))
        XCTAssertNil(session.activeAgentRunID)
        XCTAssertTrue(session.runtimeSettlementQuarantined)
    }

    func testTimedOutPromptQuarantinesLateAgentEventsBeforeRetry() {
        let session = PiSessionController()
        let command = PiRPCCommand.prompt("旧 Prompt", id: "prompt-timeout")
        session.activePromptCommandID = command.id
        session.activeAgentRunID = UUID()
        session.runOutcome = .running
        session.phase = .requesting
        session.registerRuntimeRequest(command, purpose: .operation)
        let request = session.runtimeRequests[command.id ?? ""]
        XCTAssertNotNil(request)
        if let request {
            session.handleRuntimeRequestTimeout(request)
        }

        XCTAssertTrue(session.runtimeSettlementQuarantined)
        XCTAssertTrue(session.runSettlementHandled)
        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ]))
        XCTAssertTrue(session.runSettlementHandled)
        XCTAssertNil(session.activeAgentRunID)

        // 迟到 settled 只解除旧回合隔离；在没有新 agent_start 前不能再结算任何回合。
        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ]))
        XCTAssertFalse(session.runtimeSettlementQuarantined)
        XCTAssertTrue(session.ignoreSettledUntilAgentStart)
    }

    func testTimedOutIDlessResponseCannotSettleARetriedRequest() {
        let session = PiSessionController()
        let first = PiRPCCommand.getSessionStats(id: "stats-old")
        session.registerRuntimeRequest(first, purpose: .refresh)
        let oldRequest = session.runtimeRequests[first.id ?? ""]
        XCTAssertNotNil(oldRequest)
        if let oldRequest {
            session.handleRuntimeRequestTimeout(oldRequest)
        }

        let retry = PiRPCCommand.getSessionStats(id: "stats-retry")
        session.registerRuntimeRequest(retry, purpose: .refresh)
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object(["totalMessages": .integer(99)]),
        ]))

        XCTAssertNotNil(session.runtimeRequests[retry.id ?? ""])
        XCTAssertNil(session.sessionStats)
    }

    func testQuarantineReleaseWhileRuntimeIsUnavailableKeepsReconnectAndQueueState() async throws {
        let session = PiSessionController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-boundary-unavailable-\(UUID().uuidString)", isDirectory: true)
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.runtimeReady = false
        session.phase = .failed
        session.runOutcome = .failed
        session.terminalRunStatus = .failed
        session.runtimeSettlementQuarantined = true
        session.queuedPrompts = [PuraPiQueuedPrompt(text: "不能在失联时派发")]

        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ]))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(session.runtimeSettlementQuarantined)
        XCTAssertTrue(session.canReconnectRuntime)
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["不能在失联时派发"])
    }

    func testCancelledQuarantineReleaseWhileRuntimeIsUnavailableKeepsReconnect() async throws {
        let session = PiSessionController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-boundary-cancelled-unavailable-\(UUID().uuidString)", isDirectory: true)
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.runtimeReady = false
        session.phase = .failed
        session.runOutcome = .cancelled
        session.terminalRunStatus = .cancelled
        session.runtimeSettlementQuarantined = true
        session.queuedPrompts = [PuraPiQueuedPrompt(text: "等待重连")]

        session.consume(PiRPCRecord(fields: ["type": .string("agent_settled")]))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(session.canReconnectRuntime)
        XCTAssertEqual(session.queuedPrompts.count, 1)
        XCTAssertNotNil(session.runtimeNotice)
    }

    func testLateSettledAfterRuntimeTerminationCannotClearReconnectState() {
        let session = PiSessionController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-boundary-\(UUID().uuidString)", isDirectory: true)
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.runtimeReady = true
        session.phase = .streaming
        session.runOutcome = .running
        session.activeAgentRunID = UUID()
        session.currentAssistantItemID = UUID()
        session.queuedPrompts = [PuraPiQueuedPrompt(text: "保留到重连")]
        let generation = session.generation

        session.handleRuntimeTermination(.eof, generation: generation)
        let notice = session.runtimeNotice
        let queuedCount = session.queuedPrompts.count
        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ]))
        session.handleRuntimeTermination(
            .processExited(1),
            generation: generation
        )

        XCTAssertEqual(session.runtimeNotice, notice)
        XCTAssertEqual(session.queuedPrompts.count, queuedCount)
        XCTAssertTrue(session.canReconnectRuntime)
        XCTAssertEqual(session.phase, .failed)
    }

    func testLateSettledQuarantineDispatchesOnlyAfterItselfAndNotAsSettlement() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.phase = .failed
        session.runOutcome = .failed
        session.terminalRunStatus = .failed
        session.runSettlementHandled = true
        session.runtimeSettlementQuarantined = true
        session.queuedPrompts = [PuraPiQueuedPrompt(text: "新回合")]

        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ]))

        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "prompt" }.count == 1
        }
        XCTAssertFalse(session.runtimeSettlementQuarantined)
        XCTAssertEqual(session.phase, .requesting)
        XCTAssertEqual(session.runOutcome, .running)
        XCTAssertFalse(session.runSettlementHandled)

        let sentCommands = await transport.sentCommands
        let prompt = try XCTUnwrap(
            sentCommands.last(where: { $0.type == "prompt" })
        )
        // 再来一条旧 settled，不能结束刚派发的新回合。
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(session.phase, .requesting)
        XCTAssertEqual(session.runOutcome, .running)
        XCTAssertNotNil(session.runtimeRequests[prompt.id ?? ""])

        // 真实新回合已经发出 agent_start 后，自己的 settled 仍必须能够正常收束。
        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ]))
        session.consume(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ]))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.runOutcome, .completed)
    }

    func testDuplicateReconnectUsesOneStopBarrier() async throws {
        let (session, transport, root) = try makeBlockingSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.handleRuntimeTermination(.eof, generation: session.generation)
        try await waitUntil { await transport.stopStarted }
        session.reconnectRuntime()
        session.reconnectRuntime()
        await transport.releaseStop()

        try await waitUntil { await transport.startCount == 2 }
        let startCount = await transport.startCount
        let startedWhileStopping = await transport.startedWhileStopping
        XCTAssertEqual(startCount, 2)
        XCTAssertFalse(startedWhileStopping)
    }

    func testDuplicateRestartWaitsForOneStopBeforeStartingLatestRuntime() async throws {
        let (session, transport, root) = try makeBlockingSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.restartRuntime(for: root, launchMode: .fresh)
        session.restartRuntime(for: root, launchMode: .fresh)
        try await waitUntil { await transport.stopStarted }
        let startCountBeforeRelease = await transport.startCount
        let stopCountBeforeRelease = await transport.stopCount
        XCTAssertEqual(startCountBeforeRelease, 1)
        XCTAssertEqual(stopCountBeforeRelease, 1)

        await transport.releaseStop()
        try await waitUntil { await transport.startCount == 2 }
        let startedWhileStopping = await transport.startedWhileStopping
        let stopCountAfterRelease = await transport.stopCount
        XCTAssertFalse(startedWhileStopping)
        XCTAssertEqual(stopCountAfterRelease, 1)
    }

    func testDuplicateStartCallsWhileRunningDoNotReplaceTransport() async throws {
        let (session, transport, root) = try makeBlockingSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let generation = session.generation
        session.startRuntime(for: root, generation: generation, launchMode: .fresh)
        session.startRuntime(for: root, generation: generation, launchMode: .fresh)
        try await Task.sleep(for: .milliseconds(60))

        let startCount = await transport.startCount
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(session.runtimeReady)
    }

    func testDuplicateStartCallsShareTheSameStopBarrier() async throws {
        let (session, transport, root) = try makeBlockingSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let generation = session.generation
        session.handleRuntimeTermination(.eof, generation: generation)
        try await waitUntil { await transport.stopStarted }
        session.startRuntime(for: root, generation: generation, launchMode: .fresh)
        session.startRuntime(for: root, generation: generation, launchMode: .fresh)
        let startCountBeforeRelease = await transport.startCount
        XCTAssertEqual(startCountBeforeRelease, 1)

        await transport.releaseStop()
        try await waitUntil { await transport.startCount == 2 }
        let startedWhileStopping = await transport.startedWhileStopping
        XCTAssertFalse(startedWhileStopping)
    }

    func testDuplicateCloseChainsStopWithoutStartingOrStoppingTwice() async throws {
        let (session, transport, root) = try makeBlockingSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        XCTAssertTrue(session.closeWorkspace())
        XCTAssertTrue(session.closeWorkspace())
        try await waitUntil { await transport.stopStarted }
        let stopCountBeforeRelease = await transport.stopCount
        let runningBeforeRelease = await transport.isRunning
        XCTAssertEqual(stopCountBeforeRelease, 1)
        XCTAssertTrue(runningBeforeRelease)
        XCTAssertNil(session.workspace)

        await transport.releaseStop()
        try await waitUntil {
            let stopCount = await transport.stopCount
            let running = await transport.isRunning
            return stopCount == 1 && !running
        }
        XCTAssertNil(session.workspace)
    }

    func testAsyncWorkspaceCloseWaitsForRuntimeStopBarrier() async throws {
        let (session, transport, root) = try makeBlockingSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let closeTask = Task { @MainActor in
            await session.closeWorkspaceAsync()
            await session.waitForRuntimeStop()
        }
        try await waitUntil { await transport.stopStarted }
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(closeTask.isCancelled)

        await transport.releaseStop()
        await closeTask.value
        let isRunning = await transport.isRunning
        XCTAssertFalse(isRunning)
        XCTAssertNil(session.workspace)
    }

    func testShortRequestTimeoutActuallyRemovesRequest() async throws {
        let session = PiSessionController()
        let command = PiRPCCommand.getCommands(id: "short-timeout")
        session.commandsRequestInFlight = true
        session.activeCommandsRequestID = command.id
        session.registerRuntimeRequest(
            command,
            purpose: .operation,
            timeout: .milliseconds(20)
        )

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.runtimeRequests[command.id ?? ""])
        XCTAssertFalse(session.commandsRequestInFlight)
        XCTAssertNil(session.activeCommandsRequestID)
        XCTAssertNotNil(session.lastError)
    }

    func testProcessExitDiagnosticIsShownAlongsideExitStatus() {
        let session = PiSessionController()
        let generation = session.generation

        session.consume(
            .processExitedWithDiagnostic(
                status: 1,
                diagnostic: "fatal: no model is configured"
            ),
            generation: generation
        )

        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(
            session.lastError?.contains("状态码：1") == true
                && session.lastError?.contains("no model is configured") == true
        )
        XCTAssertFalse(session.canReconnectRuntime)
        // 没有工作区时不能显示重连；错误本身仍必须保留。
    }

    func testRestoreFailureOffersExplicitFreshSessionFallback() {
        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: URL(fileURLWithPath: "/tmp/purapi"))
        session.phase = .failed
        session.recentSessionRestoreState = .failed

        XCTAssertTrue(session.canStartNewSessionAfterRestoreFailure)
        session.runtimeAuthenticationChanged = true
        XCTAssertFalse(session.canStartNewSessionAfterRestoreFailure)
    }

    // MARK: - Helpers

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-boundary-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = FakePiRPCTransport()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { transport }
        )
        return (session, transport, root)
    }

    private func makeBlockingSession() throws -> (PiSessionController, BlockingStopTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-boundary-blocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = BlockingStopTransport()
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

    private func startAndHandshake(
        _ session: PiSessionController,
        _ transport: BlockingStopTransport,
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

    private func waitUntil(
        timeout: TimeInterval = 4,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Runtime 边界审计等待超时")
    }

}
