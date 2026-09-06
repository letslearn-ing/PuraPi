import AppKit
import PiDomain
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class WorkPiWorkspaceSplitViewController: NSSplitViewController {
    let session: PiSessionController
    let layoutState: WorkPiLayoutState
    var isFileSelected: Bool
    var inspectorDetached: Bool
    var onToggleInspectorDetached: () -> Void
    var sidebarVisible: Bool
    var sidebarWidth: CGFloat
    var inspectorWidth: CGFloat
    var language: WorkPiInterfaceLanguage
    var theme: WorkPiTheme
    var sidebarTint: WorkPiPaneTint
    var inspectorTint: WorkPiPaneTint
    var lastAppliedSidebarWidth: CGFloat?
    var lastAppliedInspectorWidth: CGFloat?
    var lastAppliedInspectorMaximized: Bool?
    /// 拖动停下后才提交宽度的延迟任务。两栏共用一个：用户一次只能拖
    /// 一条分隔线，而且提交逻辑本身会把两侧待处理值一起落盘。
    var dragSettleTask: Task<Void, Never>?

    var sidebarController: NSHostingController<WorkPiNativeSidebarHostView>!
    var conversationController: WorkPiNativeConversationPaneController!
    var sidebarItem: NSSplitViewItem!
    var workspaceItem: NSSplitViewItem!
    var inspectorController: NSHostingController<WorkPiInspectorHostView>?
    /// 包裹 hosting view 的普通容器，用于隔离 SwiftUI 的固定尺寸约束。
    var inspectorContainer: NSViewController?
    var inspectorItem: NSSplitViewItem?
    var pendingMeasuredSidebarWidth: CGFloat?
    var pendingMeasuredInspectorWidth: CGFloat?
    var lastAppliedConversationLeadingContentInset: CGFloat?
    /// 用户正在拖动分隔线。期间不允许任何代码路径回写或 setPosition，
    /// 否则迷到的 update 会拿旧宽度把分隔线拽回去。
    var isUserDraggingDivider = false
    /// 正在由代码设置分栏位置，期间忽略 resize 回调以打断回路。
    /// Sidebar 与 Inspector 共用这一个闸门：任何一侧的 setPosition 都会触发
    /// 同一个 splitViewDidResizeSubviews，两侧的测量都必须在此期间静音。
    var isApplyingPaneGeometry = false
    /// 覆盖在分隔线命中区上、用于禁止窗口拖拽的透明层。
    weak var dividerWindowDragBlocker: WorkPiDividerWindowDragBlocker?
    /// 覆盖 AppKit 在旧 pane divider 位置绘制的圆形 grabber，不参与事件。
    weak var dividerVisualMask: WorkPiDividerVisualMask?
    /// 位于 splitView 父视图上的 Inspector 标题按钮命中层；不覆盖正文滚动区域。
    weak var inspectorHeaderInteractionView: WorkPiInspectorHeaderInteractionView?
    /// 独立/挂回按钮使用单独的命中层，以保持原有三按钮代理的几何契约。
    weak var inspectorDetachInteractionView: WorkPiInspectorDetachInteractionView?
    /// Inspector 的表面由独立 native controller 的背景 hosting view 绘制；这里仅管理栏位几何。

    init(
        session: PiSessionController,
        layoutState: WorkPiLayoutState,
        isFileSelected: Bool,
        inspectorDetached: Bool = false,
        onToggleInspectorDetached: @escaping () -> Void = {},
        sidebarVisible: Bool,
        sidebarWidth: CGFloat,
        inspectorWidth: CGFloat,
        inspectorMaximized: Bool = false,
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
        self.lastAppliedInspectorMaximized = inspectorMaximized
        self.language = language
        self.theme = theme
        self.sidebarTint = sidebarTint
        self.inspectorTint = inspectorTint
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        dragSettleTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        // `.thick` 的默认 divider 颜色是透明，但仍保留 AppKit 的几何和拖动跟踪；
        // 这样 Inspector 圆角表面的左边缘是唯一可见分界，不依赖私有 divider 视图。
        splitView.dividerStyle = .thick
        splitView.delegate = self
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor

        sidebarController = NSHostingController(
            rootView: WorkPiNativeSidebarHostView(
                session: session,
                layoutState: layoutState,
                language: language,
                theme: theme,
                sidebarTint: sidebarTint
            )
        )
        // Sidebar 宽度由 NSSplitView divider（分隔线）控制。不能把托管的
        // NSHostingController 视图设为 required hugging/compression，否则
        // SwiftUI 的固有宽度会把 divider 拖动立即弹回原位置。
        sidebarController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebarController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 允许 Sidebar item 覆盖 full-size content view；外层系统表面从窗口顶部
        // 连续延伸，文件树内容表面与 item 内容边界对齐并只保留交通灯安全区。
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = WorkPiLayoutState.minimumSidebarWidth + sidebarSlotPadding
        sidebarItem.maximumThickness = WorkPiLayoutState.maximumSidebarWidth + sidebarSlotPadding
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        // Sidebar 最不愿改变尺寸。数值必须落在 AppKit 分栏区间（250 附近）：
        // 用 .defaultHigh(750) 会让它完全不可压缩，导致两条分隔线都拖不动。
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 262)
        sidebarItem.isCollapsed = !sidebarVisible
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.automaticallyAdjustsSafeAreaInsets = false

        conversationController = WorkPiNativeConversationPaneController(
            session: session,
            isFileSelected: isFileSelected,
            language: language,
            theme: theme,
            leadingContentInset: conversationLeadingContentInset
        )
        lastAppliedConversationLeadingContentInset = conversationLeadingContentInset
        conversationController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        conversationController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceItem = NSSplitViewItem(viewController: conversationController)
        // 工作区是唯一应该吸收拖动的栏，因此优先级最低。
        workspaceItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        workspaceItem.minimumThickness = 420
        workspaceItem.titlebarSeparatorStyle = .none
        workspaceItem.automaticallyAdjustsSafeAreaInsets = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(workspaceItem)

        if isFileSelected, !inspectorDetached {
            installInspector()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applySidebarGeometry()
            self.applyInspectorMaximizedState()
            self.updateInspectorThicknessLimit()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        dragSettleTask?.cancel()
        dragSettleTask = nil
        inspectorHeaderInteractionView?.removeFromSuperview()
        inspectorHeaderInteractionView = nil
        inspectorDetachInteractionView?.removeFromSuperview()
        inspectorDetachInteractionView = nil
    }

    /// 窗口尺寸、Sidebar 宽度、折叠状态任一变化都会走到这里，
    /// 因此把 Inspector 上限的重算和阻挡视图的对位都挂在这个统一入口上。
    override func viewDidLayout() {
        super.viewDidLayout()
        updateInspectorThicknessLimit()
        // 覆盖层需要 splitView 已有父视图，viewDidLoad 阶段还没有。
        installDividerVisualMask()
        installDividerWindowDragBlocker()
        updateConversationLeadingContentInset()
        // `.thick` 会让 divider 基础线透明，但 macOS 26 的辅助 divider view
        // 仍可能绘制一个圆形 grabber。按“非 arranged pane、全高、窄宽”识别并
        // 隐藏它；不依赖 AppKit 内部类名，也不影响命中几何。
        let dividerWidth = splitView.dividerThickness
        for subview in splitView.subviews
            where !splitView.arrangedSubviews.contains(where: { $0 === subview })
                && subview.frame.height >= splitView.bounds.height - 1
                && subview.frame.width <= dividerWidth + 1 {
            subview.alphaValue = 0
            subview.layer?.opacity = 0
        }
        installInspectorHeaderInteractionView()
    }

    func update(
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
        _ = inspectorMaximized
        let fileSelectionChanged = self.isFileSelected != isFileSelected
        let inspectorPresentationChanged = self.inspectorDetached != inspectorDetached
        let languageChanged = self.language != language
        let sidebarVisibilityChanged = self.sidebarVisible != sidebarVisible
        let sidebarWidthChanged = abs(self.sidebarWidth - sidebarWidth) > 0.5
        let inspectorWidthChanged = abs(self.inspectorWidth - inspectorWidth) > 0.5
        let inspectorMaximizedChanged = lastAppliedInspectorMaximized != inspectorMaximized
        let themeChanged = self.theme != theme
        self.isFileSelected = isFileSelected
        self.inspectorDetached = inspectorDetached
        self.onToggleInspectorDetached = onToggleInspectorDetached
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
        self.inspectorWidth = inspectorWidth
        self.language = language
        self.theme = theme
        let sidebarTintChanged = self.sidebarTint != sidebarTint
        let inspectorTintChanged = self.inspectorTint != inspectorTint
        self.sidebarTint = sidebarTint
        self.inspectorTint = inspectorTint

        guard isViewLoaded else { return }

        // 用 animator 代理而不是直接赋值：直接设 isCollapsed 是瞬间跳变，
        // 折叠开关与标签胶囊会突然弹到新位置。animator 让 AppKit 平滑过渡，
        // 排在 `.sidebarTrackingSeparator` 之前的工具栏项随之平移。
        if sidebarItem.isCollapsed != !sidebarVisible {
            sidebarItem.animator().isCollapsed = !sidebarVisible
        }
        // 外观/语言变化不会改变分隔线几何；只在几何输入真的变化时回写，
        // 避免用户刚完成拖动后被一次无关的 tint 更新重新触发 setPosition。
        let shouldReconcileGeometry = fileSelectionChanged
            || inspectorPresentationChanged
            || sidebarVisibilityChanged
            || sidebarWidthChanged
            || inspectorWidthChanged
            || inspectorMaximizedChanged
        if shouldReconcileGeometry {
            applyInspectorMaximizedState()
            if abs(sidebarWidth - (lastAppliedSidebarWidth ?? -1)) > 0.5 {
                applySidebarGeometry()
            }
            if abs(inspectorWidth - (lastAppliedInspectorWidth ?? -1)) > 0.5 {
                applyInspectorGeometry()
            }
            lastAppliedInspectorMaximized = inspectorMaximized
        }

        if fileSelectionChanged
            || inspectorPresentationChanged
            || languageChanged
            || sidebarVisibilityChanged
            || themeChanged {
            conversationController.update(
                isFileSelected: isFileSelected,
                language: language,
                theme: theme,
                leadingContentInset: conversationLeadingContentInset
            )
            lastAppliedConversationLeadingContentInset = conversationLeadingContentInset
        }

        if languageChanged || sidebarTintChanged || themeChanged {
            // Sidebar 的模式切换标签与颜色随状态变化。
            sidebarController.rootView = WorkPiNativeSidebarHostView(
                session: session,
                layoutState: layoutState,
                language: language,
                theme: theme,
                sidebarTint: sidebarTint
            )
        }

        if (inspectorTintChanged || languageChanged || themeChanged), let inspectorController {
            inspectorController.rootView = WorkPiInspectorHostView(
                session: session,
                layoutState: layoutState,
                language: language,
                theme: theme,
                inspectorTint: inspectorTint,
                isDetached: inspectorDetached,
                onToggleDetached: onToggleInspectorDetached
            )
        }

        if fileSelectionChanged || inspectorPresentationChanged {
            if isFileSelected, !inspectorDetached {
                installInspector()
            } else {
                removeInspector()
            }
        }
        installInspectorHeaderInteractionView()
    }

    /// 仅供诊断测试读取共享布局状态；生产代码不应依赖它。
    var diagnosticLayoutState: WorkPiLayoutState { layoutState }

    /// 当前 Inspector 外层 pane 的完整屏幕矩形。
    ///
    /// 分离窗口直接继承这个外层 frame；其内容宿主继续保留原来的内边距，
    /// 因此可见面板宽度和原栏位一致，且不会把标题栏高度重复计入内容区。
    func inspectorScreenFrame() -> NSRect? {
        guard let inspectorItem,
              let window = inspectorItem.viewController.view.window,
              inspectorItem.viewController.view.bounds.width > 0,
              inspectorItem.viewController.view.bounds.height > 0
        else { return nil }

        let pane = inspectorItem.viewController.view
        let paneInWindow = pane.convert(pane.bounds, to: nil)
        let paneOnScreen = window.convertToScreen(paneInWindow)
        guard paneOnScreen.width > 0, paneOnScreen.height > 0 else { return nil }
        return paneOnScreen
    }

    var sidebarSlotPadding: CGFloat {
        WorkPiLayoutState.sidebarInset * 2
    }

    /// Native Sidebar 的首条 divider 为 0pt，而 Inspector 的普通 `.thick` divider
    /// 与外层 inset 会让右侧可见间距多出这段距离。保留 Sidebar 完整表面，把差值
    /// 转移到中心内容的前导留白；不改变任何 pane 的真实宽度。
    var conversationLeadingContentInset: CGFloat {
        // 读取共享状态而不是当前的 `isCollapsed`：折叠/展开使用 animator，
        // 在动画开始瞬间 item 的旧值仍未更新，直接读取它会让中心内容错一帧。
        // Inspector 不存在时右侧没有对应的 divider/inset，不能给空工作区
        // 平白增加前导留白；使用目标状态而不是当前 item 动画状态。
        guard sidebarVisible, isFileSelected, !inspectorDetached else { return 0 }
        return WorkPiLayoutState.nativeSidebarCenterLeadingInset(
            for: splitView.dividerThickness
        )
    }

    func updateConversationLeadingContentInset() {
        guard conversationController != nil else { return }
        let inset = conversationLeadingContentInset
        guard abs((lastAppliedConversationLeadingContentInset ?? -.greatestFiniteMagnitude) - inset) > 0.5 else {
            return
        }
        conversationController.update(
            isFileSelected: isFileSelected,
            language: language,
            theme: theme,
            leadingContentInset: inset
        )
        lastAppliedConversationLeadingContentInset = inset
    }

    /// Inspector 栏位里被自绘悬浮表面吃掉的宽度。
    ///
    /// `layoutState.inspectorWidth` 表示表面内部的内容宽度；普通 item 的栏位还要
    /// 预留左右各一个 `inspectorInset`，因此这里必须取 `inset * 2`。
    var inspectorSlotPadding: CGFloat {
        WorkPiLayoutState.inspectorInset * 2
    }

    func applySidebarGeometry() {
        guard !isApplyingPaneGeometry, !isUserDraggingDivider else { return }
        guard !sidebarItem.isCollapsed,
              let sidebarIndex = splitViewItems.firstIndex(where: { $0 === sidebarItem }),
              sidebarIndex < splitViewItems.count - 1
        else { return }

        let desiredWidth = sidebarWidth + sidebarSlotPadding
        let currentWidth = sidebarItem.viewController.view.frame.width
        guard abs(currentWidth - desiredWidth) > 1 else {
            lastAppliedSidebarWidth = sidebarWidth
            return
        }

        isApplyingPaneGeometry = true
        splitView.setPosition(desiredWidth, ofDividerAt: sidebarIndex)
        isApplyingPaneGeometry = false
        lastAppliedSidebarWidth = sidebarWidth
        installDividerVisualMask()
    }

    /// 把 `layoutState.inspectorWidth` 落到右分隔线位置。
    ///
    /// Inspector 的栏位包含自绘表面两侧的 8pt padding，因此先把内容宽度换算成
    /// 栏位宽度，再从 splitView 右边界反推 divider 位置。
    func applyInspectorGeometry() {
        guard !isApplyingPaneGeometry, !isUserDraggingDivider else { return }
        // 最大化期间右分隔线由 applyInspectorMaximizedState 独占，不要互相打架。
        guard !layoutState.inspectorMaximized else { return }
        guard let inspectorItem,
              !inspectorItem.isCollapsed,
              let inspectorIndex = splitViewItems.firstIndex(where: { $0 === inspectorItem }),
              inspectorIndex > 0
        else { return }

        let desiredSlotWidth = inspectorWidth + inspectorSlotPadding
        let currentWidth = inspectorItem.viewController.view.frame.width
        guard abs(currentWidth - desiredSlotWidth) > 1 else {
            lastAppliedInspectorWidth = inspectorWidth
            return
        }

        let dividerPosition = splitView.bounds.width
            - desiredSlotWidth
            - splitView.dividerThickness
        isApplyingPaneGeometry = true
        splitView.setPosition(dividerPosition, ofDividerAt: inspectorIndex - 1)
        isApplyingPaneGeometry = false
        lastAppliedInspectorWidth = inspectorWidth
        installDividerVisualMask()
    }

    /// 在 splitView 父视图上安装 Inspector 顶部按钮的 AppKit 命中层。
    ///
    /// Inspector 的正文是 SwiftUI `ScrollView`，其桥接的 `NSScrollView` 可能覆盖
    /// 标题栏的内部命中树。代理只占据右上角操作按钮的矩形，空白处仍交回正文
    /// 和窗口拖动逻辑。
    func installInspectorHeaderInteractionView() {
        guard let parent = splitView.superview,
              let inspectorItem,
              !inspectorItem.isCollapsed,
              let inspectorIndex = splitViewItems.firstIndex(where: { $0 === inspectorItem }),
              splitView.arrangedSubviews.indices.contains(inspectorIndex)
        else {
            inspectorHeaderInteractionView?.removeFromSuperview()
            inspectorHeaderInteractionView = nil
            inspectorDetachInteractionView?.removeFromSuperview()
            inspectorDetachInteractionView = nil
            return
        }

        let pane = splitView.arrangedSubviews[inspectorIndex]
        guard pane.frame.width > 0,
              pane.frame.height > 0,
              splitView.bounds.width > 0,
              splitView.bounds.height > 0
        else {
            inspectorHeaderInteractionView?.removeFromSuperview()
            inspectorHeaderInteractionView = nil
            inspectorDetachInteractionView?.removeFromSuperview()
            inspectorDetachInteractionView = nil
            return
        }

        let headerHeight = WorkPiInspectorHeaderMetrics.totalHeight
        let rectInSplit: NSRect
        let surfaceRight = pane.frame.maxX - WorkPiLayoutState.inspectorInset
        let surfaceLeft = surfaceRight
            - WorkPiInspectorHeaderMetrics.trailingPadding
            - WorkPiInspectorHeaderMetrics.actionWidth
        if splitView.isFlipped {
            // NSSplitView 当前是 flipped：y=0 是视觉顶部。
            rectInSplit = NSRect(
                x: surfaceLeft,
                y: splitView.bounds.minY + WorkPiLayoutState.inspectorInset,
                width: WorkPiInspectorHeaderMetrics.actionWidth,
                height: headerHeight
            )
        } else {
            rectInSplit = NSRect(
                x: surfaceLeft,
                y: splitView.bounds.maxY
                    - WorkPiLayoutState.inspectorInset
                    - headerHeight,
                width: WorkPiInspectorHeaderMetrics.actionWidth,
                height: headerHeight
            )
        }
        let rectInParent = parent.convert(rectInSplit, from: splitView)

        let overlay: WorkPiInspectorHeaderInteractionView
        if let existing = inspectorHeaderInteractionView,
           existing.superview === parent {
            overlay = existing
        } else {
            inspectorHeaderInteractionView?.removeFromSuperview()
            let created = WorkPiInspectorHeaderInteractionView(frame: rectInParent)
            created.autoresizingMask = []
            parent.addSubview(created, positioned: .above, relativeTo: nil)
            inspectorHeaderInteractionView = created
            overlay = created
        }

        overlay.frame = rectInParent
        overlay.update(
            previewURL: session.selectedPreview?.url ?? session.selectedFileURL,
            showsFileActions: session.selectedPreview != nil || session.selectedFileURL != nil,
            language: language,
            isDetached: false,
            onToggleMaximize: { [weak self] in
                guard let self else { return }
                self.layoutState.inspectorMaximized.toggle()
                self.applyInspectorMaximizedState()
            },
            onToggleDetached: { [weak self] in
                self?.onToggleInspectorDetached()
            },
            onClose: { [weak self] in
                self?.session.clearFileSelection()
            },
            onReveal: { [weak self] url in
                self?.session.revealInFinder(url)
            },
            onOpen: { [weak self] url in
                self?.session.openWithDefaultApplication(url)
            },
            onCopyPath: { [weak self] url in
                self?.session.copyPath(url, relative: false)
            },
            onCopyRelativePath: { [weak self] url in
                self?.session.copyPath(url, relative: true)
            }
        )

        // 分隔线覆盖层不与按钮重叠，但将按钮保持在最上方可避免 AppKit
        // 重排时把代理压到 pane 或其他辅助视图之后。
        if parent.subviews.last !== overlay {
            parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        }

        // 独立按钮位于原有三按钮代理的左侧，视觉上与 SwiftUI 标题栏中的新按钮
        // 对齐；单独安装可避免改变既有按钮的命中和几何回归。
        let detachRectInSplit = NSRect(
            x: rectInSplit.minX
                - WorkPiInspectorHeaderMetrics.detachWidth
                - WorkPiInspectorHeaderMetrics.detachSpacing,
            y: rectInSplit.minY,
            width: WorkPiInspectorHeaderMetrics.detachWidth,
            height: rectInSplit.height
        )
        let detachRectInParent = parent.convert(detachRectInSplit, from: splitView)
        let detachOverlay: WorkPiInspectorDetachInteractionView
        if let existing = inspectorDetachInteractionView,
           existing.superview === parent {
            detachOverlay = existing
        } else {
            inspectorDetachInteractionView?.removeFromSuperview()
            let created = WorkPiInspectorDetachInteractionView(frame: detachRectInParent)
            created.autoresizingMask = []
            parent.addSubview(created, positioned: .above, relativeTo: nil)
            inspectorDetachInteractionView = created
            detachOverlay = created
        }
        detachOverlay.frame = detachRectInParent
        detachOverlay.update(
            showsFileActions: session.selectedPreview != nil || session.selectedFileURL != nil,
            isDetached: false,
            language: language,
            onToggleDetached: { [weak self] in
                self?.onToggleInspectorDetached()
            }
        )
        if parent.subviews.last !== detachOverlay {
            parent.addSubview(detachOverlay, positioned: .above, relativeTo: nil)
        }
    }

    func installInspector() {
        guard !inspectorDetached else { return }
        guard inspectorItem == nil else {
            inspectorItem?.isCollapsed = false
            // 表面由 Inspector 自己保留四边悬浮 padding，内容不额外下移。
            return
        }

        let controller = NSHostingController(
            rootView: WorkPiInspectorHostView(
                session: session,
                layoutState: layoutState,
                language: language,
                theme: theme,
                inspectorTint: inspectorTint,
                isDetached: false,
                onToggleDetached: onToggleInspectorDetached
            )
        )
        // Inspector 宽度必须由外层 divider 决定，因此切断 SwiftUI 的固有尺寸，
        // 避免其内部阅读内容把宽度约束传导到外层 split。
        controller.sizingOptions = []

        // 包一层普通 NSView：容器用 autoresizing 跟随栏位尺寸，外层圆角表面
        // 与滚动正文的系统边缘效果彼此隔离。
        let container = NSViewController()
        container.view = NSView(frame: .zero)
        container.addChild(controller)
        container.view.addSubview(controller.view)

        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.frame = container.view.bounds
        controller.view.autoresizingMask = [.width, .height]

        // Inspector 必须使用普通 item，而不是 `sidebarWithViewController:`。
        // 后者在 macOS 26 会创建系统 Sidebar 玻璃外壳；当用户先拖动分隔线、
        // 再切换 Inspector 外观时，该外壳会让同一 split 中心的 SwiftUI 合成层
        // 失效，表现为对话区消失。普通 item 将 Inspector 的材质隔离在自己的
        // 普通 item 不自带系统 Sidebar 外壳；native Inspector controller 的背景
        // hosting view 绘制同指标的悬浮圆角表面。
        let item = NSSplitViewItem(viewController: container)
        // 普通 item 不自带系统外壳；表面由 hosting view 保留四边悬浮间距。
        item.allowsFullHeightLayout = true
        // 右栏的显示由"是否选中文件"决定，不参与用户折叠。
        item.canCollapse = false
        // 高于工作区、低于 Sidebar：拖右分隔线时改变的是 Inspector 与工作区的
        // 比例，Sidebar 不参与。
        item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 261)
        item.minimumThickness = WorkPiLayoutState.minimumInspectorWidth + inspectorSlotPadding
        item.maximumThickness = WorkPiLayoutState.maximumInspectorWidth + inspectorSlotPadding
        item.titlebarSeparatorStyle = .none
        item.canCollapseFromWindowResize = false
        item.isCollapsed = false
        // 与 Sidebar 一致：安全区由内容自己控制，避免 AppKit 额外插入顶部留白。
        item.automaticallyAdjustsSafeAreaInsets = false

        inspectorController = controller
        inspectorContainer = container
        inspectorItem = item
        addSplitViewItem(item)

        // 立即强制布局一次。
        //
        // `addSplitViewItem` 后新栏的 frame 还是未布局的 `(0, 0, 280, 0)`，
        // 而分隔线命中判定靠 `arrangedSubviews` 的 frame 推算位置。不先布局的话，
        // 右分隔线在判定里"不存在"，于是：
        //
        //   打开文件 → 右栏展开 → 第一次拖右分隔线 → 命中判定为假
        //   → 窗口拖拽未被抑制 → 整个软件被拖着走
        //
        // 而一旦发生过任何一次布局（比如用户去拖了一下左栏），frame 就正常了，
        // 右栏也能拖了——这解释了“只有第一次不对”这个很突然的现象。
        splitView.layoutSubtreeIfNeeded()
        installDividerVisualMask()

        // 首次安装时把持久化的宽度落到 divider 上。延后一轮是必要的：
        // addSplitViewItem 后的同一轮里 splitView.bounds 还可能是旧值。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateInspectorThicknessLimit()
            self.lastAppliedInspectorWidth = nil
            self.applyInspectorGeometry()
            self.installDividerVisualMask()
        }
    }

    func removeInspector() {
        inspectorHeaderInteractionView?.removeFromSuperview()
        inspectorHeaderInteractionView = nil
        inspectorDetachInteractionView?.removeFromSuperview()
        inspectorDetachInteractionView = nil
        guard let item = inspectorItem else { return }
        removeSplitViewItem(item)
        inspectorItem = nil
        inspectorController = nil
        inspectorContainer = nil
        lastAppliedInspectorWidth = nil
        pendingMeasuredInspectorWidth = nil
        installDividerVisualMask()
    }
}
