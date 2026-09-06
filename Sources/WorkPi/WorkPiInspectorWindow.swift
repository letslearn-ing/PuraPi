import AppKit
import Combine
import SwiftUI

/// 右侧 Inspector 的独立窗口所有者。
///
/// 窗口是展示层，不持有预览、编辑器或 Runtime 的副本。每个项目标签最多有
/// 一个独立 Inspector 窗口，窗口与该标签的 `PiSessionController` 一一对应。
@MainActor
final class WorkPiInspectorWindowCoordinator {
    private weak var mainWindow: NSWindow?
    private let tabs: WorkPiTabManager
    private let layoutState: WorkPiLayoutState
    private let appearanceState: WorkPiAppearanceState

    private var tabSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]
    private var windows: [UUID: WorkPiInspectorWindowController] = [:]
    private var lastFrames: [UUID: NSRect] = [:]
    private var liftTasks: [UUID: Task<Void, Never>] = [:]
    private var liftTokens: [UUID: UUID] = [:]
    /// 分离请求开始时记录的原 Inspector 屏幕矩形；动画期间主栏仍保持可见。
    private var pendingSourceFrames: [UUID: NSRect] = [:]
    private var isShuttingDown = false

    init(
        tabs: WorkPiTabManager,
        layoutState: WorkPiLayoutState,
        appearanceState: WorkPiAppearanceState
    ) {
        self.tabs = tabs
        self.layoutState = layoutState
        self.appearanceState = appearanceState

        tabSubscription = tabs.$tabs
            .sink { [weak self] tabs in
                self?.reconcile(tabs: tabs)
            }
        appearanceSubscription = appearanceState.$mode
            .dropFirst()
            .sink { [weak self] mode in
                self?.applyWindowAppearance(mode)
            }
        reconcile(tabs: tabs.tabs)
    }

    /// 主窗口创建完成后注入，仅用于决定首次分离窗口的初始位置。
    func attachMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    /// 当前标签是否已经拥有独立 Inspector。
    func isDetached(for tab: WorkPiProjectTab) -> Bool {
        windows[tab.id] != nil || tab.session.inspectorDetached
    }

    /// 供测试、窗口外观同步和 AppKit 生命周期使用的只读窗口访问。
    var detachedWindows: [NSWindow] {
        windows.values.compactMap(\.window)
    }

    /// 返回指定项目标签的独立窗口，避免调用方按数组顺序猜测窗口归属。
    func detachedWindow(for tab: WorkPiProjectTab) -> NSWindow? {
        windows[tab.id]?.window
    }

    /// 切换当前标签的 Inspector 展示位置。
    func toggle(tab: WorkPiProjectTab) {
        guard tabs.tabs.contains(where: { $0.id == tab.id }) else { return }
        if windows[tab.id] != nil || tab.session.inspectorDetached {
            reattach(tab: tab)
        } else {
            requestDetach(tab: tab)
        }
    }

    /// 先给 attached Inspector 一个短暂的“抬升”反馈，再创建独立窗口。
    ///
    /// 这不是拖拽手势本身，而是明确告诉用户该面板可以离开三栏；真正的窗口
    /// 拖动仍由 macOS `NSWindow` 提供，避免在 SwiftUI 内容层模拟窗口拖拽。
    func requestDetach(tab: WorkPiProjectTab) {
        guard !isShuttingDown,
              tabs.tabs.contains(where: { $0.id == tab.id }),
              tab.session.selectedFileURL != nil,
              windows[tab.id] == nil,
              !tab.session.inspectorDetached
        else { return }

        cancelLiftHint(for: tab.id)
        pendingSourceFrames[tab.id] = inspectorSourceFrame(for: tab)
        let token = UUID()
        liftTokens[tab.id] = token
        tab.session.showInspectorLiftHint()
        liftTasks[tab.id] = Task { [weak self, weak tab] in
            do {
                try await Task.sleep(for: .milliseconds(360))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  let tab,
                  self.liftTokens[tab.id] == token,
                  !self.isShuttingDown
            else { return }
            self.liftTokens.removeValue(forKey: tab.id)
            self.liftTasks.removeValue(forKey: tab.id)
            let sourceFrame = self.pendingSourceFrames.removeValue(forKey: tab.id)
            tab.session.hideInspectorLiftHint()
            self.detach(tab: tab, sourceWindowFrame: sourceFrame)
        }
    }

    /// 把当前标签的 Inspector 挂到独立窗口。
    ///
    /// 没有选中文件时不创建窗口；这保持了“空 Inspector 不参与布局”的既有语义。
    func detach(tab: WorkPiProjectTab) {
        guard !isShuttingDown,
              tabs.tabs.contains(where: { $0.id == tab.id }),
              tab.session.selectedFileURL != nil
        else { return }
        detach(tab: tab, sourceWindowFrame: inspectorSourceFrame(for: tab))
    }

    private func detach(
        tab: WorkPiProjectTab,
        sourceWindowFrame: NSRect?
    ) {
        guard !isShuttingDown,
              tabs.tabs.contains(where: { $0.id == tab.id }),
              tab.session.selectedFileURL != nil
        else { return }

        cancelLiftHint(for: tab.id)
        if let controller = windows[tab.id] {
            tab.session.detachInspector()
            controller.show(relativeTo: mainWindow)
            return
        }

        let tabID = tab.id
        let controller = WorkPiInspectorWindowController(
            tabID: tabID,
            tabTitle: tab.title,
            session: tab.session,
            layoutState: layoutState,
            appearanceState: appearanceState,
            initialFrame: lastFrames[tabID],
            onWindowClosed: { [weak self] in
                self?.handleWindowClosed(tabID: tabID)
            },
            onRequestReattach: { [weak self] in
                self?.reattach(tabID: tabID)
            },
            sourceWindowFrame: lastFrames[tabID] == nil ? sourceWindowFrame : nil
        )
        // 先登记窗口再发布 detached 状态，避免 Combine 观察者在状态切换的同步
        // 回调中看到“已分离但尚无窗口”的瞬态。
        windows[tabID] = controller
        tab.session.detachInspector()
        controller.show(relativeTo: mainWindow)
    }

    /// 关闭独立窗口并恢复主窗口内的右侧栏。
    ///
    /// 这里只改变展示状态，不调用 `clearFileSelection()`，因此不会关闭文档或绕过
    /// Markdown 保存闸门。
    func reattach(tab: WorkPiProjectTab) {
        reattach(tabID: tab.id)
    }

    func reattach(tabID: UUID) {
        cancelLiftHint(for: tabID)
        pendingSourceFrames.removeValue(forKey: tabID)
        if let controller = windows.removeValue(forKey: tabID) {
            rememberFrame(of: controller, for: tabID)
            controller.closeWithoutReattaching()
        }
        guard let tab = tab(withID: tabID) else { return }
        tab.session.reattachInspector()
        focusMainWindowIfVisible()
    }

    /// 在标签成功关闭后清理其辅助窗口。关闭失败的标签不会经过这里，窗口仍保留。
    func close(tab: WorkPiProjectTab) {
        let tabID = tab.id
        cancelLiftHint(for: tabID)
        pendingSourceFrames.removeValue(forKey: tabID)
        if let controller = windows.removeValue(forKey: tabID) {
            rememberFrame(of: controller, for: tabID)
            controller.closeWithoutReattaching()
        }
        tab.session.reattachInspector()
        sessionSubscriptions.removeValue(forKey: tabID)?.cancel()
    }

    /// 关闭所有独立窗口，但不改变标签和 Runtime 生命周期。
    func closeAll() {
        for tab in tabs.tabs {
            cancelLiftHint(for: tab.id)
            pendingSourceFrames.removeValue(forKey: tab.id)
        }
        for (tabID, controller) in windows {
            rememberFrame(of: controller, for: tabID)
            controller.closeWithoutReattaching()
        }
        windows.removeAll()
        for tab in tabs.tabs where tab.session.inspectorDetached {
            tab.session.reattachInspector()
        }
    }

    /// 应用退出时调用。取消观察者，避免窗口关闭回调在 Runtime 清理期间重新挂栏。
    func shutdown() {
        isShuttingDown = true
        closeAll()
        tabSubscription?.cancel()
        tabSubscription = nil
        appearanceSubscription?.cancel()
        appearanceSubscription = nil
        for subscription in sessionSubscriptions.values {
            subscription.cancel()
        }
        sessionSubscriptions.removeAll()
    }

    /// 外观模式由 AppDelegate 统一传播到主窗口、设置窗口和 Inspector 窗口。
    func applyWindowAppearance(_ mode: WorkPiAppearanceMode) {
        for window in detachedWindows {
            window.appearance = mode.nsAppearance
        }
    }

    /// 读取分离前 Inspector 的完整 pane 屏幕矩形，作为浮动窗口的首个 frame 来源。
    /// 不把它当作新窗口的 contentRect，避免独立窗口标题栏触发 AppKit 的高度压缩。
    private func inspectorSourceFrame(for tab: WorkPiProjectTab) -> NSRect? {
        guard let mainWindow,
              let contentView = mainWindow.contentView
        else { return nil }

        if #available(macOS 26.0, *),
           let controller = findNativeSplitController(
               in: contentView,
               session: tab.session
           ),
           let frame = controller.inspectorScreenFrame() {
            return frame
        }

        return fallbackInspectorSourceFrame(
            in: mainWindow,
            contentView: contentView
        )
    }

    @available(macOS 26.0, *)
    private func findNativeSplitController(
        in view: NSView,
        session: PiSessionController
    ) -> WorkPiWorkspaceSplitViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let controller = current as? WorkPiWorkspaceSplitViewController,
               controller.session === session {
                return controller
            }
            responder = current.nextResponder
        }
        for child in view.subviews {
            if let controller = findNativeSplitController(in: child, session: session) {
                return controller
            }
        }
        return nil
    }

    private func fallbackInspectorSourceFrame(
        in window: NSWindow,
        contentView: NSView
    ) -> NSRect? {
        let contentInWindow = contentView.convert(contentView.bounds, to: nil)
        let screenRect = window.convertToScreen(contentInWindow)
        let width = min(
            layoutState.inspectorWidth + WorkPiLayoutState.inspectorInset * 2,
            screenRect.width
        )
        let height = screenRect.height
        guard width > 0, height > 0 else { return nil }
        return NSRect(
            x: screenRect.maxX - width,
            y: screenRect.minY,
            width: width,
            height: height
        )
    }

    deinit {
        for task in liftTasks.values {
            task.cancel()
        }
    }

    private func reconcile(tabs: [WorkPiProjectTab]) {
        guard !isShuttingDown else { return }
        let liveIDs = Set(tabs.map(\.id))

        for tabID in Array(liftTasks.keys) where !liveIDs.contains(tabID) {
            cancelLiftHint(for: tabID)
        }
        for tabID in Array(liftTokens.keys) where !liveIDs.contains(tabID) {
            cancelLiftHint(for: tabID)
        }

        for tabID in Array(windows.keys) where !liveIDs.contains(tabID) {
            cancelLiftHint(for: tabID)
            pendingSourceFrames.removeValue(forKey: tabID)
            if let controller = windows.removeValue(forKey: tabID) {
                rememberFrame(of: controller, for: tabID)
                controller.closeWithoutReattaching()
            }
            lastFrames.removeValue(forKey: tabID)
        }

        for tabID in Array(sessionSubscriptions.keys) where !liveIDs.contains(tabID) {
            sessionSubscriptions.removeValue(forKey: tabID)?.cancel()
        }

        for tab in tabs where sessionSubscriptions[tab.id] == nil {
            let tabID = tab.id
            // 两个发布值共同决定窗口展示状态。只观察选中文件和 detached 标志，
            // 不把高频 Runtime/编辑器变化引入窗口生命周期协调器。
            sessionSubscriptions[tabID] = Publishers.CombineLatest(
                tab.session.$selectedFileURL,
                tab.session.$inspectorDetached
            )
            .sink { [weak self] selectedURL, detached in
                self?.handleSessionState(
                    tabID: tabID,
                    hasSelection: selectedURL != nil,
                    detached: detached
                )
            }
        }
    }

    private func handleSessionState(
        tabID: UUID,
        hasSelection: Bool,
        detached: Bool
    ) {
        guard !isShuttingDown else { return }

        if !hasSelection {
            // 文件关闭按钮或工作区切换清除了选择；独立窗口不能留下空壳。
            cancelLiftHint(for: tabID)
            pendingSourceFrames.removeValue(forKey: tabID)
            if let controller = windows.removeValue(forKey: tabID) {
                rememberFrame(of: controller, for: tabID)
                controller.closeWithoutReattaching()
            }
            if let tab = tab(withID: tabID), detached {
                tab.session.reattachInspector()
                focusMainWindowIfVisible()
            }
            return
        }

        // 正常的 detached=true 由 detach(tab:) 建立窗口。若窗口已因外部原因消失，
        // 退回 attached，避免主栏和窗口都不可用；不会在状态观察回调中擅自创建第二个窗口。
        if detached, windows[tabID] == nil {
            tab(withID: tabID)?.session.reattachInspector()
            return
        }
        if !detached, let controller = windows.removeValue(forKey: tabID) {
            rememberFrame(of: controller, for: tabID)
            controller.closeWithoutReattaching()
        }
    }

    private func handleWindowClosed(tabID: UUID) {
        guard let controller = windows.removeValue(forKey: tabID) else { return }
        rememberFrame(of: controller, for: tabID)
        guard !isShuttingDown,
              let tab = tab(withID: tabID)
        else { return }
        // 用户点击独立窗口的红色关闭按钮，语义是挂回主栏，而不是关闭文件。
        tab.session.reattachInspector()
        focusMainWindowIfVisible()
    }

    private func focusMainWindowIfVisible() {
        guard let mainWindow, mainWindow.isVisible else { return }
        mainWindow.makeKeyAndOrderFront(nil)
    }

    private func cancelLiftHint(for tabID: UUID) {
        liftTokens.removeValue(forKey: tabID)
        liftTasks.removeValue(forKey: tabID)?.cancel()
        tab(withID: tabID)?.session.hideInspectorLiftHint()
    }

    private func tab(withID id: UUID) -> WorkPiProjectTab? {
        tabs.tabs.first(where: { $0.id == id })
    }

    private func rememberFrame(
        of controller: WorkPiInspectorWindowController,
        for tabID: UUID
    ) {
        guard let frame = controller.window?.frame,
              frame.width > 0,
              frame.height > 0
        else { return }
        lastFrames[tabID] = frame
    }
}

/// 独立 Inspector 的 AppKit 窗口控制器。
@MainActor
final class WorkPiInspectorWindowController: NSWindowController, NSWindowDelegate {
    let tabID: UUID

    private let tabTitle: String
    private let session: PiSessionController
    private let layoutState: WorkPiLayoutState
    private let appearanceState: WorkPiAppearanceState
    private let hostingController: NSHostingController<WorkPiDetachedInspectorView>
    private let sourceWindowFrame: NSRect?
    private var hasAppliedSourceFrame: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var suppressCloseCallback = false
    private let onWindowClosed: () -> Void
    private let onRequestReattach: () -> Void

    init(
        tabID: UUID,
        tabTitle: String,
        session: PiSessionController,
        layoutState: WorkPiLayoutState,
        appearanceState: WorkPiAppearanceState,
        initialFrame: NSRect?,
        onWindowClosed: @escaping () -> Void,
        onRequestReattach: @escaping () -> Void,
        sourceWindowFrame: NSRect? = nil
    ) {
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.session = session
        self.layoutState = layoutState
        self.appearanceState = appearanceState
        self.onWindowClosed = onWindowClosed
        self.onRequestReattach = onRequestReattach
        self.sourceWindowFrame = sourceWindowFrame
        self.hasAppliedSourceFrame = initialFrame != nil
        self.hostingController = NSHostingController(
            rootView: WorkPiDetachedInspectorView(
                session: session,
                layoutState: layoutState,
                appearanceState: appearanceState,
                onReattach: onRequestReattach
            )
        )

        let defaultWidth = max(
            360,
            layoutState.inspectorWidth
                + WorkPiLayoutState.inspectorInset * 2
        )
        let defaultHeight: CGFloat = 720
        // `initialFrame` 保存的是窗口 frame（包含标题栏），而 NSWindow 的
        // `contentRect` 参数只接受内容区尺寸；先用内容尺寸创建，再显式恢复 frame，
        // 避免每次分离/挂回都把标题栏高度重复加到窗口上。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        // 允许 Inspector 在主窗口全屏或跨屏工作区中作为普通辅助窗口存在；
        // 用户仍可把它拖到另一块显示器。
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentMinSize = NSSize(width: 320, height: 260)
        window.appearance = appearanceState.mode.nsAppearance
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        // 必须在设置 contentViewController 后恢复 frame；AppKit 会在安装 hosting
        // view 时按固有尺寸重新计算一次窗口，提前 setFrame 会被覆盖成最小尺寸。
        if let initialFrame,
           initialFrame.width > 0,
           initialFrame.height > 0 {
            window.setFrame(initialFrame, display: false)
        }
        refreshTitle()

        session.$selectedFileURL
            .sink { [weak self] _ in
                self?.refreshTitle()
            }
            .store(in: &subscriptions)
        appearanceState.$language
            .sink { [weak self] _ in
                self?.refreshTitle()
            }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(relativeTo parent: NSWindow?) {
        guard let window else { return }
        refreshTitle()
        if !window.isVisible {
            var usedSourceFrame = false
            if !hasAppliedSourceFrame, let sourceWindowFrame {
                applySourceWindowFrame(sourceWindowFrame, to: window)
                hasAppliedSourceFrame = true
                usedSourceFrame = true
            }
            if ((!usedSourceFrame && window.frame.origin == .zero)
                || !hasVisibleScreenIntersection(window.frame)) {
                positionNearParent(window, parent: parent)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWithoutReattaching() {
        guard let window else { return }
        // 直接移除 delegate 比依赖一个瞬时布尔值更稳：AppKit 某些关闭路径可能
        // 在 close() 返回后才派发 windowWillClose，不能让它误触发一次挂回。
        suppressCloseCallback = true
        window.delegate = nil
        window.close()
    }

    func refreshTitle() {
        guard let window else { return }
        let fileName = session.selectedFileURL?.lastPathComponent ?? "Inspector"
        if appearanceState.language == .english {
            window.title = "Inspector · \(fileName) — \(tabTitle)"
        } else {
            window.title = "检查器 · \(fileName) — \(tabTitle)"
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !suppressCloseCallback else { return }
        onWindowClosed()
    }

    private func hasVisibleScreenIntersection(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return intersection.width >= 32 && intersection.height >= 32
        }
    }

    private func applySourceWindowFrame(_ source: NSRect, to window: NSWindow) {
        // 极窄窗口可能小于独立窗口的可用最小尺寸；只在这里做最小值放大，
        // 仍保留原始左下角位置，不能退回随机的 center/default frame。
        let frame = NSRect(
            x: source.minX,
            y: source.minY,
            width: max(window.minSize.width, source.width),
            height: max(window.minSize.height, source.height)
        )
        // 这里的 source 是原 Inspector 的完整 pane frame，不是 contentRect；
        // 直接 setFrame 会保留原始屏幕位置和外层尺寸，并让 AppKit自行计算标题栏内的内容高度。
        window.setFrame(frame, display: false)
    }

    private func positionNearParent(_ window: NSWindow, parent: NSWindow?) {
        guard let parent else {
            window.center()
            return
        }

        let size = window.frame.size
        var frame = NSRect(
            x: parent.frame.maxX + 16,
            y: parent.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let screen = NSScreen.screens.first {
            $0.visibleFrame.intersects(frame)
        } ?? parent.screen ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            if frame.minX > visibleFrame.maxX - 32 {
                frame.origin.x = max(
                    visibleFrame.minX,
                    parent.frame.minX - frame.width - 16
                )
            }
            frame.origin.y = min(
                max(frame.minY, visibleFrame.minY),
                visibleFrame.maxY - frame.height
            )
        }
        window.setFrame(frame, display: false)
    }
}

/// 独立窗口中的 Inspector 内容。
///
/// 它与主栏使用同一个 `PiSessionController` 和 `WorkPiMarkdownEditorState`，因此
/// 在两个窗口之间切换时，Markdown 光标、撤销栈、冲突状态和预览请求都保持一致。
@MainActor
struct WorkPiDetachedInspectorView: View {
    @ObservedObject var session: PiSessionController
    @ObservedObject var layoutState: WorkPiLayoutState
    @ObservedObject var appearanceState: WorkPiAppearanceState
    let onReattach: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WorkPiInspectorHostView(
                session: session,
                layoutState: layoutState,
                language: appearanceState.language,
                theme: appearanceState.theme,
                inspectorTint: appearanceState.inspectorTint,
                isDetached: true,
                onToggleDetached: onReattach
            )

            // 独立窗口也使用同一套 AppKit 命中代理。正文 ScrollView 可能覆盖
            // SwiftUI 标题区域，透明代理保证“挂回/更多/关闭”在两个系统版本都可点。
            WorkPiInspectorHeaderInteractionStack(
                previewURL: session.selectedPreview?.url ?? session.selectedFileURL,
                showsFileActions: session.selectedPreview != nil || session.selectedFileURL != nil,
                isDetached: true,
                language: appearanceState.language,
                onToggleMaximize: {
                    // 独立窗口由 AppKit 自己负责缩放；这里保留标题按钮的视觉兼容，
                    // 不把独立窗口误映射成主栏的 inspectorMaximized 状态。
                },
                onToggleDetached: onReattach,
                onClose: session.clearFileSelection,
                onReveal: session.revealInFinder,
                onOpen: session.openWithDefaultApplication,
                onCopyPath: { session.copyPath($0, relative: false) },
                onCopyRelativePath: { session.copyPath($0, relative: true) }
            )
            .padding(.top, WorkPiLayoutState.inspectorInset)
            .padding(
                .trailing,
                WorkPiLayoutState.inspectorInset + WorkPiInspectorHeaderMetrics.trailingPadding
            )
        }
        .frame(minWidth: 320, minHeight: 260)
        .workPiTheme(appearanceState.theme)
        .background(WorkPiWindowBackdrop())
    }
}
