import Foundation
import SwiftUI

/// 对话区使用的轻量 Markdown 分块（不是完整 Markdown AST）。
///
/// 流式输出期间不做 Markdown 解析；回合完成后才把消息拆成少量结构块。
/// 结构块避免一个超长 `Text` 成为单一布局单元，同时不为每个块启动富文本任务。
struct WorkPiMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(text: String, continuation: Bool)
        case unorderedList([String])
        case orderedList([String])
        case table(headers: [String], rows: [[String]])
        case quote(String)
        case code(language: String?, text: String)
        case thematicBreak
    }

    let id: Int
    let kind: Kind
}

enum WorkPiMarkdownParser {
    static func parse(_ source: String) -> [WorkPiMarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [WorkPiMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var codeFenceMarker: Character?
        var inCodeFence = false

        func appendBlock(_ kind: WorkPiMarkdownBlock.Kind) {
            blocks.append(WorkPiMarkdownBlock(id: blocks.count, kind: kind))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                for (index, chunk) in paragraphChunks(text).enumerated() {
                    appendBlock(.paragraph(text: chunk, continuation: index > 0))
                }
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCodeFence() {
            appendBlock(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
            codeFenceMarker = nil
            inCodeFence = false
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                if let marker = codeFenceMarker,
                   isClosingCodeFence(trimmed, marker: marker) {
                    flushCodeFence()
                } else {
                    codeLines.append(line)
                }
                index += 1
                continue
            }

            if let fence = codeFence(from: trimmed) {
                flushParagraph()
                codeLanguage = fence.language
                codeFenceMarker = fence.marker
                inCodeFence = true
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                appendBlock(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if paragraphLines.isEmpty,
               index + 1 < lines.count,
               let setextLevel = setextHeadingLevel(from: lines[index + 1]) {
                flushParagraph()
                appendBlock(.heading(level: setextLevel, text: trimmed))
                index += 2
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                appendBlock(.thematicBreak)
                index += 1
                continue
            }

            if let table = table(from: lines, at: index) {
                flushParagraph()
                appendBlock(.table(headers: table.headers, rows: table.rows))
                index = table.nextIndex
                continue
            }

            if listMarker(in: line, ordered: false) != nil {
                flushParagraph()
                var values: [String] = []
                var cursor = index
                while cursor < lines.count,
                      let value = listMarker(in: lines[cursor], ordered: false) {
                    values.append(value)
                    cursor += 1
                }
                appendBlock(.unorderedList(values))
                index = cursor
                continue
            }

            if listMarker(in: line, ordered: true) != nil {
                flushParagraph()
                var values: [String] = []
                var cursor = index
                while cursor < lines.count,
                      let value = listMarker(in: lines[cursor], ordered: true) {
                    values.append(value)
                    cursor += 1
                }
                appendBlock(.orderedList(values))
                index = cursor
                continue
            }

            if let quote = quoteText(from: line) {
                flushParagraph()
                var values = [quote]
                var cursor = index + 1
                while cursor < lines.count, let nextQuote = quoteText(from: lines[cursor]) {
                    values.append(nextQuote)
                    cursor += 1
                }
                appendBlock(.quote(values.joined(separator: "\n")))
                index = cursor
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        if inCodeFence {
            flushCodeFence()
        } else {
            flushParagraph()
        }
        return blocks
    }

    private static func paragraphChunks(
        _ text: String,
        maximumCharacters: Int = 1_600,
        boundarySearchLength: Int = 420
    ) -> [String] {
        var result: [String] = []
        var start = text.startIndex

        while let hardEnd = text.index(
            start,
            offsetBy: maximumCharacters,
            limitedBy: text.endIndex
        ), hardEnd < text.endIndex {
            let searchStart = text.index(
                hardEnd,
                offsetBy: -boundarySearchLength,
                limitedBy: start
            ) ?? start
            let window = text[searchStart..<hardEnd]
            let punctuation = window.lastIndex { character in
                "\n。！？；.!?;".contains(character)
            }
            let whitespace = window.lastIndex(where: { $0.isWhitespace })
            let boundary = punctuation ?? whitespace
            let end = boundary.map { text.index(after: $0) } ?? hardEnd
            result.append(String(text[start..<end]))
            start = end
        }

        if start < text.endIndex {
            result.append(String(text[start...]))
        }
        return result.isEmpty ? [text] : result
    }

    private static func codeFence(from line: String) -> (language: String?, marker: Character)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let markerCount = line.prefix(while: { $0 == marker }).count
        guard markerCount >= 3 else { return nil }
        let language = String(line.dropFirst(markerCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (language.isEmpty ? nil : language, marker)
    }

    private static func isClosingCodeFence(
        _ line: String,
        marker: Character
    ) -> Bool {
        guard line.first == marker else { return false }
        return line.prefix(while: { $0 == marker }).count >= 3
    }

    private static func setextHeadingLevel(from line: String) -> Int? {
        if line.range(of: #"^\s*=+\s*$"#, options: .regularExpression) != nil {
            return 1
        }
        if line.range(of: #"^\s*-+\s*$"#, options: .regularExpression) != nil {
            return 2
        }
        return nil
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else {
            return nil
        }
        let prefix = String(line[..<match.upperBound])
        let level = prefix.filter { $0 == "#" }.count
        let text = String(line[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (level, text)
    }

    private static func listMarker(in line: String, ordered: Bool) -> String? {
        let pattern = ordered ? #"^\s*\d+[.)]\s+"# : #"^\s*[-*+]\s+"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let text = String(line[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func table(
        from lines: [String],
        at index: Int
    ) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(from: lines[index]),
              headers.count > 1,
              isTableSeparator(lines[index + 1], columnCount: headers.count)
        else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count,
              let cells = tableCells(from: lines[cursor]),
              !cells.isEmpty {
            rows.append(normalizeTableRow(cells, columnCount: headers.count))
            cursor += 1
        }
        return (headers, rows, cursor)
    }

    private static func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), !trimmed.isEmpty else { return nil }
        var value = trimmed
        if value.first == "|" { value.removeFirst() }
        if value.last == "|" { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return cells.count > 1 ? cells : nil
    }

    private static func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(from: line), cells.count == columnCount else { return false }
        return cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private static func normalizeTableRow(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count == columnCount { return cells }
        if cells.count > columnCount {
            return Array(cells.prefix(columnCount - 1))
                + [cells.dropFirst(columnCount - 1).joined(separator: " | ")]
        }
        return cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private static func quoteText(from line: String) -> String? {
        guard let match = line.range(of: #"^\s*>\s?"#, options: .regularExpression) else { return nil }
        return String(line[match.upperBound...])
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        // Setext underline 行在上一个分支已经作为标题消费；这里只处理独立分隔线。
        line.range(of: #"^\s*((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#, options: .regularExpression) != nil
    }
}

/// 对话消息的 Markdown 排版视图。
///
/// 流式阶段不对累计全文执行 Markdown 解析，而是把纯文本拆成稳定的小块：
/// 已完成的小块保持原有 identity，只有最后一块随 delta 变化。这样避免每个
/// 30Hz 更新都让 CoreText 重新测量整条长消息。
///
/// 回合完成后使用 Foundation 的 `AttributedString(markdown:)`（系统 Markdown
/// 解析器）覆盖完整 CommonMark/扩展语法。解析尚未完成时先显示结构化 fallback，
/// 因此不会把等待异步任务的中间帧误认为 Markdown 解析失败。
struct WorkPiMarkdownMessageView: View {
    let text: String
    let isStreaming: Bool
    let streamingText: String?

    @State private var renderResult: WorkPiMarkdownRenderResult?
    @State private var renderedSource = ""

    init(
        text: String,
        isStreaming: Bool,
        streamingText: String? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.streamingText = streamingText
    }

    var body: some View {
        Group {
            if isStreaming {
                WorkPiIncrementalMarkdownView(text: streamingText ?? text)
            } else if renderedSource == text, let renderResult {
                if let fallbackBlocks = renderResult.fallbackBlocks {
                    WorkPiMarkdownFallbackView(blocks: fallbackBlocks)
                } else {
                    WorkPiIncrementalMarkdownView(text: text)
                }
            } else if text.isEmpty {
                EmptyView()
            } else {
                // 后台解析期间使用增量块快照，不暴露原始 Markdown 标记，也不在
                // SwiftUI body 中同步扫描整条长文本。
                WorkPiMarkdownPendingView(text: text)
            }
        }
        .task(id: isStreaming ? "streaming" : text) {
            guard !isStreaming else { return }
            let source = text
            let result = await Task.detached(priority: .utility) {
                WorkPiMarkdownRenderer.render(source)
            }.value
            guard !Task.isCancelled else { return }
            renderResult = result
            renderedSource = source
        }
    }
}

struct WorkPiMarkdownRenderResult: Sendable {
    let attributed: AttributedString?
    let fallbackBlocks: [WorkPiMarkdownBlock]?
}

private struct WorkPiMarkdownPendingView: View {
    let text: String

    var body: some View {
        WorkPiIncrementalMarkdownView(text: text)
    }
}

/// 解析尚未完成或某个扩展语法无法完整解析时的安全预览。
/// 目标是去掉常见 Markdown 控制标记，而不是伪装成完整 AST。
enum WorkPiMarkdownSanitizer {
    static func inlinePreview(_ source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        var inFence = false

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if isFence(trimmed) {
                inFence.toggle()
                continue
            }
            if inFence {
                result.append(rawLine)
                continue
            }

            var line = rawLine
            if let heading = line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(heading)
            } else if let unordered = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                line.replaceSubrange(unordered, with: "• ")
            } else if let ordered = line.range(of: #"^(\s*)\d+[.)]\s+"#, options: .regularExpression) {
                // 保留有序列表数字，只删除多余缩进和 Markdown 分隔空格。
                let prefix = line[..<ordered.upperBound]
                let digits = prefix.filter(\.isNumber)
                line.replaceSubrange(ordered, with: "\(digits). ")
            } else if let quote = line.range(of: #"^\s*>\s?"#, options: .regularExpression) {
                line.removeSubrange(quote)
            }
            result.append(line)
        }
        return result
            .map(stripInlineMarkers)
            .joined(separator: "\n")
    }

    static func streamingFragment(_ source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { line in
                var value = line
                if let heading = value.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                    value.removeSubrange(heading)
                } else if let unordered = value.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                    value.replaceSubrange(unordered, with: "• ")
                } else if let ordered = value.range(of: #"^(\s*)\d+[.)]\s+"#, options: .regularExpression) {
                    let digits = value[..<ordered.upperBound].filter(\.isNumber)
                    value.replaceSubrange(ordered, with: "\(digits). ")
                } else if let quote = value.range(of: #"^\s*>\s?"#, options: .regularExpression) {
                    value.removeSubrange(quote)
                }
                return stripInlineMarkers(value)
            }
            .joined(separator: "\n")
    }

    private static func stripInlineMarkers(_ source: String) -> String {
        var value = source
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\*\*|__|~~|`"#, ""),
            (#"(?<!\w)\*|(?<!\w)_|\*(?!\w)|_(?!\w)"#, ""),
            (#"\\([\\`*_[\]()>#+.!~-])"#, "$1")
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return value
    }

    private static func isFence(_ line: String) -> Bool {
        guard let first = line.first, first == "`" || first == "~" else { return false }
        return line.prefix(while: { $0 == first }).count >= 3
    }
}

/// Foundation Markdown 解析器的隔离入口，便于测试和将来替换渲染后端。
enum WorkPiMarkdownRenderer {
    static func render(_ source: String) -> WorkPiMarkdownRenderResult {
        // 完成态与流式期间必须使用同一套块级排版。
        //
        // 不能用 `AttributedString(markdown:)` 渲染整条消息：它会把段落边界
        // 只记在 `presentationIntent` 里而不保留空行，用单个 `Text` 渲染时
        // 多个段落会被拼成一团，段落与代码块之间还会丢空格（如
        // 「跑起来npx」），代码块也拿不到背景与边框。
        //
        // 行内富文本（加粗、链接、行内代码）仍由
        // `WorkPiMarkdownInlineRenderer` 在块内部用 AttributedString 处理。
        WorkPiMarkdownRenderResult(
            attributed: nil,
            fallbackBlocks: WorkPiMarkdownParser.parse(source)
        )
    }


}

private struct WorkPiMarkdownFallbackView: View {
    let blocks: [WorkPiMarkdownBlock]

    var body: some View {
        // 使用普通 VStack 而不是 LazyVStack：每个消息本身已经是独立的
        // NSHostingView 行，必须在 AppKit 的 fittingSize 测量时同步得到全部
        // block 高度；惰性栈可能只为可见子项建立布局，导致行框短于实际绘制内容。
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                WorkPiMarkdownBlockView(block: block)
            }
        }
    }
}
