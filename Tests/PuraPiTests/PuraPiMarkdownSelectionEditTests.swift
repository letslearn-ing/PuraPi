import AppKit
import Foundation
import PiDomain
import SwiftUI
import WorkspaceKit
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownSelectionEditTests: XCTestCase {
    func testCrossBlockDeleteRemovesCoveredBlocksAndIsUndoable() throws {
        let (state, root, url) = try makeState(with: "前\n\n中间\n\n后\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        let first = try XCTUnwrap(editable.first)
        let last = try XCTUnwrap(editable.last)
        state.setSelection(
            anchor: PuraPiMarkdownSelectionEndpoint(blockID: first.id, offset: first.displayText.utf16.count),
            focus: PuraPiMarkdownSelectionEndpoint(blockID: last.id, offset: 0)
        )

        let editor = PuraPiMarkdownEditorView(state: state, language: .chinese)
        XCTAssertTrue(editor.replaceDocumentSelection(with: ""))
        XCTAssertEqual(state.serializedLocalText, "前后\n")
        XCTAssertTrue(state.canUndo)

        state.undo()
        XCTAssertEqual(state.serializedLocalText, "前\n\n中间\n\n后\n")
    }

    func testCommandAThenBackspaceLeavesTheCaretAtDocumentStart() throws {
        let (state, root, url) = try makeState(with: "第一段\n\n第二段\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.35)
        var textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.doCommand(by: NSSelectorFromString("selectAll:"))
        textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.25)
        textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).count, 1)
        XCTAssertEqual(state.blocks.first(where: \.acceptsCursor)?.displayText, "")
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testDeletingTheEntireDocumentLeavesOneEmptyEditableLineAtStart() throws {
        let (state, root, url) = try makeState(with: "第一段\n\n第二段\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        let first = try XCTUnwrap(editable.first)
        let last = try XCTUnwrap(editable.last)
        state.setSelection(
            anchor: .init(blockID: first.id, offset: 0),
            focus: .init(blockID: last.id, offset: last.displayText.utf16.count)
        )
        let view = PuraPiMarkdownEditorView(state: state, language: .chinese)
        XCTAssertTrue(view.replaceDocumentSelection(with: ""))
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).count, 1)
        let empty = try XCTUnwrap(state.blocks.first(where: \.acceptsCursor))
        XCTAssertEqual(empty.displayText, "")
        XCTAssertEqual(state.focusedBlockID, empty.id)
        XCTAssertEqual(state.cursorRequest?.placement, .end)
    }

    func testCrossBlockReplacementParsesMultilineReplacement() throws {
        let (state, root, url) = try makeState(with: "左\n\n旧中间\n\n右\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        let first = try XCTUnwrap(editable.first)
        let last = try XCTUnwrap(editable.last)
        state.setSelection(
            anchor: PuraPiMarkdownSelectionEndpoint(blockID: first.id, offset: 1),
            focus: PuraPiMarkdownSelectionEndpoint(blockID: last.id, offset: 0)
        )

        let editor = PuraPiMarkdownEditorView(state: state, language: .chinese)
        XCTAssertTrue(editor.replaceDocumentSelection(with: "一段\n\n二段"))
        XCTAssertEqual(state.serializedLocalText, "左一段\n\n二段右\n")
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.focusedBlockID, state.blocks.last(where: \.acceptsCursor)?.id)
    }

    func testSingleBlockSelectionFallsBackToTextView() throws {
        let (state, root, url) = try makeState(with: "一段\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first(where: \.acceptsCursor))
        state.setSelection(
            anchor: PuraPiMarkdownSelectionEndpoint(blockID: block.id, offset: 0),
            focus: PuraPiMarkdownSelectionEndpoint(blockID: block.id, offset: 1)
        )

        let editor = PuraPiMarkdownEditorView(state: state, language: .chinese)
        XCTAssertFalse(editor.replaceDocumentSelection(with: "替换"))
        XCTAssertEqual(state.serializedLocalText, "一段\n")
    }

    private func findTextViews(in view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = view as? NSTextView {
            result.append(textView)
        }
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

    private func makeState(with text: String) throws -> (
        PuraPiMarkdownEditorState,
        URL,
        URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-markdown-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("doc.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (PuraPiMarkdownEditorState(), root, url)
    }
}
