import Foundation
import PiDomain
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownSyntaxHintTests: XCTestCase {
    func testBlockPrefixAndSlashHints() {
        let paragraph = MarkdownBlock(kind: .paragraph, source: "", lineRange: 0..<1)
        XCTAssertNotNil(
            PuraPiMarkdownSyntaxHint.message(kind: paragraph.kind, text: "#", language: .chinese)
        )
        XCTAssertTrue(
            PuraPiMarkdownSyntaxHint.message(kind: paragraph.kind, text: "/", language: .chinese)?.contains("/表格") == true
        )
    }

    func testUnclosedInlineMarkerHintAndCodeHint() {
        let paragraph = MarkdownBlock(kind: .paragraph, source: "", lineRange: 0..<1)
        let hint = PuraPiMarkdownSyntaxHint.message(
            kind: paragraph.kind,
            text: "这是 **未完成",
            language: .english
        )
        XCTAssertTrue(hint?.contains("**") == true)

        let code = MarkdownBlock.Kind.codeFence(language: "swift", fence: "```")
        XCTAssertTrue(
            PuraPiMarkdownSyntaxHint.message(kind: code, text: "let x", language: .chinese)?.contains("Tab") == true
        )
    }

    func testBalancedInlineTextHasNoHint() {
        let paragraph = MarkdownBlock.Kind.paragraph
        XCTAssertNil(
            PuraPiMarkdownSyntaxHint.message(
                kind: paragraph,
                text: "**完成** 和 `代码`",
                language: .chinese
            )
        )
    }
}
