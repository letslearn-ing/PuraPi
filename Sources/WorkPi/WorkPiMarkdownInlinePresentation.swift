import AppKit
import Foundation

/// Markdown 块内行内标记的展示结果。
///
/// 编辑器在失焦时显示“去掉标记后的文本”，聚焦时显示原始 Markdown。
/// `sourceToVisible` / `visibleToSource` 把两种文本的 UTF-16 光标位置互相映射，
/// 这样隐藏标记不会让用户点击后跳到错误位置，也不会改变保存时的源码。
struct WorkPiMarkdownInlinePresentation {
    struct Result {
        let attributedString: NSAttributedString
        let sourceToVisible: [Int]
        let visibleToSource: [Int]

        var sourceLength: Int { sourceToVisible.count - 1 }
        var visibleLength: Int { visibleToSource.count - 1 }

        func visibleRange(for sourceRange: NSRange) -> NSRange {
            let start = sourceToVisible[safe: sourceRange.location, default: 0]
            let endOffset = min(sourceLength, max(0, NSMaxRange(sourceRange)))
            let end = sourceToVisible[safe: endOffset, default: visibleLength]
            return NSRange(location: start, length: max(0, end - start))
        }

        func sourceRange(for visibleRange: NSRange) -> NSRange {
            let start = visibleToSource[safe: visibleRange.location, default: 0]
            let endOffset = min(visibleLength, max(0, NSMaxRange(visibleRange)))
            let end = visibleToSource[safe: endOffset, default: sourceLength]
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    private struct Span {
        let contentRange: NSRange
        let markerRanges: [NSRange]
        let style: Style
    }

    private struct Style: OptionSet {
        let rawValue: UInt8

        static let strong = Style(rawValue: 1 << 0)
        static let emphasis = Style(rawValue: 1 << 1)
        static let code = Style(rawValue: 1 << 2)
        static let strikethrough = Style(rawValue: 1 << 3)
        static let link = Style(rawValue: 1 << 4)
    }

    /// 将一段块正文转换为编辑器展示文本。
    ///
    /// `showsMarkers == true` 时保留所有源码标记；否则只移除已识别的成对标记。
    /// 代码块正文可以关闭 `allowsFormatting`，避免代码中的星号和反引号被解释。
    static func render(
        source: String,
        baseFont: NSFont,
        baseColor: NSColor,
        paragraphStyle: NSParagraphStyle,
        showsMarkers: Bool,
        allowsFormatting: Bool = true
    ) -> Result {
        let sourceString = source as NSString
        let sourceLength = sourceString.length
        let spans = allowsFormatting ? parseSpans(sourceString) : []
        var removed = IndexSet()

        if !showsMarkers {
            for span in spans {
                for marker in span.markerRanges {
                    for offset in marker.location..<NSMaxRange(marker) {
                        removed.insert(offset)
                    }
                }
            }
        }

        let visible = NSMutableAttributedString()
        var sourceToVisible = Array(repeating: 0, count: sourceLength + 1)
        var sourceOffset = 0

        while sourceOffset < sourceLength {
            let composedRange = sourceString.rangeOfComposedCharacterSequence(at: sourceOffset)
            let end = NSMaxRange(composedRange)
            let outputStart = visible.length
            let isRemoved = removed.contains(sourceOffset)

            if !isRemoved {
                visible.append(NSAttributedString(string: sourceString.substring(with: composedRange)))
            }

            let outputEnd = visible.length
            for boundary in sourceOffset...end {
                if isRemoved {
                    sourceToVisible[boundary] = outputStart
                } else {
                    let relative = boundary - sourceOffset
                    sourceToVisible[boundary] = min(outputEnd, outputStart + relative)
                }
            }
            sourceOffset = end
        }
        sourceToVisible[sourceLength] = visible.length

        var visibleToSource = Array(repeating: 0, count: visible.length + 1)
        for sourceBoundary in 0...sourceLength {
            let visibleBoundary = sourceToVisible[sourceBoundary]
            if visibleBoundary < visibleToSource.count {
                // 同一个可见位置可能对应被隐藏标记的多个源码边界；取最后一个，
                // 让点击标记原本所在的位置后光标落在正文侧，而不是标记内部。
                visibleToSource[visibleBoundary] = sourceBoundary
            }
        }
        fillUnmappedVisibleBoundaries(&visibleToSource)

        let fullRange = NSRange(location: 0, length: visible.length)
        if visible.length > 0 {
            visible.addAttributes([
                .font: baseFont,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraphStyle,
            ], range: fullRange)
        }

        var masks = Array(repeating: Style(), count: visible.length)
        for span in spans {
            let visibleRange = mapSourceRange(
                span.contentRange,
                using: sourceToVisible,
                visibleLength: visible.length
            )
            guard visibleRange.length > 0 else { continue }
            for offset in visibleRange.location..<NSMaxRange(visibleRange) {
                masks[offset].insert(span.style)
            }
        }

        applyInlineAttributes(
            to: visible,
            masks: masks,
            baseFont: baseFont,
            baseColor: baseColor
        )

        if showsMarkers {
            for span in spans {
                for marker in span.markerRanges {
                    let markerRange = mapSourceRange(
                        marker,
                        using: sourceToVisible,
                        visibleLength: visible.length
                    )
                    guard markerRange.length > 0 else { continue }
                    visible.addAttribute(
                        .foregroundColor,
                        value: baseColor.withAlphaComponent(0.48),
                        range: markerRange
                    )
                }
            }
        }

        return Result(
            attributedString: visible,
            sourceToVisible: sourceToVisible,
            visibleToSource: visibleToSource
        )
    }

    private static func parseSpans(_ source: NSString) -> [Span] {
        let codeSpans = findPairs(in: source, delimiter: "`", protected: IndexSet())
        var protected = IndexSet()
        for span in codeSpans {
            let start = span.markerRanges.first?.location ?? span.contentRange.location
            let end = span.markerRanges.last.map(NSMaxRange) ?? NSMaxRange(span.contentRange)
            for offset in start..<end { protected.insert(offset) }
        }

        let linkSpans = findLinks(in: source, protected: protected)
        for span in linkSpans {
            for marker in span.markerRanges {
                for offset in marker.location..<NSMaxRange(marker) {
                    protected.insert(offset)
                }
            }
        }

        let strongSpans = findPairs(in: source, delimiter: "**", protected: protected)
        let strikeSpans = findPairs(in: source, delimiter: "~~", protected: protected)
        let emphasisSpans = findPairs(
            in: source,
            delimiter: "*",
            protected: protected,
            rejectAdjacentDelimiter: "*"
        )

        return codeSpans.map { span in
            Span(contentRange: span.contentRange, markerRanges: span.markerRanges, style: .code)
        } + linkSpans.map { span in
            Span(contentRange: span.contentRange, markerRanges: span.markerRanges, style: .link)
        } + strongSpans.map { span in
            Span(contentRange: span.contentRange, markerRanges: span.markerRanges, style: .strong)
        } + emphasisSpans.map { span in
            Span(contentRange: span.contentRange, markerRanges: span.markerRanges, style: .emphasis)
        } + strikeSpans.map { span in
            Span(contentRange: span.contentRange, markerRanges: span.markerRanges, style: .strikethrough)
        }
    }

    private static func findPairs(
        in source: NSString,
        delimiter: String,
        protected: IndexSet,
        rejectAdjacentDelimiter: String? = nil
    ) -> [Span] {
        let width = (delimiter as NSString).length
        let length = source.length
        guard width > 0, length >= width * 2 else { return [] }

        var result: [Span] = []
        var cursor = 0
        while cursor <= length - width {
            guard source.substring(with: NSRange(location: cursor, length: width)) == delimiter,
                  !contains(protected, location: cursor, length: width),
                  !isEscaped(source, at: cursor),
                  !hasAdjacentDelimiter(
                      source,
                      at: cursor,
                      width: width,
                      delimiter: rejectAdjacentDelimiter
                  )
            else {
                cursor += 1
                continue
            }

            let opener = cursor
            var search = cursor + width
            var matched: Span?
            while search <= length - width {
                guard source.substring(with: NSRange(location: search, length: width)) == delimiter,
                      !contains(protected, location: search, length: width),
                      !isEscaped(source, at: search),
                      !hasAdjacentDelimiter(
                          source,
                          at: search,
                          width: width,
                          delimiter: rejectAdjacentDelimiter
                      )
                else {
                    search += 1
                    continue
                }

                let content = NSRange(
                    location: opener + width,
                    length: search - opener - width
                )
                if content.length > 0 {
                    matched = Span(
                        contentRange: content,
                        markerRanges: [
                            NSRange(location: opener, length: width),
                            NSRange(location: search, length: width),
                        ],
                        style: []
                    )
                    break
                }
                search += width
            }

            if let matched {
                result.append(matched)
                cursor = search + width
            } else {
                cursor = opener + width
            }
        }
        return result
    }

    private static func findLinks(in source: NSString, protected: IndexSet) -> [Span] {
        var result: [Span] = []
        var cursor = 0
        while cursor < source.length {
            guard source.character(at: cursor) == 91,
                  !contains(protected, location: cursor, length: 1),
                  !isEscaped(source, at: cursor)
            else {
                cursor += 1
                continue
            }

            var labelEnd = cursor + 1
            while labelEnd < source.length {
                if source.character(at: labelEnd) == 93,
                   labelEnd + 1 < source.length,
                   source.character(at: labelEnd + 1) == 40,
                   !isEscaped(source, at: labelEnd) {
                    break
                }
                labelEnd += 1
            }
            guard labelEnd + 1 < source.length,
                  source.character(at: labelEnd) == 93,
                  source.character(at: labelEnd + 1) == 40
            else {
                cursor += 1
                continue
            }

            var close = labelEnd + 2
            var depth = 1
            while close < source.length {
                let character = source.character(at: close)
                if character == 40, !isEscaped(source, at: close) {
                    depth += 1
                } else if character == 41, !isEscaped(source, at: close) {
                    depth -= 1
                    if depth == 0 { break }
                }
                close += 1
            }
            guard close < source.length, labelEnd > cursor + 1 else {
                cursor += 1
                continue
            }

            let content = NSRange(
                location: cursor + 1,
                length: labelEnd - cursor - 1
            )
            let markerRanges = [
                NSRange(location: cursor, length: 1),
                NSRange(location: labelEnd, length: 2),
                NSRange(location: labelEnd + 2, length: close - labelEnd - 2),
                NSRange(location: close, length: 1),
            ]
            result.append(Span(
                contentRange: content,
                markerRanges: markerRanges,
                style: .link
            ))
            cursor = close + 1
        }
        return result
    }

    private static func contains(_ set: IndexSet, location: Int, length: Int) -> Bool {
        set.intersects(integersIn: location..<(location + length))
    }

    private static func hasAdjacentDelimiter(
        _ source: NSString,
        at location: Int,
        width: Int,
        delimiter: String?
    ) -> Bool {
        guard let delimiter, delimiter == "*" else { return false }
        if location > 0, source.character(at: location - 1) == 42 { return true }
        if location + width < source.length, source.character(at: location + width) == 42 {
            return true
        }
        return false
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var slashCount = 0
        var cursor = location - 1
        while cursor >= 0, source.character(at: cursor) == 92 {
            slashCount += 1
            cursor -= 1
        }
        return slashCount % 2 == 1
    }

    private static func mapSourceRange(
        _ range: NSRange,
        using sourceToVisible: [Int],
        visibleLength: Int
    ) -> NSRange {
        let startOffset = min(sourceToVisible.count - 1, max(0, range.location))
        let endOffset = min(sourceToVisible.count - 1, max(0, NSMaxRange(range)))
        let start = min(visibleLength, sourceToVisible[startOffset])
        let end = min(visibleLength, sourceToVisible[endOffset])
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func fillUnmappedVisibleBoundaries(_ mapping: inout [Int]) {
        var last = 0
        for index in mapping.indices {
            if mapping[index] == 0 && index != 0 {
                mapping[index] = last
            } else {
                last = mapping[index]
            }
        }
    }

    private static func applyInlineAttributes(
        to text: NSMutableAttributedString,
        masks: [Style],
        baseFont: NSFont,
        baseColor: NSColor
    ) {
        guard !masks.isEmpty else { return }
        var start = 0
        while start < masks.count {
            let mask = masks[start]
            var end = start + 1
            while end < masks.count, masks[end] == mask { end += 1 }
            let range = NSRange(location: start, length: end - start)
            if !mask.isEmpty {
                text.addAttribute(
                    .font,
                    value: font(for: mask, baseFont: baseFont),
                    range: range
                )
                if mask.contains(.code) {
                    text.addAttribute(
                        .backgroundColor,
                        value: NSColor.labelColor.withAlphaComponent(0.08),
                        range: range
                    )
                }
                if mask.contains(.strikethrough) {
                    text.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
                if mask.contains(.link) {
                    text.addAttribute(
                        .foregroundColor,
                        value: NSColor.linkColor,
                        range: range
                    )
                    text.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
                if mask.contains(.code) {
                    text.addAttribute(
                        .foregroundColor,
                        value: baseColor,
                        range: range
                    )
                }
            }
            start = end
        }
    }

    private static func font(for style: Style, baseFont: NSFont) -> NSFont {
        if style.contains(.code) {
            var codeFont = NSFont.monospacedSystemFont(
                ofSize: baseFont.pointSize,
                weight: style.contains(.strong) ? .medium : .regular
            )
            if style.contains(.emphasis) {
                codeFont = NSFontManager.shared.convert(
                    codeFont,
                    toHaveTrait: .italicFontMask
                )
            }
            return codeFont
        }

        var font = baseFont
        if style.contains(.strong) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if style.contains(.emphasis) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

private extension Array {
    subscript(safe index: Index, default defaultValue: Element) -> Element {
        indices.contains(index) ? self[index] : defaultValue
    }
}
