import Foundation

/// 编辑器支持的行内格式快捷键。
enum WorkPiMarkdownInlineFormat: Equatable {
    case strong
    case emphasis
    case code
    case link

    var delimiters: (prefix: String, suffix: String) {
        switch self {
        case .strong: return ("**", "**")
        case .emphasis: return ("*", "*")
        case .code: return ("`", "`")
        case .link: return ("[", "]()")
        }
    }
}

struct WorkPiMarkdownInlineEditResult: Equatable {
    let text: String
    let selectedRange: NSRange
}

/// 只处理编辑器快捷键所需的局部包裹/解包，不重排其它源码。
enum WorkPiMarkdownInlineEditing {
    static func apply(
        _ format: WorkPiMarkdownInlineFormat,
        to source: String,
        selectedRange: NSRange
    ) -> WorkPiMarkdownInlineEditResult? {
        let value = source as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= value.length
        else { return nil }

        switch format {
        case .link:
            return applyLink(to: value, selectedRange: selectedRange)
        case .strong, .emphasis, .code:
            return applyDelimited(
                format,
                to: value,
                selectedRange: selectedRange
            )
        }
    }

    private static func applyDelimited(
        _ format: WorkPiMarkdownInlineFormat,
        to source: NSString,
        selectedRange: NSRange
    ) -> WorkPiMarkdownInlineEditResult {
        let (prefix, suffix) = format.delimiters
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        let selected = source.substring(with: selectedRange)

        let beforeRange = NSRange(
            location: max(0, selectedRange.location - prefixLength),
            length: prefixLength
        )
        let afterRange = NSRange(
            location: NSMaxRange(selectedRange),
            length: suffixLength
        )
        let hasWrappers = beforeRange.location >= 0
            && beforeRange.location + beforeRange.length <= source.length
            && afterRange.location + afterRange.length <= source.length
            && source.substring(with: beforeRange) == prefix
            && source.substring(with: afterRange) == suffix

        if hasWrappers {
            let removalRange = NSRange(
                location: beforeRange.location,
                length: prefixLength + selectedRange.length + suffixLength
            )
            let inner = source.substring(with: selectedRange)
            let mutable = source.mutableCopy() as! NSMutableString
            mutable.replaceCharacters(in: removalRange, with: inner)
            return WorkPiMarkdownInlineEditResult(
                text: String(mutable),
                selectedRange: NSRange(
                    location: beforeRange.location,
                    length: selectedRange.length
                )
            )
        }

        let replacement = prefix + selected + suffix
        let mutable = source.mutableCopy() as! NSMutableString
        mutable.replaceCharacters(in: selectedRange, with: replacement)
        return WorkPiMarkdownInlineEditResult(
            text: String(mutable),
            selectedRange: NSRange(
                location: selectedRange.location + prefixLength,
                length: selectedRange.length
            )
        )
    }

    private static func applyLink(
        to source: NSString,
        selectedRange: NSRange
    ) -> WorkPiMarkdownInlineEditResult {
        let selected = source.substring(with: selectedRange)
        let replacement = "[" + selected + "](https://)"
        let mutable = source.mutableCopy() as! NSMutableString
        mutable.replaceCharacters(in: selectedRange, with: replacement)
        let urlStart = selectedRange.location + 1 + selectedRange.length + 2
        return WorkPiMarkdownInlineEditResult(
            text: String(mutable),
            // 将光标放在 URL 的占位内容中，用户可以直接输入地址。
            selectedRange: NSRange(location: urlStart, length: "https://".utf16.count)
        )
    }
}
