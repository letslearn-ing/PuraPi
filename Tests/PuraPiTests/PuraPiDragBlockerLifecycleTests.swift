import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

/// 覆盖层的生命周期与状态切换。
///
/// 修右栏拖动时新增了一层覆盖视图和一批宽度状态，这些都会随
/// 「开关文件、折叠 Sidebar、切换语言、最大化」变化，需要单独确认没有副作用。
@available(macOS 26.0, *)
@MainActor
final class PuraPiDragBlockerLifecycleTests: XCTestCase {
    private var savedSidebar: Any?
    private var savedInspector: Any?
    private var savedSidebarVisible: Any?

    override func setUp() {
        super.setUp()
        let d = PuraPiPreferences.shared
        savedSidebar = d.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        savedInspector = d.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        d.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        d.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)
        // 显式固定 Sidebar 为展开：本机偏好可能存着"已折叠"，
        // 那样与 Sidebar 相关的几何断言会失去意义。
        savedSidebarVisible = d.object(forKey: PuraPiLayoutState.sidebarVisibleKey)
        d.set(true, forKey: PuraPiLayoutState.sidebarVisibleKey)
    }

    override func tearDown() {
        let d = PuraPiPreferences.shared
        if let savedSidebar { d.set(savedSidebar, forKey: PuraPiLayoutState.sidebarWidthKey) }
        else { d.removeObject(forKey: PuraPiLayoutState.sidebarWidthKey) }
        if let savedInspector { d.set(savedInspector, forKey: PuraPiLayoutState.inspectorWidthKey) }
        else { d.removeObject(forKey: PuraPiLayoutState.inspectorWidthKey) }
        if let savedSidebarVisible {
            d.set(savedSidebarVisible, forKey: PuraPiLayoutState.sidebarVisibleKey)
        } else {
            d.removeObject(forKey: PuraPiLayoutState.sidebarVisibleKey)
        }
        super.tearDown()
    }

    private struct Host: View {
        let session: PiSessionController
        let layoutState: PuraPiLayoutState
        let isFileSelected: Bool
        var body: some View {
            PuraPiNativeWorkspaceSplitView(
                session: session, layoutState: layoutState,
                isFileSelected: isFileSelected,
                sidebarVisible: layoutState.sidebarVisible,
                sidebarWidth: layoutState.sidebarWidth,
                inspectorWidth: layoutState.inspectorWidth,
                inspectorMaximized: layoutState.inspectorMaximized,
                language: .chinese)
            .frame(minWidth: 980, maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func settle(_ s: TimeInterval) {
        let d = Date().addingTimeInterval(s)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func findSplit(_ v: NSView) -> NSSplitView? {
        if let s = v as? NSSplitView { return s }
        for sub in v.subviews { if let f = findSplit(sub) { return f } }
        return nil
    }

    private func findController(_ v: NSView) -> PuraPiWorkspaceSplitViewController? {
        var node: NSResponder? = v
        while let cur = node {
            if let c = cur as? PuraPiWorkspaceSplitViewController { return c }
            node = cur.nextResponder
        }
        return nil
    }

    private func makePreview(_ name: String) -> FilePreview {
        FilePreview(
            url: URL(fileURLWithPath: "/tmp/\(name)"), relativePath: name,
            kind: .markdown, text: "# \(name)", byteCount: 8, modificationDate: Date())
    }

    private struct Rig {
        let window: NSWindow
        let hosting: NSView
        let splitView: NSSplitView
        let controller: PuraPiWorkspaceSplitViewController
        let session: PiSessionController
        let layoutState: PuraPiLayoutState
    }

    private func makeRig(fileSelected: Bool) -> Rig? {
        let session = PiSessionController()
        if fileSelected { session.selectedPreview = makePreview("a.md") }
        let layoutState = PuraPiLayoutState()
        let hosting = NSHostingView(
            rootView: Host(session: session, layoutState: layoutState, isFileSelected: fileSelected))
        hosting.autoresizingMask = [.width, .height]
        let w = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.isMovableByWindowBackground = true
        w.contentMinSize = NSSize(width: 980, height: 620)
        w.contentView = hosting
        w.setContentSize(NSSize(width: 1440, height: 900))
        w.makeKeyAndOrderFront(nil)
        w.layoutIfNeeded(); settle(0.5); w.layoutIfNeeded()
        guard let sv = findSplit(hosting), let c = findController(sv) else { return nil }
        return Rig(window: w, hosting: hosting, splitView: sv,
                   controller: c, session: session, layoutState: layoutState)
    }

    private func teardown(_ rig: Rig) {
        settle(0.1); rig.window.orderOut(nil); rig.window.contentView = nil; settle(0.1)
    }

    private func canMoveWindow(_ rig: Rig, atX x: CGFloat) -> Bool {
        let pt = rig.splitView.convert(NSPoint(x: x, y: rig.splitView.bounds.midY), to: nil)
        return rig.window.contentView?.hitTest(pt)?.mouseDownCanMoveWindow ?? true
    }

    private func visibleDividerEdge(at index: Int, in splitView: NSSplitView) -> CGFloat {
        let panes = splitView.arrangedSubviews
        if index == 0 {
            return panes[0].frame.maxX
        }
        return panes[index + 1].frame.minX + PuraPiLayoutState.inspectorInset
    }

    private func blockerCount(_ rig: Rig) -> Int {
        guard let parent = rig.splitView.superview else { return 0 }
        return parent.subviews.filter { $0 is PuraPiDividerWindowDragBlocker }.count
    }

    /// 反复布局不得堆积覆盖层。
    func testRepeatedLayoutDoesNotAccumulateBlockers() {
        guard let rig = makeRig(fileSelected: true) else { return XCTFail("rig") }
        defer { teardown(rig) }

        for _ in 1...12 {
            rig.window.setContentSize(NSSize(width: 1300 + CGFloat.random(in: 0...140), height: 900))
            rig.window.layoutIfNeeded()
            settle(0.03)
        }
        XCTAssertEqual(blockerCount(rig), 1, "覆盖层应只有一个，实测 \(blockerCount(rig))")
    }

    /// 覆盖层若被移出视图树，必须能重新装上——否则缺陷会静默复现。
    func testBlockerIsReinstalledAfterRemoval() {
        guard let rig = makeRig(fileSelected: true) else { return XCTFail("rig") }
        defer { teardown(rig) }

        guard let parent = rig.splitView.superview,
              let blocker = parent.subviews.first(where: { $0 is PuraPiDividerWindowDragBlocker })
        else { return XCTFail("覆盖层未安装") }

        blocker.removeFromSuperview()
        XCTAssertEqual(blockerCount(rig), 0)

        // 触发一次布局，应重新装上。
        rig.window.setContentSize(NSSize(width: 1380, height: 900))
        rig.window.layoutIfNeeded(); settle(0.2)

        XCTAssertEqual(blockerCount(rig), 1, "覆盖层被移除后应重新安装")
        XCTAssertTrue(
            rig.controller.diagnosticDividerDragBlockerInstalled,
            "重新安装后诊断标志应为真")

        let edge = visibleDividerEdge(at: 1, in: rig.splitView)
        XCTAssertFalse(canMoveWindow(rig, atX: edge), "重新安装后仍应禁止拖窗口")
    }

    /// 关闭文件后只剩两栏：原右分隔线位置应恢复为可拖窗口，左分隔线仍受保护。
    func testClosingFileReleasesRightDividerRegion() {
        guard let rig = makeRig(fileSelected: true) else { return XCTFail("rig") }
        defer { teardown(rig) }

        let panesBefore = rig.splitView.arrangedSubviews
        XCTAssertGreaterThanOrEqual(panesBefore.count, 3)
        let oldRightEdge = visibleDividerEdge(at: 1, in: rig.splitView)
        XCTAssertFalse(canMoveWindow(rig, atX: oldRightEdge), "有右栏时应禁止")

        // 关闭文件。
        rig.session.selectedPreview = nil
        rig.controller.update(
            isFileSelected: false, sidebarVisible: true,
            sidebarWidth: rig.layoutState.sidebarWidth,
            inspectorWidth: rig.layoutState.inspectorWidth,
            inspectorMaximized: false, language: .chinese)
        rig.window.layoutIfNeeded(); settle(0.3)

        let panesAfter = rig.splitView.arrangedSubviews
        XCTAssertEqual(
            panesAfter.count, 2,
            "关闭文件后应只剩 Sidebar 与工作区两栏")

        // 左分隔线仍受保护。
        let leftEdge = visibleDividerEdge(at: 0, in: rig.splitView)
        XCTAssertFalse(canMoveWindow(rig, atX: leftEdge), "左分隔线仍应禁止拖窗口")

        // 工作区中间（远离唯一的分隔线）应可拖窗口。
        XCTAssertTrue(
            canMoveWindow(rig, atX: panesAfter[1].frame.midX),
            "两栏状态下工作区中部应可拖窗口")
    }

    /// 反复开关文件：覆盖层不堆积，且每次都能正确保护右分隔线。
    func testToggleFileRepeatedly() {
        guard let rig = makeRig(fileSelected: false) else { return XCTFail("rig") }
        defer { teardown(rig) }

        for round in 1...4 {
            rig.session.selectedPreview = makePreview("r\(round).md")
            rig.controller.update(
                isFileSelected: true, sidebarVisible: true,
                sidebarWidth: rig.layoutState.sidebarWidth,
                inspectorWidth: rig.layoutState.inspectorWidth,
                inspectorMaximized: false, language: .chinese)
            rig.window.layoutIfNeeded(); settle(0.15)

            let panes = rig.splitView.arrangedSubviews
            XCTAssertGreaterThanOrEqual(panes.count, 3, "第 \(round) 轮应有三栏")
            let edge = visibleDividerEdge(at: 1, in: rig.splitView)
            XCTAssertFalse(canMoveWindow(rig, atX: edge), "第 \(round) 轮右分隔线应受保护")
            XCTAssertEqual(blockerCount(rig), 1, "第 \(round) 轮覆盖层应只有一个")

            rig.session.selectedPreview = nil
            rig.controller.update(
                isFileSelected: false, sidebarVisible: true,
                sidebarWidth: rig.layoutState.sidebarWidth,
                inspectorWidth: rig.layoutState.inspectorWidth,
                inspectorMaximized: false, language: .chinese)
            rig.window.layoutIfNeeded(); settle(0.15)
            XCTAssertEqual(blockerCount(rig), 1, "第 \(round) 轮关闭后覆盖层仍应只有一个")
        }
    }

    /// 折叠 Sidebar 后，左分隔线消失，剩下的右分隔线仍受保护。
    func testCollapsingSidebarKeepsRightDividerProtected() {
        guard let rig = makeRig(fileSelected: true) else { return XCTFail("rig") }
        defer { teardown(rig) }

        rig.layoutState.toggleSidebar()   // 折叠
        rig.controller.update(
            isFileSelected: true, sidebarVisible: false,
            sidebarWidth: rig.layoutState.sidebarWidth,
            inspectorWidth: rig.layoutState.inspectorWidth,
            inspectorMaximized: false, language: .chinese)
        rig.window.layoutIfNeeded(); settle(0.4)

        let rightEdge = visibleDividerEdge(at: 1, in: rig.splitView)
        XCTAssertFalse(
            canMoveWindow(rig, atX: rightEdge),
            "Sidebar 折叠后右分隔线仍应受保护")

        // 恢复
        rig.layoutState.toggleSidebar()
        rig.controller.update(
            isFileSelected: true, sidebarVisible: true,
            sidebarWidth: rig.layoutState.sidebarWidth,
            inspectorWidth: rig.layoutState.inspectorWidth,
            inspectorMaximized: false, language: .chinese)
        rig.window.layoutIfNeeded(); settle(0.4)
        XCTAssertEqual(blockerCount(rig), 1)
    }

    /// Inspector 最大化再还原，宽度应回到用户设定值。
    func testMaximizeAndRestoreInspectorWidth() {
        guard let rig = makeRig(fileSelected: true) else { return XCTFail("rig") }
        defer { teardown(rig) }

        // 普通 Inspector item 的栏位宽度 = 内容宽度 + 两侧 inset；
        // 右侧留白由自绘表面的 padding 提供。
        let originalWidth = rig.splitView.arrangedSubviews[2].frame.width
        XCTAssertEqual(
            originalWidth - PuraPiLayoutState.inspectorInset * 2, 410, accuracy: 4,
            "内容宽度应来自持久化的 410，实测栏位 \(originalWidth)")

        rig.layoutState.inspectorMaximized = true
        rig.controller.update(
            isFileSelected: true, sidebarVisible: true,
            sidebarWidth: rig.layoutState.sidebarWidth,
            inspectorWidth: rig.layoutState.inspectorWidth,
            inspectorMaximized: true, language: .chinese)
        rig.window.layoutIfNeeded(); settle(0.3)
        let maximized = rig.splitView.arrangedSubviews[2].frame.width
        XCTAssertGreaterThan(maximized, originalWidth, "最大化后应更宽")

        rig.layoutState.inspectorMaximized = false
        rig.controller.update(
            isFileSelected: true, sidebarVisible: true,
            sidebarWidth: rig.layoutState.sidebarWidth,
            inspectorWidth: rig.layoutState.inspectorWidth,
            inspectorMaximized: false, language: .chinese)
        rig.window.layoutIfNeeded(); settle(0.3)
        XCTAssertEqual(
            rig.splitView.arrangedSubviews[2].frame.width, originalWidth, accuracy: 3,
            "还原后应回到原宽度")
    }

    /// 切换语言不应破坏覆盖层或宽度。
    func testLanguageSwitchPreservesBlockerAndWidths() {
        guard let rig = makeRig(fileSelected: true) else { return XCTFail("rig") }
        defer { teardown(rig) }

        let widthBefore = rig.splitView.arrangedSubviews[2].frame.width
        rig.controller.update(
            isFileSelected: true, sidebarVisible: true,
            sidebarWidth: rig.layoutState.sidebarWidth,
            inspectorWidth: rig.layoutState.inspectorWidth,
            inspectorMaximized: false, language: .english)
        rig.window.layoutIfNeeded(); settle(0.3)

        XCTAssertEqual(blockerCount(rig), 1, "语言切换后覆盖层应仍只有一个")
        XCTAssertEqual(
            rig.splitView.arrangedSubviews[2].frame.width, widthBefore, accuracy: 3,
            "语言切换不应改变右栏宽度")
        let edge = visibleDividerEdge(at: 1, in: rig.splitView)
        XCTAssertFalse(canMoveWindow(rig, atX: edge), "语言切换后右分隔线仍应受保护")
    }
}

/// 覆盖层不得吞掉正常交互。
///
/// 它铺满整个 splitView 区域，只靠 `hitTest` 在区外返回 nil 来放行。
/// 一旦这个放行逻辑有误，文件树点击、对话输入、右栏滚动全部会失灵——
/// 这是本次改动最需要防守的回归面。
@available(macOS 26.0, *)
@MainActor
final class PuraPiDragBlockerPassthroughTests: XCTestCase {
    private var savedSidebar: Any?
    private var savedInspector: Any?

    override func setUp() {
        super.setUp()
        let d = PuraPiPreferences.shared
        savedSidebar = d.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        savedInspector = d.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        d.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        d.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)
    }

    override func tearDown() {
        let d = PuraPiPreferences.shared
        if let savedSidebar { d.set(savedSidebar, forKey: PuraPiLayoutState.sidebarWidthKey) }
        else { d.removeObject(forKey: PuraPiLayoutState.sidebarWidthKey) }
        if let savedInspector { d.set(savedInspector, forKey: PuraPiLayoutState.inspectorWidthKey) }
        else { d.removeObject(forKey: PuraPiLayoutState.inspectorWidthKey) }
        super.tearDown()
    }

    private struct Host: View {
        let session: PiSessionController
        let layoutState: PuraPiLayoutState
        var body: some View {
            PuraPiNativeWorkspaceSplitView(
                session: session, layoutState: layoutState,
                isFileSelected: true,
                sidebarVisible: layoutState.sidebarVisible,
                sidebarWidth: layoutState.sidebarWidth,
                inspectorWidth: layoutState.inspectorWidth,
                inspectorMaximized: layoutState.inspectorMaximized,
                language: .chinese)
            .frame(minWidth: 980, maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func settle(_ s: TimeInterval) {
        let d = Date().addingTimeInterval(s)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func findSplit(_ v: NSView) -> NSSplitView? {
        if let s = v as? NSSplitView { return s }
        for sub in v.subviews { if let f = findSplit(sub) { return f } }
        return nil
    }

    func testInteriorPointsAreNotSwallowedByBlocker() {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/pass.md"), relativePath: "pass.md",
            kind: .markdown, text: "# hi\n\nbody", byteCount: 12, modificationDate: Date())
        let layoutState = PuraPiLayoutState()

        let hosting = NSHostingView(rootView: Host(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]
        let w = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.isMovableByWindowBackground = true
        w.contentMinSize = NSSize(width: 980, height: 620)
        w.contentView = hosting
        w.setContentSize(NSSize(width: 1440, height: 900))
        w.makeKeyAndOrderFront(nil)
        w.layoutIfNeeded(); settle(0.6); w.layoutIfNeeded()
        defer { settle(0.1); w.orderOut(nil); w.contentView = nil; settle(0.1) }

        guard let sv = findSplit(hosting) else { return XCTFail("no split view") }
        let panes = sv.arrangedSubviews
        guard panes.count >= 3 else { return XCTFail("期望三栏") }

        // 三栏内部各取若干点，均不应命中覆盖层。
        let probes: [(String, NSPoint)] = [
            ("Sidebar 中部", NSPoint(x: panes[0].frame.midX, y: sv.bounds.midY)),
            ("Sidebar 上部", NSPoint(x: panes[0].frame.midX, y: sv.bounds.height * 0.8)),
            ("工作区中部", NSPoint(x: panes[1].frame.midX, y: sv.bounds.midY)),
            ("工作区下部", NSPoint(x: panes[1].frame.midX, y: sv.bounds.height * 0.2)),
            ("右栏中部", NSPoint(x: panes[2].frame.midX, y: sv.bounds.midY)),
            ("右栏上部", NSPoint(x: panes[2].frame.midX, y: sv.bounds.height * 0.85)),
        ]
        for (label, point) in probes {
            let hit = sv.hitTest(sv.convert(point, to: sv.superview))
            XCTAssertFalse(
                hit is PuraPiDividerWindowDragBlocker,
                "\(label) 被覆盖层吞掉了，正常交互会失灵")
        }

        // 距分隔线 20pt（远超 ±7pt 命中区）也不应被拦。
        let rightEdge = panes[2].frame.minX + PuraPiLayoutState.inspectorInset
        for offset in [-20.0, 20.0] as [CGFloat] {
            let p = NSPoint(x: rightEdge + offset, y: sv.bounds.midY)
            let hit = sv.hitTest(sv.convert(p, to: sv.superview))
            XCTAssertFalse(
                hit is PuraPiDividerWindowDragBlocker,
                "距分隔线 \(offset)pt 处不应被覆盖层拦截")
        }
    }
}
