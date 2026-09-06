import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiMarkdownFindReplaceTests: XCTestCase {
    func testFindStateMatchesAcrossBlocksAndWrapsNavigation() {
        let first = MarkdownBlock(kind: .paragraph, source: "Alpha alpha", lineRange: 0..<1)
        let second = MarkdownBlock(kind: .heading(level: 2), source: "## ALPHA", lineRange: 1..<2)
        let state = WorkPiMarkdownFindReplaceState()
        state.query = "alpha"
        state.update(blocks: [first, second])

        XCTAssertEqual(state.matches.count, 3)
        XCTAssertEqual(state.summary, "1/3")
        state.next()
        state.next()
        state.next()
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testFindStateBoundsQueryAndMatchCount() {
        let block = MarkdownBlock(kind: .paragraph, source: String(repeating: "a", count: 20), lineRange: 0..<1)
        let state = WorkPiMarkdownFindReplaceState()
        state.query = String(repeating: "q", count: 5_000)
        state.update(blocks: [block])
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertEqual(state.summary, "0")
    }

    func testCommandFOpensEditorFindBar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-markdown-find-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.md")
        try "正文\n".write(to: url, atomically: true, encoding: .utf8)
        let state = WorkPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(
            rootView: WorkPiMarkdownEditorView(state: state, language: .chinese)
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
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        settle(0.2)
        XCTAssertTrue(findTextFields(in: hosting).contains {
            $0.placeholderString == "查找"
        })
    }

    func testFindStateDismissClearsSensitiveTransientText() {
        let state = WorkPiMarkdownFindReplaceState()
        state.query = "secret search"
        state.replacement = "secret replacement"
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.query.isEmpty)
        XCTAssertTrue(state.replacement.isEmpty)
    }

    private func findTextViews(in view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = view as? NSTextView { result.append(textView) }
        for subview in view.subviews {
            result.append(contentsOf: findTextViews(in: subview))
        }
        return result
    }

    private func findTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = view as? NSTextField { result.append(field) }
        for subview in view.subviews {
            result.append(contentsOf: findTextFields(in: subview))
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
