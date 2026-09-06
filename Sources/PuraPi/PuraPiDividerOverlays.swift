import AppKit

@available(macOS 26.0, *)
final class PuraPiDividerVisualMask: NSView {
    var maskedRects: [NSRect] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 只遮住 AppKit 辅助 grabber 的小圆点；使用系统语义背景色，
        // 不绘制固定 RGB 色带，也让浅色/深色外观自动同步。
        NSColor.underPageBackgroundColor.setFill()
        for rect in maskedRects where rect.intersects(dirtyRect) {
            // AppKit 已按 dirtyRect 裁剪绘制；路径必须使用完整圆形，否则局部
            // 重绘时把交集矩形当成椭圆会改变遮罩形状。
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只遮挡绘制，不抢走拖动覆盖层或普通内容的事件。
        nil
    }
}


/// 分隔线命中区的透明覆盖层，唯一职责是禁止窗口背景拖拽。
///
/// 它装在 `NSSplitView` 的**父视图**上并排在其之上，因此不受 AppKit 对
/// split view 内部 subviews 的重排影响（装在内部实测会被压到栏包装视图之下）。
///
/// 只在命中区内接管：`hitTest` 区内返回自己（AppKit 随即查到
/// `mouseDownCanMoveWindow = false`），区外返回 nil，事件照常下传，
/// 因此其他位置仍可"拖内容背景移动窗口"。
@available(macOS 26.0, *)
final class PuraPiDividerWindowDragBlocker: NSView {
    /// 命中区矩形（splitView 坐标系），由控制器实时提供。
    var hitRectsInSplitView: (() -> [NSRect])?
    weak var splitView: NSSplitView?

    override var mouseDownCanMoveWindow: Bool { false }

    /// 纯拦截层，不参与绘制。
    override func draw(_ dirtyRect: NSRect) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 在父视图坐标系；换算到 splitView 坐标系再比对。
        guard let splitView,
              let superview,
              let rects = hitRectsInSplitView?()
        else { return nil }
        let pointInSplitView = splitView.convert(point, from: superview)
        return rects.contains(where: { $0.contains(pointInSplitView) }) ? self : nil
    }

    override func resetCursorRects() {
        guard let splitView, let rects = hitRectsInSplitView?() else { return }
        for rect in rects {
            addCursorRect(convert(rect, from: splitView), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 必须转发，否则分隔线拖不动。窗口拖拽已由
        // mouseDownCanMoveWindow = false 排除。
        splitView?.mouseDown(with: event)
    }
}
