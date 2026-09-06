import AppKit
import PiDomain
import PiRPC
import SwiftUI
import XCTest
@testable import WorkPi

/// 右侧 Inspector 独立窗口的展示与生命周期回归测试。
@available(macOS 26.0, *)
@MainActor
final class WorkPiInspectorWindowLifecycleTests: XCTestCase {
    private struct SplitHost: View {
        @ObservedObject var session: PiSessionController
        @ObservedObject var layoutState: WorkPiLayoutState
        let coordinator: WorkPiInspectorWindowCoordinator
        let tab: WorkPiProjectTab

        var body: some View {
            WorkPiNativeWorkspaceSplitView(
                session: session,
                layoutState: layoutState,
                isFileSelected: session.selectedFileURL != nil,
                inspectorDetached: session.inspectorDetached,
                onToggleInspectorDetached: {
                    coordinator.toggle(tab: tab)
                },
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    func testDetachAndReattachKeepTheSameSessionAndEditorState() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-inspector-window-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("design.md")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try "# Design\n\ncontent".write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return XCTFail("无法创建测试文件：\(error)")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let tabs = WorkPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        tabs.openProject(at: root)
        guard let tab = tabs.selectedTab else { return XCTFail("项目标签未创建") }
        let session = tab.session
        session.selectedFileURL = file
        session.selectedPreview = FilePreview(
            url: file,
            relativePath: "design.md",
            kind: .markdown,
            text: "# Design\n\ncontent",
            byteCount: 17,
            modificationDate: Date()
        )

        let defaultsName = "WorkPi-inspector-window-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let appearanceState = WorkPiAppearanceState(defaults: defaults)
        let layoutState = WorkPiLayoutState()
        let coordinator = WorkPiInspectorWindowCoordinator(
            tabs: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
        defer {
            coordinator.shutdown()
            tabs.closeAll()
        }

        let hosting = NSHostingView(
            rootView: SplitHost(
                session: session,
                layoutState: layoutState,
                coordinator: coordinator,
                tab: tab
            )
        )
        hosting.autoresizingMask = [.width, .height]
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1_420, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        mainWindow.contentView = hosting
        mainWindow.setContentSize(NSSize(width: 1_420, height: 900))
        mainWindow.makeKeyAndOrderFront(nil)
        coordinator.attachMainWindow(mainWindow)
        mainWindow.layoutIfNeeded()
        settle(0.45)
        mainWindow.layoutIfNeeded()
        defer {
            mainWindow.orderOut(nil)
            mainWindow.contentView = nil
            settle(0.1)
        }

        guard let split = findSplit(in: hosting) else {
            return XCTFail("找不到主工作区 SplitView")
        }
        XCTAssertEqual(split.arrangedSubviews.count, 3)
        let inspectorPane = split.arrangedSubviews[2]
        let paneInWindow = inspectorPane.convert(inspectorPane.bounds, to: nil)
        let paneOnScreen = mainWindow.convertToScreen(paneInWindow)
        let expectedInspectorWindowFrame = paneOnScreen
        let selectedURL = session.selectedFileURL
        let editorState = session.markdownEditor

        coordinator.requestDetach(tab: tab)
        XCTAssertTrue(session.inspectorLiftHint)
        mainWindow.layoutIfNeeded()
        XCTAssertEqual(split.arrangedSubviews.count, 3, "边缘反馈期间主栏仍应保持可见")
        settle(0.45)
        mainWindow.layoutIfNeeded()

        XCTAssertFalse(session.inspectorLiftHint)
        XCTAssertTrue(session.inspectorDetached)
        XCTAssertEqual(session.selectedFileURL, selectedURL)
        XCTAssertTrue(session.markdownEditor === editorState)
        XCTAssertEqual(coordinator.detachedWindows.count, 1)
        XCTAssertEqual(split.arrangedSubviews.count, 2, "分离后主窗口只应保留 Sidebar 与对话")
        var rememberedFloatingFrame: NSRect?
        if let detachedWindow = coordinator.detachedWindows.first {
            XCTAssertTrue(detachedWindow.isVisible)
            XCTAssertEqual(
                detachedWindow.frame.minX,
                expectedInspectorWindowFrame.minX,
                accuracy: 3,
                "首次分离应继承 Inspector 原屏幕横坐标"
            )
            XCTAssertEqual(
                detachedWindow.frame.minY,
                expectedInspectorWindowFrame.minY,
                accuracy: 3,
                "首次分离应继承 Inspector 原屏幕纵坐标"
            )
            XCTAssertEqual(
                detachedWindow.frame.width,
                expectedInspectorWindowFrame.width,
                accuracy: 3,
                "首次分离应继承 Inspector 原窗口宽度"
            )
            XCTAssertEqual(
                detachedWindow.frame.height,
                expectedInspectorWindowFrame.height,
                accuracy: 3,
                "首次分离应继承 Inspector 原窗口高度"
            )
            var movedFrame = detachedWindow.frame
            movedFrame.origin.x -= 72
            detachedWindow.setFrame(movedFrame, display: false)
            rememberedFloatingFrame = detachedWindow.frame
            let viewNames = [detachedWindow.contentView].compactMap { $0 }
                .flatMap { [$0] + descendants(of: $0) }
                .map { String(describing: type(of: $0)) }
            XCTAssertTrue(
                viewNames.contains(where: { $0.contains("NSHostingView") }),
                "独立窗口必须由 SwiftUI 宿主承载（实际：\(viewNames)）"
            )
            let detachedContent = detachedWindow.contentView ?? NSView()
            let proxies = descendants(of: detachedContent)
                .compactMap { $0 as? WorkPiInspectorHeaderInteractionView }
            XCTAssertEqual(proxies.count, 1, "独立窗口应有唯一的标题按钮命中代理")
            let detachProxies = descendants(of: detachedContent)
                .compactMap { $0 as? WorkPiInspectorDetachInteractionView }
            XCTAssertEqual(detachProxies.count, 1, "独立窗口应有唯一的挂回按钮命中代理")
        }

        coordinator.reattach(tab: tab)
        mainWindow.layoutIfNeeded()
        settle(0.45)
        mainWindow.layoutIfNeeded()

        XCTAssertFalse(session.inspectorDetached)
        XCTAssertTrue(coordinator.detachedWindows.isEmpty)
        XCTAssertEqual(split.arrangedSubviews.count, 3, "挂回后主窗口应恢复第三栏")
        XCTAssertEqual(session.selectedFileURL, selectedURL)

        // 用户直接点击浮动窗口的红色关闭按钮时，语义仍是挂回主栏，而不是关闭文件。
        coordinator.detach(tab: tab)
        settle(0.35)
        if let rememberedFloatingFrame,
           let restoredWindow = coordinator.detachedWindows.first {
            XCTAssertEqual(
                restoredWindow.frame.minX,
                rememberedFloatingFrame.minX,
                accuracy: 3,
                "再次分离应保留用户调整后的横向位置"
            )
            XCTAssertEqual(
                restoredWindow.frame.minY,
                rememberedFloatingFrame.minY,
                accuracy: 3,
                "再次分离应保留用户调整后的纵向位置"
            )
            XCTAssertEqual(restoredWindow.frame.width, rememberedFloatingFrame.width, accuracy: 3)
            XCTAssertEqual(restoredWindow.frame.height, rememberedFloatingFrame.height, accuracy: 3)
        }
        coordinator.detachedWindows.first?.close()
        settle(0.45)
        mainWindow.layoutIfNeeded()
        XCTAssertFalse(session.inspectorDetached)
        XCTAssertEqual(split.arrangedSubviews.count, 3)
        XCTAssertEqual(session.selectedFileURL, selectedURL)

        // 关闭文件按钮的语义不同：它清除选择并让协调器关闭空浮动窗口。
        coordinator.detach(tab: tab)
        settle(0.35)
        session.clearFileSelection()
        settle(0.45)
        mainWindow.layoutIfNeeded()
        XCTAssertTrue(coordinator.detachedWindows.isEmpty)
        XCTAssertFalse(session.inspectorDetached)
        XCTAssertNil(session.selectedFileURL)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
    }

    func testDetachedWindowsStayBoundToTheirProjectTab() {
        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-inspector-tab-one-\(UUID())", isDirectory: true)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-inspector-tab-two-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let tabs = WorkPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        tabs.openProject(at: firstRoot)
        guard let firstTab = tabs.selectedTab else { return XCTFail("第一个标签未创建") }
        tabs.openProject(at: secondRoot)
        guard let secondTab = tabs.selectedTab else { return XCTFail("第二个标签未创建") }
        let firstFile = firstRoot.appendingPathComponent("one.md")
        let secondFile = secondRoot.appendingPathComponent("two.md")
        firstTab.session.selectedFileURL = firstFile
        secondTab.session.selectedFileURL = secondFile
        firstTab.session.selectedPreview = FilePreview(
            url: firstFile,
            relativePath: "one.md",
            kind: .markdown,
            text: "one",
            byteCount: 3,
            modificationDate: nil
        )
        secondTab.session.selectedPreview = FilePreview(
            url: secondFile,
            relativePath: "two.md",
            kind: .markdown,
            text: "two",
            byteCount: 3,
            modificationDate: nil
        )

        let defaultsName = "WorkPi-inspector-tabs-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let coordinator = WorkPiInspectorWindowCoordinator(
            tabs: tabs,
            layoutState: WorkPiLayoutState(),
            appearanceState: WorkPiAppearanceState(defaults: defaults)
        )
        defer {
            coordinator.shutdown()
            tabs.closeAll()
        }

        coordinator.detach(tab: firstTab)
        coordinator.detach(tab: secondTab)
        XCTAssertTrue(firstTab.session.inspectorDetached)
        XCTAssertTrue(secondTab.session.inspectorDetached)
        XCTAssertEqual(coordinator.detachedWindows.count, 2)

        coordinator.reattach(tab: firstTab)
        XCTAssertFalse(firstTab.session.inspectorDetached)
        XCTAssertTrue(secondTab.session.inspectorDetached)
        XCTAssertEqual(coordinator.detachedWindows.count, 1)

        // 关闭第一个标签只清理它的窗口，不影响第二个标签的 Inspector。
        tabs.close(firstTab)
        settle(0.2)
        XCTAssertEqual(coordinator.detachedWindows.count, 1)
        XCTAssertTrue(secondTab.session.inspectorDetached)
    }

    func testDetachWithoutASelectedFileDoesNothing() {
        let tabs = WorkPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-inspector-empty-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            tabs.closeAll()
        }
        tabs.openProject(at: root)
        guard let tab = tabs.selectedTab else { return XCTFail("项目标签未创建") }

        let defaultsName = "WorkPi-inspector-empty-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let coordinator = WorkPiInspectorWindowCoordinator(
            tabs: tabs,
            layoutState: WorkPiLayoutState(),
            appearanceState: WorkPiAppearanceState(defaults: defaults)
        )

        coordinator.detach(tab: tab)
        XCTAssertFalse(tab.session.inspectorDetached)
        XCTAssertTrue(coordinator.detachedWindows.isEmpty)
        coordinator.shutdown()
    }
}
