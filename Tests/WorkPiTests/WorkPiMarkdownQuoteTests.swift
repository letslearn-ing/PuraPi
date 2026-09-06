import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiMarkdownQuoteTests: XCTestCase {
    func testNestedQuoteMarkerConversionPreservesDepth() throws {
        let block = MarkdownBlock(
            kind: .paragraph,
            source: "",
            lineRange: 0..<1
        )
        let converted = try XCTUnwrap(
            WorkPiMarkdownBlockConverter.convert(block: block, displayText: "> > 深层引用")
        )
        XCTAssertEqual(converted.kind, .quote(depth: 2))
        XCTAssertEqual(converted.source, "> > 深层引用")
    }

    func testMultilineQuoteDisplayAndSerializationPreservePrefixes() {
        let block = MarkdownBlock(
            kind: .quote(depth: 2),
            source: "> > 第一行\n> > 第二行",
            lineRange: 0..<2
        )
        XCTAssertEqual(block.displayText, "第一行\n第二行")
        XCTAssertEqual(
            WorkPiMarkdownBlockConverter.composeSource(
                kind: block.kind,
                displayText: block.displayText
            ),
            block.source
        )
    }

    func testReturnInQuoteCreatesAnotherQuoteBlock() throws {
        let (root, url) = try makeDocument("> 引用一\n\n正文\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let quote = try XCTUnwrap(state.blocks.first(where: {
            if case .quote = $0.kind { return true }
            return false
        }))
        state.focusedBlockID = quote.id

        let (window, hosting) = makeWindow(state: state)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            _ = hosting
        }
        settle(0.3)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(textView.string, "引用一")
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.doCommand(by: NSSelectorFromString("insertNewline:"))
        settle(0.1)

        let quoteBlocks = state.blocks.compactMap { block -> MarkdownBlock? in
            if case .quote = block.kind { return block }
            return nil
        }
        XCTAssertEqual(quoteBlocks.count, 2)
        XCTAssertEqual(quoteBlocks[1].source, "> ")
    }

    private func makeDocument(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-markdown-quote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
    }

    private func makeWindow(state: WorkPiMarkdownEditorState) -> (NSWindow, NSHostingView<WorkPiMarkdownEditorView>) {
        let hosting = NSHostingView(
            rootView: WorkPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 320),
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
