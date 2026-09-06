import Foundation
import PiDomain
import WorkspaceKit

enum PuraPiMarkdownCursorPlacement: Equatable {
    case beginning
    case end
}

struct PuraPiMarkdownCursorRequest: Equatable {
    let blockID: UUID
    let placement: PuraPiMarkdownCursorPlacement
}

extension Notification.Name {
    /// ⌘S：保存当前文档。
    static let puraPiSaveDocument = Notification.Name("PuraPi.saveDocument")
}

/// Markdown 编辑器的状态与生命周期。
///
/// 所有编辑都经由 `apply(_:)` 表达为 `MarkdownBlockEdit`，再由
/// `MarkdownDocumentStore` 落盘。UI 不直接写文件；协作 Prompt 组装也只从这条
/// 状态边界读取已确认的快照。
@MainActor
final class PuraPiMarkdownEditorState: ObservableObject {
    enum SaveState: Equatable {
        case clean
        case dirty
        case saving
        case saved
        case failed(String)
    }

    /// 磁盘被外部改动（通常是 Agent）时的待决冲突。
    struct Conflict: Equatable {
        enum Kind: Equatable {
            case modified
            case deleted
            case unreadable
        }

        let kind: Kind
        let diskText: String
        let diskHash: String
    }

    private struct HistoryEntry: Equatable {
        let blocks: [MarkdownBlock]
        let focusedBlockID: UUID?
    }

    @Published var document: MarkdownDocument?
    @Published var saveState: SaveState = .clean
    @Published var conflict: Conflict?
    @Published var loadError: String?
    /// 当前光标所在块。决定该块是否显示原始标记符号。
    @Published var focusedBlockID: UUID?
    /// 当前文档级选择；普通单块选择也记录在这里，便于 Cmd+C 统一复制源码。
    @Published var selection: PuraPiMarkdownSelection?
    /// 文档级光标移动的一次性请求；由目标块消费后清除。
    @Published var cursorRequest: PuraPiMarkdownCursorRequest? = nil
    /// 空文档临时首行的稳定身份。放在共享编辑器状态中，避免 attached/detached
    /// 两个宿主各自生成不同 placeholder，导致焦点互相覆盖。
    @Published var emptyDocumentPlaceholderID = UUID()
    /// 每次文档内容或打开的文件发生变化都会递增；协作审阅用它检测审阅期间的编辑。
    @Published var collaborationRevision: UInt64 = 0

    let store = MarkdownDocumentStore()
    /// 串行化后台保存，并记住本进程最近一次成功写入的 hash，避免旧快照
    /// 写入后被新快照误判为外部修改。
    let backgroundSaveCoordinator = PuraPiMarkdownSaveCoordinator()
    /// 与磁盘保存基线分开：它代表 Agent 协作层最后确认的版本，自动保存不会推进它。
    let changeBuffer = PuraPiMarkdownChangeBuffer()
    var workspaceRoot: URL?
    var baselineText: String?
    var autosaveTask: Task<Void, Never>?
    var imageDropTask: Task<Void, Never>?
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private let maximumHistoryEntries = 200
    private var undoGroupDepth = 0
    private var undoGroupStart: HistoryEntry?
    private var restoringHistory = false
    /// Invalidates detached load/save completions when the selected document changes.
    var documentOperationID = UUID()
    /// Consecutive ordinary updates to the same block are one typing gesture.
    /// NSTextView publishes one `.update` per character, so recording every one
    /// made a long paste/type run exhaust the bounded history ring before it
    /// could be undone in full.
    private var lastHistoryUpdateBlockID: UUID?

    /// 自动保存延迟。停止输入这么久后落盘，避免每个字符都写磁盘。
    private let autosaveDelay: Duration = .seconds(2)

    var blocks: [MarkdownBlock] { document?.blocks ?? [] }
    var workspaceRootURL: URL? { workspaceRoot }
    var isEditing: Bool { document != nil }
    var fileName: String { document?.url.lastPathComponent ?? "" }
    /// 不序列化全文的轻量状态，供 Composer 提示使用。
    var hasPendingCollaborationChanges: Bool { changeBuffer.hasPendingChanges }
    var pendingCollaborationBlockCount: Int { changeBuffer.pendingChangedBlockCount }
    /// 冲突面板使用的本地源码快照；只读序列化，不改变文档或保存基线。
    var serializedLocalText: String {
        guard let document else { return "" }
        return serializedText(for: document)
    }

    /// 当前尚未被 Agent 协作层确认的变更快照。故意不使用 `@Published`：编辑时不应把
    /// 完整文档按字符发布给 SwiftUI；消费者在真正组装 Prompt 时读取一次即可。
    /// 自动保存不会清除此快照，只有显式确认才会推进协作基线。
    var pendingCollaborationSnapshot: PuraPiMarkdownChangeSnapshot? {
        guard let document else { return nil }
        return changeBuffer.snapshot(
            currentText: serializedText(for: document),
            fallbackChangedBlockIDs: Set(document.blocks.map(\.id))
        )
    }

    /// 兼容旧调用方：确认当前完整协作快照。
    func acknowledgePendingCollaboration() {
        guard conflict == nil, let document else { return }
        changeBuffer.acknowledge(currentText: serializedText(for: document))
        collaborationRevision &+= 1
    }

    /// 只确认已经成功发送的快照；快照之后的新编辑不会被一并清除。
    @discardableResult
    func acknowledgePendingCollaboration(
        _ snapshot: PuraPiMarkdownChangeSnapshot
    ) -> Bool {
        guard conflict == nil, let document else { return false }
        let currentText = serializedText(for: document)
        let acknowledged = changeBuffer.acknowledge(
            snapshot: snapshot,
            currentText: currentText,
            currentBlockIDs: Set(document.blocks.map(\.id))
        )
        if acknowledged { collaborationRevision &+= 1 }
        return acknowledged
    }

    func serializedText(for document: MarkdownDocument) -> String {
        MarkdownBlockParser.serialize(
            document.blocks,
            usesCRLF: document.usesCRLF,
            hasTrailingNewline: document.hasTrailingNewline
        )
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - 打开与关闭

    /// 判断某个文件是否应由编辑器接管。
    static func canEdit(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    /// 打开文件。若当前文档有未保存修改且无法安全保存，则保持当前文件不变。
    @discardableResult
    func open(url: URL, workspaceRoot: URL) -> Bool {
        let targetURL = url.standardizedFileURL
        guard conflict == nil else { return false }
        if let current = document,
           current.url != targetURL,
           current.isDirty {
            guard close() else { return false }
        }
        // 同一份脏文档不能因为重选文件或通知而被静默重载；外部变化走专用入口。
        if let current = document,
           current.url == targetURL,
           current.isDirty {
            return false
        }
        load(url: targetURL, workspaceRoot: workspaceRoot)
        return true
    }

    /// 关闭文件。冲突、保存失败或协作差异尚未确认时保留文档和编辑器，避免
    /// 把本地内容或“尚未通知 Agent”的状态一并静默丢弃。
    @discardableResult
    func close() -> Bool {
        close(preservingPendingCollaboration: false)
    }

    /// 关闭编辑器宿主但保留协作层快照。文件切换使用此入口：磁盘内容已经
    /// 自动保存，协作差异由 `PiSessionController` 按文件保存，不能因离开当前
    /// Inspector 就丢失。
    @discardableResult
    func close(preservingPendingCollaboration: Bool) -> Bool {
        imageDropTask?.cancel()
        imageDropTask = nil
        autosaveTask?.cancel()
        guard conflict == nil else { return false }
        if document?.isDirty == true, !save() {
            return false
        }
        if !preservingPendingCollaboration,
           let document,
           changeBuffer.hasPendingChanges(
               currentText: serializedText(for: document)
           ) {
            // 本地内容可能已经自动保存，但 Agent 尚未收到协作差异；不能在
            // close() 中静默清掉这份 pending 状态。用户可显式“放弃同步”。
            return false
        }
        documentOperationID = UUID()
        document = nil
        baselineText = nil
        emptyDocumentPlaceholderID = UUID()
        collaborationRevision &+= 1
        changeBuffer.clear()
        conflict = nil
        loadError = nil
        saveState = .clean
        focusedBlockID = nil
        selection = nil
        cursorRequest = nil
        clearHistory()
        return true
    }

    /// 实际读取入口。只有用户明确选择“重新读取”或当前文档干净时才能调用。
    private func load(url: URL, workspaceRoot: URL) {
        imageDropTask?.cancel()
        imageDropTask = nil
        autosaveTask?.cancel()
        documentOperationID = UUID()
        emptyDocumentPlaceholderID = UUID()
        self.workspaceRoot = workspaceRoot
        conflict = nil
        loadError = nil

        do {
            let loadedDocument = try store.load(url: url, workspaceRoot: workspaceRoot)
            document = loadedDocument
            collaborationRevision &+= 1
            let loadedText = serializedText(for: loadedDocument)
            baselineText = loadedText
            changeBuffer.reset(
                url: loadedDocument.url,
                text: loadedText,
                hash: loadedDocument.baselineHash
            )
            clearHistory()
            saveState = .clean
            // 文件开头的空标题/空行是合法源码，不能删除；初始焦点跳到
            // 第一个有可见内容的块，避免不可见块把首屏正文推得过低。
            let blocks = document?.blocks ?? []
            focusedBlockID = blocks.first {
                $0.acceptsCursor
                    && !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?.id ?? blocks.first(where: { $0.acceptsCursor })?.id
            cursorRequest = nil
            selection = nil
        } catch {
            document = nil
            baselineText = nil
            collaborationRevision &+= 1
            changeBuffer.clear()
            focusedBlockID = nil
            cursorRequest = nil
            selection = nil
            clearHistory()
            loadError = Self.describe(error)
            saveState = .clean
        }
    }

    // MARK: - 编辑

    /// 应用一次块级变更并安排自动保存。
    func apply(_ edit: MarkdownBlockEdit) {
        guard var current = document else { return }
        if case .remove(let id) = edit,
           cursorRequest?.blockID == id {
            cursorRequest = nil
        }
        current.apply(edit)
        guard current != document else { return }

        // A block-local update is the notification emitted by ordinary typing.
        // Keep the first pre-edit snapshot and coalesce following updates for
        // that same block. Structural edits and edits to another block always
        // form a new undo boundary.
        let canCoalesce: Bool = {
            guard case .update(let id, _) = edit,
                  undoGroupDepth == 0
            else { return false }
            return lastHistoryUpdateBlockID == id
        }()
        if canCoalesce {
            redoStack.removeAll()
        } else {
            recordHistoryBeforeChange()
        }
        if case .update(let id, _) = edit {
            lastHistoryUpdateBlockID = id
        } else {
            lastHistoryUpdateBlockID = nil
        }
        documentOperationID = UUID()
        document = current
        collaborationRevision &+= 1
        markCollaborationChange(for: edit)
        selection = nil
        saveState = .dirty
        scheduleAutosave()
    }

    /// 把一组结构性编辑合并成一个撤销单元，例如一次 Return 可能同时产生
    /// 拆块和空行，列表重排也可能修改多个块。
    func withUndoGroup(_ changes: () -> Void) {
        if undoGroupDepth == 0 {
            undoGroupStart = document.map {
                HistoryEntry(blocks: $0.blocks, focusedBlockID: focusedBlockID)
            }
        }
        undoGroupDepth += 1
        lastHistoryUpdateBlockID = nil
        changes()
        undoGroupDepth -= 1
        if undoGroupDepth == 0 {
            if let start = undoGroupStart,
               let current = document,
               current.blocks != start.blocks {
                appendUndoEntry(start)
            }
            undoGroupStart = nil
            lastHistoryUpdateBlockID = nil
        }
    }

    /// 设置当前块内的普通选择/光标位置。
    func setLocalSelection(blockID: UUID, range: NSRange) {
        guard let block = blocks.first(where: { $0.id == blockID }) else { return }
        let length = block.displayText.utf16.count
        let start = min(length, max(0, range.location))
        let end = min(length, max(start, NSMaxRange(range)))
        focusedBlockID = blockID
        cursorRequest = nil
        selection = PuraPiMarkdownSelection(
            anchor: PuraPiMarkdownSelectionEndpoint(blockID: blockID, offset: start),
            focus: PuraPiMarkdownSelectionEndpoint(blockID: blockID, offset: end)
        )
    }

    /// 设置跨块选择端点。跨块选区保留发起选择的块作为实际键盘焦点，
    /// 不把 active endpoint 误当成 first responder。
    func setSelection(
        anchor: PuraPiMarkdownSelectionEndpoint,
        focus: PuraPiMarkdownSelectionEndpoint
    ) {
        guard let anchorBlock = blocks.first(where: { $0.id == anchor.blockID }),
              let focusBlock = blocks.first(where: { $0.id == focus.blockID })
        else { return }
        let clampedAnchor = PuraPiMarkdownSelectionEndpoint(
            blockID: anchor.blockID,
            offset: min(anchorBlock.displayText.utf16.count, max(0, anchor.offset))
        )
        let clampedFocus = PuraPiMarkdownSelectionEndpoint(
            blockID: focus.blockID,
            offset: min(focusBlock.displayText.utf16.count, max(0, focus.offset))
        )
        selection = PuraPiMarkdownSelection(anchor: clampedAnchor, focus: clampedFocus)
        // 文档级选区可以跨越多个 NSTextView，但实际键盘所有权仍在发起
        // 选择的块上。若这里把焦点直接改成 active endpoint，原 firstResponder
        // 会变成不可编辑的失焦视图，下一次输入/删除就会被吞掉。
        if focusedBlockID == nil {
            focusedBlockID = focus.blockID
        }
        cursorRequest = nil
    }

    func clearSelection() {
        selection = nil
    }

    /// 将一个块移动到目标块之前；移动本身是一个可撤销的结构编辑。
    func moveBlock(id: UUID, before targetID: UUID?) {
        guard var current = document,
              let sourceIndex = current.blocks.firstIndex(where: { $0.id == id })
        else { return }
        let requestedDestination: Int?
        if let targetID {
            requestedDestination = current.blocks.firstIndex(where: { $0.id == targetID })
        } else {
            requestedDestination = current.blocks.count
        }
        guard let requestedDestination else { return }
        if targetID == id { return }

        // A blank group is the separator of the block immediately before it,
        // not an independent item. Carry it with the moved block; otherwise a
        // drag followed by serialization can leave the blank on the old side
        // and the next parse changes paragraph/list structure.
        let targetIsAfterSource = requestedDestination > sourceIndex
        if targetIsAfterSource {
            let intervening = current.blocks[(sourceIndex + 1)..<requestedDestination]
            if intervening.allSatisfy({ $0.kind == .blank }) { return }
        }
        if targetID == nil,
           current.blocks.dropFirst(sourceIndex + 1).allSatisfy({ $0.kind == .blank }) {
            return
        }

        var unitStart = sourceIndex
        var unitEnd = sourceIndex + 1
        while unitEnd < current.blocks.count,
              current.blocks[unitEnd].kind == .blank {
            unitEnd += 1
        }
        var hasLeadingSeparators = false
        if unitEnd == sourceIndex + 1, sourceIndex > 0 {
            unitStart = sourceIndex
            while unitStart > 0,
                  current.blocks[unitStart - 1].kind == .blank {
                unitStart -= 1
                hasLeadingSeparators = true
            }
        }

        if let targetID,
           (unitStart..<unitEnd).contains(where: { current.blocks[$0].id == targetID }) {
            return
        }
        let moved = Array(current.blocks[unitStart..<unitEnd])
        current.blocks.removeSubrange(unitStart..<unitEnd)
        let movedUnit: [MarkdownBlock]
        if hasLeadingSeparators {
            // A trailing block has its separator on the left.  Re-home that
            // separator to the right when the block is moved, so the unit can
            // be inserted before another content block without a leading blank.
            movedUnit = [moved.last!] + Array(moved.dropLast())
        } else {
            movedUnit = moved
        }
        let destinationIndex: Int
        if let destinationBlockID = targetID {
            guard let targetIndex = current.blocks.firstIndex(where: { $0.id == destinationBlockID }) else {
                return
            }
            destinationIndex = targetIndex
        } else {
            destinationIndex = current.blocks.count
        }
        current.blocks.insert(contentsOf: movedUnit, at: destinationIndex)
        recordHistoryBeforeChange()
        current.markAllDirty()
        documentOperationID = UUID()
        document = current
        lastHistoryUpdateBlockID = nil
        collaborationRevision &+= 1
        changeBuffer.markChanged(blockIDs: Set(current.blocks.map(\.id)))
        selection = nil
        saveState = .dirty
        scheduleAutosave()
    }

    func selectionRange(for blockID: UUID) -> NSRange? {
        guard let selection,
              let block = blocks.first(where: { $0.id == blockID })
        else { return nil }
        return selection.bodyRange(for: block, in: blocks)
    }

    /// 将当前选择转换为可粘贴的 Markdown 源码。
    func selectedMarkdownSource() -> String? {
        guard let selection,
              !selection.isCollapsed,
              let ordered = selection.orderedEndpoints(in: blocks),
              let startIndex = blocks.firstIndex(where: { $0.id == ordered.start.blockID }),
              let endIndex = blocks.firstIndex(where: { $0.id == ordered.end.blockID })
        else { return nil }

        var parts: [String] = []
        for index in startIndex...endIndex {
            let block = blocks[index]
            guard let range = selection.bodyRange(for: block, in: blocks) else { continue }
            // 块之间的结构性 blank 不需要在复制结果中再额外生成两个换行；
            // 分隔由下面的 join 统一提供。零长度的边界块也不应产生空片段。
            if range.length == 0 {
                if case .blank = block.kind { continue }
                if index == startIndex || index == endIndex { continue }
            }
            let body = block.displayText as NSString
            let selectedBody = body.substring(with: range)
            parts.append(PuraPiMarkdownBlockConverter.composeSource(
                kind: block.kind,
                displayText: selectedBody
            ))
        }
        return parts.joined(separator: "\n\n")
    }

    /// 请求把焦点移动到指定块的首部或尾部。
    func requestCursorPlacement(for blockID: UUID, at placement: PuraPiMarkdownCursorPlacement) {
        guard blocks.contains(where: { $0.id == blockID && $0.acceptsCursor }) else { return }
        focusedBlockID = blockID
        cursorRequest = PuraPiMarkdownCursorRequest(blockID: blockID, placement: placement)
    }

    func consumeCursorRequest(for blockID: UUID) {
        guard cursorRequest?.blockID == blockID else { return }
        cursorRequest = nil
    }

    /// 用户直接点击其它编辑宿主时，取消尚未执行的旧导航请求。
    func clearCursorRequest() {
        cursorRequest = nil
    }

    /// 撤销最近一次块级变更。历史栈不因保存而清空，保存后仍可回退。
    func undo() {
        guard let current = document, let target = undoStack.popLast() else { return }
        appendRedoEntry(HistoryEntry(blocks: current.blocks, focusedBlockID: focusedBlockID))
        restoreHistory(target)
    }

    /// 重做最近撤销的块级变更。
    func redo() {
        guard let current = document, let target = redoStack.popLast() else { return }
        appendUndoEntry(HistoryEntry(blocks: current.blocks, focusedBlockID: focusedBlockID))
        restoreHistory(target)
    }

    private func recordHistoryBeforeChange() {
        guard !restoringHistory else { return }
        guard let current = document else { return }
        let entry = HistoryEntry(blocks: current.blocks, focusedBlockID: focusedBlockID)
        if undoGroupDepth > 0 {
            // 外层 withUndoGroup 已经记录起点；这里不再追加中间状态。
            if undoGroupStart == nil { undoGroupStart = entry }
        } else {
            appendUndoEntry(entry)
        }
        redoStack.removeAll()
        lastHistoryUpdateBlockID = nil
    }

    private func appendUndoEntry(_ entry: HistoryEntry) {
        undoStack.append(entry)
        if undoStack.count > maximumHistoryEntries {
            undoStack.removeFirst(undoStack.count - maximumHistoryEntries)
        }
    }

    private func appendRedoEntry(_ entry: HistoryEntry) {
        redoStack.append(entry)
        if redoStack.count > maximumHistoryEntries {
            redoStack.removeFirst(redoStack.count - maximumHistoryEntries)
        }
    }

    private func restoreHistory(_ entry: HistoryEntry) {
        guard var current = document else { return }
        restoringHistory = true
        current.blocks = entry.blocks
        // 保留当前文件基线；历史恢复的内容只有在恰好等于当前磁盘基线时
        // 才能回到 clean，否则必须标记为待保存。
        let restoredText = serializedText(for: current)
        if restoredText == baselineText {
            current.resetBaseline(
                hash: current.baselineHash,
                modificationDate: current.baselineModificationDate
            )
            saveState = .clean
        } else {
            current.markAllDirty()
            saveState = .dirty
        }
        documentOperationID = UUID()
        document = current
        collaborationRevision &+= 1
        changeBuffer.reconcile(
            currentText: restoredText,
            changedBlockIDs: Set(current.blocks.map(\.id))
        )
        focusedBlockID = validFocusID(entry.focusedBlockID, in: entry.blocks)
        selection = nil
        cursorRequest = nil
        if let focusedBlockID {
            // 历史恢复可能重建了 NSTextView；显式请求 first responder 和
            // 一个确定的插入点，不能只依赖旧视图是否恰好还在窗口中。
            requestCursorPlacement(for: focusedBlockID, at: .end)
        }
        restoringHistory = false
        lastHistoryUpdateBlockID = nil
        scheduleAutosave()
    }

    private func markCollaborationChange(for edit: MarkdownBlockEdit) {
        let ids: Set<UUID>
        switch edit {
        case .update(let id, _), .retype(let id, _, _):
            ids = [id]
        case .insert(let block, _):
            ids = [block.id]
        case .remove(let id):
            ids = [id]
        case .merge(let into, let from, _):
            ids = [into, from]
        case .split(let id, _, let second):
            ids = [id, second.id]
        }
        changeBuffer.markChanged(blockIDs: ids)
    }

    private func validFocusID(_ preferred: UUID?, in blocks: [MarkdownBlock]) -> UUID? {
        if let preferred, blocks.contains(where: { $0.id == preferred && $0.acceptsCursor }) {
            return preferred
        }
        return blocks.first(where: { $0.acceptsCursor })?.id
    }

    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        undoGroupDepth = 0
        undoGroupStart = nil
        lastHistoryUpdateBlockID = nil
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            _ = await self?.save()
        }
    }

    // MARK: - 保存

    @discardableResult
    func save() -> Bool {
        guard let current = document else { return true }
        guard conflict == nil else { return false }
        guard current.isDirty else { return true }
        autosaveTask?.cancel()
        saveState = .saving
        do {
            switch try backgroundSaveCoordinator.save(current, store: store, force: false) {
            case .saved(let hash, let date):
                var updated = current
                updated.resetBaseline(hash: hash, modificationDate: date)
                document = updated
                baselineText = serializedText(for: updated)
                backgroundSaveCoordinator.rememberSavedHash(hash, for: updated.url)
                saveState = .saved
                return true
            case .conflict(let diskHash, let diskText):
                // 不覆盖：交给用户在冲突界面决定。
                conflict = Conflict(
                    kind: .modified,
                    diskText: diskText,
                    diskHash: diskHash
                )
                saveState = .dirty
                return false
            case .deleted:
                // 文件被删除时不能默认恢复旧文件，留给用户显式选择。
                conflict = Conflict(kind: .deleted, diskText: "", diskHash: "")
                saveState = .dirty
                return false
            case .unreadable:
                // 未知编码或读取失败时不能覆盖未知磁盘内容。
                conflict = Conflict(kind: .unreadable, diskText: "", diskHash: "")
                saveState = .dirty
                return false
            }
        } catch let failure as MarkdownDocumentStore.SaveFailure {
            if case .deleted = failure {
                conflict = Conflict(kind: .deleted, diskText: "", diskHash: "")
                saveState = .dirty
            } else {
                saveState = .failed(Self.describe(failure))
            }
            return false
        } catch {
            saveState = .failed(Self.describe(error))
            return false
        }
    }

    // MARK: - 冲突处理

    /// 放弃本地改动，采用磁盘版本。
    func resolveConflictByReloading() {
        guard conflict != nil,
              let url = document?.url,
              let root = workspaceRoot
        else { return }
        // 这是用户明确选择放弃本地版本，因此绕过 open() 的未保存保护。
        load(url: url, workspaceRoot: root)
    }

    /// 保留本地版本，覆盖磁盘。
    func resolveConflictByOverwriting() {
        guard conflict != nil, let current = document else { return }
        conflict = nil
        saveState = .saving
        do {
            switch try backgroundSaveCoordinator.save(current, store: store, force: true) {
            case .saved(let hash, let date):
                var updated = current
                updated.resetBaseline(hash: hash, modificationDate: date)
                document = updated
                baselineText = serializedText(for: updated)
                backgroundSaveCoordinator.rememberSavedHash(hash, for: updated.url)
                saveState = .saved
            case .conflict(let diskHash, let diskText):
                conflict = Conflict(
                    kind: .modified,
                    diskText: diskText,
                    diskHash: diskHash
                )
                saveState = .dirty
            case .deleted, .unreadable:
                // force=true 已跳过基线读取；若写入仍失败，catch 会显示具体错误。
                saveState = .failed("无法覆盖文件。")
            }
        } catch {
            saveState = .failed(Self.describe(error))
        }
    }

    func dismissConflict() {
        guard let currentConflict = conflict else { return }
        conflict = nil
        // 删除/不可解码冲突即使原先没有本地编辑，也不能让后续 close() 无提示地
        // 丢掉仍保留在内存中的文档快照；再次保存时会重新进入同一冲突分支。
        if currentConflict.kind != .modified, var current = document {
            current.markAllDirty()
            document = current
            changeBuffer.markChanged(blockIDs: Set(current.blocks.map(\.id)))
            saveState = .dirty
        }
    }

    // MARK: - 外部变更

    /// 当前关闭是否因未确认协作差异而被阻止。
    var isCloseBlockedByPendingCollaboration: Bool {
        guard conflict == nil, let document else { return false }
        return changeBuffer.hasPendingChanges(
            currentText: serializedText(for: document)
        )
    }

    /// 显式放弃“通知 Agent”这份协作意图，但不修改磁盘上的 Markdown 内容。
    @discardableResult
    func discardPendingCollaboration() -> Bool {
        guard conflict == nil, let document else { return false }
        if document.isDirty, !save() { return false }
        let currentText = serializedText(for: document)
        guard changeBuffer.hasPendingChanges(currentText: currentText) else { return true }
        changeBuffer.acknowledge(currentText: currentText)
        collaborationRevision &+= 1
        return true
    }

    /// 在用户审阅/发送协作差异前主动复用一次磁盘校验，覆盖 FSEvents 尚未送达的
    /// 窗口；不会绕过既有冲突处理，只会把结果写入同一个 `conflict` 状态。
    @discardableResult
    func refreshExternalConflict() -> Bool {
        guard let document else { return false }
        handleExternalChange(at: document.url)
        return conflict != nil
    }

    /// 由文件监控调用：磁盘上的当前文件被改动了。
    ///
    /// 本地无改动时，只有可安全读取的普通修改才直接重载；本地有改动、文件被删或
    /// 文件不可解码时都转冲突，不自动选边——静默丢弃任何一方都不可接受。
    func handleExternalChange(at url: URL) {
        guard let current = document,
              current.url.standardizedFileURL == url.standardizedFileURL
        else { return }

        let serializedCurrentText = serializedText(for: current)
        let hasPendingCollaboration = changeBuffer.hasPendingChanges(
            currentText: serializedCurrentText
        )

        switch store.externalChange(for: current) {
        case .unchanged:
            return
        case .modified(let diskHash, let diskText):
            if current.isDirty || hasPendingCollaboration {
                conflict = Conflict(
                    kind: .modified,
                    diskText: diskText,
                    diskHash: diskHash
                )
                saveState = .dirty
            } else if let root = workspaceRoot {
                load(url: current.url, workspaceRoot: root)
            }
        case .deleted:
            conflict = Conflict(kind: .deleted, diskText: "", diskHash: "")
            saveState = .dirty
        case .unreadable:
            conflict = Conflict(kind: .unreadable, diskText: "", diskHash: "")
            saveState = .dirty
        }
    }

    // MARK: - 文案

    static func describe(_ error: Error) -> String {
        if let failure = error as? MarkdownDocumentStore.LoadFailure {
            switch failure {
            case .outsideWorkspace: return "文件不在当前项目内。"
            case .notAFile: return "这不是一个文件。"
            case .tooLarge(let byteCount):
                let mb = Double(byteCount) / (1024 * 1024)
                return String(format: "文件过大（%.1f MB），暂不支持编辑。", mb)
            case .notUTF8: return "文件不是 UTF-8 文本，无法编辑。"
            }
        }
        if let failure = error as? MarkdownDocumentStore.SaveFailure {
            switch failure {
            case .tooLarge(let byteCount):
                let mb = Double(byteCount) / (1024 * 1024)
                return String(format: "保存内容过大（%.1f MB），请减少内容后重试。", mb)
            case .deleted:
                return "文件在保存时被删除。"
            case .outsideWorkspace:
                return "文件已不在当前项目内。"
            }
        }
        return error.localizedDescription
    }
}
