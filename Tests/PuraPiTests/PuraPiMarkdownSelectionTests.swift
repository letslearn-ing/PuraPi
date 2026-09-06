import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownSelectionTests: XCTestCase {
    func testSelectionMapsRangesForEachCrossedBlock() {
        let first = MarkdownBlock(
            kind: .heading(level: 2),
            source: "## 标题",
            lineRange: 0..<1
        )
        let second = MarkdownBlock(
            kind: .paragraph,
            source: "正文",
            lineRange: 1..<2
        )
        let selection = PuraPiMarkdownSelection(
            anchor: .init(blockID: first.id, offset: 0),
            focus: .init(blockID: second.id, offset: 2)
        )

        XCTAssertEqual(
            selection.bodyRange(for: first, in: [first, second]),
            NSRange(location: 0, length: ("标题" as NSString).length)
        )
        XCTAssertEqual(
            selection.bodyRange(for: second, in: [first, second]),
            NSRange(location: 0, length: 2)
        )
    }

    func testSelectedMarkdownSourceRestoresBlockMarkers() {
        let heading = MarkdownBlock(
            kind: .heading(level: 2),
            source: "## 标题",
            lineRange: 0..<1
        )
        let list = MarkdownBlock(
            kind: .unorderedListItem(indent: 0, marker: "-"),
            source: "- 项目",
            lineRange: 1..<2
        )
        let state = PuraPiMarkdownEditorState()
        // 通过文件加载获得真实文档基线，再设置文档级选择。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-selection-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.md")
        try? "## 标题\n\n- 项目\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let blocks = state.blocks
        let loadedHeading = blocks.first { if case .heading = $0.kind { return true }; return false }
        let loadedList = blocks.first { if case .unorderedListItem = $0.kind { return true }; return false }
        XCTAssertNotNil(loadedHeading)
        XCTAssertNotNil(loadedList)
        state.setSelection(
            anchor: .init(blockID: loadedHeading!.id, offset: 0),
            focus: .init(blockID: loadedList!.id, offset: loadedList!.displayText.utf16.count)
        )

        XCTAssertEqual(state.selectedMarkdownSource(), "## 标题\n\n- 项目")
        _ = heading
        _ = list
    }

    func testBoundarySelectionCanBeCopiedAsMarkdownSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-selection-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.md")
        try "第一段\n\n第二段\n".write(to: url, atomically: true, encoding: .utf8)

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let editable = state.blocks.filter(\.acceptsCursor)
        XCTAssertEqual(editable.count, 2)
        let first = editable[0]
        let second = editable[1]
        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 260),
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

        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let firstTextView = textViews[0]
        XCTAssertTrue(window.makeFirstResponder(firstTextView))
        let firstLength = first.displayText.utf16.count
        firstTextView.setSelectedRange(NSRange(location: 0, length: firstLength))
        XCTAssertEqual(state.focusedBlockID, first.id)
        state.setLocalSelection(
            blockID: first.id,
            range: NSRange(location: 0, length: firstLength)
        )
        firstTextView.doCommand(by: NSSelectorFromString("moveDownAndModifySelection:"))
        settle(0.15)

        XCTAssertEqual(state.selection?.anchor.blockID, first.id)
        XCTAssertEqual(state.selection?.focus.blockID, second.id)
        XCTAssertEqual(state.selectionRange(for: first.id), NSRange(location: 0, length: firstLength))
        XCTAssertEqual(state.selectionRange(for: second.id), NSRange(location: 0, length: 0))
        XCTAssertEqual(state.focusedBlockID, first.id)
        XCTAssertTrue(window.firstResponder === firstTextView)

        let pasteboard = NSPasteboard.general
        let previousClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousClipboard {
                pasteboard.setString(previousClipboard, forType: .string)
            }
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let secondTextView = textViews[1]
        XCTAssertTrue(secondTextView.performKeyEquivalent(with: event))
        XCTAssertEqual(pasteboard.string(forType: .string), "第一段")
    }

    func testLocalSelectionCanBeClearedByNewEdit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-selection-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.md")
        try "文本\n".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first)
        state.setLocalSelection(blockID: block.id, range: NSRange(location: 0, length: 1))
        XCTAssertNotNil(state.selection)
        state.apply(.update(id: block.id, source: "新文本"))
        XCTAssertNil(state.selection)
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
