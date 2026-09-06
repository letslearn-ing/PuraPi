import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownCodeBlockTests: XCTestCase {
    func testTabInsertsIndentAndKeepsCodeFenceBlock() throws {
        let (root, url) = try makeDocument("```swift\nlet value = 1\n```\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let codeBlock = try XCTUnwrap(state.blocks.first(where: {
            if case .codeFence = $0.kind { return true }
            return false
        }))
        let (window, hosting) = makeWindow(state: state)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            _ = hosting
        }
        settle(0.3)

        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(textView.string, "let value = 1")
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.doCommand(by: NSSelectorFromString("insertTab:"))
        settle(0.1)

        XCTAssertEqual(state.blocks.first(where: { $0.id == codeBlock.id })?.source,
                       "```swift\n\tlet value = 1\n```")
        guard case .codeFence(let language, _) = state.blocks.first(where: { $0.id == codeBlock.id })?.kind else {
            return XCTFail("应仍然是代码块")
        }
        XCTAssertEqual(language, "swift")
    }

    func testCodeLanguageChangeRebuildsOnlyFenceHeader() throws {
        let (root, url) = try makeDocument("```swift\nlet value = 1\n```\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let block = try XCTUnwrap(state.blocks.first)
        guard case .codeFence(_, let fence) = block.kind else {
            return XCTFail("应读取为代码块")
        }
        let kind = MarkdownBlock.Kind.codeFence(language: "python", fence: fence)
        let source = PuraPiMarkdownBlockConverter.composeSource(
            kind: kind,
            displayText: block.displayText
        )
        state.apply(.retype(id: block.id, kind: kind, source: source))

        XCTAssertEqual(state.blocks.first?.source, "```python\nlet value = 1\n```")
        XCTAssertEqual(state.blocks.first?.displayText, "let value = 1")
    }

    private func makeDocument(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
    }

    private func makeWindow(state: PuraPiMarkdownEditorState) -> (NSWindow, NSHostingView<PuraPiMarkdownEditorView>) {
        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
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
