import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiMarkdownNavigationTests: XCTestCase {
    func testBackspaceAtBlockStartRevertsMarkerToParagraph() throws {
        let (root, url) = try makeDocument("## 标题\n\n正文\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let heading = try XCTUnwrap(state.blocks.first(where: {
            if case .heading = $0.kind { return true }
            return false
        }))
        state.focusedBlockID = heading.id

        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(textView.string, "标题")
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.1)

        let converted = try XCTUnwrap(state.blocks.first)
        XCTAssertEqual(converted.kind, .paragraph)
        XCTAssertEqual(converted.source, "标题")
    }

    func testEmptyListItemBackspaceStillRemovesTheItem() throws {
        let (root, url) = try makeDocument("- \n\n正文\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let item = try XCTUnwrap(state.blocks.first(where: {
            if case .unorderedListItem = $0.kind { return true }
            return false
        }))
        state.focusedBlockID = item.id

        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.1)

        XCTAssertFalse(state.blocks.contains(where: { $0.id == item.id }))
    }

    func testReturnMovesFirstResponderToTheNewBlock() throws {
        let (root, url) = try makeDocument("第一段")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)
        var textViews = findTextViews(in: hosting)
        let first = try XCTUnwrap(textViews.first)
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: first.string.utf16.count, length: 0))
        first.doCommand(by: NSSelectorFromString("insertNewline:"))
        settle(0.25)

        textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let second = try XCTUnwrap(textViews.last)
        XCTAssertEqual(state.focusedBlockID, state.blocks.last(where: \.acceptsCursor)?.id)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertTrue(second.isEditable)
        XCTAssertEqual(second.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testDownArrowMovesFirstResponderToTheNextBlock() throws {
        let (root, url) = try makeDocument("第一段\n\n第二段")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)
        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let first = textViews[0]
        let second = textViews[1]
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: first.string.utf16.count, length: 0))
        first.doCommand(by: NSSelectorFromString("moveDown:"))
        settle(0.2)

        XCTAssertEqual(state.focusedBlockID, state.blocks.last(where: \.acceptsCursor)?.id)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertEqual(second.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testMergingAtBlockStartPlacesCaretAtPreviousBlockEnd() throws {
        let (root, url) = try makeDocument("前文\n\n后文\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        XCTAssertEqual(editable.count, 2)
        state.focusedBlockID = editable[1].id

        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)
        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let second = textViews[1]
        XCTAssertTrue(window.makeFirstResponder(second))
        second.setSelectedRange(NSRange(location: 0, length: 0))
        second.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.2)

        let first = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).map(\.displayText), ["前文后文"])
        XCTAssertTrue(window.firstResponder === first)
        XCTAssertEqual(first.selectedRange(), NSRange(location: first.string.utf16.count, length: 0))
    }

    func testDocumentEndCommandMovesToLastEditableBlock() throws {
        let (root, url) = try makeDocument("第一段\n\n第二段\n\n第三段\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let last = try XCTUnwrap(state.blocks.last(where: { $0.acceptsCursor }))
        let (window, hosting) = makeWindow(state: state)
        defer { close(window, hosting: hosting) }
        settle(0.3)

        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 3)
        let first = try XCTUnwrap(textViews.first)
        XCTAssertTrue(window.makeFirstResponder(first))
        first.doCommand(by: NSSelectorFromString("moveToEndOfDocument:"))
        settle(0.2)

        XCTAssertEqual(state.focusedBlockID, last.id)
        let lastTextView = try XCTUnwrap(textViews.last)
        XCTAssertEqual(lastTextView.selectedRange().location, lastTextView.string.utf16.count)
    }

    private func makeDocument(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-markdown-navigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
    }

    private func makeWindow(state: WorkPiMarkdownEditorState) -> (NSWindow, NSHostingView<WorkPiMarkdownEditorView>) {
        let hosting = NSHostingView(
            rootView: WorkPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 360)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 360),
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
