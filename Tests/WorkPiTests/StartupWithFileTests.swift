import AppKit
import PiDomain
import SwiftUI
import XCTest
@testable import WorkPi

/// "启动时已选中文件"这条路径（恢复上次会话）的初始布局。
///
/// 与"先显示两栏、之后再打开文件"不同：右栏在第一次布局时就要存在，
/// 容易踩到 splitView 尚无真实宽度的时序问题。
@available(macOS 26.0, *)
@MainActor
final class StartupWithFileTests: XCTestCase {
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let d = WorkPiPreferences.shared
        for k in [WorkPiLayoutState.sidebarWidthKey,
                  WorkPiLayoutState.inspectorWidthKey,
                  WorkPiLayoutState.sidebarVisibleKey] {
            saved[k] = d.object(forKey: k)
        }
        d.set(290.0, forKey: WorkPiLayoutState.sidebarWidthKey)
        d.set(410.0, forKey: WorkPiLayoutState.inspectorWidthKey)
        d.set(true, forKey: WorkPiLayoutState.sidebarVisibleKey)
    }

    override func tearDown() {
        let d = WorkPiPreferences.shared
        for (k, v) in saved {
            if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private struct Host: View {
        let session: PiSessionController
        let layoutState: WorkPiLayoutState
        var body: some View {
            WorkPiNativeWorkspaceSplitView(
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

    /// 启动即带文件时，三栏几何必须正确：不能重叠、宽度要来自持久化值。
    func testLayoutIsCorrectWhenFileSelectedAtStartup() {
        let session = PiSessionController()
        session.selectedPreview = FilePreview(
            url: URL(fileURLWithPath: "/tmp/startup.md"), relativePath: "startup.md",
            kind: .markdown, text: "# hi", byteCount: 4, modificationDate: Date())
        let layoutState = WorkPiLayoutState()
        let hosting = NSHostingView(rootView: Host(session: session, layoutState: layoutState))
        hosting.autoresizingMask = [.width, .height]
        let w = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 980, height: 620)
        w.contentView = hosting
        w.setContentSize(NSSize(width: 1440, height: 900))
        w.makeKeyAndOrderFront(nil)
        w.layoutIfNeeded(); settle(0.7); w.layoutIfNeeded()
        defer { settle(0.1); w.orderOut(nil); w.contentView = nil; settle(0.1) }

        func findSplit(_ v: NSView) -> NSSplitView? {
            if let s = v as? NSSplitView { return s }
            for sub in v.subviews { if let f = findSplit(sub) { return f } }
            return nil
        }
        guard let sv = findSplit(hosting) else { return XCTFail("no split view") }
        let panes = sv.arrangedSubviews
        let widths = panes.map { $0.frame.width }
        let origins = panes.map { $0.frame.minX }
        XCTAssertGreaterThanOrEqual(panes.count, 3, "应有 Sidebar / 工作区 / Inspector 三栏，实测 \(panes.count)")

        // 栏不能重叠：每一栏的起点都应 >= 前一栏的终点。
        for i in 1..<panes.count {
            XCTAssertGreaterThanOrEqual(
                origins[i], panes[i - 1].frame.maxX - 1,
                "栏 \(i) 与前一栏重叠：origins=\(origins) widths=\(widths)")
        }

        // Sidebar 宽度应来自持久化的 290（+ 内边距），不能塌到最小值。
        XCTAssertEqual(
            widths[0] - WorkPiLayoutState.sidebarInset * 2, 290, accuracy: 4,
            "Sidebar 应为持久化宽度，实测栏位 \(widths[0])")
        // 右栏宽度应来自持久化的 410。
        XCTAssertEqual(
            widths[2] - WorkPiLayoutState.inspectorInset * 2, 410, accuracy: 4,
            "右栏应为持久化宽度，实测栏位 \(widths[2])")
    }
}
