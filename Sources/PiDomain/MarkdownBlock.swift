import Foundation

/// 编辑器中的一个 Markdown 块。
///
/// 与只读渲染用的块（`WorkPiMarkdownBlock`）不同，这里必须携带**源码文本**与
/// **源码行范围**，并记录块内部及块末的原始行尾：写回时未触碰的源码字节和行尾
/// 应尽量保留。否则用户只改一行也会重写整个文件，既污染 git diff，也会让 Agent
/// 的 `edit` 工具失效（它依赖 `oldText` 精确匹配）。
public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case unorderedListItem(indent: Int, marker: Character)
        case orderedListItem(indent: Int, number: Int, delimiter: Character)
        case quote(depth: Int)
        case codeFence(language: String?, fence: String)
        case thematicBreak
        case table
        /// 空行组。单独成块，才能在往返中保持原有空行数。
        case blank
    }

    /// 稳定身份。编辑不改变它，重解析时按内容与位置匹配复用。
    ///
    /// 稳定是撤销重做与未来协作协议的前提：协议要能引用「某个块」而不依赖行号，
    /// 否则在文档开头插入一块就会让后面所有引用失效。
    public let id: UUID
    public var kind: Kind
    /// 该块的原始 Markdown 源码，不含尾随换行。
    public var source: String
    /// 在文件中的行索引范围（0-based，半开区间）。
    public var lineRange: Range<Int>
    /// `source` 内部各行之间的原始行尾。源码正文统一用 LF 保存，避免把 CRLF
    /// 混入显示文本；序列化时再按这里的记录还原。
    public var internalLineEndings: [String]
    /// 该块最后一行之后的原始行尾；为 nil 表示块到达文件末尾且没有尾随换行。
    public var trailingLineEnding: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        source: String,
        lineRange: Range<Int>,
        internalLineEndings: [String] = [],
        trailingLineEnding: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.lineRange = lineRange
        self.internalLineEndings = internalLineEndings
        self.trailingLineEnding = trailingLineEnding
    }

    /// 块的行数。
    public var lineCount: Int { lineRange.count }

    /// 是否为可编辑的正文块。空行组与分隔线不接受光标。
    public var acceptsCursor: Bool {
        switch kind {
        case .blank, .thematicBreak: return false
        default: return true
        }
    }

    /// 去掉块级标记后的正文，用于编辑器显示。
    ///
    /// 例如 `## 标题` 显示为 `标题`，`- 项` 显示为 `项`。标记由块类型承载，
    /// 用户看到的是渲染后的样子，这是所见即所得的基础。
    public var displayText: String {
        switch kind {
        case .heading(let level):
            return String(source.dropFirst(level + 1))
        case .unorderedListItem(let indent, _):
            let stripped = source.dropFirst(indent + 2)
            return String(stripped)
        case .orderedListItem(let indent, let number, _):
            // "1. " 的前缀长度随数字位数变化
            let prefixLength = indent + String(number).count + 2
            return String(source.dropFirst(min(prefixLength, source.count)))
        case .quote(let depth):
            let prefixLength = quotePrefixLength(depth: depth)
            let lines = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            return lines.map { line in
                String(line.dropFirst(min(prefixLength, line.count)))
            }.joined(separator: "\n")
        case .codeFence:
            // 代码块正文是围栏之间的内容，不含围栏本身
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > 1 else { return "" }
            let body = lines.dropFirst().dropLast(isClosedFence ? 1 : 0)
            return body.joined(separator: "\n")
        case .paragraph, .table, .blank, .thematicBreak:
            return source
        }
    }

    private func quotePrefixLength(depth: Int) -> Int {
        var remainder = Substring(source)
        var consumed = 0
        for _ in 0..<depth {
            if remainder.hasPrefix("> ") {
                remainder = remainder.dropFirst(2)
                consumed += 2
            } else if remainder.hasPrefix(">") {
                remainder = remainder.dropFirst()
                consumed += 1
            }
        }
        return consumed
    }

    /// 围栏代码块是否有闭合行。流式写入或文件末尾可能未闭合。
    public var isClosedFence: Bool {
        guard case .codeFence(_, let fence) = kind else { return false }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let last = lines.last else { return false }
        let line = String(last)
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return false }
        let rest = line.dropFirst(leadingSpaces)
        guard let character = fence.first, rest.first == character else { return false }
        let run = rest.prefix(while: { $0 == character })
        guard run.count >= fence.count else { return false }
        return rest.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// 一次块级变更的语义描述。
///
/// 所有编辑最终都要表达为它的序列——这是未来人机协作协议的**变更单元**。
/// UI 不得绕过它直接写文件，否则协作机制无法挂上变更广播。
/// 未来要支持思维导图、Excel、HTML，因此这里只描述「哪个块、怎么变」，
/// 不掺入 Markdown 特有的语法细节。
public enum MarkdownBlockEdit: Equatable, Sendable {
    /// 块内文本改变。
    case update(id: UUID, source: String)
    /// 块类型改变，例如段落变标题。
    case retype(id: UUID, kind: MarkdownBlock.Kind, source: String)
    /// 在指定块之后插入新块。`after` 为 nil 表示插入到文档开头。
    case insert(block: MarkdownBlock, after: UUID?)
    case remove(id: UUID)
    /// 两块合并，保留 `into` 的身份。
    case merge(into: UUID, from: UUID, source: String)
    /// 一块拆成两块。
    case split(id: UUID, firstSource: String, second: MarkdownBlock)
}
