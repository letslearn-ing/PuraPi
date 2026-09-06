import Foundation
import PiDomain

/// 源码 ↔ 块序列的双向映射。
///
/// 与只读渲染用的解析器（`PuraPiMarkdownParser`）不同，这里的硬要求是**往返保真**：
/// `serialize(parse(text)) == text` 必须逐字节成立。原因有两个——
/// 用户只改一行时不该重写整个文件（污染 git diff），以及 Agent 的 `edit` 工具
/// 依赖 `oldText` 精确匹配，我们重排格式会让它失效。
///
/// 因此空行、行尾风格、列表符号、缩进宽度全部原样保留，不做任何规范化。
public enum MarkdownBlockParser {
    private struct SourceLine {
        let content: String
        let ending: String?
    }
    /// 把源码切成块序列。
    ///
    /// `previousBlocks` 用于复用稳定 id：重解析时按「类型 + 内容」匹配旧块，
    /// 匹配上就沿用它的 id。不这样做的话，在文档开头插入一块会让后面所有块
    /// 的 id 全变，撤销栈和未来协作协议的块引用都会失效。
    public static func parse(
        _ text: String,
        previousBlocks: [MarkdownBlock] = []
    ) -> [MarkdownBlock] {
        let sourceLines = splitSourceLines(text)
        let lines = sourceLines.map(\.content)
        var blocks: [MarkdownBlock] = []
        var index = 0
        var reusePool = IDReusePool(blocks: previousBlocks)

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // 连续空行合并为一个 blank 块，保留原有数量
                let start = index
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                append(
                    &blocks,
                    kind: .blank,
                    lines: Array(lines[start..<index]),
                    sourceLines: sourceLines,
                    range: start..<index,
                    pool: &reusePool
                )
                continue
            }

            if let fence = fenceMarker(line) {
                // 围栏代码块：吃到闭合行或文件尾
                let start = index
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    index += 1
                    // A closing fence is deliberately stricter than an opening
                    // marker.  A line such as ```swift, ```` or ``` trailing
                    // text is code, not the end of the block.  In particular,
                    // using `hasPrefix` here used to make prose containing a
                    // longer fence or a language-looking suffix disappear from
                    // the code block.
                    if isFenceClosing(candidate, fence: fence) { break }
                }
                let language = fenceLanguage(line)
                append(
                    &blocks,
                    kind: .codeFence(language: language, fence: fence),
                    lines: Array(lines[start..<index]),
                    sourceLines: sourceLines,
                    range: start..<index,
                    pool: &reusePool
                )
                continue
            }

            if isThematicBreak(line) {
                append(
                    &blocks,
                    kind: .thematicBreak,
                    lines: [line],
                    sourceLines: sourceLines,
                    range: index..<(index + 1),
                    pool: &reusePool
                )
                index += 1
                continue
            }

            if let level = headingLevel(line) {
                append(
                    &blocks,
                    kind: .heading(level: level),
                    lines: [line],
                    sourceLines: sourceLines,
                    range: index..<(index + 1),
                    pool: &reusePool
                )
                index += 1
                continue
            }

            if let marker = unorderedMarker(line) {
                append(
                    &blocks,
                    kind: .unorderedListItem(indent: marker.indent, marker: marker.character),
                    lines: [line],
                    sourceLines: sourceLines,
                    range: index..<(index + 1),
                    pool: &reusePool
                )
                index += 1
                continue
            }

            if let ordered = orderedMarker(line) {
                append(
                    &blocks,
                    kind: .orderedListItem(
                        indent: ordered.indent,
                        number: ordered.number,
                        delimiter: ordered.delimiter
                    ),
                    lines: [line],
                    sourceLines: sourceLines,
                    range: index..<(index + 1),
                    pool: &reusePool
                )
                index += 1
                continue
            }

            if let depth = quoteDepth(line) {
                append(
                    &blocks,
                    kind: .quote(depth: depth),
                    lines: [line],
                    sourceLines: sourceLines,
                    range: index..<(index + 1),
                    pool: &reusePool
                )
                index += 1
                continue
            }

            if isTableRow(line), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                let start = index
                index += 2
                while index < lines.count, isTableRow(lines[index]) {
                    index += 1
                }
                append(
                    &blocks,
                    kind: .table,
                    lines: Array(lines[start..<index]),
                    sourceLines: sourceLines,
                    range: start..<index,
                    pool: &reusePool
                )
                continue
            }

            // 段落：吃到空行或下一个块级结构
            let start = index
            while index < lines.count {
                let candidate = lines[index]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if index > start, startsNewBlock(candidate, next: index + 1 < lines.count ? lines[index + 1] : nil) {
                    break
                }
                index += 1
            }
            append(
                &blocks,
                kind: .paragraph,
                lines: Array(lines[start..<index]),
                sourceLines: sourceLines,
                range: start..<index,
                pool: &reusePool
            )
        }

        return blocks
    }

    /// 把块序列还原为源码。必须与 `parse` 严格互逆。
    /// 解析得到的块优先使用自身记录的逐行行尾；调用方传入的风格只作为
    /// 手工构造块或新增行的 fallback。
    public static func serialize(
        _ blocks: [MarkdownBlock],
        usesCRLF: Bool = false,
        hasTrailingNewline: Bool = true
    ) -> String {
        let separator = usesCRLF
            ? "\r\n"
            : fallbackLineEnding(for: blocks)
        var text = ""
        for (index, block) in blocks.enumerated() {
            text += renderedSource(for: block, fallbackLineEnding: separator)
            // 旧的/手工构造块没有行尾元数据时，继续使用调用方指定的默认风格。
            if block.trailingLineEnding == nil, index < blocks.count - 1 {
                text += separator
            }
        }
        if hasTrailingNewline, !text.isEmpty, !endsWithLineBreak(text) {
            text += separator
        }
        return text
    }

    /// 探测默认行尾风格。已解析块会单独记录每一行的原始行尾；此值只用于
    /// 新增源码行或手工构造块的 fallback。
    public static func detectCRLF(_ text: String) -> Bool {
        text.contains("\r\n")
    }

    public static func detectTrailingNewline(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return last.value == 0x0A || last.value == 0x0D
    }

    // MARK: - 行切分

    /// 按行切分，剥离行尾换行但保留空行。
    ///
    /// 不能用 `components(separatedBy: .newlines)`：它会把 `U+2028` 之类也当成
    /// 换行，而那些字符在 Markdown 正文里是合法内容。
    static func splitLines(_ text: String) -> [String] {
        splitSourceLines(text).map(\.content)
    }

    /// 保留每一行的真实行尾，供块级序列化还原混合 CRLF/LF。
    private static func splitSourceLines(_ text: String) -> [SourceLine] {
        guard !text.isEmpty else { return [] }
        var result: [SourceLine] = []
        var content = ""
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            switch scalar.value {
            case 0x0A: // LF
                result.append(SourceLine(content: content, ending: "\n"))
                content.removeAll(keepingCapacity: true)
                index = text.unicodeScalars.index(after: index)
            case 0x0D: // CR 或 CRLF
                let next = text.unicodeScalars.index(after: index)
                if next < text.unicodeScalars.endIndex,
                   text.unicodeScalars[next].value == 0x0A {
                    result.append(SourceLine(content: content, ending: "\r\n"))
                    index = text.unicodeScalars.index(after: next)
                } else {
                    result.append(SourceLine(content: content, ending: "\r"))
                    index = next
                }
                content.removeAll(keepingCapacity: true)
            default:
                content.unicodeScalars.append(scalar)
                index = text.unicodeScalars.index(after: index)
            }
        }

        if !content.isEmpty {
            result.append(SourceLine(content: content, ending: nil))
        }
        return result
    }

    private static func renderedSource(
        for block: MarkdownBlock,
        fallbackLineEnding: String
    ) -> String {
        let contents = sourceContents(block.source)
        var result = ""
        for (index, content) in contents.enumerated() {
            result += content
            guard index < contents.count - 1 else { continue }
            let ending = block.internalLineEndings.indices.contains(index)
                ? block.internalLineEndings[index]
                : fallbackLineEnding
            result += ending
        }
        if let trailingLineEnding = block.trailingLineEnding {
            result += trailingLineEnding
        }
        return result
    }

    private static func sourceContents(_ source: String) -> [String] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [""] }
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func endsWithLineBreak(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return last.value == 0x0A || last.value == 0x0D
    }

    private static func fallbackLineEnding(for blocks: [MarkdownBlock]) -> String {
        let endings = blocks.flatMap { block in
            block.internalLineEndings
                + (block.trailingLineEnding.map { [$0] } ?? [])
        }
        // `usesCRLF` 只有一个 Bool，无法单独表达 CR-only 文件；如果所有已知
        // 行尾都是 CR，新增行也沿用 CR，否则使用常规 LF。
        if !endings.isEmpty, endings.allSatisfy({ $0 == "\r" }) {
            return "\r"
        }
        return "\n"
    }

    // MARK: - 块级识别

    static func headingLevel(_ line: String) -> Int? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        return level
    }

    static func fenceMarker(_ line: String) -> String? {
        // CommonMark permits at most three leading spaces and requires a run of
        // at least three identical fence characters.  Keep the complete run in
        // the kind so a four-backtick opener cannot be closed by three.
        let spaces = leadingSpaces(line)
        guard spaces <= 3 else { return nil }
        let rest = line.dropFirst(spaces)
        guard let character = rest.first, character == "`" || character == "~" else {
            return nil
        }
        let run = rest.prefix(while: { $0 == character })
        guard run.count >= 3 else { return nil }
        return String(run)
    }

    static func fenceLanguage(_ line: String) -> String? {
        guard let marker = fenceMarker(line) else { return nil }
        let start = line.index(line.startIndex, offsetBy: leadingSpaces(line) + marker.count)
        let language = line[start...].trimmingCharacters(in: .whitespaces)
        return language.isEmpty ? nil : language
    }

    /// A closing fence must use the same character, be at least as long as the
    /// opener, and contain only spaces/tabs afterwards.  Do not trim the whole
    /// line: four leading spaces and non-whitespace suffixes are meaningful code.
    private static func isFenceClosing(_ line: String, fence: String) -> Bool {
        let spaces = leadingSpaces(line)
        guard spaces <= 3 else { return false }
        let rest = line.dropFirst(spaces)
        guard let character = fence.first, rest.first == character else { return false }
        let run = rest.prefix(while: { $0 == character })
        guard run.count >= fence.count else { return false }
        let suffix = rest.dropFirst(run.count)
        return suffix.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        for marker: Character in ["-", "*", "_"] {
            if trimmed.allSatisfy({ $0 == marker }) { return true }
        }
        return false
    }

    static func unorderedMarker(_ line: String) -> (indent: Int, character: Character)? {
        let indent = leadingSpaces(line)
        let rest = line.dropFirst(indent)
        guard let first = rest.first, "-*+".contains(first) else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.first == " " else { return nil }
        // 分隔线优先于列表项：`---` 不是列表
        guard !isThematicBreak(line) else { return nil }
        return (indent, first)
    }

    static func orderedMarker(_ line: String) -> (indent: Int, number: Int, delimiter: Character)? {
        let indent = leadingSpaces(line)
        var rest = line.dropFirst(indent)
        var digits = ""
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        guard rest.dropFirst().first == " " else { return nil }
        return (indent, number, delimiter)
    }

    static func quoteDepth(_ line: String) -> Int? {
        var depth = 0
        var rest = Substring(line.drop(while: { $0 == " " }))
        while rest.hasPrefix(">") {
            depth += 1
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        }
        return depth > 0 ? depth : nil
    }

    static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// 段落是否应在此行终止。
    static func startsNewBlock(_ line: String, next: String?) -> Bool {
        if headingLevel(line) != nil { return true }
        if fenceMarker(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if unorderedMarker(line) != nil { return true }
        if orderedMarker(line) != nil { return true }
        if quoteDepth(line) != nil { return true }
        if isTableRow(line), let next, isTableDelimiter(next) { return true }
        return false
    }

    static func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    // MARK: - 构造

    private static func append(
        _ blocks: inout [MarkdownBlock],
        kind: MarkdownBlock.Kind,
        lines: [String],
        sourceLines: [SourceLine],
        range: Range<Int>,
        pool: inout IDReusePool
    ) {
        let selectedLines = sourceLines[range]
        let source = lines.joined(separator: "\n")
        let id = pool.take(kind: kind, source: source)
        blocks.append(MarkdownBlock(
            id: id,
            kind: kind,
            source: source,
            lineRange: range,
            internalLineEndings: Array(selectedLines.dropLast().map { $0.ending ?? "\n" }),
            trailingLineEnding: selectedLines.last?.ending
        ))
    }
}

/// 重解析时复用旧块的 id。
///
/// 按「类型 + 内容」精确匹配，同一内容出现多次时按出现顺序依次取用，
/// 避免两个相同段落抢同一个 id。
private struct IDReusePool {
    private var available: [String: [UUID]] = [:]

    init(blocks: [MarkdownBlock]) {
        for block in blocks {
            available[Self.key(kind: block.kind, source: block.source), default: []].append(block.id)
        }
    }

    mutating func take(kind: MarkdownBlock.Kind, source: String) -> UUID {
        let key = Self.key(kind: kind, source: source)
        guard var ids = available[key], !ids.isEmpty else { return UUID() }
        let id = ids.removeFirst()
        available[key] = ids
        return id
    }

    private static func key(kind: MarkdownBlock.Kind, source: String) -> String {
        "\(kind)\u{1F}\(source)"
    }
}
