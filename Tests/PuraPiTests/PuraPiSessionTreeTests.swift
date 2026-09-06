import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// 会话树的命令构造、响应处理与安全门控。
@MainActor
final class PuraPiSessionTreeTests: XCTestCase {
    // MARK: - 轮次定位

    /// 已是当前会话时直接定位，不应重复发 switch_session。
    func testOpenTurnInActiveSessionLocatesWithoutSwitching() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        let file = root.appendingPathComponent("active.jsonl")
        session.activeSessionFilePath = file.path
        session.conversation = [
            ConversationItem(kind: .user, text: "第一个问题"),
            ConversationItem(kind: .assistant, text: "回答"),
            ConversationItem(kind: .user, text: "第二个问题"),
        ]
        let summary = PiSessionSummary(
            fileURL: file,
            sessionID: "s1",
            createdAt: Date(),
            modifiedAt: Date(),
            cwd: root.path
        )
        let turn = PiSessionTurn(entryID: "e2", text: "第二个问题", timestamp: Date())

        session.openTurn(turn, in: summary)

        XCTAssertEqual(session.conversationScrollTarget, session.conversation[2].id)
        let switches = await transport.sentCommands.filter { $0.type == "switch_session" }
        XCTAssertTrue(switches.isEmpty)
    }

    /// 其他会话：先切换，历史到位后才定位。
    func testOpenTurnInOtherSessionSwitchesFirst() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.activeSessionFilePath = root.appendingPathComponent("current.jsonl").path
        let other = root.appendingPathComponent("other.jsonl")
        let summary = PiSessionSummary(
            fileURL: other,
            sessionID: "s2",
            createdAt: Date(),
            modifiedAt: Date(),
            cwd: root.path
        )
        let turn = PiSessionTurn(entryID: "e9", text: "另一个会话的问题", timestamp: Date())

        session.openTurn(turn, in: summary)

        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "switch_session" }
        }
        // 历史还没重建，此时不能有定位目标。
        XCTAssertNil(session.conversationScrollTarget)
        XCTAssertEqual(session.pendingTurnLocation, "另一个会话的问题")
    }

    /// 匹配不到就不设目标，避免滚到无关消息。
    func testLocateTurnIgnoresMissingText() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        session.conversation = [ConversationItem(kind: .user, text: "只有这一条")]

        session.locateTurn(matching: "不存在的内容")

        XCTAssertNil(session.conversationScrollTarget)
    }

    // MARK: - 协议层

    func testCommandFactoriesEncodeUpstreamFields() {
        let fork = PiRPCCommand.fork(entryID: "abc123")
        XCTAssertEqual(fork.type, "fork")
        XCTAssertEqual(fork.fields["entryId"]?.stringValue, "abc123")

        XCTAssertEqual(PiRPCCommand.clone().type, "clone")
        XCTAssertEqual(PiRPCCommand.getTree().type, "get_tree")
        XCTAssertEqual(PiRPCCommand.getForkMessages().type, "get_fork_messages")

        let named = PiRPCCommand.setSessionName("我的会话")
        XCTAssertEqual(named.type, "set_session_name")
        XCTAssertEqual(named.fields["name"]?.stringValue, "我的会话")

        // 无游标时不带 since 字段。
        let entries = PiRPCCommand.getEntries()
        XCTAssertEqual(entries.type, "get_entries")
        XCTAssertNil(entries.fields["since"])

        let incremental = PiRPCCommand.getEntries(since: "cursor1")
        XCTAssertEqual(incremental.fields["since"]?.stringValue, "cursor1")
    }

    /// fork/clone 被扩展取消时 success 仍为 true，必须靠 cancelled 区分。
    func testCancelledOperationIsDetected() {
        let cancelled = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("fork"),
            "success": .bool(true),
            "data": .object(["cancelled": .bool(true)]),
        ])
        XCTAssertTrue(cancelled.operationWasCancelled)

        let applied = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("fork"),
            "success": .bool(true),
            "data": .object(["cancelled": .bool(false)]),
        ])
        XCTAssertFalse(applied.operationWasCancelled)
    }

    func testForkMessagesParsing() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_fork_messages"),
            "success": .bool(true),
            "data": .object([
                "messages": .array([
                    .object(["entryId": .string("e1"), "text": .string("第一问")]),
                    .object(["entryId": .string("e2"), "text": .string("第二问")]),
                    // 缺 entryId 无法用于 fork，必须丢弃。
                    .object(["text": .string("孤儿")]),
                ]),
            ]),
        ])

        let messages = try? XCTUnwrap(record.forkMessages)
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?.entryID, "e1")
        XCTAssertEqual(messages?.first?.text, "第一问")
    }

    func testSessionIdentityParsingFromState() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "sessionFile": .string("/tmp/sessions/a.jsonl"),
                "sessionName": .string("我的会话"),
                "leafId": .string("leaf1"),
            ]),
        ])

        XCTAssertEqual(record.sessionFilePath, "/tmp/sessions/a.jsonl")
        XCTAssertEqual(record.sessionName, "我的会话")
        XCTAssertEqual(record.leafEntryID, "leaf1")

        // 空字符串与缺失同义，避免界面显示空标题。
        let empty = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object(["sessionName": .string(""), "leafId": .string("")]),
        ])
        XCTAssertNil(empty.sessionName)
        XCTAssertNil(empty.leafEntryID)
    }

    // MARK: - 控制器行为

    func testActiveSessionIdentityTracksState() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        XCTAssertEqual(session.activeSessionFilePath, "/tmp/sessions/current.jsonl")
        XCTAssertEqual(session.activeSessionName, "当前会话")
    }

    func testSessionOperationsAreGloballySerialized() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        session.activeSessionFilePath = root.appendingPathComponent("current.jsonl").path

        let other = makeSummary(path: root.appendingPathComponent("other.jsonl").path)
        XCTAssertTrue(session.switchToSession(other))
        session.renameCurrentSession(to: "不应并发发送")

        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "switch_session" }
        }
        let commands = await transport.sentCommands
        XCTAssertFalse(commands.contains { $0.type == "set_session_name" })
        XCTAssertNotNil(session.activeSessionCommandID)
        XCTAssertNil(session.activeRenameCommandID)
    }

    func testForkSendsCommandAndRebuildsConversation() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        let turn = PiSessionTurn(entryID: "entry-7", text: "从这里重来", timestamp: Date())
        session.forkSession(from: turn)

        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "fork" }
        }
        let forks = await transport.sentCommands.filter { $0.type == "fork" }
        let sent = try XCTUnwrap(forks.first)
        XCTAssertEqual(sent.fields["entryId"]?.stringValue, "entry-7")

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("fork"),
            "id": .string(sent.id ?? ""),
            "success": .bool(true),
            "data": .object(["text": .string("从这里重来"), "cancelled": .bool(false)]),
        ])))

        // fork 改变了活动分支，必须重新拉消息，否则界面仍显示被抛弃的历史。
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.filter { $0 == "get_messages" }.count >= 1
        }
        XCTAssertNil(session.lastError)
    }

    func testCancelledForkReportsWithoutRebuilding() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        let before = await transport.sentCommands.filter { $0.type == "get_messages" }.count
        session.forkSession(from: PiSessionTurn(
            entryID: "e1", text: "提问", timestamp: Date()
        ))
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "fork" }
        }
        let forks = await transport.sentCommands.filter { $0.type == "fork" }
        let sent = try XCTUnwrap(forks.first)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("fork"),
            "id": .string(sent.id ?? ""),
            "success": .bool(true),
            "data": .object(["cancelled": .bool(true)]),
        ])))

        try await waitUntil { session.lastError == "扩展取消了这次分叉。" }
        try await Task.sleep(for: .milliseconds(80))
        let after = await transport.sentCommands.filter { $0.type == "get_messages" }.count
        XCTAssertEqual(before, after)
    }

    /// Agent 正在运行时切换或分叉都会丢失上下文，必须拒绝并说明原因。
    func testDestructiveOperationsAreBlockedWhileBusy() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "长任务"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }

        session.forkSession(from: PiSessionTurn(
            entryID: "e1", text: "提问", timestamp: Date()
        ))
        XCTAssertEqual(session.lastError, "Agent 正在运行，请先停止再分叉会话。")

        session.cloneCurrentSession()
        XCTAssertEqual(session.lastError, "Agent 正在运行，请先停止再复制会话。")

        session.switchToSession(makeSummary(path: "/tmp/sessions/other.jsonl"))
        XCTAssertEqual(session.lastError, "Agent 正在运行，请先停止再切换会话。")

        let types = await transport.sentCommands.map(\.type)
        XCTAssertFalse(types.contains("fork"))
        XCTAssertFalse(types.contains("clone"))
        XCTAssertFalse(types.contains("switch_session"))
    }

    /// 切换到当前会话本身是空操作，不应发命令。
    func testSwitchingToActiveSessionIsNoOp() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.switchToSession(makeSummary(path: "/tmp/sessions/current.jsonl"))

        try await Task.sleep(for: .milliseconds(60))
        let types = await transport.sentCommands.map(\.type)
        XCTAssertFalse(types.contains("switch_session"))
    }

    func testRenameSendsTrimmedNameAndRefreshes() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.renameCurrentSession(to: "  新名字  ")

        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "set_session_name" }
        }
        let renames = await transport.sentCommands.filter { $0.type == "set_session_name" }
        let sent = try XCTUnwrap(renames.first)
        XCTAssertEqual(sent.fields["name"]?.stringValue, "新名字")

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_session_name"),
            "id": .string(sent.id ?? ""),
            "success": .bool(true),
        ])))

        // 名字写入的是会话文件里的 session_info 条目，需要回读状态。
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.filter { $0 == "get_state" }.count >= 2
        }
        XCTAssertNil(session.lastError)
    }

    /// 旧会话操作响应不能清掉当前操作的请求标记。
    func testStaleSessionResponseIsIgnored() {
        let session = PiSessionController()
        session.activeCloneCommandID = "clone-new"
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("clone"),
            "id": .string("clone-old"),
            "success": .bool(false),
            "error": .string("旧请求失败"),
        ]))

        XCTAssertEqual(session.activeCloneCommandID, "clone-new")
        XCTAssertNil(session.lastError)
    }

    /// 当前 Pi RPC 拒绝空名称；UI 应在发送前阻止它，而不是制造一个必然失败的请求。
    func testEmptySessionNameIsRejectedBeforeSendingRPC() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.renameCurrentSession(to: "  \n")
        try await Task.sleep(for: .milliseconds(60))

        let types = await transport.sentCommands.map(\.type)
        XCTAssertFalse(types.contains("set_session_name"))
        XCTAssertEqual(session.lastError, "Pi 当前版本不支持空会话名称；请填写名称。")
    }

    /// 失败响应必须清掉 in-flight 标记，否则相关入口永久禁用。
    func testFailedSessionOperationReportsError() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.cloneCurrentSession()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "clone" }
        }
        let clones = await transport.sentCommands.filter { $0.type == "clone" }
        let sent = try XCTUnwrap(clones.first)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("clone"),
            "id": .string(sent.id ?? ""),
            "success": .bool(false),
            "error": .string("磁盘写入失败"),
        ])))

        try await waitUntil { session.lastError == "磁盘写入失败" }
    }

    func testSessionStateClearsOnWorkspaceClose() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        session.sessionTurns["k"] = [
            PiSessionTurn(entryID: "e", text: "t", timestamp: Date()),
        ]
        session.conversationScrollTarget = UUID()
        session.activeExportCommandID = "export"
        session.activeAutoCompactionCommandID = "auto"
        session.bashExecutions = [BashExecution(id: "bash", command: "echo")]
        session.pendingAttachments = [
            PuraPiAttachment(url: nil, kind: .text("待发送"))
        ]
        session.sessionStats = PiSessionStats(totalTokens: 10)
        session.subagentTasks = [SubagentTaskSnapshot(
            id: "child",
            sessionFilePath: "/tmp/sessions/child.jsonl",
            agentName: "worker",
            task: "子任务",
            status: .completed
        )]
        session.selectedSubagentTask = session.subagentTasks.first
        session.directoryToReveal = root.appendingPathComponent("sub")
        session.draftPrompt = "草稿"

        XCTAssertFalse(session.closeWorkspace())
        XCTAssertTrue(session.composerCloseBlocked)
        session.discardComposerInput()
        XCTAssertTrue(session.closeWorkspace())

        XCTAssertTrue(session.sessionSummaries.isEmpty)
        XCTAssertTrue(session.sessionTurns.isEmpty)
        XCTAssertNil(session.activeSessionFilePath)
        XCTAssertNil(session.activeSessionName)
        XCTAssertNil(session.conversationScrollTarget)
        XCTAssertNil(session.activeExportCommandID)
        XCTAssertNil(session.activeAutoCompactionCommandID)
        XCTAssertTrue(session.bashExecutions.isEmpty)
        XCTAssertTrue(session.pendingAttachments.isEmpty)
        XCTAssertNil(session.sessionStats)
        XCTAssertTrue(session.subagentTasks.isEmpty)
        XCTAssertNil(session.selectedSubagentTask)
        XCTAssertNil(session.directoryToReveal)
        XCTAssertTrue(session.draftPrompt.isEmpty)
    }

    // MARK: - 辅助

    private func makeSummary(path: String) -> PiSessionSummary {
        PiSessionSummary(
            fileURL: URL(fileURLWithPath: path),
            sessionID: "sid",
            createdAt: Date(),
            modifiedAt: Date(),
            cwd: "/tmp"
        )
    }

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-session-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }
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
        XCTFail("Timed out waiting for PuraPi session tree state")
    }

    private static func stateRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "id": .string("gpt-5.6"),
                    "provider": .string("openai"),
                    "name": .string("GPT-5.6"),
                    "contextWindow": .integer(272_000),
                ]),
                "thinkingLevel": .string("medium"),
                "messageCount": .integer(0),
                "sessionFile": .string("/tmp/sessions/current.jsonl"),
                "sessionName": .string("当前会话"),
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
                    "contextWindow": .integer(272_000),
                    "percent": .integer(0),
                ]),
            ]),
        ])
    }
}
