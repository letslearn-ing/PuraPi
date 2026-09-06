import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

/// Inspector 外观切换的系统合成回归测试。
///
/// macOS 26 的 `sidebarWithViewController:` 外壳会在 Inspector 拖动后与动态外观
/// 切换发生合成冲突；生产实现改为普通 item + 自绘表面，因而不应再出现该系统外壳。
@available(macOS 26.0, *)
@MainActor
final class WorkPiInspectorSystemChromeTests: XCTestCase {
    private var savedSidebarWidth: Any?
    private var savedInspectorWidth: Any?

    override func setUp() {
        super.setUp()
        let defaults = WorkPiPreferences.shared
        savedSidebarWidth = defaults.object(forKey: WorkPiLayoutState.sidebarWidthKey)
        savedInspectorWidth = defaults.object(forKey: WorkPiLayoutState.inspectorWidthKey)
        defaults.set(290.0, forKey: WorkPiLayoutState.sidebarWidthKey)
        defaults.set(410.0, forKey: WorkPiLayoutState.inspectorWidthKey)
    }

    override func tearDown() {
        let defaults = WorkPiPreferences.shared
        if let savedSidebarWidth { defaults.set(savedSidebarWidth, forKey: WorkPiLayoutState.sidebarWidthKey) }
        else { defaults.removeObject(forKey: WorkPiLayoutState.sidebarWidthKey) }
        if let savedInspectorWidth { defaults.set(savedInspectorWidth, forKey: WorkPiLayoutState.inspectorWidthKey) }
        else { defaults.removeObject(forKey: WorkPiLayoutState.inspectorWidthKey) }
        super.tearDown()
    }

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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func makeWindow(tintState: TintState) -> (NSWindow, WorkPiLayoutState) {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/workpi-chrome.md"),
            relativePath: "workpi-chrome.md",
            kind: .markdown,
            text: "# chrome",
            byteCount: 8,
            modificationDate: Date()
        )
        let layoutState = WorkPiLayoutState()
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
        return (window, layoutState)
    }

    private func findSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = findSplit(in: child) { return split }
        }
        return nil
    }

    private func cleanup(_ window: NSWindow) {
        settle(0.1)
        window.orderOut(nil)
        window.contentView = nil
        settle(0.1)
    }

    func testNoColorUsesOwnNeutralSurfaceWithoutSystemSidebarChrome() {
        let tintState = TintState(.none)
        let (window, layoutState) = makeWindow(tintState: tintState)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView)
        else { return XCTFail("找不到三栏 SplitView") }

        let panes = split.arrangedSubviews
        XCTAssertEqual(panes.count, 3)
        let inspectorViews = descendants(of: panes[2])
        XCTAssertTrue(
            inspectorViews.allSatisfy {
                let name = String(describing: type(of: $0))
                return !name.contains("NSBlurryAlleywayView")
                    && !name.contains("NSContainerConcentricGlassEffectView")
            },
            "无颜色 Inspector 不应创建系统 Sidebar 玻璃外壳"
        )
        XCTAssertEqual(
            panes[2].frame.width,
            layoutState.inspectorWidth + WorkPiLayoutState.inspectorInset * 2,
            accuracy: 2,
            "自绘表面的栏位应包含左右两个 inset"
        )

        let centerHosts = descendants(of: panes[1]).filter {
            String(describing: type(of: $0)).contains("WorkPiConversationHostView")
        }
        XCTAssertFalse(centerHosts.isEmpty)
        XCTAssertTrue(centerHosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 })
    }

    func testResizeThenSwitchThroughColoredAndNoColorKeepsCenterVisible() {
        let tintState = TintState(.purple)
        let (window, _) = makeWindow(tintState: tintState)
        defer { cleanup(window) }

        guard let contentView = window.contentView,
              let split = findSplit(in: contentView),
              split.arrangedSubviews.count == 3
        else { return XCTFail("找不到三栏 SplitView") }

        let rightDivider = split.arrangedSubviews[2].frame.minX - split.dividerThickness
        split.setPosition(rightDivider - 180, ofDividerAt: 1)
        window.layoutIfNeeded()
        settle(0.35)
        let centerBefore = split.arrangedSubviews[1].frame

        tintState.value = .blue
        settle(0.3)
        tintState.value = .none
        settle(0.75)
        window.layoutIfNeeded()

        let center = split.arrangedSubviews[1]
        XCTAssertEqual(center.frame.minX, centerBefore.minX, accuracy: 2)
        XCTAssertEqual(center.frame.width, centerBefore.width, accuracy: 2)
        XCTAssertGreaterThan(center.frame.width, 400)
        let hosts = descendants(of: center).filter {
            String(describing: type(of: $0)).contains("WorkPiConversationHostView")
        }
        XCTAssertTrue(hosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 })
    }
}
