import Foundation
import PiDomain
import XCTest
@testable import WorkspaceKit

/// 源码 ↔ 块序列的往返保真。
///
/// 这是编辑器最硬的要求：`serialize(parse(text)) == text` 必须逐字节成立。
/// 一旦破坏，用户只改一行也会重写整个文件，既污染 git diff，也会让 Agent 的
/// `edit` 工具失效（它依赖 `oldText` 精确匹配）。
final class MarkdownBlockParserTests: XCTestCase {
    // MARK: - 往返保真

    private func assertRoundTrip(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let blocks = MarkdownBlockParser.parse(text)
        let restored = MarkdownBlockParser.serialize(
            blocks,
            usesCRLF: MarkdownBlockParser.detectCRLF(text),
            hasTrailingNewline: MarkdownBlockParser.detectTrailingNewline(text)
        )
        XCTAssertEqual(restored, text, "往返不保真", file: file, line: line)
    }

    func testRoundTripBasicBlocks() {
        assertRoundTrip("""
        # 标题

        一段正文。

        ## 二级标题

        - 项一
        - 项二

        1. 第一
        2. 第二

        > 引用

        ---

        ```swift
        let x = 1
        ```

        """)
    }

    /// 空行数量必须原样保留——多空行是作者的排版意图。
    func testRoundTripPreservesBlankLineCount() {
        assertRoundTrip("段落一\n\n\n\n段落二\n")
        assertRoundTrip("段落一\n\n段落二\n")
    }

    /// 列表符号不做统一：作者用 `*` 就保持 `*`。
    func testRoundTripPreservesListMarkers() {
        assertRoundTrip("* 星号项\n+ 加号项\n- 减号项\n")
        assertRoundTrip("1) 圆括号\n2. 句点\n")
    }

    /// 缩进宽度原样保留。
    func testRoundTripPreservesIndentation() {
        assertRoundTrip("- 一级\n  - 二级\n    - 三级\n")
    }

    func testRoundTripPreservesCRLF() {
        let text = "# 标题\r\n\r\n正文\r\n"
        let blocks = MarkdownBlockParser.parse(text)
        let restored = MarkdownBlockParser.serialize(
            blocks,
            usesCRLF: true,
            hasTrailingNewline: true
        )
        XCTAssertEqual(restored, text)
    }

    func testRoundTripPreservesMixedLineEndings() {
        assertRoundTrip("第一行\r\n第二行\n\r\n第三行\r\n")
        assertRoundTrip("\r\n\n\r\n")
        assertRoundTrip("仅使用 CR 的第一行\r第二行\r")
    }

    func testRoundTripPreservesMultilineCodeLineEndings() {
        assertRoundTrip("```swift\r\nlet a = 1\nlet b = 2\r\n```\n")
    }

    /// 无尾随换行的文件不能被擅自补上。
    func testRoundTripWithoutTrailingNewline() {
        assertRoundTrip("只有一行，没有换行结尾")
    }

    func testRoundTripEmptyDocument() {
        assertRoundTrip("")
    }

    /// 未闭合围栏（流式写入或文件截断）不能吃掉后续内容或崩溃。
    func testRoundTripUnclosedFence() {
        assertRoundTrip("```swift\nlet x = 1\n")
    }

    func testRoundTripTable() {
        assertRoundTrip("""
        | 列一 | 列二 |
        |---|---|
        | a | b |

        """)
    }

    // MARK: - 块识别

    func testHeadingLevels() {
        let blocks = MarkdownBlockParser.parse("# 一\n## 二\n###### 六\n####### 七\n")
        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(blocks[1].kind, .heading(level: 2))
        XCTAssertEqual(blocks[2].kind, .heading(level: 6))
        // 七个 # 不是合法标题，退化为段落
        XCTAssertEqual(blocks[3].kind, .paragraph)
    }

    /// `#标题` 没有空格，不是标题。
    func testHeadingRequiresSpace() {
        let blocks = MarkdownBlockParser.parse("#不是标题\n")
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    /// `---` 是分隔线而不是列表项，两者前缀容易混淆。
    func testThematicBreakNotConfusedWithList() {
        let blocks = MarkdownBlockParser.parse("---\n")
        XCTAssertEqual(blocks[0].kind, .thematicBreak)
    }

    func testOrderedListNumberAndDelimiter() {
        let blocks = MarkdownBlockParser.parse("3. 三\n4) 四\n")
        XCTAssertEqual(blocks[0].kind, .orderedListItem(indent: 0, number: 3, delimiter: "."))
        XCTAssertEqual(blocks[1].kind, .orderedListItem(indent: 0, number: 4, delimiter: ")"))
    }

    func testQuoteDepth() {
        let blocks = MarkdownBlockParser.parse("> 一层\n>> 两层\n")
        XCTAssertEqual(blocks[0].kind, .quote(depth: 1))
        XCTAssertEqual(blocks[1].kind, .quote(depth: 2))
    }

    /// 围栏内的 Markdown 标记不能被当成块级结构解析。
    func testFenceContentIsNotParsed() {
        let blocks = MarkdownBlockParser.parse("```\n# 这不是标题\n- 这不是列表\n```\n")
        let fences = blocks.filter {
            if case .codeFence = $0.kind { return true }
            return false
        }
        XCTAssertEqual(fences.count, 1)
        XCTAssertTrue(blocks.allSatisfy { $0.kind != .heading(level: 1) })
    }

    func testFenceLanguage() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet x = 1\n```\n")
        XCTAssertEqual(blocks[0].kind, .codeFence(language: "swift", fence: "```"))

        let noLanguage = MarkdownBlockParser.parse("```\ncode\n```\n")
        XCTAssertEqual(noLanguage[0].kind, .codeFence(language: nil, fence: "```"))
    }

    func testFenceClosingRequiresMatchingRunAndWhitespaceOnlySuffix() {
        let text = "````\n```\n```swift\nstill code\n````   \n"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .codeFence(language: nil, fence: "````"))
        XCTAssertTrue(blocks[0].source.contains("```swift"))
        XCTAssertTrue(blocks[0].source.hasSuffix("````   "))

        let unclosed = MarkdownBlockParser.parse("```\n```swift\ntext\n")
        XCTAssertEqual(unclosed.count, 1)
        XCTAssertEqual(unclosed[0].source, "```\n```swift\ntext")
    }

    /// 段落遇到块级结构要断开，否则标题会被吞进段落。
    func testParagraphStopsAtBlockStart() {
        let blocks = MarkdownBlockParser.parse("正文一行\n## 标题\n")
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].source, "正文一行")
        XCTAssertEqual(blocks[1].kind, .heading(level: 2))
    }

    // MARK: - 行范围

    func testLineRangesAreContiguous() {
        let text = "# 标题\n\n正文\n\n- 项\n"
        let blocks = MarkdownBlockParser.parse(text)
        var expected = 0
        for block in blocks {
            XCTAssertEqual(block.lineRange.lowerBound, expected, "行范围不连续")
            expected = block.lineRange.upperBound
        }
        XCTAssertEqual(expected, MarkdownBlockParser.splitLines(text).count)
    }

    // MARK: - id 稳定

    /// 在文档开头插入内容后，原有块必须保留各自的 id。
    ///
    /// 不稳定的话撤销栈与未来协作协议的块引用都会失效。
    func testIDsAreReusedAcrossReparse() {
        let original = MarkdownBlockParser.parse("# 标题\n\n正文\n")
        // 只比较有内容的块：blank 块的 source 都是空串，彼此不可区分，
        // 它们的 id 复用没有意义也无法断言。
        let originalIDs = Dictionary(
            uniqueKeysWithValues: original
                .filter { !$0.source.isEmpty }
                .map { ("\($0.kind)\($0.source)", $0.id) }
        )
        XCTAssertFalse(originalIDs.isEmpty)

        let updated = MarkdownBlockParser.parse(
            "新增首行\n\n# 标题\n\n正文\n",
            previousBlocks: original
        )

        for block in updated where !block.source.isEmpty {
            if let expected = originalIDs["\(block.kind)\(block.source)"] {
                XCTAssertEqual(block.id, expected, "相同块的 id 应被复用：\(block.source)")
            }
        }
    }

    /// 内容相同的两个块不能抢同一个 id。
    func testDuplicateBlocksGetDistinctIDs() {
        let blocks = MarkdownBlockParser.parse("重复\n\n重复\n")
        let paragraphs = blocks.filter { $0.kind == .paragraph }
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertNotEqual(paragraphs[0].id, paragraphs[1].id)
    }

    // MARK: - 显示文本

    /// 编辑器显示的是去掉块级标记后的正文。
    func testDisplayTextStripsBlockMarkers() {
        let blocks = MarkdownBlockParser.parse("## 标题\n- 项\n3. 第三\n> 引用\n")
        XCTAssertEqual(blocks[0].displayText, "标题")
        XCTAssertEqual(blocks[1].displayText, "项")
        XCTAssertEqual(blocks[2].displayText, "第三")
        XCTAssertEqual(blocks[3].displayText, "引用")
    }

    /// 代码块正文不含围栏行。
    func testCodeFenceDisplayTextExcludesFence() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet x = 1\nlet y = 2\n```\n")
        XCTAssertEqual(blocks[0].displayText, "let x = 1\nlet y = 2")
    }

    func testBlankAndBreakDoNotAcceptCursor() {
        let blocks = MarkdownBlockParser.parse("正文\n\n---\n")
        XCTAssertTrue(blocks.contains { $0.kind == .blank && !$0.acceptsCursor })
        XCTAssertTrue(blocks.contains { $0.kind == .thematicBreak && !$0.acceptsCursor })
    }

    // MARK: - 真实文档

    /// 用仓库里的真实文档做往返验证，比构造样例更能暴露边界。
    func testRoundTripRealProjectDocuments() throws {
        let candidates = [
            "docs/MARKDOWN_EDITOR.md",
            "docs/agent/CODE_MAP.md",
            "docs/BENCHMARKS.md",
            "AGENTS.md",
            "README.md",
        ]
        var checked = 0
        for relative in candidates {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let blocks = MarkdownBlockParser.parse(text)
            let restored = MarkdownBlockParser.serialize(
                blocks,
                usesCRLF: MarkdownBlockParser.detectCRLF(text),
                hasTrailingNewline: MarkdownBlockParser.detectTrailingNewline(text)
            )
            XCTAssertEqual(restored, text, "真实文档往返不保真：\(relative)")
            checked += 1
        }
        // 至少验证到一个文件，否则这个测试等于没跑
        XCTAssertGreaterThan(checked, 0, "未找到任何真实文档，测试无效")
    }
}
