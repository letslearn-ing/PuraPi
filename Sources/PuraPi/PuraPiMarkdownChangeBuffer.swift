import Foundation
import WorkspaceKit

/// Markdown 编辑器到协作 Prompt 组装层之间的本地变更缓冲区。
///
/// 它刻意不依赖 RPC，也不发布高频文本变化。自动保存只更新磁盘基线，不代表
/// Agent 已经收到这次用户修改；Prompt 组装器只有在用户确认且 Runtime 接受后才会推进协作基线。
@MainActor
final class PuraPiMarkdownChangeBuffer {
    private(set) var url: URL?
    private var baseText: String?
    private var baseHash: String?
    private var hasChanges = false
    private var changedBlockIDs = Set<UUID>()

    var hasPendingChanges: Bool { hasChanges }
    var pendingChangedBlockCount: Int { changedBlockIDs.count }

    func reset(url: URL, text: String, hash: String) {
        self.url = url.standardizedFileURL
        baseText = text
        baseHash = hash
        hasChanges = false
        changedBlockIDs.removeAll()
    }

    func clear() {
        url = nil
        baseText = nil
        baseHash = nil
        hasChanges = false
        changedBlockIDs.removeAll()
    }

    /// 文件已经自动保存但仍未通知 Agent 时，切换文件后恢复原协作基线。
    /// 磁盘上的当前文本必须与快照一致；否则调用方应先走外部修改冲突处理。
    @discardableResult
    func restore(_ snapshot: PuraPiMarkdownChangeSnapshot) -> Bool {
        guard MarkdownDocumentStore.hash(snapshot.baseText) == snapshot.baseHash,
              MarkdownDocumentStore.hash(snapshot.currentText) == snapshot.currentHash
        else { return false }
        url = snapshot.url.standardizedFileURL
        baseText = snapshot.baseText
        baseHash = snapshot.baseHash
        hasChanges = snapshot.baseText != snapshot.currentText
        changedBlockIDs = Set(snapshot.changedBlockIDs)
        return hasChanges
    }

    /// 标记一次已经通过 `MarkdownBlockEdit` 应用的本地变更。
    ///
    /// 不在每次按键时序列化整篇文档，避免影响编辑器输入性能；完整文本只在
    /// 未来消费者真正读取快照，或文件监视器需要判断冲突时生成。
    func markChanged(blockIDs: Set<UUID> = []) {
        hasChanges = true
        changedBlockIDs.formUnion(blockIDs)
    }

    /// 用当前源码确认“用户是否已经回到协作基线”。只在撤销/重做和外部变更路径调用。
    func hasPendingChanges(currentText: String) -> Bool {
        guard let baseText else { return false }
        if currentText == baseText {
            hasChanges = false
            changedBlockIDs.removeAll()
            return false
        }
        return hasChanges || currentText != baseText
    }

    /// 用完整源码重新同步缓冲区的 pending 标记；用于撤销/重做等非单块编辑路径。
    func reconcile(currentText: String, changedBlockIDs: Set<UUID>) {
        guard let baseText else { return }
        if currentText == baseText {
            hasChanges = false
            self.changedBlockIDs.removeAll()
        } else {
            hasChanges = true
            self.changedBlockIDs.formUnion(changedBlockIDs)
        }
    }

    /// 生成供 Prompt 组装器读取的快照；不会改变确认状态。
    func snapshot(
        currentText: String,
        fallbackChangedBlockIDs: Set<UUID> = []
    ) -> PuraPiMarkdownChangeSnapshot? {
        guard let url,
              let baseText,
              let baseHash
        else { return nil }
        guard currentText != baseText else {
            hasChanges = false
            changedBlockIDs.removeAll()
            return nil
        }
        // 即使某条未来的编辑入口忘记调用 markChanged，只要源码相对协作基线
        // 发生变化，按需读取快照仍应能发现它。
        hasChanges = true
        changedBlockIDs.formUnion(fallbackChangedBlockIDs)

        return PuraPiMarkdownChangeSnapshot(
            url: url,
            baseHash: baseHash,
            baseText: baseText,
            currentText: currentText,
            changedBlockIDs: changedBlockIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// 未来协作层在成功把快照加入 Prompt 后调用；当前版本不会调用它。
    func acknowledge(currentText: String) {
        guard let url else { return }
        let hash = MarkdownDocumentStore.hash(currentText)
        baseText = currentText
        baseHash = hash
        hasChanges = false
        changedBlockIDs.removeAll()
        self.url = url.standardizedFileURL
    }

    /// 只确认已经发送的那一个快照。
    ///
    /// 如果用户在 RPC 响应到达前继续编辑，协作基线推进到已发送文本，后续编辑
    /// 仍保留为新的 pending 变更；若 URL/基线已变化，则拒绝确认，避免丢失变更。
    @discardableResult
    func acknowledge(
        snapshot: PuraPiMarkdownChangeSnapshot,
        currentText: String,
        currentBlockIDs: Set<UUID>
    ) -> Bool {
        guard let url,
              url.standardizedFileURL == snapshot.url.standardizedFileURL,
              let baseText,
              let baseHash,
              baseText == snapshot.baseText,
              baseHash == snapshot.baseHash,
              MarkdownDocumentStore.hash(snapshot.currentText) == snapshot.currentHash
        else { return false }

        self.baseText = snapshot.currentText
        self.baseHash = snapshot.currentHash
        self.url = snapshot.url.standardizedFileURL
        if currentText == snapshot.currentText {
            hasChanges = false
            changedBlockIDs.removeAll()
        } else {
            hasChanges = true
            // 无法在这里安全地推断“哪些块是快照之后改的”；保守保留当前所有
            // 块 ID，宁可在 UI 中显示稍宽的影响范围，也不能漏掉后续修改。
            changedBlockIDs = currentBlockIDs
        }
        return true
    }
}

/// 供 Markdown 协作组装层读取的本地变更快照。
///
/// 这不是 RPC 载荷，也不会自动进入 Agent 上下文。它把“基于哪个版本、用户当前
/// 改成了什么、哪些块受影响”集中在编辑器状态边界内，由 Prompt 组装阶段转换为
/// 用户可审阅的 unified diff（统一差异），而不让窗口控制器直接操作 Runtime。
struct PuraPiMarkdownChangeSnapshot: Equatable, Sendable {
    let url: URL
    let baseHash: String
    let baseText: String
    let currentText: String
    let changedBlockIDs: [UUID]

    var currentHash: String {
        MarkdownDocumentStore.hash(currentText)
    }
}
