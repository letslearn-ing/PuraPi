import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import PuraPi

/// Inspector 的栏位生命周期回归测试。
///
/// macOS 26 原生路径使用普通 `NSSplitViewItem`；右侧 8pt 留白由 Inspector 自己
/// 的 SwiftUI padding 提供；四边保留悬浮间距，内容相对表面不额外下移，
/// 同时避免多余的 divider 参与宽度计算。
@available(macOS 26.0, *)
@MainActor
final class PuraPiInspectorSurfaceLifecycleTests: XCTestCase {
    private var savedSidebar: Any?
    private var savedInspector: Any?
    private var savedSidebarVisible: Any?

    override func setUp() {
        super.setUp()
        let defaults = PuraPiPreferences.shared
        savedSidebar = defaults.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        savedInspector = defaults.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        savedSidebarVisible = defaults.object(forKey: PuraPiLayoutState.sidebarVisibleKey)
        defaults.set(290.0, forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: PuraPiLayoutState.inspectorWidthKey)
        defaults.set(true, forKey: PuraPiLayoutState.sidebarVisibleKey)
    }

    override func tearDown() {
        let defaults = PuraPiPreferences.shared
        if let savedSidebar { defaults.set(savedSidebar, forKey: PuraPiLayoutState.sidebarWidthKey) }
        else { defaults.removeObject(forKey: PuraPiLayoutState.sidebarWidthKey) }
        if let savedInspector { defaults.set(savedInspector, forKey: PuraPiLayoutState.inspectorWidthKey) }
        else { defaults.removeObject(forKey: PuraPiLayoutState.inspectorWidthKey) }
        if let savedSidebarVisible { defaults.set(savedSidebarVisible, forKey: PuraPiLayoutState.sidebarVisibleKey) }
        else { defaults.removeObject(forKey: PuraPiLayoutState.sidebarVisibleKey) }
        super.tearDown()
    }

    private struct Host: View {
        let session: PiSessionController
        let layoutState: PuraPiLayoutState
        let isFileSelected: Bool

        var body: some View {
            PuraPiNativeWorkspaceSplitView(
                session: session,
                layoutState: layoutState,
                isFileSelected: isFileSelected,
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

    private func findSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = findSplit(in: child) { return split }
        }
        return nil
    }

    private func findController(in view: NSView) -> PuraPiWorkspaceSplitViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let controller = current as? PuraPiWorkspaceSplitViewController { return controller }
            responder = current.nextResponder
        }
        for child in view.subviews {
            if let controller = findController(in: child) { return controller }
        }
        return nil
    }

    private func preview(_ name: String) -> FilePreview {
        FilePreview(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            relativePath: name,
            kind: .markdown,
            text: "# \(name)",
            byteCount: 8,
            modificationDate: Date()
        )
    }

    private func makeWindow(
        session: PiSessionController,
        layoutState: PuraPiLayoutState,
        isFileSelected: Bool
    ) -> NSWindow {
        let hosting = NSHostingView(
            rootView: Host(
                session: session,
                layoutState: layoutState,
                isFileSelected: isFileSelected
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
        settle(0.6)
        window.layoutIfNeeded()
        return window
    }

    private func cleanup(_ window: NSWindow) {
        settle(0.1)
        window.orderOut(nil)
        window.contentView = nil
        settle(0.1)
    }

    func testInspectorTogglesWithoutTrailingPlaceholder() {
        let session = PiSessionController()
        let layoutState = PuraPiLayoutState()
        let window = makeWindow(session: session, layoutState: layoutState, isFileSelected: false)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView),
              let controller = findController(in: contentView)
        else { return XCTFail("setup") }
        XCTAssertEqual(split.arrangedSubviews.count, 2)

        for round in 1...3 {
            session.selectedPreview = preview("toggle-\(round).md")
            controller.update(
                isFileSelected: true,
                sidebarVisible: true,
                sidebarWidth: layoutState.sidebarWidth,
                inspectorWidth: layoutState.inspectorWidth,
                inspectorMaximized: false,
                language: .chinese
            )
            window.layoutIfNeeded()
            settle(0.2)
            XCTAssertEqual(split.arrangedSubviews.count, 3, "第 \(round) 轮应有三栏")
            XCTAssertEqual(
                split.arrangedSubviews[2].frame.width,
                layoutState.inspectorWidth + PuraPiLayoutState.inspectorInset * 2,
                accuracy: 2,
                "第 \(round) 轮 Inspector 栏位应包含两侧 padding"
            )

            session.selectedPreview = nil
            controller.update(
                isFileSelected: false,
                sidebarVisible: true,
                sidebarWidth: layoutState.sidebarWidth,
                inspectorWidth: layoutState.inspectorWidth,
                inspectorMaximized: false,
                language: .chinese
            )
            window.layoutIfNeeded()
            settle(0.2)
            XCTAssertEqual(split.arrangedSubviews.count, 2, "第 \(round) 轮关闭后应回到两栏")
        }
    }

    func testInspectorSurfaceSurvivesMaximizeCycle() {
        let session = PiSessionController()
        session.selectedPreview = preview("maximize.md")
        let layoutState = PuraPiLayoutState()
        let window = makeWindow(session: session, layoutState: layoutState, isFileSelected: true)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView),
              let controller = findController(in: contentView)
        else { return XCTFail("setup") }
        let widthBefore = split.arrangedSubviews[2].frame.width

        layoutState.inspectorMaximized = true
        controller.update(
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            inspectorMaximized: true,
            language: .chinese
        )
        window.layoutIfNeeded()
        settle(0.25)
        XCTAssertEqual(split.arrangedSubviews.count, 3)
        XCTAssertGreaterThan(split.arrangedSubviews[2].frame.width, widthBefore)

        layoutState.inspectorMaximized = false
        controller.update(
            isFileSelected: true,
            sidebarVisible: true,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            inspectorMaximized: false,
            language: .chinese
        )
        window.layoutIfNeeded()
        settle(0.25)
        XCTAssertEqual(split.arrangedSubviews[2].frame.width, widthBefore, accuracy: 3)
    }

    func testInitialMaximizeStateIsAppliedAfterControllerCreation() {
        let session = PiSessionController()
        session.selectedPreview = preview("initial-maximize.md")
        let layoutState = PuraPiLayoutState()
        layoutState.inspectorMaximized = true
        let window = makeWindow(session: session, layoutState: layoutState, isFileSelected: true)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView)
        else { return XCTFail("setup") }
        XCTAssertEqual(split.arrangedSubviews.count, 3)
        XCTAssertGreaterThan(
            split.arrangedSubviews[2].frame.width,
            layoutState.inspectorWidth + PuraPiLayoutState.inspectorInset * 2
        )
    }

    func testInspectorSurfaceKeepsRightInsetWhenSidebarCollapses() {
        let session = PiSessionController()
        session.selectedPreview = preview("collapse.md")
        let layoutState = PuraPiLayoutState()
        let window = makeWindow(session: session, layoutState: layoutState, isFileSelected: true)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView),
              let controller = findController(in: contentView)
        else { return XCTFail("setup") }

        layoutState.toggleSidebar()
        controller.update(
            isFileSelected: true,
            sidebarVisible: false,
            sidebarWidth: layoutState.sidebarWidth,
            inspectorWidth: layoutState.inspectorWidth,
            inspectorMaximized: false,
            language: .chinese
        )
        window.layoutIfNeeded()
        settle(0.35)

        XCTAssertEqual(split.arrangedSubviews.count, 3)
        let inspector = split.arrangedSubviews[2]
        XCTAssertEqual(inspector.frame.maxX, split.bounds.maxX, accuracy: 1)
        XCTAssertEqual(
            inspector.frame.width,
            layoutState.inspectorWidth + PuraPiLayoutState.inspectorInset * 2,
            accuracy: 2
        )
    }
}
