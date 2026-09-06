import AppKit
import SwiftUI
import XCTest
@testable import WorkPi

/// Runtime 错误必须出现在对话底部的局部通知中，而不是只存在于控制器属性里。
@MainActor
final class WorkPiRuntimeErrorPresentationTests: XCTestCase {
    func testRuntimeErrorBannerRendersItsMessage() {
        let hosting = NSHostingView(
            rootView: ErrorBanner(
                text: "Pi Runtime 的 RPC 输出已结束。",
                onDismiss: {}
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 56)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 56),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        XCTAssertTrue(allText(in: hosting).contains("Pi Runtime 的 RPC 输出已结束。"))
    }

    func testRuntimeNoticeBannerRendersItsMessage() {
        let hosting = NSHostingView(
            rootView: RuntimeNoticeBanner(
                text: "Agent 已停止，但 Pi Runtime 已退出。",
                onDismiss: {}
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 56)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 56),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        XCTAssertTrue(allText(in: hosting).contains("Agent 已停止，但 Pi Runtime 已退出。"))
    }

    private func allText(in view: NSView) -> String {
        var values: [String] = []
        if let field = view as? NSTextField {
            values.append(field.stringValue)
        }
        if let button = view as? NSButton {
            values.append(button.title)
        }
        for child in view.subviews {
            values.append(allText(in: child))
        }
        return values.joined(separator: "\n")
    }
}
