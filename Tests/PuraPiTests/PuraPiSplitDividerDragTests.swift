import AppKit
import XCTest
import PiDomain
@testable import PuraPi

/// 三栏分隔线拖动的回归测试。
///
/// 背景：AppKit 在 `splitViewDidResizeSubviews` 的 userInfo 里告知哪条分隔线动了
/// （`NSSplitViewDividerIndex`）以及是否为显式位置变更（`NSSplitViewUserResizeKey`）。
/// 早期实现忽略了这两个信息，每次通知都同时测量两栏，于是拖右分隔线时
/// 初始布局阶段 Sidebar 的瞬态 frame 被异步回写到共享状态，每次削掉一个
/// `sidebarSlotPadding`——表现为“拖右边界左栏跟着缩”。这组用例锁住该行为。
@available(macOS 26.0, *)
@MainActor
final class PuraPiSplitDividerDragTests: XCTestCase {
    /// 这组用例会真的回写并持久化宽度，所以必须每例重置到确定的初始值，
    /// 否则前一个用例把宽度拖到上限后，后一个用例就没有拖动余量了。
    private var savedSidebarWidth: Any?
    private var savedInspectorWidth: Any?

    override func setUp() {
        super.setUp()
        let defaults = PuraPiPreferences.shared
        savedSidebarWidth = defaults.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        savedInspectorWidth = defaults.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)
    }

    override func tearDown() {
        let defaults = PuraPiPreferences.shared
        if let savedSidebarWidth {
            defaults.set(savedSidebarWidth, forKey: PuraPiLayoutState.sidebarWidthKey)
        } else {
            defaults.removeObject(forKey: PuraPiLayoutState.sidebarWidthKey)
        }
        if let savedInspectorWidth {
            defaults.set(savedInspectorWidth, forKey: PuraPiLayoutState.inspectorWidthKey)
        } else {
            defaults.removeObject(forKey: PuraPiLayoutState.inspectorWidthKey)
        }
        super.tearDown()
    }

    private func makeHosted(
        windowWidth: CGFloat = 1440
    ) -> (PuraPiWorkspaceSplitViewController, NSWindow) {
        let session = PiSessionController()
        let layoutState = PuraPiLayoutState()
        // 必须与 ContentView 一致：宽度参数就是 layoutState 当前值。
        // 写死常量会让初始状态自相矛盾，造出并不存在的回写。
        let controller = PuraPiWorkspaceSplitViewController(
            session: session,
            layoutState: layoutState,
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            language: .chinese
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        // contentViewController 会带来自己的最小尺寸约束，必须在挂载之后再
        // 强制设置 frame，否则窗口停留在“三栏最小值之和”，没有拖动余量。
        window.setContentSize(NSSize(width: windowWidth, height: 900))
        window.layoutIfNeeded()
        // 让 installInspector 的 DispatchQueue.main.async 落地。
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        window.layoutIfNeeded()
        return (controller, window)
    }

    func testDraggingRightDividerDoesNotShrinkSidebar() {
        let (controller, window) = makeHosted()
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        XCTAssertGreaterThanOrEqual(splitView.arrangedSubviews.count, 3, "应有 sidebar / 工作区 / inspector 三栏")

        let sidebarBefore = splitView.arrangedSubviews[0].frame.width
        let inspectorBefore = splitView.arrangedSubviews[2].frame.width

        // 模拟用户把右分隔线向左拖 120pt（Inspector 变宽）。
        let dividerPosition = splitView.arrangedSubviews[2].frame.minX - splitView.dividerThickness
        splitView.setPosition(dividerPosition - 120, ofDividerAt: 1)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        window.layoutIfNeeded()

        let sidebarAfter = splitView.arrangedSubviews[0].frame.width
        let inspectorAfter = splitView.arrangedSubviews[2].frame.width

        XCTAssertEqual(
            sidebarAfter,
            sidebarBefore,
            accuracy: 1,
            "拖右分隔线时 Sidebar 宽度必须完全不变，实测从 \(sidebarBefore) 变成 \(sidebarAfter)"
        )
        XCTAssertGreaterThan(inspectorAfter, inspectorBefore, "Inspector 应变宽")
    }

    /// 真实拖动是一串逐帧的 setPosition，中间夹着我们的异步回写。
    /// 单次 setPosition 不复现问题，因此这里模拟逐帧拖动，并在每帧之后
    /// 转一下 RunLoop，让 measure→发布→update→setPosition 的回路有机会介入。
    func testIncrementalRightDividerDragKeepsSidebarStable() {
        let (controller, window) = makeHosted()
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        let sidebarBefore = splitView.arrangedSubviews[0].frame.width

        var minObservedSidebar = sidebarBefore
        for _ in 1...12 {
            let dividerPosition = splitView.arrangedSubviews[2].frame.minX
                - splitView.dividerThickness
            splitView.setPosition(dividerPosition - 10, ofDividerAt: 1)
            window.layoutIfNeeded()
            // 让异步回写和 SwiftUI 更新在两帧之间真的跑一遍。
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            let sidebarNow = splitView.arrangedSubviews[0].frame.width
            minObservedSidebar = min(minObservedSidebar, sidebarNow)
        }

        XCTAssertEqual(
            minObservedSidebar,
            sidebarBefore,
            accuracy: 1,
            "逐帧拖动右分隔线期间 Sidebar 最小降到 \(minObservedSidebar)，起始是 \(sidebarBefore)"
        )
    }

    /// 拖动右分隔线不应让 layoutState.sidebarWidth 被回写。
    /// 即使 frame 最终回位，中途被写脏也会把脏值持久化下去。
    func testRightDividerDragDoesNotWriteSidebarWidth() {
        let (controller, window) = makeHosted()
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        let layoutState = controller.diagnosticLayoutState
        let sidebarWidthBefore = layoutState.sidebarWidth

        for _ in 1...12 {
            let dividerPosition = splitView.arrangedSubviews[2].frame.minX
                - splitView.dividerThickness
            splitView.setPosition(dividerPosition - 10, ofDividerAt: 1)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        XCTAssertEqual(
            layoutState.sidebarWidth,
            sidebarWidthBefore,
            accuracy: 1,
            "拖右分隔线却修改了 sidebarWidth"
        )
    }

    /// 对称方向：拖左分隔线也不得扰动 Inspector 的宽度状态。
    func testLeftDividerDragDoesNotWriteInspectorWidth() {
        let (controller, window) = makeHosted()
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        let layoutState = controller.diagnosticLayoutState
        let inspectorWidthBefore = layoutState.inspectorWidth

        for _ in 1...10 {
            let dividerPosition = splitView.arrangedSubviews[0].frame.maxX
            splitView.setPosition(dividerPosition + 8, ofDividerAt: 0)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        XCTAssertEqual(
            layoutState.inspectorWidth,
            inspectorWidthBefore,
            accuracy: 1,
            "拖左分隔线却修改了 inspectorWidth"
        )
        XCTAssertGreaterThan(
            layoutState.sidebarWidth,
            0,
            "Sidebar 宽度应该被正常回写"
        )
    }
}

/// 窄窗口下的挤压诊断。
///
/// 前一组用例用 1440pt 宽窗口，三栏都有余量，因此掩盖了真正的耦合路径：
/// 工作区一旦撞到 minimumThickness（420pt），AppKit 为了继续满足右分隔线的
/// 拖动请求，只能从 holdingPriority 更高的 Sidebar 身上抢空间。
@available(macOS 26.0, *)
@MainActor
final class PuraPiNarrowWindowSqueezeTests: XCTestCase {
    func testDraggingRightDividerInNarrowWindow() {
        let defaults = PuraPiPreferences.shared
        let savedSidebar = defaults.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        let savedInspector = defaults.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        defer {
            if let savedSidebar { defaults.set(savedSidebar, forKey: PuraPiLayoutState.sidebarWidthKey) }
            if let savedInspector { defaults.set(savedInspector, forKey: PuraPiLayoutState.inspectorWidthKey) }
        }
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)

        let layoutState = PuraPiLayoutState()
        let controller = PuraPiWorkspaceSplitViewController(
            session: PiSessionController(),
            layoutState: layoutState,
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            language: .chinese
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1180, height: 900))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        window.layoutIfNeeded()
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        let sidebarStart = splitView.arrangedSubviews[0].frame.width

        var minSidebar = sidebarStart
        for _ in 1...20 {
            let dividerPosition = splitView.arrangedSubviews[2].frame.minX - splitView.dividerThickness
            splitView.setPosition(dividerPosition - 20, ofDividerAt: 1)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            let s = splitView.arrangedSubviews[0].frame.width
            minSidebar = min(minSidebar, s)
        }

        XCTAssertEqual(
            minSidebar, sidebarStart, accuracy: 1,
            "窄窗口下拖右分隔线把 Sidebar 从 \(sidebarStart) 挤到 \(minSidebar)"
        )
    }
}

/// 上限是动态的，不能因为收紧了 Inspector 就把窗口变宽后的余量也锁死。
@available(macOS 26.0, *)
@MainActor
final class PuraPiInspectorLimitTests: XCTestCase {
    func testWideningWindowReleasesInspectorCap() {
        let defaults = PuraPiPreferences.shared
        let savedSidebar = defaults.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        let savedInspector = defaults.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        defer {
            if let savedSidebar { defaults.set(savedSidebar, forKey: PuraPiLayoutState.sidebarWidthKey) }
            if let savedInspector { defaults.set(savedInspector, forKey: PuraPiLayoutState.inspectorWidthKey) }
        }
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)

        let layoutState = PuraPiLayoutState()
        let controller = PuraPiWorkspaceSplitViewController(
            session: PiSessionController(),
            layoutState: layoutState,
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            language: .chinese
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1180, height: 900))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        // 窄窗口：Inspector 拖到底也只能到 452 附近（1180 - 307 - 420 - 1）。
        for _ in 1...20 {
            let p = splitView.arrangedSubviews[2].frame.minX - splitView.dividerThickness
            splitView.setPosition(p - 20, ofDividerAt: 1)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let narrowMax = splitView.arrangedSubviews[2].frame.width
        XCTAssertLessThan(narrowMax, 500, "窄窗口下 Inspector 应被上限卡住")
        // 普通 item 的透明 divider 仍参与几何计算，允许几 pt 的 AppKit 舍入误差。
        XCTAssertEqual(
            splitView.arrangedSubviews[1].frame.width, 420, accuracy: 5,
            "工作区应停在下限附近")

        // 窗口变宽后余量增加，上限必须跟着放开。
        window.setContentSize(NSSize(width: 1700, height: 900))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        for _ in 1...20 {
            let p = splitView.arrangedSubviews[2].frame.minX - splitView.dividerThickness
            splitView.setPosition(p - 20, ofDividerAt: 1)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let wideMax = splitView.arrangedSubviews[2].frame.width
        XCTAssertGreaterThan(wideMax, narrowMax, "窗口变宽后 Inspector 应能拖得更宽")
        XCTAssertEqual(
            // 占位 = sidebarWidth(290) + sidebarSlotPadding(sidebarInset*2 = 16)。
            splitView.arrangedSubviews[0].frame.width, 306, accuracy: 2,
            "整个过程中 Sidebar 都不该被动过"
        )
    }
}

/// 带真实预览内容的拖动测试。
///
/// 之前几组用例都没给 session 设置 `selectedPreview`，Inspector 渲染的是
/// “正在读取预览…”这个极简分支，SwiftUI 不会产生有实际宽度诉求的内容。
/// 用户的真实场景是文件已选中、正文已渲染，此时 hosting view 内部的固定
/// 宽度约束才会参与求解——这正是"拖右边界却动左栏"的现场。
@available(macOS 26.0, *)
@MainActor
final class PuraPiLoadedInspectorDragTests: XCTestCase {
    private func makeLoaded(
        windowWidth: CGFloat
    ) -> (PuraPiWorkspaceSplitViewController, NSWindow, PuraPiLayoutState) {
        let defaults = PuraPiPreferences.shared
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)

        let session = PiSessionController()
        // 关键：塞进真实预览，让 Inspector 走正文渲染路径。
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/purapi-drag-fixture.txt"),
            relativePath: "purapi-drag-fixture.txt",
            kind: .text,
            text: String(repeating: "let sample = \"a fairly long line of source code\"\n", count: 400),
            byteCount: 4096,
            modificationDate: Date()
        )

        let layoutState = PuraPiLayoutState()
        let controller = PuraPiWorkspaceSplitViewController(
            session: session,
            layoutState: layoutState,
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            language: .chinese
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: windowWidth, height: 900))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()
        return (controller, window, layoutState)
    }

    func testDragRightDividerWithLoadedPreview() {
        let (controller, window, _) = makeLoaded(windowWidth: 1440)
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        let sidebarStart = splitView.arrangedSubviews[0].frame.width
        let inspectorStart = splitView.arrangedSubviews[2].frame.width

        var minSidebar = sidebarStart
        for _ in 1...15 {
            let p = splitView.arrangedSubviews[2].frame.minX - splitView.dividerThickness
            splitView.setPosition(p - 20, ofDividerAt: 1)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            let s = splitView.arrangedSubviews[0].frame.width
            minSidebar = min(minSidebar, s)
        }

        let inspectorEnd = splitView.arrangedSubviews[2].frame.width
        XCTAssertEqual(minSidebar, sidebarStart, accuracy: 1,
                       "Sidebar 从 \(sidebarStart) 被挤到 \(minSidebar)")
        XCTAssertGreaterThan(inspectorEnd, inspectorStart,
                             "Inspector 应该变宽，实测 \(inspectorStart) -> \(inspectorEnd)")
    }
}

/// 用真实鼠标事件驱动的拖动测试。
///
/// 前面所有用例都用 `setPosition` 直接改位置，走的是布局路径，因此一直是绿的。
/// 但用户是用鼠标拖：NSSplitView 先靠 `effectiveRect` /
/// `additionalEffectiveRectOfDividerAt` 判断"抓住的是哪条分隔线"，再进入自己的
/// 事件跟踪循环。判断错了就会去拖另一条线——这才是"拖右边界动的是左栏"的现场。
@available(macOS 26.0, *)
@MainActor
final class PuraPiMouseDragTests: XCTestCase {
    /// 把 splitView 上某个点的命中结果解析成"AppKit 认为这是第几条分隔线"。
    /// 直接查询我们自己的两个 override，等价于 NSSplitView 内部的判定输入。
    private func hitDividerIndices(
        _ controller: PuraPiWorkspaceSplitViewController,
        atX x: CGFloat
    ) -> [Int] {
        let splitView = controller.splitView
        let point = NSPoint(x: x, y: splitView.bounds.midY)
        var hits: [Int] = []
        for index in 0..<max(0, splitView.arrangedSubviews.count - 1) {
            let drawn = dividerDrawnRect(splitView, index: index)
            let effective = controller.splitView(
                splitView,
                effectiveRect: drawn,
                forDrawnRect: drawn,
                ofDividerAt: index
            )
            let additional = controller.splitView(
                splitView,
                additionalEffectiveRectOfDividerAt: index
            )
            if effective.contains(point) || additional.contains(point) {
                hits.append(index)
            }
        }
        return hits
    }

    /// 分隔线的绘制矩形必须由 `arrangedSubviews`（视觉顺序）推导，
    /// `subviews` 既含占位视图也不按视觉顺序排列。
    private func dividerDrawnRect(_ splitView: NSSplitView, index: Int) -> NSRect {
        let pane = splitView.arrangedSubviews[index]
        return NSRect(
            x: pane.frame.maxX,
            y: splitView.bounds.minY,
            width: splitView.dividerThickness,
            height: splitView.bounds.height
        )
    }

    func testRightDividerHitAreaDoesNotClaimSidebarDivider() {
        let defaults = PuraPiPreferences.shared
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)

        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/purapi-hit.txt"),
            relativePath: "purapi-hit.txt",
            kind: .text,
            text: "sample",
            byteCount: 6,
            modificationDate: Date()
        )
        let layoutState = PuraPiLayoutState()
        let controller = PuraPiWorkspaceSplitViewController(
            session: session,
            layoutState: layoutState,
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            language: .chinese
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        defer { window.contentViewController = nil }

        let splitView = controller.splitView
        // Sidebar 保留完整表面，左命中区以其真实 pane 边界为中心；
        // Inspector 仍以自绘表面的可见左边缘为中心。
        let sidebarEdge = splitView.arrangedSubviews[0].frame.maxX
        let inspectorEdge = splitView.arrangedSubviews[2].frame.minX
            + PuraPiLayoutState.inspectorInset

        let onSidebarDivider = hitDividerIndices(controller, atX: sidebarEdge)
        let onRightDivider = hitDividerIndices(controller, atX: inspectorEdge)
        let oldRightDividerCenter = (
            splitView.arrangedSubviews[1].frame.maxX
                + splitView.arrangedSubviews[2].frame.minX
        ) / 2
        let onOldRightDivider = hitDividerIndices(controller, atX: oldRightDividerCenter)

        XCTAssertEqual(onSidebarDivider, [0], "左分隔线处只应命中 divider 0")
        XCTAssertEqual(onRightDivider, [1], "右分隔线处只应命中 divider 1，实测 \(onRightDivider)")
        XCTAssertTrue(
            onOldRightDivider.isEmpty,
            "Inspector pane 几何 divider 的旧位置不应再是拖动手柄：\(onOldRightDivider)"
        )
    }
}
