import AppKit
import Combine
import PiDomain
import SwiftUI

/// 主窗口顶部空白区域的双击命中规则。
///
/// `contentLayoutRect` 是未被 Toolbar 遮挡的内容区域；其上方即系统标题栏。
/// 交通灯和自定义 Toolbar item 作为排除区域传入，避免双击控件时缩放窗口。
enum PuraPiWindowZoomPolicy {
    static func titlebarRect(
        windowBounds: NSRect,
        contentLayoutRect: NSRect
    ) -> NSRect {
        let minimumY = min(
            max(contentLayoutRect.maxY, windowBounds.minY),
            windowBounds.maxY
        )
        return NSRect(
            x: windowBounds.minX,
            y: minimumY,
            width: windowBounds.width,
            height: max(0, windowBounds.maxY - minimumY)
        )
    }

    static func shouldToggleZoom(
        clickCount: Int,
        location: NSPoint,
        windowBounds: NSRect,
        contentLayoutRect: NSRect,
        excludedRects: [NSRect],
        isFullScreen: Bool
    ) -> Bool {
        guard clickCount == 2,
              !isFullScreen,
              titlebarRect(
                  windowBounds: windowBounds,
                  contentLayoutRect: contentLayoutRect
              ).contains(location)
        else { return false }

        return !excludedRects.contains(where: { $0.contains(location) })
    }
}

/// 将旧版 AppKit 窗口 frame 偏好迁移到新 autosave 名称。
///
/// NSToolbar 当前关闭用户自定义，只有窗口 frame 需要显式保留；旧键只读，
/// 不删除旧值，避免用户回滚到旧版本时窗口位置丢失。
enum PuraPiWindowFrameMigration {
    static let currentAutosaveName = "PuraPi.mainWindow"
    static let legacyAutosaveName = PuraPiLegacyIdentifiers.windowAutosaveName

    static func migrateLegacyFrame(in defaults: UserDefaults = .standard) {
        let currentKey = "NSWindow Frame \(currentAutosaveName)"
        let legacyKey = "NSWindow Frame \(legacyAutosaveName)"
        guard defaults.object(forKey: currentKey) == nil,
              let legacyFrame = defaults.string(forKey: legacyKey),
              !legacyFrame.isEmpty
        else { return }
        defaults.set(legacyFrame, forKey: currentKey)
    }
}

/// PuraPi 主窗口。双击透明标题栏的空白拖拽区时使用 AppKit 原生 Zoom，
/// 填满当前屏幕可用区域；再次双击由系统还原原窗口 frame。
@MainActor
final class PuraPiWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown,
              PuraPiWindowZoomPolicy.shouldToggleZoom(
                  clickCount: event.clickCount,
                  location: event.locationInWindow,
                  windowBounds: NSRect(origin: .zero, size: frame.size),
                  contentLayoutRect: contentLayoutRect,
                  excludedRects: titlebarInteractiveRects,
                  isFullScreen: styleMask.contains(.fullScreen)
              )
        else {
            super.sendEvent(event)
            return
        }

        // 使用原生 Zoom 而不是 toggleFullScreen：保留当前 Space、菜单栏和 Dock，
        // 同时让 AppKit 负责多屏 visibleFrame 与原尺寸还原。
        performZoom(nil)
    }

    private var titlebarInteractiveRects: [NSRect] {
        let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton,
            .miniaturizeButton,
            .zoomButton,
        ]
        var rects: [NSRect] = buttonTypes.compactMap { buttonType in
            guard let button = standardWindowButton(buttonType),
                  button.window === self
            else { return nil }
            return button.convert(button.bounds, to: nil).insetBy(dx: -4, dy: -4)
        }

        if let toolbar {
            rects.append(contentsOf: toolbar.items.compactMap { item in
                guard let view = item.view, view.window === self else { return nil }
                // 包含系统为自定义 item 保留的少量外边距，避免胶囊边缘误触。
                return view.convert(view.bounds, to: nil).insetBy(dx: -8, dy: -8)
            })
        }
        return rects
    }
}

/// 显式的 macOS 应用委托，保证 SwiftPM executable target 直接运行时创建窗口。
@MainActor
final class PuraPiApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var toolbar: NSToolbar?
    private var toolbarDelegate: PuraPiToolbarDelegate?
    private var localEventMonitor: Any?
    private var appearanceWindow: NSWindow?
    private var appearanceCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var openAccountSettingsObserver: NSObjectProtocol?
    private let runtimeProvisioner: PuraPiRuntimeProvisioner
    private let authCoordinator: PuraPiAuthCoordinator
    private let tabs: PuraPiTabManager
    private let layoutState = PuraPiLayoutState()
    private let appearanceState = PuraPiAppearanceState()
    private let inspectorCoordinator: PuraPiInspectorWindowCoordinator
    private var terminationInProgress = false

    override init() {
        let selection = PuraPiRuntimeSelection()
        runtimeProvisioner = PuraPiRuntimeProvisioner(selection: selection)
        authCoordinator = PuraPiAuthCoordinator(selection: selection)
        tabs = PuraPiTabManager(makeTransport: { mode in
            let snapshot = selection.snapshot()
            let executableURL = snapshot.executableURL
                ?? (snapshot.automaticResolutionAllowed
                    ? nil
                    : PuraPiRuntimeSelection.unavailableExecutableURL)
            return makeDefaultPiTransport(
                for: mode,
                executableURL: executableURL,
                environmentOverrides: snapshot.environmentOverrides
            )
        })
        inspectorCoordinator = PuraPiInspectorWindowCoordinator(
            tabs: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PuraPiBranding.installApplicationIcon()
        configureMainMenu()
        installKeyboardShortcutMonitor()
        openAccountSettingsObserver = NotificationCenter.default.addObserver(
            forName: .puraPiOpenAccountSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 设置窗口已存在时，AppearanceSettingsView 会消费同一通知切换页；
                // 只有窗口未打开时才由 AppDelegate 创建它，避免通知递归。
                guard self.appearanceWindow == nil || self.appearanceWindow?.isVisible != true else { return }
                self.presentSettings(tab: .accounts)
            }
        }

        appearanceCancellable = appearanceState.$mode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.scheduleWindowAppearance(mode)
            }
        languageCancellable = appearanceState.$language
            .dropFirst()
            .removeDuplicates()
            .sink { _ in }

        let hostingView = NSHostingView(
            rootView: ContentView(
                tabs: tabs,
                layoutState: layoutState,
                appearanceState: appearanceState,
                runtimeProvisioner: runtimeProvisioner,
                authCoordinator: authCoordinator,
                inspectorCoordinator: inspectorCoordinator
            )
        )
        hostingView.autoresizingMask = [.width, .height]

        let window = PuraPiWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_420, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = PuraPiBranding.name
        window.titleVisibility = .hidden
        // 让 macOS 自己管理窗口/标题栏的系统外壳；不要用透明窗口
        // 再手工绘制一整块灰色背景来伪造 Liquid Glass。
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // unified 将标准交通灯放在标题栏左上圆角的视觉焦点处，
        // 同时让工具栏胶囊与标题栏使用同一条中心线。
        window.toolbarStyle = .unified
        window.backgroundColor = .windowBackgroundColor
        window.appearance = appearanceState.mode.nsAppearance
        window.isOpaque = true
        // 内容背景仍可用于移动窗口；Sidebar 原生调整手柄通过
        // mouseDownCanMoveWindow = false 单独排除窗口移动。
        window.isMovableByWindowBackground = true
        PuraPiWindowFrameMigration.migrateLegacyFrame()
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(PuraPiWindowFrameMigration.currentAutosaveName)

        let toolbarDelegate = PuraPiToolbarDelegate(
            manager: tabs,
            layoutState: layoutState,
            appearanceState: appearanceState
        )
        let toolbar = NSToolbar(identifier: "PuraPi.projectTabs")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        window.toolbar = toolbar
        toolbarDelegate.attach(to: toolbar)
        self.toolbarDelegate = toolbarDelegate
        self.toolbar = toolbar

        window.center()

        self.window = window
        inspectorCoordinator.attachMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 不能在 NSApplicationDelegate 的同步回调里等待磁盘或 Pi 进程；先返回
        // terminateLater，异步完成保存闸门和 Runtime stop 后再回复 AppKit。
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { @MainActor [weak self, sender] in
            guard let self else { return }
            let closed = await self.tabs.closeAllAsync()
            guard closed else {
                self.terminationInProgress = false
                self.window?.makeKeyAndOrderFront(nil)
                sender.activate(ignoringOtherApps: true)
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.inspectorCoordinator.closeAll()
            self.terminationInProgress = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let openAccountSettingsObserver {
            NotificationCenter.default.removeObserver(openAccountSettingsObserver)
            self.openAccountSettingsObserver = nil
        }
        // Runtime 清理属于 AppKit 应用生命周期，不应放在 SwiftUI 根视图的
        // onDisappear 中；后者发生在 View 更新/拆卸期间，同步发布多个 Session
        // 状态会触发“Publishing changes from within view updates”警告。
        inspectorCoordinator.shutdown()
        tabs.closeAll()
        authCoordinator.cancelOperation()
        // applicationWillTerminate 不能等待 async Task；同步终止认证 sidecar，
        // 防止 OAuth 回调服务器或 Node 子进程在 PuraPi 退出后继续运行。
        PuraPiAuthBridgeProcess.terminateAllImmediately()
        runtimeProvisioner.shutdown()
    }

    private func installKeyboardShortcutMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, PuraPiKeyboardShortcut.isToggleSidebar(event) else { return event }
            self.toggleSidebarFromMenu(nil)
            return nil
        }
    }

    @objc private func newWorkspaceFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiNewWorkspace, object: nil)
    }

    @objc private func openWorkspaceFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiOpenWorkspace, object: nil)
    }

    @objc private func closeSelectedTabFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiCloseSelectedTab, object: nil)
    }

    @objc private func closeAllProjectsFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiCloseAllProjects, object: nil)
    }

    @objc private func saveDocumentFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiSaveDocument, object: nil)
    }

    @objc private func findInConversationFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiFindInConversation, object: nil)
    }

    @objc private func toggleSidebarFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiToggleSidebar, object: nil)
    }

    @objc private func toggleInspectorDetachedFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .puraPiToggleInspectorDetached, object: nil)
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: PuraPiBranding.name,
            .applicationVersion: "Developer Preview",
            .version: "A native macOS client for Pi",
        ])
    }

    @objc private func showAppearanceSettings(_ sender: Any?) {
        presentSettings(tab: .appearance)
    }

    @objc private func showAccountSettings(_ sender: Any?) {
        presentSettings(tab: .accounts)
    }

    private func presentSettings(tab: PuraPiSettingsTab) {
        if let appearanceWindow, appearanceWindow.isVisible {
            if tab == .accounts {
                NotificationCenter.default.post(name: .puraPiOpenAccountSettings, object: nil)
            }
            appearanceWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = PuraPiAppearanceSettingsView(
            appearanceState: appearanceState,
            runtimeProvisioner: runtimeProvisioner,
            authCoordinator: authCoordinator,
            initialTab: tab
        )
        let hostingView = NSHostingView(rootView: settingsView)
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = appearanceState.language == .english ? "PuraPi Settings" : "PuraPi 设置"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.contentView = hostingView
        settingsWindow.appearance = appearanceState.mode.nsAppearance
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        appearanceWindow = settingsWindow
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 设置窗口关闭后，主动让主窗口重绘一次。
    ///
    /// macOS 在窗口重叠期间可能暂缓主窗口被遮挡区域的合成；如果外部只截取
    /// 主窗口 backing store，刚关闭设置窗口时会短暂看到一块旧的空白帧。这里不
    /// 重建任何 SwiftUI 状态，只要求 AppKit 重新显示，避免把正常对话生命周期
    /// 误当成颜色切换的一部分。
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === appearanceWindow
        else { return }

        // 关闭设置窗口时不能让 OAuth 回调服务器或 API Key 输入等待器
        // 在后台继续存活；重新打开设置即可重新发起操作。
        authCoordinator.cancelOperation()

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    private func scheduleWindowAppearance(_ mode: PuraPiAppearanceMode) {
        // Picker 的状态写入先完成，再统一更新两个 PuraPi 窗口。连续选择时只应用
        // 最后一个值，避免同一输入事件内同步重建窗口材质树。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.appearanceState.mode == mode else { return }
            self.applyWindowAppearance(mode)
        }
    }

    private func applyWindowAppearance(_ mode: PuraPiAppearanceMode) {
        let appearance = mode.nsAppearance
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window?.appearance = appearance
            appearanceWindow?.appearance = appearance
            inspectorCoordinator.applyWindowAppearance(mode)
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "关于 PuraPi",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let appearanceItem = applicationMenu.addItem(
            withTitle: "设置…",
            action: #selector(showAppearanceSettings(_:)),
            keyEquivalent: ","
        )
        appearanceItem.keyEquivalentModifierMask = [.command]
        appearanceItem.target = self
        let accountItem = applicationMenu.addItem(
            withTitle: "账号与认证…",
            action: #selector(showAccountSettings(_:)),
            keyEquivalent: ""
        )
        accountItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "退出 PuraPi",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let newItem = fileMenu.addItem(
            withTitle: "新建项目文件夹…",
            action: #selector(newWorkspaceFromMenu(_:)),
            keyEquivalent: "n"
        )
        newItem.target = self

        let openItem = fileMenu.addItem(
            withTitle: "打开项目文件夹…",
            action: #selector(openWorkspaceFromMenu(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(.separator())

        let closeItem = fileMenu.addItem(
            withTitle: "关闭当前标签页",
            action: #selector(closeSelectedTabFromMenu(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = self

        let closeAllItem = fileMenu.addItem(
            withTitle: "关闭全部项目",
            action: #selector(closeAllProjectsFromMenu(_:)),
            keyEquivalent: "w"
        )
        closeAllItem.keyEquivalentModifierMask = [.command, .shift]
        closeAllItem.target = self
        fileMenu.addItem(.separator())

        let toggleSidebarItem = fileMenu.addItem(
            withTitle: "显示/隐藏侧边栏",
            action: #selector(toggleSidebarFromMenu(_:)),
            keyEquivalent: "\\"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command]
        toggleSidebarItem.target = self

        let inspectorWindowItem = fileMenu.addItem(
            withTitle: "独立/挂回检查器",
            action: #selector(toggleInspectorDetachedFromMenu(_:)),
            keyEquivalent: ""
        )
        inspectorWindowItem.target = self

        let saveItem = fileMenu.addItem(
            withTitle: "保存",
            action: #selector(saveDocumentFromMenu(_:)),
            keyEquivalent: "s"
        )
        saveItem.keyEquivalentModifierMask = [.command]
        saveItem.target = self

        let findItem = fileMenu.addItem(
            withTitle: "在对话中查找…",
            action: #selector(findInConversationFromMenu(_:)),
            keyEquivalent: "f"
        )
        findItem.keyEquivalentModifierMask = [.command]
        findItem.target = self

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        NSApp.mainMenu = mainMenu
    }
}

/// 将项目标签放入真正的 AppKit `NSToolbar`（系统工具栏）项目。
///
/// 原生全高 Sidebar 会让 AppKit 自动移动 Toolbar 的前导内容边界；这里只
/// 放一个系统 `.space` 作为固定间距。不能再按 Sidebar 宽度累加占位，否则
/// Sidebar 宽度会被计算两次，把标签推到窗口中间。
@MainActor
final class PuraPiToolbarDelegate: NSObject, NSToolbarDelegate {
    let manager: PuraPiTabManager
    let layoutState: PuraPiLayoutState
    let appearanceState: PuraPiAppearanceState
    let tabsItemIdentifier = NSToolbarItem.Identifier("PuraPi.projectTabs.item")
    /// Sidebar 文件树 / 会话树切换图标。
    ///
    /// 必须做成工具栏项：统一工具栏的 `NSToolbarView` 在视图层级上位于
    /// contentView 之上，直接把 SwiftUI 按钮顶进标题栏区域时点击会被它拦住。
    let sidebarModeItemIdentifier = NSToolbarItem.Identifier("PuraPi.sidebarMode.item")
    /// Sidebar 折叠开关。展开时贴 Sidebar 右上角，折叠后自动落到交通灯右侧。
    let sidebarToggleItemIdentifier = NSToolbarItem.Identifier("PuraPi.sidebarToggle.item")

    private weak var toolbar: NSToolbar?
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false
    private var appliedTabCount: Int?

    init(
        manager: PuraPiTabManager,
        layoutState: PuraPiLayoutState,
        appearanceState: PuraPiAppearanceState
    ) {
        self.manager = manager
        self.layoutState = layoutState
        self.appearanceState = appearanceState
        super.init()

        manager.objectWillChange
            .sink { [weak self] _ in self?.scheduleToolbarRefresh() }
            .store(in: &cancellables)
        layoutState.objectWillChange
            .sink { [weak self] _ in self?.scheduleToolbarRefresh() }
            .store(in: &cancellables)
        // 折叠开关的 tooltip 在构造时定型，语言切换必须重建该项。
        appearanceState.$language
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildSidebarToggleItem() }
            .store(in: &cancellables)
    }

    /// 重建折叠开关项，让新语言的 tooltip 生效。
    private func rebuildSidebarToggleItem() {
        guard let toolbar,
              let index = toolbar.items.firstIndex(where: {
                  $0.itemIdentifier == sidebarToggleItemIdentifier
              })
        else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: sidebarToggleItemIdentifier, at: index)
    }

    func attach(to toolbar: NSToolbar) {
        self.toolbar = toolbar
        applyToolbarLayout(rebuildTabsItem: false)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            sidebarModeItemIdentifier,
            sidebarToggleItemIdentifier,
            .sidebarTrackingSeparator,
            .space,
            tabsItemIdentifier,
            .flexibleSpace,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        desiredItemIdentifiers()
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == sidebarModeItemIdentifier {
            return makeSidebarModeItem()
        }
        if itemIdentifier == sidebarToggleItemIdentifier {
            return makeSidebarToggleItem()
        }
        guard itemIdentifier == tabsItemIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let width = PuraPiTitlebarTabs.toolbarWidth(for: manager)
        let hostingView = NSHostingView(
            rootView: PuraPiTitlebarTabs(
                manager: manager,
                appearanceState: appearanceState
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: PuraPiTitlebarTabs.tabBarHeight)
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        item.view = hostingView
        // macOS 26 的自定义 Toolbar Item 自带系统胶囊；ProjectTabBar
        // 不再重复绘制玻璃，旧系统材质由兼容修饰器提供。
        if #available(macOS 26.0, *) {
            item.style = .plain
        }
        item.label = "项目标签"
        item.paletteLabel = "项目标签"
        return item
    }

    private func makeSidebarModeItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: sidebarModeItemIdentifier)
        let hostingView = NSHostingView(
            rootView: PuraPiSidebarModeSwitcher(
                layoutState: layoutState,
                appearanceState: appearanceState
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: PuraPiSidebarModeSwitcher.width,
            height: PuraPiSidebarModeSwitcher.height
        )
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        item.view = hostingView
        if #available(macOS 26.0, *) {
            item.style = .plain
        }
        item.label = "侧边栏模式"
        item.paletteLabel = "侧边栏模式"
        return item
    }

    private func makeSidebarToggleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: sidebarToggleItemIdentifier)
        let hostingView = NSHostingView(
            rootView: PuraPiSidebarToggle(
                layoutState: layoutState,
                appearanceState: appearanceState,
                language: appearanceState.language
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: PuraPiSidebarToggle.width,
            height: PuraPiSidebarToggle.height
        )
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        item.view = hostingView
        if #available(macOS 26.0, *) {
            item.style = .plain
        }
        item.label = "侧边栏开关"
        item.paletteLabel = "侧边栏开关"
        return item
    }

    /// 内部可见以便测试布局顺序。
    func desiredItemIdentifiers() -> [NSToolbarItem.Identifier] {
        // 空工作区没有项目语境；隐藏整个标签项，避免标题栏残留无意义的“+”。
        guard !manager.tabs.isEmpty else { return [] }

        // 模式切换图标必须排在 `.sidebarTrackingSeparator` 之前，才会落在
        // Sidebar 上方与交通灯同行（Xcode 导航器按钮的位置）。
        // 分隔符交由 AppKit 跟随 Sidebar divider，拖动宽度时自动对齐。
        // Sidebar 折叠时没有可切换的树，只留折叠开关；它排在分隔符之前，
        // 因此会自动贴到交通灯右侧（与 Xcode 折叠导航器后的位置一致）。
        guard layoutState.sidebarVisible else {
            return [
                sidebarToggleItemIdentifier,
                .sidebarTrackingSeparator,
                .space,
                tabsItemIdentifier,
            ]
        }
        // 弹性间距把开关推到 Sidebar 右上角；分隔符跟随 Sidebar 边界，
        // 所以 Sidebar 宽度变化时开关会随之平移，不需要手写动画。
        return [
            sidebarModeItemIdentifier,
            .flexibleSpace,
            sidebarToggleItemIdentifier,
            .sidebarTrackingSeparator,
            .space,
            tabsItemIdentifier,
        ]
    }

    private func scheduleToolbarRefresh() {
        guard toolbar != nil, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let tabCountChanged = self.appliedTabCount != nil
                && self.appliedTabCount != self.manager.tabs.count
            self.applyToolbarLayout(rebuildTabsItem: tabCountChanged)
        }
    }

    private func applyToolbarLayout(rebuildTabsItem: Bool) {
        guard let toolbar else { return }
        let desired = desiredItemIdentifiers()
        let current = toolbar.items.map(\.itemIdentifier)

        if current != desired {
            if #available(macOS 15.0, *) {
                toolbar.itemIdentifiers = desired
            } else {
                while !toolbar.items.isEmpty {
                    toolbar.removeItem(at: toolbar.items.count - 1)
                }
                for (index, identifier) in desired.enumerated() {
                    toolbar.insertItem(withItemIdentifier: identifier, at: index)
                }
            }
        }

        if rebuildTabsItem,
           let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == tabsItemIdentifier }) {
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: tabsItemIdentifier, at: index)
        }

        appliedTabCount = manager.tabs.count
    }
}

@main
struct PuraPiMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = PuraPiApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
