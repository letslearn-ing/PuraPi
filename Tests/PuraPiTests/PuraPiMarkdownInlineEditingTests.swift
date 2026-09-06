import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownInlineEditingTests: XCTestCase {
    func testDelimitedFormatWrapsAndTogglesSelection() throws {
        let source = "前后"
        let selected = NSRange(location: 1, length: ("后" as NSString).length)
        let wrapped = try XCTUnwrap(
            PuraPiMarkdownInlineEditing.apply(.strong, to: source, selectedRange: selected)
        )
        XCTAssertEqual(wrapped.text, "前**后**")
        XCTAssertEqual(wrapped.selectedRange, NSRange(location: 3, length: 1))

        let toggled = try XCTUnwrap(
            PuraPiMarkdownInlineEditing.apply(
                .strong,
                to: wrapped.text,
                selectedRange: wrapped.selectedRange
            )
        )
        XCTAssertEqual(toggled.text, source)
        XCTAssertEqual(toggled.selectedRange, selected)
    }

    func testEmptySelectionCreatesInlinePair() throws {
        let result = try XCTUnwrap(
            PuraPiMarkdownInlineEditing.apply(
                .code,
                to: "代码",
                selectedRange: NSRange(location: 2, length: 0)
            )
        )
        XCTAssertEqual(result.text, "代码``")
        XCTAssertEqual(result.selectedRange, NSRange(location: 3, length: 0))
    }

    func testLinkShortcutSelectsURLPlaceholder() throws {
        let result = try XCTUnwrap(
            PuraPiMarkdownInlineEditing.apply(
                .link,
                to: "打开文档",
                selectedRange: NSRange(location: 2, length: ("文档" as NSString).length)
            )
        )
        XCTAssertEqual(result.text, "打开[文档](https://)")
        XCTAssertEqual(
            result.text.nsRange(of: "https://"),
            result.selectedRange
        )
    }

    func testCommandKeyEquivalentRoutesToMarkdownFormat() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-key-equivalent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("document.md")
        try "代码".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
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
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        settle(0.1)
        XCTAssertEqual(state.blocks.first?.source, "`代码`")
    }

    func testInlineShortcutChangesDocumentSourceThroughEditor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("document.md")
        try "文字".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
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
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        textView.doCommand(by: NSSelectorFromString("bold:"))
        settle(0.1)

        XCTAssertEqual(state.blocks.first?.source, "**文字**")
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        (self as NSString).range(of: substring)
    }
}

private extension PuraPiMarkdownInlineEditingTests {
    func findTextViews(in view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = view as? NSTextView { result.append(textView) }
        for subview in view.subviews {
            result.append(contentsOf: findTextViews(in: subview))
        }
        return result
    }

    func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}
