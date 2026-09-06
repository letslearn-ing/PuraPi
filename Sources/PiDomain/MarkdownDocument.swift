import Foundation

/// 编辑中的 Markdown 文档。
///
/// 持有块序列与打开时的基线信息。基线用于保存前的冲突判定：Pi 的
/// `file-mutation-queue` 只在 Pi 进程内串行化写入，它不知道 WorkPi 的写入，
/// 因此「Agent 正在写 + 用户正在编辑同一文件」的丢失风险必须由我们防。
public struct MarkdownDocument: Equatable, Sendable {
    public let url: URL
    /// 打开时使用的工作区根目录；Store 用它在读取/冲突检查时执行安全的逐级路径校验。
    public let workspaceRoot: URL?
    public var blocks: [MarkdownBlock]
    /// 打开或上次保存时的文件内容哈希，用于检测外部修改。
    public var baselineHash: String
    /// 打开或上次保存时的修改时间。
    public var baselineModificationDate: Date?
    /// 行尾风格。写回时保持原样，避免整文件 diff。
    public let usesCRLF: Bool
    /// 文件是否以换行结尾。同样为了往返保真。
    public let hasTrailingNewline: Bool
    /// 被修改过、尚未写回的块。
    public private(set) var dirtyBlockIDs: Set<UUID> = []
    /// 文档发生过尚未写回的结构性或全文变更。
    ///
    /// 不能只依赖 `dirtyBlockIDs`：文档删空后没有任何相邻块可以承载脏标记，
    /// 但空文件本身仍然是一次必须落盘的编辑。
    public private(set) var hasUnpersistedChanges = false

    public init(
        url: URL,
        workspaceRoot: URL? = nil,
        blocks: [MarkdownBlock],
        baselineHash: String,
        baselineModificationDate: Date? = nil,
        usesCRLF: Bool = false,
        hasTrailingNewline: Bool = true
    ) {
        self.url = url
        self.workspaceRoot = workspaceRoot
        self.blocks = blocks
        self.baselineHash = baselineHash
        self.baselineModificationDate = baselineModificationDate
        self.usesCRLF = usesCRLF
        self.hasTrailingNewline = hasTrailingNewline
    }

    public var isDirty: Bool {
        hasUnpersistedChanges || !dirtyBlockIDs.isEmpty
    }

    public func block(id: UUID) -> MarkdownBlock? {
        blocks.first { $0.id == id }
    }

    public func index(of id: UUID) -> Int? {
        blocks.firstIndex { $0.id == id }
    }

    /// 应用一次块级变更。
    ///
    /// 所有编辑都必须经由这里，这样脏标记与未来的变更广播才有唯一入口。
    /// 行范围在应用后会失效，由 `MarkdownDocumentStore` 在写回时重建——
    /// 编辑期间维护精确行号既昂贵也无必要。
    public mutating func apply(_ edit: MarkdownBlockEdit) {
        switch edit {
        case .update(let id, let source):
            guard let index = index(of: id) else { return }
            blocks[index].source = source
            dirtyBlockIDs.insert(id)
            hasUnpersistedChanges = true

        case .retype(let id, let kind, let source):
            guard let index = index(of: id) else { return }
            blocks[index].kind = kind
            blocks[index].source = source
            dirtyBlockIDs.insert(id)
            hasUnpersistedChanges = true

        case .insert(let block, let after):
            if let after, let index = index(of: after) {
                blocks.insert(block, at: index + 1)
            } else if after == nil {
                blocks.insert(block, at: 0)
            } else {
                // 锚点已不存在：追加到末尾而不是静默丢弃这次插入。
                blocks.append(block)
            }
            dirtyBlockIDs.insert(block.id)
            hasUnpersistedChanges = true

        case .remove(let id):
            guard let index = index(of: id) else { return }
            blocks.remove(at: index)
            dirtyBlockIDs.remove(id)
            // 删除也是需要写回的改动，用相邻块承载脏标记。
            markNeighborDirty(at: index)
            hasUnpersistedChanges = true

        case .merge(let into, let from, let source):
            guard let target = index(of: into) else { return }
            blocks[target].source = source
            if let sourceIndex = index(of: from) {
                blocks.remove(at: sourceIndex)
            }
            dirtyBlockIDs.insert(into)
            hasUnpersistedChanges = true

        case .split(let id, let firstSource, let second):
            guard let index = index(of: id) else { return }
            blocks[index].source = firstSource
            blocks.insert(second, at: index + 1)
            dirtyBlockIDs.insert(id)
            dirtyBlockIDs.insert(second.id)
            hasUnpersistedChanges = true
        }
    }

    /// 删除块后，让相邻块承担脏标记，确保该区域会被重写。
    private mutating func markNeighborDirty(at index: Int) {
        if blocks.indices.contains(index) {
            dirtyBlockIDs.insert(blocks[index].id)
        } else if blocks.indices.contains(index - 1) {
            dirtyBlockIDs.insert(blocks[index - 1].id)
        }
        // 文档被删空时没有邻居可标记；此时由 hasUnpersistedChanges 保证 store
        // 仍会整体写回。
    }

    /// 保存成功后重置基线。
    public mutating func resetBaseline(hash: String, modificationDate: Date?) {
        baselineHash = hash
        baselineModificationDate = modificationDate
        dirtyBlockIDs.removeAll()
        hasUnpersistedChanges = false
    }

    /// 强制标记全文为脏。删空文档或结构性重排时使用。
    public mutating func markAllDirty() {
        dirtyBlockIDs = Set(blocks.map(\.id))
        hasUnpersistedChanges = true
    }
}
