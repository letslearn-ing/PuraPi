import SwiftUI

/// 流式 Markdown 的增量快照（incremental snapshot，已经稳定的块与尚未闭合的尾部）。
struct PuraPiIncrementalMarkdownSnapshot: Equatable, Sendable {
    let stableBlocks: [PuraPiMarkdownBlock]
    let tailText: String
}

/// 只从上一次稳定边界继续扫描的 Markdown 块状态机。
///
/// 稳定边界是「已经写完的一行」：只要收到换行符，该行就提交为稳定块，
/// 因此正文是一行一行推进的，而不是整段懋到空行才出现。代码围栏是例外：
/// 围栏内部不拆行，必须等闭合后整块提交，否则语法不完整、高亮也会抛。
///
/// 未到边界的尾部不会被重复解析成完整文档，只显示有限的安全预览。
/// 回合结束时调用 `finish`，再由完整解析器生成最终块，保证跨行结构
/// （列表、表格、引用）在最终排版上仍然正确。
struct PuraPiIncrementalMarkdownState: Sendable {
    private(set) var stableBlocks: [PuraPiMarkdownBlock] = []

    /// 已写完但尚未提交的整行（不含换行符）。
    ///
    /// 用行数组而不是一个不断重建的尾部字符串：原先每次提交都要
    /// `tailText = String(tailText[boundary...])`，那是 O(尾部长度) 的拷贝，
    /// 逐字流式下累积成二次复杂度。
    private var pendingLines: [String] = []
    /// 正在写、还没收到换行符的一行。
    private var currentLine = ""
    /// 已提交行中尚未完成的跨行组类型。
    private var pendingGroupKind: LineGroupKind?
    /// 未闭合代码围栏的标记字符。
    private var openFenceMarker: Character?

    /// 完整原文，仅用于 `finish` 时的权威解析。追加是摊销 O(1)。
    private(set) var rawText = ""
    /// 已消费的 UTF-8 字节数。`utf8.count` 对原生字符串是 O(1)，
    /// 而 `String.count` 是 O(n)，逐字流式下后者会退化为 O(n²)。
    private var consumedUTF8Count = 0

    /// 展示用的未提交尾部。长度受跨行组与超长行上限约束，不随全文增长。
    var tailText: String {
        guard !pendingLines.isEmpty else { return currentLine }
        var out = pendingLines.joined(separator: "\n")
        out.append("\n")
        out.append(currentLine)
        return out
    }

    var snapshot: PuraPiIncrementalMarkdownSnapshot {
        PuraPiIncrementalMarkdownSnapshot(
            stableBlocks: stableBlocks,
            tailText: tailText
        )
    }

    mutating func update(_ source: String) {
        let sourceUTF8Count = source.utf8.count
        guard sourceUTF8Count != consumedUTF8Count || source != rawText else { return }

        let deltaUTF8Count = sourceUTF8Count - consumedUTF8Count
        guard deltaUTF8Count > 0, isAppend(of: source, deltaUTF8Count: deltaUTF8Count) else {
            // 内容被重写（切换消息、历史重建）：整体重算。
            rebuild(with: source)
            return
        }

        // 从尾部向前取 delta，避开从开头 offsetBy 的全串遍历。
        // rawText 是 source 的前缀，因此 delta 边界一定在字符边界上。
        let deltaBytes = source.utf8.suffix(deltaUTF8Count)
        let delta = String(decoding: deltaBytes, as: UTF8.self)

        rawText.append(delta)
        consumedUTF8Count = sourceUTF8Count
        ingest(delta)
    }

    mutating func finish(_ source: String? = nil) {
        if let source {
            rawText = source
            consumedUTF8Count = source.utf8.count
        }
        stableBlocks = reindex(PuraPiMarkdownParser.parse(rawText), startingAt: 0)
        pendingLines.removeAll(keepingCapacity: true)
        currentLine = ""
        pendingGroupKind = nil
        openFenceMarker = nil
    }

    mutating func reset() {
        stableBlocks.removeAll(keepingCapacity: true)
        pendingLines.removeAll(keepingCapacity: true)
        currentLine = ""
        pendingGroupKind = nil
        openFenceMarker = nil
        rawText = ""
        consumedUTF8Count = 0
    }

    /// 只比较重叠区末尾的有限窗口。
    ///
    /// 完整前缀比较是 O(n)，逐字流式下累积成 O(n²)。流式场景下只会
    /// 追加，因此用固定窗口确认边界对齐就够用；窗口外的差异会在下一次
    /// 长度不匹配或 `finish` 的权威解析时被纠正。
    private func isAppend(of source: String, deltaUTF8Count: Int) -> Bool {
        guard consumedUTF8Count > 0 else { return true }
        let window = min(Self.appendCheckWindowBytes, consumedUTF8Count)
        let previousTail = Array(rawText.utf8.suffix(window))
        let overlapTail = Array(source.utf8.dropLast(deltaUTF8Count).suffix(window))
        return previousTail == overlapTail
    }

    private mutating func rebuild(with source: String) {
        reset()
        rawText = source
        consumedUTF8Count = source.utf8.count
        ingest(source)
    }

    /// 把新到的文本按行切开，每写完一行就尝试提交。
    private mutating func ingest(_ delta: String) {
        for character in delta {
            if character == "\n" {
                pendingLines.append(currentLine)
                currentLine = ""
                commitCompletedLines()
            } else {
                currentLine.append(character)
            }
        }
        // 没有换行符的超长单行仍需切分，否则尾部会无限增长。
        splitOverlongCurrentLineIfNeeded()
    }

    /// 根据已完整的行推进稳定区。只看行头特征，不重扫历史文本。
    private mutating func commitCompletedLines() {
        while !pendingLines.isEmpty {
            let trimmed = pendingLines[0].trimmingCharacters(in: .whitespaces)

            if let marker = openFenceMarker {
                // 围栏内不拆行：未闭合的代码块拆开后语法不成立。
                //
                // 从第 2 行开始找闭合：索引 0 是开围栏行本身，
                // `isClosingFence` 对它也成立，从 0 找会立即提交出一个空代码块。
                guard pendingLines.count > 1 else { return }
                let closingOffset = pendingLines[1...].firstIndex(where: {
                    Self.isClosingFence(
                        $0.trimmingCharacters(in: .whitespaces),
                        marker: marker
                    )
                })
                guard let closingOffset else { return }
                commitLines(through: closingOffset)
                openFenceMarker = nil
                continue
            }

            if let marker = Self.openingFenceMarker(trimmed) {
                // 围栏开头前的跨行组先整组提交。
                if pendingGroupKind != nil {
                    commitLines(through: -1)
                    pendingGroupKind = nil
                    continue
                }
                // 记下开围栏后直接退出：开围栏行必须留在缓冲区，
                // 等闭合行到达时跟整个代码块一起提交。
                openFenceMarker = marker
                return
            }

            let kind = Self.lineGroupKind(trimmed)

            if let group = pendingGroupKind {
                // 跨行组必须整组提交：否则表格分隔行会以普通段落裸露，
                // 列表也会被拆成多个单项列表。
                guard let endIndex = pendingLines.firstIndex(where: {
                    Self.lineGroupKind($0.trimmingCharacters(in: .whitespaces)) != group
                }) else {
                    // 全部仍属于同一组；过长时先提交已完成部分。
                    if pendingGroupCharacterCount > Self.maximumUncommittedGroupCharacters {
                        commitLines(through: pendingLines.count - 1)
                    }
                    return
                }
                commitLines(through: endIndex - 1)
                pendingGroupKind = nil
                continue
            }

            if kind != nil {
                pendingGroupKind = kind
                continue
            }

            // 普通行（含标题、空行）：写完即提交。
            commitLines(through: 0)
        }
    }

    /// 提交 `pendingLines` 前 0...index 行；index 为 -1时提交全部已缓存行。
    private mutating func commitLines(through index: Int) {
        let end = index < 0 ? pendingLines.count : index + 1
        guard end > 0, end <= pendingLines.count else { return }
        let source = pendingLines[0..<end].joined(separator: "\n")
        pendingLines.removeFirst(end)
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let parsed = PuraPiMarkdownParser.parse(source)
        stableBlocks.append(contentsOf: reindex(parsed, startingAt: stableBlocks.count))
    }

    private var pendingGroupCharacterCount: Int {
        pendingLines.reduce(0) { $0 + $1.count + 1 }
    }

    private mutating func splitOverlongCurrentLineIfNeeded() {
        guard openFenceMarker == nil,
              pendingGroupKind == nil,
              currentLine.count > Self.maximumUncommittedCharacters
        else { return }

        let hardEnd = currentLine.index(
            currentLine.startIndex,
            offsetBy: Self.maximumUncommittedCharacters
        )
        let searchStart = currentLine.index(
            hardEnd,
            offsetBy: -Self.boundarySearchCharacters,
            limitedBy: currentLine.startIndex
        ) ?? currentLine.startIndex
        let window = currentLine[searchStart..<hardEnd]
        let cut = window.lastIndex(where: { $0.isWhitespace }).map(currentLine.index(after:))
            ?? hardEnd

        let committed = String(currentLine[..<cut])
        currentLine = String(currentLine[cut...])
        guard !committed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let parsed = PuraPiMarkdownParser.parse(committed)
        stableBlocks.append(contentsOf: reindex(parsed, startingAt: stableBlocks.count))
    }

    /// 稳定块的 id 必须全局递增，否则 SwiftUI 会因 identity 重复而复用错行。
    private func reindex(
        _ blocks: [PuraPiMarkdownBlock],
        startingAt offset: Int
    ) -> [PuraPiMarkdownBlock] {
        blocks.enumerated().map { index, block in
            PuraPiMarkdownBlock(id: offset + index, kind: block.kind)
        }
    }

    /// 必须整组提交的跨行结构类型。
    private enum LineGroupKind: Equatable {
        case list
        case table
        case quote
    }

    /// 判定一行是否属于跨行结构；nil 表示普通行，可以逐行提交。
    private static func lineGroupKind(_ trimmed: String) -> LineGroupKind? {
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("|") { return .table }
        if trimmed.hasPrefix(">") { return .quote }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return .list
        }
        if trimmed == "-" || trimmed == "*" || trimmed == "+" { return .list }
        // 有序列表：数字加 `.` 或 `)`。
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ")
                || rest == "." || rest == ")" {
                return .list
            }
        }
        return nil
    }

    private static func openingFenceMarker(_ line: String) -> Character? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        return line.prefix(while: { $0 == first }).count >= 3 ? first : nil
    }

    private static func isClosingFence(_ line: String, marker: Character) -> Bool {
        guard line.first == marker else { return false }
        return line.prefix(while: { $0 == marker }).count >= 3
    }

    private static let maximumUncommittedCharacters = 1_600
    private static let boundarySearchCharacters = 360
    /// 跨行组的最大暂缓长度；超过后先提交已完整的行，保证长列表仍有流式感。
    private static let maximumUncommittedGroupCharacters = 600
    /// 追加校验窗口。只比较重叠区末尾这些字节，避免每次全前缀比较。
    private static let appendCheckWindowBytes = 64
}

/// 增量 Markdown 的 SwiftUI 行视图。稳定块保持自己的 identity，只有尾部在变化。
struct PuraPiIncrementalMarkdownView: View {
    let text: String

    @State private var state: PuraPiIncrementalMarkdownState

    init(text: String) {
        self.text = text
        var initialState = PuraPiIncrementalMarkdownState()
        initialState.update(text)
        _state = State(initialValue: initialState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.stableBlocks) { block in
                PuraPiMarkdownBlockView(block: block)
            }

            if !state.tailText.isEmpty {
                PuraPiIncrementalMarkdownTailView(text: state.tailText)
            }
        }
        .onAppear {
            state.update(text)
        }
        .onChange(of: text) { _, newText in
            state.update(newText)
        }
    }
}

private struct PuraPiIncrementalMarkdownTailView: View {
    let text: String

    var body: some View {
        let blocks = PuraPiMarkdownParser.parse(text)
        let hasUnclosedInlineSyntax = PuraPiIncrementalMarkdownSyntax.hasUnclosedInlineSyntax(text)

        if !hasUnclosedInlineSyntax, !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    PuraPiMarkdownBlockView(block: block)
                }
            }
        } else {
            Text(verbatim: PuraPiMarkdownSanitizer.inlinePreview(text))
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum PuraPiIncrementalMarkdownSyntax {
    static func hasUnclosedInlineSyntax(_ source: String) -> Bool {
        let markers = ["**", "__", "~~", "`"]
        return markers.contains { marker in
            let occurrenceCount = source.components(separatedBy: marker).count - 1
            return occurrenceCount % 2 == 1
        }
    }
}
