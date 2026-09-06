import SwiftUI

/// 对话正文的排版标尺。消息容器仍保持平面；这里只定义阅读宽度、字级和垂直节奏。
enum WorkPiMarkdownTypography {
    static let assistantReadingWidth: CGFloat = 740
    static let bodySize: CGFloat = 14.5
    static let bodyLineSpacing: CGFloat = 5
    static let paragraphSpacing: CGFloat = 13
    static let listRowSpacing: CGFloat = 8
    static let blockSpacing: CGFloat = 14
    static let compactBlockSpacing: CGFloat = 10
}

/// 一条完整消息的结构化 Markdown 文档。普通 VStack 可以让 AppKit 行宿主同步测得
/// 所有块的高度；不要改成 LazyVStack，否则离屏块可能缺少 intrinsic height。
struct WorkPiMarkdownDocumentView: View {
    let blocks: [WorkPiMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                WorkPiMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkPiMarkdownBlockView: View {
    let block: WorkPiMarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            WorkPiMarkdownInlineText(
                text: text,
                font: headingFont(level: level),
                color: .primary,
                lineSpacing: level <= 2 ? 3 : 4
            )
            .padding(.top, topSpacing(for: .heading(level: level)))
            .padding(.bottom, level <= 2 ? 2 : 0)

        case .paragraph(let text, let continuation):
            WorkPiMarkdownInlineText(
                text: text,
                font: .system(size: WorkPiMarkdownTypography.bodySize),
                color: .primary,
                lineSpacing: WorkPiMarkdownTypography.bodyLineSpacing
            )
            .padding(
                .top,
                block.id == 0 || continuation ? 0 : WorkPiMarkdownTypography.paragraphSpacing
            )

        case .unorderedList(let values):
            VStack(alignment: .leading, spacing: WorkPiMarkdownTypography.listRowSpacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    WorkPiMarkdownListRow(marker: "•", text: value)
                }
            }
            .padding(.top, topSpacing(for: .list))

        case .orderedList(let values):
            VStack(alignment: .leading, spacing: WorkPiMarkdownTypography.listRowSpacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    WorkPiMarkdownListRow(marker: "\(index + 1).", text: value)
                }
            }
            .padding(.top, topSpacing(for: .list))

        case .table(let headers, let rows):
            WorkPiMarkdownTableView(headers: headers, rows: rows)
                .padding(.top, topSpacing(for: .regular))

        case .quote(let text):
            HStack(alignment: .top, spacing: 11) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.32))
                    .frame(width: 3)
                WorkPiMarkdownInlineText(
                    text: text,
                    font: .system(size: 14),
                    color: .secondary,
                    lineSpacing: 4
                )
                .padding(.vertical, 1)
            }
            .padding(.top, topSpacing(for: .regular))
            .padding(.bottom, 1)

        case .code(let language, let text):
            WorkPiMarkdownCodeBlock(language: language, text: text)
                .padding(.top, topSpacing(for: .regular))

        case .thematicBreak:
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
                .padding(.top, topSpacing(for: .heading(level: 2)))
                .padding(.bottom, 2)
        }
    }

    private enum SpacingKind {
        case heading(level: Int)
        case list
        case regular
    }

    private func topSpacing(for kind: SpacingKind) -> CGFloat {
        guard block.id != 0 else { return 0 }
        switch kind {
        case .heading(let level):
            return level <= 2 ? 22 : 17
        case .list:
            return WorkPiMarkdownTypography.compactBlockSpacing
        case .regular:
            return WorkPiMarkdownTypography.blockSpacing
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 20, weight: .bold)
        case 2:
            return .system(size: 17.5, weight: .semibold)
        case 3:
            return .system(size: 15.5, weight: .semibold)
        default:
            return .system(size: 14.5, weight: .semibold)
        }
    }
}

private struct WorkPiMarkdownCodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(0.45)
                    .foregroundStyle(.tertiary)
            }

            // 对话区只保留外层一个纵向滚动所有者。代码按阅读栏宽度换行，
            // 避免横向 ScrollView 吞掉触控板的纵向滚动事件。
            Text(verbatim: text)
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

private struct WorkPiMarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            WorkPiMarkdownTableRow(values: headers, emphasized: true)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { index, values in
                WorkPiMarkdownTableRow(values: values, emphasized: false)
                if index < rows.count - 1 {
                    Divider().opacity(0.55)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct WorkPiMarkdownTableRow: View {
    let values: [String]
    let emphasized: Bool

    var body: some View {
        GridRow {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                WorkPiMarkdownInlineText(
                    text: value,
                    font: .system(size: 13.5, weight: emphasized ? .semibold : .regular),
                    color: emphasized ? .primary : .secondary,
                    lineSpacing: 3
                )
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, emphasized ? 9 : 8)
            }
        }
    }
}

private struct WorkPiMarkdownListRow: View {
    let marker: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marker)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 23, alignment: .trailing)

            WorkPiMarkdownInlineText(
                text: text,
                font: .system(size: WorkPiMarkdownTypography.bodySize),
                color: .primary,
                lineSpacing: WorkPiMarkdownTypography.bodyLineSpacing
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 块内部的行内 Markdown。Foundation 负责粗体、斜体和链接语义；代码 run
/// 追加等宽字体与弱底色，使命令、路径和正文在同一行内也有可见层级。
struct WorkPiMarkdownInlineText: View {
    @Environment(\.workPiTheme) private var theme

    let text: String
    let font: Font
    let color: Color
    let lineSpacing: CGFloat

    var body: some View {
        Text(attributedText)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedText: AttributedString {
        WorkPiMarkdownInlineRenderer.render(text, accent: theme.accent)
    }
}

@MainActor
enum WorkPiMarkdownInlineRenderer {
    static func render(
        _ source: String,
        accent: Color = WorkPiTheme.default.accent
    ) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var value = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(WorkPiMarkdownSanitizer.inlinePreview(source))
        }

        for run in value.runs {
            var attributes = AttributeContainer()
            if run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]?
                .contains(.code) == true {
                attributes[AttributeScopes.SwiftUIAttributes.FontAttribute.self] =
                    .system(size: 13, weight: .medium, design: .monospaced)
                attributes[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .primary
                attributes[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] =
                    .primary.opacity(0.07)
            } else if run[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil {
                attributes[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = accent
                attributes[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            value[run.range].mergeAttributes(attributes)
        }
        return value
    }
}
