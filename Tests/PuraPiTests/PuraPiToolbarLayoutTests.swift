import AppKit
import XCTest
@testable import PuraPi

/// 标题栏工具栏的项顺序。
///
/// 折叠开关的位置完全由项顺序决定：排在 `.sidebarTrackingSeparator` 之前的项
/// 会跟随 Sidebar 边界移动，因此「展开时贴 Sidebar 右上角、折叠后落到交通灯
/// 右侧」这个平移不需要手写动画，但顺序错了就会失效。
@MainActor
final class PuraPiToolbarLayoutTests: XCTestCase {
    private func makeDelegate() -> (PuraPiToolbarDelegate, PuraPiTabManager, PuraPiLayoutState) {
        let manager = PuraPiTabManager()
        let layoutState = PuraPiLayoutState()
        let delegate = PuraPiToolbarDelegate(
            manager: manager,
            layoutState: layoutState,
            appearanceState: PuraPiAppearanceState()
        )
        return (delegate, manager, layoutState)
    }

    /// 空工作区没有 Sidebar，也就不该出现折叠开关。
    func testEmptyWorkspaceHasNoToolbarItems() {
        let (delegate, _, _) = makeDelegate()
        XCTAssertTrue(delegate.desiredItemIdentifiers().isEmpty)
    }

    /// 展开态：弹性间距把开关推到 Sidebar 右上角，且仍在分隔符之前。
    func testExpandedSidebarPlacesToggleAtSidebarTrailingEdge() {
        let (delegate, manager, layoutState) = makeDelegate()
        manager.openProject(at: URL(fileURLWithPath: "/tmp"))
        if !layoutState.sidebarVisible { layoutState.toggleSidebar() }

        let items = delegate.desiredItemIdentifiers()
        let mode = try? XCTUnwrap(items.firstIndex(of: delegate.sidebarModeItemIdentifier))
        let flexible = try? XCTUnwrap(items.firstIndex(of: .flexibleSpace))
        let toggle = try? XCTUnwrap(items.firstIndex(of: delegate.sidebarToggleItemIdentifier))
        let separator = try? XCTUnwrap(items.firstIndex(of: .sidebarTrackingSeparator))

        XCTAssertNotNil(mode)
        XCTAssertNotNil(separator)
        if let mode, let flexible, let toggle, let separator {
            XCTAssertLessThan(mode, flexible)
            XCTAssertLessThan(flexible, toggle)
            // 必须在分隔符之前，才会跟随 Sidebar 边界平移。
            XCTAssertLessThan(toggle, separator)
        }
    }

    /// 折叠态：没有可切换的树，只留开关，并且它贴到交通灯右侧（列表首位）。
    func testCollapsedSidebarMovesToggleNextToTrafficLights() {
        let (delegate, manager, layoutState) = makeDelegate()
        manager.openProject(at: URL(fileURLWithPath: "/tmp"))
        if layoutState.sidebarVisible { layoutState.toggleSidebar() }

        let items = delegate.desiredItemIdentifiers()
        XCTAssertEqual(items.first, delegate.sidebarToggleItemIdentifier)
        XCTAssertFalse(items.contains(delegate.sidebarModeItemIdentifier))
        XCTAssertFalse(items.contains(.flexibleSpace))
    }
}
