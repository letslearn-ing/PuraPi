import AppKit
import SwiftUI

/// macOS 26.1 的公开 AppKit 滚动边缘容器。
///
/// `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle` 是 Apple
/// 给自定义 AppKit 滚动内容提供的正式入口：滚动视图必须是 item 的直接视图，顶部
/// accessory（附件）作为固定控件，系统才会创建真实的滚动边缘效果。
/// 这不是对私有类的依赖；生产代码只创建公开的 split item 和 accessory。
@available(macOS 26.1, *)
@MainActor
final class WorkPiNativeScrollEdgeContainerController: NSSplitViewController {
    let scrollView: NSScrollView
    private let scrollItem: NSSplitViewItem
    private var hasInstalledScrollEdgeAccessory = false

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        let contentController = NSViewController()
        contentController.view = scrollView
        scrollItem = NSSplitViewItem(viewController: contentController)
        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor

        scrollItem.allowsFullHeightLayout = true
        scrollItem.automaticallyAdjustsSafeAreaInsets = false
        scrollItem.titlebarSeparatorStyle = .none
        addSplitViewItem(scrollItem)
    }

    /// 等外层把容器放进真实 pane 并完成首次布局后再创建系统 pocket；否则
    /// AppKit 会按尚未确定的 0 宽度缓存 accessory 的横向范围。
    @discardableResult
    func installScrollEdgeAccessory() -> Bool {
        // 外层容器可能先布局 controller、后把它挂进 window；调用方负责在
        // window 生命周期稳定后重试。这里仅以两个直接视图的真实尺寸作为缓存条件，
        // 否则会得到 0 宽的永久系统效果。
        // 安装请求是幂等的：外层 viewport 会在每次 layout 后再次询问。
        // 已安装不代表“未准备好”，否则调用方会不断向主队列排队重试。
        if hasInstalledScrollEdgeAccessory {
            return true
        }
        guard splitView.bounds.width > 1,
              splitView.bounds.height > 1,
              scrollView.bounds.width > 1,
              scrollView.bounds.height > 1
        else { return false }
        hasInstalledScrollEdgeAccessory = true
        scrollItem.addTopAlignedAccessoryViewController(
            WorkPiNativeScrollEdgeAccessoryViewController(
                width: scrollView.bounds.width
            )
        )
        view.layoutSubtreeIfNeeded()
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@available(macOS 26.1, *)
@MainActor
private final class WorkPiNativeScrollEdgeAccessoryView: NSView {
    let height: CGFloat

    init(height: CGFloat, frame: NSRect) {
        self.height = height
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}

@available(macOS 26.1, *)
@MainActor
private final class WorkPiNativeScrollEdgeAccessoryViewController: NSSplitViewItemAccessoryViewController {
    init(width: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        // accessory 不占用 pane 的真实高度；系统仍会为其内部滚动内容创建 pocket。
        automaticallyAppliesContentInsets = false
        // 使用安装时真实滚动视图的宽度作为测量框；宽度为 1 会让系统把 pocket
        // 缓存成 0 宽，导致自定义 viewport 没有获得实际的顶部系统效果。
        let accessoryView = WorkPiNativeScrollEdgeAccessoryView(
            height: WorkPiTitlebarTabs.tabBarHeight,
            frame: NSRect(
                x: 0,
                y: 0,
                width: width,
                height: WorkPiTitlebarTabs.tabBarHeight
            )
        )
        accessoryView.wantsLayer = false
        accessoryView.setContentHuggingPriority(.required, for: .vertical)
        accessoryView.setContentCompressionResistancePriority(.required, for: .vertical)
        self.view = accessoryView
        preferredScrollEdgeEffectStyle = .soft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 在真正的 SwiftUI `ScrollView` 上启用 macOS 26 的系统顶部滚动边缘效果。
///
/// AppKit 自定义 `NSScrollView` 不能消费这个 SwiftUI modifier；那条路径由
/// `WorkPiScrollEdgeEffectView` 负责桥接。旧系统由显式 attachment 提供兼容效果。
extension View {
    @ViewBuilder
    func workPiTopScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func workPiSidebarScrollEdgeEffect(enabled: Bool) -> some View {
        if enabled {
            workPiTopScrollEdgeEffect()
        } else {
            self
        }
    }

    /// 明确请求顶部 soft effect。
    ///
    /// Apple 的滚动边缘效果只应出现在固定顶部控件与滚动内容的交界处；各调用方
    /// 只使用纵向阅读滚动轴，避免系统为无关方向推断额外效果。
    @ViewBuilder
    func workPiTopOnlyScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// 只在旧系统插入 AppKit fallback（降级实现）的零尺寸锚点。
///
/// macOS 26 由同一层级的公开 SwiftUI `scrollEdgeEffectStyle` 负责创建系统
/// 滚动边缘层；不能再叠加一个手工 `NSVisualEffectView`，否则会出现两层效果
/// 互相覆盖。旧系统没有该 API，才安装兼容适配器。
struct WorkPiLegacyScrollEdgeEffectMarker: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .frame(width: 0, height: 0)
        } else {
            WorkPiScrollEdgeEffectAttachment()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// 在不改变滚动视图自身配置的前提下，给一个 SwiftUI `ScrollView` 挂上
/// macOS 14–25 的 AppKit fallback（降级效果）。macOS 26 由 SwiftUI 的
/// `scrollEdgeEffectStyle` 或 AppKit 的公开 accessory API 负责；不会改动 content
/// inset、滚动条或文档尺寸。
struct WorkPiScrollEdgeEffectAttachment: NSViewRepresentable {
    var enabled: Bool = true

    func makeNSView(context: Context) -> WorkPiScrollEdgeEffectAttachmentView {
        WorkPiScrollEdgeEffectAttachmentView(enabled: enabled)
    }

    func updateNSView(
        _ nsView: WorkPiScrollEdgeEffectAttachmentView,
        context: Context
    ) {
        nsView.update(enabled: enabled)
    }

    static func dismantleNSView(
        _ nsView: WorkPiScrollEdgeEffectAttachmentView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

final class WorkPiScrollEdgeEffectAttachmentView: NSView {
    private var enabled: Bool
    private weak var attachedScrollView: NSScrollView?
    private var effectView: WorkPiScrollEdgeEffectView?
    private var attachAttempt = 0

    init(enabled: Bool) {
        self.enabled = enabled
        super.init(frame: .zero)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachWhenPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            attachWhenPossible()
        }
    }

    func update(enabled: Bool) {
        guard self.enabled != enabled else {
            attachWhenPossible()
            return
        }
        self.enabled = enabled
        if enabled {
            attachWhenPossible()
        } else {
            detach()
        }
    }

    func attachWhenPossible() {
        guard enabled, window != nil else { return }
        guard let scrollView = enclosingScrollView else {
            attachAttempt &+= 1
            guard attachAttempt <= 20 else { return }
            let attempt = attachAttempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self,
                      self.attachAttempt == attempt,
                      self.window != nil
                else { return }
                self.attachWhenPossible()
            }
            return
        }

        if attachedScrollView === scrollView, let effectView {
            effectView.updateFrame(for: scrollView)
            return
        }

        detach()
        attachedScrollView = scrollView
        let effect = WorkPiScrollEdgeEffectView()
        effect.autoresizingMask = [.width]
        effect.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.bounds.width,
            height: WorkPiScrollEdgeEffectView.height
        )
        scrollView.addFloatingSubview(effect, for: .vertical)
        effect.attach(to: scrollView)
        effectView = effect
        attachAttempt = 0
    }

    func detach() {
        attachAttempt &+= 1
        effectView?.detach()
        effectView?.removeFromSuperview()
        effectView = nil
        attachedScrollView = nil
    }
}

/// 配置 SwiftUI 内部真实 `NSScrollView`（AppKit 滚动视图）。
///
/// 中央工作区和 Sidebar 都使用真实 `NSScrollView`。这个桥接负责保留系统滚动器、
/// 配置标题栏内缩策略，以及在 SwiftUI 重建后恢复原始状态；需要时还会为 AppKit
/// 自定义 viewport 安装顶部滚动边缘效果。中心工作区在 macOS 26 保持
/// edge-to-edge 内容，效果层只采样滚动中的真实文本。
struct WorkPiScrollViewConfiguration: NSViewRepresentable {
    let managesTitlebarContentInsets: Bool
    let edgeToEdgeContent: Bool
    /// 是否为 AppKit 托管滚动视图安装顶部滚动边缘效果。
    let installsScrollEdgeEffect: Bool
    /// macOS 26 的自定义 AppKit viewport 也需要适配层；普通 SwiftUI
    /// ScrollView 则把效果交给公开的 SwiftUI modifier。
    let usesAppKitScrollEdgeEffect: Bool

    init(
        managesTitlebarContentInsets: Bool = false,
        edgeToEdgeContent: Bool = false,
        installsScrollEdgeEffect: Bool = false,
        usesAppKitScrollEdgeEffect: Bool = false
    ) {
        self.managesTitlebarContentInsets = managesTitlebarContentInsets
        self.edgeToEdgeContent = edgeToEdgeContent
        self.installsScrollEdgeEffect = installsScrollEdgeEffect
        self.usesAppKitScrollEdgeEffect = usesAppKitScrollEdgeEffect
    }

    func makeNSView(context: Context) -> WorkPiScrollViewConfigurationView {
        WorkPiScrollViewConfigurationView(
            managesTitlebarContentInsets: managesTitlebarContentInsets,
            edgeToEdgeContent: edgeToEdgeContent,
            installsScrollEdgeEffect: installsScrollEdgeEffect,
            usesAppKitScrollEdgeEffect: usesAppKitScrollEdgeEffect
        )
    }

    func updateNSView(
        _ nsView: WorkPiScrollViewConfigurationView,
        context: Context
    ) {
        nsView.update(
            managesTitlebarContentInsets: managesTitlebarContentInsets,
            edgeToEdgeContent: edgeToEdgeContent,
            installsScrollEdgeEffect: installsScrollEdgeEffect,
            usesAppKitScrollEdgeEffect: usesAppKitScrollEdgeEffect
        )
        nsView.attachWhenPossible()
    }

    static func dismantleNSView(
        _ nsView: WorkPiScrollViewConfigurationView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

final class WorkPiScrollViewConfigurationView: NSView {
    private var managesTitlebarContentInsets: Bool
    private var edgeToEdgeContent: Bool
    private var installsScrollEdgeEffect: Bool
    private var usesAppKitScrollEdgeEffect: Bool
    private weak var attachedScrollView: NSScrollView?
    private var attachAttempt = 0

    private var previousAutomaticallyAdjustsContentInsets = true
    private var previousContentInsets = NSEdgeInsetsZero
    private var previousScrollClipsToBounds = true
    private var previousContentClipsToBounds = true
    private var previousDrawsBackground = true
    private var previousBackgroundColor = NSColor.clear
    private var previousBorderType = NSBorderType.noBorder
    private var previousHasVerticalScroller = true
    private var previousHasHorizontalScroller = false
    private var previousScrollerStyle = NSScroller.Style.overlay
    private var previousVerticalScrollerAlpha: CGFloat = 1
    private var changedScrollViewState = false
    private var scrollEdgeEffect: WorkPiScrollEdgeEffectView?

    init(
        managesTitlebarContentInsets: Bool,
        edgeToEdgeContent: Bool,
        installsScrollEdgeEffect: Bool = false,
        usesAppKitScrollEdgeEffect: Bool = false
    ) {
        self.managesTitlebarContentInsets = managesTitlebarContentInsets
        self.edgeToEdgeContent = edgeToEdgeContent
        self.installsScrollEdgeEffect = installsScrollEdgeEffect
        self.usesAppKitScrollEdgeEffect = usesAppKitScrollEdgeEffect
        super.init(frame: .zero)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachWhenPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            attachWhenPossible()
        }
    }

    func update(
        managesTitlebarContentInsets: Bool,
        edgeToEdgeContent: Bool,
        installsScrollEdgeEffect: Bool,
        usesAppKitScrollEdgeEffect: Bool
    ) {
        guard self.managesTitlebarContentInsets != managesTitlebarContentInsets
            || self.edgeToEdgeContent != edgeToEdgeContent
            || self.installsScrollEdgeEffect != installsScrollEdgeEffect
            || self.usesAppKitScrollEdgeEffect != usesAppKitScrollEdgeEffect
        else { return }
        self.managesTitlebarContentInsets = managesTitlebarContentInsets
        self.edgeToEdgeContent = edgeToEdgeContent
        self.installsScrollEdgeEffect = installsScrollEdgeEffect
        self.usesAppKitScrollEdgeEffect = usesAppKitScrollEdgeEffect

        guard let attachedScrollView else { return }
        restoreScrollViewState(attachedScrollView)
        configure(attachedScrollView)
    }

    func attachWhenPossible() {
        guard window != nil else { return }
        if attachToEnclosingScrollView() { return }

        attachAttempt &+= 1
        guard attachAttempt <= 20 else { return }
        let attempt = attachAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self,
                  self.attachAttempt == attempt,
                  self.window != nil
            else { return }
            self.attachWhenPossible()
        }
    }

    @discardableResult
    private func attachToEnclosingScrollView() -> Bool {
        guard let scrollView = enclosingScrollView else { return false }
        if attachedScrollView === scrollView {
            installScrollEdgeEffectIfNeeded(on: scrollView)
            return true
        }

        detach()
        attachedScrollView = scrollView
        previousAutomaticallyAdjustsContentInsets = scrollView.automaticallyAdjustsContentInsets
        previousContentInsets = scrollView.contentInsets
        previousScrollClipsToBounds = scrollView.clipsToBounds
        previousContentClipsToBounds = scrollView.contentView.clipsToBounds
        previousDrawsBackground = scrollView.drawsBackground
        previousBackgroundColor = scrollView.backgroundColor
        previousBorderType = scrollView.borderType
        previousHasVerticalScroller = scrollView.hasVerticalScroller
        previousHasHorizontalScroller = scrollView.hasHorizontalScroller
        previousScrollerStyle = scrollView.scrollerStyle
        previousVerticalScrollerAlpha = scrollView.verticalScroller?.alphaValue ?? 1

        configure(scrollView)
        attachAttempt = 0
        return true
    }

    private func configure(_ scrollView: NSScrollView) {
        changedScrollViewState = true

        if #available(macOS 26.0, *), edgeToEdgeContent {
            // 中心工作区和原生 Sidebar 都让真实内容延伸到顶部，交给系统边缘效果
            // 采样内容；不额外插入顶部占位。
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
        } else if managesTitlebarContentInsets {
            // macOS 14–25 的中心兼容路径保留自动标题栏内缩，并叠加语义化
            // WorkPiScrollEdgeEffectView。
            scrollView.automaticallyAdjustsContentInsets = true
        } else {
            // 旧系统 Sidebar 的交通灯安全区由外层内容布局提供。
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
        }

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // 保留真实 vertical overlay scroller。macOS 26 的 scroll-edge effect 依赖
        // 这个系统滚动器；不能用 `.scrollIndicators(.hidden)` 把它从层级中移除。
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        if #available(macOS 26.0, *), edgeToEdgeContent {
            // 仅 macOS 26 允许顶部系统 edge effect 在滚动视口边缘采样真实
            // document content；保留 overlay scroller，不用 `.scrollIndicators(.hidden)`。
            scrollView.clipsToBounds = false
            scrollView.contentView.clipsToBounds = false
        } else {
            // macOS 14–25 的语义材质 fallback 仍使用传统裁剪边界。
            scrollView.clipsToBounds = true
            scrollView.contentView.clipsToBounds = true
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.needsLayout = true
        installScrollEdgeEffectIfNeeded(on: scrollView)
    }

    private func installScrollEdgeEffectIfNeeded(on scrollView: NSScrollView) {
        let shouldInstall: Bool
        if #available(macOS 26.0, *) {
            // SwiftUI 自己创建的 ScrollView 使用系统 modifier；macOS 26.1+ 的中心
            // 自定义 viewport 使用公开 split accessory，不在这里再叠加 fallback。
            shouldInstall = installsScrollEdgeEffect && usesAppKitScrollEdgeEffect
        } else {
            // 旧系统没有公开 SwiftUI edge-effect API，所有显式请求以及原有
            // 中心标题栏内缩路径都使用语义化 NSVisualEffectView fallback。
            shouldInstall = installsScrollEdgeEffect || managesTitlebarContentInsets
        }

        guard shouldInstall else {
            detachScrollEdgeEffect()
            return
        }

        if let scrollEdgeEffect {
            scrollEdgeEffect.updateFrame(for: scrollView)
            return
        }

        let effect = WorkPiScrollEdgeEffectView()
        effect.autoresizingMask = [.width]
        effect.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.bounds.width,
            height: WorkPiScrollEdgeEffectView.height
        )
        scrollView.addFloatingSubview(effect, for: .vertical)
        effect.attach(to: scrollView)
        scrollEdgeEffect = effect
    }

    private func detachScrollEdgeEffect() {
        scrollEdgeEffect?.detach()
        scrollEdgeEffect?.removeFromSuperview()
        scrollEdgeEffect = nil
    }

    private func restoreScrollViewState(_ scrollView: NSScrollView) {
        detachScrollEdgeEffect()
        guard changedScrollViewState else { return }

        scrollView.automaticallyAdjustsContentInsets = previousAutomaticallyAdjustsContentInsets
        scrollView.contentInsets = previousContentInsets
        scrollView.clipsToBounds = previousScrollClipsToBounds
        scrollView.contentView.clipsToBounds = previousContentClipsToBounds
        scrollView.drawsBackground = previousDrawsBackground
        scrollView.backgroundColor = previousBackgroundColor
        scrollView.borderType = previousBorderType
        scrollView.hasVerticalScroller = previousHasVerticalScroller
        scrollView.hasHorizontalScroller = previousHasHorizontalScroller
        scrollView.scrollerStyle = previousScrollerStyle
        scrollView.verticalScroller?.alphaValue = previousVerticalScrollerAlpha
        changedScrollViewState = false
    }

    func detach() {
        attachAttempt &+= 1
        guard let scrollView = attachedScrollView else { return }
        restoreScrollViewState(scrollView)
        attachedScrollView = nil
    }
}

/// 空工作区的两个主要项目入口。玻璃表面、命中区域和交互反馈属于同一个
/// `Button`，因此卡片留白也可点击，键盘与辅助功能语义仍由系统按钮提供。
struct WorkPiEmptyActionButton: View {
    @Environment(\.workPiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
            style: .continuous
        )
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // 明确覆盖整张卡片，避免只有图标和文字参与命中测试。
                Color.clear

                VStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .medium))
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 132, height: 132)
            .contentShape(.interaction, shape)
        }
        .buttonStyle(
            WorkPiEmptyActionButtonStyle(
                prominent: prominent,
                isHovering: isHovering,
                accent: theme.accent,
                cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                reduceMotion: reduceMotion,
                highlightColor: theme.windowBackground,
                pressedColor: theme.workspaceBackground,
                borderColor: theme.hairline,
                shadowColor: Color(nsColor: .shadowColor)
            )
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(title)
    }
}

private struct WorkPiEmptyActionButtonStyle: ButtonStyle {
    let prominent: Bool
    let isHovering: Bool
    let accent: Color
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    let highlightColor: Color
    let pressedColor: Color
    let borderColor: Color
    let shadowColor: Color

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.primary : Color.secondary)
            .workPiGlassSurface(
                role: .glass,
                cornerRadius: cornerRadius,
                interactive: true,
                tint: prominent ? accent.opacity(0.18) : nil
            )
            .overlay {
                shape
                    .fill(highlightColor.opacity(isHovering ? 0.075 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .fill(pressedColor.opacity(configuration.isPressed ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(
                        borderColor.opacity(isHovering ? 0.28 : 0.1),
                        lineWidth: isHovering ? 0.9 : 0.5
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: shadowColor.opacity(
                    configuration.isPressed ? 0.08 : (isHovering ? 0.2 : 0.1)
                ),
                radius: configuration.isPressed ? 4 : (isHovering ? 13 : 7),
                y: configuration.isPressed ? 2 : (isHovering ? 8 : 4)
            )
            .scaleEffect(
                reduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.965 : (isHovering ? 1.018 : 1))
            )
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1 : (isHovering ? -2 : 0)))
            .contentShape(.interaction, shape)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: configuration.isPressed)
    }
}
