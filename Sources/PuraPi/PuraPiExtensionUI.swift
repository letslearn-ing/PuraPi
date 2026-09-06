import PiRPC
import SwiftUI

/// PuraPi 内部对 Extension UI 对话的结果，不暴露给 PiRPC 以外的协议细节。
enum PuraPiExtensionUIResult: Equatable {
    case value(String)
    case confirmed(Bool)
    case cancelled
}

/// 非阻塞的 Extension UI 通知。它不是 Runtime 错误，不会覆盖 `lastError`。
struct PuraPiExtensionNotification: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case info
        case warning
        case error

        init(rawValue: String?) {
            switch rawValue?.lowercased() {
            case "warning": self = .warning
            case "error": self = .error
            default: self = .info
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

/// Extension UI 的字符串 widget（小组件）快照。
struct PuraPiExtensionWidget: Identifiable, Equatable {
    let id: String
    let lines: [String]
    let placement: String
}

/// 原生 macOS Extension UI 对话容器。
///
/// sheet 被关闭、按 Escape 或点击取消时都会走同一条取消路径。控制器仍会以
/// request id 做一次性去重，因此系统关闭和用户按钮不会产生两次 RPC 响应。
struct PuraPiExtensionUIDialog: View {
    let request: PiExtensionUIRequest
    let onResolve: (String, PuraPiExtensionUIResult) -> Void

    @State private var didResolve = false

    var body: some View {
        dialogContent
            .frame(width: dialogWidth, height: dialogHeight)
            .padding(22)
            .onExitCommand {
                resolve(.cancelled)
            }
            .onDisappear {
                // Sheet 的消失可能正发生在 SwiftUI 当前 View 更新/拆卸轮次中。
                // 将取消响应推迟到下一轮，避免同步修改 PiSessionController 的
                // @Published extensionUIRequest 触发运行期警告；request id 去重
                // 仍保证旧 sheet 不会解析新请求。
                DispatchQueue.main.async {
                    resolve(.cancelled)
                }
            }
    }

    @ViewBuilder
    private var dialogContent: some View {
        switch request.dialogMethod {
        case .select:
            PuraPiExtensionSelectDialog(
                title: request.title ?? "选择",
                message: request.message,
                options: request.options,
                onResolve: resolve
            )
        case .confirm:
            PuraPiExtensionConfirmDialog(
                title: request.title ?? "确认",
                message: request.message,
                onResolve: resolve
            )
        case .input:
            PuraPiExtensionInputDialog(
                title: request.title ?? "输入",
                message: request.message,
                placeholder: request.placeholder,
                onResolve: resolve
            )
        case .editor:
            PuraPiExtensionEditorDialog(
                title: request.title ?? "编辑",
                message: request.message,
                prefill: request.prefill ?? "",
                onResolve: resolve
            )
        case nil:
            PuraPiExtensionUnsupportedDialog(
                title: request.title ?? "不支持的扩展交互",
                message: "此扩展交互不能在 PuraPi 原生界面中显示。",
                onResolve: { resolve(.cancelled) }
            )
        }
    }

    private var dialogWidth: CGFloat {
        request.dialogMethod == .editor ? 620 : 480
    }

    private var dialogHeight: CGFloat {
        switch request.dialogMethod {
        case .select: return min(520, max(300, CGFloat(request.options.count) * 42 + 190))
        case .confirm: return 220
        case .input: return 240
        case .editor: return 480
        case nil: return 230
        }
    }

    private func resolve(_ result: PuraPiExtensionUIResult) {
        guard !didResolve else { return }
        didResolve = true
        onResolve(request.id, result)
    }
}

private struct PuraPiExtensionDialogHeader: View {
    let title: String
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PuraPiExtensionDialogButtons: View {
    let onCancel: () -> Void
    let confirmTitle: String
    let confirmDisabled: Bool
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(confirmDisabled)
        }
    }
}

private struct PuraPiExtensionSelectDialog: View {
    let title: String
    let message: String?
    let options: [String]
    let onResolve: (PuraPiExtensionUIResult) -> Void

    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PuraPiExtensionDialogHeader(title: title, message: message)

            if options.isEmpty {
                ContentUnavailableView(
                    "没有可选项",
                    systemImage: "list.bullet.rectangle",
                    description: Text("扩展没有提供任何选项。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedIndex) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Text(option)
                            .lineLimit(2)
                            .tag(Optional(index))
                    }
                }
                .listStyle(.inset)
                .onAppear {
                    if selectedIndex == nil { selectedIndex = options.indices.first }
                }
                .onSubmit {
                    submit()
                }
            }

            PuraPiExtensionDialogButtons(
                onCancel: { onResolve(.cancelled) },
                confirmTitle: "选择",
                confirmDisabled: selectedIndex == nil,
                onConfirm: submit
            )
        }
    }

    private func submit() {
        guard let selectedIndex, options.indices.contains(selectedIndex) else { return }
        onResolve(.value(options[selectedIndex]))
    }
}

private struct PuraPiExtensionConfirmDialog: View {
    let title: String
    let message: String?
    let onResolve: (PuraPiExtensionUIResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PuraPiExtensionDialogHeader(title: title, message: message)
            Spacer(minLength: 0)
            PuraPiExtensionDialogButtons(
                onCancel: { onResolve(.cancelled) },
                confirmTitle: "确认",
                confirmDisabled: false,
                onConfirm: { onResolve(.confirmed(true)) }
            )
        }
    }
}

private struct PuraPiExtensionInputDialog: View {
    let title: String
    let message: String?
    let placeholder: String?
    let onResolve: (PuraPiExtensionUIResult) -> Void

    @State private var value = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PuraPiExtensionDialogHeader(title: title, message: message)

            TextField(placeholder ?? "输入内容", text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)

            Spacer(minLength: 0)
            PuraPiExtensionDialogButtons(
                onCancel: { onResolve(.cancelled) },
                confirmTitle: "完成",
                confirmDisabled: false,
                onConfirm: submit
            )
        }
        .onAppear {
            isFocused = true
        }
    }

    private func submit() {
        onResolve(.value(value))
    }
}

private struct PuraPiExtensionEditorDialog: View {
    let title: String
    let message: String?
    let prefill: String
    let onResolve: (PuraPiExtensionUIResult) -> Void

    @State private var value: String

    init(
        title: String,
        message: String?,
        prefill: String,
        onResolve: @escaping (PuraPiExtensionUIResult) -> Void
    ) {
        self.title = title
        self.message = message
        self.prefill = prefill
        self.onResolve = onResolve
        _value = State(initialValue: prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PuraPiExtensionDialogHeader(title: title, message: message)

            TextEditor(text: $value)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5)
                }

            PuraPiExtensionDialogButtons(
                onCancel: { onResolve(.cancelled) },
                confirmTitle: "完成",
                confirmDisabled: false,
                onConfirm: { onResolve(.value(value)) }
            )
        }
    }
}

private struct PuraPiExtensionUnsupportedDialog: View {
    let title: String
    let message: String
    let onResolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PuraPiExtensionDialogHeader(title: title, message: message)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("关闭", action: onResolve)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 将 Extension UI 的非阻塞状态显示在 Composer 上方；不改变中心滚动内容模型。
struct PuraPiExtensionStatusStack: View {
    @Environment(\.puraPiTheme) private var theme

    let notifications: [PuraPiExtensionNotification]
    let statuses: [String: String]
    let widgets: [PuraPiExtensionWidget]
    let widgetPlacement: String
    let onDismissNotification: (UUID) -> Void

    private var visibleWidgets: [PuraPiExtensionWidget] {
        widgets.filter { ($0.placement == "belowEditor" ? "belowEditor" : "aboveEditor") == widgetPlacement }
    }

    var body: some View {
        if !notifications.isEmpty || !statuses.isEmpty || !visibleWidgets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notifications) { notification in
                    notificationRow(notification)
                }

                ForEach(statuses.keys.sorted(), id: \.self) { key in
                    statusRow(key: key, value: statuses[key] ?? "")
                }

                ForEach(visibleWidgets) { widget in
                    widgetView(widget)
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 42)
            .padding(.bottom, 5)
        }
    }

    private func notificationRow(_ notification: PuraPiExtensionNotification) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: notification.kind))
                .foregroundStyle(color(for: notification.kind))
            Text(notification.message)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                onDismissNotification(notification.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            color(for: notification.kind).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private func statusRow(key: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func widgetView(_ widget: PuraPiExtensionWidget) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !widget.id.isEmpty {
                Text(widget.id)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func icon(for kind: PuraPiExtensionNotification.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(for kind: PuraPiExtensionNotification.Kind) -> Color {
        switch kind {
        case .info: return theme.info
        case .warning: return theme.warning
        case .error: return theme.error
        }
    }
}
