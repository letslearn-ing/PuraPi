import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

/// 拖动分隔线不得移动窗口。
///
/// 症状：拖工作区与右栏之间的分隔线时，整个软件被拖着走。
///
/// 成因：主窗口设置了 `isMovableByWindowBackground = true`，而可见圆角边缘的命中区
/// 扩大到 ±7pt。AppKit 判断"能否拖窗口"的依据是 **hitTest 命中视图**的
/// `mouseDownCanMoveWindow`，因此这里直接断言可观察的契约：命中区内 hitTest 得到的
/// 视图必须 `mouseDownCanMoveWindow == false`，而远离可见边缘处必须仍为 true。
/// 这条契约不依赖任何事件时序，是 AppKit 真正查询的那个值。
@available(macOS 26.0, *)
@MainActor
final class WorkPiWindowDragSuppressionTests: XCTestCase {
    private var savedSidebar: Any?
    private var savedInspector: Any?
    private var savedSidebarVisible: Any?

    override func setUp() {
        super.setUp()
        let defaults = WorkPiPreferences.shared
        savedSidebar = defaults.object(forKey: WorkPiLayoutState.sidebarWidthKey)
        savedInspector = defaults.object(forKey: WorkPiLayoutState.inspectorWidthKey)
        defaults.set(290.0, forKey: WorkPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: WorkPiLayoutState.inspectorWidthKey)
        // 必须显式固定：本机偏好里可能存着"Sidebar 已折叠"，
        // 那样左分隔线根本不存在，关于它的断言会失去意义。
        savedSidebarVisible = defaults.object(forKey: WorkPiLayoutState.sidebarVisibleKey)
        defaults.set(true, forKey: WorkPiLayoutState.sidebarVisibleKey)
    }

    override func tearDown() {
        let defaults = WorkPiPreferences.shared
        if let savedSidebar {
            defaults.set(savedSidebar, forKey: WorkPiLayoutState.sidebarWidthKey)
        } else {
            defaults.removeObject(forKey: WorkPiLayoutState.sidebarWidthKey)
        }
        if let savedInspector {
            defaults.set(savedInspector, forKey: WorkPiLayoutState.inspectorWidthKey)
        } else {
            defaults.removeObject(forKey: WorkPiLayoutState.inspectorWidthKey)
        }
        if let savedSidebarVisible {
            defaults.set(savedSidebarVisible, forKey: WorkPiLayoutState.sidebarVisibleKey)
        } else {
            defaults.removeObject(forKey: WorkPiLayoutState.sidebarVisibleKey)
        }
        super.tearDown()
    }

    private struct Host: View {
        let session: PiSessionController
        let layoutState: WorkPiLayoutState
        var body: some View {
            WorkPiNativeWorkspaceSplitView(
                session: session,
                layoutState: layoutState,
                isFileSelected: true,
                sidebarVisible: layoutState.sidebarVisible,
                sidebarWidth: layoutState.sidebarWidth,
                inspectorWidth: layoutState.inspectorWidth,
                inspectorMaximized: layoutState.inspectorMaximized,
                language: .chinese
            )
            .frame(minWidth: 980, maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func findSplit(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let found = findSplit(sub) { return found }
        }
        return nil
    }

    private func findController(_ view: NSView) -> WorkPiWorkspaceSplitViewController? {
        var node: NSResponder? = view
        while let current = node {
            if let c = current as? WorkPiWorkspaceSplitViewController { return c }
            node = current.nextResponder
        }
        return nil
    }

    /// 返回与生产代码一致的可见圆角边缘：Sidebar 取右边缘，Inspector 取左边缘。
    private func visibleDividerEdge(at index: Int, in splitView: NSSplitView) -> CGFloat {
        let panes = splitView.arrangedSubviews
        if index == 0 {
            return panes[0].frame.maxX
        }
        return panes[index + 1].frame.minX + WorkPiLayoutState.inspectorInset
    }

    /// 完整复刻真实 App 的宿主方式（NSHostingView + autoresizingMask + 工具栏）。
    func testDividerHitMarginForbidsWindowDrag() {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/wp-window-drag.md"),
            relativePath: "wp-window-drag.md",
            kind: .markdown,
            text: "# heading\n\nbody text",
            byteCount: 24,
            modificationDate: Date()
        )
        let layoutState = WorkPiLayoutState()

        let hosting = NSHostingView(rootView: Host(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 与真实 App 一致：允许拖内容背景移动窗口。
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.6)
        window.layoutIfNeeded()
        defer {
            settle(0.1)
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let splitView = findSplit(hosting),
              let controller = findController(splitView)
        else { return XCTFail("找不到 split view / controller") }

        let panes = splitView.arrangedSubviews
        guard panes.count >= 3 else {
            return XCTFail("期望三栏，实测 \(panes.count)")
        }

        // 覆盖层必须真的装上，否则契约永远不会成立。
        XCTAssertTrue(
            controller.diagnosticDividerDragBlockerInstalled,
            "分隔线窗口拖拽覆盖层未安装"
        )

        // 可见边缘必须**实时**读取，不能用先前捕获的 panes 快照：
        // Inspector 安装后还有一轮异步布局，旧 frame 会让命中位置算偏。
        let rightDividerEdge = visibleDividerEdge(at: 1, in: splitView)
        let sidebarDividerEdge = visibleDividerEdge(at: 0, in: splitView)
        let y = splitView.bounds.midY

        for (label, center) in [
            ("右分隔线", rightDividerEdge),
            ("左分隔线", sidebarDividerEdge),
        ] {
            for offset in [-7.0, -5.0, -2.0, 0.0, 2.0, 5.0, 7.0] as [CGFloat] {
                let pointInWindow = splitView.convert(
                    NSPoint(x: center + offset, y: y), to: nil
                )
                let hit = window.contentView?.hitTest(pointInWindow)
                XCTAssertFalse(
                    hit?.mouseDownCanMoveWindow ?? true,
                    "\(label) offset \(offset)pt 处仍允许拖窗口，命中 \(String(describing: hit.map { type(of: $0) }))"
                )
            }
        }

        // 远离分隔线：必须保留"拖背景移窗口"，不能把整个内容区变成不可拖。
        let farPoint = splitView.convert(
            NSPoint(x: panes[1].frame.midX, y: y), to: nil
        )
        let farHit = window.contentView?.hitTest(farPoint)
        XCTAssertTrue(
            farHit?.mouseDownCanMoveWindow ?? false,
            "远离分隔线处应保留拖背景移动窗口"
        )
    }

    /// 拖动命中区必须对齐**用户看到的边界**，也就是右栏圆角矩形的左边缘。
    ///
    /// Inspector 的可见边缘比 pane 几何边界向内缩 8pt；Native Sidebar
    /// 还需补回被系统折叠的 `.thick` divider，命中中心与裁剪后的表面保持一致。
    /// 早先命中区按 pane 边界居中，用户在矩形边缘按下时抓不到，只能去按
    /// "看起来像分界线"的位置——手感与视觉完全错位。
    func testHitRegionCentersOnVisibleRoundedRectEdge() {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/wp-hit-align.md"),
            relativePath: "wp-hit-align.md",
            kind: .markdown, text: "# hi", byteCount: 4, modificationDate: Date())
        let layoutState = WorkPiLayoutState()

        let hosting = NSHostingView(rootView: Host(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded(); settle(0.6); window.layoutIfNeeded()
        defer {
            settle(0.1); window.orderOut(nil); window.contentView = nil; settle(0.1)
        }

        guard let splitView = findSplit(hosting) else { return XCTFail("no split view") }
        let panes = splitView.arrangedSubviews
        guard panes.count >= 3 else { return XCTFail("期望三栏") }

        // 可见边缘：右栏 pane 左边界再往右一个 inset。
        let visibleEdge = panes[2].frame.minX + WorkPiLayoutState.inspectorInset

        func isHandle(atX x: CGFloat) -> Bool {
            let pt = splitView.convert(NSPoint(x: x, y: splitView.bounds.midY), to: nil)
            return window.contentView?.hitTest(pt) is WorkPiDividerWindowDragBlocker
        }

        // 可见边缘本身，以及它两侧 6pt 内，都必须能抓到。
        for offset in [-6.0, -3.0, 0.0, 3.0, 6.0] as [CGFloat] {
            XCTAssertTrue(
                isHandle(atX: visibleEdge + offset),
                "可见边缘 \(offset)pt 处应能抓到分隔线")
        }

        // pane 几何 divider 与圆角边缘之间的旧位置不再是手柄中心。
        let oldPaneDividerCenter = (panes[1].frame.maxX + panes[2].frame.minX) / 2
        XCTAssertFalse(
            isHandle(atX: oldPaneDividerCenter),
            "pane 几何 divider 的旧位置不应再是 Inspector 手柄")

        // 离得足够远则不该被拦，否则右栏内容点不动。
        XCTAssertFalse(
            isHandle(atX: visibleEdge + 20),
            "距可见边缘 20pt 处不应被命中区拦截")
    }


    /// 复刻用户的操作顺序：打开 markdown → 右栏刚展开 → 立刻拖右分隔线。
    /// 右栏刚装上时 frame 尚未布局，命中区若算不出来就会漏判。
    func testFirstDragRightAfterInspectorAppears() {
        let session = PiSessionController()
        let layoutState = WorkPiLayoutState()

        let hosting = NSHostingView(rootView: Host(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.6)
        defer {
            settle(0.1)
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let splitView = findSplit(hosting),
              let controller = findController(splitView)
        else { return XCTFail("找不到 split view / controller") }

        // 打开文件：右栏出现。
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/first.md"),
            relativePath: "first.md",
            kind: .markdown,
            text: "# hi",
            byteCount: 4,
            modificationDate: Date()
        )
        controller.update(
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            inspectorMaximized: false,
            language: .chinese
        )

        let panes = splitView.arrangedSubviews
        guard panes.count >= 3 else {
            return XCTFail("期望三栏，实测 \(panes.count)")
        }

        // 不额外跑布局，直接检查——这正是"右栏一出现就去拖"的时刻。
        let edge = visibleDividerEdge(at: 1, in: splitView)
        let point = splitView.convert(
            NSPoint(x: edge, y: splitView.bounds.midY), to: nil
        )
        let hit = window.contentView?.hitTest(point)
        XCTAssertFalse(
            hit?.mouseDownCanMoveWindow ?? true,
            "右栏刚出现时按下右分隔线仍允许拖窗口，命中 \(String(describing: hit.map { type(of: $0) }))"
        )
    }
}
