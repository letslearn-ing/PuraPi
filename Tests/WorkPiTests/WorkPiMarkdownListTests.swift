import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiMarkdownListTests: XCTestCase {
    func testTabAndBacktabChangeListIndent() throws {
        let (root, url) = try makeDocument("- 一\n- 二\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let second = try XCTUnwrap(state.blocks.last(where: {
            if case .unorderedListItem = $0.kind { return true }
            return false
        }))
        state.focusedBlockID = second.id
        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)

        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let secondTextView = textViews[1]
        XCTAssertTrue(window.makeFirstResponder(secondTextView))
        secondTextView.doCommand(by: NSSelectorFromString("insertTab:"))
        settle(0.1)

        guard case .unorderedListItem(let indent, _) = state.blocks.last?.kind else {
            return XCTFail("应仍然是无序列表项")
        }
        XCTAssertEqual(indent, 2)
        XCTAssertEqual(state.blocks.last?.source, "  - 二")

        secondTextView.doCommand(by: NSSelectorFromString("insertBacktab:"))
        settle(0.1)
        guard case .unorderedListItem(let unindented, _) = state.blocks.last?.kind else {
            return XCTFail("退格后应仍然是无序列表项")
        }
        XCTAssertEqual(unindented, 0)
        XCTAssertEqual(state.blocks.last?.source, "- 二")
    }

    func testOrderedListNumbersAreIndependentPerIndentLevel() throws {
        let (root, url) = try makeDocument(
            "1. 父一\n2. 父二\n  1. 子一\n  4. 子四\n4. 父四\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let view = WorkPiMarkdownEditorView(state: state, language: .chinese)
        view.renumberOrderedLists()

        let ordered = state.blocks.compactMap { block -> (Int, Int)? in
            guard case .orderedListItem(let indent, let number, _) = block.kind else { return nil }
            return (indent, number)
        }
        XCTAssertEqual(
            ordered.map { "\($0.0):\($0.1)" },
            ["0:1", "0:2", "2:1", "2:2", "0:3"]
        )
    }

    func testReturnOnEmptyListItemExitsList() throws {
        let (root, url) = try makeDocument("- 一\n- \n\n正文\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let empty = try XCTUnwrap(state.blocks.first(where: {
            if case .unorderedListItem = $0.kind { return $0.displayText.isEmpty }
            return false
        }))
        state.focusedBlockID = empty.id
        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)

        let textViews = findTextViews(in: hosting)
        let emptyIndex = try XCTUnwrap(state.blocks.firstIndex(where: { $0.id == empty.id }))
        // 空项之前的列表项也有编辑器；找到对应空项的空字符串视图。
        let emptyTextView = try XCTUnwrap(textViews.first(where: { $0.string.isEmpty }))
        XCTAssertTrue(window.makeFirstResponder(emptyTextView))
        emptyTextView.doCommand(by: NSSelectorFromString("insertNewline:"))
        settle(0.1)

        XCTAssertEqual(state.blocks[emptyIndex].kind, .paragraph)
        XCTAssertEqual(state.blocks[emptyIndex].source, "")
    }

    private func makeDocument(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-markdown-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
    }

    private func makeWindow(state: WorkPiMarkdownEditorState) -> (NSWindow, NSHostingView<WorkPiMarkdownEditorView>) {
        let hosting = NSHostingView(
            rootView: WorkPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 340)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 340),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return (window, hosting)
    }

    private func close(_ window: NSWindow, hosting: NSHostingView<WorkPiMarkdownEditorView>) {
        window.orderOut(nil)
        window.contentView = nil
        _ = hosting
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
}
