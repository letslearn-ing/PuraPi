import Foundation
import PiDomain

struct WorkPiMarkdownOutlineItem: Identifiable, Equatable {
    let id: UUID
    let level: Int
    let title: String

    var indent: CGFloat { CGFloat(max(0, level - 1)) * 10 }
}

enum WorkPiMarkdownOutline {
    static func items(from blocks: [MarkdownBlock]) -> [WorkPiMarkdownOutlineItem] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let title = block.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return WorkPiMarkdownOutlineItem(id: block.id, level: level, title: title)
        }
    }
}
