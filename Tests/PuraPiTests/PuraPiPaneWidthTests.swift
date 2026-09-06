import XCTest
@testable import PuraPi

/// Inspector（右侧文件检查器）的宽度状态必须与 Sidebar 完全对称：
/// 同样的区间夹取、同样的“改了才发布”、同样的显式持久化。
/// 不对称的话，用户拖右栏时会得到与左栏不同的手感（越界、跳变或不保留）。
@MainActor
final class PuraPiPaneWidthTests: XCTestCase {
    /// 每个用例都在干净的偏好域上跑，并在结束后恢复，避免污染开发机上的真实设置。
    private var savedSidebarWidth: Any?
    private var savedInspectorWidth: Any?

    override func setUp() {
        super.setUp()
        let defaults = PuraPiPreferences.shared
        savedSidebarWidth = defaults.object(forKey: PuraPiLayoutState.sidebarWidthKey)
        savedInspectorWidth = defaults.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        defaults.removeObject(forKey: PuraPiLayoutState.sidebarWidthKey)
        defaults.removeObject(forKey: PuraPiLayoutState.inspectorWidthKey)
    }

    override func tearDown() {
        let defaults = PuraPiPreferences.shared
        restore(savedSidebarWidth, forKey: PuraPiLayoutState.sidebarWidthKey, in: defaults)
        restore(savedInspectorWidth, forKey: PuraPiLayoutState.inspectorWidthKey, in: defaults)
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testInspectorWidthDefaultsWhenNothingStored() {
        let state = PuraPiLayoutState()
        XCTAssertEqual(state.inspectorWidth, PuraPiLayoutState.defaultInspectorWidth)
    }

    /// 拖到区间之外时夹到边界，而不是把布局撑坏。
    func testInspectorWidthClampsToBounds() {
        let state = PuraPiLayoutState()

        state.resizeInspector(to: 10)
        XCTAssertEqual(state.inspectorWidth, PuraPiLayoutState.minimumInspectorWidth)

        state.resizeInspector(to: 5_000)
        XCTAssertEqual(state.inspectorWidth, PuraPiLayoutState.maximumInspectorWidth)
    }

    /// 只有显式 persist 才落盘：拖动过程中不写偏好，避免高频 IO。
    func testInspectorWidthPersistsOnlyWhenRequested() {
        let state = PuraPiLayoutState()
        state.resizeInspector(to: 500)
        XCTAssertNil(
            PuraPiPreferences.shared.object(forKey: PuraPiLayoutState.inspectorWidthKey)
        )

        state.persistInspectorWidth()
        XCTAssertEqual(
            PuraPiPreferences.shared.double(forKey: PuraPiLayoutState.inspectorWidthKey),
            500,
            accuracy: 0.001
        )

        // 新实例读回同一宽度，等价于“重启应用后仍保留”。
        XCTAssertEqual(PuraPiLayoutState().inspectorWidth, 500)
    }

    /// 存量偏好中的越界值也要夹取，否则一次异常写入会永久卡住布局。
    func testStoredOutOfRangeInspectorWidthIsClamped() {
        PuraPiPreferences.shared.set(9_999.0, forKey: PuraPiLayoutState.inspectorWidthKey)
        XCTAssertEqual(
            PuraPiLayoutState().inspectorWidth,
            PuraPiLayoutState.maximumInspectorWidth
        )
    }

    /// 两侧宽度互不影响：共用同一个 layoutState 但是独立的键。
    func testSidebarAndInspectorWidthsAreIndependent() {
        let state = PuraPiLayoutState()
        let originalSidebarWidth = state.sidebarWidth

        state.resizeInspector(to: 360)
        XCTAssertEqual(state.sidebarWidth, originalSidebarWidth)

        state.resizeSidebar(to: 300)
        XCTAssertEqual(state.inspectorWidth, 360)
    }

    /// Native Sidebar 的首条 divider 为 0pt；额外差值转移到中心内容的
    /// leading inset，不应改变 Sidebar 的 pane 宽度。
    func testNativeSidebarCenterLeadingInsetMatchesInspectorGap() {
        XCTAssertEqual(
            PuraPiLayoutState.nativeSidebarCenterLeadingInset(for: 9),
            PuraPiLayoutState.inspectorInset + 9,
            accuracy: 0.01
        )
        XCTAssertEqual(
            PuraPiLayoutState.nativeSidebarCenterLeadingInset(for: 0),
            PuraPiLayoutState.inspectorInset,
            accuracy: 0.01
        )
    }
}
