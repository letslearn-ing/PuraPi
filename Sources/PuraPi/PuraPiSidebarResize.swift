import AppKit
import SwiftUI

/// 栏边缘的原生拖拽区域。
/// 使用 AppKit 鼠标事件而不是 SwiftUI `DragGesture`，避免透明光标层截获按下事件。
struct PuraPiSidebarResizeHandle: NSViewRepresentable {
    /// 拖动方向。决定鼠标位移如何折算成宽度变化。
    enum Edge {
        /// 手柄在栏的右边缘（Sidebar）：向右拖变宽。
        case trailingEdgeOfLeadingPane
        /// 手柄在栏的左边缘（Inspector）：向左拖变宽。
        case leadingEdgeOfTrailingPane

        var deltaSign: CGFloat {
            switch self {
            case .trailingEdgeOfLeadingPane: return 1
            case .leadingEdgeOfTrailingPane: return -1
            }
        }
    }

    let width: CGFloat
    var edge: Edge = .trailingEdgeOfLeadingPane
    let onResizeStart: () -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PuraPiSidebarResizeNSView {
        let view = PuraPiSidebarResizeNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: PuraPiSidebarResizeNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: PuraPiSidebarResizeNSView) {
        view.currentWidth = width
        view.deltaSign = edge.deltaSign
        view.onResizeStart = onResizeStart
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
        view.onHover = onHover
    }
}

final class PuraPiSidebarResizeNSView: NSView {
    var currentWidth: CGFloat = PuraPiLayoutState.defaultSidebarWidth
    /// 鼠标位移到宽度变化的符号。右边缘手柄为 +1，左边缘手柄为 -1。
    var deltaSign: CGFloat = 1
    var onResizeStart: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var dragStartScreenX: CGFloat?
    private var dragStartWidth: CGFloat?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenX = screenX(for: event)
        dragStartWidth = currentWidth
        onResizeStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartScreenX, let dragStartWidth else { return }
        let delta = (screenX(for: event) - dragStartScreenX) * deltaSign
        onResize?(dragStartWidth + delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartScreenX = nil
        dragStartWidth = nil
        onResizeEnd?()
    }

    private func screenX(for event: NSEvent) -> CGFloat {
        guard let window else { return NSEvent.mouseLocation.x }
        return window.convertPoint(toScreen: event.locationInWindow).x
    }
}
