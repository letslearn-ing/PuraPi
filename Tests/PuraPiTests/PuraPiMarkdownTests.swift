import Foundation
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownTests: XCTestCase {
    func testMarkdownParserPreservesBlockStructure() {
        let blocks = PuraPiMarkdownParser.parse("""
        # 标题

        第一段，包含 **强调**。

        - 项目一
        - 项目二

        ```swift
        print("hello")
        ```
        """)

        XCTAssertEqual(blocks.count, 4)
        guard case .heading(level: 1, text: "标题") = blocks[0].kind else {
            return XCTFail("Expected heading block")
        }
        guard case .paragraph(let paragraph, continuation: false) = blocks[1].kind else {
            return XCTFail("Expected paragraph block")
        }
        XCTAssertEqual(paragraph, "第一段，包含 **强调**。")
        guard case .unorderedList(let items) = blocks[2].kind else {
            return XCTFail("Expected list block")
        }
        XCTAssertEqual(items, ["项目一", "项目二"])
        guard case .code(language: "swift", text: let code) = blocks[3].kind else {
            return XCTFail("Expected code block")
        }
        XCTAssertEqual(code, "print(\"hello\")")
    }

    func testMarkdownParserChunksVeryLongParagraphWithoutDataLoss() {
        let source = String(repeating: "中文长段落。", count: 600)
        let blocks = PuraPiMarkdownParser.parse(source)
        let paragraphs = blocks.compactMap { block -> String? in
            guard case .paragraph(let text, continuation: _) = block.kind else { return nil }
            return text
        }
        XCTAssertGreaterThan(paragraphs.count, 1)
        XCTAssertEqual(paragraphs.joined(), source)
        XCTAssertLessThanOrEqual(paragraphs.map(\.count).max() ?? 0, 1_600)
    }

    /// 完成态必须使用块级排版，与流式期间一致。
    ///
    /// 旧实现把整条消息交给 `AttributedString(markdown:)`，它不保留段落
    /// 空行，导致多段被拼成一团（如「标题重点…第二项print」）、段落与
    /// 代码块之间丢空格，代码块也拿不到背景与边框。
    func testCompletedMessageUsesStructuredBlocksInsteadOfFlattenedText() {
        let source = """
        ## 标题

        **重点**、`代码` 和 [链接](https://example.com)。

        - 第一项
        - 第二项

        ```swift
        print(\"ok\")
        ```
        """

        let result = PuraPiMarkdownRenderer.render(source)

        // 不再使用展平的整段 AttributedString。
        XCTAssertNil(result.attributed)

        let blocks = try? XCTUnwrap(result.fallbackBlocks)
        XCTAssertEqual(blocks?.count, 4)

        guard case .heading(let level, let heading) = blocks?[0].kind else {
            return XCTFail("期望标题块")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(heading, "标题")

        guard case .paragraph(let paragraph, _) = blocks?[1].kind else {
            return XCTFail("期望段落块")
        }
        // 行内标记保留在源文中，由 PuraPiMarkdownInlineRenderer 在块内渲染。
        XCTAssertTrue(paragraph.contains("重点"))
        XCTAssertTrue(paragraph.contains("链接"))

        guard case .unorderedList(let items) = blocks?[2].kind else {
            return XCTFail("期望列表块")
        }
        XCTAssertEqual(items, ["第一项", "第二项"])

        guard case .code(let language, let code) = blocks?[3].kind else {
            return XCTFail("期望代码块")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "print(\"ok\")")
    }

    /// 行内渲染必须去掉标记并保留链接。
    func testInlineRendererStripsMarkersAndKeepsLink() {
        let value = PuraPiMarkdownInlineRenderer.render(
            "**重点**、`代码` 和 [链接](https://example.com)。"
        )
        let plain = String(value.characters)

        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertFalse(plain.contains("]("))
        XCTAssertTrue(plain.contains("重点"))
        XCTAssertTrue(value.runs.contains { $0.link != nil })
    }

    func testMarkdownParserSupportsTildeFencesAndSetextHeadings() {
        let blocks = PuraPiMarkdownParser.parse("""
        标题
        ====

        ~~~python
        print(1)
        ~~~
        """)
        XCTAssertEqual(blocks.count, 2)
        guard case .heading(level: 1, text: "标题") = blocks[0].kind else {
            return XCTFail("Expected setext heading")
        }
        guard case .code(language: "python", text: "print(1)") = blocks[1].kind else {
            return XCTFail("Expected tilde code fence")
        }
    }

    func testUserMarkdownMapsTablesAndFencesToStructuredBlocks() {
        let source = """
        ### Step 2

        | 资产 | 搜索路径 |
        | --- | --- |
        | **Logo** | `<brand>.com/brand` |

        ```swift
        let value = 1
        ```
        """
        let blocks = PuraPiMarkdownParser.parse(source)
        XCTAssertTrue(blocks.contains {
            if case .table(let headers, let rows) = $0.kind {
                return headers == ["资产", "搜索路径"]
                    && rows == [["**Logo**", "`<brand>.com/brand`"]]
            }
            return false
        })
        XCTAssertTrue(blocks.contains {
            if case .code(language: "swift", text: "let value = 1") = $0.kind { return true }
            return false
        })
        XCTAssertNotNil(PuraPiMarkdownRenderer.render(source).fallbackBlocks)
    }

    func testMarkdownPendingPreviewRemovesBlockAndInlineMarkers() {
        let source = """
        ## Blocked

        - **bold** and `code`
        1. [link](https://example.com)
        > quote

        ```bash
        echo ok
        ```
        """
        let preview = PuraPiMarkdownSanitizer.inlinePreview(source)
        XCTAssertFalse(preview.contains("##"))
        XCTAssertFalse(preview.contains("**"))
        XCTAssertFalse(preview.contains("```"))
        XCTAssertTrue(preview.contains("Blocked"))
        XCTAssertTrue(preview.contains("• bold and code"))
        XCTAssertTrue(preview.contains("1. link"))
        XCTAssertTrue(preview.contains("quote"))
        XCTAssertTrue(preview.contains("echo ok"))
    }

    func testIncrementalMarkdownCommitsClosedBlocksAndKeepsTailContext() {
        var state = PuraPiIncrementalMarkdownState()
        state.update("# 标题\n\n这是 **第一")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 1)
        XCTAssertEqual(state.snapshot.tailText, "这是 **第一")

        state.update("# 标题\n\n这是 **第一段**。\n\n```swift\nlet value = 1")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 2)
        XCTAssertTrue(state.snapshot.tailText.contains("```swift"))
        XCTAssertTrue(state.snapshot.tailText.contains("let value = 1"))

        state.update("# 标题\n\n这是 **第一段**。\n\n```swift\nlet value = 1\n```\n\n结尾")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 3)
        XCTAssertEqual(state.snapshot.stableBlocks.compactMap { block -> String? in
            guard case .code(_, let text) = block.kind else { return nil }
            return text
        }, ["let value = 1"])
        XCTAssertEqual(
            state.snapshot.tailText.trimmingCharacters(in: .newlines),
            "结尾"
        )
    }

    func testIncrementalMarkdownHandlesDeltaSplitInlineMarker() {
        var state = PuraPiIncrementalMarkdownState()
        state.update("说明：**重")
        XCTAssertEqual(state.snapshot.tailText, "说明：**重")
        state.update("说明：**重点** 和 `代码`")
        XCTAssertEqual(state.snapshot.tailText, "说明：**重点** 和 `代码`")
        XCTAssertEqual(
            PuraPiMarkdownSanitizer.inlinePreview(state.snapshot.tailText),
            "说明：重点 和 代码"
        )
    }

    /// 逐字符馈入，模拟真实的细粒度 `text_delta`。
    private func streamCharByChar(_ text: String) -> PuraPiIncrementalMarkdownState {
        var state = PuraPiIncrementalMarkdownState()
        var accumulated = ""
        for character in text {
            accumulated.append(character)
            state.update(accumulated)
        }
        return state
    }

    /// 普通正文逐行提交：每写完一行就固定下来，不再整段懋到空行。
    func testIncrementalMarkdownCommitsParagraphLineByLine() {
        var state = PuraPiIncrementalMarkdownState()

        state.update("第一行。\n")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 1)

        state.update("第一行。\n第二行。\n")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 2)

        state.update("第一行。\n第二行。\n第三行")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 2)
        XCTAssertEqual(state.snapshot.tailText, "第三行")
    }

    /// 表格必须整组提交；逐行拆开会把 `|---|---|` 当普通段落裸露给用户。
    func testIncrementalMarkdownCommitsTableAsSingleBlock() {
        let state = streamCharByChar("| A | B |\n|---|---|\n| 1 | 2 |\n\n")

        XCTAssertEqual(state.snapshot.stableBlocks.count, 1)
        guard case .table(let headers, let rows) = state.snapshot.stableBlocks.first?.kind else {
            return XCTFail("期望表格块，实际为 \(String(describing: state.snapshot.stableBlocks.first?.kind))")
        }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    /// 列表整组提交，不能被拆成多个单项列表。
    func testIncrementalMarkdownCommitsListAsSingleBlock() {
        let state = streamCharByChar("- 甲\n- 乙\n- 丙\n\n")

        XCTAssertEqual(state.snapshot.stableBlocks.count, 1)
        guard case .unorderedList(let items) = state.snapshot.stableBlocks.first?.kind else {
            return XCTFail("期望无序列表块")
        }
        XCTAssertEqual(items, ["甲", "乙", "丙"])
    }

    /// 引用与代码围栏在逐字流式下仍保持完整结构。
    func testIncrementalMarkdownKeepsQuoteAndFenceIntactWhileStreaming() {
        let state = streamCharByChar("> 引用一\n> 引用二\n\n```swift\nlet a = 1\n```\n\n")

        XCTAssertEqual(state.snapshot.stableBlocks.count, 2)
        guard case .quote(let quoted) = state.snapshot.stableBlocks.first?.kind else {
            return XCTFail("期望引用块")
        }
        XCTAssertTrue(quoted.contains("引用一"))
        XCTAssertTrue(quoted.contains("引用二"))

        guard case .code(let language, let code) = state.snapshot.stableBlocks.last?.kind else {
            return XCTFail("期望代码块")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1")
    }

    /// 表格首行刚收到换行、下一行只有一个 `|` 时，不能提交首行。
    func testIncrementalMarkdownDoesNotCommitPartialTableRow() {
        var state = PuraPiIncrementalMarkdownState()

        state.update("| A | B |\n")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 0)

        state.update("| A | B |\n|")
        XCTAssertEqual(state.snapshot.stableBlocks.count, 0)
        XCTAssertTrue(state.snapshot.tailText.contains("| A | B |"))
    }

    /// 回合结束时的完整解析仍然是排版权威，逐行提交不能丢数据。
    func testIncrementalMarkdownFinishMatchesFullParse() {
        let source = "# 标题\n\n正文一。\n正文二。\n\n- 甲\n- 乙\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        var state = streamCharByChar(source)
        state.finish(source)

        XCTAssertEqual(
            state.snapshot.stableBlocks.map(\.kind),
            PuraPiMarkdownParser.parse(source).map(\.kind)
        )
        XCTAssertTrue(state.snapshot.tailText.isEmpty)
    }

    /// 真实截图回归：完成态曾把多段拼成一团、段落与代码块之间丢空格
    /// （「跑起来npx」）、代码块拿不到背景与边框。
    func testCompletedMessageKeepsParagraphAndCodeBoundaries() {
        let source = """
        **DeepSeek Harness (dsh)**：DeepSeek AI 开源的 agent harness。核心特征**一切皆插件**。

        **profile + bundle 分层组装**：`dsh-base` 打底。

        跑起来

        ```bash
        npx @deepseek-ai/dsh web
        ```

        仓库规模不小：`packages/` 下按能力域分了三十多个工作区。
        """

        let blocks = try? XCTUnwrap(PuraPiMarkdownRenderer.render(source).fallbackBlocks)
        XCTAssertEqual(blocks?.count, 5)

        let paragraphs = (blocks ?? []).compactMap { block -> String? in
            if case .paragraph(let text, _) = block.kind { return text }
            return nil
        }
        XCTAssertEqual(paragraphs.count, 4)
        // 段落之间不能粘连。
        XCTAssertTrue(paragraphs.contains { $0.trimmingCharacters(in: .whitespaces) == "跑起来" })
        XCTAssertFalse(paragraphs.contains { $0.contains("跑起来npx") })

        // 代码块必须独立，才能拿到圆角背景与边框。
        let code = (blocks ?? []).compactMap { block -> String? in
            if case .code(_, let text) = block.kind { return text }
            return nil
        }
        XCTAssertEqual(code, ["npx @deepseek-ai/dsh web"])
    }
}
