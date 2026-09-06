import AppKit
import PiDomain

/// 块的视觉样式。由块类型决定，用户看到的是渲染后的样子。
struct PuraPiBlockStyle: Equatable {
    let kind: MarkdownBlock.Kind
    let font: NSFont
    let textColor: NSColor
    let leadingInset: CGFloat
    /// 列表项与引用的前导装饰，例如项目符号。
    let decoration: String?
    let decorationColor: NSColor

    init(kind: MarkdownBlock.Kind) {
        self.kind = kind
        switch kind {
        case .heading(let level):
            let sizes: [CGFloat] = [24, 20, 17, 15.5, 14.5, 14]
            font = .systemFont(ofSize: sizes[min(level, 6) - 1], weight: .semibold)
            textColor = .labelColor
            leadingInset = 0
            decoration = nil
            decorationColor = .secondaryLabelColor

        case .unorderedListItem(let indent, _):
            font = .systemFont(ofSize: 14)
            textColor = .labelColor
            leadingInset = CGFloat(indent) * 8 + 18
            decoration = "•"
            decorationColor = .secondaryLabelColor

        case .orderedListItem(let indent, let number, _):
            font = .systemFont(ofSize: 14)
            textColor = .labelColor
            leadingInset = CGFloat(indent) * 8 + 22
            decoration = "\(number)."
            decorationColor = .secondaryLabelColor

        case .quote(let depth):
            font = .systemFont(ofSize: 14)
            textColor = .secondaryLabelColor
            leadingInset = CGFloat(max(1, depth)) * 14
            decoration = nil
            decorationColor = .secondaryLabelColor

        case .codeFence:
            font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            textColor = .labelColor
            leadingInset = 10
            decoration = nil
            decorationColor = .secondaryLabelColor

        case .paragraph, .table, .blank, .thematicBreak:
            font = .systemFont(ofSize: 14)
            textColor = .labelColor
            leadingInset = 0
            decoration = nil
            decorationColor = .secondaryLabelColor
        }
    }
}

/// 承载单块的 NSTextView。
@MainActor
private final class PuraPiInlineTextView: NSTextView {
    var onBecomeFirstResponder: (() -> Void)?
    var onMarkedTextWillResign: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?
    var onFormat: ((PuraPiMarkdownInlineFormat) -> Void)?
    var onCopySelection: (() -> Bool)?
    var onSelectAll: (() -> Void)?
    var onFind: (() -> Void)?
    var onUserMouseDown: (() -> Void)?
    var onMarkedTextStateChanged: (() -> Void)?

    override func resetCursorRects() {
        // 失焦块的 NSTextView 会暂时设为不可编辑；AppKit 因此默认显示箭头，
        // 但整个正文区域仍然是可点击的编辑入口。显式注册 I-beam，避免鼠标
        // 移到其它编辑行时看起来像离开了编辑器。
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        // 展示态先让 NSTextView 按“无标记”的视觉文本计算点击选区，
        // 再成为第一响应者。becomeFirstResponder 中的 reveal 会把这个
        // 可见选区映射回源码；若顺序相反，插入的 `**`/链接标记会改变布局，
        // super.mouseDown 会把光标放到错误位置。
        onUserMouseDown?()
        if !isEditable {
            super.mouseDown(with: event)
            if window?.firstResponder !== self {
                _ = window?.makeFirstResponder(self)
            }
            return
        }
        if window?.firstResponder !== self {
            _ = window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        onMarkedTextStateChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextStateChanged?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onMarkedTextStateChanged?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        if characters == "c", !flags.contains(.shift), onCopySelection?() == true {
            return true
        }
        if characters == "a", !flags.contains(.shift) {
            onSelectAll?()
            return true
        }
        if characters == "f", !flags.contains(.shift) {
            onFind?()
            return true
        }

        let format: PuraPiMarkdownInlineFormat?
        switch (characters, flags.contains(.shift)) {
        case ("b", false): format = .strong
        case ("i", false): format = .emphasis
        case ("k", false): format = .link
        case ("c", true): format = .code
        default: format = nil
        }
        guard let format else { return super.performKeyEquivalent(with: event) }
        onFormat?(format)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { onBecomeFirstResponder?() }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        // 必须在 AppKit resign/unmark 流程开始前处理组合文本；部分输入法
        // 会在 super 返回前把 marked 字符串变成普通文本，届时再恢复已经太晚。
        if hasMarkedText() {
            onMarkedTextWillResign?()
        }
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { onResignFirstResponder?() }
        return resignedFirstResponder
    }
}

@MainActor
final class PuraPiBlockTextView: NSView {
    private let textView = PuraPiInlineTextView()
    private var appliedStyle: PuraPiBlockStyle?
    /// 最近一次传给 NSTextView 的块正文（聚焦时含行内标记，失焦时为展示文本）。
    private var appliedBodyText: String?
    private var appliedPresentation: PuraPiMarkdownInlinePresentation.Result?
    private var appliedParagraphStyle: NSParagraphStyle?
    private var appliedShowsMarkers = false
    private var appliedCursorPlacement: PuraPiMarkdownCursorPlacement?
    private var appliedSelectionRange: NSRange?
    private var appliedBlockID: UUID?
    /// 只在焦点请求从 false → true 时主动抢焦点；用户点击 Composer 或其他
    /// 控件后，后续 SwiftUI 重绘不能再次把焦点强行拉回右侧编辑器。
    private var focusRequestApplied = false
    /// updateNSView 可能早于 view 加入 window；先记住语义焦点，待
    /// viewDidMoveToWindow 后再完成第一响应者切换。
    private var wantsFocus = false
    private var pendingCursorPlacement: PuraPiMarkdownCursorPlacement?
    private var cursorPlacementScheduled = false
    private var focusTaskGeneration = 0
    private var pendingInitialCaret = false
    private var trackingArea: NSTrackingArea?
    private var expectedProgrammaticSelection: NSRange?
    private var selectionExpectationGeneration = 0
    private weak var coordinator: PuraPiMarkdownBlockEditor.Coordinator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setUpTextView() {
        // 不触碰 layoutManager：访问它会让 NSTextView 降级到 TextKit 1。
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        // 撤销历史由 MarkdownDocument 状态统一维护，覆盖跨块结构编辑和保存边界。
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        // 智能替换会把引号换成弯引号、`--` 换成破折号，这会破坏 Markdown 源码。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(coordinator: PuraPiMarkdownBlockEditor.Coordinator) {
        self.coordinator = coordinator
        coordinator.blockTextView = self
        textView.delegate = coordinator
        textView.onBecomeFirstResponder = { [weak self, weak coordinator] in
            // 在 AppKit 把第一响应者交给本块的同一调用栈内恢复源码文本，
            // 避免点击后立刻输入的第一个字符被 SwiftUI 重绘延迟吞掉。
            self?.revealMarkersForEditing()
            coordinator?.owner.onFocus()
        }
        textView.onMarkedTextWillResign = { [weak coordinator] in
            // 在 AppKit 开始 resign 前取消，避免 super 在回调之前提交原始拼音。
            coordinator?.cancelMarkedTextIfNeeded()
        }
        textView.onResignFirstResponder = { [weak coordinator] in
            coordinator?.owner.onBlur()
            coordinator?.markedTextStateChanged()
        }
        textView.onFormat = { [weak self] format in
            guard let self, let coordinator = self.coordinator else { return }
            coordinator.applyInlineFormat(format, to: self.textView)
        }
        textView.onCopySelection = { [weak coordinator] in
            coordinator?.owner.onCopySelection() ?? false
        }
        textView.onSelectAll = { [weak coordinator] in
            coordinator?.owner.onSelectAll()
        }
        textView.onFind = { [weak coordinator] in
            coordinator?.owner.onFind()
        }
        textView.onUserMouseDown = { [weak coordinator] in
            coordinator?.blockTextView?.cancelPendingCursorPlacement()
            coordinator?.owner.onUserInteraction()
        }
        textView.onMarkedTextStateChanged = { [weak coordinator] in
            coordinator?.markedTextStateChanged()
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if textView.window == nil {
            invalidateFocusTasks()
            return
        }
        // SwiftUI 可能在同一轮才把 isFocused 传入；让出一轮主线程，
        // 同时覆盖“先挂入 window、后 updateNSView”和相反的两种时序。
        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusIfNeeded()
        }
    }

    func update(
        blockID: UUID,
        text: String,
        style: PuraPiBlockStyle,
        isFocused: Bool,
        cursorPlacement: PuraPiMarkdownCursorPlacement?,
        selectionRange: NSRange?
    ) {
        // 视图换承载对象时必须无条件重写文本；同一块的普通输入如果已经
        // 由 NSTextView 写入本地内容，则不能因为 SwiftUI 重绘再次重写它，
        // 否则 TextKit 会把用户选区异步归零。
        let switchedBlock = appliedBlockID != blockID
        let previousCursorPlacement = appliedCursorPlacement
        let previousSelectionRange = appliedSelectionRange
        let cursorRequestChanged = previousCursorPlacement != cursorPlacement
        let selectionRangeChanged = previousSelectionRange != selectionRange
        let oldSelection = textView.selectedRange()

        wantsFocus = isFocused
        if switchedBlock || !isFocused {
            focusRequestApplied = false
            invalidateFocusTasks()
        }
        if cursorRequestChanged {
            invalidateFocusTasks()
            pendingCursorPlacement = cursorPlacement
            if cursorPlacement != nil {
                focusRequestApplied = false
            }
        }
        if !isFocused {
            pendingCursorPlacement = nil
        }

        // 中文输入法（IME）的 marked text 是 NSTextView 的临时编辑缓冲，不能
        // 被 SwiftUI 的模型快照或 presentation 重建覆盖。等输入法提交后，
        // Coordinator 会把最终字符串送回状态。
        if !switchedBlock,
           (textView.hasMarkedText() || coordinator?.hasPendingMarkedText == true) {
            return
        }

        let sourceSelection: NSRange
        if let selectionRange {
            sourceSelection = selectionRange
        } else if let cursorPlacement {
            sourceSelection = NSRange(
                location: cursorPlacement == .end ? text.utf16.count : 0,
                length: 0
            )
        } else if switchedBlock {
            sourceSelection = NSRange(location: 0, length: 0)
        } else if appliedShowsMarkers {
            sourceSelection = oldSelection
        } else if let appliedPresentation {
            sourceSelection = appliedPresentation.sourceRange(for: oldSelection)
        } else {
            sourceSelection = oldSelection
        }

        appliedBlockID = blockID

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.headIndent = style.leadingInset
        paragraph.firstLineHeadIndent = style.leadingInset
        let styleChanged = appliedStyle != style
        if styleChanged {
            appliedStyle = style
            textView.font = style.font
            textView.textColor = style.textColor
            textView.defaultParagraphStyle = paragraph
        }

        let isCodeBlock: Bool = {
            if case .codeFence = style.kind { return true }
            return false
        }()
        let presentation = PuraPiMarkdownInlinePresentation.render(
            source: text,
            baseFont: style.font,
            baseColor: style.textColor,
            paragraphStyle: paragraph,
            showsMarkers: isFocused,
            allowsFormatting: !isCodeBlock
        )
        let contentMatches = textView.string == presentation.attributedString.string
        let attributedMatches = textView.attributedString().isEqual(to: presentation.attributedString)
        let needsPresentationUpdate = switchedBlock
            || !contentMatches
            || !attributedMatches
            || appliedShowsMarkers != isFocused
            || styleChanged

        if needsPresentationUpdate {
            withSuppressedCallbacks {
                textView.isEditable = isFocused
                textView.textStorage?.setAttributedString(presentation.attributedString)
                if textView.textStorage == nil {
                    textView.string = presentation.attributedString.string
                }
            }
        } else {
            textView.isEditable = isFocused
        }
        textView.window?.invalidateCursorRects(for: textView)

        appliedBodyText = text
        appliedPresentation = presentation
        appliedParagraphStyle = paragraph
        appliedShowsMarkers = isFocused
        appliedCursorPlacement = cursorPlacement
        appliedSelectionRange = selectionRange

        // 只有外部明确给出新选区/光标请求，或 presentation 真的发生变化时，
        // 才写回 NSTextView 选区。普通删除后的 nil selection 不应覆盖原生 caret。
        let shouldApplySelection = needsPresentationUpdate
            || (selectionRange != nil && selectionRangeChanged)
            || (cursorPlacement != nil && cursorRequestChanged)
        if shouldApplySelection {
            let targetSelection: NSRange
            if let selectionRange {
                targetSelection = presentation.visibleRange(for: selectionRange)
            } else {
                targetSelection = isFocused
                    ? presentation.sourceRange(for: sourceSelection)
                    : presentation.visibleRange(for: sourceSelection)
            }
            setSelectedRangeSilently(clamped(targetSelection, to: presentation.attributedString.length))
        }

        attemptFocusIfNeeded()
    }

    /// 在 view 尚未挂入 window 时，`updateNSView` 无法设置 first responder；
    /// 这里统一处理挂入后的补偿，以及跨块导航产生的显式光标请求。
    private func attemptFocusIfNeeded() {
        guard wantsFocus, let window = textView.window else { return }

        let explicitPlacement = pendingCursorPlacement
        let alreadyFirstResponder = window.firstResponder === textView
        if !alreadyFirstResponder,
           explicitPlacement == nil,
           !shouldClaimInitialFocus(in: window) {
            // Composer 等其它可编辑控件已经拥有用户焦点；这是用户选择，
            // 不能在后续 SwiftUI 重绘中被 Inspector 抢回。
            focusRequestApplied = true
            return
        }

        var didMakeFirstResponder = false
        if !alreadyFirstResponder {
            // 先占位再调用 AppKit：makeFirstResponder 会同步触发 onFocus，
            // 进而可能重入 SwiftUI update；没有这个标记，重入路径会重复抢焦点。
            focusRequestApplied = true
            guard window.makeFirstResponder(textView) else {
                focusRequestApplied = false
                return
            }
            didMakeFirstResponder = true
        }
        guard window.firstResponder === textView else { return }

        focusRequestApplied = true
        if let explicitPlacement, !cursorPlacementScheduled {
            cursorPlacementScheduled = true
            scheduleCursorPlacement(explicitPlacement)
        } else if didMakeFirstResponder {
            scheduleInitialCaret()
        }
    }

    private func scheduleInitialCaret() {
        let generation = focusTaskGeneration
        let selectionAtSchedule = textView.selectedRange()
        pendingInitialCaret = true
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.focusTaskGeneration == generation,
                  self.pendingInitialCaret,
                  self.textView.window?.firstResponder === self.textView,
                  !self.textView.hasMarkedText()
            else { return }
            self.pendingInitialCaret = false
            // 用户若在等待期间已经点选/输入，不再覆盖他的选择。
            let current = self.textView.selectedRange()
            guard current == selectionAtSchedule
                    || current.length == self.textView.string.utf16.count
            else { return }
            self.setSelectedRangeSilently(NSRange(location: 0, length: 0))
            self.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    private func scheduleCursorPlacement(_ placement: PuraPiMarkdownCursorPlacement) {
        let generation = focusTaskGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.focusTaskGeneration == generation,
                  self.pendingCursorPlacement == placement
            else { return }
            guard self.textView.window?.firstResponder === self.textView,
                  !self.textView.hasMarkedText()
            else {
                // 保留 pending 请求；下一次焦点/布局更新或输入法结束后再尝试，
                // 不能因为一个异步 tick 恰好撞上切焦点就永久丢失定位。
                self.cursorPlacementScheduled = false
                return
            }
            let location = placement == .end ? self.textView.string.utf16.count : 0
            self.setSelectedRangeSilently(NSRange(location: location, length: 0))
            self.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            self.pendingCursorPlacement = nil
            self.cursorPlacementScheduled = false
            self.coordinator?.owner.onCursorPlacementConsumed()
        }
    }

    func cancelPendingCursorPlacement() {
        let hadPendingFocusWork = pendingCursorPlacement != nil || pendingInitialCaret
        pendingCursorPlacement = nil
        expectedProgrammaticSelection = nil
        selectionExpectationGeneration &+= 1
        guard hadPendingFocusWork else { return }
        invalidateFocusTasks()
    }

    private func invalidateFocusTasks() {
        focusTaskGeneration &+= 1
        pendingInitialCaret = false
        cursorPlacementScheduled = false
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), max(0, length - location))
        )
    }

    func isExpectedProgrammaticSelection(_ range: NSRange) -> Bool {
        expectedProgrammaticSelection == range
    }

    func setSelectedRangeSilently(_ range: NSRange) {
        expectedProgrammaticSelection = range
        selectionExpectationGeneration &+= 1
        let generation = selectionExpectationGeneration
        let previous = coordinator?.suppressSelectionCallbacks ?? false
        coordinator?.suppressSelectionCallbacks = true
        textView.setSelectedRange(range)
        coordinator?.suppressSelectionCallbacks = previous
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.selectionExpectationGeneration == generation
            else { return }
            self.expectedProgrammaticSelection = nil
        }
    }

    private func withSuppressedCallbacks(_ action: () -> Void) {
        let previousChanges = coordinator?.suppressChangeCallbacks ?? false
        let previousSelection = coordinator?.suppressSelectionCallbacks ?? false
        coordinator?.suppressChangeCallbacks = true
        coordinator?.suppressSelectionCallbacks = true
        action()
        coordinator?.suppressSelectionCallbacks = previousSelection
        coordinator?.suppressChangeCallbacks = previousChanges
    }

    /// 取消失焦时仍未提交的输入法组合，并恢复到最近一次模型快照。
    /// 组合阶段不能把临时拼音写入 Markdown；用户再次点击本块即可重新输入。
    func cancelInlineComposition() {
        guard textView.hasMarkedText() else { return }
        let markedRange = textView.markedRange()
        let fallbackLocation = textView.selectedRange().location
        let sourceLocation = markedRange.location == NSNotFound
            ? fallbackLocation
            : markedRange.location
        textView.unmarkText()
        restoreInlineCompositionToModel(at: sourceLocation)
    }

    /// 在 AppKit 事件先于 SwiftUI 焦点更新到达时，同步打开编辑状态，
    /// 避免首个字符被 `shouldChangeTextIn` 丢掉。
    func activateForEditing() {
        textView.isEditable = true
        revealMarkersForEditing()
        textView.window?.invalidateCursorRects(for: textView)
    }

    /// 输入法可能在 AppKit 的 resign 流程中先清除 marked 状态，再发出
    /// `textDidChange`；此时仍要能把临时字符串恢复为模型内容。
    func restoreInlineCompositionToModel(at location: Int? = nil) {
        guard let bodyText = appliedBodyText,
              let style = appliedStyle
        else { return }

        let paragraph = appliedParagraphStyle ?? NSParagraphStyle.default
        let presentation = PuraPiMarkdownInlinePresentation.render(
            source: bodyText,
            baseFont: style.font,
            baseColor: style.textColor,
            paragraphStyle: paragraph,
            showsMarkers: appliedShowsMarkers,
            allowsFormatting: !isCodeBlock(style.kind)
        )
        withSuppressedCallbacks {
            textView.textStorage?.setAttributedString(presentation.attributedString)
            if textView.textStorage == nil {
                textView.string = presentation.attributedString.string
            }
        }
        let fallbackLocation = textView.selectedRange().location
        let sourceLocation = location ?? fallbackLocation
        let target = appliedShowsMarkers
            ? presentation.sourceRange(for: NSRange(location: sourceLocation, length: 0))
            : presentation.visibleRange(for: NSRange(location: sourceLocation, length: 0))
        setSelectedRangeSilently(clamped(target, to: presentation.attributedString.length))
        appliedPresentation = presentation
        appliedBodyText = bodyText
        textView.window?.invalidateCursorRects(for: textView)
    }

    /// AppKit 成为第一响应者时，SwiftUI 还来不及把 `isFocused` 传回本视图。
    /// 这里同步切换到源码展示，保证点击后紧接着输入不会修改已经隐藏标记的文本。
    private func revealMarkersForEditing() {
        guard !appliedShowsMarkers,
              let bodyText = appliedBodyText,
              let style = appliedStyle
        else { return }

        let sourceSelection = appliedPresentation?.sourceRange(for: textView.selectedRange())
            ?? textView.selectedRange()
        let paragraph = appliedParagraphStyle ?? NSParagraphStyle.default
        let presentation = PuraPiMarkdownInlinePresentation.render(
            source: bodyText,
            baseFont: style.font,
            baseColor: style.textColor,
            paragraphStyle: paragraph,
            showsMarkers: true,
            allowsFormatting: !isCodeBlock(style.kind)
        )

        textView.isEditable = true
        withSuppressedCallbacks {
            textView.textStorage?.setAttributedString(presentation.attributedString)
            if textView.textStorage == nil {
                textView.string = presentation.attributedString.string
            }
        }
        textView.window?.invalidateCursorRects(for: textView)
        let location = min(sourceSelection.location, presentation.attributedString.length)
        let selection = NSRange(
            location: location,
            length: min(
                sourceSelection.length,
                max(0, presentation.attributedString.length - location)
            )
        )
        setSelectedRangeSilently(selection)
        appliedPresentation = presentation
        appliedShowsMarkers = true
    }

    private func isCodeBlock(_ kind: MarkdownBlock.Kind) -> Bool {
        if case .codeFence = kind { return true }
        return false
    }

    /// 只有窗口没有明确的用户输入目标时，编辑器才可以请求初始焦点。
    ///
    /// `focusedBlockID` 是编辑器内部的语义状态，不等于“窗口当前应该接收键盘
    /// 输入”。如果 Composer 或其他 NSTextView 已经是 first responder，重新创建
    /// 一个 Markdown block view 也不能把焦点抢回 Inspector。
    private func shouldClaimInitialFocus(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return true }
        if responder === textView { return true }
        if let view = responder as? NSView, view.isDescendant(of: self) { return true }
        if responder is NSTextView || responder is NSTextField || responder is NSControl {
            return false
        }
        return true
    }

    var inlineTextViewHasMarkedText: Bool {
        textView.hasMarkedText()
    }

    var inlineTextViewIsFirstResponder: Bool {
        textView.window?.firstResponder === textView
    }

    var inlineText: String {
        textView.string
    }

    func sourceRange(for visibleRange: NSRange) -> NSRange {
        guard !appliedShowsMarkers,
              let appliedPresentation
        else { return visibleRange }
        return appliedPresentation.sourceRange(for: visibleRange)
    }

    /// 在给定宽度下测量所需高度。
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer,
              let layoutManager = textView.textLayoutManager
        else { return 20 }
        // 先固定换行宽度，再测量；否则长行会被当成单行内容。
        container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let used = layoutManager.usageBoundsForTextContainer
        return max(20, ceil(used.height) + 6)
    }
}
