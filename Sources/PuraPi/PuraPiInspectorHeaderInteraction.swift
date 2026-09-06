import AppKit
import PiDomain
import SwiftUI

/// Inspector 标题栏的共享几何。
///
/// SwiftUI 的预览滚动容器会桥接成覆盖整个表面的 AppKit `NSScrollView`。
/// 因此实际鼠标命中代理由 `PuraPiWorkspaceSplitViewController` 放在 pane
/// 父视图上；这里集中保存它与 SwiftUI 标题栏必须一致的尺寸。
enum PuraPiInspectorHeaderMetrics {
    static let height: CGFloat = 36
    static let separatorHeight: CGFloat = 0.5
    static let actionWidth: CGFloat = 95
    static let trailingPadding: CGFloat = 13
    static let horizontalPadding: CGFloat = 13
    static let verticalPadding: CGFloat = 6
    static let buttonHeight: CGFloat = 24
    static let buttonSpacing: CGFloat = 8
    static let maximizeWidth: CGFloat = 22
    static let menuWidth: CGFloat = 33
    static let closeWidth: CGFloat = 24
    /// 独立/挂回按钮单独由一个命中代理承载，以保持旧三按钮代理的几何契约。
    static let detachWidth: CGFloat = 22
    static let detachSpacing: CGFloat = 8

    static var totalHeight: CGFloat {
        height + separatorHeight
    }
}

/// 位于 Inspector pane 父视图上的透明标题栏交互层。
///
/// macOS 26 下，Inspector 内部的 SwiftUI `ScrollView` 可能在 AppKit 视图树中
/// 覆盖标题栏的绘制区域。把真实的透明 `NSButton` 放到 pane 外层，既不改变
/// 滚动容器，也不会依赖 AppKit 私有视图类名；普通内容区域仍按原逻辑可拖动窗口。
@MainActor
final class PuraPiInspectorHeaderInteractionView: NSView {
    private let maximizeButton = PuraPiInspectorProxyButton()
    private let menuButton = PuraPiInspectorProxyButton()
    private let closeButton = PuraPiInspectorProxyButton()

    private var previewURL: URL?
    private var isEnglish = false
    private var isDetached = false
    private var onToggleMaximize: () -> Void = {}
    private var onToggleDetached: () -> Void = {}
    private var onClose: () -> Void = {}
    private var onReveal: (URL) -> Void = { _ in }
    private var onOpen: (URL) -> Void = { _ in }
    private var onCopyPath: (URL) -> Void = { _ in }
    private var onCopyRelativePath: (URL) -> Void = { _ in }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(
            maximizeButton,
            label: "最大化编辑区",
            action: #selector(toggleMaximize)
        )
        configure(
            menuButton,
            label: "更多",
            action: #selector(showMenu)
        )
        configure(
            closeButton,
            label: "关闭文件检查器",
            action: #selector(closeInspector)
        )
        addSubview(maximizeButton)
        addSubview(menuButton)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        previewURL: URL?,
        showsFileActions: Bool,
        language: PuraPiInterfaceLanguage,
        isDetached: Bool = false,
        onToggleMaximize: @escaping () -> Void,
        onToggleDetached: @escaping () -> Void = {},
        onClose: @escaping () -> Void,
        onReveal: @escaping (URL) -> Void,
        onOpen: @escaping (URL) -> Void,
        onCopyPath: @escaping (URL) -> Void,
        onCopyRelativePath: @escaping (URL) -> Void
    ) {
        self.previewURL = previewURL
        isEnglish = language == .english
        self.isDetached = isDetached
        self.onToggleMaximize = onToggleMaximize
        self.onToggleDetached = onToggleDetached
        self.onClose = onClose
        self.onReveal = onReveal
        self.onOpen = onOpen
        self.onCopyPath = onCopyPath
        self.onCopyRelativePath = onCopyRelativePath
        // 独立窗口使用系统标题栏的 Zoom 按钮；不能让主栏“最大化编辑区”
        // 的状态误操作共享的 layoutState。
        maximizeButton.isHidden = !showsFileActions || isDetached
        menuButton.isHidden = !showsFileActions
        closeButton.isHidden = false
        maximizeButton.setAccessibilityLabel(
            isEnglish ? "Maximize editor" : "最大化编辑区"
        )
        menuButton.setAccessibilityLabel(isEnglish ? "More" : "更多")
        closeButton.setAccessibilityLabel(
            isEnglish ? "Close file inspector" : "关闭文件检查器"
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = max(0, (bounds.height - PuraPiInspectorHeaderMetrics.buttonHeight) / 2)
        var x: CGFloat = 0

        if isDetached {
            // 独立窗口由系统标题栏负责 Zoom；不为隐藏按钮保留一段可点击的
            // 空白命中区，菜单和关闭按钮与其 SwiftUI 视觉位置保持一致。
            maximizeButton.frame = .zero
        } else {
            maximizeButton.frame = NSRect(
                x: x,
                y: y,
                width: PuraPiInspectorHeaderMetrics.maximizeWidth,
                height: PuraPiInspectorHeaderMetrics.buttonHeight
            )
            x += PuraPiInspectorHeaderMetrics.maximizeWidth
                + PuraPiInspectorHeaderMetrics.buttonSpacing
        }

        menuButton.frame = NSRect(
            x: x,
            y: y,
            width: PuraPiInspectorHeaderMetrics.menuWidth,
            height: PuraPiInspectorHeaderMetrics.buttonHeight
        )
        x += PuraPiInspectorHeaderMetrics.menuWidth
            + PuraPiInspectorHeaderMetrics.buttonSpacing

        closeButton.frame = NSRect(
            x: x,
            y: y,
            width: PuraPiInspectorHeaderMetrics.closeWidth,
            height: PuraPiInspectorHeaderMetrics.buttonHeight
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 某些 AppKit 容器调用自定义子视图的 hitTest 时仍传入父坐标；
        // 同时兼容直接调用时已经是本地坐标的情况。
        let localPoint: NSPoint
        if bounds.contains(point) {
            localPoint = point
        } else if let superview {
            localPoint = convert(point, from: superview)
        } else {
            return nil
        }
        for button in [maximizeButton, menuButton, closeButton]
            where !button.isHidden && button.frame.contains(localPoint) {
            return button
        }
        // 标题栏中非按钮的空白仍交回下面的内容，保留窗口背景拖动能力。
        return nil
    }

    private func configure(_ button: NSButton, label: String, action: Selector) {
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = self
        button.action = action
        button.alphaValue = 1
        button.setAccessibilityElement(false)
        button.setAccessibilityLabel(label)
    }

    @objc private func toggleMaximize() {
        onToggleMaximize()
    }

    @objc private func closeInspector() {
        onClose()
    }

    @objc private func toggleDetached() {
        onToggleDetached()
    }

    @objc private func showMenu() {
        guard previewURL != nil else { return }

        let menu = NSMenu()
        menu.addItem(
            menuItem(
                isEnglish ? "Copy Absolute Path" : "复制绝对路径",
                action: #selector(copyAbsolutePath)
            )
        )
        menu.addItem(
            menuItem(
                isEnglish ? "Copy Relative Path" : "复制相对路径",
                action: #selector(copyRelativePath)
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                isEnglish ? "Show in Finder" : "在 Finder 中显示",
                action: #selector(revealInFinder)
            )
        )
        menu.addItem(
            menuItem(
                isEnglish ? "Open with Default Application" : "用默认应用打开",
                action: #selector(openWithDefaultApplication)
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                isDetached
                    ? (isEnglish ? "Reattach to Main Window" : "挂回主窗口")
                    : (isEnglish ? "Open in Separate Window" : "在独立窗口中打开"),
                action: #selector(toggleDetached)
            )
        )

        // 菜单从按钮下方弹出；坐标使用代理自身的 flipped 坐标系。
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY),
            in: self
        )
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyAbsolutePath() {
        guard let previewURL else { return }
        onCopyPath(previewURL)
    }

    @objc private func copyRelativePath() {
        guard let previewURL else { return }
        onCopyRelativePath(previewURL)
    }

    @objc private func revealInFinder() {
        guard let previewURL else { return }
        onReveal(previewURL)
    }

    @objc private func openWithDefaultApplication() {
        guard let previewURL else { return }
        onOpen(previewURL)
    }
}

/// SwiftUI fallback（降级路径）的宿主包装；它与原生路径共用同一个 AppKit
/// 命中视图，但由外层 SwiftUI 负责提供位置。
@MainActor
struct PuraPiInspectorHeaderInteractionRepresentable: NSViewRepresentable {
    let previewURL: URL?
    let showsFileActions: Bool
    let isDetached: Bool
    let language: PuraPiInterfaceLanguage
    let onToggleMaximize: () -> Void
    let onToggleDetached: () -> Void
    let onClose: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void

    init(
        previewURL: URL?,
        showsFileActions: Bool,
        isDetached: Bool = false,
        language: PuraPiInterfaceLanguage,
        onToggleMaximize: @escaping () -> Void,
        onToggleDetached: @escaping () -> Void = {},
        onClose: @escaping () -> Void,
        onReveal: @escaping (URL) -> Void,
        onOpen: @escaping (URL) -> Void,
        onCopyPath: @escaping (URL) -> Void,
        onCopyRelativePath: @escaping (URL) -> Void
    ) {
        self.previewURL = previewURL
        self.showsFileActions = showsFileActions
        self.isDetached = isDetached
        self.language = language
        self.onToggleMaximize = onToggleMaximize
        self.onToggleDetached = onToggleDetached
        self.onClose = onClose
        self.onReveal = onReveal
        self.onOpen = onOpen
        self.onCopyPath = onCopyPath
        self.onCopyRelativePath = onCopyRelativePath
    }

    func makeNSView(context: Context) -> PuraPiInspectorHeaderInteractionView {
        let view = PuraPiInspectorHeaderInteractionView()
        view.update(
            previewURL: previewURL,
            showsFileActions: showsFileActions,
            language: language,
            isDetached: isDetached,
            onToggleMaximize: onToggleMaximize,
            onToggleDetached: onToggleDetached,
            onClose: onClose,
            onReveal: onReveal,
            onOpen: onOpen,
            onCopyPath: onCopyPath,
            onCopyRelativePath: onCopyRelativePath
        )
        return view
    }

    func updateNSView(
        _ nsView: PuraPiInspectorHeaderInteractionView,
        context: Context
    ) {
        nsView.update(
            previewURL: previewURL,
            showsFileActions: showsFileActions,
            language: language,
            isDetached: isDetached,
            onToggleMaximize: onToggleMaximize,
            onToggleDetached: onToggleDetached,
            onClose: onClose,
            onReveal: onReveal,
            onOpen: onOpen,
            onCopyPath: onCopyPath,
            onCopyRelativePath: onCopyRelativePath
        )
    }
}

/// 独立/挂回按钮的透明 AppKit 命中代理。
///
/// 它与原有的最大化/菜单/关闭代理分开，保留旧代理的三按钮几何契约；
/// SwiftUI 负责绘制图标，代理只负责在滚动视图覆盖标题时接收点击。
@MainActor
final class PuraPiInspectorDetachInteractionView: NSView {
    private let button = PuraPiInspectorProxyButton()
    private var isEnglish = false
    private var onToggleDetached: () -> Void = {}

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = self
        button.action = #selector(toggleDetached)
        button.setAccessibilityElement(false)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        showsFileActions: Bool,
        isDetached: Bool,
        language: PuraPiInterfaceLanguage,
        onToggleDetached: @escaping () -> Void
    ) {
        isEnglish = language == .english
        self.onToggleDetached = onToggleDetached
        button.isHidden = !showsFileActions
        button.setAccessibilityLabel(
            isDetached
                ? (isEnglish ? "Reattach to main window" : "挂回主窗口")
                : (isEnglish ? "Open in separate window" : "在独立窗口中打开")
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = PuraPiInspectorHeaderMetrics.buttonHeight
        button.frame = NSRect(
            x: 0,
            y: max(0, (bounds.height - height) / 2),
            width: bounds.width,
            height: height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 与旧标题代理保持一致：部分 AppKit 容器会把父层坐标直接传入自定义
        // hitTest，不能只按当前视图坐标判断。
        let localPoint: NSPoint
        if bounds.contains(point) {
            localPoint = point
        } else if let superview {
            localPoint = convert(point, from: superview)
        } else {
            return nil
        }
        guard !button.isHidden, button.frame.contains(localPoint) else { return nil }
        return button
    }

    @objc private func toggleDetached() {
        onToggleDetached()
    }
}

/// SwiftUI 对独立/挂回命中代理的桥接。
@MainActor
struct PuraPiInspectorDetachInteractionRepresentable: NSViewRepresentable {
    let showsFileActions: Bool
    let isDetached: Bool
    let language: PuraPiInterfaceLanguage
    let onToggleDetached: () -> Void

    init(
        showsFileActions: Bool,
        isDetached: Bool = false,
        language: PuraPiInterfaceLanguage,
        onToggleDetached: @escaping () -> Void = {}
    ) {
        self.showsFileActions = showsFileActions
        self.isDetached = isDetached
        self.language = language
        self.onToggleDetached = onToggleDetached
    }

    func makeNSView(context: Context) -> PuraPiInspectorDetachInteractionView {
        let view = PuraPiInspectorDetachInteractionView()
        view.update(
            showsFileActions: showsFileActions,
            isDetached: isDetached,
            language: language,
            onToggleDetached: onToggleDetached
        )
        return view
    }

    func updateNSView(
        _ nsView: PuraPiInspectorDetachInteractionView,
        context: Context
    ) {
        nsView.update(
            showsFileActions: showsFileActions,
            isDetached: isDetached,
            language: language,
            onToggleDetached: onToggleDetached
        )
    }
}

/// Inspector 标题操作代理的组合；legacy 和独立窗口直接复用，native 路径则
/// 将两个 AppKit 代理分别放到 splitView 父层，以避开滚动视图覆盖。
@MainActor
struct PuraPiInspectorHeaderInteractionStack: View {
    let previewURL: URL?
    let showsFileActions: Bool
    let isDetached: Bool
    let language: PuraPiInterfaceLanguage
    let onToggleMaximize: () -> Void
    let onToggleDetached: () -> Void
    let onClose: () -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onCopyPath: (URL) -> Void
    let onCopyRelativePath: (URL) -> Void

    var body: some View {
        HStack(spacing: PuraPiInspectorHeaderMetrics.detachSpacing) {
            PuraPiInspectorDetachInteractionRepresentable(
                showsFileActions: showsFileActions,
                isDetached: isDetached,
                language: language,
                onToggleDetached: onToggleDetached
            )
            .frame(
                width: PuraPiInspectorHeaderMetrics.detachWidth,
                height: PuraPiInspectorHeaderMetrics.totalHeight
            )
            PuraPiInspectorHeaderInteractionRepresentable(
                previewURL: previewURL,
                showsFileActions: showsFileActions,
                isDetached: isDetached,
                language: language,
                onToggleMaximize: onToggleMaximize,
                onToggleDetached: onToggleDetached,
                onClose: onClose,
                onReveal: onReveal,
                onOpen: onOpen,
                onCopyPath: onCopyPath,
                onCopyRelativePath: onCopyRelativePath
            )
            .frame(
                width: PuraPiInspectorHeaderMetrics.actionWidth,
                height: PuraPiInspectorHeaderMetrics.totalHeight
            )
        }
    }
}

/// 不绘制任何内容的透明 AppKit 按钮，只承担标题栏的鼠标命中与 action 转发。
@MainActor
private final class PuraPiInspectorProxyButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {}
}
