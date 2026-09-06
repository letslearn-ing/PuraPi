import AppKit
import SwiftUI

/// HUD 下拉项的一条候选。
struct WorkPiHUDMenuOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isSelected: Bool
}

/// 由 AppKit `NSMenu` 承载的 HUD 下拉。
///
/// 不使用 SwiftUI `Menu`：在 macOS 上给它套自定义 label 时，`.borderlessButton`
/// 会用系统弹出按钮外观替掉 label（值文本消失），而叠加 `.buttonStyle(.plain)`
/// 又会吃掉点击、菜单不展开。这里直接用 `NSMenu.popUp`，保证外观与命中都可控。
struct WorkPiHUDMenu: NSViewRepresentable {
    let options: [WorkPiHUDMenuOption]
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> WorkPiHUDMenuHostView {
        let view = WorkPiHUDMenuHostView()
        view.onSelect = onSelect
        view.options = options
        return view
    }

    func updateNSView(_ nsView: WorkPiHUDMenuHostView, context: Context) {
        nsView.onSelect = onSelect
        nsView.options = options
    }
}

/// 透明的命中层：铺在 HUD 项之上，点击时在自身下沿弹出菜单。
final class WorkPiHUDMenuHostView: NSView {
    var options: [WorkPiHUDMenuOption] = []
    var onSelect: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !options.isEmpty else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options {
            let item = NSMenuItem(
                title: option.detail.isEmpty || option.detail == option.title
                    ? option.title
                    : "\(option.title)  ·  \(option.detail)",
                action: #selector(handleSelection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
            item.state = option.isSelected ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
        }

        // 在命中层左下角弹出，视觉上贴着 HUD 项。
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: bounds.maxY + 4),
            in: self
        )
    }

    @objc private func handleSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect?(id)
    }

    /// 允许在窗口非激活状态下首次点击即命中。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
