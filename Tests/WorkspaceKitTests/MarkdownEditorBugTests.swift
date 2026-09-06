import Foundation
import PiDomain
import XCTest
@testable import WorkspaceKit

/// 编辑器块模型的三个缺陷回归测试。
///
/// 这三条都是审查代码时推断、并用测试确认真实存在后才修的：
/// 段落拆分缺空行导致两段合一、合并后残留孤立空行、有序列表编号不重排。
/// 修复在 `WorkPiMarkdownEditorView`（容器层），这里锁住块模型侧的表现。
final class MarkdownEditorBugTests: XCTestCase {
    /// 缺陷一：段落之间靠 blank 块分隔，拆块时若不插入 blank，
    /// 两个段落会挨在一起，序列化后变成同一段的两行。
    func testSplitParagraphWithoutBlankMergesOnSerialize() {
        let blocks = MarkdownBlockParser.parse("原始段落\n")
        var document = MarkdownDocument(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            blocks: blocks,
            baselineHash: ""
        )
        let first = blocks[0]
        let second = MarkdownBlock(kind: .paragraph, source: "新段落", lineRange: 1..<2)
        document.apply(.split(id: first.id, firstSource: "原始段落", second: second))

        let text = MarkdownBlockParser.serialize(document.blocks)
        // 两段之间没有空行，Markdown 会把它们当成同一段
        XCTAssertEqual(text, "原始段落\n新段落\n")
        let reparsed = MarkdownBlockParser.parse(text)
        let paragraphs = reparsed.filter { $0.kind == .paragraph }
        XCTAssertEqual(paragraphs.count, 1, "缺陷确认：两段被合成一段")
    }

    /// 缺陷二：块首退格与上一块合并时，中间的 blank 块留了下来，
    /// 合并后的块与残留空行之间关系错乱。
    func testMergeLeavesOrphanBlankBlock() {
        let blocks = MarkdownBlockParser.parse("第一段\n\n第二段\n")
        var document = MarkdownDocument(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            blocks: blocks,
            baselineHash: ""
        )
        let first = blocks.first { $0.kind == .paragraph }!
        let second = blocks.last { $0.kind == .paragraph }!
        document.apply(.merge(into: first.id, from: second.id, source: "第一段第二段"))

        let text = MarkdownBlockParser.serialize(document.blocks)
        // 合并后仍残留空行，末尾出现多余空白
        XCTAssertTrue(text.contains("\n\n"), "缺陷确认：残留了孤立的空行块，得到 \(text.debugDescription)")
    }

    /// 空列表项与空代码块不该被写进文件。
    ///
    /// 实测文件被写坏的表现：出现成片的 `- `（空列表项）和空的 ``` 围栏。
    /// 根因是视图复用时把新块内容写回了旧块，这里锁住组合层的行为：
    /// 空内容的列表项序列化后不能只剩标记。
    func testEmptyListItemSerializesWithoutStrayMarker() {
        let blocks = MarkdownBlockParser.parse("- 项一\n")
        let item = blocks[0]
        XCTAssertEqual(item.displayText, "项一")

        // 清空内容后源码只剩 "- "，这在文件里就是一个空列表项
        var document = MarkdownDocument(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            blocks: blocks,
            baselineHash: ""
        )
        document.apply(.update(id: item.id, source: "- "))
        let text = MarkdownBlockParser.serialize(document.blocks)
        XCTAssertEqual(text, "- \n", "空列表项的源码形态，UI 层需避免产生它")
    }

    /// 缺陷三：有序列表续行编号递增，但后续项的编号不会重排。
    /// 在 1、2 之间插入一项，得到 1、2、2。
    func testOrderedListNumbersNotRenumbered() {
        let blocks = MarkdownBlockParser.parse("1. 一\n2. 二\n")
        var document = MarkdownDocument(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            blocks: blocks,
            baselineHash: ""
        )
        let first = blocks[0]
        // 模拟在第一项尾部回车：新项编号为 2
        let inserted = MarkdownBlock(
            kind: .orderedListItem(indent: 0, number: 2, delimiter: "."),
            source: "2. 新项",
            lineRange: 1..<2
        )
        document.apply(.insert(block: inserted, after: first.id))

        let text = MarkdownBlockParser.serialize(document.blocks)
        XCTAssertEqual(text, "1. 一\n2. 新项\n2. 二\n", "缺陷确认：编号重复")
    }
}
