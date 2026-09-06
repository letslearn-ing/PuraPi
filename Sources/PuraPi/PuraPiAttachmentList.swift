import PiDomain
import SwiftUI

/// 待发送附件的横向列表。
///
/// 放在输入框上方，与追问队列、shell 执行块同区——都是「尚未发送的内容」。
@MainActor
struct PuraPiAttachmentList: View {
    @Environment(\.puraPiTheme) private var theme

    let attachments: [PuraPiAttachment]
    let language: PuraPiInterfaceLanguage
    let onRemove: (UUID) -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    chip(attachment)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 30)
    }

    private func chip(_ attachment: PuraPiAttachment) -> some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.accent)

            Text(attachment.displayName)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)

            Button {
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Remove" : "移除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.24), lineWidth: 0.5)
        )
        .help(attachment.url?.path ?? attachment.displayName)
    }
}
