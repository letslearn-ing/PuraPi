import Foundation
import PiDomain
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiMarkdownSyntaxHintTests: XCTestCase {
    func testBlockPrefixAndSlashHints() {
        let paragraph = MarkdownBlock(kind: .paragraph, source: "", lineRange: 0..<1)
        XCTAssertNotNil(
            WorkPiMarkdownSyntaxHint.message(kind: paragraph.kind, text: "#", language: .chinese)
        )
        XCTAssertTrue(
            WorkPiMarkdownSyntaxHint.message(kind: paragraph.kind, text: "/", language: .chinese)?.contains("/表格") == true
        )
    }

    func testUnclosedInlineMarkerHintAndCodeHint() {
        let paragraph = MarkdownBlock(kind: .paragraph, source: "", lineRange: 0..<1)
        let hint = WorkPiMarkdownSyntaxHint.message(
            kind: paragraph.kind,
            text: "这是 **未完成",
            language: .english
        )
        XCTAssertTrue(hint?.contains("**") == true)

        let code = MarkdownBlock.Kind.codeFence(language: "swift", fence: "```")
        XCTAssertTrue(
            WorkPiMarkdownSyntaxHint.message(kind: code, text: "let x", language: .chinese)?.contains("Tab") == true
        )
    }

    func testBalancedInlineTextHasNoHint() {
        let paragraph = MarkdownBlock.Kind.paragraph
        XCTAssertNil(
            WorkPiMarkdownSyntaxHint.message(
                kind: paragraph,
                text: "**完成** 和 `代码`",
                language: .chinese
            )
        )
    }
}
