import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

/// 复刻真实 App 的宿主结构后再做真实鼠标拖动。
///
/// 与 `PuraPiRealMouseDragTests` 的区别，也正是之前一直没覆盖到的部分：
/// 真实 App 里这个控制器不是直接当 `contentViewController`，而是
/// 1. 由 SwiftUI 的 `NSViewControllerRepresentable` 包裹，外面还套着
///    `.frame(minWidth: 980)` 和 `.ignoresSafeArea(.container, edges: .top)`；
/// 2. 窗口装有 `NSToolbar`，其中含 `.sidebarTrackingSeparator`——这个工具栏项
///    会把自己**绑定到 split view 的某条 divider** 上。
///
/// 这两点都会改变 NSSplitView 的 divider 拓扑与命中判定。
@available(macOS 26.0, *)
@MainActor
final class PuraPiHostedDragTests: XCTestCase {
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
        // 必须显式固定：本机偏好里可能存着"Sidebar 已折叠"，
        // 那样拖左分隔线的断言会失去意义（实测 Sidebar 停在 244 不动）。
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

    /// 与真实 App 一致的 SwiftUI 包装层。
    private struct HostWrapper: View {
        let session: PiSessionController
        let layoutState: PuraPiLayoutState

        var body: some View {
            PuraPiNativeWorkspaceSplitView(
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

    /// 在视图树里找到真实的 NSSplitView。
    private func findSplitView(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let found = findSplitView(sub) { return found }
        }
        return nil
    }

    /// 拖右分隔线：Inspector 变宽，Sidebar 不动。
    func testHostedRealMouseDragOnRightDivider() {
        assertHostedDrag(divider: .right)
    }

    /// 拖左分隔线：Sidebar 变宽，Inspector 不动。
    func testHostedRealMouseDragOnLeftDivider() {
        assertHostedDrag(divider: .left)
    }

    private enum DividerUnderTest { case left, right }

    private func assertHostedDrag(divider: DividerUnderTest) {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/purapi-hosted.txt"),
            relativePath: "purapi-hosted.txt",
            kind: .text,
            text: String(repeating: "let sample = \"a line\"\n", count: 300),
            byteCount: 4096,
            modificationDate: Date()
        )
        let layoutState = PuraPiLayoutState()

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 复刻真实 App 的窗口 chrome。
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "PuraPiTests.toolbar")
        let toolbarDelegate = TrackingSeparatorToolbarDelegate()
        toolbar.delegate = toolbarDelegate
        window.toolbar = toolbar

        let hostingView = NSHostingView(
            rootView: HostWrapper(session: session, layoutState: layoutState)
        )
        // 完全复刻 PuraPiApp.applicationDidFinishLaunching 的宿主方式：
        // autoresizingMask + contentMinSize，而不是自己加约束或让它自由伸缩。
        hostingView.autoresizingMask = [.width, .height]
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.6)
        // 上屏后窗口可能被系统按屏幕可用区域收窄（实测请求 1440 实得 1280），
        // 因此必须以真实内容宽度为基准断言，否则算出的拖动目标会落到视图之外。
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.layoutIfNeeded()
        settle(0.3)
        window.layoutIfNeeded()
        defer {
            settle(0.1)
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let splitView = findSplitView(hostingView) else {
            return XCTFail("在 SwiftUI 宿主里找不到 NSSplitView")
        }

        let panes = splitView.arrangedSubviews
        guard panes.count >= 3 else {
            return XCTFail("期望三栏，实测 \(panes.count)")
        }

        let before = (panes[0].frame.width, panes[1].frame.width, panes[2].frame.width)

        // 真实鼠标拖动指定分隔线。左分隔线向右拖 80pt，右分隔线向左拖 160pt。
        let y = splitView.bounds.midY
        let startX: CGFloat
        let endX: CGFloat
        switch divider {
        case .right:
            // 命中区中心与 Inspector 圆角表面的可见左边缘重合。
            startX = panes[2].frame.minX + PuraPiLayoutState.inspectorInset
            endX = startX - 160
        case .left:
            // 命中区中心与 Sidebar 圆角表面的可见右边缘重合。
            startX = panes[0].frame.maxX
            endX = startX + 80
        }

        func makeEvent(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            let inWindow = splitView.convert(NSPoint(x: x, y: y), to: nil)
            return NSEvent.mouseEvent(
                with: type,
                location: inWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )!
        }

        var queued: [NSEvent] = []
        for step in 1...12 {
            let progress = CGFloat(step) / 12.0
            queued.append(makeEvent(.leftMouseDragged, x: startX + (endX - startX) * progress))
        }
        queued.append(makeEvent(.leftMouseUp, x: endX))
        for queuedEvent in queued.reversed() {
            window.postEvent(queuedEvent, atStart: true)
        }
        splitView.mouseDown(with: makeEvent(.leftMouseDown, x: startX))
        settle(0.4)
        window.layoutIfNeeded()

        let after = (panes[0].frame.width, panes[1].frame.width, panes[2].frame.width)
        print("[hosted] \(divider) 拖动 sidebar \(before.0)->\(after.0) inspector \(before.2)->\(after.2)")

        switch divider {
        case .right:
            XCTAssertEqual(
                after.0, before.0, accuracy: 1,
                "拖右分隔线时 Sidebar 不应被动过：\(before.0) -> \(after.0)"
            )
            XCTAssertEqual(
                after.2, before.2 + 160, accuracy: 12,
                "Inspector 应加宽约 160pt：\(before.2) -> \(after.2)"
            )
        case .left:
            XCTAssertEqual(
                after.2, before.2, accuracy: 1,
                "拖左分隔线时 Inspector 不应被动过：\(before.2) -> \(after.2)"
            )
            XCTAssertEqual(
                after.0, before.0 + 80, accuracy: 12,
                "Sidebar 应加宽约 80pt：\(before.0) -> \(after.0)"
            )
        }
    }
}

/// 只提供 `.sidebarTrackingSeparator`，复刻真实 App 工具栏对 divider 的绑定。
private final class TrackingSeparatorToolbarDelegate: NSObject, NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }
}
