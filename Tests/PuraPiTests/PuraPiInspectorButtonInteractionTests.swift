import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

/// Inspector 顶部按钮的 AppKit 命中回归测试。
///
/// 预览 `ScrollView` 的桥接视图会覆盖 SwiftUI 标题栏的内部命中树，因此按钮的
/// 透明代理必须安装在 splitView 父层，而不是只依赖 SwiftUI 的 zIndex（层级）。
@available(macOS 26.0, *)
@MainActor
final class PuraPiInspectorButtonInteractionTests: XCTestCase {
    private struct Host: View {
        let session: PiSessionController
        let layoutState: PuraPiLayoutState

        var body: some View {
            PuraPiNativeWorkspaceSplitView(
                session: session,
                layoutState: layoutState,
                isFileSelected: true,
                onToggleInspectorDetached: session.showInspectorLiftHint,
                sidebarVisible: true,
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

    private func findSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = findSplit(in: child) { return split }
        }
        return nil
    }

    func testHeaderProxyOwnsMouseHitAreaAndActions() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("purapi-inspector-button-test")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("button-test.md")
        try? "# button test".write(to: file, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.selectedFileURL = file
        session.selectedPreview = FilePreview(
            url: file,
            relativePath: "button-test.md",
            kind: .markdown,
            text: "# button test",
            byteCount: 14,
            modificationDate: Date()
        )
        let layoutState = PuraPiLayoutState()
        let hosting = NSHostingView(rootView: Host(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]

        let window = PuraPiWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_420, height: 900),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentView = hosting

        let tabManager = PuraPiTabManager()
        tabManager.openProject(at: root)
        let appearanceState = PuraPiAppearanceState()
        let toolbarDelegate = PuraPiToolbarDelegate(
            manager: tabManager,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
        let toolbar = NSToolbar(identifier: "PuraPi.inspector-button-test")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        toolbarDelegate.attach(to: toolbar)
        window.setContentSize(NSSize(width: 1_420, height: 900))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        settle(0.8)
        window.layoutIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            tabManager.closeAll()
            settle(0.1)
        }

        guard let content = window.contentView,
              let split = findSplit(in: content),
              let parent = split.superview,
              let inspectorIndex = split.arrangedSubviews.indices.last,
              let proxy = parent.subviews.compactMap({
                  $0 as? PuraPiInspectorHeaderInteractionView
              }).first,
              let detachProxy = parent.subviews.compactMap({
                  $0 as? PuraPiInspectorDetachInteractionView
              }).first
        else {
            return XCTFail("找不到 Inspector 或标题按钮命中代理")
        }

        let pane = split.arrangedSubviews[inspectorIndex]
        let expectedSplitRect = NSRect(
            x: pane.frame.maxX
                - PuraPiLayoutState.inspectorInset
                - PuraPiInspectorHeaderMetrics.trailingPadding
                - PuraPiInspectorHeaderMetrics.actionWidth,
            y: split.isFlipped
                ? split.bounds.minY + PuraPiLayoutState.inspectorInset
                : split.bounds.maxY
                    - PuraPiLayoutState.inspectorInset
                    - PuraPiInspectorHeaderMetrics.totalHeight,
            width: PuraPiInspectorHeaderMetrics.actionWidth,
            height: PuraPiInspectorHeaderMetrics.totalHeight
        )
        let expectedParentRect = parent.convert(expectedSplitRect, from: split)
        XCTAssertEqual(proxy.frame.minX, expectedParentRect.minX, accuracy: 1)
        XCTAssertEqual(proxy.frame.minY, expectedParentRect.minY, accuracy: 1)
        XCTAssertEqual(proxy.frame.width, expectedParentRect.width, accuracy: 1)
        XCTAssertEqual(proxy.frame.height, expectedParentRect.height, accuracy: 1)
        XCTAssertEqual(
            detachProxy.frame.width,
            PuraPiInspectorHeaderMetrics.detachWidth,
            accuracy: 1
        )
        XCTAssertEqual(
            detachProxy.frame.maxX + PuraPiInspectorHeaderMetrics.detachSpacing,
            proxy.frame.minX,
            accuracy: 1,
            "独立按钮应紧邻原有标题操作组左侧"
        )
        let detachButtons = detachProxy.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(detachButtons.count, 1)
        if let detachButton = detachButtons.first {
            let point = NSPoint(
                x: detachProxy.frame.minX + detachButton.frame.midX,
                y: detachProxy.frame.minY + detachButton.frame.midY
            )
            let localPoint = detachProxy.convert(point, from: parent)
            let directDetachHit = detachProxy.hitTest(localPoint)
            let detachHit = parent.hitTest(point)
            XCTAssertTrue(
                directDetachHit === detachButton,
                "独立代理自身命中错误：\(String(describing: directDetachHit))，代理 frame=\(detachProxy.frame)，按钮 frame=\(detachButton.frame)"
            )
            XCTAssertTrue(
                detachHit === detachButton,
                "独立按钮中心命中错误：\(String(describing: detachHit))，父层子视图=\(parent.subviews.map { String(describing: type(of: $0)) })"
            )
            XCTAssertFalse(detachButton.mouseDownCanMoveWindow)
            detachButton.performClick(nil)
            settle(0.05)
            XCTAssertTrue(session.inspectorLiftHint, "点击顶部独立按钮应触发边缘抬升反馈")
            session.hideInspectorLiftHint()
        }

        let buttons = proxy.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3, "应有最大化、更多、关闭三个代理按钮")
        for button in buttons {
            let point = NSPoint(
                x: proxy.frame.minX + button.frame.midX,
                y: proxy.frame.minY + button.frame.midY
            )
            let hit = parent.hitTest(point)
            XCTAssertTrue(hit === button, "按钮中心应命中透明 AppKit 代理")
            XCTAssertFalse(hit?.mouseDownCanMoveWindow ?? true, "按钮中心不能触发窗口拖动")
        }

        buttons[0].performClick(nil)
        settle(0.2)
        XCTAssertTrue(layoutState.inspectorMaximized, "最大化代理按钮应切换 Inspector 状态")

        layoutState.inspectorMaximized = false
        settle(0.2)
        buttons[2].performClick(nil)
        settle(0.2)
        XCTAssertNil(session.selectedPreview, "关闭代理按钮应清除当前预览")
    }
}
