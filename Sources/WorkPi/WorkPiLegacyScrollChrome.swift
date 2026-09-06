import AppKit

/// AppKit 托管滚动视图的顶部滚动边缘效果。
///
/// SwiftUI 的 `scrollEdgeEffectStyle` 只能作用于 SwiftUI 自己创建的
/// `ScrollView`。中心对话区是为了性能而自建的 AppKit `NSScrollView`，因此需要
/// 在其 floating layer（悬浮层）上挂一个语义化 `NSVisualEffectView`，并根据真实
/// content offset（内容偏移）调整系统材质的 mask（透明度遮罩）。这里遮罩的是
/// 系统材质本身，不绘制固定 RGB 背景或伪造玻璃颜色。
///
/// 同一个适配器也供 macOS 14–25 使用：旧系统没有 SwiftUI 的 scroll-edge API，
/// 由 `NSVisualEffectView` 提供兼容的模糊失焦效果。macOS 26.1+ 不走这条路径，
/// 而是交给 SwiftUI/AppKit 的公开系统 pocket。
final class WorkPiScrollEdgeEffectView: NSView {
    // 旧系统 fallback 保留原有的渐隐范围；macOS 26.1+ 不使用此层，交给
    // AppKit/SwiftUI 的系统 pocket 管理实际边缘几何。
    static let height: CGFloat = 132

    private let materialView: NSVisualEffectView
    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var contentBoundsObserver: NSObjectProtocol?
    private var scrollBoundsObserver: NSObjectProtocol?
    private var documentBoundsObserver: NSObjectProtocol?
    private var documentFrameObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var previousScrollPostsBoundsChangedNotifications = false
    private var previousContentPostsBoundsChangedNotifications = false
    private var previousDocumentPostsBoundsChangedNotifications = false
    private var previousDocumentPostsFrameChangedNotifications = false
    private var lastStrength: CGFloat = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        materialView = NSVisualEffectView(frame: .zero)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        // `.headerView` 是 AppKit 公开的语义材质，颜色和模糊强度随窗口外观、
        // blending mode（混合模式）及系统版本解析，不绑定某一套 RGB。
        materialView.material = .headerView
        materialView.blendingMode = .withinWindow
        materialView.state = .followsWindowActiveState
        materialView.wantsLayer = true
        materialView.layer?.backgroundColor = NSColor.clear.cgColor
        materialView.autoresizingMask = [.width, .height]
        materialView.isHidden = true
        addSubview(materialView)

        // 使用 NSVisualEffectView 公开的 maskImage 只裁切系统材质的 alpha：顶部
        // 材质最强，向内容区平滑衰减。它不会在滚动内容上绘制固定颜色矩形。
        materialView.maskImage = Self.materialMaskImage
        updateMask(strength: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        updateEffect()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            // deinit 在 Swift 6 中是 nonisolated；在离开窗口时提前收回观察者，
            // 既避免通知 token 泄漏，也不在析构阶段跨 actor 访问 AppKit 状态。
            detach()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// 将效果挂到真实滚动视图的 floating layer。父视图返回 nil 命中，
    /// 因此顶部消息、标题和文本选择仍由原滚动内容接收鼠标事件。
    func attach(to scrollView: NSScrollView) {
        restoreDocumentNotificationState()
        restoreScrollNotificationState()
        removeObservers()
        self.scrollView = scrollView
        self.documentView = scrollView.documentView
        previousScrollPostsBoundsChangedNotifications = scrollView.postsBoundsChangedNotifications
        previousContentPostsBoundsChangedNotifications = scrollView.contentView.postsBoundsChangedNotifications
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsBoundsChangedNotifications = true

        if let documentView = scrollView.documentView {
            self.documentView = documentView
            previousDocumentPostsBoundsChangedNotifications = documentView.postsBoundsChangedNotifications
            previousDocumentPostsFrameChangedNotifications = documentView.postsFrameChangedNotifications
            documentView.postsBoundsChangedNotifications = true
            documentView.postsFrameChangedNotifications = true

            documentBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateEffect()
                }
            }

            documentFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateEffect()
                }
            }
        }

        contentBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateEffect()
            }
        }

        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.updateFrame(for: scrollView)
                self.updateEffect()
            }
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: scrollView.window,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.updateFrame(for: scrollView)
                self.updateEffect()
            }
        }

        updateFrame(for: scrollView)
        updateEffect()
    }

    func detach() {
        restoreDocumentNotificationState()
        restoreScrollNotificationState()
        removeObservers()
        scrollView = nil
        documentView = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 这是纯绘制层，不能挡住顶部消息、Inspector 文本或编辑器光标。
        nil
    }

    func updateFrame(for scrollView: NSScrollView) {
        guard superview != nil else { return }
        var frame = self.frame
        frame.origin.x = 0
        frame.origin.y = 0
        frame.size.width = scrollView.bounds.width
        frame.size.height = Self.height
        self.frame = frame
        needsLayout = true
    }

    private func updateEffect() {
        guard let scrollView,
              let documentView = scrollView.documentView
        else {
            updateMask(strength: 0)
            return
        }

        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 1,
              documentView.bounds.height > visibleHeight + 1
        else {
            updateMask(strength: 0)
            return
        }

        // 使用 documentVisibleRect 而不是 contentView 的原始 y：前者已经转换到
        // document 坐标，能够正确处理 flipped / 非 flipped 视图以及系统内缩。
        let visibleRect = scrollView.documentVisibleRect
        let distanceFromTop: CGFloat
        if documentView.isFlipped {
            distanceFromTop = max(0, visibleRect.minY - documentView.bounds.minY)
        } else {
            distanceFromTop = max(0, documentView.bounds.maxY - visibleRect.maxY)
        }

        // 约 36pt 的滚动距离后达到完整效果；顶部和弹性回弹区保持清晰。
        updateMask(strength: min(1, distanceFromTop / 36))
    }

    private func updateMask(strength: CGFloat) {
        let clamped = min(1, max(0, strength))
        guard abs(clamped - lastStrength) > 0.005 else { return }
        lastStrength = clamped

        // maskImage 固定负责空间上的渐隐；alphaValue 根据真实滚动距离控制
        // 整体强度，避免每一帧重建图片或触碰滚动内容。
        materialView.alphaValue = clamped
        materialView.isHidden = clamped <= 0.001
    }

    private static let materialMaskImage: NSImage = {
        let height = Int(WorkPiScrollEdgeEffectView.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: 1, height: WorkPiScrollEdgeEffectView.height))
        }

        // 这是材质 alpha 的 mask，不是 UI 颜色。顶部为白色不透明，底部逐渐
        // 透明；NSVisualEffectView 会负责实际的系统模糊和色彩合成。
        let stops: [(position: CGFloat, alpha: CGFloat)] = [
            (0, 1.0),
            (0.14, 0.9),
            (0.32, 0.58),
            (0.54, 0.28),
            (0.74, 0.09),
            (0.9, 0.02),
            (1, 0)
        ]
        for y in 0..<height {
            // NSBitmapImageRep 的原点在左下；翻转索引，让视觉顶部使用首个 stop。
            let position = 1 - CGFloat(y) / CGFloat(max(1, height - 1))
            let alpha: CGFloat
            if let upperIndex = stops.firstIndex(where: { position <= $0.position }) {
                let upper = stops[upperIndex]
                if upperIndex == 0 {
                    alpha = upper.alpha
                } else {
                    let lower = stops[upperIndex - 1]
                    let amount = (position - lower.position) / (upper.position - lower.position)
                    alpha = lower.alpha + (upper.alpha - lower.alpha) * amount
                }
            } else {
                alpha = stops.last?.alpha ?? 0
            }
            var pixel: [UInt] = [255, 255, 255, UInt((alpha * 255).rounded())]
            rep.setPixel(&pixel, atX: 0, y: y)
        }

        let image = NSImage(
            size: NSSize(width: 1, height: WorkPiScrollEdgeEffectView.height)
        )
        image.addRepresentation(rep)
        image.capInsets = NSEdgeInsetsZero
        return image
    }()

    private func restoreDocumentNotificationState() {
        guard let documentView else { return }
        documentView.postsBoundsChangedNotifications = previousDocumentPostsBoundsChangedNotifications
        documentView.postsFrameChangedNotifications = previousDocumentPostsFrameChangedNotifications
    }

    private func restoreScrollNotificationState() {
        guard let scrollView else { return }
        scrollView.postsBoundsChangedNotifications = previousScrollPostsBoundsChangedNotifications
        scrollView.contentView.postsBoundsChangedNotifications = previousContentPostsBoundsChangedNotifications
    }

    private func removeObservers() {
        for observer in [
            contentBoundsObserver,
            scrollBoundsObserver,
            documentBoundsObserver,
            documentFrameObserver,
            windowObserver
        ] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        contentBoundsObserver = nil
        scrollBoundsObserver = nil
        documentBoundsObserver = nil
        documentFrameObserver = nil
        windowObserver = nil
    }
}
