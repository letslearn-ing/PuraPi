import AppKit
import PiDomain
import PiRPC
import SwiftUI
import XCTest
@testable import PuraPi

/// 从真实 `ContentView` 入口验证 Inspector 颜色变化不会影响中心对话。
///
/// 之前仅用一个简化的 `NSHostingView` 宿主测试分栏；这里把实际的
/// `PuraPiTabManager → ContentView → SessionWorkspaceView` 链路也覆盖上，
/// 直接对应设置窗口改色时的生产路径。
@MainActor
final class PuraPiContentViewTintIntegrationTests: XCTestCase {
    private struct Root: View {
        @ObservedObject var tabs: PuraPiTabManager
        @ObservedObject var layoutState: PuraPiLayoutState
        @ObservedObject var appearanceState: PuraPiAppearanceState

        var body: some View {
            ContentView(
                tabs: tabs,
                layoutState: layoutState,
                appearanceState: appearanceState
            )
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

    private func findComposer(in view: NSView) -> NSTextField? {
        descendants(of: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.placeholderString == "输入指令…" })
    }

    func testInspectorNoColorAtInitialInstallPreservesCenterConversation() {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-initial-none-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: projectURL,
                withIntermediateDirectories: true
            )
        } catch {
            return XCTFail("无法创建临时项目：\(error)")
        }
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let tabs = PuraPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        tabs.openProject(at: projectURL)
        guard let tab = tabs.selectedTab else {
            return XCTFail("项目标签未创建")
        }
        let selectedURL = projectURL.appendingPathComponent("AGENTS.md")
        tab.session.selectedFileURL = selectedURL
        tab.session.selectedPreview = FilePreview(
            url: selectedURL,
            relativePath: "AGENTS.md",
            kind: .markdown,
            text: "# Agents",
            byteCount: 8,
            modificationDate: Date()
        )
        tab.session.conversation = [
            ConversationItem(kind: .user, text: "启动时保留这条对话")
        ]

        let defaultsDomain = "PuraPi-initial-none-state-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsDomain)!
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let appearanceState = PuraPiAppearanceState(defaults: defaults)
        appearanceState.setInspectorTint(.none)
        let layoutState = PuraPiLayoutState()
        let hosting = NSHostingView(
            rootView: Root(
                tabs: tabs,
                layoutState: layoutState,
                appearanceState: appearanceState
            )
        )
        hosting.autoresizingMask = [.width, .height]
        let window = PuraPiWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        let toolbarDelegate = PuraPiToolbarDelegate(
            manager: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
        let toolbar = NSToolbar(identifier: "PuraPi.initialNoneTintTest")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        toolbarDelegate.attach(to: toolbar)
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.9)
        window.layoutIfNeeded()
        defer {
            tabs.closeAll()
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let split = findSplit(in: hosting),
              split.arrangedSubviews.count >= 3
        else { return XCTFail("找不到真实 ContentView 中的三栏 SplitView") }

        let panes = split.arrangedSubviews
        XCTAssertGreaterThan(panes[1].frame.width, 400, "启动即无颜色时中心工作区不能消失")
        let conversationHosts = descendants(of: panes[1]).filter {
            String(describing: type(of: $0)).contains("PuraPiConversationHostView")
        }
        XCTAssertFalse(conversationHosts.isEmpty, "启动即无颜色时中心对话宿主不能缺失")
        XCTAssertTrue(
            conversationHosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 },
            "启动即无颜色时中心对话宿主必须可见"
        )
        let conversationViewports = descendants(of: panes[1]).filter {
            String(describing: type(of: $0)).contains("PuraPiConversationViewport")
        }
        XCTAssertFalse(conversationViewports.isEmpty, "启动即无颜色时中心 viewport 不能缺失")
        XCTAssertTrue(
            conversationViewports.allSatisfy { !$0.isHidden && $0.frame.height > 300 },
            "启动即无颜色时中心 viewport 必须有有效布局"
        )
    }

    func testInspectorNoColorDoesNotRemoveCenterConversation() {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-content-tint-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: projectURL,
                withIntermediateDirectories: true
            )
        } catch {
            return XCTFail("无法创建临时项目：\(error)")
        }
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let tabs = PuraPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        tabs.openProject(at: projectURL)
        guard let tab = tabs.selectedTab else {
            return XCTFail("项目标签未创建")
        }
        let selectedURL = projectURL.appendingPathComponent("AGENTS.md")
        tab.session.selectedFileURL = selectedURL
        tab.session.selectedPreview = FilePreview(
            url: selectedURL,
            relativePath: "AGENTS.md",
            kind: .markdown,
            text: "# Agents",
            byteCount: 8,
            modificationDate: Date()
        )
        tab.session.conversation = [
            ConversationItem(kind: .user, text: "保留这条对话"),
            ConversationItem(kind: .assistant, text: "对话仍应可见")
        ]
        tab.session.draftPrompt = "继续输入"

        let defaultsDomain = "PuraPi-content-tint-state-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsDomain)!
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let appearanceState = PuraPiAppearanceState(defaults: defaults)
        let layoutState = PuraPiLayoutState()
        let hosting = NSHostingView(
            rootView: Root(
                tabs: tabs,
                layoutState: layoutState,
                appearanceState: appearanceState
            )
        )
        hosting.autoresizingMask = [.width, .height]
        let window = PuraPiWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        let toolbarDelegate = PuraPiToolbarDelegate(
            manager: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
        let toolbar = NSToolbar(identifier: "PuraPi.contentTintTest")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        toolbarDelegate.attach(to: toolbar)
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.8)
        window.layoutIfNeeded()
        defer {
            tabs.closeAll()
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let split = findSplit(in: hosting),
              split.arrangedSubviews.count >= 3
        else { return XCTFail("找不到真实 ContentView 中的三栏 SplitView") }

        let centerBefore = split.arrangedSubviews[1].frame
        XCTAssertGreaterThan(centerBefore.width, 400, "切换前中心工作区应可见")

        appearanceState.setInspectorTint(.none)
        settle(0.8)
        window.layoutIfNeeded()

        let panes = split.arrangedSubviews
        XCTAssertEqual(panes[1].frame.minX, centerBefore.minX, accuracy: 2)
        XCTAssertEqual(panes[1].frame.width, centerBefore.width, accuracy: 2)
        XCTAssertGreaterThan(panes[1].frame.width, 400, "无颜色后中心工作区不能消失")

        let conversationHosts = descendants(of: panes[1]).filter {
            String(describing: type(of: $0)).contains("PuraPiConversationHostView")
        }
        XCTAssertFalse(conversationHosts.isEmpty, "中心对话宿主不能被颜色切换移除")
        XCTAssertTrue(
            conversationHosts.allSatisfy { !$0.isHidden && $0.alphaValue > 0 },
            "中心对话宿主切换后必须仍可见"
        )

        let conversationViewports = descendants(of: panes[1]).filter {
            String(describing: type(of: $0)).contains("PuraPiConversationViewport")
        }
        XCTAssertFalse(conversationViewports.isEmpty, "中心对话 viewport 不能被移除")
        XCTAssertTrue(
            conversationViewports.allSatisfy { !$0.isHidden && $0.frame.height > 300 },
            "中心对话 viewport 切换后必须仍有有效高度"
        )
        let conversationTextViews = descendants(of: panes[1]).compactMap { $0 as? NSTextView }
        XCTAssertFalse(conversationTextViews.isEmpty, "中心对话内容视图不能被移除")

        let neutralSurfacesInCenter = descendants(of: panes[1]).filter {
            String(describing: type(of: $0)).contains("PuraPiInspectorNeutralSurfaceView")
        }
        XCTAssertTrue(
            neutralSurfacesInCenter.isEmpty,
            "Inspector 的无颜色覆盖层不能进入中心工作区"
        )

        // 主题切换只更新视觉树，不应改变三栏几何或让中心宿主消失。
        appearanceState.setTheme(id: "purapi.midnight")
        settle(0.8)
        window.layoutIfNeeded()
        let panesAfterTheme = split.arrangedSubviews
        XCTAssertEqual(panesAfterTheme[1].frame.minX, centerBefore.minX, accuracy: 2)
        XCTAssertEqual(panesAfterTheme[1].frame.width, centerBefore.width, accuracy: 2)
        XCTAssertGreaterThan(panesAfterTheme[1].frame.width, 400)
    }

    func testComposerAcceptsMouseAndKeyboardWhenMarkdownInspectorIsOpen() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Inspector 只在 macOS 26+ 路径运行")
        }
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-composer-input-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: projectURL,
                withIntermediateDirectories: true
            )
        } catch {
            return XCTFail("无法创建临时项目：\(error)")
        }
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let tabs = PuraPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        tabs.openProject(at: projectURL)
        guard let tab = tabs.selectedTab else { return XCTFail("项目标签未创建") }
        let selectedURL = projectURL.appendingPathComponent("AGENTS.md")
        tab.session.selectedFileURL = selectedURL
        tab.session.selectedPreview = FilePreview(
            url: selectedURL,
            relativePath: "AGENTS.md",
            kind: .markdown,
            text: "# Agents",
            byteCount: 8,
            modificationDate: Date()
        )

        let defaultsDomain = "PuraPi-composer-input-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsDomain)!
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let appearanceState = PuraPiAppearanceState(defaults: defaults)
        let layoutState = PuraPiLayoutState()
        let hosting = NSHostingView(
            rootView: Root(
                tabs: tabs,
                layoutState: layoutState,
                appearanceState: appearanceState
            )
        )
        hosting.autoresizingMask = [.width, .height]
        let window = PuraPiWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.8)
        window.layoutIfNeeded()
        defer {
            tabs.closeAll()
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let split = findSplit(in: hosting), split.arrangedSubviews.count >= 3 else {
            return XCTFail("找不到带 Inspector 的三栏布局")
        }
        let center = split.arrangedSubviews[1]
        let fields = descendants(of: center).compactMap { $0 as? NSTextField }
        guard let composerField = fields.first(where: { $0.placeholderString == "输入指令…" }) else {
            return XCTFail("找不到 Composer 输入框")
        }
        XCTAssertTrue(composerField.isEditable)

        // 使用真实的 AppKit mouse event（鼠标事件）走完整窗口分发链，
        // 不用直接调用控件 action，确保 Inspector 存在时焦点仍能到达 Composer。
        let localPoint = NSPoint(x: composerField.bounds.midX, y: composerField.bounds.midY)
        // `to: nil` 返回窗口 base 坐标（不是屏幕坐标），正好是 NSEvent.locationInWindow
        // 所需的坐标系。
        let pointInWindow = composerField.convert(localPoint, to: nil)
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ) else {
            return XCTFail("无法创建 Composer 鼠标事件")
        }
        // NSTextView.mouseDown 会从应用事件队列读取后续 mouseUp；先入队，避免
        // 测试线程在 AppKit 的鼠标跟踪循环中等待永远不会到达的事件。
        NSApp.postEvent(mouseUp, atStart: true)
        window.sendEvent(mouseDown)
        settle(0.1)

        let editor = composerField.currentEditor()
        XCTAssertNotNil(editor, "Inspector 打开时点击 Composer 后应创建文本编辑器")
        XCTAssertTrue(
            window.firstResponder === editor || window.firstResponder === composerField,
            "Inspector 打开时 Composer 应获得键盘焦点，实际 firstResponder=\(String(describing: window.firstResponder))"
        )

        // 再发送一个键盘事件，验证焦点不仅存在，而且能写入绑定值。
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ) else { return XCTFail("无法创建 Composer 键盘事件") }
        window.sendEvent(keyDown)
        settle(0.1)
        XCTAssertTrue(
            tab.session.draftPrompt.contains("x"),
            "Inspector 打开时 Composer 应能接收键盘输入，实际 draft=\(tab.session.draftPrompt.debugDescription)"
        )
    }

    func testComposerAcceptsMouseAndKeyboardAfterSelectingMarkdownInExistingWorkspace() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Inspector 只在 macOS 26+ 路径运行")
        }
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-composer-transition-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: projectURL,
                withIntermediateDirectories: true
            )
            try "# Agents\n\n真实选择路径".write(
                to: projectURL.appendingPathComponent("AGENTS.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            return XCTFail("无法准备临时项目：\(error)")
        }
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let tabs = PuraPiTabManager(makeTransport: { _ in FakePiRPCTransport() })
        tabs.openProject(at: projectURL)
        guard let tab = tabs.selectedTab else { return XCTFail("项目标签未创建") }
        tab.session.conversation = [
            ConversationItem(kind: .user, text: "已有对话")
        ]

        let defaultsDomain = "PuraPi-composer-transition-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsDomain)!
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let appearanceState = PuraPiAppearanceState(defaults: defaults)
        let layoutState = PuraPiLayoutState()
        let hosting = NSHostingView(
            rootView: Root(
                tabs: tabs,
                layoutState: layoutState,
                appearanceState: appearanceState
            )
        )
        hosting.autoresizingMask = [.width, .height]
        let window = PuraPiWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        settle(0.8)

        // 先让工作区以“无 Inspector”状态完成布局，再走用户点击文件后的状态转换。
        guard let splitBefore = findSplit(in: hosting) else {
            return XCTFail("找不到初始三栏布局")
        }
        XCTAssertEqual(splitBefore.arrangedSubviews.count, 2)
        // 先覆盖另一种竞态：如果用户在选择文件前已经正在 Composer 中输入，
        // Inspector 的初始聚焦请求也不能覆盖这个已有的用户焦点。
        let preselectionComposer = descendants(of: splitBefore.arrangedSubviews[1])
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.placeholderString == "输入指令…" })
        guard let preselectionComposer,
              window.makeFirstResponder(preselectionComposer)
        else { return XCTFail("选择文件前无法聚焦 Composer") }
        tab.session.selectFile(projectURL.appendingPathComponent("AGENTS.md"))
        settle(0.1)
        guard let composerAfterSelection = findComposer(in: hosting) else {
            return XCTFail("选择 Markdown 后找不到 Composer")
        }
        XCTAssertTrue(
            window.firstResponder === composerAfterSelection.currentEditor()
                || window.firstResponder === composerAfterSelection,
            "已有 Composer 焦点时，Inspector 不能抢走输入目标；实际=\(String(describing: window.firstResponder))"
        )
        tab.session.clearFileSelection()
        settle(0.3)
        guard let splitAfterClear = findSplit(in: hosting), splitAfterClear.arrangedSubviews.count == 2 else {
            return XCTFail("清除文件选择后未恢复两栏布局")
        }
        // 让 Inspector 的自动初始聚焦路径可重复，同时不让测试依赖 SwiftUI
        // 默认把 Composer 设为 firstResponder 的实现细节。
        _ = window.makeFirstResponder(nil)
        tab.session.selectFile(projectURL.appendingPathComponent("AGENTS.md"))
        // 尽量在 Inspector 仍处于异步预览更新阶段点击 Composer，覆盖竞态。
        settle(0.1)
        window.layoutIfNeeded()
        defer {
            tabs.closeAll()
            window.orderOut(nil)
            window.contentView = nil
            settle(0.1)
        }

        guard let split = findSplit(in: hosting), split.arrangedSubviews.count >= 3 else {
            return XCTFail("选择 Markdown 后未安装 Inspector")
        }
        let center = split.arrangedSubviews[1]
        let inspector = split.arrangedSubviews[2]
        let inspectorEditors = descendants(of: inspector)
            .compactMap { $0 as? NSTextView }
            .filter(\.isEditable)
        guard let initiallyFocusedInspectorEditor = inspectorEditors.first else {
            return XCTFail("找不到 Markdown Inspector 的编辑器")
        }
        XCTAssertTrue(
            window.firstResponder === initiallyFocusedInspectorEditor,
            "动态选择 Markdown 后应只在初始阶段聚焦 Inspector 编辑器，实际=\(String(describing: window.firstResponder))"
        )
        guard let composerField = descendants(of: center)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.placeholderString == "输入指令…" })
        else { return XCTFail("找不到转换后的 Composer 输入框") }
        XCTAssertTrue(composerField.isEditable)

        let localPoint = NSPoint(x: composerField.bounds.midX, y: composerField.bounds.midY)
        // `to: nil` 返回窗口 base 坐标（不是屏幕坐标），正好是 NSEvent.locationInWindow
        // 所需的坐标系。
        let pointInWindow = composerField.convert(localPoint, to: nil)
        let composerRectInSplit = split.convert(composerField.bounds, from: composerField)
        let inspectorRect = split.arrangedSubviews[2].frame
        let headerViews = descendants(of: hosting).filter {
            String(describing: type(of: $0)).contains("PuraPiInspectorHeaderInteractionView")
        }
        XCTAssertFalse(
            inspectorRect.intersects(composerRectInSplit),
            "Inspector pane 不应覆盖 Composer：inspector=\(inspectorRect) composer=\(composerRectInSplit)"
        )
        XCTAssertFalse(headerViews.isEmpty, "Inspector 标题命中层应已安装")
        for headerView in headerViews {
            let headerRect = split.convert(headerView.bounds, from: headerView)
            XCTAssertFalse(
                headerRect.intersects(composerRectInSplit),
                "Inspector 标题命中层不应覆盖 Composer：header=\(headerRect) composer=\(composerRectInSplit)"
            )
        }
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 11,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 12,
            clickCount: 1,
            pressure: 0
        ) else { return XCTFail("无法创建转换路径鼠标事件") }
        // NSTextView.mouseDown 会从应用事件队列读取后续 mouseUp；先入队，避免
        // 测试线程在 AppKit 的鼠标跟踪循环中等待永远不会到达的事件。
        NSApp.postEvent(mouseUp, atStart: true)
        window.sendEvent(mouseDown)
        settle(0.1)

        let editor = composerField.currentEditor()
        XCTAssertNotNil(editor, "动态打开 Inspector 后点击 Composer 应创建文本编辑器")
        XCTAssertTrue(
            window.firstResponder === editor || window.firstResponder === composerField,
            "动态打开 Inspector 后 Composer 应获得焦点，实际=\(String(describing: window.firstResponder))"
        )
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        ) else { return XCTFail("无法创建转换路径键盘事件") }
        window.sendEvent(keyDown)
        settle(0.1)
        XCTAssertTrue(tab.session.draftPrompt.contains("z"))

        // 右侧编辑器仍然保持“语义焦点块”状态；中心 Composer 更新后，不能
        // 因为 Inspector 的 SwiftUI 重绘再次把 firstResponder 抢回去。
        let composerEditor = composerField.currentEditor()
        tab.session.conversation.append(
            ConversationItem(kind: .assistant, text: "触发一次中心重绘")
        )
        appearanceState.setTheme(id: "purapi.midnight")
        settle(0.5)
        XCTAssertTrue(
            window.firstResponder === composerEditor || window.firstResponder === composerField,
            "中心状态更新后焦点仍应留在 Composer，实际=\(String(describing: window.firstResponder))"
        )
    }
}
