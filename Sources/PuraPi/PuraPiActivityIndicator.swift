import PiDomain
import SwiftUI

/// Agent 活动指示器。
///
/// 与 Pi TUI 的 `Loader` 对齐：Braille 点阵十帧、80ms 一跳，配一句短文案。
/// 只重绘这一个小视图，不触碰对话内容，因此不会引起正文重排。
struct PuraPiActivityIndicator: View {
    @Environment(\.puraPiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let activity: AgentActivity
    let language: PuraPiInterfaceLanguage
    /// 活动开始时刻；用于显示已耗时，让长任务有进度感。
    let startedAt: Date

    /// 与 Pi TUI 相同的帧集合与节奏。
    static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let frameInterval: TimeInterval = 0.08

    /// 固定行高。
    ///
    /// 外层需要用 `GeometryReader` 读可用宽度来对齐正文左边界，而
    /// `GeometryReader` 不提供固有高度，必须在这里给出确定值。
    static let preferredHeight: CGFloat = 22

    /// 指示色。
    ///
    /// 不用 accent：项目的 accent 是紫色，已经给 Sidebar 选中态、链接和
    /// 模型下拉占用，再用同一色表达「运行中」分辨不出来。
    /// 结束态（停止）用橙色，与普通运行区分。
    private var indicatorColor: Color {
        activity == .stopping ? theme.warning : theme.success
    }

    @State private var frameIndex = 0
    @State private var elapsed: TimeInterval = 0

    private var label: String {
        AgentActivityText.label(
            for: activity,
            language: language == .english ? .english : .chinese
        )
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(Self.frames[frameIndex])
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(indicatorColor)
                // 单字符宽度固定，避免逐帧改变布局宽度。
                .frame(width: 13, alignment: .center)

            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            if let elapsedText {
                Text(elapsedText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: activityIdentity) {
            // 活动切换时重置，避免沿用上一段活动的耗时与帧位。
            frameIndex = 0
            elapsed = 0
            if !reduceMotion {
                await animate()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    /// 只显示到秒；1 秒内不显示，避免短任务出现无意义的跳动。
    private var elapsedText: String? {
        guard elapsed >= 1 else { return nil }
        if elapsed < 60 {
            return language == .english ? "\(Int(elapsed))s" : "\(Int(elapsed))秒"
        }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return language == .english
            ? "\(minutes)m \(seconds)s"
            : "\(minutes)分 \(seconds)秒"
    }

    /// 活动语义变化才重启动画；同一活动内不因父视图刷新而重置。
    private var activityIdentity: String {
        "\(activity)-\(startedAt.timeIntervalSince1970)"
    }

    private func animate() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.frameInterval))
            if Task.isCancelled { return }
            frameIndex = (frameIndex + 1) % Self.frames.count
            elapsed = Date().timeIntervalSince(startedAt)
        }
    }
}
