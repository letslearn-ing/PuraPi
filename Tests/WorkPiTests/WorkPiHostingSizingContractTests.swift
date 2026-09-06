import AppKit
import SwiftUI
import XCTest

/// `NSSplitViewController` 放进 `NSHostingView` 时的尺寸契约。
///
/// 这组用例不含任何 WorkPi 代码，纯粹记录 AppKit/SwiftUI 的互操作行为：
/// 不实现 `sizeThatFits` 时 divider 拖动是坏的（窗口被缩、或压力转移到相邻栏）。
/// 将来 SDK 行为变化时能立刻发现。
@MainActor
final class WorkPiHostingSizingContractTests: XCTestCase {
    private struct Rep: NSViewControllerRepresentable {
        func makeNSViewController(context: Context) -> NSSplitViewController {
            let c = NSSplitViewController()
            c.splitView.isVertical = true
            func pane() -> NSViewController { let v = NSViewController(); v.view = NSView(); return v }
            let sb = NSSplitViewItem(sidebarWithViewController: pane())
            sb.minimumThickness = 236; sb.maximumThickness = 476
            sb.holdingPriority = NSLayoutConstraint.Priority(rawValue: 262)
            sb.allowsFullHeightLayout = true
            let mid = NSSplitViewItem(viewController: pane())
            mid.minimumThickness = 420
            mid.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
            let insp = NSSplitViewItem(inspectorWithViewController: pane())
            insp.minimumThickness = 280; insp.maximumThickness = 720
            insp.holdingPriority = NSLayoutConstraint.Priority(rawValue: 261)
            c.addSplitViewItem(sb); c.addSplitViewItem(mid); c.addSplitViewItem(insp)
            return c
        }
        func updateNSViewController(_ c: NSSplitViewController, context: Context) {}
    }

    /// 候选修复：把 split controller 包进一个用 autoresizing 驱动的普通容器，
    /// 让 SwiftUI 的约束求解看不到 split view 自身的尺寸诉求。
    private struct IsolatedRep: NSViewControllerRepresentable {
        func makeNSViewController(context: Context) -> NSViewController {
            let split = WorkPiHostingSizingContractTests.makeStockSplitController()
            let container = NSViewController()
            container.view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 860))
            container.addChild(split)
            split.view.translatesAutoresizingMaskIntoConstraints = true
            split.view.frame = container.view.bounds
            split.view.autoresizingMask = [.width, .height]
            container.view.addSubview(split.view)
            return container
        }
        func updateNSViewController(_ c: NSViewController, context: Context) {}
    }

    private struct Isolated: View {
        var body: some View {
            IsolatedRep().frame(minWidth: 980, maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// 候选修复 B：显式实现 sizeThatFits，直接接受 SwiftUI 提议的尺寸，
    /// 不让 AppKit 的固有尺寸参与协商。
    private struct SizedRep: NSViewControllerRepresentable {
        func makeNSViewController(context: Context) -> NSSplitViewController {
            WorkPiHostingSizingContractTests.makeStockSplitController()
        }
        func updateNSViewController(_ c: NSSplitViewController, context: Context) {}
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsViewController: NSSplitViewController,
            context: Context
        ) -> CGSize? {
            CGSize(width: proposal.width ?? 1440, height: proposal.height ?? 860)
        }
    }

    private struct Sized: View {
        var body: some View {
            SizedRep().frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private struct WithFrame: View {
        var body: some View {
            Rep().frame(minWidth: 980, maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
    private struct Bare: View {
        var body: some View { Rep() }
    }

    private func settle(_ s: TimeInterval) {
        let d = Date().addingTimeInterval(s)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private struct ProbeResult {
        let sidebarBefore: CGFloat
        let sidebarAfter: CGFloat
        let inspectorDelta: CGFloat
    }

    @discardableResult
    private func probe<V: View>(_ label: String, _ root: V) -> ProbeResult {
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1440, height: 860),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 860))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded(); settle(0.5); window.layoutIfNeeded()

        func find(_ v: NSView) -> NSSplitView? {
            if let s = v as? NSSplitView { return s }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        guard let splitView = find(hosting) else {
            XCTFail("no split view")
            return ProbeResult(sidebarBefore: 0, sidebarAfter: 0, inspectorDelta: 0)
        }
        splitView.setPosition(306, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - 411 - splitView.dividerThickness, ofDividerAt: 1)
        window.layoutIfNeeded(); settle(0.2)

        let panes = splitView.arrangedSubviews
        let wBefore = window.frame.width
        let inspBefore = panes[2].frame.width
        let sbBefore = panes[0].frame.width
        let y = splitView.bounds.midY
        let startX = panes[2].frame.minX - splitView.dividerThickness / 2
        let endX = startX - 160
        func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: splitView.convert(NSPoint(x: x, y: y), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
        }
        var q: [NSEvent] = []
        for i in 1...12 { q.append(ev(.leftMouseDragged, startX + (endX - startX) * CGFloat(i) / 12)) }
        q.append(ev(.leftMouseUp, endX))
        for e in q.reversed() { window.postEvent(e, atStart: true) }
        splitView.mouseDown(with: ev(.leftMouseDown, startX))
        settle(0.35); window.layoutIfNeeded()

        print("[hprobe \(label)] window \(wBefore)->\(window.frame.width) insp \(inspBefore)->\(panes[2].frame.width) sidebar \(sbBefore)->\(panes[0].frame.width)")
        let result = ProbeResult(
            sidebarBefore: sbBefore,
            sidebarAfter: panes[0].frame.width,
            inspectorDelta: panes[2].frame.width - inspBefore
        )
        settle(0.05); window.orderOut(nil); window.contentView = nil; settle(0.05)
        return result
    }

    /// 对照：同一套 split view 直接当 contentViewController，不经过 NSHostingView。
    func testDirectContentViewControllerWorks() {
        let c = Self.makeStockSplitController()
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1440, height: 860),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentViewController = c
        window.setContentSize(NSSize(width: 1440, height: 860))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded(); settle(0.4)
        let splitView = c.splitView
        splitView.setPosition(306, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - 411 - splitView.dividerThickness, ofDividerAt: 1)
        window.layoutIfNeeded(); settle(0.2)
        let panes = splitView.arrangedSubviews
        let wBefore = window.frame.width
        let inspBefore = panes[2].frame.width
        let sbBefore = panes[0].frame.width
        let y = splitView.bounds.midY
        let startX = panes[2].frame.minX - splitView.dividerThickness / 2
        let endX = startX - 160
        func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: splitView.convert(NSPoint(x: x, y: y), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
        }
        var q: [NSEvent] = []
        for i in 1...12 { q.append(ev(.leftMouseDragged, startX + (endX - startX) * CGFloat(i) / 12)) }
        q.append(ev(.leftMouseUp, endX))
        for e in q.reversed() { window.postEvent(e, atStart: true) }
        splitView.mouseDown(with: ev(.leftMouseDown, startX))
        settle(0.35); window.layoutIfNeeded()
        print("[hprobe direct] window \(wBefore)->\(window.frame.width) insp \(inspBefore)->\(panes[2].frame.width) sidebar \(sbBefore)->\(panes[0].frame.width)")
        settle(0.05); window.orderOut(nil); window.contentViewController = nil; settle(0.05)
    }

    /// 与 Rep.makeNSViewController 完全相同的配置，供不经 SwiftUI 的对照使用。
    static func makeStockSplitController() -> NSSplitViewController {
        let c = NSSplitViewController()
        c.splitView.isVertical = true
        func pane() -> NSViewController { let v = NSViewController(); v.view = NSView(); return v }
        let sb = NSSplitViewItem(sidebarWithViewController: pane())
        sb.minimumThickness = 236; sb.maximumThickness = 476
        sb.holdingPriority = NSLayoutConstraint.Priority(rawValue: 262)
        sb.allowsFullHeightLayout = true
        let mid = NSSplitViewItem(viewController: pane())
        mid.minimumThickness = 420
        mid.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        let insp = NSSplitViewItem(inspectorWithViewController: pane())
        insp.minimumThickness = 280; insp.maximumThickness = 720
        insp.holdingPriority = NSLayoutConstraint.Priority(rawValue: 261)
        c.addSplitViewItem(sb); c.addSplitViewItem(mid); c.addSplitViewItem(insp)
        return c
    }

    /// 锁定结论：只有实现了 `sizeThatFits` 的变体能正确拖动。
    ///
    /// 这些用例不含任何 WorkPi 代码，纯粹记录 AppKit/SwiftUI 的互操作缺陷，
    /// 以便将来 SDK 行为变化时能立刻发现。
    func testOnlySizeThatFitsVariantDragsCorrectly() {
        let withFrame = probe("withFrame", WithFrame())
        let sized = probe("sized", Sized())

        // 缺陷现象：inspector 几乎不动，且 sidebar 被误伤。
        XCTAssertLessThan(
            withFrame.inspectorDelta, 40,
            "无 sizeThatFits 时 inspector 本应几乎不动（记录缺陷），实测增量 \(withFrame.inspectorDelta)"
        )
        XCTAssertNotEqual(
            withFrame.sidebarAfter, withFrame.sidebarBefore, accuracy: 0.4,
            "无 sizeThatFits 时 sidebar 本应被误伤（记录缺陷）"
        )

        // 实现 sizeThatFits 后：inspector 跟随 160pt 拖动，sidebar 完全不动。
        XCTAssertEqual(
            sized.inspectorDelta, 160, accuracy: 12,
            "sized 变体 inspector 应加宽约 160pt，实测 \(sized.inspectorDelta)"
        )
        XCTAssertEqual(
            sized.sidebarAfter, sized.sidebarBefore, accuracy: 1,
            "sized 变体 sidebar 不应被动过"
        )
    }
}
