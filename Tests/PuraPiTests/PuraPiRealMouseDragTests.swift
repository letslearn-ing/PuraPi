import AppKit
import PiDomain
import XCTest
@testable import PuraPi

/// 用真实鼠标事件驱动 NSSplitView 自己的事件跟踪循环。
///
/// 之前所有用例都是 `setPosition` 或直接查询 `effectiveRect`，走的是布局路径和
/// 命中判定的**输入**，因此一直是绿的，但用户报告的 bug 依然存在。真正的拖动是：
/// mouseDown 落在某条分隔线上 → NSSplitView 进入内部跟踪循环 → 逐个 mouseDragged
/// 事件更新位置 → mouseUp 结束。只有把完整事件序列送进去，才能看到 AppKit 实际
/// 决定去动哪一栏。
@available(macOS 26.0, *)
@MainActor
final class PuraPiRealMouseDragTests: XCTestCase {
    private var savedSidebar: Any?
    private var savedInspector: Any?
    private var savedSidebarVisible: Any?

    override func setUp() {
        super.setUp()
        let defaults = PuraPiPreferences.shared
        savedSidebar = defaults.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        savedInspector = defaults.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)
        // 显式固定 Sidebar 为展开：本机偏好可能存着"已折叠"，
        // 那样与 Sidebar 相关的几何断言会失去意义。
        savedSidebarVisible = defaults.object(forKey: PuraPiLayoutState.sidebarVisibleKey)
        defaults.set(true, forKey: PuraPiLayoutState.sidebarVisibleKey)
    }

    override func tearDown() {
        let defaults = PuraPiPreferences.shared
        if let savedSidebar {
            defaults.set(savedSidebar, forKey: PuraPiLayoutState.sidebarWidthKey)
        } else {
            defaults.removeObject(forKey: PuraPiLayoutState.sidebarWidthKey)
        }
        if let savedInspector {
            defaults.set(savedInspector, forKey: PuraPiLayoutState.inspectorWidthKey)
        } else {
            defaults.removeObject(forKey: PuraPiLayoutState.inspectorWidthKey)
        }
        if let savedSidebarVisible {
            defaults.set(savedSidebarVisible, forKey: PuraPiLayoutState.sidebarVisibleKey)
        } else {
            defaults.removeObject(forKey: PuraPiLayoutState.sidebarVisibleKey)
        }
        super.tearDown()
    }

    private struct Harness {
        let controller: PuraPiWorkspaceSplitViewController
        let window: NSWindow
        let layoutState: PuraPiLayoutState
    }

    private func makeHarness(windowWidth: CGFloat = 1440) -> Harness {
        let session = PiSessionController()
        // 带真实预览内容，尽量贴近用户实际使用状态。
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/purapi-real-drag.txt"),
            relativePath: "purapi-real-drag.txt",
            kind: .text,
            text: String(repeating: "let sample = \"long enough line of code\"\n", count: 300),
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
            contentRect: NSRect(x: 100, y: 100, width: windowWidth, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: windowWidth, height: 900))
        // 必须真正上屏：NSSplitView 的事件跟踪依赖窗口存在且能取事件。
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.4)
        window.layoutIfNeeded()
        return Harness(controller: controller, window: window, layoutState: layoutState)
    }

    /// 关窗前先把事件队列排空并摘掉 contentViewController。
    /// 直接 close() 会在仍有排队鼠标事件时崩溃（实测 SIGSEGV）。
    private func teardown(_ harness: Harness) {
        settle(0.1)
        harness.window.orderOut(nil)
        harness.window.contentViewController = nil
        settle(0.1)
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func event(
        _ type: NSEvent.EventType,
        at pointInSplitView: NSPoint,
        in harness: Harness
    ) -> NSEvent {
        let splitView = harness.controller.splitView
        let inWindow = splitView.convert(pointInSplitView, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: inWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    /// 把一次完整的拖动（down → 多次 dragged → up）送进 split view。
    ///
    /// NSSplitView 在 mouseDown 里会自己 nextEvent 抽取后续事件，因此必须先把
    /// dragged/up 事件排进队列，再投递 mouseDown。
    private func performDrag(
        in harness: Harness,
        fromX startX: CGFloat,
        toX endX: CGFloat,
        steps: Int = 12
    ) {
        let splitView = harness.controller.splitView
        let y = splitView.bounds.midY

        var queued: [NSEvent] = []
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let x = startX + (endX - startX) * progress
            queued.append(event(.leftMouseDragged, at: NSPoint(x: x, y: y), in: harness))
        }
        queued.append(event(.leftMouseUp, at: NSPoint(x: endX, y: y), in: harness))

        // 逆序 postEvent(atStart: true) 相当于按顺序排在队首。
        for queuedEvent in queued.reversed() {
            harness.window.postEvent(queuedEvent, atStart: true)
        }

        let down = event(.leftMouseDown, at: NSPoint(x: startX, y: y), in: harness)
        splitView.mouseDown(with: down)
        settle(0.35)
        harness.window.layoutIfNeeded()
    }

    private func widths(_ harness: Harness) -> (sidebar: CGFloat, workspace: CGFloat, inspector: CGFloat) {
        let panes = harness.controller.splitView.arrangedSubviews
        return (panes[0].frame.width, panes[1].frame.width, panes[2].frame.width)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// 核心用例：从 Inspector 圆角表面的可见左边缘真实拖动。
    /// 期望 Inspector 变宽、Sidebar 完全不动。
    func testRealMouseDragOnRightDividerMovesInspectorOnly() {
        let harness = makeHarness()
        defer { teardown(harness) }

        let before = widths(harness)
        let splitView = harness.controller.splitView
        let rightDividerX = splitView.arrangedSubviews[2].frame.minX
            + PuraPiLayoutState.inspectorInset
        print("[real] 拖动前 sidebar=\(before.sidebar) workspace=\(before.workspace) inspector=\(before.inspector)")
        print("[real] Inspector 可见左边缘 x=\(rightDividerX)，向左拖 160pt")

        performDrag(in: harness, fromX: rightDividerX, toX: rightDividerX - 160)

        let after = widths(harness)
        print("[real] 拖动后 sidebar=\(after.sidebar) workspace=\(after.workspace) inspector=\(after.inspector)")

        XCTAssertEqual(
            after.sidebar, before.sidebar, accuracy: 1,
            "Sidebar 不应被动过：\(before.sidebar) -> \(after.sidebar)"
        )
        XCTAssertEqual(
            after.inspector, before.inspector + 160, accuracy: 12,
            "Inspector 应加宽约 160pt：\(before.inspector) -> \(after.inspector)"
        )
    }

    /// 反方向同样要成立：拖 Sidebar 边界只动 Sidebar，Inspector 不变。
    func testRealMouseDragOnSidebarDividerMovesSidebarOnly() {
        let harness = makeHarness()
        defer { teardown(harness) }

        let before = widths(harness)
        let splitView = harness.controller.splitView
        let sidebarDividerX = splitView.arrangedSubviews[0].frame.maxX

        performDrag(in: harness, fromX: sidebarDividerX, toX: sidebarDividerX + 80)

        let after = widths(harness)
        print("[real-left] sidebar \(before.sidebar) -> \(after.sidebar), inspector \(before.inspector) -> \(after.inspector)")

        XCTAssertEqual(
            after.inspector, before.inspector, accuracy: 1,
            "Inspector 不应被动过：\(before.inspector) -> \(after.inspector)"
        )
        XCTAssertEqual(
            after.sidebar, before.sidebar + 80, accuracy: 12,
            "Sidebar 应加宽约 80pt：\(before.sidebar) -> \(after.sidebar)"
        )
    }

    /// 用户报告的完整关键路径：真实鼠标拖动完成后，再切换有色/无颜色。
    /// 中心宿主、尺寸和可见性都必须保持不变。
    func testRealDividerDragThenInspectorNoColorKeepsConversationVisible() {
        let harness = makeHarness()
        defer { teardown(harness) }

        let splitView = harness.controller.splitView
        let rightDividerX = splitView.arrangedSubviews[2].frame.minX
            + PuraPiLayoutState.inspectorInset
        performDrag(in: harness, fromX: rightDividerX, toX: rightDividerX - 140)

        let centerBefore = splitView.arrangedSubviews[1].frame
        let state = harness.layoutState
        harness.controller.update(
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: state.sidebarWidth,
            inspectorWidth: state.inspectorWidth,
            inspectorMaximized: false,
            language: .chinese,
            sidebarTint: .purple,
            inspectorTint: .blue
        )
        settle(0.25)
        harness.controller.update(
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: state.sidebarWidth,
            inspectorWidth: state.inspectorWidth,
            inspectorMaximized: false,
            language: .chinese,
            sidebarTint: .purple,
            inspectorTint: .none
        )
        settle(0.7)
        harness.window.layoutIfNeeded()

        let center = splitView.arrangedSubviews[1]
        XCTAssertEqual(center.frame.minX, centerBefore.minX, accuracy: 2)
        XCTAssertEqual(center.frame.width, centerBefore.width, accuracy: 2)
        XCTAssertGreaterThan(center.frame.width, 400)
        let hosts = descendants(of: center).filter {
            String(describing: type(of: $0)).contains("PuraPiConversationHostView")
        }
        XCTAssertTrue(hosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 })
    }
}
