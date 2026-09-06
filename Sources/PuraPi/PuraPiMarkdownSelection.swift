import Foundation
import PiDomain

/// 一个块内的 UTF-16 光标端点。
struct PuraPiMarkdownSelectionEndpoint: Equatable {
    let blockID: UUID
    let offset: Int
}

/// Markdown 编辑器的文档级选择。
///
/// `anchor` 是用户开始选择的位置，`focus` 是当前活动端点；两者可以跨越多个
/// block。选择模型只记录正文偏移，块级标记由对应 block 的 `kind` 在复制时补回。
struct PuraPiMarkdownSelection: Equatable {
    let anchor: PuraPiMarkdownSelectionEndpoint
    let focus: PuraPiMarkdownSelectionEndpoint

    var isCollapsed: Bool { anchor == focus }

    func orderedEndpoints(
        in blocks: [MarkdownBlock]
    ) -> (start: PuraPiMarkdownSelectionEndpoint, end: PuraPiMarkdownSelectionEndpoint)? {
        guard let anchorIndex = blocks.firstIndex(where: { $0.id == anchor.blockID }),
              let focusIndex = blocks.firstIndex(where: { $0.id == focus.blockID })
        else { return nil }
        if anchorIndex < focusIndex || (anchorIndex == focusIndex && anchor.offset <= focus.offset) {
            return (anchor, focus)
        }
        return (focus, anchor)
    }

    /// 返回某个 block 在当前选择中的正文范围；未被选中的 block 返回 nil。
    func bodyRange(
        for block: MarkdownBlock,
        in blocks: [MarkdownBlock]
    ) -> NSRange? {
        guard let ordered = orderedEndpoints(in: blocks),
              let startIndex = blocks.firstIndex(where: { $0.id == ordered.start.blockID }),
              let endIndex = blocks.firstIndex(where: { $0.id == ordered.end.blockID }),
              let blockIndex = blocks.firstIndex(where: { $0.id == block.id })
        else { return nil }
        guard blockIndex >= startIndex, blockIndex <= endIndex else { return nil }

        let length = block.displayText.utf16.count
        if startIndex == endIndex {
            let start = min(length, max(0, ordered.start.offset))
            let end = min(length, max(start, ordered.end.offset))
            return NSRange(location: start, length: end - start)
        }
        if blockIndex == startIndex {
            let start = min(length, max(0, ordered.start.offset))
            return NSRange(location: start, length: length - start)
        }
        if blockIndex == endIndex {
            let end = min(length, max(0, ordered.end.offset))
            return NSRange(location: 0, length: end)
        }
        return NSRange(location: 0, length: length)
    }
}
