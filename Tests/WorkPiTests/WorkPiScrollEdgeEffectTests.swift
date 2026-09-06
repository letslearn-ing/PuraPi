import AppKit
import SwiftUI
import XCTest
@testable import WorkPi

/// AppKit 托管滚动视图的顶部失焦效果回归测试。
@MainActor
final class WorkPiScrollEdgeEffectTests: XCTestCase {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    func testEffectIsHiddenAtTopAndAppearsAfterScrolling() throws {
        let (scrollView, effect, window) = makeScrollFixture(documentHeight: 1_800)
        defer { cleanup(scrollView: scrollView, effect: effect, window: window) }

        let material = try XCTUnwrap(effect.subviews.first as? NSVisualEffectView)
        XCTAssertNotNil(material.maskImage)
        XCTAssertTrue(material.isHidden)

        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 120))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(0.05)

        XCTAssertFalse(material.isHidden)
        XCTAssertGreaterThan(material.alphaValue, 0)

        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(0.05)
        XCTAssertTrue(material.isHidden)
    }

    @available(macOS 26.1, *)
    func testNativeContainerUsesPublicTopAccessory() {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 500)
        )
        scrollView.documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 1_800)
        )
        scrollView.hasVerticalScroller = true
        let controller = WorkPiNativeScrollEdgeContainerController(scrollView: scrollView)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        controller.view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 400, height: 500)
        controller.view.autoresizingMask = [.width, .height]
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.1)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.installScrollEdgeAccessory())
        // viewport 的 layout 生命周期会重复请求；幂等成功不能触发异步忙循环。
        XCTAssertTrue(controller.installScrollEdgeAccessory())

        XCTAssertEqual(controller.splitViewItems.count, 1)
        let item = controller.splitViewItems[0]
        XCTAssertTrue(item.viewController.view === scrollView)
        XCTAssertEqual(item.topAlignedAccessoryViewControllers.count, 1)
        let accessory = item.topAlignedAccessoryViewControllers[0]
        XCTAssertFalse(accessory.automaticallyAppliesContentInsets)
        XCTAssertEqual(
            accessory.view.intrinsicContentSize.height,
            WorkPiTitlebarTabs.tabBarHeight,
            accuracy: 0.01,
            "系统 accessory 必须有真实固有高度，否则 AppKit 会将滚动边缘层压成不可见的 0pt"
        )
        XCTAssertGreaterThan(accessory.view.frame.height, 1)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertTrue(
            descendants(of: controller.view).allSatisfy {
                !($0 is WorkPiScrollEdgeEffectView)
            },
            "macOS 26.1+ 不应再叠加旧的手工材质 fallback"
        )

        window.orderOut(nil)
        window.contentView = nil
    }

    func testShortDocumentDoesNotInstallVisibleEffect() throws {
        let (scrollView, effect, window) = makeScrollFixture(documentHeight: 200)
        defer { cleanup(scrollView: scrollView, effect: effect, window: window) }

        let material = try XCTUnwrap(effect.subviews.first as? NSVisualEffectView)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(0.05)

        XCTAssertTrue(material.isHidden)
    }

    func testEffectIsPointerTransparent() {
        let (scrollView, effect, window) = makeScrollFixture(documentHeight: 1_800)
        defer { cleanup(scrollView: scrollView, effect: effect, window: window) }

        XCTAssertNil(effect.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testDetachRestoresScrollNotificationSettings() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_800))
        scrollView.documentView = document
        scrollView.postsBoundsChangedNotifications = false
        scrollView.contentView.postsBoundsChangedNotifications = false
        document.postsBoundsChangedNotifications = false
        document.postsFrameChangedNotifications = false

        let effect = WorkPiScrollEdgeEffectView(frame: .zero)
        effect.attach(to: scrollView)
        XCTAssertTrue(scrollView.postsBoundsChangedNotifications)
        XCTAssertTrue(scrollView.contentView.postsBoundsChangedNotifications)
        XCTAssertTrue(document.postsBoundsChangedNotifications)
        XCTAssertTrue(document.postsFrameChangedNotifications)

        effect.detach()
        XCTAssertFalse(scrollView.postsBoundsChangedNotifications)
        XCTAssertFalse(scrollView.contentView.postsBoundsChangedNotifications)
        XCTAssertFalse(document.postsBoundsChangedNotifications)
        XCTAssertFalse(document.postsFrameChangedNotifications)
    }

    func testAttachmentFindsTheNearestSwiftUIScrollView() throws {
        let root = NSHostingView(rootView: AttachmentHost())
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.1)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let effects = descendants(of: root).compactMap { $0 as? WorkPiScrollEdgeEffectView }
        XCTAssertEqual(effects.count, 1)
        let scrollViews = descendants(of: root).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrollViews.count, 1)
        XCTAssertGreaterThan(scrollViews[0].documentView?.bounds.height ?? 0, scrollViews[0].bounds.height)
    }

    private func makeScrollFixture(
        documentHeight: CGFloat
    ) -> (NSScrollView, WorkPiScrollEdgeEffectView, NSWindow) {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 500)
        )
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let document = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: documentHeight)
        )
        scrollView.documentView = document

        let effect = WorkPiScrollEdgeEffectView(frame: .zero)
        effect.autoresizingMask = [.width]
        scrollView.addFloatingSubview(effect, for: .vertical)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        effect.attach(to: scrollView)
        window.layoutIfNeeded()
        settle(0.05)
        return (scrollView, effect, window)
    }

    private func cleanup(
        scrollView: NSScrollView,
        effect: WorkPiScrollEdgeEffectView,
        window: NSWindow
    ) {
        effect.detach()
        effect.removeFromSuperview()
        window.orderOut(nil)
        window.contentView = nil
        _ = scrollView
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private struct AttachmentHost: View {
        var body: some View {
            ScrollView {
                WorkPiScrollEdgeEffectAttachment()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    ForEach(0..<80, id: \.self) { index in
                        Text("row \(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
