import PiDomain
import SwiftUI

/// `/status` 的会话统计面板。
///
/// 与 shell 执行块同区（输入框上方），因为两者都是用户主动触发、看完即可关闭的
/// 一次性输出。不放 HUD：HUD 是常驻状态条，塞进这些明细会挤爆它。
@MainActor
struct WorkPiSessionStatsPanel: View {
    @Environment(\.workPiTheme) private var theme

    let stats: PiSessionStats
    let language: WorkPiInterfaceLanguage
    let onDismiss: () -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            contextRow
            Divider().opacity(0.4)
            tokenGrid
            messageRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .workPiGlassSurface(
            role: .glass,
            cornerRadius: 11,
            tint: theme.accent.opacity(0.06)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(isEnglish ? "Session statistics" : "会话统计")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(String(format: "$%.4f", stats.cost))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent)
                .help(isEnglish ? "Total cost this session" : "本会话累计费用")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Close" : "关闭")
        }
    }

    @ViewBuilder
    private var contextRow: some View {
        if let window = stats.contextWindow {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(isEnglish ? "Context" : "上下文")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    // 压缩刚结束时 Pi 会把 tokens/percent 报成 null。
                    if let tokens = stats.contextTokens {
                        Text("\(format(tokens)) / \(format(window))")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(isEnglish ? "recalculating…" : "重新统计中…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                GeometryReader { proxy in
                    let ratio = min(max((stats.contextPercent ?? 0) / 100, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(theme.accent.opacity(ratio > 0.85 ? 0.85 : 0.55))
                            .frame(width: proxy.size.width * ratio)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private var tokenGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            metric(isEnglish ? "Input" : "输入", format(stats.inputTokens))
            metric(isEnglish ? "Output" : "输出", format(stats.outputTokens))
            metric(isEnglish ? "Cache read" : "缓存读取", format(stats.cacheReadTokens))
            metric(isEnglish ? "Cache write" : "缓存写入", format(stats.cacheWriteTokens))
            metric(isEnglish ? "Total" : "合计", format(stats.totalTokens))
        }
    }

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 0) {
            metric(isEnglish ? "You" : "你的消息", "\(stats.userMessages)")
            metric(isEnglish ? "Pi" : "Pi 回复", "\(stats.assistantMessages)")
            metric(isEnglish ? "Tool calls" : "工具调用", "\(stats.toolCalls)")
            metric(isEnglish ? "Messages" : "消息总数", "\(stats.totalMessages)")
            // 缓存命中率解释了「为什么这次花了这么多钱」，比裸 token 更有用。
            if let ratio = stats.cacheHitRatio {
                metric(
                    isEnglish ? "Cache hit" : "缓存命中",
                    "\(Int((ratio * 100).rounded()))%"
                )
            } else {
                metric(isEnglish ? "Cache hit" : "缓存命中", "—")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
