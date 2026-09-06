import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
import WorkspaceKit
@testable import WorkPi

@MainActor
final class WorkPiMarkdownUndoTests: XCTestCase {
    func testUndoAndRedoRestoreCrossBlockStructure() throws {
        let (root, url) = try makeDocument("第一段\n\n第二段\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let original = state.blocks
        let first = try XCTUnwrap(original.first(where: { $0.kind == .paragraph }))
        let inserted = MarkdownBlock(
            kind: .heading(level: 2),
            source: "## 新标题",
            lineRange: 0..<1
        )

        state.withUndoGroup {
            state.apply(.update(id: first.id, source: "第一段（修改）"))
            state.apply(.insert(block: inserted, after: first.id))
        }
        XCTAssertTrue(state.canUndo)
        XCTAssertFalse(state.canRedo)
        XCTAssertEqual(state.blocks.count, original.count + 1)

        state.undo()
        XCTAssertEqual(state.blocks, original)
        XCTAssertFalse(state.document?.isDirty == true)
        XCTAssertTrue(state.canRedo)

        state.redo()
        XCTAssertEqual(state.blocks.count, original.count + 1)
        XCTAssertEqual(state.blocks.first?.source, "第一段（修改）")
        XCTAssertTrue(state.document?.isDirty == true)
    }

    func testUndoHistorySurvivesSaveBoundary() throws {
        let (root, url) = try makeDocument("原始内容\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first)
        state.apply(.update(id: block.id, source: "修改后"))
        XCTAssertTrue(state.save())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "修改后\n")
        XCTAssertFalse(state.document?.isDirty == true)

        state.undo()
        XCTAssertEqual(state.blocks.first?.source, "原始内容")
        // 保存边界之后磁盘仍是“修改后”，回退旧内容必须再次标记待保存。
        XCTAssertTrue(state.document?.isDirty == true)
        XCTAssertTrue(state.save())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "原始内容\n")

        state.redo()
        XCTAssertEqual(state.blocks.first?.source, "修改后")
        XCTAssertTrue(state.document?.isDirty == true)
    }

    func testUndoBeforeSavingReturnsToCleanBaseline() throws {
        let (root, url) = try makeDocument("原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first)
        state.apply(.update(id: block.id, source: "修改"))
        state.undo()
        XCTAssertFalse(state.document?.isDirty == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "原始\n")
    }

    func testEditorRoutesUndoAndRedoCommandsToDocumentState() throws {
        let (root, url) = try makeDocument("原始\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(
            rootView: WorkPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 220)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 500, height: 220),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        settle(0.3)

        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText(
            "改",
            replacementRange: NSRange(location: textView.string.utf16.count, length: 0)
        )
        XCTAssertEqual(state.blocks.first?.source, "原始改")

        textView.doCommand(by: NSSelectorFromString("undo:"))
        settle(0.1)
        XCTAssertEqual(state.blocks.first?.source, "原始")
        XCTAssertTrue(state.canRedo)

        textView.doCommand(by: NSSelectorFromString("redo:"))
        settle(0.1)
        XCTAssertEqual(state.blocks.first?.source, "原始改")
    }

    func testUndoAfterSplitRestoresAnEditableFocusedBlock() throws {
        let (root, url) = try makeDocument("第一段")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: WorkPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 260)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 260), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.3)
        var textViews = findTextViews(in: hosting)
        let first = try XCTUnwrap(textViews.first)
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: first.string.utf16.count, length: 0))
        first.doCommand(by: NSSelectorFromString("insertNewline:"))
        settle(0.2)
        XCTAssertGreaterThanOrEqual(findTextViews(in: hosting).count, 2)
        first.doCommand(by: NSSelectorFromString("undo:"))
        settle(0.2)
        textViews = findTextViews(in: hosting)
        let restored = try XCTUnwrap(textViews.first)
        XCTAssertTrue(window.firstResponder === restored)
        XCTAssertTrue(restored.isEditable)
        restored.insertText("后", replacementRange: restored.selectedRange())
        settle(0.15)
        XCTAssertEqual(state.blocks.first?.source, "第一段后")
    }

    func testMovingBlockCarriesSeparatorAndRoundTripsStructure() throws {
        let (root, url) = try makeDocument("一\n\n二\n\n三\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        state.moveBlock(id: editable[2].id, before: editable[0].id)
        let serialized = MarkdownBlockParser.serialize(
            state.blocks,
            usesCRLF: state.document?.usesCRLF ?? false,
            hasTrailingNewline: state.document?.hasTrailingNewline ?? true
        )
        let reparsed = MarkdownBlockParser.parse(serialized)
        XCTAssertEqual(reparsed.filter(\.acceptsCursor).map(\.displayText), ["三", "一", "二"])
        XCTAssertEqual(reparsed.filter { $0.kind == .blank }.count, 2)
    }

    func testMovingBlockIsUndoableAndMarksDocumentDirty() throws {
        let (root, url) = try makeDocument("一\n\n二\n\n三\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        XCTAssertEqual(editable.map(\.displayText), ["一", "二", "三"])
        state.moveBlock(id: editable[2].id, before: editable[0].id)
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).map(\.displayText), ["三", "一", "二"])
        XCTAssertTrue(state.document?.isDirty == true)

        state.undo()
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).map(\.displayText), ["一", "二", "三"])
        state.redo()
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).map(\.displayText), ["三", "一", "二"])
    }

    func testLongOrdinaryInputIsOneUndoStep() throws {
        let (root, url) = try makeDocument("原始\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first)
        for character in "这是一次很长的普通输入" {
            state.apply(.update(id: block.id, source: (state.blocks.first?.source ?? "") + String(character)))
        }
        XCTAssertEqual(state.blocks.first?.source, "原始这是一次很长的普通输入")
        state.undo()
        XCTAssertEqual(state.blocks.first?.source, "原始")
        XCTAssertFalse(state.canUndo)
    }

    func testSeparateEditsUndoInReverseOrderAndNewEditClearsRedo() throws {
        let (root, url) = try makeDocument("一\n\n二\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let blocks = state.blocks.filter { $0.kind == .paragraph }
        XCTAssertEqual(blocks.count, 2)

        state.apply(.update(id: blocks[0].id, source: "一改"))
        state.apply(.update(id: blocks[1].id, source: "二改"))
        state.undo()
        XCTAssertEqual(state.blocks.first(where: { $0.id == blocks[1].id })?.source, "二")
        state.undo()
        XCTAssertEqual(state.blocks.first(where: { $0.id == blocks[0].id })?.source, "一")
        XCTAssertFalse(state.canUndo)
        XCTAssertTrue(state.canRedo)

        state.apply(.update(id: blocks[0].id, source: "一新改"))
        XCTAssertFalse(state.canRedo)
    }

    private func findTextViews(in view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = view as? NSTextView { result.append(textView) }
        for subview in view.subviews {
            result.append(contentsOf: findTextViews(in: subview))
        }
        return result
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func makeDocument(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-markdown-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
    }
}
