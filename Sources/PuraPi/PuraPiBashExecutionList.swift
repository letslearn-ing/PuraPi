import PiDomain
import SwiftUI

/// 直接执行的 shell 命令块。
///
/// 独立于对话气泡：命令输出是流式的，需要显示退出码、截断入口和中止按钮，
/// 这些普通消息行承载不了。位置在输入框上方，与追问队列同一区域，
/// 因为两者都是「尚未进入模型上下文的待发内容」。
@MainActor
struct PuraPiBashExecutionList: View {
    @Environment(\.puraPiTheme) private var theme

    let executions: [BashExecution]
    let language: PuraPiInterfaceLanguage
    let onAbort: () -> Void
    let onCopy: (BashExecution) -> Void
    let onRevealFullOutput: (String) -> Void
    let onClear: () -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            ForEach(executions) { execution in
                PuraPiBashExecutionRow(
                    execution: execution,
                    isEnglish: isEnglish,
                    onAbort: onAbort,
                    onCopy: { onCopy(execution) },
                    onRevealFullOutput: onRevealFullOutput
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .puraPiGlassSurface(
            role: .glass,
            cornerRadius: 11,
            tint: theme.accent.opacity(0.06)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accent)
            // 明确说明输出何时进入上下文：这是 bash 与工具调用最容易混淆的地方。
            Text(
                isEnglish
                    ? "Command output joins the context on your next message"
                    : "命令输出会在下一次提问时并入上下文"
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            Button(action: onClear) {
                Text(isEnglish ? "Clear" : "清空")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Remove these blocks from the view" : "从界面移除这些执行块")
        }
    }
}

@MainActor
private struct PuraPiBashExecutionRow: View {
    @Environment(\.puraPiTheme) private var theme

    let execution: BashExecution
    let isEnglish: Bool
    let onAbort: () -> Void
    let onCopy: () -> Void
    let onRevealFullOutput: (String) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            commandLine
            if isExpanded, !execution.output.isEmpty {
                outputBlock
            }
            if case .failed(let message) = execution.state, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.error)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let path = execution.fullOutputPath {
                truncationNotice(path: path)
            } else if execution.outputTruncated {
                Text(isEnglish ? "Output truncated to protect memory" : "输出已截断以保护内存")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.warning)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var commandLine: some View {
        HStack(spacing: 6) {
            Image(systemName: execution.isRunning ? "circle.dotted" : statusIcon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(statusColor)

            Text(execution.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? 2 : 1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(execution.statusText(isEnglish: isEnglish))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(statusColor)

            if execution.isRunning {
                Button(action: onAbort) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isEnglish ? "Abort" : "中止")
            } else if !execution.output.isEmpty {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isEnglish ? "Copy output" : "复制输出")
            }

            if !execution.output.isEmpty {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
    }

    private var outputBlock: some View {
        // stdout 与 stderr 由 Pi 合并成一条流，无法分开着色。
        ScrollView {
            Text(execution.output)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }

    private func truncationNotice(path: String) -> some View {
        Button {
            onRevealFullOutput(path)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 9))
                Text(isEnglish ? "Output truncated · reveal full log" : "输出已截断 · 查看完整日志")
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
    }

    private var statusIcon: String {
        switch execution.state {
        case .running: return "circle.dotted"
        case .finished(let code): return code == 0 ? "checkmark.circle" : "xmark.circle"
        case .cancelled: return "minus.circle"
        case .failed: return "xmark.octagon"
        case .rejected: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        if execution.isRunning { return theme.accent }
        switch execution.state {
        case .cancelled: return .secondary
        case .failed, .rejected: return theme.error
        case .finished(let code): return code == 0 ? theme.success : theme.warning
        case .running: return theme.accent
        }
    }
}
