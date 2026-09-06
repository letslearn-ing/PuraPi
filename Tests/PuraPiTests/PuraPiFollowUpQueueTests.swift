import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// 待执行任务队列：忙时排队、可取消、回合结束后自动继续。
@MainActor
final class PuraPiFollowUpQueueTests: XCTestCase {
    /// Agent 忙时按 Return 不再静默丢弃，而是进入队列。
    func testSubmitWhileBusyEnqueuesInsteadOfDropping() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "第一个任务"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))
        XCTAssertTrue(session.queuedPrompts.isEmpty)

        session.draftPrompt = "第二个任务"
        session.submitPrompt()

        XCTAssertEqual(session.queuedPrompts.map(\.text), ["第二个任务"])
        // 排队后输入框应清空，用户能继续输入下一条。
        XCTAssertEqual(session.draftPrompt, "")

        // 排队不应额外发出 prompt 命令。第一条 prompt 是异步送出的，
        // 先等它到达再断言总数，避免把「尚未送达」误判为「没有发送」。
        try await waitUntil {
            let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
            return prompts.count == 1
        }
        try await Task.sleep(for: .milliseconds(120))
        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(prompts.count, 1)
    }

    func testQueuedPromptCanBeCancelledBeforeDispatch() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中的任务"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }

        session.draftPrompt = "会被取消的任务"
        session.submitPrompt()
        session.draftPrompt = "保留的任务"
        session.submitPrompt()
        XCTAssertEqual(session.queuedPrompts.count, 2)

        let cancelled = try XCTUnwrap(session.queuedPrompts.first)
        session.cancelQueuedPrompt(cancelled.id)

        XCTAssertEqual(session.queuedPrompts.map(\.text), ["保留的任务"])
    }

    /// 忙时排队必须冻结附件；dispatch 时不能把后来加入 Composer 的附件串进来。
    func testQueuedPromptSnapshotsAttachmentsAndDispatchesThem() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中的任务"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))

        let queuedFile = root.appendingPathComponent("queued.txt")
        try "排队附件内容".write(to: queuedFile, atomically: true, encoding: .utf8)
        session.attachFiles([queuedFile])
        session.draftPrompt = "带附件的排队任务"
        session.submitPrompt()

        XCTAssertEqual(session.queuedPrompts.count, 1)
        XCTAssertEqual(session.queuedPrompts[0].attachmentNames, ["queued.txt"])
        XCTAssertTrue(session.pendingAttachments.isEmpty)

        let laterFile = root.appendingPathComponent("later.txt")
        try "后来加入".write(to: laterFile, atomically: true, encoding: .utf8)
        session.attachFiles([laterFile])

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil {
            let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
            return prompts.count == 2
        }

        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        let dispatched = try XCTUnwrap(prompts.last)
        XCTAssertTrue(dispatched.fields["message"]?.stringValue?.contains("queued.txt") == true)
        XCTAssertTrue(dispatched.fields["message"]?.stringValue?.contains("排队附件内容") == true)
        XCTAssertFalse(dispatched.fields["message"]?.stringValue?.contains("later.txt") == true)
        // dispatch 使用队列快照，不应清除用户后来加入的附件。
        XCTAssertEqual(session.pendingAttachments.map(\.displayName), ["later.txt"])
    }

    /// 回合结束后自动发出下一条，无需用户再次操作。
    func testQueueDispatchesAfterAgentSettles() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "第一个任务"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))

        session.draftPrompt = "排队任务"
        session.submitPrompt()
        XCTAssertEqual(session.queuedPrompts.count, 1)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))

        try await waitUntil { session.queuedPrompts.isEmpty }
        try await waitUntil {
            let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
            return prompts.count == 2
        }
        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(prompts.last?.fields["message"]?.stringValue, "排队任务")
    }

    /// 一次只发一条：第二条要等第一条也跑完，与 Pi 的 one-at-a-time 语义一致。
    func testQueueDispatchesOneAtATime() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))

        session.draftPrompt = "排队 A"
        session.submitPrompt()
        session.draftPrompt = "排队 B"
        session.submitPrompt()
        XCTAssertEqual(session.queuedPrompts.count, 2)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil { session.queuedPrompts.count == 1 }

        // 仍有一条留在队列里，直到下一次 settled。
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["排队 B"])
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil { session.queuedPrompts.isEmpty }
    }

    /// 用户点停止时必须清空队列，否则停止后任务仍会自动开跑。
    func testAbortClearsQueue() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))

        session.draftPrompt = "排队任务"
        session.submitPrompt()
        XCTAssertEqual(session.queuedPrompts.count, 1)

        session.abort()
        XCTAssertTrue(session.queuedPrompts.isEmpty)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await Task.sleep(for: .milliseconds(80))

        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(prompts.count, 1)
    }

    /// 斜杠命令的意义在于当下生效，不能被排队。
    func testSlashCommandIsNotQueuedWhileBusy() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }

        session.draftPrompt = "/abort"
        session.submitPrompt()

        XCTAssertTrue(session.queuedPrompts.isEmpty)
    }

    func testEmptyInputIsNotQueued() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }

        session.draftPrompt = "   \n  "
        session.submitPrompt()

        XCTAssertTrue(session.queuedPrompts.isEmpty)
    }

    /// 空闲时直接发送，不应让用户多等一个回合。
    func testIdleSubmitBypassesQueue() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "立即执行"
        session.submitPrompt()

        XCTAssertTrue(session.queuedPrompts.isEmpty)
        try await waitUntil {
            let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
            return prompts.count == 1
        }
    }

    func testQueueClearsWhenWorkspaceResets() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "进行中"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.draftPrompt = "排队任务"
        session.submitPrompt()
        XCTAssertEqual(session.queuedPrompts.count, 1)

        XCTAssertFalse(session.closeWorkspace())
        XCTAssertTrue(session.composerCloseBlocked)
        session.discardComposerInput()
        XCTAssertTrue(session.closeWorkspace())

        XCTAssertTrue(session.queuedPrompts.isEmpty)
    }

    // MARK: - 辅助

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-queue-\(UUID().uuidString)", isDirectory: true)
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
        XCTFail("Timed out waiting for PuraPi queue state")
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
