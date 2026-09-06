import SwiftUI

/// Runtime 断开或请求失败时显示在 Composer 上方的局部错误视图；
/// Inspector 的 `previewError` 仍由自己的正文错误视图承载，二者不混用。
struct RuntimeNoticeBanner: View {
    @Environment(\.workPiTheme) private var theme

    let text: String
    let onDismiss: () -> Void
    let actionTitle: String?
    let onAction: (() -> Void)?
    let secondaryActionTitle: String?
    let onSecondaryAction: (() -> Void)?
    let isDismissible: Bool

    init(
        text: String,
        onDismiss: @escaping () -> Void,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil,
        isDismissible: Bool = true
    ) {
        self.text = text
        self.onDismiss = onDismiss
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.secondaryActionTitle = secondaryActionTitle
        self.onSecondaryAction = onSecondaryAction
        self.isDismissible = isDismissible
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel(actionTitle)
            }
            if let secondaryActionTitle, let onSecondaryAction {
                Button(secondaryActionTitle, action: onSecondaryAction)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel(secondaryActionTitle)
            }
            Spacer(minLength: 0)
            if isDismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Runtime 提示：\(text)")
    }
}

struct ErrorBanner: View {
    @Environment(\.workPiTheme) private var theme

    let text: String
    let onDismiss: () -> Void
    let actionTitle: String?
    let onAction: (() -> Void)?
    let secondaryActionTitle: String?
    let onSecondaryAction: (() -> Void)?

    init(
        text: String,
        onDismiss: @escaping () -> Void,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.onDismiss = onDismiss
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.secondaryActionTitle = secondaryActionTitle
        self.onSecondaryAction = onSecondaryAction
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.error)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel(actionTitle)
            }
            if let secondaryActionTitle, let onSecondaryAction {
                Button(secondaryActionTitle, action: onSecondaryAction)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel(secondaryActionTitle)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭错误")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Runtime 错误：\(text)")
    }
}
