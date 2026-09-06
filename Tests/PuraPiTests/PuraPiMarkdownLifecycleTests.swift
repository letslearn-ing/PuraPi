import Foundation
import PiDomain
import WorkspaceKit
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownLifecycleTests: XCTestCase {
    func testAsyncLoadAndSavePreserveBaselineSemantics() async throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = await state.open(url: url, workspaceRoot: root)
        XCTAssertTrue(opened)
        let block = try XCTUnwrap(state.document?.blocks.first)
        state.apply(.update(id: block.id, source: "异步修改"))
        let saved = await state.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "异步修改\n")

        state.apply(.update(id: block.id, source: "本地版本"))
        try "Agent 版本\n".write(to: url, atomically: true, encoding: .utf8)
        let conflictedSave = await state.save()
        XCTAssertFalse(conflictedSave)
        XCTAssertEqual(state.conflict?.kind, .modified)
        XCTAssertEqual(state.document?.block(id: block.id)?.source, "本地版本")
    }

    func testExternalEditCreatesConflictAndPreservesLocalDocument() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)

        state.apply(.update(id: block.id, source: "我的版本"))
        try "Agent 版本\n".write(to: url, atomically: true, encoding: .utf8)
        state.handleExternalChange(at: url)

        XCTAssertEqual(state.document?.block(id: block.id)?.source, "我的版本")
        XCTAssertEqual(state.conflict?.kind, .modified)
        XCTAssertFalse(state.close(), "未解决冲突时不能关闭文档")
        XCTAssertTrue(state.isEditing)
    }

    func testCleanExternalEditReloadsDocument() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        try "Agent 版本\n".write(to: url, atomically: true, encoding: .utf8)

        state.handleExternalChange(at: url)

        XCTAssertNil(state.conflict)
        XCTAssertEqual(state.document?.blocks.first?.source, "Agent 版本")
        XCTAssertEqual(state.saveState, .clean)
    }

    func testDeletedExternalFileRequiresExplicitRestore() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)
        state.apply(.update(id: block.id, source: "我的版本"))
        try FileManager.default.removeItem(at: url)

        state.handleExternalChange(at: url)
        XCTAssertEqual(state.conflict?.kind, .deleted)
        XCTAssertFalse(state.close())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        state.resolveConflictByOverwriting()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "我的版本\n")
        XCTAssertNil(state.conflict)
    }

    func testDismissingDeletionConflictStillProtectsLocalSnapshot() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        try FileManager.default.removeItem(at: url)

        state.handleExternalChange(at: url)
        state.dismissConflict()

        XCTAssertNil(state.conflict)
        XCTAssertFalse(state.close(), "dismiss 不能绕过删除冲突的保存保护")
        XCTAssertTrue(state.isEditing)
    }

    func testCloseSavesDirtyDocumentBeforeReleasingIt() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)
        state.apply(.update(id: block.id, source: "关闭前保存"))

        XCTAssertFalse(state.close(), "未确认的 Markdown 协作快照不能静默丢失")
        XCTAssertTrue(state.discardPendingCollaboration())
        XCTAssertTrue(state.close())
        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "关闭前保存\n")
    }

    func testSavedButUnacknowledgedCollaborationBlocksCloseUntilExplicitDiscard() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)
        state.apply(.update(id: block.id, source: "已保存但未通知"))
        XCTAssertTrue(state.save())
        XCTAssertFalse(state.document?.isDirty == true)
        XCTAssertNotNil(state.pendingCollaborationSnapshot)

        XCTAssertFalse(state.close())
        XCTAssertTrue(state.isEditing)
        XCTAssertTrue(state.discardPendingCollaboration())
        XCTAssertNil(state.pendingCollaborationSnapshot)
        XCTAssertTrue(state.close())
    }

    func testSessionFileMonitorPathUsesConflictHandler() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("doc.md")
        try "原始\n".write(to: url, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(url)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "我的版本"))
        try "Agent 版本\n".write(to: url, atomically: true, encoding: .utf8)

        session.consume(
            WorkspaceFileChange(url: url, kind: .modified),
            generation: session.generation
        )

        XCTAssertEqual(session.markdownEditor.conflict?.kind, .modified)
        XCTAssertEqual(session.markdownEditor.document?.block(id: block.id)?.source, "我的版本")
        XCTAssertEqual(session.selectedFileURL, url.standardizedFileURL)
    }

    func testRetryAfterInvalidMarkdownLoadEntersEditor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("broken.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(url)
        XCTAssertFalse(session.markdownEditor.isEditing)

        try "修复后的 Markdown\n".write(to: url, atomically: true, encoding: .utf8)
        session.retryFilePreview()

        XCTAssertTrue(session.markdownEditor.isEditing)
        XCTAssertEqual(session.markdownEditor.document?.blocks.first?.source, "修复后的 Markdown")
    }

    func testCloseWorkspaceRefusesToDiscardUnresolvedConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("doc.md")
        try "原始\n".write(to: url, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(url)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "我的版本"))
        try "Agent 版本\n".write(to: url, atomically: true, encoding: .utf8)
        session.markdownEditor.handleExternalChange(at: url)

        XCTAssertFalse(session.closeWorkspace())
        XCTAssertEqual(session.workspace?.rootURL, root.standardizedFileURL)
        XCTAssertTrue(session.markdownEditor.isEditing)
    }

    func testSelectingAnotherFileDoesNotHideUnresolvedConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-select-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "原始\n".write(to: first, atomically: true, encoding: .utf8)
        try "第二个\n".write(to: second, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(first)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "我的版本"))
        try "Agent 版本\n".write(to: first, atomically: true, encoding: .utf8)
        session.markdownEditor.handleExternalChange(at: first)

        session.selectFile(second)

        XCTAssertEqual(session.selectedFileURL, first.standardizedFileURL)
        XCTAssertEqual(session.markdownEditor.conflict?.kind, .modified)
        XCTAssertEqual(session.markdownEditor.document?.block(id: block.id)?.source, "我的版本")
    }

    func testPendingCollaborationSnapshotCapturesBaselineAndLocalText() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)

        state.apply(.update(id: block.id, source: "用户修改"))

        let snapshot = try XCTUnwrap(state.pendingCollaborationSnapshot)
        XCTAssertEqual(snapshot.url, url.standardizedFileURL)
        XCTAssertEqual(snapshot.baseText, "原始\n")
        XCTAssertEqual(snapshot.currentText, "用户修改\n")
        XCTAssertEqual(snapshot.baseHash, MarkdownDocumentStore.hash("原始\n"))
        XCTAssertEqual(snapshot.currentHash, MarkdownDocumentStore.hash("用户修改\n"))
        XCTAssertEqual(snapshot.changedBlockIDs, [block.id])

        // 自动保存只落盘，不代表 Agent 已收到变更；快照要保留到用户审阅并显式确认。
        XCTAssertTrue(state.save())
        XCTAssertEqual(state.pendingCollaborationSnapshot?.currentText, "用户修改\n")
        state.acknowledgePendingCollaboration()
        XCTAssertNil(state.pendingCollaborationSnapshot)
    }

    func testSavedUserChangeStillConflictsWithLaterAgentChangeUntilAcknowledged() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)

        state.apply(.update(id: block.id, source: "用户版本"))
        XCTAssertTrue(state.save())
        XCTAssertNotNil(state.pendingCollaborationSnapshot)

        try "Agent 版本\n".write(to: url, atomically: true, encoding: .utf8)
        state.handleExternalChange(at: url)

        XCTAssertEqual(state.conflict?.kind, .modified)
        XCTAssertEqual(state.document?.block(id: block.id)?.source, "用户版本")
    }

    func testUndoBackToBaselineRemovesPendingCollaborationSnapshot() throws {
        let (state, url, root) = try makeState(with: "原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.document?.blocks.first)

        state.apply(.update(id: block.id, source: "用户修改"))
        XCTAssertNotNil(state.pendingCollaborationSnapshot)
        state.undo()

        XCTAssertNil(state.pendingCollaborationSnapshot)
        XCTAssertEqual(state.saveState, .clean)
    }

    func testOpeningAnotherWorkspaceDoesNotDiscardUnresolvedConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-open-\(UUID().uuidString)")
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-open-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let file = root.appendingPathComponent("doc.md")
        try "原始\n".write(to: file, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.selectFile(file)
        let block = try XCTUnwrap(session.markdownEditor.document?.blocks.first)
        session.markdownEditor.apply(.update(id: block.id, source: "我的版本"))
        try "Agent 版本\n".write(to: file, atomically: true, encoding: .utf8)
        session.markdownEditor.handleExternalChange(at: file)

        session.openWorkspace(otherRoot)

        XCTAssertEqual(session.workspace?.rootURL, root.standardizedFileURL)
        XCTAssertTrue(session.markdownEditor.isEditing)
        XCTAssertEqual(session.markdownEditor.conflict?.kind, .modified)
    }

    private func makeState(with text: String) throws -> (
        PuraPiMarkdownEditorState,
        URL,
        URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-lifecycle-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("doc.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (PuraPiMarkdownEditorState(), url, root)
    }
}
