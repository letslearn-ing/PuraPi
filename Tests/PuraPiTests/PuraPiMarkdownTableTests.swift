import AppKit
import Foundation
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownTableTests: XCTestCase {
    func testTableParserPreservesAlignmentAndEscapedPipes() {
        let source = "| 名称 | 说明 |\n| :--- | ---: |\n| A\\|B | `x|y` |"
        let table = PuraPiMarkdownTableModel(source: source)

        XCTAssertEqual(table.headers, ["名称", "说明"])
        XCTAssertEqual(table.rows, [["A\\|B", "`x|y`"]])
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.value(at: .init(row: 1, column: 0)), "A\\|B")
    }

    func testEditingTableCellsAndStructureSerializesSafely() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        var table = PuraPiMarkdownTableModel(source: source)
        table.update("changed", at: .init(row: 1, column: 1))
        table.appendRow()
        table.appendColumn()
        table.update("new", at: .init(row: 2, column: 2))

        XCTAssertEqual(
            table.serializedSource,
            "| A | B |  |\n| --- | --- | --- |\n| 1 | changed |  |\n|  |  | new |"
        )

        table.removeRow(at: 2)
        table.removeColumn(at: 2)
        XCTAssertEqual(table.serializedSource, "| A | B |\n| --- | --- |\n| 1 | changed |")
    }

    func testTableModelNeverRemovesTheLastColumn() {
        var table = PuraPiMarkdownTableModel(source: "| A |\n| --- |\n| 1 |")
        table.removeColumn(at: 0)
        XCTAssertEqual(table.columnCount, 1)
        XCTAssertEqual(table.headers, ["A"])
    }

    func testTableEditorExposesEditableCellsAndWritesCellChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-table-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("table.md")
        try "| A | B |\n| --- | --- |\n| 1 | 2 |\n".write(to: url, atomically: true, encoding: .utf8)
        let state = PuraPiMarkdownEditorState()
        XCTAssertTrue(state.open(url: url, workspaceRoot: root))

        let hosting = NSHostingView(
            rootView: PuraPiMarkdownEditorView(state: state, language: .chinese)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 700, height: 360),
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

        let fields = findTextFields(in: hosting)
        let header = try XCTUnwrap(fields.first(where: { $0.stringValue == "A" }))
        XCTAssertTrue(header.isEditable)
        XCTAssertTrue(window.makeFirstResponder(header))
        header.stringValue = "改过"
        let notification = Notification(
            name: NSControl.textDidChangeNotification,
            object: header
        )
        (header.delegate as? PuraPiMarkdownTableCellEditor.Coordinator)?
            .controlTextDidChange(notification)
        settle(0.2)

        XCTAssertTrue(state.blocks.first?.source.contains("改过") == true)
    }
}

private extension PuraPiMarkdownTableTests {
    func findTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = view as? NSTextField { result.append(field) }
        for subview in view.subviews {
            result.append(contentsOf: findTextFields(in: subview))
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
