import PiDomain
import SwiftUI

/// 标题栏图标按钮的共享几何。
///
/// 数值来自 Xcode 导航器按钮的像素实测（Retina 2x 截图换算）：底板 31×22pt，
/// 圆角曲线延伸约 8.5pt，对应半径约 7pt。苹果用的是连续圆角（continuous，
/// 圆角与直边平滑过渡，不是正圆弧），必须用 `style: .continuous`，
/// 否则圆角与直边的转折处会出现可见硬边。
enum WorkPiTitlebarButtonMetrics {
    static let plateWidth: CGFloat = 31
    static let plateHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 7

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// 标题栏中的 Sidebar 模式切换图标（文件树 / 会话树）。
///
/// 之所以由 `NSToolbarItem` 承载而不是直接画在 Sidebar 顶部：统一工具栏的
/// `NSToolbarView` 在视图层级上位于 contentView 之上，把 SwiftUI 按钮顶进标题栏
/// 区域时点击会被它拦住（实测事件到达窗口、命中判定正确，但按钮 action 不触发）。
/// 工具栏项本身就在那一层，因此天生可点击，也是 Xcode 导航器按钮的做法。
@MainActor
struct WorkPiSidebarModeSwitcher: View {
    /// 两个底板加 2pt 间距。
    static let width: CGFloat = WorkPiTitlebarButtonMetrics.plateWidth * 2 + 2
    static let height: CGFloat = WorkPiTitlebarButtonMetrics.plateHeight

    @ObservedObject var layoutState: WorkPiLayoutState
    @ObservedObject var appearanceState: WorkPiAppearanceState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkPiSidebarMode.allCases) { candidate in
                WorkPiTitlebarIconButton(
                    systemImage: candidate.icon,
                    isSelected: layoutState.sidebarMode == candidate,
                    help: candidate.helpText
                ) {
                    layoutState.sidebarMode = candidate
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .workPiTheme(appearanceState.theme)
    }
}

/// Sidebar 折叠开关。
///
/// 快捷键 `Cmd+\` 对不熟悉快捷键的用户不可发现，因此提供显式图标。
/// 位置随 Sidebar 状态平移：展开时在 Sidebar 右上角，折叠后落到交通灯右侧。
/// 这个平移由工具栏项顺序 + `.sidebarTrackingSeparator` 自动完成——分隔符跟随
/// Sidebar 边界，因此排在它之前的项会随 Sidebar 收起而左移，无需自己做动画。
@MainActor
struct WorkPiSidebarToggle: View {
    static let width = WorkPiTitlebarButtonMetrics.plateWidth
    static let height = WorkPiTitlebarButtonMetrics.plateHeight

    @ObservedObject var layoutState: WorkPiLayoutState
    @ObservedObject var appearanceState: WorkPiAppearanceState
    let language: WorkPiInterfaceLanguage

    private var help: String {
        let english = language == .english
        if layoutState.sidebarVisible {
            return english ? "Hide Sidebar (⌘\\)" : "隐藏侧边栏（⌘\\）"
        }
        return english ? "Show Sidebar (⌘\\)" : "显示侧边栏（⌘\\）"
    }

    var body: some View {
        WorkPiTitlebarIconButton(
            // 与 Xcode 导航器开关同款字形：三行「圆点 + 横线」。
            // `sidebar.left` 画的是面板轮廓，和 Xcode 的列表字形不是一回事。
            systemImage: "list.bullet",
            isSelected: false,
            help: help
        ) {
            layoutState.toggleSidebar()
        }
        .frame(width: Self.width, height: Self.height)
        .workPiTheme(appearanceState.theme)
    }
}

/// 标题栏图标按钮的统一外观：Xcode 几何 + 项目紫色选中态。
@MainActor
struct WorkPiTitlebarIconButton: View {
    @Environment(\.workPiTheme) private var theme

    let systemImage: String
    let isSelected: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                .frame(
                    width: WorkPiTitlebarButtonMetrics.plateWidth,
                    height: WorkPiTitlebarButtonMetrics.plateHeight
                )
                // hover/选中底板必须与图标按钮共用同一个连续圆角形状，
                // 并显式裁剪：只给 background 填色时，父级布局仍可能让底色
                // 溢出到形状之外，视觉上就成了方角。
                .background(
                    WorkPiTitlebarButtonMetrics.shape
                        .fill(background)
                )
                .clipShape(WorkPiTitlebarButtonMetrics.shape)
                .contentShape(WorkPiTitlebarButtonMetrics.shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var background: Color {
        if isSelected { return theme.accent.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.09) }
        return .clear
    }
}
