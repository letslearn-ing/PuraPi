import AppKit
import Combine
import Foundation

/// Sidebar（侧边栏）的显示、宽度和持久化状态。
/// 原生全高 Split 负责让 Toolbar 前导边界跟随 divider；不要再用这里的宽度
/// 为 Toolbar 叠加第二套动态占位。
@MainActor
final class PuraPiLayoutState: ObservableObject {
    static let sidebarVisibleKey = PuraPiPreferences.Key.sidebarVisible
    static let sidebarWidthKey = PuraPiPreferences.Key.sidebarWidth
    static let inspectorWidthKey = PuraPiPreferences.Key.inspectorWidth
    static let defaultSidebarWidth: CGFloat = 290
    static let minimumSidebarWidth: CGFloat = 220
    static let maximumSidebarWidth: CGFloat = 460
    /// Inspector（右侧文件检查器）与 Sidebar 共用同一套宽度语义：
    /// 用户拖动 → 回写状态 → 防抖持久化。区间比 Sidebar 宽，因为它要放代码和 Markdown。
    static let defaultInspectorWidth: CGFloat = 410
    static let minimumInspectorWidth: CGFloat = 280
    static let maximumInspectorWidth: CGFloat = 720
    /// 窗口与悬浮 Sidebar 共用的连续圆角指标。
    static let chromeCornerRadius: CGFloat = 18
    /// Sidebar 与窗口外框之间的呼吸间距，接近 Finder 的悬浮侧边栏几何。
    static let sidebarInset: CGFloat = 8
    /// Inspector 与窗口外框之间的呼吸间距。
    ///
    /// 与 `sidebarInset` 取同一个值，让左右两栏的悬浮层级完全对称。
    static let inspectorInset: CGFloat = 8
    /// Inspector 内容相对自身圆角表面的额外顶部安全区。
    /// 外层表面仍通过 `inspectorInset` 与窗口边缘保持间距；由于 Inspector 没有
    /// 交通灯或独立顶部工具栏，这个内部额外 inset 保持为 0。
    static let inspectorContentTopInset: CGFloat = 0
    /// Inspector 自绘圆角表面相对栏位顶部的实际间距。
    /// 这是外层悬浮 inset 加上内容自身的额外安全区；当前值为 8pt。
    static var inspectorSurfaceTopInset: CGFloat {
        inspectorInset + inspectorContentTopInset
    }
    /// Native Sidebar item 会把第一条 divider 折叠为 0pt，而普通 Inspector
    /// 仍保留实际 divider。这个值用于补齐中心内容的前导留白，使两侧可见表面
    /// 到中心内容的间距一致；不参与任何 pane 宽度或持久化宽度计算。
    static func nativeSidebarCenterLeadingInset(for dividerThickness: CGFloat) -> CGFloat {
        inspectorInset + max(0, dividerThickness)
    }
    /// Sidebar 材质从窗口顶部延伸时，目录树内容为交通灯保留的安全区。
    /// 项目根目录行位于真实 ScrollView 内，会与其他文件一起滚动。
    static let sidebarContentTopInset: CGFloat = 40
    /// macOS 26 原生 Sidebar 只保留交通灯下方的紧凑间距；legacy 路径继续
    /// 使用上面的完整标题栏安全区。
    static let nativeSidebarContentTopInset: CGFloat = 18

    @Published private(set) var sidebarVisible: Bool
    @Published private(set) var sidebarWidth: CGFloat
    @Published private(set) var inspectorWidth: CGFloat
    /// Inspector 是否处于最大化状态。
    ///
    /// 最大化时中间工作区折叠，Inspector 向左延伸到 Sidebar 分隔处。
    @Published var inspectorMaximized = false

    /// Sidebar 当前显示文件树还是会话树。
    ///
    /// 放在这里而不是 `PuraPiSidebarPane` 的 `@State`：模式切换图标位于
    /// 标题栏工具栏中，与 Sidebar 内容处于两棵不同的视图树，必须共享状态。
    @Published var sidebarMode: PuraPiSidebarMode = .files

    init() {
        let defaults = PuraPiPreferences.shared
        sidebarVisible = defaults.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true

        let storedWidth = defaults.double(forKey: Self.sidebarWidthKey)
        if storedWidth.isFinite, storedWidth > 0 {
            sidebarWidth = Self.clampedSidebarWidth(CGFloat(storedWidth))
        } else {
            sidebarWidth = Self.defaultSidebarWidth
        }

        let storedInspectorWidth = defaults.double(forKey: Self.inspectorWidthKey)
        if storedInspectorWidth.isFinite, storedInspectorWidth > 0 {
            inspectorWidth = Self.clampedInspectorWidth(CGFloat(storedInspectorWidth))
        } else {
            inspectorWidth = Self.defaultInspectorWidth
        }
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        PuraPiPreferences.shared.set(sidebarVisible, forKey: Self.sidebarVisibleKey)
    }

    func resizeSidebar(to width: CGFloat) {
        let clampedWidth = Self.clampedSidebarWidth(width)
        guard abs(clampedWidth - sidebarWidth) > 0.01 else { return }
        sidebarWidth = clampedWidth
    }

    func persistSidebarWidth() {
        PuraPiPreferences.shared.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    func resizeInspector(to width: CGFloat) {
        let clampedWidth = Self.clampedInspectorWidth(width)
        guard abs(clampedWidth - inspectorWidth) > 0.01 else { return }
        inspectorWidth = clampedWidth
    }

    func persistInspectorWidth() {
        PuraPiPreferences.shared.set(Double(inspectorWidth), forKey: Self.inspectorWidthKey)
    }

    private static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    private static func clampedInspectorWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumInspectorWidth), maximumInspectorWidth)
    }
}

enum PuraPiKeyboardShortcut {
    static func isToggleSidebar(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard event.keyCode == 42 || event.charactersIgnoringModifiers == "\\" else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }
}

extension Notification.Name {
    static let puraPiNewWorkspace = Notification.Name("PuraPi.newWorkspace")
    static let puraPiOpenWorkspace = Notification.Name("PuraPi.openWorkspace")
    static let puraPiCloseSelectedTab = Notification.Name("PuraPi.closeSelectedTab")
    static let puraPiCloseAllProjects = Notification.Name("PuraPi.closeAllProjects")
    static let puraPiToggleSidebar = Notification.Name("PuraPi.toggleSidebar")
    static let puraPiToggleInspectorDetached = Notification.Name("PuraPi.toggleInspectorDetached")
}
