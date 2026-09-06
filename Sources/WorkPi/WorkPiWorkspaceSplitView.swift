import AppKit
import PiDomain
import SwiftUI

/// macOS 26 的原生三栏工作区。
///
/// Sidebar、中心对话和 Inspector 都是同一个 `NSSplitViewController` 的 item。Sidebar
/// 使用 `sidebarWithViewController` item，由 AppKit 提供全高系统表面；中心的真实
/// AppKit 滚动根视图交给公开 accessory API 合成，Inspector 的 SwiftUI 滚动正文使用
/// 公开 `scrollEdgeEffectStyle`。
/// Sidebar 保留完整可见表面；Native Sidebar 与 Inspector 的 divider 差值只由中心
/// 底部浮动内容的前导留白吸收，不改变 pane 几何。中心真实 ScrollView 仍保持原有
/// edge-to-edge 几何并自行承担系统 scroll-edge effect。
@available(macOS 26.0, *)
struct WorkPiNativeWorkspaceSplitView: NSViewControllerRepresentable {
    let session: PiSessionController
    let layoutState: WorkPiLayoutState
    let isFileSelected: Bool
    let inspectorDetached: Bool
    let onToggleInspectorDetached: () -> Void
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    /// 必须作为参数传入而不是只读 layoutState：SwiftUI 靠参数变化决定是否调用
    /// updateNSViewController，只在内部读取的话状态变了也不会触发更新。
    let inspectorWidth: CGFloat
    let inspectorMaximized: Bool
    let language: WorkPiInterfaceLanguage
    let theme: WorkPiTheme
    let sidebarTint: WorkPiPaneTint
    let inspectorTint: WorkPiPaneTint

    init(
        session: PiSessionController,
        layoutState: WorkPiLayoutState,
        isFileSelected: Bool,
        inspectorDetached: Bool = false,
        onToggleInspectorDetached: @escaping () -> Void = {},
        sidebarVisible: Bool,
        sidebarWidth: CGFloat,
        inspectorWidth: CGFloat,
        inspectorMaximized: Bool,
        language: WorkPiInterfaceLanguage,
        theme: WorkPiTheme = .default,
        sidebarTint: WorkPiPaneTint = .purple,
        inspectorTint: WorkPiPaneTint = .purple
    ) {
        self.session = session
        self.layoutState = layoutState
        self.isFileSelected = isFileSelected
        self.inspectorDetached = inspectorDetached
        self.onToggleInspectorDetached = onToggleInspectorDetached
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
        self.inspectorWidth = inspectorWidth
        self.inspectorMaximized = inspectorMaximized
        self.language = language
        self.theme = theme
        self.sidebarTint = sidebarTint
        self.inspectorTint = inspectorTint
    }

    func makeNSViewController(context: Context) -> WorkPiWorkspaceSplitViewController {
        WorkPiWorkspaceSplitViewController(
            session: session,
            layoutState: layoutState,
            isFileSelected: isFileSelected,
            inspectorDetached: inspectorDetached,
            onToggleInspectorDetached: onToggleInspectorDetached,
            sidebarVisible: sidebarVisible,
            sidebarWidth: sidebarWidth,
            inspectorWidth: inspectorWidth,
            inspectorMaximized: inspectorMaximized,
            language: language,
            theme: theme,
            sidebarTint: sidebarTint,
            inspectorTint: inspectorTint
        )
    }

    func updateNSViewController(
        _ nsViewController: WorkPiWorkspaceSplitViewController,
        context: Context
    ) {
        nsViewController.update(
            isFileSelected: isFileSelected,
            inspectorDetached: inspectorDetached,
            onToggleInspectorDetached: onToggleInspectorDetached,
            sidebarVisible: sidebarVisible,
            sidebarWidth: sidebarWidth,
            inspectorWidth: inspectorWidth,
            inspectorMaximized: inspectorMaximized,
            language: language,
            theme: theme,
            sidebarTint: sidebarTint,
            inspectorTint: inspectorTint
        )
    }

    /// 直接接受 SwiftUI 提议的尺寸，不让 AppKit 的固有尺寸参与协商。
    ///
    /// 不实现这个方法时，`NSSplitViewController` 嵌在 `NSHostingView` 里的
    /// divider 拖动是坏的。用最小复现（原生 NSSplitViewController + 空白
    /// NSViewControllerRepresentable，不含任何 WorkPi 代码）实测到两种表现：
    ///
    ///     无 .frame 约束： window 1440->1280  inspector 不动
    ///     有 .frame 约束： window 不变      inspector 412->425  sidebar 306->301
    ///
    /// 前者是拖动被当成缩窗口，后者正是用户报告的“拖右边界却动左栏、
    /// 右栏几乎不动”。根因是 SwiftUI 会反复向 hosting 层询问固有尺寸，而
    /// NSSplitView 在拖动跟踪循环中的中间态会被当成“理想尺寸”回流。
    ///
    /// 只要把 proposal 原样返回，拖动立即恢复正常（inspector 412->572，
    /// sidebar 纹丝不动）。对照实验见 `WorkPiHostingSizingContractTests`。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: WorkPiWorkspaceSplitViewController,
        context: Context
    ) -> CGSize? {
        // 拿不到提议时给一个不小于窗口最小内容宽度的兼容值。
        CGSize(
            width: proposal.width ?? 980,
            height: proposal.height ?? 620
        )
    }
}
