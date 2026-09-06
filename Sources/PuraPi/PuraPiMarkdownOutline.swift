import Foundation
import PiDomain

struct PuraPiMarkdownOutlineItem: Identifiable, Equatable {
    let id: UUID
    let level: Int
    let title: String

    var indent: CGFloat { CGFloat(max(0, level - 1)) * 10 }
}

enum PuraPiMarkdownOutline {
    static func items(from blocks: [MarkdownBlock]) -> [PuraPiMarkdownOutlineItem] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let title = block.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return PuraPiMarkdownOutlineItem(id: block.id, level: level, title: title)
        }
    }
}
