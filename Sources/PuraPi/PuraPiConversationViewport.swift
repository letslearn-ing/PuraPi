import AppKit
import PiDomain
import SwiftUI

/// 中央对话区的 AppKit 视口（viewport，真实可滚动的可见区域）。
///
/// AppKit 负责 document view 的尺寸、滚动偏移、底部跟随和用户阅读位置；
/// 每个 `ConversationItem` 仍由独立的 SwiftUI 行视图绘制。消息行的高度变化
/// 会回到同一个 document view 重新布局，不依赖 `ScrollViewReader` 猜测位置。
struct PuraPiConversationViewport: NSViewRepresentable {
    let items: [ConversationItem]
    let language: PuraPiInterfaceLanguage
    let theme: PuraPiTheme
    /// 需要滚动到的消息。会话树双击某一轮时由控制器设置。
    let scrollTarget: UUID?
    /// 定位完成后回调，让控制器清空目标，避免重复滚动。
    let onScrollTargetConsumed: () -> Void

    init(
        items: [ConversationItem],
        language: PuraPiInterfaceLanguage,
        theme: PuraPiTheme = .default,
        scrollTarget: UUID? = nil,
        onScrollTargetConsumed: @escaping () -> Void = {}
    ) {
        self.items = items
        self.language = language
        self.theme = theme
        self.scrollTarget = scrollTarget
        self.onScrollTargetConsumed = onScrollTargetConsumed
    }

    func makeNSView(context: Context) -> PuraPiConversationViewportView {
        PuraPiConversationViewportView()
    }

    func updateNSView(
        _ nsView: PuraPiConversationViewportView,
        context: Context
    ) {
        nsView.update(items: items, language: language, theme: theme)
        if let scrollTarget {
            nsView.scroll(to: scrollTarget, onCompletion: onScrollTargetConsumed)
        }
    }

    static func dismantleNSView(
        _ nsView: PuraPiConversationViewportView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
final class PuraPiConversationViewportView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = PuraPiConversationDocumentView()
    private let scrollConfiguration: PuraPiScrollViewConfigurationView
    /// macOS 26.1+ 用一个单项 split item 让滚动视图成为 accessory 的直接内容，
    /// 从而由 AppKit 创建真实的系统滚动边缘效果；旧系统保留原生 fallback。
    private var nativeScrollContainer: AnyObject?
    private var nativeScrollContainerView: NSView?
    private var rowHosts: [UUID: PuraPiConversationRowHost] = [:]
    /// 行内文案（如「思考过程」）随语言变化，必须参与行的相等判定。
    private var language: PuraPiInterfaceLanguage = .chinese
    private var theme: PuraPiTheme = .default
    private var previousItems: [UUID: ConversationItem] = [:]
    private var orderedIDs: [UUID] = []
    private var hasRenderedInitialSnapshot = false
    private var isProgrammaticScroll = false
    private var followsBottom = true
    private var isUserScrolling = false
    private var userScrollResetToken = UUID()
    private var relayoutScheduled = false
    private var pendingFollowBottom = false
    private var lastKnownViewportSize: CGSize = .zero
    private var liveScrollStartObserver: NSObjectProtocol?
    private var liveScrollObserver: NSObjectProtocol?
    private var liveScrollEndObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?
    private var nativeAccessoryInstallScheduled = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.1, *) {
            scrollConfiguration = PuraPiScrollViewConfigurationView(
                managesTitlebarContentInsets: true,
                edgeToEdgeContent: true,
                installsScrollEdgeEffect: false,
                usesAppKitScrollEdgeEffect: false
            )
        } else {
            scrollConfiguration = PuraPiScrollViewConfigurationView(
                managesTitlebarContentInsets: true,
                edgeToEdgeContent: true,
                installsScrollEdgeEffect: true,
                usesAppKitScrollEdgeEffect: true
            )
        }
        super.init(frame: frameRect)
        wantsLayer = false
        // macOS 26.1+ 的顶部效果由公开的 split accessory 负责；旧系统才使用
        // PuraPiScrollEdgeEffectView fallback。外层 viewport 仍负责裁剪到底部边界，
        // 避免最后一条消息绘制到 Composer（输入区）上方或下方的兄弟视图中。
        clipsToBounds = true
        configureScrollView()
        installScrollContainer()
        installObservers()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestNativeScrollEdgeAccessoryInstall()
    }

    override func layout() {
        super.layout()
        if let nativeScrollContainerView {
            nativeScrollContainerView.frame = bounds
            nativeScrollContainerView.layoutSubtreeIfNeeded()
            requestNativeScrollEdgeAccessoryInstall()
        } else {
            scrollView.frame = bounds
        }
        scrollConfiguration.attachWhenPossible()
        scrollView.layoutSubtreeIfNeeded()
        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let sizeChanged = abs(lastKnownViewportSize.width - viewportSize.width) > 0.5
            || abs(lastKnownViewportSize.height - viewportSize.height) > 0.5
        lastKnownViewportSize = viewportSize
        documentView.setDocumentWidth(viewportSize.width)
        documentView.layoutSubtreeIfNeeded()
        if sizeChanged, !orderedIDs.isEmpty {
            scheduleRelayout(
                shouldFollowBottom: !hasRenderedInitialSnapshot
                    || (followsBottom && !isUserScrolling)
            )
        }
    }

    func update(
        items: [ConversationItem],
        language: PuraPiInterfaceLanguage,
        theme: PuraPiTheme = .default
    ) {
        self.language = language
        self.theme = theme
        // `followsBottom` 只由初始状态和真实用户滚动决定；不能在消息高度
        // 改变后再次调用 `isAtBottom()`，否则用户向上阅读时可能被误判为贴底。
        let shouldFollowBottom = !hasRenderedInitialSnapshot || followsBottom
        updateRows(items)
        documentView.update(orderedItems: items, hosts: rowHosts)
        hasRenderedInitialSnapshot = true
        // 数据快照可能早于真实窗口宽度到达；scheduleRelayout 会在下一轮
        // 主线程布局中重试，届时 document view 已经拥有确定的宽度。
        scheduleRelayout(shouldFollowBottom: shouldFollowBottom)
    }

    /// 把某条消息滚动到可视区顶部。
    ///
    /// 行布局是异步的（宽度与 Markdown 高度都可能晚到），因此定位要等到下一轮
    /// 布局完成后再执行，否则会滚到旧的偏移。
    func scroll(to itemID: UUID, onCompletion: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.documentView.layoutSubtreeIfNeeded()
            guard let host = self.rowHosts[itemID] else {
                onCompletion()
                return
            }
            // 用户主动定位后不再自动贴底，否则下一次高度变化会把视图拉走。
            self.followsBottom = false
            let visibleHeight = self.scrollView.contentView.bounds.height
            let maximumY = max(0, self.documentView.bounds.height - visibleHeight)
            let targetY = min(max(0, host.frame.minY - 12), maximumY)
            self.isProgrammaticScroll = true
            self.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticScroll = false
                onCompletion()
            }
        }
    }

    func detach() {
        removeObservers()
        scrollConfiguration.detach()
        for host in rowHosts.values {
            host.onIntrinsicSizeInvalidated = nil
            host.removeFromSuperview()
        }
        rowHosts.removeAll()
        previousItems.removeAll()
        orderedIDs.removeAll()
        documentView.detach()
        nativeScrollContainerView?.removeFromSuperview()
        nativeScrollContainerView = nil
        nativeScrollContainer = nil
    }

    private func requestNativeScrollEdgeAccessoryInstall() {
        guard bounds.width > 1,
              bounds.height > 1,
              window != nil,
              #available(macOS 26.1, *),
              let nativeScrollContainer = nativeScrollContainer as? PuraPiNativeScrollEdgeContainerController
        else { return }

        if nativeScrollContainer.installScrollEdgeAccessory() {
            nativeAccessoryInstallScheduled = false
        } else if !nativeAccessoryInstallScheduled {
            // 只允许一次“让出当前布局周期”的重试。不要在回调中再次调用本方法：
            // 如果 AppKit 仍未完成布局，递归 async 会变成无界主线程忙循环。
            nativeAccessoryInstallScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.nativeAccessoryInstallScheduled = false
                guard self.window != nil,
                      let container = self.nativeScrollContainer as? PuraPiNativeScrollEdgeContainerController
                else { return }
                _ = container.installScrollEdgeAccessory()
            }
        }
    }

    private func installScrollContainer() {
        if #available(macOS 26.1, *) {
            let controller = PuraPiNativeScrollEdgeContainerController(scrollView: scrollView)
            nativeScrollContainer = controller
            nativeScrollContainerView = controller.view
            controller.view.frame = bounds
            controller.view.autoresizingMask = [.width, .height]
            addSubview(controller.view)
        } else {
            scrollView.frame = bounds
            scrollView.autoresizingMask = [.width, .height]
            addSubview(scrollView)
        }
    }

    private func configureScrollView() {
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        // 复用项目已有的 AppKit scroll chrome 配置器，确保新的 viewport
        // 仍保留 edge-to-edge 几何、真实 overlay scroller 和旧系统材质 fallback。
        scrollConfiguration.frame = .zero
        documentView.addSubview(scrollConfiguration)
        scrollConfiguration.attachWhenPossible()
    }

    private func installObservers() {
        liveScrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isProgrammaticScroll = false
                self.isUserScrolling = true
                // 一旦用户开始接管滚动，新的消息或高度变化不能把视口
                // 强行拉回底部；到达滚动结束通知后再重新判断是否贴底。
                self.followsBottom = false
                self.pendingFollowBottom = false
            }
        }

        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isUserScrolling = true
                self.followsBottom = false
                self.pendingFollowBottom = false
                let token = UUID()
                self.userScrollResetToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.userScrollResetToken == token else { return }
                        self.isUserScrolling = false
                        self.followsBottom = self.isAtBottom()
                    }
                }
            }
        }

        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isUserScrolling = false
                self.followsBottom = self.isAtBottom()
                self.scheduleRelayout(shouldFollowBottom: false)
            }
        }

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isProgrammaticScroll else { return }
                let viewportSize = self.scrollView.contentView.bounds.size
                guard viewportSize.width > 1, viewportSize.height > 1 else { return }

                // boundsDidChange 同时会在用户垂直滚动时触发。垂直滚动不
                // 是重新测量消息的理由；若在这里 scheduleRelayout 并沿用
                // 旧的 followsBottom，AppKit 可能在用户刚滚动后把 clip view
                // 再次设置到底部，表现为滚动条不出现、内容无法移动。
                // 但可视区域尺寸变化（窗口、Composer 或状态条改变高度）
                // 必须重新布局，否则 NSScrollView 可能把 document frame
                // 暂时压回可视高度，之后就失去有效滚动范围。
                let sizeChanged = abs(self.lastKnownViewportSize.width - viewportSize.width) > 0.5
                    || abs(self.lastKnownViewportSize.height - viewportSize.height) > 0.5
                guard sizeChanged else { return }
                self.lastKnownViewportSize = viewportSize
                self.documentView.setDocumentWidth(viewportSize.width)
                self.documentView.needsLayout = true
                self.scheduleRelayout(
                    shouldFollowBottom: self.followsBottom && !self.isUserScrolling
                )
            }
        }
    }

    private func removeObservers() {
        if let liveScrollStartObserver {
            NotificationCenter.default.removeObserver(liveScrollStartObserver)
            self.liveScrollStartObserver = nil
        }
        if let liveScrollObserver {
            NotificationCenter.default.removeObserver(liveScrollObserver)
            self.liveScrollObserver = nil
        }
        if let liveScrollEndObserver {
            NotificationCenter.default.removeObserver(liveScrollEndObserver)
            self.liveScrollEndObserver = nil
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    private func updateRows(_ items: [ConversationItem]) {
        let newIDs = items.map(\.id)
        let newIDSet = Set(newIDs)

        for id in orderedIDs where !newIDSet.contains(id) {
            rowHosts[id]?.onIntrinsicSizeInvalidated = nil
            rowHosts[id]?.removeFromSuperview()
            rowHosts.removeValue(forKey: id)
            previousItems.removeValue(forKey: id)
        }

        for item in items {
            if let host = rowHosts[item.id] {
                // 语言变化时 item 本身没变，但行内文案要重绘；
                // 只比较 item 会漏掉这种情况。
                if previousItems[item.id] != item
                    || host.language != language
                    || host.theme != theme {
                    host.update(item: item, language: language, theme: theme)
                    previousItems[item.id] = item
                }
            } else {
                let host = makeRowHost(for: item)
                rowHosts[item.id] = host
                previousItems[item.id] = item
            }
        }
        orderedIDs = newIDs
    }

    private func makeRowHost(for item: ConversationItem) -> PuraPiConversationRowHost {
        let host = PuraPiConversationRowHost(
            item: item,
            language: language,
            theme: theme
        )
        // 文档视图手动管理每一行的 x/width/height。若保留 `.width` 自动调整，
        // NSScrollView 在首次设置 document frame 时会先把 row 拉伸到一个临时
        // 宽度；SwiftUI 会在这个错误 proposal 下建立换行布局，随后即使 frame
        // 被纠正，也可能留下错误的 intrinsic 高度。
        host.autoresizingMask = []
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        host.onIntrinsicSizeInvalidated = { [weak self] in
            guard let self else { return }
            self.documentView.needsLayout = true
            self.scheduleRelayout(shouldFollowBottom: self.followsBottom)
        }
        return host
    }

    private func scheduleRelayout(shouldFollowBottom: Bool) {
        if shouldFollowBottom {
            pendingFollowBottom = true
        }
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.layoutSubtreeIfNeeded()
            self.scrollView.layoutSubtreeIfNeeded()
            self.documentView.layoutSubtreeIfNeeded()
            let shouldFollow = self.pendingFollowBottom
                && self.followsBottom
                && !self.isUserScrolling
            self.pendingFollowBottom = false
            if shouldFollow {
                self.scrollToBottom()
            }
        }
    }

    private func isAtBottom() -> Bool {
        let visible = scrollView.documentVisibleRect
        let documentHeight = documentView.bounds.height
        guard documentHeight > visible.height + 2 else { return true }
        return visible.maxY >= documentHeight - 28
    }

    private func scrollToBottom() {
        followsBottom = true
        let visibleHeight = scrollView.contentView.bounds.height
        let maximumY = max(0, documentView.bounds.height - visibleHeight)
        isProgrammaticScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticScroll = false
        }
    }
}

/// 每条消息的独立 SwiftUI/AppKit 行宿主。其 intrinsic size（固有尺寸）变化
/// 会通知外层 document view 重新测量，覆盖流式文本和异步 Markdown 完成两类变化。
/// AppKit 行宿主的根视图必须收到明确的宽度提案（proposal，SwiftUI 用来
/// 决定文本换行的可用宽度）。如果只给 `NSHostingView` 一个宽度、再读取
/// 没有宽度上下文的 intrinsic size，长文本会被测成接近单行高度；宿主内容
/// 随后会绘制到相邻行上，表现为历史消息互相重叠。
struct PuraPiConversationRowContent: View, Equatable {
    let item: ConversationItem
    let contentWidth: CGFloat
    let language: PuraPiInterfaceLanguage
    let theme: PuraPiTheme

    var body: some View {
        ConversationItemView(item: item, language: language)
            .puraPiTheme(theme)
            .frame(width: contentWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class PuraPiConversationRowHost: NSHostingView<PuraPiConversationRowContent> {
    private(set) var item: ConversationItem
    private(set) var contentWidth: CGFloat = 1
    private(set) var language: PuraPiInterfaceLanguage
    private(set) var theme: PuraPiTheme
    var onIntrinsicSizeInvalidated: (() -> Void)?
    private var lastReportedHeight: CGFloat = 0
    /// 上一次测量出的高度，以及测量时的宽度。
    ///
    /// 没有这层缓存时，每轮布局都要对每一行调用
    /// `layoutSubtreeIfNeeded()` + `fittingSize`，即让 SwiftUI 重新做一遍
    /// CoreText 测量。实测 1000 条消息因此需要约 4 秒，长会话恢复会明显卡住。
    private var cachedHeight: CGFloat?
    private var cachedHeightWidth: CGFloat = 0

    init(
        item: ConversationItem,
        language: PuraPiInterfaceLanguage,
        theme: PuraPiTheme = .default
    ) {
        self.item = item
        self.language = language
        self.theme = theme
        super.init(
            rootView: PuraPiConversationRowContent(
                item: item,
                contentWidth: 1,
                language: language,
                theme: theme
            )
        )
        sizingOptions = [.intrinsicContentSize]
        autoresizingMask = []
        clipsToBounds = true
    }

    required init(rootView: PuraPiConversationRowContent) {
        self.item = rootView.item
        self.contentWidth = rootView.contentWidth
        self.language = rootView.language
        self.theme = rootView.theme
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        autoresizingMask = []
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        item: ConversationItem,
        language: PuraPiInterfaceLanguage,
        theme: PuraPiTheme
    ) {
        guard self.item != item || self.language != language || self.theme != theme else { return }
        self.item = item
        self.language = language
        self.theme = theme
        cachedHeight = nil
        rootView = PuraPiConversationRowContent(
            item: item,
            contentWidth: contentWidth,
            language: language,
            theme: theme
        )
        invalidateIntrinsicContentSize()
    }

    func updateContentWidth(_ width: CGFloat) {
        let normalizedWidth = max(1, width)
        guard abs(contentWidth - normalizedWidth) > 0.5 else { return }
        contentWidth = normalizedWidth
        cachedHeight = nil
        rootView = PuraPiConversationRowContent(
            item: item,
            contentWidth: normalizedWidth,
            language: language,
            theme: theme
        )
        invalidateIntrinsicContentSize()
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        notifyIfMeasuredHeightChanged()
    }

    override func layout() {
        super.layout()
        // `rootView` 的异步 Markdown 替换有时不会立即把新的 intrinsic
        // size 冒泡到 document view；但只有测量高度确实变化时才通知外层，
        // 避免 layout → callback → layout 的递归循环。
        notifyIfMeasuredHeightChanged()
    }

    private func notifyIfMeasuredHeightChanged() {
        let measuredHeight = fittingSize.height
        guard measuredHeight.isFinite, measuredHeight > 0,
              abs(measuredHeight - lastReportedHeight) > 0.5
        else { return }
        lastReportedHeight = measuredHeight
        // 异步 Markdown 完成会改变真实高度，缓存必须跟着作废，
        // 否则行框会停留在旧高度上，后续行随之错位。
        cachedHeight = nil
        onIntrinsicSizeInvalidated?()
    }

    /// 返回这一行在给定宽度下的高度，可用缓存时不重新测量。
    ///
    /// 布局遍历会对每一行调用它。没有缓存时每次都要触发一遍 SwiftUI 的
    /// CoreText 测量，长会话的重排成本会随条数线性膨胀到数秒。
    func measuredHeight(forWidth width: CGFloat) -> CGFloat? {
        let normalizedWidth = max(1, width)
        if let cachedHeight, abs(cachedHeightWidth - normalizedWidth) <= 0.5 {
            return cachedHeight
        }
        updateContentWidth(normalizedWidth)
        needsLayout = true
        layoutSubtreeIfNeeded()
        let fittingHeight = fittingSize.height
        guard fittingHeight.isFinite, fittingHeight > 0 else { return nil }
        let height = ceil(fittingHeight)
        cachedHeight = height
        cachedHeightWidth = normalizedWidth
        return height
    }
}

@MainActor
/// 对话区的共享布局基准。
///
/// viewport 内的行与 viewport 外的活动指示必须对齐到同一左边界，
/// 否则指示器会与正文错位。
enum PuraPiConversationLayout {
    static let rowHorizontalInset: CGFloat = 30
    static let rowMaximumContentWidth: CGFloat = 900

    /// 行内容的宝度。
    static func rowWidth(availableWidth: CGFloat) -> CGFloat {
        min(
            max(availableWidth - rowHorizontalInset * 2, 1),
            rowMaximumContentWidth
        )
    }

    /// 行内容的左边界。
    ///
    /// 行被限制到 `rowMaximumContentWidth` 后是居中的，所以左边界是
    /// 一个随窗口宽度变化的动态值，不是固定的 `rowHorizontalInset`。
    /// 活动指示在 viewport 外，必须用同一公式算出这个偏移。
    static func rowLeadingOffset(availableWidth: CGFloat) -> CGFloat {
        max((availableWidth - rowWidth(availableWidth: availableWidth)) / 2, 0)
    }
}

final class PuraPiConversationDocumentView: NSView {
    private var orderedItems: [ConversationItem] = []
    private var rowHosts: [UUID: PuraPiConversationRowHost] = [:]
    private var isLayingOutDocument = false
    private var documentWidth: CGFloat = 0
    private let rowSpacing: CGFloat = 22
    private let horizontalInset = PuraPiConversationLayout.rowHorizontalInset
    private let maximumContentWidth = PuraPiConversationLayout.rowMaximumContentWidth
    // Composer 现在是 ConversationPane 的兄弟视图，不再悬浮覆盖 document view。
    // 旧的 190pt 是给悬浮 Composer 预留的，会在 /continue 后制造明显的底部空洞。
    private let bottomInset: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        // 宽度由外层 viewport 显式同步；不要让 NSScrollView 在布局期间
        // 自动改写 document frame，造成 row proposal 与实际宽度短暂分离。
        autoresizingMask = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setDocumentWidth(_ width: CGFloat) {
        let normalizedWidth = max(1, width)
        documentWidth = normalizedWidth
        var documentFrame = frame
        if abs(documentFrame.width - normalizedWidth) > 0.5 {
            documentFrame.size.width = normalizedWidth
            frame = documentFrame
        }
        needsLayout = true
    }

    func update(
        orderedItems: [ConversationItem],
        hosts: [UUID: PuraPiConversationRowHost]
    ) {
        self.orderedItems = orderedItems
        self.rowHosts = hosts
        for item in orderedItems {
            guard let host = hosts[item.id], host.superview !== self else { continue }
            addSubview(host)
        }
        needsLayout = true
    }

    override func layout() {
        guard !isLayingOutDocument else { return }
        isLayingOutDocument = true
        defer { isLayingOutDocument = false }
        super.layout()
        guard documentWidth > 1 else { return }
        let availableWidth = documentWidth
        if abs(bounds.width - availableWidth) > 1 {
            var synchronizedFrame = frame
            synchronizedFrame.size.width = availableWidth
            frame = synchronizedFrame
        }

        let rowWidth = PuraPiConversationLayout.rowWidth(availableWidth: availableWidth)
        let rowX = PuraPiConversationLayout.rowLeadingOffset(availableWidth: availableWidth)
        var y: CGFloat = 0

        for item in orderedItems {
            guard let host = rowHosts[item.id] else { continue }
            // 高度由 host 负责测量并缓存：内容与宽度都没变时直接复用，
            // 否则在明确的宽度 proposal 下重新测一次。不能跳过宽度设置，
            // 否则长行会被当成单行内容，后续行就会绘制到它上面。
            guard let height = host.measuredHeight(forWidth: rowWidth) else { continue }
            host.frame = NSRect(x: rowX, y: y, width: rowWidth, height: height)
            y += height + rowSpacing
        }

        if !orderedItems.isEmpty {
            y -= rowSpacing
        }
        let desiredHeight = max(1, y + (orderedItems.isEmpty ? 0 : bottomInset))
        let desiredSize = NSSize(width: availableWidth, height: desiredHeight)
        if abs(frame.width - desiredSize.width) > 0.5
            || abs(frame.height - desiredSize.height) > 0.5 {
            setFrameSize(desiredSize)
        }
    }

    func detach() {
        for host in rowHosts.values {
            host.removeFromSuperview()
        }
        rowHosts.removeAll()
        orderedItems.removeAll()
    }
}
