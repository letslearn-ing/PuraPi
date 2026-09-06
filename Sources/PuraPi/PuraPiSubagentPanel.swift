import PiDomain
import SwiftUI

/// Runtime HUD 下方的 SubAgent 任务面板。
///
/// 面板只展示主 Runtime 通过 Extension UI 发布的快照；点击任务打开独立的
/// 只读 Session 查看器，不切换主 Runtime 的会话。
@MainActor
struct PuraPiSubagentPanel: View {
    @Environment(\.puraPiTheme) private var theme

    let tasks: [SubagentTaskSnapshot]
    let language: PuraPiInterfaceLanguage
    let onOpen: (SubagentTaskSnapshot) -> Void

    private var runningCount: Int {
        tasks.filter { $0.status == .running || $0.status == .retrying }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(language == .english ? "SubAgents" : "SubAgent")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(tasks.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if runningCount > 0 {
                    Text(language == .english ? "\(runningCount) running" : "\(runningCount) 个运行中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
                Spacer(minLength: 0)
                Text(language == .english ? "Click to inspect" : "点击查看独立会话")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(tasks) { task in
                        PuraPiSubagentTaskRow(
                            task: task,
                            language: language,
                            onOpen: { onOpen(task) }
                        )
                    }
                }
            }
            .frame(maxHeight: 190)
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .puraPiGlassSurface(
            role: .hud,
            cornerRadius: 10,
            interactive: true,
            tint: theme.accent.opacity(0.055)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language == .english ? "SubAgent tasks" : "SubAgent 任务")
    }
}

@MainActor
private struct PuraPiSubagentTaskRow: View {
    @Environment(\.puraPiTheme) private var theme

    let task: SubagentTaskSnapshot
    let language: PuraPiInterfaceLanguage
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.agentName)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        if let step = task.step {
                            Text(language == .english ? "step \(step)" : "第 \(step) 步")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        if let model = task.model {
                            Text(shortModelName(model))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(task.fallbackUsed ? theme.warning : Color.secondary.opacity(0.8))
                                .help(model)
                        }
                        if task.fallbackUsed {
                            Text(language == .english ? "fallback" : "回退")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(theme.warning)
                        }
                    }

                    Text(task.task)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let detail = task.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let outputPreview = task.outputPreview, !outputPreview.isEmpty,
                       task.status == .completed || task.status == .failed {
                        Text("↳ \(outputPreview)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? theme.accent.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isHovering ? theme.accent.opacity(0.24) : Color.clear,
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityText)
        .help(language == .english ? "Open this SubAgent session" : "打开这个 SubAgent 的独立会话")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.72)
        case .retrying:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.warning)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.error)
        case .cancelled:
            Image(systemName: "stop.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var detailColor: Color {
        switch task.status {
        case .failed: return theme.error
        case .retrying: return theme.warning
        case .completed: return theme.success.opacity(0.85)
        default: return .secondary
        }
    }

    private var accessibilityText: String {
        let status: String
        switch task.status {
        case .queued: status = language == .english ? "queued" : "等待中"
        case .running: status = language == .english ? "running" : "运行中"
        case .retrying: status = language == .english ? "retrying" : "重试中"
        case .completed: status = language == .english ? "completed" : "已完成"
        case .failed: status = language == .english ? "failed" : "失败"
        case .cancelled: status = language == .english ? "cancelled" : "已取消"
        }
        return "\(task.agentName), \(status): \(task.task)"
    }

    private func shortModelName(_ model: String) -> String {
        let raw = model.split(separator: "/").last.map(String.init) ?? model
        switch raw {
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.6-sol": return "Sol"
        default: return raw
        }
    }
}
