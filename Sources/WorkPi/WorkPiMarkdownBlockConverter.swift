import Foundation
import PiDomain

/// 显示文本 ↔ 源码的组合，以及行首标记触发的块类型转换。
///
/// 编辑器显示的是去掉块级标记的正文（`## 标题` 显示为 `标题`），因此写回时
/// 必须补上标记，否则保存后标题会退化成普通段落。
enum WorkPiMarkdownBlockConverter {
    /// 把显示文本组合回带标记的源码。
    static func composeSource(kind: MarkdownBlock.Kind, displayText: String) -> String {
        switch kind {
        case .heading(let level):
            return String(repeating: "#", count: level) + " " + displayText

        case .unorderedListItem(let indent, let marker):
            return String(repeating: " ", count: indent) + "\(marker) " + displayText

        case .orderedListItem(let indent, let number, let delimiter):
            return String(repeating: " ", count: indent) + "\(number)\(delimiter) " + displayText

        case .quote(let depth):
            let prefix = String(repeating: "> ", count: depth)
            return displayText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { prefix + $0 }
                .joined(separator: "\n")

        case .codeFence(let language, let fence):
            // 围栏由块承载，正文是围栏之间的内容
            let opening = fence + (language ?? "")
            return ([opening] + displayText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) + [fence])
                .joined(separator: "\n")

        case .paragraph, .table, .blank, .thematicBreak:
            return displayText
        }
    }

    /// 行首输入 Markdown 标记时转换块类型。
    ///
    /// 例如在段落开头输入 `## ` 应变成二级标题，且标记本身不留在正文里。
    /// 返回 nil 表示不需要转换。
    static func convert(
        block: MarkdownBlock,
        displayText: String
    ) -> (kind: MarkdownBlock.Kind, source: String)? {
        // 代码块内的内容按原文处理，不做任何转换——
        // 代码里出现 `# 注释` 或 `- 列表` 是完全正常的。
        if case .codeFence = block.kind { return nil }

        guard let converted = detectMarker(displayText) else { return nil }
        // 类型没变就不算转换，避免每次输入都重建块
        guard converted.kind != block.kind else { return nil }

        return (
            converted.kind,
            composeSource(kind: converted.kind, displayText: converted.remainder)
        )
    }

    /// 识别行首标记，返回目标类型与剩余正文。
    private static func detectMarker(
        _ text: String
    ) -> (kind: MarkdownBlock.Kind, remainder: String)? {
        // 标题：# 到 ###### 且必须跟空格
        var hashes = 0
        var index = text.startIndex
        while index < text.endIndex, text[index] == "#", hashes < 6 {
            hashes += 1
            index = text.index(after: index)
        }
        if hashes > 0, index < text.endIndex, text[index] == " " {
            return (.heading(level: hashes), String(text[text.index(after: index)...]))
        }

        // 无序列表
        if let first = text.first, "-*+".contains(first),
           text.dropFirst().first == " " {
            return (
                .unorderedListItem(indent: 0, marker: first),
                String(text.dropFirst(2))
            )
        }

        // 有序列表
        var digits = ""
        var cursor = text.startIndex
        while cursor < text.endIndex, text[cursor].isNumber {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        if !digits.isEmpty, let number = Int(digits), cursor < text.endIndex,
           text[cursor] == "." || text[cursor] == ")" {
            let delimiter = text[cursor]
            let afterDelimiter = text.index(after: cursor)
            if afterDelimiter < text.endIndex, text[afterDelimiter] == " " {
                return (
                    .orderedListItem(indent: 0, number: number, delimiter: delimiter),
                    String(text[text.index(after: afterDelimiter)...])
                )
            }
        }

        // 引用：连续的 `> ` 前缀表示嵌套层级。
        var quoteDepth = 0
        var quoteRemainder = Substring(text)
        while quoteRemainder.hasPrefix(">") {
            quoteDepth += 1
            quoteRemainder = quoteRemainder.dropFirst()
            if quoteRemainder.hasPrefix(" ") {
                quoteRemainder = quoteRemainder.dropFirst()
            }
        }
        if quoteDepth > 0 {
            return (.quote(depth: quoteDepth), String(quoteRemainder))
        }

        // 围栏代码块：输入 ``` 即转换，语言留空待用户补
        if text.hasPrefix("```") {
            let language = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return (
                .codeFence(language: language.isEmpty ? nil : language, fence: "```"),
                ""
            )
        }

        return nil
    }

    /// 该类型的块与前一块之间是否需要空行分隔。
    ///
    /// 段落、标题、代码块在 Markdown 里必须用空行断开，否则会被当成续行。
    /// 列表项与引用是连续结构，插入空行反而会把列表断成两截。
    /// 空段落中的斜杠插入命令。未知命令继续作为普通文本。
    static func slashInsertion(
        _ text: String
    ) -> (kind: MarkdownBlock.Kind, source: String)? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "/table", "/表格":
            return (
                .table,
                "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |"
            )
        case "/code", "/代码":
            let kind = MarkdownBlock.Kind.codeFence(language: nil, fence: "```")
            return (kind, composeSource(kind: kind, displayText: ""))
        case "/quote", "/引用":
            let kind = MarkdownBlock.Kind.quote(depth: 1)
            return (kind, composeSource(kind: kind, displayText: ""))
        case "/bullet", "/list", "/列表":
            let kind = MarkdownBlock.Kind.unorderedListItem(indent: 0, marker: "-")
            return (kind, composeSource(kind: kind, displayText: ""))
        default:
            return nil
        }
    }

    static func requiresBlankSeparator(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .paragraph, .heading, .codeFence, .table, .thematicBreak:
            return true
        case .unorderedListItem, .orderedListItem, .quote, .blank:
            return false
        }
    }

    /// 在某类块中回车后，新块应是什么类型。
    ///
    /// 列表项要延续列表（有序列表递增编号），其余回到段落——
    /// 在标题后回车继续写标题不符合直觉。
    static func continuationKind(for kind: MarkdownBlock.Kind) -> MarkdownBlock.Kind {
        switch kind {
        case .unorderedListItem(let indent, let marker):
            return .unorderedListItem(indent: indent, marker: marker)
        case .orderedListItem(let indent, let number, let delimiter):
            return .orderedListItem(indent: indent, number: number + 1, delimiter: delimiter)
        case .quote(let depth):
            return .quote(depth: depth)
        case .heading, .paragraph, .codeFence, .table, .blank, .thematicBreak:
            return .paragraph
        }
    }
}
