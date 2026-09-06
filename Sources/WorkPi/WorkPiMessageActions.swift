import AppKit
import PiDomain
import SwiftUI

/// 单条消息的操作：复制、重发。
///
/// 直接写剪贴板而不是回调到控制器：消息行是高频更新的轻量 View，
/// viewport 通过稳定的消息 id 管理宿主；塞进可变协调器闭包会增加重排成本。
@MainActor
enum WorkPiMessageActions {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 把原文填回输入框，供用户修改后再发。
    ///
    /// 通过通知而不是把控制器闭包存进高频消息行。
    static func edit(_ text: String) {
        NotificationCenter.default.post(
            name: .workPiEditMessage,
            object: nil,
            userInfo: ["text": text]
        )
    }

    /// 立即重试：原样重新发送这条消息。
    ///
    /// 与 `edit` 分开是必要的：重试的语义是「刚才那次不满意，再来一遍」，
    /// 多一步确认反而碍事；而修改后重发是另一个意图。
    static func retry(_ text: String) {
        NotificationCenter.default.post(
            name: .workPiRetryMessage,
            object: nil,
            userInfo: ["text": text]
        )
    }
}

extension Notification.Name {
    static let workPiEditMessage = Notification.Name("WorkPi.editMessage")
    static let workPiRetryMessage = Notification.Name("WorkPi.retryMessage")
}

/// 消息下方的操作条：时间、复制、重试、编辑。
///
/// 时间常显，操作按钮悬停才出现——时间是信息，按钮是动作，
/// 常显按钮会让长对话显得嘈杂。
struct WorkPiMessageActionBar: View {
    @Environment(\.workPiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let createdAt: Date
    /// 用户消息可重试与编辑；助手消息只能复制。
    let allowsRetry: Bool
    let isVisible: Bool

    @State private var didCopy = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.timeFormatter.string(from: createdAt))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if isVisible || didCopy {
                copyButton
                if allowsRetry {
                    retryButton
                    editButton
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isVisible)
    }

    private var copyButton: some View {
        actionButton(
            icon: didCopy ? "checkmark" : "doc.on.doc",
            tint: didCopy ? theme.success : Color.secondary,
            help: "复制这条消息"
        ) {
            WorkPiMessageActions.copy(text)
            // 剪贴板没有系统反馈，给一个短暂确认。
            didCopy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                didCopy = false
            }
        }
    }

    private var retryButton: some View {
        actionButton(
            icon: "arrow.clockwise",
            tint: .secondary,
            help: "重新发送这条消息"
        ) {
            WorkPiMessageActions.retry(text)
        }
    }

    private var editButton: some View {
        actionButton(
            icon: "square.and.pencil",
            tint: .secondary,
            help: "填回输入框以便修改后重发"
        ) {
            WorkPiMessageActions.edit(text)
        }
    }

    private func actionButton(
        icon: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 给消息行挂上操作条。
struct WorkPiMessageActionsModifier: ViewModifier {
    let text: String
    let createdAt: Date
    let allowsRetry: Bool
    /// 操作条的水平对齐：用户消息靠右（与气泡同侧），助手消息靠左。
    let alignment: HorizontalAlignment

    @State private var isHovering = false

    func body(content: Content) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            content
            if !text.isEmpty {
                WorkPiMessageActionBar(
                    text: text,
                    createdAt: createdAt,
                    allowsRetry: allowsRetry,
                    isVisible: isHovering
                )
            }
        }
        .onHover { isHovering = $0 }
    }
}

extension View {
    func workPiMessageActions(
        text: String,
        createdAt: Date,
        allowsRetry: Bool = false,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        modifier(
            WorkPiMessageActionsModifier(
                text: text,
                createdAt: createdAt,
                allowsRetry: allowsRetry,
                alignment: alignment
            )
        )
    }
}
