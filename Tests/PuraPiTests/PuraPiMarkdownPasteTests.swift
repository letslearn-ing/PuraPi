import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
import WorkspaceKit
@testable import PuraPi

@MainActor
final class PuraPiMarkdownPasteTests: XCTestCase {
    func testMultilinePasteSplitsIntoStructuredBlocks() throws {
        let (root, url) = try makeDocument("起点\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let first = try XCTUnwrap(state.blocks.first)
        let (window, hosting) = makeWindow(state: state)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            _ = hosting
        }
        settle(0.3)

        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText(
            "第一段\n\n## 标题\n\n- 项目",
            replacementRange: textView.selectedRange()
        )
        settle(0.15)

        XCTAssertEqual(state.blocks.first?.id, first.id)
        XCTAssertTrue(state.blocks.contains { $0.source.contains("起点第一段") })
        XCTAssertTrue(state.blocks.contains {
            if case .heading(level: 2) = $0.kind { return $0.displayText == "标题" }
            return false
        })
        XCTAssertTrue(state.blocks.contains {
            if case .unorderedListItem = $0.kind { return $0.displayText == "项目" }
            return false
        })
        XCTAssertTrue(state.canUndo)
    }

    func testTrailingBlankPasteKeepsSuffixOutOfSeparatorBlock() throws {
        let (root, url) = try makeDocument("起点尾巴\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first)
        let view = PuraPiMarkdownEditorView(state: state, language: .chinese)
        XCTAssertTrue(view.handlePaste(
            block: block,
            pastedText: "中间\n\n",
            affectedRange: NSRange(location: 2, length: 0)
        ))
        XCTAssertFalse(state.blocks.contains { $0.kind == .blank && $0.source.contains("尾巴") })
        XCTAssertEqual(state.blocks.filter(\.acceptsCursor).map(\.displayText), ["起点中间", "尾巴"])
        let serialized = MarkdownBlockParser.serialize(state.blocks)
        XCTAssertEqual(
            MarkdownBlockParser.parse(serialized).filter(\.acceptsCursor).map(\.displayText),
            ["起点中间", "尾巴"]
        )
    }

    func testSlashInsertionCreatesTableAndCodeBlocks() throws {
        let table = try XCTUnwrap(PuraPiMarkdownBlockConverter.slashInsertion("/表格"))
        XCTAssertEqual(table.kind, .table)
        XCTAssertTrue(table.source.contains("| --- | --- |"))

        let code = try XCTUnwrap(PuraPiMarkdownBlockConverter.slashInsertion("/code"))
        guard case .codeFence(let language, let fence) = code.kind else {
            return XCTFail("/code 应创建代码块")
        }
        XCTAssertNil(language)
        XCTAssertEqual(code.source, "```\n\n```")
        XCTAssertEqual(fence, "```")
    }

    func testCodeBlockMultilinePasteRemainsCodeText() throws {
        let (root, url) = try makeDocument("```swift\nlet a = 1\n```\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let (window, hosting) = makeWindow(state: state)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            _ = hosting
        }
        settle(0.3)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText(
            "\nlet b = 2",
            replacementRange: textView.selectedRange()
        )
        settle(0.1)

        XCTAssertEqual(state.blocks.count, 1)
        XCTAssertTrue(state.blocks[0].source.contains("let b = 2"))
        guard case .codeFence(let language, _) = state.blocks[0].kind else {
            return XCTFail("代码块不应被粘贴拆开")
        }
        XCTAssertEqual(language, "swift")
    }

    private func makeDocument(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
    }

    private func makeWindow(state: PuraPiMarkdownEditorState) -> (NSWindow, NSHostingView<PuraPiMarkdownEditorView>) {
        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 700, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return (window, hosting)
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
