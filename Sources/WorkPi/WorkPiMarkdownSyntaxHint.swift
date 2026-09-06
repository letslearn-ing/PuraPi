import Foundation
import PiDomain

/// 编辑器内的非阻塞 Markdown 语法提示。
enum WorkPiMarkdownSyntaxHint {
    static func message(
        kind: MarkdownBlock.Kind,
        text: String,
        language: WorkPiInterfaceLanguage
    ) -> String? {
        let isEnglish = language == .english
        if case .codeFence = kind {
            return isEnglish
                ? "Tab inserts indentation · Return adds a code line"
                : "Tab 插入缩进 · Return 在代码块内换行"
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/" {
            return isEnglish
                ? "Try /table, /code, /quote, or /list"
                : "可输入 /表格、/代码、/引用 或 /列表"
        }
        if trimmed.hasPrefix("/") {
            return isEnglish
                ? "Known block commands: /table · /code · /quote · /list"
                : "可用块命令：/表格 · /代码 · /引用 · /列表"
        }
        if isBlockPrefix(trimmed) {
            return isEnglish
                ? "Press Space to turn this line into a Markdown block"
                : "输入空格即可转换为 Markdown 块"
        }

        let markerPairs = [("**", "**"), ("~~", "~~"), ("`", "`"), ("*", "*")]
        for (opening, _) in markerPairs {
            if unmatchedCount(of: opening, in: text) % 2 == 1 {
                return isEnglish
                    ? "Close the \(opening) marker to apply inline formatting"
                    : "补全 \(opening) 标记即可应用行内格式"
            }
        }
        return nil
    }

    private static func isBlockPrefix(_ text: String) -> Bool {
        if text == ">" || text == "```" || text == "~~~" { return true }
        if text.allSatisfy({ $0 == "#" }), (1...6).contains(text.count) { return true }
        if text.count == 1, "-*+".contains(text.first ?? " ") { return true }
        if text.count <= 3,
           text.last == ".",
           text.dropLast().allSatisfy({ $0.isNumber }) {
            return true
        }
        return false
    }

    private static func unmatchedCount(of marker: String, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            if !isEscaped(text, at: range.lowerBound) { count += 1 }
            searchStart = range.upperBound
        }
        return count
    }

    private static func isEscaped(_ text: String, at index: String.Index) -> Bool {
        var count = 0
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if text[cursor] == "\\" { count += 1 } else { break }
        }
        return count % 2 == 1
    }
}
