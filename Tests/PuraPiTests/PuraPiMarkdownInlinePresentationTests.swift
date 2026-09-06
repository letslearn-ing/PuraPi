import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownInlinePresentationTests: XCTestCase {
    func testUnfocusedPresentationHidesMarkersAndAppliesInlineStyles() {
        let source = "前 **粗😀**、*斜*、`码`、~~删~~ 后"
        let paragraph = NSParagraphStyle.default
        let result = PuraPiMarkdownInlinePresentation.render(
            source: source,
            baseFont: .systemFont(ofSize: 14),
            baseColor: .labelColor,
            paragraphStyle: paragraph,
            showsMarkers: false
        )

        XCTAssertEqual(result.attributedString.string, "前 粗😀、斜、码、删 后")
        XCTAssertFalse(result.attributedString.string.contains("**"))
        XCTAssertFalse(result.attributedString.string.contains("~~"))

        let rendered = result.attributedString
        let boldRange = rendered.string.nsRange(of: "粗😀")
        let italicRange = rendered.string.nsRange(of: "斜")
        let codeRange = rendered.string.nsRange(of: "码")
        let strikeRange = rendered.string.nsRange(of: "删")

        let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let italicFont = rendered.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)

        let codeFont = rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(codeFont?.isFixedPitch == true)
        XCTAssertNotNil(
            rendered.attribute(
                NSAttributedString.Key.backgroundColor,
                at: codeRange.location,
                effectiveRange: nil
            )
        )

        let strike = rendered.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? NSNumber
        XCTAssertEqual(strike?.intValue, NSUnderlineStyle.single.rawValue)
    }

    func testUnfocusedLinkHidesDestinationAndKeepsLinkStyle() {
        let source = "打开 [文档😀](https://example.com/path)"
        let result = PuraPiMarkdownInlinePresentation.render(
            source: source,
            baseFont: .systemFont(ofSize: 14),
            baseColor: .labelColor,
            paragraphStyle: NSParagraphStyle.default,
            showsMarkers: false
        )
        XCTAssertEqual(result.attributedString.string, "打开 文档😀")
        let location = result.attributedString.string.nsRange(of: "文档😀").location
        XCTAssertEqual(
            result.attributedString.attribute(.underlineStyle, at: location, effectiveRange: nil) as? NSNumber,
            NSNumber(value: NSUnderlineStyle.single.rawValue)
        )
        XCTAssertEqual(
            result.sourceRange(for: NSRange(
                location: location + ("文档😀" as NSString).length,
                length: 0
            )).location,
            (source as NSString).length
        )
    }

    func testFocusedPresentationKeepsSourceAndMapsIdentity() {
        let source = "**粗体** 和 `代码`"
        let result = PuraPiMarkdownInlinePresentation.render(
            source: source,
            baseFont: .systemFont(ofSize: 14),
            baseColor: .labelColor,
            paragraphStyle: NSParagraphStyle.default,
            showsMarkers: true
        )

        XCTAssertEqual(result.attributedString.string, source)
        XCTAssertEqual(result.sourceToVisible, Array(0...source.utf16.count))
        XCTAssertEqual(result.visibleToSource, Array(0...source.utf16.count))

        let markerLocation = (source as NSString).range(of: "**").location
        let markerColor = result.attributedString.attribute(
            .foregroundColor,
            at: markerLocation,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertNotNil(markerColor)
        XCTAssertLessThan(markerColor?.alphaComponent ?? 1, 1)
    }

    func testHiddenMarkerCursorMappingUsesTextSideOfMarker() {
        let source = "前 **粗😀** 后"
        let result = PuraPiMarkdownInlinePresentation.render(
            source: source,
            baseFont: .systemFont(ofSize: 14),
            baseColor: .labelColor,
            paragraphStyle: NSParagraphStyle.default,
            showsMarkers: false
        )
        let visible = result.attributedString.string as NSString
        let visibleBoldStart = visible.range(of: "粗").location
        let sourceBoldStart = (source as NSString).range(of: "粗").location
        XCTAssertEqual(
            result.sourceRange(for: NSRange(location: visibleBoldStart, length: 0)).location,
            sourceBoldStart
        )

        let visibleEnd = visibleBoldStart + visible.range(of: "粗😀").length
        let sourceAfterClosingMarker = (source as NSString).range(of: " 后").location
        XCTAssertEqual(
            result.sourceRange(for: NSRange(location: visibleEnd, length: 0)).location,
            sourceAfterClosingMarker
        )

        let sourceContentRange = NSRange(
            location: sourceBoldStart,
            length: ("粗😀" as NSString).length
        )
        XCTAssertEqual(
            result.visibleRange(for: sourceContentRange),
            NSRange(location: visibleBoldStart, length: ("粗😀" as NSString).length)
        )
    }

    func testUnmatchedAndCodeMarkersRemainLiteral() {
        let source = #"未闭合 **粗体、\*转义\*、`a ** b`"#
        let result = PuraPiMarkdownInlinePresentation.render(
            source: source,
            baseFont: .systemFont(ofSize: 14),
            baseColor: .labelColor,
            paragraphStyle: NSParagraphStyle.default,
            showsMarkers: false
        )

        XCTAssertEqual(result.attributedString.string, "未闭合 **粗体、\\*转义\\*、a ** b")
        XCTAssertNil(
            result.attributedString.attribute(
                NSAttributedString.Key.backgroundColor,
                at: 0,
                effectiveRange: nil
            )
        )

        let codeLocation = result.attributedString.string.nsRange(of: "a ** b").location
        XCTAssertNotNil(
            result.attributedString.attribute(
                NSAttributedString.Key.backgroundColor,
                at: codeLocation,
                effectiveRange: nil
            )
        )
    }

    func testCodeBlockDisablesInlineFormatting() {
        let source = "**不是粗体** `也不是代码`"
        let result = PuraPiMarkdownInlinePresentation.render(
            source: source,
            baseFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            baseColor: .labelColor,
            paragraphStyle: NSParagraphStyle.default,
            showsMarkers: false,
            allowsFormatting: false
        )

        XCTAssertEqual(result.attributedString.string, source)
        XCTAssertNil(
            result.attributedString.attribute(
                NSAttributedString.Key.backgroundColor,
                at: 0,
                effectiveRange: nil
            )
        )
    }

    func testRenderedBlockBecomesEditableBeforeTextInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-inline-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("inline.md")
        let source = "**粗体**"
        try source.write(to: url, atomically: true, encoding: .utf8)

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        state.focusedBlockID = nil

        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 240),
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
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.string, "粗体")
        XCTAssertTrue(window.makeFirstResponder(textView))
        // 成为 firstResponder 的同一调用栈内必须恢复源码并允许编辑，
        // 不能要求用户等待一次 SwiftUI 重绘或吞掉紧接着输入的第一个字符。
        XCTAssertEqual(state.focusedBlockID, state.blocks[0].id)
        XCTAssertTrue(textView.isEditable)
        XCTAssertEqual(textView.string, source)
        textView.insertText(
            "!",
            replacementRange: NSRange(location: source.utf16.count, length: 0)
        )
        settle(0.2)
        XCTAssertEqual(state.blocks[0].source, "**粗体**!")
    }

    func testEditorTogglesInlineMarkersWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-inline-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("inline.md")
        let source = "**粗体**、*斜体*、`代码`、~~删除~~"
        try source.write(to: url, atomically: true, encoding: .utf8)

        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))
        state.focusedBlockID = nil

        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
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
        settle(0.35)

        let textView = try XCTUnwrap(findTextViews(in: hosting).first)
        XCTAssertEqual(textView.string, "粗体、斜体、代码、删除")
        let codeLocation = textView.string.nsRange(of: "代码").location
        XCTAssertNotNil(
            textView.textStorage?.attribute(
                NSAttributedString.Key.backgroundColor,
                at: codeLocation,
                effectiveRange: nil
            )
        )

        state.focusedBlockID = state.blocks[0].id
        settle(0.2)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(state.blocks[0].source, source)

        state.focusedBlockID = nil
        settle(0.2)
        XCTAssertEqual(textView.string, "粗体、斜体、代码、删除")
        XCTAssertEqual(state.blocks[0].source, source)
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

private extension String {
    func nsRange(of substring: String) -> NSRange {
        (self as NSString).range(of: substring)
    }
}
