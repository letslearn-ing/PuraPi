import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownEditorRenderTests: XCTestCase {
    func testEmptyMarkdownFileProvidesAnEditableFirstRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-empty-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("empty.md")
        try Data().write(to: url)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))

        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
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
        settle(0.4)

        let textViews = findTextViews(in: hosting)
        XCTAssertEqual(textViews.count, 1, "空文件应提供一个可编辑的首行")
        XCTAssertTrue(textViews[0].isEditable)

        window.makeFirstResponder(textViews[0])
        textViews[0].insertText(
            "第一行",
            replacementRange: NSRange(location: 0, length: 0)
        )
        settle(0.2)

        XCTAssertEqual(state.blocks.count, 1)
        XCTAssertEqual(state.blocks[0].source, "第一行")
        XCTAssertTrue(state.document?.isDirty == true)
    }

    func testDeletingTheOnlyParagraphKeepsAnEmptyFirstResponderAtStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-delete-empty-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("empty-after-delete.md")
        try "中文".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))

        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
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
        settle(0.4)

        var textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.2)

        XCTAssertEqual(state.blocks.count, 1)
        XCTAssertEqual(state.blocks[0].source, "")
        textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))

        textView.insertText("再次输入", replacementRange: NSRange(location: 0, length: 0))
        settle(0.2)
        XCTAssertEqual(state.blocks[0].source, "再次输入")
    }

    func testDeleteCharactersOneByOneKeepsSelectionAtStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-delete-one-by-one-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("doc.md")
        try "中文".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        var textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        for expected in ["中", ""] {
            textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
            settle(0.15)
            textView = try XCTUnwrap(findTextViews(in: hosting).first)
            XCTAssertEqual(state.blocks.first?.source, expected)
            XCTAssertTrue(window.firstResponder === textView)
            XCTAssertEqual(textView.selectedRange().length, 0)
            XCTAssertEqual(textView.selectedRange().location, expected.utf16.count)
        }
        textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.15)
        textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testClickingAnUnfocusedBlockMakesItEditableImmediately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-click-focus-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("click.md")
        try "第一段\n\n第二段".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let first = textViews[0]
        let second = textViews[1]
        XCTAssertTrue(window.firstResponder === first)
        window.invalidateCursorRects(for: second)
        NSCursor.arrow.set()
        defer { NSCursor.arrow.set() }
        let cursorPoint = second.convert(NSPoint(x: second.bounds.midX, y: second.bounds.midY), to: nil)
        if let move = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: cursorPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 30,
            clickCount: 0,
            pressure: 0
        ) {
            second.mouseMoved(with: move)
        }
        XCTAssertEqual(NSCursor.current.image.size, NSCursor.iBeam.image.size)
        let point = cursorPoint
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 31,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 32,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        window.contentView?.hitTest(point)?.mouseDown(with: down)
        settle(0.15)

        XCTAssertTrue(window.firstResponder === second)
        XCTAssertEqual(state.focusedBlockID, state.blocks.last(where: \.acceptsCursor)?.id)
        second.insertText("追加", replacementRange: second.selectedRange())
        settle(0.15)
        XCTAssertTrue(state.blocks.last(where: \.acceptsCursor)?.source.contains("追加") == true)
    }

    func testClickingRenderedInlineTextMapsCaretBackToSourceOffset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-inline-click-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("inline-click.md")
        try "**甲乙**".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        state.focusedBlockID = nil
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.string, "甲乙")
        // 以第一个可见字符右侧为点击点，不能依赖源码标记的宽度。
        let point = NSPoint(x: 8, y: textView.bounds.midY)
        let windowPoint = textView.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 41,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 42,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        textView.mouseDown(with: down)
        settle(0.15)

        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.string, "**甲乙**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
        textView.insertText("X", replacementRange: textView.selectedRange())
        settle(0.15)
        XCTAssertEqual(state.blocks.first?.source, "**甲X乙**")
    }

    func testDraggingAcrossRenderedInlineTextPreservesSourceSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-inline-drag-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("inline-drag.md")
        try "**甲乙丙**".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        state.focusedBlockID = nil
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        let start = textView.convert(NSPoint(x: 1, y: textView.bounds.midY), to: nil)
        let end = textView.convert(NSPoint(x: 28, y: textView.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 51, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 52, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.02, windowNumber: window.windowNumber, context: nil, eventNumber: 53, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(drag, atStart: true)
        textView.mouseDown(with: down)
        settle(0.15)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertGreaterThan(textView.selectedRange().length, 0)
        XCTAssertEqual(state.blocks.first?.source, "**甲乙丙**")
    }

    func testSequentialTypingKeepsCaretAfterInsertedCharacters() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-sequential-typing-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("typing.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        var textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        for (character, expected) in [("你", "你"), ("好", "你好"), ("😀", "你好😀")] {
            textView.insertText(character, replacementRange: textView.selectedRange())
            settle(0.12)
            XCTAssertEqual(state.blocks.last?.source, expected)
            textView = try XCTUnwrap(findTextViews(in: hosting).first)
            XCTAssertTrue(window.firstResponder === textView)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: expected.utf16.count, length: 0))
        }
    }

    func testEditingInTheMiddleKeepsCaretAfterTheInsertedText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-middle-edit-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("middle.md")
        try "甲乙丙".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText("X", replacementRange: textView.selectedRange())
        settle(0.2)
        XCTAssertEqual(state.blocks.first?.source, "甲X乙丙")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        textView.doCommand(by: NSSelectorFromString("deleteBackward:"))
        settle(0.15)
        XCTAssertEqual(state.blocks.first?.source, "甲乙丙")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testBlockMarkerConversionPreservesCaretAtEnd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-marker-typing-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("marker.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        var textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        for (value, expected) in [("# ", ""), ("标题", "标题")] {
            textView.insertText(value, replacementRange: textView.selectedRange())
            settle(0.15)
            textView = try XCTUnwrap(findTextViews(in: hosting).first)
            XCTAssertEqual(state.blocks.last?.displayText, expected)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: expected.utf16.count, length: 0))
            XCTAssertTrue(window.firstResponder === textView)
        }
        guard case .heading = state.blocks.last?.kind else {
            return XCTFail("行首标记应转换为标题块")
        }
    }

    func testTypingInlineMarkersDoesNotMoveCaretOrLoseText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-inline-typing-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("inline-typing.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        var textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        for (value, expected) in [("*", "*"), ("粗", "*粗"), ("*", "*粗*")] {
            textView.insertText(value, replacementRange: textView.selectedRange())
            settle(0.12)
            textView = try XCTUnwrap(findTextViews(in: hosting).first)
            XCTAssertEqual(state.blocks.last?.source, expected)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: expected.utf16.count, length: 0))
            XCTAssertTrue(window.firstResponder === textView)
        }
    }

    func testMarkedTextIsNotRewrittenAndCommittedChineseTextReachesModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-marked-text-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ime.md")
        try "原".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.setMarkedText(
            "n",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 1, length: 0)
        )
        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 1, length: 1)
        )
        settle(0.1)
        // 强制一次模型/SwiftUI 重绘，验证它不会覆盖输入法的临时文本。
        if let block = state.blocks.first {
            state.setLocalSelection(blockID: block.id, range: textView.selectedRange())
        }
        settle(0.05)

        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(state.blocks.first?.source, "原")
        XCTAssertEqual(textView.string, "原ni")

        textView.insertText("你", replacementRange: textView.markedRange())
        settle(0.2)
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "原你")
        XCTAssertEqual(state.blocks.first?.source, "原你")
    }

    func testReturnInEmptyDocumentMovesFocusToTheNewLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-empty-return-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("empty-return.md")
        try Data().write(to: url)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let placeholder = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(placeholder))
        placeholder.doCommand(by: NSSelectorFromString("insertNewline:"))
        settle(0.2)
        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        XCTAssertTrue(window.firstResponder === textViews.last)
        XCTAssertEqual(textViews.last?.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(state.focusedBlockID, state.blocks.last(where: \.acceptsCursor)?.id)
    }

    func testChineseCompositionCanCreateTheFirstBlockInAnEmptyFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-empty-ime-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("empty-ime.md")
        try Data().write(to: url)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let placeholder = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(placeholder))
        placeholder.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        settle(0.05)
        XCTAssertTrue(placeholder.hasMarkedText())
        XCTAssertTrue(state.blocks.isEmpty)
        placeholder.insertText("你", replacementRange: placeholder.markedRange())
        settle(0.2)
        let editor = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(state.blocks.last?.source, "你")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testMarkedTextDoesNotLeakWhenFocusMovesToAnotherBlock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-marked-focus-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("focus-change.md")
        try "原文\n\n第二段".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(rootView: PuraPiMarkdownEditorView(state: state, language: .chinese))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle(0.4)
        let textViews = findTextViews(in: hosting)
        XCTAssertGreaterThanOrEqual(textViews.count, 2)
        let first = textViews[0]
        let second = textViews[1]
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: first.string.utf16.count, length: 0))
        first.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: first.string.utf16.count, length: 0))
        settle(0.05)
        XCTAssertTrue(first.hasMarkedText())
        XCTAssertEqual(state.blocks[0].source, "原文")

        XCTAssertTrue(window.makeFirstResponder(second))
        settle(0.2)
        // 本产品选择在切焦点时取消未确认的组合；拼音不能以半成品写入
        // 原块，更不能泄漏到第二块。
        XCTAssertFalse(first.hasMarkedText())
        XCTAssertEqual(first.string, "原文")
        XCTAssertEqual(state.blocks[0].source, "原文")
        XCTAssertFalse(state.blocks[1].source.contains("ni"))
        XCTAssertFalse(state.blocks[1].source.contains("你"))
    }

    func testWhitespaceOnlyMarkdownFileProvidesAnEditableRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-whitespace-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("blank.md")
        try "\n\n".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
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
        settle(0.4)

        let textViews = findTextViews(in: hosting)
        XCTAssertEqual(textViews.count, 1, "只有空行的文件也应提供一个可编辑行")
        window.makeFirstResponder(textViews[0])
        textViews[0].insertText(
            "正文",
            replacementRange: NSRange(location: 0, length: 0)
        )
        settle(0.2)

        XCTAssertEqual(state.blocks.last?.source, "正文")
        XCTAssertTrue(state.blocks.contains { $0.kind == .blank })
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
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
    }
}
