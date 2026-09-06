import AppKit
import Foundation

@available(macOS 26.0, *)
@MainActor
extension WorkPiWorkspaceSplitViewController {
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        // NSSplitViewController 要求子类实现 resize callback 时继续调用
        // super；否则 AppKit 可能不完成托管 pane 的约束布局。
        super.splitViewDidResizeSubviews(notification)

        // 自己调用 setPosition 引发的回调必须忽略，否则形成回路：
        // setPosition → didResize → 回写 @Published → update → setPosition。
        guard !isApplyingPaneGeometry else { return }

        // 拖动 Sidebar 会改变留给 Inspector 的余量，因此每次都要重算上限。
        updateInspectorThicknessLimit()
        installDividerVisualMask()

        // AppKit 在 userInfo 里说明了「哪条分隔线动了」和「是不是显式的位置变更」。
        // 之前两个信息都被忽略，于是每次通知都同时测量两栏，产生两个 bug：
        //
        // 1. 拖右分隔线时也去测量 Sidebar。窗口初次布局阶段 Sidebar 的 frame 还停在
        //    minimumThickness，这个瞬态被异步回写晚一步落到共享状态上，于是每次
        //    都把 sidebarWidth 削掉一个 sidebarSlotPadding——用户看到的
        //    「拖右边界左栏跟着缩」。
        // 2. 初始布局/窗口缩放这类非用户操作也被当成用户偏好写回并持久化。
        let userInfo = notification.userInfo
        guard userInfo?[Self.splitViewUserResizeKey] != nil else { return }
        guard let dividerIndex = userInfo?[Self.splitViewDividerIndexKey] as? Int else { return }

        if dividerIndex == sidebarDividerIndex {
            measureSidebarWidth()
        } else if let inspectorItem,
                  let inspectorIndex = splitViewItems.firstIndex(where: { $0 === inspectorItem }),
                  dividerIndex == inspectorIndex - 1 {
            measureInspectorWidth()
        }
    }

    /// AppKit 私有约定的 userInfo 键名。它们不在公开头文件里，但从 10.5 起稳定，
    /// 且这里的用法是「读到就用、读不到就退回不测量」，键名变化只会退化成
    /// 「拖动不再回写宽度」，不会造成布局错乱。
    static let splitViewDividerIndexKey = "NSSplitViewDividerIndex"
    static let splitViewUserResizeKey = "NSSplitViewUserResizeKey"

    func measureSidebarWidth() {
        guard let sidebarItem,
              !sidebarItem.isCollapsed,
              sidebarItem.viewController.view.window != nil
        else { return }

        let measuredWidth = sidebarItem.viewController.view.frame.width - sidebarSlotPadding
        let clampedWidth = min(
            max(measuredWidth, WorkPiLayoutState.minimumSidebarWidth),
            WorkPiLayoutState.maximumSidebarWidth
        )
        guard abs(clampedWidth - layoutState.sidebarWidth) > 0.5 else { return }

        pendingMeasuredSidebarWidth = clampedWidth
        scheduleDragSettle()
    }

    /// 与 `measureSidebarWidth` 完全对称。
    func measureInspectorWidth() {
        guard let inspectorItem,
              !inspectorItem.isCollapsed,
              inspectorItem.viewController.view.window != nil,
              // 最大化是临时模式，不该把被拉宽的尺寸当成用户首选写回去。
              !layoutState.inspectorMaximized
        else { return }

        let measuredWidth = inspectorItem.viewController.view.frame.width
            - inspectorSlotPadding
        let clampedWidth = min(
            max(measuredWidth, WorkPiLayoutState.minimumInspectorWidth),
            WorkPiLayoutState.maximumInspectorWidth
        )
        guard abs(clampedWidth - layoutState.inspectorWidth) > 0.5 else { return }

        pendingMeasuredInspectorWidth = clampedWidth
        scheduleDragSettle()
    }

    /// 拖动期间不回写 `@Published`，只在停下来之后提交一次。
    ///
    /// 这一点是「拖动不顺滑」的根因：原来每一帧都发布一次宽度，SwiftUI 随之重算
    /// 整个工作区（包括 Inspector 里的 Markdown/代码渲染），拖动手感自然发涩。
    /// 而拖动过程中的视觉宽度本来就由 AppKit 直接驱动，不需要经过我们的状态。
    func scheduleDragSettle() {
        isUserDraggingDivider = true
        dragSettleTask?.cancel()
        dragSettleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard let self else { return }
            self.dragSettleTask = nil
            self.isUserDraggingDivider = false
            self.commitMeasuredPaneWidths()
        }
    }

    func commitMeasuredPaneWidths() {
        if let width = pendingMeasuredSidebarWidth {
            pendingMeasuredSidebarWidth = nil
            if abs(width - layoutState.sidebarWidth) > 0.5 {
                // 先记下已应用值，避免回写触发的 update 又把同一个宽度 setPosition 一遍。
                lastAppliedSidebarWidth = width
                layoutState.resizeSidebar(to: width)
                layoutState.persistSidebarWidth()
            }
        }

        if let width = pendingMeasuredInspectorWidth {
            pendingMeasuredInspectorWidth = nil
            if abs(width - layoutState.inspectorWidth) > 0.5 {
                lastAppliedInspectorWidth = width
                layoutState.resizeInspector(to: width)
                layoutState.persistInspectorWidth()
            }
        }
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let baseRect = super.splitView(
            splitView,
            effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect,
            ofDividerAt: dividerIndex
        )
        guard isResizableDividerIndex(dividerIndex) else { return baseRect }
        // 将 AppKit 的拖动命中区从 pane 几何 divider 移到悬浮圆角表面的可见边缘。
        // 只返回新位置，不能与 baseRect 合并，否则用户仍会在空隙中的旧位置抓到。
        let alignedRect = visibleDividerHitRect(at: dividerIndex, in: splitView)
        return alignedRect
            ?? baseRect
            .insetBy(
                dx: splitView.isVertical ? -Self.dividerHitMargin : 0,
                dy: splitView.isVertical ? 0 : -Self.dividerHitMargin
            )
    }

    override func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        guard isResizableDividerIndex(dividerIndex) else {
            return super.splitView(
                splitView,
                additionalEffectiveRectOfDividerAt: dividerIndex
            )
        }
        // `effectiveRect` 已经移动到可见边缘；这里返回同一个矩形，确保 AppKit
        // 不会额外保留 pane 几何 divider 的命中区。
        return visibleDividerHitRect(at: dividerIndex, in: splitView) ?? .zero
    }

    /// 各条可拖动分隔线的命中区矩形（splitView 坐标系）。
    ///
    /// 分隔线的真实几何取"左栏 maxX 到右栏 minX"。不能只用 `dividerThickness` 推算：
    /// AppKit 的透明 divider 可能有独立的跟踪宽度，左右 pane 的可见边缘才是用户
    /// 实际按下的位置。
    ///
    /// 宽度额外 +1：`NSRect.contains` 对 maxX 是开区间，恰好等于 maxX 的点会被
    /// 判为区外，于是 +margin 那一端漏掉。
    fileprivate func dividerHitRects() -> [NSRect] {
        let panes = splitView.arrangedSubviews
        guard panes.count > 1 else { return [] }

        var rects: [NSRect] = []
        for index in 0..<(panes.count - 1) {
            guard isResizableDividerIndex(index) else { continue }

            // 命中区必须以**悬浮栏自身的可见边缘**为中心，而不是以两 pane
            // 几何边界之间的空隙中点为中心。后者正是用户截图中箭头所指的位置。
            guard let rect = visibleDividerHitRect(at: index, in: splitView) else {
                continue
            }
            rects.append(rect)
        }
        return rects
    }

    /// 生成以悬浮栏可见边缘为中心的拖动命中矩形。
    ///
    /// Sidebar 使用它的可见右边缘，Inspector 使用它的可见左边缘；这样命中区
    /// 与用户看到的圆角矩形边缘重合，而不会停在 pane divider 与表面之间的空隙。
    func visibleDividerHitRect(at dividerIndex: Int, in splitView: NSSplitView) -> NSRect? {
        let panes = splitView.arrangedSubviews
        guard panes.indices.contains(dividerIndex),
              panes.indices.contains(dividerIndex + 1)
        else { return nil }

        let leadingPane = panes[dividerIndex]
        let trailingPane = panes[dividerIndex + 1]
        let edge: CGFloat
        if splitView.isVertical {
            if splitViewItems.indices.contains(dividerIndex),
               splitViewItems[dividerIndex] === sidebarItem {
                // Sidebar 保留完整可见表面；中心内容的前导留白负责对称间距，
                // 因此拖动命中中心就是真实 pane 边界，不再落在被裁掉的区域。
                edge = leadingPane.frame.maxX
            } else if splitViewItems.indices.contains(dividerIndex + 1),
                      splitViewItems[dividerIndex + 1] === inspectorItem {
                edge = trailingPane.frame.minX + visibleInset(ofPaneAt: dividerIndex + 1)
            } else {
                edge = (leadingPane.frame.maxX + trailingPane.frame.minX) / 2
            }
            return NSRect(
                x: edge - Self.dividerHitMargin,
                y: splitView.bounds.minY,
                width: Self.dividerHitMargin * 2 + 1,
                height: splitView.bounds.height
            )
        }

        if splitViewItems.indices.contains(dividerIndex),
           splitViewItems[dividerIndex] === sidebarItem {
            edge = leadingPane.frame.maxY - visibleInset(ofPaneAt: dividerIndex)
        } else if splitViewItems.indices.contains(dividerIndex + 1),
                  splitViewItems[dividerIndex + 1] === inspectorItem {
            edge = trailingPane.frame.minY + visibleInset(ofPaneAt: dividerIndex + 1)
        } else {
            edge = (leadingPane.frame.maxY + trailingPane.frame.minY) / 2
        }
        return NSRect(
            x: splitView.bounds.minX,
            y: edge - Self.dividerHitMargin,
            width: splitView.bounds.width,
            height: Self.dividerHitMargin * 2 + 1
        )
    }

    /// 该栏内容相对 pane 边界的内缩量。中间工作区不内缩。
    func visibleInset(ofPaneAt index: Int) -> CGFloat {
        guard index < splitViewItems.count else { return 0 }
        let item = splitViewItems[index]
        if item === sidebarItem { return WorkPiLayoutState.sidebarInset }
        if item === inspectorItem { return WorkPiLayoutState.inspectorInset }
        return 0
    }

    func installDividerVisualMask() {
        guard let parent = splitView.superview else { return }

        let mask: WorkPiDividerVisualMask
        if let existing = dividerVisualMask, existing.superview === parent {
            mask = existing
        } else {
            dividerVisualMask?.removeFromSuperview()
            let created = WorkPiDividerVisualMask(frame: parent.bounds)
            created.autoresizingMask = [.width, .height]
            parent.addSubview(created, positioned: .above, relativeTo: splitView)
            dividerVisualMask = created
            mask = created
        }

        mask.frame = parent.bounds
        mask.maskedRects = splitView.arrangedSubviews.enumerated().compactMap { index, pane in
            guard index < splitView.arrangedSubviews.count - 1,
                  splitView.dividerThickness > 0,
                  pane.frame.width > 0
            else { return nil }
            let nextPane = splitView.arrangedSubviews[index + 1]
            let dividerGap = nextPane.frame.minX - pane.frame.maxX
            guard dividerGap > 0.5 else { return nil }
            // 只覆盖旧 divider 中央的圆形 grabber，不铺一整条竖带；Inspector
            // 的可见左边缘在旧 divider 右侧，不会被这个遮罩触及。
            let diameter: CGFloat = 10
            let center = NSPoint(
                x: (pane.frame.maxX + nextPane.frame.minX) / 2,
                y: splitView.bounds.midY
            )
            let rect = NSRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            return parent.convert(rect, from: splitView)
        }
        mask.needsDisplay = true
        if let blocker = dividerWindowDragBlocker, blocker.superview === parent {
            parent.addSubview(mask, positioned: .below, relativeTo: blocker)
        } else {
            parent.addSubview(mask, positioned: .above, relativeTo: splitView)
        }
    }

    func installDividerWindowDragBlocker() {
        guard let parent = splitView.superview else { return }

        // 判据是"是否仍挂在正确的父视图上"，而不是"引用是否为 nil"。
        //
        // 这里持有的是 weak 引用（视图树才是所有者）。如果只判 nil，覆盖层被移出
        // 视图树后引用可能还没置空，就会永远不再安装，缺陷静默复现；
        // 而 SwiftUI 重建宿主时父视图会换成新的，也需要重新挂一层。
        if let existing = dividerWindowDragBlocker, existing.superview === parent {
            // 已在正确位置。仅确保它在视觉遮罩之上、且仍在 splitView 之上；
            // AppKit 可能重排兄弟节点。
            let reference: NSView = dividerVisualMask ?? splitView
            let existingIndex = parent.subviews.firstIndex(where: { $0 === existing }) ?? -1
            let referenceIndex = parent.subviews.firstIndex(where: { $0 === reference }) ?? -1
            if existingIndex <= referenceIndex {
                existing.removeFromSuperview()
                parent.addSubview(existing, positioned: .above, relativeTo: reference)
            }
            return
        }
        dividerWindowDragBlocker?.removeFromSuperview()

        let blocker = WorkPiDividerWindowDragBlocker(frame: parent.bounds)
        blocker.translatesAutoresizingMaskIntoConstraints = true
        blocker.autoresizingMask = [.width, .height]
        blocker.splitView = splitView
        blocker.hitRectsInSplitView = { [weak self] in
            self?.dividerHitRects() ?? []
        }
        parent.addSubview(
            blocker,
            positioned: .above,
            relativeTo: dividerVisualMask ?? splitView
        )
        dividerWindowDragBlocker = blocker
    }

    /// 供测试确认覆盖层已安装。缺了它，窗口会在拖分隔线时被拖走。
    var diagnosticDividerDragBlockerInstalled: Bool {
        dividerWindowDragBlocker?.superview != nil
    }

    /// 分隔线两侧额外的命中宽度。透明 divider 本身不可见，必须扩大命中区。
    fileprivate static let dividerHitMargin: CGFloat = 7

    /// 应用 Inspector 最大化。
    ///
    /// 只调整右分隔线位置，不改任何约束或折叠状态——上一轮试过改
    /// holdingPriority、hugging、canCollapse 与 sizingOptions，每一种都让三栏
    /// 布局整体错位（Sidebar 被推到窗口中间）。这套约束对改动很敏感，
    /// 因此这里只做最小干预。
    ///
    /// 退出最大化时直接回到 `layoutState.inspectorWidth`：它已经是宽度的
    /// 唯一真相，不需要另存一份 divider 位置快照。
    func applyInspectorMaximizedState() {
        guard let inspectorItem, !inspectorItem.isCollapsed,
              let inspectorIndex = splitViewItems.firstIndex(where: { $0 === inspectorItem }),
              inspectorIndex > 0
        else { return }

        isApplyingPaneGeometry = true
        defer { isApplyingPaneGeometry = false }

        if layoutState.inspectorMaximized {
            // 推到 Sidebar 右边界；工作区的 minimumThickness 会挡住最后一段，
            // 因此这不是"完全遮挡"，而是把工作区压到最小。
            let sidebarEdge = sidebarItem.isCollapsed
                ? 0
                : sidebarItem.viewController.view.frame.maxX
            splitView.setPosition(sidebarEdge, ofDividerAt: inspectorIndex - 1)
        } else {
            let dividerPosition = splitView.bounds.width
                - (layoutState.inspectorWidth + inspectorSlotPadding)
                - splitView.dividerThickness
            splitView.setPosition(dividerPosition, ofDividerAt: inspectorIndex - 1)
            lastAppliedInspectorWidth = layoutState.inspectorWidth
        }
        installDividerVisualMask()
    }

    /// 把 Inspector 的上限收紧到“不需要动用 Sidebar 空间”的程度。
    ///
    /// 这是“拖右边界却影响左栏”的真正修法，与宽度回写无关。holdingPriority
    /// 只决定 AppKit“先动谁”；当中间工作区已触到 minimumThickness 而拖动还在
    /// 继续时，它为了满足请求仍会继续向左找空间，于是 Sidebar 被挤小：
    ///
    ///     step2 sidebar=306 workspace=421 inspector=453
    ///     step3 sidebar=286 workspace=420 inspector=474   ← 工作区触底，开始抢 Sidebar
    ///
    /// 不能用 `splitView:constrainMinCoordinate:ofSubviewAt:` 卡住拖动范围：
    /// NSSplitViewController 明确不支持该代理方法，实测会在 `_setupSplitView`
    /// 里抛异常直接 SIGTRAP。可用的口子是 `maximumThickness`：AppKit 尊重它，
    /// 于是拖动在工作区触底那一刻就自然停住，而不会把压力传给左栏。
    func updateInspectorThicknessLimit() {
        guard let inspectorItem, !inspectorItem.isCollapsed else { return }
        // 最大化是有意压缩工作区的临时模式，不受这个上限约束。
        guard !layoutState.inspectorMaximized else {
            inspectorItem.maximumThickness = WorkPiLayoutState.maximumInspectorWidth
            return
        }
        let bounds = splitView.bounds.width
        guard bounds > 0 else { return }

        // Sidebar 预留占位（含它右侧的分隔线），折叠时为 0。
        //
        // 必须取“当前 frame”与“目标宽度”的较大值。只看 frame 会在初始安装阶段
        // 读到还停在 minimumThickness 的瞬态值（实测 237 而非 298），算出的上限偏大，
        // 于是根本卡不住拖动；只看目标宽度则会忽略用户正在拖 Sidebar 的中间态。
        let sidebarReserved: CGFloat
        if sidebarItem.isCollapsed {
            sidebarReserved = 0
        } else {
            let currentSlot = sidebarItem.viewController.view.frame.width
            let desiredSlot = layoutState.sidebarWidth + sidebarSlotPadding
            sidebarReserved = max(currentSlot, desiredSlot) + splitView.dividerThickness
        }
        // 普通 Inspector item 没有 AppKit Sidebar 外壳；`inspectorSlotPadding` 已经
        // 包含表面两侧的 8pt padding，因此这里不再另扣一个 inset。否则窄窗口会
        // 提前收紧 Inspector 上限，工作区会停在 429pt 而不是其 420pt 最小值。
        let available = bounds
            - sidebarReserved
            - workspaceItem.minimumThickness
        // available 与 maximumThickness 都是"栏位宽度"，因此上下限也要含内边距。
        let limit = min(
            WorkPiLayoutState.maximumInspectorWidth + inspectorSlotPadding,
            max(WorkPiLayoutState.minimumInspectorWidth + inspectorSlotPadding, available)
        )
        guard abs(inspectorItem.maximumThickness - limit) > 0.5 else { return }
        inspectorItem.maximumThickness = limit
    }

    /// 两条分隔线都属于用户可拖动的边界，共用同一套加宽的命中区。
    func isResizableDividerIndex(_ index: Int) -> Bool {
        if index == sidebarDividerIndex { return true }
        guard let inspectorItem,
              let inspectorIndex = splitViewItems.firstIndex(where: { $0 === inspectorItem })
        else { return false }
        // 只有右栏的**前导**分隔线可拖；右栏外侧没有第二条可调分隔线。
        return index == inspectorIndex - 1
    }

    var sidebarDividerIndex: Int {
        guard let index = splitViewItems.firstIndex(where: { $0 === sidebarItem }) else {
            return 0
        }
        return index
    }
}
