import AppKit
import PiDomain
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// 块状 Markdown 编辑器。
///
/// 容器负责块序列、跨块导航与源码组合；单块的文本编辑由
/// `PuraPiMarkdownBlockEditor` 承担。所有变更都表达为 `MarkdownBlockEdit`
/// 交给 `PuraPiMarkdownEditorState`，不直接写文件。
enum PuraPiMarkdownDrag {
    static let type = UTType(exportedAs: "com.purapi.markdown-block")
    /// 接受旧版应用/辅助工具发出的 block drag，新的拖出统一使用 PuraPi UTI。
    static let legacyType = UTType(exportedAs: PuraPiLegacyIdentifiers.markdownBlockUTI)
    static let acceptedTypes = [type, legacyType]

    static func blockID(from data: Data) -> UUID? {
        UUID(uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
struct PuraPiMarkdownEditorView: View {
    @Environment(\.puraPiTheme) private var theme
    @ObservedObject var state: PuraPiMarkdownEditorState
    let language: PuraPiInterfaceLanguage
    /// Inspector 标题作为滚动区的固定顶部安全区；普通编辑器为 nil。
    var inspectorTopInset: AnyView? = nil
    /// 空文件没有持久化块；临时首行的身份由共享 editor state 持有，
    /// 用户输入后才通过 `.insert` 写入真实文档。
    @State private var draggingBlockID: UUID?
    @State private var isBlockDropTargeted = false
    @State private var syntaxHint: String?
    @StateObject private var findReplace = PuraPiMarkdownFindReplaceState()
    var findReplaceState: PuraPiMarkdownFindReplaceState { findReplace }
    private var isEnglish: Bool { language == .english }

    var body: some View {
        blockList
            // 编辑器必须占满右栏并顶部对齐；否则父容器会按内容高度收缩，
            // 短文档看起来悬在半空。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onReceive(NotificationCenter.default.publisher(for: .puraPiSaveDocument)) { _ in
                Task { _ = await state.save() }
            }
            .onReceive(state.$document) { _ in
                findReplaceState.update(blocks: state.blocks)
            }
            .onChange(of: findReplaceState.query) { _, _ in
                findReplaceState.update(blocks: state.blocks)
            }
            .onChange(of: isBlockDropTargeted) { _, targeted in
                // SwiftUI does not call the drop closure when a drag is
                // cancelled (Escape or leaving the window).  The target edge
                // is the reliable cancellation signal; clear only our custom
                // block drag state, never ordinary text/image drops.
                if !targeted { draggingBlockID = nil }
            }
    }

    private var blockList: some View {
        ScrollViewReader { proxy in
            ScrollView {
            PuraPiScrollViewConfiguration(
                managesTitlebarContentInsets: false,
                edgeToEdgeContent: true
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            PuraPiLegacyScrollEdgeEffectMarker()

            LazyVStack(alignment: .leading, spacing: 0) {
                if needsEmptyEditableRow {
                    emptyDocumentRow
                } else {
                    ForEach(state.blocks) { block in
                        blockRow(block)
                            .onDrag {
                                guard block.acceptsCursor else { return NSItemProvider() }
                                draggingBlockID = block.id
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(
                                    forTypeIdentifier: PuraPiMarkdownDrag.type.identifier,
                                    visibility: .all
                                ) { completion in
                                    completion(Data(block.id.uuidString.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            .onDrop(
                                of: PuraPiMarkdownDrag.acceptedTypes,
                                isTargeted: $isBlockDropTargeted
                            ) { providers, _ in
                                guard block.acceptsCursor else { return false }
                                let targetID = block.id

                                if let draggingBlockID {
                                    self.draggingBlockID = nil
                                    guard draggingBlockID != targetID else { return false }
                                    state.moveBlock(id: draggingBlockID, before: targetID)
                                    return true
                                }

                                guard let provider = providers.first,
                                      let type = PuraPiMarkdownDrag.acceptedTypes.first(where: {
                                          provider.hasItemConformingToTypeIdentifier($0.identifier)
                                      })
                                else { return false }

                                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                                    guard let data,
                                          let sourceID = PuraPiMarkdownDrag.blockID(from: data),
                                          sourceID != targetID
                                    else { return }
                                    Task { @MainActor in
                                        state.moveBlock(id: sourceID, before: targetID)
                                    }
                                }
                                return true
                            }
                            // 必须绑定块 id：LazyVStack 会按位置复用视图，
                            // 复用时上一个块的残留文本会被写回成新块内容，
                            // 实测把文件写坏（多出空列表项与空代码块）。
                            .id(block.id)
                    }
                }
            }
            .padding(.horizontal, 18)
            // 固定标题已经占据 safeAreaInset；正文只保留 6pt 呼吸间距，
            // 避免标题下出现第二个明显的空白带。普通无标题编辑器仍保持 14pt。
            .padding(.top, contentTopPadding)
            .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let inspectorTopInset {
                    inspectorTopInset
                }
                if findReplaceState.isPresented {
                    PuraPiMarkdownFindReplaceBar(
                        state: findReplaceState,
                        language: language,
                        onReplaceCurrent: replaceCurrentMatch,
                        onReplaceAll: replaceAllMatches,
                        onNavigate: { blockID in
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(blockID, anchor: .center)
                            }
                        }
                    )
                    .padding(.vertical, 5)
                }
                if let conflict = state.conflict {
                    PuraPiMarkdownConflictBar(
                        conflict: conflict,
                        localText: state.serializedLocalText,
                        language: language,
                        onReload: {
                            Task { await state.resolveConflictByReloadingAsync() }
                        },
                        onOverwrite: {
                            Task { await state.resolveConflictByOverwritingAsync() }
                        },
                        onDismiss: state.dismissConflict
                    )
                }
                if hasTopInsetControls,
                   (findReplaceState.isPresented || state.conflict != nil),
                   !outlineItems.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        outlineMenu(proxy: proxy)
                            .padding(.trailing, 10)
                    }
                    .frame(height: 30)
                }
            }
        }
            .overlay(alignment: .topTrailing) {
                // Inspector 只有固定标题时，把大纲按钮放在标题下方但不额外
                // 撑高正文；查找/冲突条出现时，按钮改由上面的安全区独立行承载。
                if !findReplaceState.isPresented,
                   state.conflict == nil,
                   !outlineItems.isEmpty {
                    outlineMenu(proxy: proxy)
                        .padding(.top, outlineMenuTopPadding)
                        .padding(.trailing, 10)
                }
            }
            .puraPiTopOnlyScrollEdgeEffect()
            .onDrop(of: [.fileURL], isTargeted: nil) { providers, _ in
                acceptImageDrop(providers)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let syntaxHint, !syntaxHint.isEmpty {
                    Text(syntaxHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.thinMaterial)
                }
            }
        }
    }

    private var outlineItems: [PuraPiMarkdownOutlineItem] {
        PuraPiMarkdownOutline.items(from: state.blocks)
    }

    private var hasTopInsetControls: Bool {
        inspectorTopInset != nil
            || findReplaceState.isPresented
            || state.conflict != nil
    }

    private var outlineMenuTopPadding: CGFloat {
        inspectorTopInset == nil
            ? 6
            : PuraPiInspectorHeaderMetrics.totalHeight + 6
    }

    @ViewBuilder
    private func outlineMenu(proxy: ScrollViewProxy) -> some View {
        Menu {
            ForEach(outlineItems) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(item.id, anchor: .top)
                    }
                } label: {
                    HStack {
                        Text(item.title)
                        Spacer()
                        Text("H\(item.level)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 24)
        }
        .menuStyle(.borderlessButton)
        .help(isEnglish ? "Document outline" : "文档大纲")
        .accessibilityLabel(isEnglish ? "Document outline" : "文档大纲")
    }

    private var needsEmptyEditableRow: Bool {
        state.blocks.isEmpty || !state.blocks.contains(where: { $0.acceptsCursor })
    }

    /// 在文档没有可编辑块时立即把语义焦点交给临时首行，避免等待 SwiftUI
    /// 的 `onAppear` 造成删除后的输入窗口。
    func focusEmptyDocumentPlaceholder() {
        state.clearCursorRequest()
        state.focusedBlockID = state.emptyDocumentPlaceholderID
    }

    private var emptyDocumentBlock: MarkdownBlock {
        MarkdownBlock(
            id: state.emptyDocumentPlaceholderID,
            kind: .paragraph,
            source: "",
            lineRange: 0..<1
        )
    }

    @ViewBuilder
    private var emptyDocumentRow: some View {
        PuraPiMarkdownBlockEditor(
            block: emptyDocumentBlock,
            // onAppear 会设置初始焦点；这里不要直接用 needsEmptyEditableRow，
            // 否则用户点击冲突条或其他控件后，下一次布局会反复抢回焦点。
            isFocused: state.focusedBlockID == state.emptyDocumentPlaceholderID,
            language: language,
            onChange: handleEmptyDocumentChange,
            onPaste: { _, _ in false },
            onReplaceSelection: { _ in false },
            onDeleteSelection: { false },
            selectionRange: nil,
            onSelectionChanged: { _ in },
            onExtendSelection: { _, _ in false },
            onCopySelection: { false },
            onSelectAll: {},
            onFind: showFindReplace,
            onSyntaxHint: { syntaxHint = $0 },
            onSplit: handleEmptyDocumentSplit,
            onMergeBackward: {},
            onRevertBlockType: { false },
            onFocus: {
                state.focusedBlockID = state.emptyDocumentPlaceholderID
            },
            onUserInteraction: {
                if state.cursorRequest != nil {
                    state.clearCursorRequest()
                }
            },
            onBlur: {
                // 输入第一个字符后 placeholder 会被同一个 id 的真实块替换；
                // 旧视图随后失焦时不能把新块刚建立的语义焦点清掉。
                let placeholderWasReplaced = state.blocks.contains {
                    $0.id == state.emptyDocumentPlaceholderID
                }
                if state.focusedBlockID == state.emptyDocumentPlaceholderID,
                   !placeholderWasReplaced {
                    state.focusedBlockID = nil
                }
            },
            onUndo: state.undo,
            onRedo: state.redo,
            onMoveToStart: {},
            onMoveToEnd: {},
            onIndent: {},
            onOutdent: {},
            onExitList: {},
            cursorPlacement: nil,
            onCursorPlacementConsumed: {},
            onMoveUp: {},
            onMoveDown: {}
        )
        .padding(.bottom, spacing(for: .paragraph))
        .onAppear {
            if needsEmptyEditableRow, state.focusedBlockID == nil {
                focusEmptyDocumentPlaceholder()
            }
        }
    }

    private func handleEmptyDocumentChange(_ displayText: String) {
        guard needsEmptyEditableRow, !displayText.isEmpty else { return }
        let placeholder = emptyDocumentBlock
        let insertion = PuraPiMarkdownBlockConverter.slashInsertion(displayText)
        let converted = insertion == nil
            ? PuraPiMarkdownBlockConverter.convert(
                block: placeholder,
                displayText: displayText
            )
            : nil
        let kind = insertion?.kind ?? converted?.kind ?? .paragraph
        let source = insertion?.source
            ?? converted?.source
            ?? PuraPiMarkdownBlockConverter.composeSource(
                kind: kind,
                displayText: displayText
            )
        let block = MarkdownBlock(
            id: state.emptyDocumentPlaceholderID,
            kind: kind,
            source: source,
            lineRange: 0..<1
        )
        state.apply(.insert(block: block, after: state.blocks.last?.id))
        // placeholder 行会切换成真实块并重建 NSTextView；显式请求行尾，
        // 否则新视图默认把光标放在 0，下一字会插到首字符之前。
        state.requestCursorPlacement(for: state.emptyDocumentPlaceholderID, at: .end)
    }

    private func handleEmptyDocumentSplit(_ head: String, _ tail: String) {
        guard needsEmptyEditableRow else { return }
        state.withUndoGroup {
            let first = MarkdownBlock(
                id: state.emptyDocumentPlaceholderID,
                kind: .paragraph,
                source: head,
                lineRange: 0..<1
            )
            let second = MarkdownBlock(
                kind: .paragraph,
                source: tail,
                lineRange: 1..<2
            )
            let anchor = state.blocks.last?.id
            state.apply(.insert(block: first, after: anchor))
            state.apply(.insert(block: second, after: first.id))
            let blank = MarkdownBlock(
                kind: .blank,
                source: "",
                lineRange: 1..<2
            )
            state.apply(.insert(block: blank, after: first.id))
            state.requestCursorPlacement(for: second.id, at: .beginning)
        }
    }

    @ViewBuilder
    private func blockRow(_ block: MarkdownBlock) -> some View {
        if shouldCollapseLeadingPlaceholder(block) {
            // 只压缩视觉高度，不从 state.blocks 删除源码块；这样空标题/空行仍可
            // 被序列化回原文件，也不会破坏块级编辑的行范围。
            // LazyVStack 对完全零高度的首批子项可能无法继续估算后续 NSView
            // 宿主的可见范围，因此保留 1pt 的不可见占位。
            Color.clear.frame(height: 1)
        } else {
            switch block.kind {
            case .blank:
                // 非前导空行仍保留节奏；前导空行由上面的视觉规则压缩。
                Color.clear.frame(height: 10)

            case .thematicBreak:
                Divider()
                    .padding(.vertical, 8)

            case .table:
                tableEditorRow(block)

            default:
                editableBlockRow(block)
            }
        }
    }

    @ViewBuilder
    private func tableEditorRow(_ block: MarkdownBlock) -> some View {
        PuraPiMarkdownTableEditor(
            block: block,
            language: language,
            onChange: { source in
                handleTableChange(block: block, source: source)
            },
            onFocus: {
                state.clearSelection()
                if state.focusedBlockID != block.id {
                    state.focusedBlockID = block.id
                }
            },
            onBlur: {
                let currentBlock = state.blocks.first {
                    $0.id == block.id
                }
                if state.focusedBlockID == block.id,
                   (currentBlock == nil || currentBlock?.kind == block.kind) {
                    state.focusedBlockID = nil
                }
            },
            onUndo: state.undo,
            onRedo: state.redo
        )
        .padding(.bottom, spacing(for: block.kind))
    }

    private func handleTableChange(block: MarkdownBlock, source: String) {
        guard source != block.source else { return }
        state.apply(.update(id: block.id, source: source))
        state.focusedBlockID = block.id
    }

    @ViewBuilder
    private func editableBlockRow(_ block: MarkdownBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .codeFence(let codeLanguage, _) = block.kind {
                codeLanguageField(
                    block: block,
                    languageText: codeLanguage ?? ""
                )
            }
            PuraPiMarkdownBlockEditor(
                block: block,
                isFocused: state.focusedBlockID == block.id,
                language: language,
                onChange: { text in
                    handleChange(block: block, displayText: text)
                },
                onPaste: { pastedText, affectedRange in
                    handlePaste(
                        block: block,
                        pastedText: pastedText,
                        affectedRange: affectedRange
                    )
                },
                onReplaceSelection: { replacement in
                    replaceDocumentSelection(with: replacement)
                },
                onDeleteSelection: {
                    replaceDocumentSelection(with: "")
                },
                selectionRange: state.selectionRange(for: block.id),
                onSelectionChanged: { range in
                    state.setLocalSelection(blockID: block.id, range: range)
                },
                onExtendSelection: { direction, range in
                    extendSelection(from: block, direction: direction, range: range)
                },
                onCopySelection: copyMarkdownSelection,
                onSelectAll: selectAllMarkdown,
                onFind: showFindReplace,
                onSyntaxHint: { syntaxHint = $0 },
                onSplit: { head, tail in
                    handleSplit(block: block, head: head, tail: tail)
                },
                onMergeBackward: {
                    handleMergeBackward(block: block)
                },
                onRevertBlockType: {
                    revertBlockType(block: block)
                },
                onFocus: {
                    if state.focusedBlockID != block.id {
                        // 点击另一个块开始新的编辑时，旧的跨块选区不能继续
                        // 参与替换；键盘跨块导航若仍在同一语义焦点则保留它。
                        state.clearSelection()
                        state.focusedBlockID = block.id
                    }
                },
                onUserInteraction: {
                    if state.cursorRequest != nil {
                        state.clearCursorRequest()
                    }
                },
                onBlur: {
                    // 块类型转换（例如 `/table`）会替换当前 NSTextView；
                    // 旧视图失焦时不能把新宿主刚建立的同一块焦点清掉。
                    let currentBlock = state.blocks.first {
                        $0.id == block.id
                    }
                    if state.focusedBlockID == block.id,
                       (currentBlock == nil || currentBlock?.kind == block.kind) {
                        state.focusedBlockID = nil
                    }
                    syntaxHint = nil
                },
                onUndo: state.undo,
                onRedo: state.redo,
                onMoveToStart: moveToDocumentStart,
                onMoveToEnd: moveToDocumentEnd,
                onIndent: { indentList(block: block, delta: 2) },
                onOutdent: { indentList(block: block, delta: -2) },
                onExitList: { exitList(block: block) },
                cursorPlacement: cursorPlacement(for: block.id),
                onCursorPlacementConsumed: {
                    state.consumeCursorRequest(for: block.id)
                },
                onMoveUp: { moveFocus(from: block, offset: -1) },
                onMoveDown: { moveFocus(from: block, offset: 1) }
            )
            if let reference = PuraPiMarkdownImageReference.parse(block.source),
               let root = state.workspaceRootURL,
               let imageURL = reference.resolvedURL(workspaceRoot: root) {
                PuraPiMarkdownEmbeddedImageView(
                    url: imageURL,
                    workspaceRoot: root,
                    altText: reference.altText
                )
                .padding(.leading, 10)
            }
        }
        .padding(.bottom, spacing(for: block.kind))
        .background(
            // 代码块给出可辨识的底，否则用户看不出边界。
            codeBackground(for: block.kind)
        )
    }

    private func codeLanguageField(
        block: MarkdownBlock,
        languageText: String
    ) -> some View {
        TextField(
            isEnglish ? "Language (optional)" : "语言（可选）",
            text: Binding(
                get: { languageText },
                set: { updateCodeLanguage(block: block, language: $0) }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .onTapGesture {
            state.clearSelection()
            state.focusedBlockID = block.id
        }
        .accessibilityLabel(isEnglish ? "Code block language" : "代码块语言")
    }

    private func updateCodeLanguage(block: MarkdownBlock, language: String) {
        guard case .codeFence(_, let fence) = block.kind else { return }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        let kind = MarkdownBlock.Kind.codeFence(
            language: normalized.isEmpty ? nil : normalized,
            fence: fence
        )
        guard kind != block.kind else { return }
        let source = PuraPiMarkdownBlockConverter.composeSource(
            kind: kind,
            displayText: block.displayText
        )
        state.apply(.retype(id: block.id, kind: kind, source: source))
        state.focusedBlockID = block.id
    }

    private var contentTopPadding: CGFloat {
        guard inspectorTopInset != nil else { return 14 }
        // macOS 26 的固定标题已经占据完整安全区；legacy 保持原有正文留白。
        if #available(macOS 26.0, *) { return 6 }
        return 14
    }

    private var leadingPlaceholderIDs: Set<UUID> {
        guard #available(macOS 26.0, *) else { return [] }
        var ids = Set<UUID>()
        for block in state.blocks {
            let isPlaceholder: Bool
            switch block.kind {
            case .blank:
                isPlaceholder = true
            case .heading:
                isPlaceholder = block.displayText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            default:
                isPlaceholder = false
            }
            guard isPlaceholder else { break }
            ids.insert(block.id)
        }
        return ids
    }

    private func shouldCollapseLeadingPlaceholder(_ block: MarkdownBlock) -> Bool {
        guard leadingPlaceholderIDs.contains(block.id) else { return false }
        // 空标题被键盘导航聚焦时恢复为可编辑行；空行本身不可聚焦。
        if case .heading = block.kind, state.focusedBlockID == block.id {
            return false
        }
        return true
    }

    @ViewBuilder
    private func codeBackground(for kind: MarkdownBlock.Kind) -> some View {
        if case .codeFence = kind {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        } else if case .quote = kind {
            // 引用用左侧竖线表达，与 Markdown 的语义对应。
            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.accent.opacity(0.45))
                    .frame(width: 2.5)
                Spacer(minLength: 0)
            }
        } else {
            Color.clear
        }
    }

    private func spacing(for kind: MarkdownBlock.Kind) -> CGFloat {
        switch kind {
        case .heading: return 6
        case .unorderedListItem, .orderedListItem: return 2
        case .codeFence: return 8
        default: return 4
        }
    }
}
