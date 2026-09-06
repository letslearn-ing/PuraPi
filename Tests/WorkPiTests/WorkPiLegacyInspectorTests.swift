import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

/// macOS 14–25（legacy）路径的右侧检查器。
///
/// 这条路径原来缺三样东西：宽度不持久化、最大化按钮点了没反应、没有悬浮层级。
/// 无法在当前机器上真正运行 macOS 14，因此这里验证驱动它的状态层与几何常量，
/// 以及拖拽手柄的方向折算——这些是 legacy 视图唯一依赖的可测部分。
@MainActor
final class WorkPiLegacyInspectorTests: XCTestCase {
    private var savedInspector: Any?

    override func setUp() {
        super.setUp()
        savedInspector = WorkPiPreferences.shared.object(forKey: WorkPiLayoutState.inspectorWidthKey)
        WorkPiPreferences.shared.removeObject(forKey: WorkPiLayoutState.inspectorWidthKey)
    }

    override func tearDown() {
        if let savedInspector {
            WorkPiPreferences.shared.set(savedInspector, forKey: WorkPiLayoutState.inspectorWidthKey)
        } else {
            WorkPiPreferences.shared.removeObject(forKey: WorkPiLayoutState.inspectorWidthKey)
        }
        super.tearDown()
    }

    /// 左边缘手柄：向左拖（负位移）必须变宽。
    /// 符号弄反会导致"越拖越窄"，这是复用 Sidebar 手柄时最容易出的错。
    func testLeadingEdgeHandleInvertsDelta() {
        XCTAssertEqual(
            WorkPiSidebarResizeHandle.Edge.leadingEdgeOfTrailingPane.deltaSign, -1,
            "Inspector 手柄在左边缘，位移符号应取反")
        XCTAssertEqual(
            WorkPiSidebarResizeHandle.Edge.trailingEdgeOfLeadingPane.deltaSign, 1,
            "Sidebar 手柄在右边缘，位移符号不变")
    }

    /// 模拟一次向左拖动 60pt，宽度应增加 60。
    func testDragLeftWidensInspector() {
        let state = WorkPiLayoutState()
        let start = state.inspectorWidth
        let sign = WorkPiSidebarResizeHandle.Edge.leadingEdgeOfTrailingPane.deltaSign
        // 向左拖 60pt：屏幕 x 位移为 -60。
        let delta = CGFloat(-60) * sign
        state.resizeInspector(to: start + delta)
        XCTAssertEqual(state.inspectorWidth, start + 60, accuracy: 0.01)
    }

    /// legacy 路径必须真正持久化宽度（原来完全没有这一步）。
    func testLegacyResizePersists() {
        let state = WorkPiLayoutState()
        state.resizeInspector(to: 520)
        state.persistInspectorWidth()
        XCTAssertEqual(WorkPiLayoutState().inspectorWidth, 520, accuracy: 0.01,
                       "重启应保留 legacy 路径拖出的宽度")
    }

    /// 最大化状态可切换，并且是 legacy 视图用来决定是否隐藏工作区的依据。
    func testMaximizeStateToggles() {
        let state = WorkPiLayoutState()
        XCTAssertFalse(state.inspectorMaximized)
        state.inspectorMaximized = true
        XCTAssertTrue(state.inspectorMaximized)
        state.inspectorMaximized = false
        XCTAssertFalse(state.inspectorMaximized)
    }

    /// 左右两栏的悬浮内边距必须相等，否则视觉上不对称。
    func testFloatingInsetsAreSymmetric() {
        XCTAssertEqual(
            WorkPiLayoutState.inspectorInset, WorkPiLayoutState.sidebarInset,
            "左右悬浮内边距应相等")
        XCTAssertGreaterThan(WorkPiLayoutState.chromeCornerRadius, 0, "应有圆角")
    }

    /// Inspector 材质角色在两个系统上都要有明确降级，且与 Sidebar 同为
    /// behindWindow，才能得到一致的"悬浮在窗口之上"的层级感。
    func testInspectorMaterialRoleMatchesSidebarLayering() {
        // 原生 Inspector 使用独立的 Glass 表面；legacy 路径仍由同一个角色
        // 降级到 NSVisualEffectView，保持 macOS 14–25 的材质一致性。
        XCTAssertTrue(
            WorkPiMaterialRole.inspector.usesNativeGlassWhenAvailable,
            "macOS 26 Inspector 应使用独立的原生玻璃表面")
        XCTAssertEqual(
            WorkPiMaterialRole.inspector.fallbackBlendingMode,
            WorkPiMaterialRole.sidebar.fallbackBlendingMode,
            "混合模式应与 Sidebar 一致，才能得到同样的悬浮层级")
        XCTAssertEqual(
            WorkPiMaterialRole.inspector.fallbackMaterial, .sidebar,
            "legacy 降级材质应与 Sidebar 同级")
    }
}

/// 真正把 legacy 视图渲染出来，确认它能布局、宽度正确、且左边缘有拖拽手柄。
///
/// `#available` 是运行时判断，legacy 分支在任何系统上都能编译和实例化，
/// 因此可以直接托管 `FileInspectorPane` + 手柄的组合来验证几何。
@MainActor
final class WorkPiLegacyInspectorRenderTests: XCTestCase {
    private func settle(_ s: TimeInterval) {
        let d = Date().addingTimeInterval(s)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    /// 复刻 WorkPiAttachedInspector 的几何：内容宽度 + 两侧内边距。
    private struct LegacyInspectorHarness: View {
        @ObservedObject var session: PiSessionController
        @ObservedObject var layoutState: WorkPiLayoutState

        var body: some View {
            HStack(spacing: 0) {
                Color.clear.frame(maxWidth: .infinity)
                FileInspectorPane(
                    preview: session.selectedPreview,
                    editorState: session.markdownEditor,
                    layoutState: layoutState,
                    language: .chinese,
                    error: nil,
                    onRetry: {}, onClose: {}, onReveal: { _ in }, onOpen: { _ in },
                    onCopyPath: { _ in }, onCopyRelativePath: { _ in }
                )
                .frame(width: layoutState.inspectorWidth)
                .padding(.leading, WorkPiLayoutState.inspectorInset)
                .padding(.trailing, WorkPiLayoutState.inspectorInset)
                .padding(.bottom, WorkPiLayoutState.inspectorInset)
                .padding(
                    .top,
                    WorkPiLayoutState.inspectorSurfaceTopInset
                )
                .overlay(alignment: .leading) {
                    WorkPiSidebarResizeHandle(
                        width: layoutState.inspectorWidth,
                        edge: .leadingEdgeOfTrailingPane,
                        onResizeStart: {}, onResize: { _ in }, onResizeEnd: {}, onHover: { _ in }
                    )
                    .frame(width: 10)
                    .offset(x: WorkPiLayoutState.inspectorInset)
                }
            }
        }
    }

    func testLegacyInspectorRendersWithFloatingInset() {
        let defaults = WorkPiPreferences.shared
        let saved = defaults.object(forKey: WorkPiLayoutState.inspectorWidthKey)
        defaults.set(410.0, forKey: WorkPiLayoutState.inspectorWidthKey)
        defer {
            if let saved { defaults.set(saved, forKey: WorkPiLayoutState.inspectorWidthKey) }
            else { defaults.removeObject(forKey: WorkPiLayoutState.inspectorWidthKey) }
        }

        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/legacy.md"), relativePath: "legacy.md",
            kind: .markdown, text: "# legacy\n\nbody", byteCount: 16, modificationDate: Date())
        let layoutState = WorkPiLayoutState()

        let hosting = NSHostingView(
            rootView: LegacyInspectorHarness(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]
        let w = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.contentView = hosting
        w.setContentSize(NSSize(width: 1440, height: 900))
        w.makeKeyAndOrderFront(nil)
        w.layoutIfNeeded(); settle(0.5); w.layoutIfNeeded()
        defer { settle(0.1); w.orderOut(nil); w.contentView = nil; settle(0.1) }

        // 找到拖拽手柄，确认它真的在视图树里且位于右栏左侧。
        func findHandle(_ v: NSView) -> WorkPiSidebarResizeNSView? {
            if let h = v as? WorkPiSidebarResizeNSView { return h }
            for sub in v.subviews { if let f = findHandle(sub) { return f } }
            return nil
        }
        guard let handle = findHandle(hosting) else {
            return XCTFail("legacy 右栏缺少拖拽手柄")
        }

        let handleFrame = handle.convert(handle.bounds, to: hosting)
        print("[legacy] handleFrame=\(handleFrame) hostingWidth=\(hosting.bounds.width)")

        // 手柄应落在窗口右侧区域（右栏的左边界附近），而不是贴着窗口左边。
        XCTAssertGreaterThan(
            handleFrame.midX, hosting.bounds.width * 0.5,
            "手柄应在右栏左边界，实测 midX=\(handleFrame.midX)")
        XCTAssertFalse(handle.mouseDownCanMoveWindow, "手柄不应触发窗口拖拽")
        XCTAssertEqual(handle.deltaSign, -1, "legacy 右栏手柄应向左拖变宽")
    }
}
