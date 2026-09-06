import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

/// macOS 26 原生路径的 Inspector 表面与生命周期回归测试。
///
/// Inspector 不再使用 `sidebarWithViewController:`：macOS 26 的系统 Sidebar 外壳
/// 在分隔线拖动后切换外观会让中心 SwiftUI 合成层失效。普通 item 配合 Inspector
/// 自己绘制的圆角表面，并由正文 ScrollView 使用系统 scroll-edge modifier。
@available(macOS 26.0, *)
@MainActor
final class WorkPiInspectorFloatingSurfaceTests: XCTestCase {
    private final class TintState: ObservableObject {
        @Published var value: WorkPiPaneTint

        init(_ value: WorkPiPaneTint) {
            self.value = value
        }
    }

    private struct Host: View {
        let session: PiSessionController
        let layoutState: WorkPiLayoutState
        @ObservedObject var tintState: TintState

        var body: some View {
            WorkPiNativeWorkspaceSplitView(
                session: session,
                layoutState: layoutState,
                isFileSelected: true,
                sidebarVisible: true,
                sidebarWidth: layoutState.sidebarWidth,
                inspectorWidth: layoutState.inspectorWidth,
                inspectorMaximized: layoutState.inspectorMaximized,
                language: .chinese,
                sidebarTint: .purple,
                inspectorTint: tintState.value
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func makeSession() -> PiSessionController {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/workpi-surface.md"),
            relativePath: "workpi-surface.md",
            kind: .markdown,
            text: "# surface",
            byteCount: 9,
            modificationDate: Date()
        )
        return session
    }

    private func makeWindow(
        session: PiSessionController,
        layoutState: WorkPiLayoutState,
        tintState: TintState
    ) -> NSWindow {
        let hosting = NSHostingView(
            rootView: Host(
                session: session,
                layoutState: layoutState,
                tintState: tintState
            )
        )
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.75)
        window.layoutIfNeeded()
        return window
    }

    private func cleanup(_ window: NSWindow) {
        settle(0.1)
        window.orderOut(nil)
        window.contentView = nil
        settle(0.1)
    }

    func testInspectorUsesIsolatedRegularItemAndAlignedSurfaceSlot() {
        let defaults = WorkPiPreferences.shared
        let savedSidebar = defaults.object(forKey: WorkPiLayoutState.sidebarWidthKey)
        let savedInspector = defaults.object(forKey: WorkPiLayoutState.inspectorWidthKey)
        defaults.set(290.0, forKey: WorkPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: WorkPiLayoutState.inspectorWidthKey)
        defer {
            if let savedSidebar { defaults.set(savedSidebar, forKey: WorkPiLayoutState.sidebarWidthKey) }
            else { defaults.removeObject(forKey: WorkPiLayoutState.sidebarWidthKey) }
            if let savedInspector { defaults.set(savedInspector, forKey: WorkPiLayoutState.inspectorWidthKey) }
            else { defaults.removeObject(forKey: WorkPiLayoutState.inspectorWidthKey) }
        }

        let session = makeSession()
        let layoutState = WorkPiLayoutState()
        let tintState = TintState(.none)
        let window = makeWindow(session: session, layoutState: layoutState, tintState: tintState)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView)
        else { return XCTFail("找不到三栏 SplitView") }

        let panes = split.arrangedSubviews
        XCTAssertEqual(panes.count, 3, "普通 Inspector item 不应再附带尾随 spacer")

        let inspector = panes[2]
        let inset = WorkPiLayoutState.inspectorInset
        XCTAssertEqual(
            inspector.frame.width,
            layoutState.inspectorWidth + inset * 2,
            accuracy: 2,
            "Inspector 栏位应包含表面左右各一个 inset"
        )
        XCTAssertEqual(
            inspector.frame.maxX,
            split.bounds.maxX,
            accuracy: 1,
            "Inspector 栏位应延伸到窗口边界，由表面 padding 提供右侧留白"
        )

        // Sidebar 保留完整表面；左右差异转移到中心内容的前导留白，不能
        // 通过缩小 Sidebar pane 或在父层覆盖其内容来实现。
        XCTAssertEqual(
            panes[0].frame.width,
            layoutState.sidebarWidth + WorkPiLayoutState.sidebarInset * 2,
            accuracy: 2,
            "视觉间距补偿不应改变 Sidebar 的 pane 宽度"
        )
        let inspectorVisualGap = inspector.frame.minX
            + WorkPiLayoutState.inspectorInset
            - panes[1].frame.maxX
        XCTAssertEqual(
            inspectorVisualGap,
            WorkPiLayoutState.inspectorInset + split.dividerThickness,
            accuracy: 1,
            "Inspector 可见左边缘应包含 divider 与 leading inset"
        )

        let inspectorViews = descendants(of: inspector)
        XCTAssertTrue(
            inspectorViews.allSatisfy {
                let typeName = String(describing: type(of: $0))
                return !typeName.contains("NSBlurryAlleywayView")
                    && !typeName.contains("NSContainerConcentricGlassEffectView")
            },
            "Inspector 不应创建会影响中心合成的系统 Sidebar 玻璃外壳"
        )

        let inspectorHosts = inspectorViews.filter {
            let name = String(describing: type(of: $0))
            return name.contains("WorkPiInspectorHostView")
        }
        XCTAssertFalse(inspectorHosts.isEmpty, "Inspector 内容宿主不能缺失")
        XCTAssertTrue(
            inspectorHosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 },
            "Inspector 内容宿主必须可见"
        )
        if #available(macOS 26.1, *) {
            XCTAssertTrue(
                inspectorViews.allSatisfy { !($0 is WorkPiScrollEdgeEffectView) },
                "macOS 26.1+ Inspector 应使用系统 scroll-edge modifier，不应叠加手工材质"
            )
            let inspectorScrollViews = inspectorViews.compactMap { $0 as? NSScrollView }
            XCTAssertEqual(inspectorScrollViews.count, 1)
            if let inspectorScrollView = inspectorScrollViews.first {
                XCTAssertLessThan(
                    abs(inspectorScrollView.documentVisibleRect.minY),
                    100,
                    "Inspector 顶部系统 pocket 不应被错误计算成巨型内容内缩"
                )
            }
        }

        XCTAssertEqual(
            split.dividerStyle,
            .thick,
            "应使用透明的 thick divider 保留拖动几何而不绘制可见分隔线"
        )
        XCTAssertEqual(
            WorkPiLayoutState.inspectorContentTopInset,
            0,
            accuracy: 0.01,
            "Inspector 内容相对圆角表面不应额外保留顶部安全区"
        )
        XCTAssertEqual(
            WorkPiLayoutState.inspectorSurfaceTopInset,
            WorkPiLayoutState.inspectorInset,
            accuracy: 0.01,
            "Inspector 圆角表面顶部必须与窗口外框保持 8pt 悬浮间距"
        )
    }

    /// 覆盖真实报告的顺序：先改变分隔线几何，再切换有色/无色。
    func testTintChangeAfterDividerResizePreservesCenterConversation() {
        let session = makeSession()
        let layoutState = WorkPiLayoutState()
        let tintState = TintState(.purple)
        let window = makeWindow(session: session, layoutState: layoutState, tintState: tintState)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView),
              split.arrangedSubviews.count == 3
        else { return XCTFail("找不到三栏 SplitView") }

        // 模拟用户把 Inspector 拉宽，并让 AppKit 完成一次真实布局。
        let rightDivider = split.arrangedSubviews[2].frame.minX - split.dividerThickness
        split.setPosition(rightDivider - 150, ofDividerAt: 1)
        window.layoutIfNeeded()
        settle(0.35)
        window.layoutIfNeeded()
        let resizedCenter = split.arrangedSubviews[1].frame
        XCTAssertGreaterThan(resizedCenter.width, 400, "拖动后中心仍应有最小可用宽度")

        tintState.value = .blue
        settle(0.35)
        tintState.value = .none
        settle(0.75)
        window.layoutIfNeeded()

        let center = split.arrangedSubviews[1]
        XCTAssertEqual(center.frame.minX, resizedCenter.minX, accuracy: 2)
        XCTAssertEqual(center.frame.width, resizedCenter.width, accuracy: 2)
        XCTAssertGreaterThan(center.frame.width, 400, "无颜色切换后中心 pane 不能消失")

        let centerHosts = descendants(of: center).filter {
            String(describing: type(of: $0)).contains("WorkPiConversationHostView")
        }
        XCTAssertFalse(centerHosts.isEmpty, "中心对话宿主不能被 Inspector 改色移除")
        XCTAssertTrue(
            centerHosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 },
            "中心对话宿主切换后必须仍可见"
        )
    }
}
