import AppKit
import SwiftUI

/// 只识别“整块就是图片引用”的简单 Markdown 形式；复杂行内混排继续由文本编辑器处理。
struct PuraPiMarkdownImageReference: Equatable, Sendable {
    let altText: String
    let relativePath: String

    static func parse(_ source: String) -> Self? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("![") else { return nil }

        // Find the unescaped alt-text delimiter.  A plain firstIndex(of: "]")
        // rejected perfectly ordinary names such as `![a\\]b](...)`.
        var cursor = value.index(value.startIndex, offsetBy: 2)
        let altStart = cursor
        var escaped = false
        var altEnd: String.Index?
        while cursor < value.endIndex {
            let character = value[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "]" {
                altEnd = cursor
                break
            }
            cursor = value.index(after: cursor)
        }
        guard let altEnd,
              altEnd >= altStart
        else { return nil }
        cursor = value.index(after: altEnd)
        guard cursor < value.endIndex, value[cursor] == "(" else { return nil }
        cursor = value.index(after: cursor)
        while cursor < value.endIndex, value[cursor].isWhitespace { cursor = value.index(after: cursor) }

        let destination: String
        if cursor < value.endIndex, value[cursor] == "<" {
            cursor = value.index(after: cursor)
            let start = cursor
            escaped = false
            while cursor < value.endIndex {
                let character = value[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == ">" {
                    break
                } else if character == "\n" || character == "\r" {
                    return nil
                }
                cursor = value.index(after: cursor)
            }
            guard cursor < value.endIndex, value[cursor] == ">" else { return nil }
            destination = unescapeMarkdown(String(value[start..<cursor]))
            cursor = value.index(after: cursor)
        } else {
            let start = cursor
            var parenthesisDepth = 0
            escaped = false
            while cursor < value.endIndex {
                let character = value[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "(" {
                    parenthesisDepth += 1
                } else if character == ")" {
                    if parenthesisDepth == 0 { break }
                    parenthesisDepth -= 1
                } else if character.isWhitespace {
                    break
                } else if character == "\n" || character == "\r" {
                    return nil
                }
                cursor = value.index(after: cursor)
            }
            destination = unescapeMarkdown(String(value[start..<cursor]))
        }
        guard !destination.isEmpty else { return nil }

        while cursor < value.endIndex, value[cursor].isWhitespace { cursor = value.index(after: cursor) }
        if cursor < value.endIndex, value[cursor] != ")" {
            // Titles are accepted in the normal Markdown forms.  They are not
            // needed for the preview, but validating them prevents a malformed
            // suffix from being mistaken for a valid image reference.
            let quote = value[cursor]
            if quote == "\"" || quote == "'" {
                cursor = value.index(after: cursor)
                escaped = false
                while cursor < value.endIndex {
                    let character = value[cursor]
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == quote { break }
                    else if character == "\n" || character == "\r" { return nil }
                    cursor = value.index(after: cursor)
                }
                guard cursor < value.endIndex, value[cursor] == quote else { return nil }
                cursor = value.index(after: cursor)
                while cursor < value.endIndex, value[cursor].isWhitespace { cursor = value.index(after: cursor) }
                guard cursor < value.endIndex, value[cursor] == ")" else { return nil }
                cursor = value.index(after: cursor)
            } else if quote == "(" {
                cursor = value.index(after: cursor)
                var depth = 1
                while cursor < value.endIndex, depth > 0 {
                    let character = value[cursor]
                    if character == "\\" {
                        cursor = value.index(after: cursor)
                        if cursor < value.endIndex { cursor = value.index(after: cursor) }
                        continue
                    }
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                    cursor = value.index(after: cursor)
                }
                guard depth == 0 else { return nil }
                // The title's closing parenthesis is also the reference's
                // closing parenthesis only for the parenthesized title form.
                while cursor < value.endIndex, value[cursor].isWhitespace { cursor = value.index(after: cursor) }
                guard cursor < value.endIndex, value[cursor] == ")" else { return nil }
                cursor = value.index(after: cursor)
            } else {
                return nil
            }
        } else if cursor < value.endIndex {
            cursor = value.index(after: cursor)
        }
        while cursor < value.endIndex, value[cursor].isWhitespace { cursor = value.index(after: cursor) }
        guard cursor == value.endIndex else { return nil }

        let alt = unescapeMarkdown(String(value[altStart..<altEnd]))
        return Self(altText: alt, relativePath: destination)
    }

    private static func unescapeMarkdown(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                // A backslash before a Markdown punctuation/space is an
                // escape; before an ordinary filename character it is a real
                // macOS filename character and must be retained.
                if next == "\\"
                    || next == "<" || next == ">"
                    || next == "[" || next == "]"
                    || next.isPunctuation || next.isWhitespace {
                    result.append(next)
                } else {
                    result.append("\\")
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    func resolvedURL(workspaceRoot: URL) -> URL? {
        let candidate = URL(
            fileURLWithPath: relativePath,
            relativeTo: workspaceRoot
        ).standardizedFileURL
        guard PuraPiMarkdownImageInsertion.validatedImageURL(
            candidate,
            workspaceRoot: workspaceRoot
        ) != nil else { return nil }
        // 保留工作区内的逻辑路径；安全读取时再由 root fd 逐级打开，不能直接
        // 返回解析后的符号链接目标路径。
        return candidate
    }
}

/// 编辑态图片预览：图片是独立的视觉层，源码仍由同一个 NSTextView 编辑和保存。
@MainActor
struct PuraPiMarkdownEmbeddedImageView: View {
    @Environment(\.puraPiTheme) private var theme

    let url: URL
    let workspaceRoot: URL
    let altText: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 280, alignment: .leading)
                    .accessibilityLabel(altText.isEmpty ? "Markdown 图片" : altText)
            } else if failed {
                Label("图片无法预览", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(7)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.panelBorder.opacity(0.65), lineWidth: 0.7)
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        image = nil
        failed = false
        let imageData: Data? = await Task.detached(priority: .utility) { () async -> Data? in
            await Task.yield()
            guard !Task.isCancelled,
                  let data = PuraPiMarkdownImageInsertion.readImageData(
                      at: url,
                      workspaceRoot: workspaceRoot
                  )
            else { return nil }
            return PuraPiMarkdownImageInsertion.safePreviewData(from: data)
        }.value
        guard !Task.isCancelled,
              let imageData,
              let decoded = NSImage(data: imageData)
        else {
            failed = true
            return
        }
        image = decoded
    }
}
