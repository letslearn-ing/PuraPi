import AppKit
import SwiftUI

/// 单个 Markdown 表格单元格的 AppKit 编辑桥。
///
/// 使用字段编辑代理直接接收文本变化和 Tab 命令，避免 SwiftUI `TextField` 的
/// 默认焦点循环把 Tab 带出表格；所有状态仍由上层表格模型拥有。
@MainActor
struct PuraPiMarkdownTableCellEditor: NSViewRepresentable {
    let text: String
    let isHeader: Bool
    let isFocused: Bool
    let onChange: (String) -> Void
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onMove: (Bool) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    func makeNSView(context: Context) -> PuraPiTableCellTextField {
        let field = PuraPiTableCellTextField()
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 12.5, weight: isHeader ? .semibold : .regular)
        field.textColor = isHeader ? .labelColor : .secondaryLabelColor
        field.alignment = .left
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: PuraPiTableCellTextField, context: Context) {
        context.coordinator.owner = self
        let hasMarkedText = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !hasMarkedText, nsView.stringValue != text {
            context.coordinator.suppressCallbacks = true
            nsView.stringValue = text
            context.coordinator.suppressCallbacks = false
        }
        nsView.font = .systemFont(ofSize: 12.5, weight: isHeader ? .semibold : .regular)
        nsView.textColor = isHeader ? .labelColor : .secondaryLabelColor
        if isFocused, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        } else if !isFocused, nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: PuraPiMarkdownTableCellEditor
        var suppressCallbacks = false

        init(owner: PuraPiMarkdownTableCellEditor) {
            self.owner = owner
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            owner.onFocus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !suppressCallbacks,
                  let field = notification.object as? NSTextField
            else { return }
            // NSTextField 的 field editor 也会在中文输入法组合期间发出
            // textDidChange；临时拼音不能先写入表格模型再被 SwiftUI 重绘覆盖。
            if let editor = field.currentEditor() as? NSTextView,
               editor.hasMarkedText() {
                return
            }
            owner.onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            owner.onBlur()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch NSStringFromSelector(selector) {
            case "insertTab:":
                owner.onMove(true)
                return true
            case "insertBacktab:":
                owner.onMove(false)
                return true
            case "insertNewline:":
                owner.onMove(true)
                return true
            case "undo:":
                owner.onUndo()
                return true
            case "redo:":
                owner.onRedo()
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
final class PuraPiTableCellTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }
}
