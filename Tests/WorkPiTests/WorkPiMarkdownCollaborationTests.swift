import Foundation
import PiDomain
import PiRPC
import WorkspaceKit
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiMarkdownCollaborationTests: XCTestCase {
    func testUnapprovedMarkdownChangeIsNotInjectedIntoPrompt() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))

        session.draftPrompt = "请检查当前文件"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }

        let sentCommands = await transport.sentCommands
        let prompt = try XCTUnwrap(
            sentCommands.first(where: { $0.type == "prompt" })
        )
        XCTAssertEqual(prompt.fields["message"]?.stringValue, "请检查当前文件")
        XCTAssertFalse(prompt.fields["message"]?.stringValue?.contains("workpi.markdown.diff") == true)
        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)
    }

    func testApprovedMarkdownDiffIsInjectedAndAcknowledgedAfterRuntimeAcceptsPrompt() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))

        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)
        XCTAssertTrue(session.markdownCollaborationDisplayState.isApproved)

        session.draftPrompt = "请继续处理"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }
        let sentCommands = await transport.sentCommands
        let prompt = try XCTUnwrap(
            sentCommands.last(where: { $0.type == "prompt" })
        )
        let message = try XCTUnwrap(prompt.fields["message"]?.stringValue)
        XCTAssertTrue(message.contains("workpi.markdown.diff"))
        XCTAssertTrue(message.contains("用户修改"))
        XCTAssertTrue(message.contains(review.context.envelope.baseHash))
        // 发出 write 不等于 Pi 已接受；response 前协作基线仍然保留。
        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "id": .string(try XCTUnwrap(prompt.id)),
            "success": .bool(true),
        ])))
        try await waitUntil { session.pendingInspectorChangeSnapshot == nil }
        let acceptedID = try XCTUnwrap(prompt.id)
        // 迟到的重复成功响应不能再次改变协作基线或制造新的状态。
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "id": .string(acceptedID),
            "success": .bool(true),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "success": .bool(false),
            "error": .string("迟到的无 id 失败"),
        ])))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(session.pendingInspectorChangeSnapshot)
        XCTAssertNil(session.lastError)
    }

    func testRejectedPromptKeepsMarkdownChangePending() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)
        session.draftPrompt = "请处理"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }
        let sent = await transport.sentCommands
        let prompt = try XCTUnwrap(sent.last(where: { $0.type == "prompt" }))

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "id": .string(try XCTUnwrap(prompt.id)),
            "success": .bool(false),
            "error": .string("Pi 拒绝了请求"),
        ])))
        try await waitUntil { session.activePromptInspectorChange == nil }
        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)
    }

    func testIDlessPromptResponseBlocksASecondPromptUntilReconnect() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        session.draftPrompt = "第一条"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "prompt" }.count == 1
        }
        let activePromptID = try XCTUnwrap(session.activePromptCommandID)
        XCTAssertNotNil(session.runtimeRequests[activePromptID])
        XCTAssertFalse(session.idlessResponseQuarantine.contains("prompt"))
        XCTAssertEqual(session.runtimeRequestCandidates(for: "prompt").count, 1)
        let response = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "success": .bool(true),
        ])
        XCTAssertEqual(response.command, "prompt")
        XCTAssertEqual(response.success, true)
        XCTAssertNil(response.id)
        XCTAssertNotNil(session.runtimeRequest(for: response, command: "prompt", purposes: [.operation]))
        session.consumeResponse(response)
        XCTAssertNil(session.runtimeRequests[activePromptID])
        XCTAssertTrue(session.activePromptResponseAccepted)
        XCTAssertTrue(session.idlessResponseQuarantine.contains("prompt"))
        // 模拟随后收到 settled；该测试只关注无 id 响应的隔离。
        session.activeAgentRunID = nil
        session.runSettlementPending = false
        session.phase = .idle

        session.draftPrompt = "第二条"
        session.submitPrompt()
        XCTAssertEqual(session.draftPrompt, "第二条")
        XCTAssertTrue(session.lastError?.contains("缺少 id") == true)
        try await Task.sleep(for: .milliseconds(40))
        let sentCount = await transport.sentCommands.filter { $0.type == "prompt" }.count
        XCTAssertEqual(sentCount, 1)
    }

    func testQueuedPromptWithoutDiffDoesNotConsumeLaterApproval() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)

        let queued = WorkPiQueuedPrompt(text: "先前已排队的任务")
        XCTAssertTrue(session.submitPrompt(queued))
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }
        let sent = await transport.sentCommands
        let prompt = try XCTUnwrap(sent.last(where: { $0.type == "prompt" }))
        XCTAssertEqual(prompt.fields["message"]?.stringValue, "先前已排队的任务")
        XCTAssertTrue(session.markdownCollaborationDisplayState.isApproved)
    }

    func testPromptTimeoutKeepsMarkdownDiffPending() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)
        session.draftPrompt = "请处理"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }
        let sentCommands = await transport.sentCommands
        let prompt = try XCTUnwrap(
            sentCommands.first(where: { $0.type == "prompt" })
        )
        let request = try XCTUnwrap(session.runtimeRequests[prompt.id ?? ""])
        session.handleRuntimeRequestTimeout(request)

        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)
        XCTAssertNil(session.activePromptInspectorChange)
    }

    func testRuntimeEOFKeepsMarkdownDiffPending() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)
        session.draftPrompt = "请处理"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }

        session.handleTransportEOF(generation: session.generation)
        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)
        XCTAssertNil(session.activePromptInspectorChange)
    }

    func testUnapprovedDiffCannotBeInsertedDirectlyIntoQueue() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)

        XCTAssertNil(session.enqueueFollowUp("不应直接排队", inspectorChange: review.context))
        let forged = review.context.approvedCopy(with: UUID())
        XCTAssertNil(session.enqueueFollowUp("伪造票据", inspectorChange: forged))
        XCTAssertTrue(session.queuedPrompts.isEmpty)
        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)
    }

    func testAbortDoesNotAcknowledgeApprovedMarkdownDiff() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)
        session.draftPrompt = "请处理"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }

        session.abort()
        session.finishAbort(commandItemID: nil)
        XCTAssertNotNil(session.pendingInspectorChangeSnapshot)
    }

    func testStaleApprovalBlocksPromptAndPreservesDraft() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "第一次修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)

        session.markdownEditor.apply(.update(id: block.id, source: "第二次修改"))
        session.draftPrompt = "不要丢失这条输入"
        session.submitPrompt()

        XCTAssertEqual(session.draftPrompt, "不要丢失这条输入")
        XCTAssertFalse(session.markdownCollaborationDisplayState.isApproved)
        XCTAssertTrue(session.markdownDiffReviewError?.contains("变化") == true)
        try await Task.sleep(for: .milliseconds(80))
        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        XCTAssertEqual(prompts.count, 0)
    }

    func testQueuedMarkdownDiffIsFrozenAndLaterEditsRemainPending() async throws {
        let (session, transport, root, file) = try makeSession(fileText: "原始\n")
        try await startAndHandshake(session, transport, root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)

        session.draftPrompt = "正在处理的任务"
        session.submitPrompt()
        try await waitUntil { session.phase == .requesting }
        session.consume(PiRPCRecord(fields: ["type": .string("agent_start")]))

        session.markdownEditor.apply(.update(id: block.id, source: "第一次修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)

        session.draftPrompt = "排队处理"
        session.submitPrompt()
        let queued = try XCTUnwrap(session.queuedPrompts.first)
        XCTAssertNotNil(queued.inspectorChange)
        let frozenText = queued.inspectorChange?.snapshot.currentText

        session.markdownEditor.apply(.update(id: block.id, source: "第二次修改"))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "prompt" }.count == 2
        }
        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        let dispatched = try XCTUnwrap(prompts.last)
        let dispatchedMessage = try XCTUnwrap(dispatched.fields["message"]?.stringValue)
        XCTAssertTrue(dispatchedMessage.contains("第一次修改"))
        XCTAssertFalse(dispatchedMessage.contains("第二次修改"))
        XCTAssertEqual(frozenText, "第一次修改\n")

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "id": .string(try XCTUnwrap(dispatched.id)),
            "success": .bool(true),
        ])))
        try await waitUntil {
            session.pendingInspectorChangeSnapshot?.baseText == "第一次修改\n"
                && session.pendingInspectorChangeSnapshot?.currentText == "第二次修改\n"
        }
    }

    func testFileCloseKeepsSavedUnacknowledgedMarkdownInPerFileLedger() throws {
        let (session, _, root, file) = try makeSession(fileText: "原始\n")
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "本地修改"))
        XCTAssertTrue(session.markdownEditor.save())

        session.clearFileSelection()
        XCTAssertNil(session.selectedFileURL)
        XCTAssertEqual(
            session.pendingMarkdownSnapshots[file.standardizedFileURL]?.currentText,
            "本地修改\n"
        )
        XCTAssertFalse(session.markdownCollaborationCloseBlocked)

        session.discardPendingMarkdownCollaboration(for: file)
        XCTAssertNil(session.pendingMarkdownSnapshots[file.standardizedFileURL])
    }

    func testSwitchingFilesRetainsIndependentMarkdownSnapshots() async throws {
        let (session, _, root, first) = try makeSession(fileText: "第一份\n")
        let second = root.appendingPathComponent("second.md")
        try "第二份\n".write(to: second, atomically: true, encoding: .utf8)
        session.workspace = WorkspaceDescriptor(rootURL: root)

        session.selectFile(first)
        let firstBlock = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: firstBlock.id, source: "第一份修改"))
        session.selectFile(second)
        try await waitUntil {
            session.selectedFileURL == second.standardizedFileURL
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "第一份修改\n")
        XCTAssertEqual(
            session.pendingMarkdownSnapshots[first.standardizedFileURL]?.currentText,
            "第一份修改\n"
        )

        let secondBlock = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: secondBlock.id, source: "第二份修改"))
        session.selectFile(first)
        try await waitUntil {
            session.selectedFileURL == first.standardizedFileURL
        }
        XCTAssertEqual(
            session.pendingMarkdownSnapshots[second.standardizedFileURL]?.currentText,
            "第二份修改\n"
        )
        XCTAssertTrue(session.markdownCollaborationDisplayState.items.count >= 2)
    }

    func testArchivedFileChangedByAgentMustBeReconciledBeforeReview() async throws {
        let (session, _, root, first) = try makeSession(fileText: "第一份\n")
        let second = root.appendingPathComponent("second.md")
        try "第二份\n".write(to: second, atomically: true, encoding: .utf8)
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(first)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.selectFile(second)
        try await waitUntil { session.selectedFileURL == second.standardizedFileURL }
        try "Agent 已修改\n".write(to: first, atomically: true, encoding: .utf8)

        session.presentMarkdownDiffReview(for: first)
        try await waitUntil {
            session.markdownDiffReviewError != nil || !session.isBuildingMarkdownDiffReview
        }
        XCTAssertNil(session.markdownDiffReview)
        XCTAssertTrue(session.markdownDiffReviewError?.contains("基线") == true)
        XCTAssertNotNil(session.pendingMarkdownSnapshots[first.standardizedFileURL])
    }

    func testApprovedChangesFromMultipleFilesAreSentTogether() async throws {
        let (session, transport, root, first) = try makeSession(fileText: "第一份\n")
        let second = root.appendingPathComponent("second.md")
        try "第二份\n".write(to: second, atomically: true, encoding: .utf8)
        try await startAndHandshake(session, transport, root)
        session.selectFile(first)
        let firstBlock = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: firstBlock.id, source: "第一份修改"))
        session.selectFile(second)
        try await waitUntil { session.selectedFileURL == second.standardizedFileURL }
        let secondBlock = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: secondBlock.id, source: "第二份修改"))
        session.clearFileSelection()
        try await waitUntil { session.selectedFileURL == nil }

        session.presentMarkdownDiffReview(for: first)
        try await waitUntil { session.markdownDiffReview != nil }
        let firstReview = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: firstReview.id)
        session.presentMarkdownDiffReview(for: second)
        try await waitUntil { session.markdownDiffReview != nil }
        let secondReview = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: secondReview.id)

        session.draftPrompt = "同时检查两个文件"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "prompt" }
        }
        let sentCommands = await transport.sentCommands
        let command = try XCTUnwrap(
            sentCommands.last(where: { $0.type == "prompt" })
        )
        let message = try XCTUnwrap(command.fields["message"]?.stringValue)
        XCTAssertTrue(message.contains("第一份修改"))
        XCTAssertTrue(message.contains("第二份修改"))
        XCTAssertEqual(session.activePromptMarkdownChanges.count, 2)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("prompt"),
            "id": .string(try XCTUnwrap(command.id)),
            "success": .bool(true),
        ])))
        try await waitUntil { session.pendingMarkdownSnapshots.isEmpty }
    }

    func testSendRechecksDiskBeforeUsingApprovedDiff() async throws {
        let (session, _, root, file) = try makeSession(fileText: "原始\n")
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        session.presentMarkdownDiffReview()
        try await waitUntil { session.markdownDiffReview != nil }
        let review = try XCTUnwrap(session.markdownDiffReview)
        session.approveMarkdownDiffReview(id: review.id)
        try "Agent 已修改\n".write(to: file, atomically: true, encoding: .utf8)
        if case .needsReview = session.markdownChangeForNextPrompt() {
            // 发送前的同步磁盘校验捕获了尚未到达的 FSEvents。
        } else {
            XCTFail("approved diff should be invalidated by the disk change")
        }
        XCTAssertEqual(session.markdownEditor.conflict?.kind, .modified)
    }

    func testConflictPreventsMarkdownDiffReview() throws {
        let (session, _, root, file) = try makeSession(fileText: "原始\n")
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "用户修改"))
        try "Agent 修改\n".write(to: file, atomically: true, encoding: .utf8)
        session.markdownEditor.handleExternalChange(at: file)

        session.presentMarkdownDiffReview()

        XCTAssertNil(session.markdownDiffReview)
        XCTAssertTrue(session.markdownDiffReviewError?.contains("冲突") == true)
    }

    // MARK: - Helpers

    private func makeSession(fileText: String) throws -> (
        PiSessionController,
        FakePiRPCTransport,
        URL,
        URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-markdown-collab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("doc.md")
        try fileText.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transport = FakePiRPCTransport()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { transport }
        )
        return (session, transport, root, file)
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
        XCTFail("Timed out waiting for Markdown collaboration state")
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
