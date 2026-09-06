import SwiftUI

/// Composer 上方的待执行任务列表。
///
/// Agent 忙时提交的任务会停在这里，等当前回合结束后自动发出；每条都可以在
/// 发出前取消。任务已经交给 Pi 之后就不再出现在这里。
struct WorkPiQueuedPromptList: View {
    let items: [WorkPiQueuedPrompt]
    let language: WorkPiInterfaceLanguage
    let onCancel: (UUID) -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(headerText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            ForEach(items) { item in
                WorkPiQueuedPromptRow(
                    text: item.text,
                    attachmentNames: item.attachmentNames,
                    cancelHint: isEnglish ? "Cancel this task" : "取消这条任务",
                    onCancel: { onCancel(item.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerText: String {
        if items.count == 1 {
            return isEnglish ? "1 task queued" : "1 条任务等待执行"
        }
        return isEnglish
            ? "\(items.count) tasks queued"
            : "\(items.count) 条任务等待执行"
    }
}

private struct WorkPiQueuedPromptRow: View {
    @Environment(\.workPiTheme) private var theme

    let text: String
    let attachmentNames: [String]
    let cancelHint: String
    let onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    // 队列里可能是很长的任务描述；限制两行，完整内容在 tooltip 中。
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(text)
                if !attachmentNames.isEmpty {
                    Label(
                        attachmentNames.joined(separator: ", "),
                        systemImage: "paperclip"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(attachmentNames.joined(separator: ", "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(isHovering ? theme.error : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(cancelHint)
            .accessibilityLabel(cancelHint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .onHover { isHovering = $0 }
    }
}
