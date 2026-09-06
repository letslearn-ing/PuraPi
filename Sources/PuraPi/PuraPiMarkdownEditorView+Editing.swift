import AppKit
import PiDomain
import UniformTypeIdentifiers
import WorkspaceKit

extension PuraPiMarkdownEditorView {
    // MARK: - 编辑处理

    /// 块内文本变化：把显示文本组合回源码。
    ///
    /// 显示文本不含块级标记（`## `、`- ` 等），写回时必须补上，否则保存后
    /// 标题会退化成普通段落。
    func handleChange(block: MarkdownBlock, displayText: String) {
        // 只有整段内容就是命令时才执行块插入，普通正文中的 `/` 保持原样。
        if block.kind == .paragraph,
           let insertion = PuraPiMarkdownBlockConverter.slashInsertion(displayText) {
            state.apply(.retype(
                id: block.id,
                kind: insertion.kind,
                source: insertion.source
            ))
            state.focusedBlockID = block.id
            return
        }
        // 行首标记可能触发块类型转换，例如在段落开头输入 "## "
        if let converted = PuraPiMarkdownBlockConverter.convert(
            block: block,
            displayText: displayText
        ) {
            state.apply(.retype(id: block.id, kind: converted.kind, source: converted.source))
            return
        }
        let source = PuraPiMarkdownBlockConverter.composeSource(
            kind: block.kind,
            displayText: displayText
        )
        guard source != block.source else { return }
        state.apply(.update(id: block.id, source: source))
    }

    func showFindReplace() {
        findReplaceState.present(blocks: state.blocks)
    }

    func replaceCurrentMatch() {
        guard let match = findReplaceState.currentMatch,
              let block = state.blocks.first(where: { $0.id == match.blockID })
        else { return }
        let body = block.displayText as NSString
        guard NSMaxRange(match.range) <= body.length else {
            findReplaceState.update(blocks: state.blocks)
            return
        }
        let mutable = body.mutableCopy() as! NSMutableString
        mutable.replaceCharacters(in: match.range, with: findReplaceState.replacement)
        let source = PuraPiMarkdownBlockConverter.composeSource(
            kind: block.kind,
            displayText: String(mutable)
        )
        state.apply(.update(id: block.id, source: source))
        findReplaceState.update(blocks: state.blocks)
    }

    func replaceAllMatches() {
        let matchesByBlock = Dictionary(grouping: findReplaceState.matches, by: \.blockID)
        guard !matchesByBlock.isEmpty else { return }
        state.withUndoGroup {
            for block in state.blocks {
                guard let matches = matchesByBlock[block.id], !matches.isEmpty else { continue }
                let body = block.displayText as NSString
                let mutable = body.mutableCopy() as! NSMutableString
                for match in matches.sorted(by: { $0.range.location > $1.range.location })
                where NSMaxRange(match.range) <= mutable.length {
                    mutable.replaceCharacters(in: match.range, with: findReplaceState.replacement)
                }
                let source = PuraPiMarkdownBlockConverter.composeSource(
                    kind: block.kind,
                    displayText: String(mutable)
                )
                state.apply(.update(id: block.id, source: source))
            }
        }
        findReplaceState.update(blocks: state.blocks)
    }

    func cursorPlacement(for blockID: UUID) -> PuraPiMarkdownCursorPlacement? {
        guard let request = state.cursorRequest, request.blockID == blockID else { return nil }
        return request.placement
    }

    func moveToDocumentStart() {
        guard let first = state.blocks.first(where: { $0.acceptsCursor }) else { return }
        state.requestCursorPlacement(for: first.id, at: .beginning)
    }

    func moveToDocumentEnd() {
        guard let last = state.blocks.last(where: { $0.acceptsCursor }) else { return }
        state.requestCursorPlacement(for: last.id, at: .end)
    }

    func selectAllMarkdown() {
        guard let first = state.blocks.first(where: { $0.acceptsCursor }),
              let last = state.blocks.last(where: { $0.acceptsCursor })
        else { return }
        state.setSelection(
            anchor: PuraPiMarkdownSelectionEndpoint(blockID: first.id, offset: 0),
            focus: PuraPiMarkdownSelectionEndpoint(
                blockID: last.id,
                offset: last.displayText.utf16.count
            )
        )
    }

    @discardableResult
    func copyMarkdownSelection() -> Bool {
        guard let source = state.selectedMarkdownSource() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
        return true
    }

    /// 替换跨块选择。
    ///
    /// 选区两端保留在起始块中间的前缀和结束块中间的后缀；被完全覆盖的块及其
    /// 空行分隔一起移除。替换文本再经过同一块解析器拆分，因此粘贴多行内容不会
    /// 绕过 `MarkdownBlockEdit` 或破坏撤销栈。单块选区返回 false，交给 NSTextView。
    @discardableResult
    func replaceDocumentSelection(with replacement: String) -> Bool {
        guard let selection = state.selection,
              !selection.isCollapsed,
              let ordered = selection.orderedEndpoints(in: state.blocks),
              let startIndex = state.blocks.firstIndex(where: { $0.id == ordered.start.blockID }),
              let endIndex = state.blocks.firstIndex(where: { $0.id == ordered.end.blockID }),
              startIndex < endIndex
        else { return false }
        let startBlock = state.blocks[startIndex]
        let endBlock = state.blocks[endIndex]

        let startBody = startBlock.displayText as NSString
        let endBody = endBlock.displayText as NSString
        let startOffset = min(startBody.length, max(0, ordered.start.offset))
        let endOffset = min(endBody.length, max(0, ordered.end.offset))
        let prefix = startBody.substring(to: startOffset)
        let suffix = endBody.substring(from: endOffset)
        let combinedDisplayText = prefix + replacement + suffix
        let combinedSource = PuraPiMarkdownBlockConverter.composeSource(
            kind: startBlock.kind,
            displayText: combinedDisplayText
        )
        var parsed = MarkdownBlockParser.parse(combinedSource)
        if parsed.isEmpty {
            parsed = [MarkdownBlock(kind: .paragraph, source: "", lineRange: 0..<1)]
        }

        let coveredIDs = state.blocks[(startIndex + 1)...endIndex].map(\.id)
        var targetID = startBlock.id
        state.withUndoGroup {
            // 先删除后续块，避免按索引删除时被插入/合并改变位置。
            for id in coveredIDs {
                state.apply(.remove(id: id))
            }
            let first = parsed[0]
            state.apply(.retype(
                id: startBlock.id,
                kind: first.kind,
                source: first.source
            ))
            var anchor = startBlock.id
            var insertedIDs = [startBlock.id]
            for parsedBlock in parsed.dropFirst() {
                let inserted = MarkdownBlock(
                    kind: parsedBlock.kind,
                    source: parsedBlock.source,
                    lineRange: 0..<max(1, parsedBlock.lineCount),
                    internalLineEndings: parsedBlock.internalLineEndings,
                    trailingLineEnding: parsedBlock.trailingLineEnding
                )
                state.apply(.insert(block: inserted, after: anchor))
                anchor = inserted.id
                insertedIDs.append(inserted.id)
            }
            targetID = insertedIDs.reversed().first { candidate in
                state.blocks.first(where: { $0.id == candidate })?.acceptsCursor == true
            } ?? startBlock.id
            state.focusedBlockID = targetID
        }
        state.requestCursorPlacement(for: targetID, at: .end)
        return true
    }

    /// 在块边界扩展文档选择。块内未到边界时返回 false，让 NSTextView 使用
    /// 自己的字符/行选择逻辑；跨过边界时由文档状态统一绘制各块选区。
    func extendSelection(
        from block: MarkdownBlock,
        direction: Int,
        range: NSRange
    ) -> Bool {
        let bodyLength = block.displayText.utf16.count
        let existing = state.selection
        let anchor: PuraPiMarkdownSelectionEndpoint
        let focus: PuraPiMarkdownSelectionEndpoint
        if let existing,
           existing.anchor.blockID == block.id || existing.focus.blockID == block.id {
            anchor = existing.anchor
            focus = existing.focus
        } else {
            let start = min(bodyLength, max(0, range.location))
            let end = min(bodyLength, max(start, NSMaxRange(range)))
            if direction < 0 {
                anchor = PuraPiMarkdownSelectionEndpoint(blockID: block.id, offset: end)
                focus = PuraPiMarkdownSelectionEndpoint(blockID: block.id, offset: start)
            } else {
                anchor = PuraPiMarkdownSelectionEndpoint(blockID: block.id, offset: start)
                focus = PuraPiMarkdownSelectionEndpoint(blockID: block.id, offset: end)
            }
        }

        guard let focusIndex = state.blocks.firstIndex(where: { $0.id == focus.blockID }) else {
            return false
        }
        if direction < 0 {
            guard focus.offset == 0 else { return false }
            guard let target = state.blocks[..<focusIndex].last(where: { $0.acceptsCursor }) else {
                return false
            }
            state.setSelection(
                anchor: anchor,
                focus: PuraPiMarkdownSelectionEndpoint(
                    blockID: target.id,
                    offset: target.displayText.utf16.count
                )
            )
        } else {
            let focusBlockLength = state.blocks[focusIndex].displayText.utf16.count
            guard focus.offset >= focusBlockLength else { return false }
            guard let target = state.blocks.dropFirst(focusIndex + 1).first(where: { $0.acceptsCursor }) else {
                return false
            }
            state.setSelection(
                anchor: anchor,
                focus: PuraPiMarkdownSelectionEndpoint(blockID: target.id, offset: 0)
            )
        }
        return true
    }

    /// 块首退格：带块级标记的块先退回普通段落；已经是段落时才与上一块合并。
    func revertBlockType(block: MarkdownBlock) -> Bool {
        // 空列表项/空块的退格仍交给删除或合并逻辑；否则第一次退格只会
        // 把它变成一个看不见的空段落，用户还要再按一次才能移除。
        guard !block.displayText.isEmpty else { return false }
        switch block.kind {
        case .heading, .unorderedListItem, .orderedListItem, .quote, .codeFence:
            let source = block.displayText
            state.apply(.retype(id: block.id, kind: .paragraph, source: source))
            state.focusedBlockID = block.id
            return true
        case .paragraph, .table, .blank, .thematicBreak:
            return false
        }
    }

    func indentList(block: MarkdownBlock, delta: Int) {
        let updatedKind: MarkdownBlock.Kind?
        switch block.kind {
        case .unorderedListItem(let indent, let marker):
            updatedKind = .unorderedListItem(
                indent: max(0, indent + delta),
                marker: marker
            )
        case .orderedListItem(let indent, let number, let delimiter):
            updatedKind = .orderedListItem(
                indent: max(0, indent + delta),
                // 新建嵌套层级从 1 开始；回到父层时交给统一编号逻辑续号。
                number: delta > 0 ? 1 : number,
                delimiter: delimiter
            )
        default:
            updatedKind = nil
        }
        guard let updatedKind, updatedKind != block.kind else { return }
        let source = PuraPiMarkdownBlockConverter.composeSource(
            kind: updatedKind,
            displayText: block.displayText
        )
        state.withUndoGroup {
            state.apply(.retype(id: block.id, kind: updatedKind, source: source))
            state.focusedBlockID = block.id
            renumberOrderedLists()
        }
    }

    func exitList(block: MarkdownBlock) {
        let isList: Bool
        switch block.kind {
        case .unorderedListItem, .orderedListItem:
            isList = true
        default:
            isList = false
        }
        guard isList else { return }
        state.withUndoGroup {
            state.apply(.retype(id: block.id, kind: .paragraph, source: block.displayText))
            state.focusedBlockID = block.id
        }
    }

    /// 接收 Finder/桌面拖入的图片，并插入工作区内的相对 Markdown 引用。
    /// 拖放开始时固定文档、工作区、锚点和文档操作代际；所有 provider
    /// 按原始顺序加载，完成后作为一个 undo group 提交。
    @discardableResult
    func acceptImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let document = state.document,
              let root = state.workspaceRootURL
        else { return false }
        let editorState = state
        let documentURL = document.url.standardizedFileURL
        let operationID = editorState.documentOperationID
        let anchorID = editorState.focusedBlockID.flatMap { focused in
            document.blocks.contains { $0.id == focused && $0.acceptsCursor } ? focused : nil
        } ?? document.blocks.last(where: { $0.acceptsCursor })?.id
        let orderedProviders = Array(providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }.prefix(32))
        guard !orderedProviders.isEmpty else { return false }

        editorState.imageDropTask?.cancel()
        let dropTask = Task { @MainActor [weak editorState] in
            guard let editorState else { return }
            var markdowns: [String] = []
            for provider in orderedProviders {
                guard !Task.isCancelled,
                      let url = await Self.loadDroppedURL(from: provider)
                else { continue }
                let markdown = await Task.detached(priority: .utility) {
                    PuraPiMarkdownImageInsertion.markdown(for: url, workspaceRoot: root)
                }.value
                if let markdown { markdowns.append(markdown) }
            }
            guard !markdowns.isEmpty,
                  editorState.document?.url.standardizedFileURL == documentURL,
                  editorState.documentOperationID == operationID,
                  editorState.workspaceRootURL?.standardizedFileURL == root.standardizedFileURL
            else { return }

            var currentAnchorID = anchorID
            var lastInsertedID: UUID?
            editorState.withUndoGroup {
                for markdown in markdowns {
                    let inserted = MarkdownBlock(
                        kind: .paragraph,
                        source: markdown,
                        lineRange: 0..<1
                    )
                    editorState.apply(.insert(block: inserted, after: currentAnchorID))
                    currentAnchorID = inserted.id
                    lastInsertedID = inserted.id
                }
                if let lastInsertedID {
                    editorState.focusedBlockID = lastInsertedID
                }
            }
            if let lastInsertedID {
                editorState.requestCursorPlacement(for: lastInsertedID, at: .end)
            }
            editorState.imageDropTask = nil
        }
        editorState.imageDropTask = dropTask
        return true
    }

    private static func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                continuation.resume(returning: object)
            }
        }
    }

    /// 将多行粘贴解析为块序列。当前块保留自身身份，后续块按顺序插入，
    /// 这样 Undo 可以一次撤销整次粘贴而不是留下半截文本。
    func handlePaste(
        block: MarkdownBlock,
        pastedText: String,
        affectedRange: NSRange
    ) -> Bool {
        // 代码块内的换行必须原样进入代码正文，不能被 Markdown 解析器拆成块。
        if case .codeFence = block.kind { return false }
        let currentText = block.displayText as NSString
        guard affectedRange.location >= 0,
              affectedRange.length >= 0,
              NSMaxRange(affectedRange) <= currentText.length
        else { return false }

        let before = currentText.substring(to: affectedRange.location)
        let after = currentText.substring(from: NSMaxRange(affectedRange))
        let pastedBlocks = MarkdownBlockParser.parse(pastedText)
        guard !pastedBlocks.isEmpty else { return false }

        struct PendingBlock {
            let kind: MarkdownBlock.Kind
            let source: String
            let internalLineEndings: [String]
            let trailingLineEnding: String?
        }

        var pending: [PendingBlock] = []
        for (index, pastedBlock) in pastedBlocks.enumerated() {
            var kind = pastedBlock.kind
            var displayText = pastedBlock.displayText
            if index == 0 {
                if case .paragraph = kind, block.kind != .paragraph {
                    // 在标题/列表/引用中粘贴普通文本时，首段继续沿用当前块类型；
                    // 真正带有块标记的粘贴内容仍使用解析出的目标类型。
                    kind = block.kind
                }
                displayText = before + displayText
            }
            if index == pastedBlocks.count - 1 {
                // A trailing blank is a separator, not a text-bearing block.
                // Appending the suffix to it used to produce a blank block whose
                // source was "after", so the next parse lost the paragraph
                // boundary.  Put the suffix in a fresh paragraph instead.
                if case .blank = kind {
                    // Keep the parsed blank source untouched below.
                } else {
                    displayText += after
                }
            }
            pending.append(PendingBlock(
                kind: kind,
                source: PuraPiMarkdownBlockConverter.composeSource(
                    kind: kind,
                    displayText: displayText
                ),
                internalLineEndings: pastedBlock.internalLineEndings,
                trailingLineEnding: pastedBlock.trailingLineEnding
            ))
        }
        if !after.isEmpty,
           let last = pending.last,
           case .blank = last.kind {
            pending.append(PendingBlock(
                kind: .paragraph,
                source: after,
                internalLineEndings: [],
                trailingLineEnding: nil
            ))
        }

        var insertedIDs = [block.id]
        var targetID = block.id
        state.withUndoGroup {
            let first = pending[0]
            state.apply(.retype(id: block.id, kind: first.kind, source: first.source))
            var anchor = block.id
            for item in pending.dropFirst() {
                let inserted = MarkdownBlock(
                    kind: item.kind,
                    source: item.source,
                    lineRange: 0..<max(1, item.source.split(separator: "\n", omittingEmptySubsequences: false).count),
                    internalLineEndings: item.internalLineEndings,
                    trailingLineEnding: item.trailingLineEnding
                )
                state.apply(.insert(block: inserted, after: anchor))
                anchor = inserted.id
                insertedIDs.append(inserted.id)
            }
            targetID = insertedIDs.reversed().first { candidate in
                state.blocks.first(where: { $0.id == candidate })?.acceptsCursor == true
            } ?? block.id
            state.requestCursorPlacement(for: targetID, at: .end)
        }
        return true
    }

    /// Return 拆块。
    ///
    /// 新块的类型延续当前块：在列表项里回车应继续列表，而不是变成段落。
    func handleSplit(block: MarkdownBlock, head: String, tail: String) {
        state.withUndoGroup {
            let headSource = PuraPiMarkdownBlockConverter.composeSource(
                kind: block.kind,
                displayText: head
            )
            let continuationKind = PuraPiMarkdownBlockConverter.continuationKind(for: block.kind)
            let tailSource = PuraPiMarkdownBlockConverter.composeSource(
                kind: continuationKind,
                displayText: tail
            )
            let anchor = block.lineRange.upperBound
            let newBlock = MarkdownBlock(
                kind: continuationKind,
                source: tailSource,
                lineRange: anchor..<(anchor + 1)
            )
            state.apply(.split(id: block.id, firstSource: headSource, second: newBlock))

            // 段落、标题、代码块之间必须有空行分隔，否则会被 Markdown
            // 当成同一段的续行（实测：两段变一段）。列表项与引用是连续结构，
            // 中间插空行反而会断开列表。
            if PuraPiMarkdownBlockConverter.requiresBlankSeparator(continuationKind) {
                let blank = MarkdownBlock(
                    kind: .blank,
                    source: "",
                    lineRange: anchor..<(anchor + 1)
                )
                state.apply(.insert(block: blank, after: block.id))
            }
            state.requestCursorPlacement(for: newBlock.id, at: .beginning)
            renumberOrderedLists()
        }
    }

    /// 块首 Backspace：与上一个可编辑块合并。
    ///
    /// 空块直接删除；非空块把内容并入上一块尾部。跳过空行块，
    /// 否则用户要按两次退格才能穿过一个空行。
    func handleMergeBackward(block: MarkdownBlock) {
        guard let index = state.blocks.firstIndex(where: { $0.id == block.id }) else { return }

        state.withUndoGroup {
            if block.displayText.isEmpty {
                // 空块即使位于文档首部也应能被一次退格删除；删除后若没有
                // 可编辑块，编辑器会提供临时首行。
                state.apply(.remove(id: block.id))
                let safeIndex = min(index, state.blocks.count)
                let replacement = state.blocks[..<safeIndex]
                    .reversed()
                    .first(where: { $0.acceptsCursor })
                    ?? state.blocks.dropFirst(safeIndex).first(where: { $0.acceptsCursor })
                if let replacement {
                    let replacementIndex = state.blocks.firstIndex {
                        $0.id == replacement.id
                    } ?? safeIndex
                    let placement: PuraPiMarkdownCursorPlacement =
                        replacementIndex < safeIndex ? .end : .beginning
                    state.requestCursorPlacement(for: replacement.id, at: placement)
                } else {
                    // 文档没有任何可编辑块时，保留一个稳定的临时首行；不能
                    // 先把焦点设为 nil 再等待 onAppear，否则旧块失焦和新行
                    // 出现之间会丢掉键盘输入。
                    focusEmptyDocumentPlaceholder()
                }
                renumberOrderedLists()
                return
            }

            // 已是首块：非空内容无处可并
            guard let previous = state.blocks[..<index].last(where: { $0.acceptsCursor }) else {
                return
            }

            let merged = previous.displayText + block.displayText
            let source = PuraPiMarkdownBlockConverter.composeSource(
                kind: previous.kind,
                displayText: merged
            )
            state.apply(.merge(into: previous.id, from: block.id, source: source))

            // 两块之间的空行必须一起删除，否则合并后残留孤立空行，
            // 文末会多出空白且下次解析时结构错乱。
            if let previousIndex = state.blocks.firstIndex(where: { $0.id == previous.id }) {
                let separators = state.blocks[(previousIndex + 1)...]
                    .prefix { $0.kind == .blank }
                    .map(\.id)
                for id in separators {
                    state.apply(.remove(id: id))
                }
            }
            state.requestCursorPlacement(for: previous.id, at: .end)
            renumberOrderedLists()
        }
    }

    /// 重排有序列表编号。
    func renumberOrderedLists() {
        // 每个缩进层级拥有独立计数器；进入/离开嵌套列表时不能把父列表的
        // 编号延续到子列表，或把子列表的编号写回父列表。
        var nextNumberByIndent: [Int: Int] = [:]
        let blocks = state.blocks
        for block in blocks {
            guard case .orderedListItem(let indent, let number, let delimiter) = block.kind else {
                nextNumberByIndent.removeAll()
                continue
            }
            // 保留当前层级已有的下一个编号，只丢弃更深的子层级。
            nextNumberByIndent = nextNumberByIndent.filter { $0.key <= indent }
            let expected = nextNumberByIndent[indent] ?? number
            if number != expected {
                let kind = MarkdownBlock.Kind.orderedListItem(
                    indent: indent,
                    number: expected,
                    delimiter: delimiter
                )
                let source = PuraPiMarkdownBlockConverter.composeSource(
                    kind: kind,
                    displayText: block.displayText
                )
                state.apply(.retype(id: block.id, kind: kind, source: source))
            }
            nextNumberByIndent[indent] = expected + 1
        }
    }

    /// 跨块移动焦点，跳过不接受光标的块。
    func moveFocus(from block: MarkdownBlock, offset: Int) {
        guard let index = state.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let candidates = offset < 0
            ? state.blocks[..<index].reversed().map { $0 }
            : Array(state.blocks[(index + 1)...])
        guard let target = candidates.first(where: { $0.acceptsCursor }) else { return }
        // 跨块移动必须同时切换 AppKit firstResponder；向上/向下分别落在
        // 目标块的末尾/开头，避免只改语义焦点后键盘仍留在旧块。
        state.requestCursorPlacement(
            for: target.id,
            at: offset < 0 ? .end : .beginning
        )
    }
}
