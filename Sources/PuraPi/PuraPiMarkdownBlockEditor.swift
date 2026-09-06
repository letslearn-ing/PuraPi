import AppKit
import PiDomain
import SwiftUI

/// 单个块的编辑视图。
///
/// 每块一个 `NSTextView` 是块状编辑器的核心。实测依据（见
/// `docs/MARKDOWN_EDITOR.md`）：块状首屏恒定约 11 ms，而单一 TextView 在
/// 97k 字符时需要 111 ms；按键成本两者都是常数。
///
/// 必须用 TextKit 2：TextKit 1 的 `ensureLayout` 会重排整个容器，97k 字符时
/// 单次按键 0.155 ms 且随长度增长；TextKit 2 只布局视口，恒定 0.088 ms。
/// **不要访问 `layoutManager`**，那会让 NSTextView 静默降级到 TextKit 1。
struct PuraPiMarkdownBlockEditor: NSViewRepresentable {
    let block: MarkdownBlock
    let isFocused: Bool
    let language: PuraPiInterfaceLanguage
    /// 块内文本变更。传出的是显示文本，由调用方组合回源码。
    let onChange: (String) -> Void
    /// 多行粘贴交给容器解析为多个 Markdown 块；返回 true 表示已处理。
    let onPaste: (String, NSRange) -> Bool
    /// 跨块选择的文本替换；单块选择返回 false，交还 NSTextView。
    let onReplaceSelection: (String) -> Bool
    /// 跨块选择的删除；单块选择返回 false，交还 NSTextView。
    let onDeleteSelection: () -> Bool
    /// 当前文档级选择映射到本块正文的范围。
    let selectionRange: NSRange?
    let onSelectionChanged: (NSRange) -> Void
    let onExtendSelection: (Int, NSRange) -> Bool
    let onCopySelection: () -> Bool
    let onSelectAll: () -> Void
    let onFind: () -> Void
    let onSyntaxHint: (String?) -> Void
    /// 在块尾按 Return：请求新建块。
    let onSplit: (String, String) -> Void
    /// 在块首按 Backspace：请求与上一块合并。
    let onMergeBackward: () -> Void
    /// 非段落块在块首按 Backspace 时先退回普通段落；返回是否已处理。
    let onRevertBlockType: () -> Bool
    let onFocus: () -> Void
    /// 用户直接点入块时取消尚未执行的旧导航请求。
    let onUserInteraction: () -> Void
    /// 光标离开块时隐藏行内源码标记。
    let onBlur: () -> Void
    /// 跨块撤销/重做由文档状态统一处理，而不是由单个 NSTextView 处理。
    let onUndo: () -> Void
    let onRedo: () -> Void
    /// ⌘↑ / ⌘↓ 移动到整个 Markdown 文档的首尾。
    let onMoveToStart: () -> Void
    let onMoveToEnd: () -> Void
    /// 列表块的 Tab/⇧Tab 缩进，以及空列表项的 Return 退出。
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onExitList: () -> Void
    /// 用于把文档级移动的光标放到目标块首/尾。
    let cursorPlacement: PuraPiMarkdownCursorPlacement?
    let onCursorPlacementConsumed: () -> Void
    /// 上下方向键越过块边界。
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    func makeNSView(context: Context) -> PuraPiBlockTextView {
        let view = PuraPiBlockTextView()
        view.configure(coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PuraPiBlockTextView, context: Context) {
        if context.coordinator.blockID != block.id {
            // LazyVStack 复用宿主前先结束旧块的输入法组合，避免旧候选词
            // 在新块的 owner 已替换后再回调。
            context.coordinator.prepareForBlockReuse()
        }
        context.coordinator.owner = self
        // 先同步身份再写文本：顺序颠倒会让复用瞬间的回调用旧 id 判断，
        // 从而把新内容写回旧块。
        context.coordinator.blockID = block.id
        nsView.update(
            blockID: block.id,
            text: block.displayText,
            style: PuraPiBlockStyle(kind: block.kind),
            isFocused: isFocused,
            cursorPlacement: cursorPlacement,
            selectionRange: selectionRange
        )
    }

    /// 由 SwiftUI 询问高度。
    ///
    /// 必须实现它而不是依赖包装视图的 `intrinsicContentSize`：后者在宽度尚未
    /// 确定时会测出错误高度（长行被当成单行），行框随之错位。这里拿到的
    /// proposal 已带确定宽度，测量才有效。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PuraPiBlockTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 400
        return CGSize(width: width, height: nsView.fittingHeight(forWidth: width))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: PuraPiMarkdownBlockEditor
        /// 视图当前真正承载的块。与 owner.block.id 不一致说明正处于复用切换中。
        var blockID: UUID
        weak var blockTextView: PuraPiBlockTextView?
        var suppressChangeCallbacks = false
        var suppressSelectionCallbacks = false
        private var markedTextNeedsCommit = false
        private var markedTextBlockID: UUID?
        private var markedTextFlushScheduled = false
        private var markedTextGeneration = 0

        var hasPendingMarkedText: Bool {
            markedTextNeedsCommit
        }

        init(owner: PuraPiMarkdownBlockEditor) {
            self.owner = owner
            self.blockID = owner.block.id
        }

        /// 失焦展示文本隐藏了源码标记；用户第一次点击它时先切换到源码展示，
        /// 下一次输入再真正修改，避免把隐藏标记静默写掉。
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            // 组合输入由 NSTextView/输入法自己维护；不能被跨块替换或
            // 多行粘贴分流提前消费，即使失焦更新已经暂时改变了 isEditable。
            if textView.hasMarkedText() || markedTextNeedsCommit { return true }
            guard textView.isEditable else {
                blockTextView?.activateForEditing()
                owner.onFocus()
                return textView.isEditable
            }
            if let replacementString,
               owner.onReplaceSelection(replacementString) {
                return false
            }
            if let replacementString,
               replacementString.contains("\n") || replacementString.contains("\r"),
               owner.onPaste(replacementString, affectedCharRange) {
                return false
            }
            return true
        }

        /// 输入法组合文本不是正式文档内容。只有组合结束后才把最终字符串
        /// 送入块模型；否则 SwiftUI 重绘会覆盖候选词和 marked range。
        func markedTextStateChanged() {
            guard let textView = blockTextView else { return }
            if textView.inlineTextViewHasMarkedText {
                markedTextNeedsCommit = true
                markedTextBlockID = blockID
                return
            }
            scheduleMarkedTextCommit()
        }

        /// 块视图被 LazyVStack 复用时，旧输入法组合不能写入新块。
        func resetMarkedTextTracking() {
            markedTextGeneration &+= 1
            markedTextNeedsCommit = false
            markedTextBlockID = nil
            markedTextFlushScheduled = false
        }

        /// 视图复用前先处理旧块的组合文本，再清理追踪状态。
        func prepareForBlockReuse() {
            guard let textView = blockTextView,
                  markedTextNeedsCommit || textView.inlineTextViewHasMarkedText
            else {
                resetMarkedTextTracking()
                return
            }
            cancelMarkedTextIfNeeded()
        }

        /// 离开块时取消尚未提交的组合文本；不要把原始拼音当成正式内容。
        func cancelMarkedTextIfNeeded() {
            guard let textView = blockTextView,
                  markedTextNeedsCommit || textView.inlineTextViewHasMarkedText
            else { return }
            resetMarkedTextTracking()
            let previousSuppression = suppressChangeCallbacks
            suppressChangeCallbacks = true
            if textView.inlineTextViewHasMarkedText {
                textView.cancelInlineComposition()
            } else {
                textView.restoreInlineCompositionToModel()
            }
            suppressChangeCallbacks = previousSuppression
        }

        private func scheduleMarkedTextCommit() {
            guard markedTextNeedsCommit, !markedTextFlushScheduled else { return }
            markedTextFlushScheduled = true
            let generation = markedTextGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.markedTextGeneration == generation
                else { return }
                self.markedTextFlushScheduled = false
                guard let textView = self.blockTextView,
                      !textView.inlineTextViewHasMarkedText
                else { return }
                // 提交通常仍由本块持有 first responder；如果组合结束是因为
                // 用户切到了别的块，则取消而不是把原始拼音写入文档。
                guard textView.inlineTextViewIsFirstResponder else {
                    self.cancelMarkedTextIfNeeded()
                    return
                }
                self.flushMarkedTextIfNeeded(from: textView)
            }
        }

        private func flushMarkedTextIfNeeded(from textView: PuraPiBlockTextView) {
            guard markedTextNeedsCommit else { return }
            let composingBlockID = markedTextBlockID
            markedTextNeedsCommit = false
            markedTextBlockID = nil
            guard let composingBlockID,
                  composingBlockID == blockID,
                  composingBlockID == owner.block.id,
                  !suppressChangeCallbacks
            else { return }
            // resignFirstResponder 后 isEditable 可能已被 SwiftUI 更新为 false；
            // 块身份和 firstResponder 校验比 isEditable 更能保证提交不会串块。
            publishTextChange(text: textView.inlineText)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  blockID == owner.block.id
            else { return }
            if !suppressChangeCallbacks {
                blockTextView?.cancelPendingCursorPlacement()
            }
            if textView.hasMarkedText() {
                markedTextNeedsCommit = true
                markedTextBlockID = blockID
                return
            }
            guard !suppressChangeCallbacks else { return }
            if markedTextNeedsCommit {
                // 不要在输入法刚结束组合的同一回调里猜测这是“提交”还是
                // “失焦取消”；下一轮检查 first responder 后再决定。
                scheduleMarkedTextCommit()
                return
            }
            guard textView.isEditable else { return }
            publishTextChange(text: textView.string)
        }

        private func publishTextChange(text: String) {
            owner.onChange(text)
            owner.onSyntaxHint(
                PuraPiMarkdownSyntaxHint.message(
                    kind: owner.block.kind,
                    text: text,
                    language: owner.language
                )
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  !textView.hasMarkedText(),
                  !suppressSelectionCallbacks,
                  textView.window?.firstResponder === textView
            else { return }
            if blockTextView?.isExpectedProgrammaticSelection(textView.selectedRange()) == true {
                return
            }
            blockTextView?.cancelPendingCursorPlacement()
            owner.onFocus()
            owner.onSyntaxHint(
                PuraPiMarkdownSyntaxHint.message(
                    kind: owner.block.kind,
                    text: textView.string,
                    language: owner.language
                )
            )
            let sourceRange = blockTextView?.sourceRange(for: textView.selectedRange())
                ?? textView.selectedRange()
            owner.onSelectionChanged(sourceRange)
        }

        func applyInlineFormat(
            _ format: PuraPiMarkdownInlineFormat,
            to textView: NSTextView
        ) {
            guard textView.isEditable,
                  let result = PuraPiMarkdownInlineEditing.apply(
                      format,
                      to: textView.string,
                      selectedRange: textView.selectedRange()
                  )
            else { return }
            if let ownerCoordinator = textView.delegate as? PuraPiMarkdownBlockEditor.Coordinator {
                ownerCoordinator.suppressChangeCallbacks = true
                ownerCoordinator.suppressSelectionCallbacks = true
            }
            textView.replaceCharacters(
                in: NSRange(location: 0, length: textView.string.utf16.count),
                with: result.text
            )
            // replaceCharacters 可能不会为 TextKit 2 的整段替换发出可靠的
            // textDidChange；明确把一次完整源码变更交给文档状态。
            if let blockTextView {
                blockTextView.setSelectedRangeSilently(result.selectedRange)
            } else {
                textView.setSelectedRange(result.selectedRange)
            }
            if let ownerCoordinator = textView.delegate as? PuraPiMarkdownBlockEditor.Coordinator {
                ownerCoordinator.suppressSelectionCallbacks = false
                ownerCoordinator.suppressChangeCallbacks = false
            }
            owner.onChange(result.text)
        }

        /// 拦截需要跨块处理的按键。
        ///
        /// 这些操作单块无法完成，必须上抛给容器：Return 要新建块、块首 Backspace
        /// 要合并、方向键到边界要跨块移动。
        func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            // 组合输入期间 Return/Backspace 等按键属于输入法候选处理，
            // 不应被块拆分或合并逻辑截获。
            if textView.hasMarkedText() || markedTextNeedsCommit { return false }
            // command 路由保持在 NSTextView delegate 内，避免系统字体命令直接改写
            // 属性而绕过 Markdown 源码状态。
            if selector == Selector(("undo:")) {
                owner.onUndo()
                return true
            }
            if selector == Selector(("redo:")) {
                owner.onRedo()
                return true
            }

            let selection = textView.selectedRange()
            let text = textView.string as NSString
            let selectorName = NSStringFromSelector(selector)
            if selectorName == "copy:", owner.onCopySelection() {
                return true
            }
            if selectorName == "selectAll:" {
                owner.onSelectAll()
                return true
            }
            if selectorName == "moveUpAndModifySelection:" {
                return owner.onExtendSelection(-1, selection)
            }
            if selectorName == "moveDownAndModifySelection:" {
                return owner.onExtendSelection(1, selection)
            }
            if selectorName == "moveLeftAndModifySelection:", selection.location == 0 {
                return owner.onExtendSelection(-1, selection)
            }
            if selectorName == "moveRightAndModifySelection:", NSMaxRange(selection) >= text.length {
                return owner.onExtendSelection(1, selection)
            }
            switch selectorName {
            case "bold:", "toggleBold:":
                applyInlineFormat(.strong, to: textView)
                return true
            case "italic:", "toggleItalic:":
                applyInlineFormat(.emphasis, to: textView)
                return true
            case "link:", "insertLink:":
                applyInlineFormat(.link, to: textView)
                return true
            case "performFindPanelAction:":
                owner.onFind()
                return true
            default:
                break
            }
            if selectorName == "moveToBeginningOfDocument:" {
                owner.onMoveToStart()
                return true
            }
            if selectorName == "moveToEndOfDocument:" {
                owner.onMoveToEnd()
                return true
            }

            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // 代码块内 Return 是正常换行，不拆块。
                if case .codeFence = owner.block.kind { return false }
                if case .unorderedListItem = owner.block.kind,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    owner.onExitList()
                    return true
                }
                if case .orderedListItem = owner.block.kind,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    owner.onExitList()
                    return true
                }
                let head = text.substring(to: selection.location)
                let tail = text.substring(from: min(selection.location + selection.length, text.length))
                owner.onSplit(head, tail)
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                if owner.onDeleteSelection() { return true }
                guard selection.location == 0, selection.length == 0 else { return false }
                if owner.onRevertBlockType() { return true }
                owner.onMergeBackward()
                return true

            case #selector(NSResponder.deleteForward(_:)):
                if owner.onDeleteSelection() { return true }
                return false

            case #selector(NSResponder.insertTab(_:)):
                if case .codeFence = owner.block.kind {
                    textView.insertText(
                        "\t",
                        replacementRange: selection
                    )
                    return true
                }
                switch owner.block.kind {
                case .unorderedListItem, .orderedListItem:
                    owner.onIndent()
                    return true
                default:
                    return false
                }

            case #selector(NSResponder.insertBacktab(_:)):
                switch owner.block.kind {
                case .unorderedListItem, .orderedListItem:
                    owner.onOutdent()
                    return true
                default:
                    return false
                }

            case #selector(NSResponder.moveUp(_:)):
                guard isOnFirstLine(textView, location: selection.location) else { return false }
                owner.onMoveUp()
                return true

            case #selector(NSResponder.moveDown(_:)):
                guard isOnLastLine(textView, location: selection.location) else { return false }
                owner.onMoveDown()
                return true

            default:
                return false
            }
        }

        /// 光标是否在首行——只有此时上方向键才应跨块。
        private func isOnFirstLine(_ textView: NSTextView, location: Int) -> Bool {
            let text = textView.string as NSString
            guard text.length > 0 else { return true }
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length - 1), length: 0))
            return lineRange.location == 0
        }

        private func isOnLastLine(_ textView: NSTextView, location: Int) -> Bool {
            let text = textView.string as NSString
            guard text.length > 0 else { return true }
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length - 1), length: 0))
            return NSMaxRange(lineRange) >= text.length
        }
    }
}
