import Foundation
import XCTest
@testable import PuraPi

/// Markdown 渲染成本，用于与 Pi TUI 做同文档对比。
///
/// 对比的是「同一份 Markdown 从文本到可布局结构」这一段：
/// TUI 侧调 `Markdown.render(width)` 得到行数组，PuraPi 侧调
/// `PuraPiMarkdownRenderer.render` 得到块结构。两边都不含终端转义生成，
/// 也都不含最终绘制。
///
/// 必须说明的差异：TUI 输出的是字符行，PuraPi 输出的是待交给 SwiftUI 的块，
/// 后者的真实屏幕成本还要加上 CoreText 测量与视图树构建
/// （见 `PuraPiViewportPerfTests`）。因此这里只能比较解析与结构化这一层。
@MainActor
final class PuraPiMarkdownCostTests: XCTestCase {
    /// 与 tui_bench.mjs 完全相同的文档生成规则。
    private func makeDoc(paragraphs: Int) -> String {
        var parts: [String] = []
        for index in 0..<paragraphs {
            parts.append("## 小节 \(index)")
            parts.append(
                "这是一段包含 `inline code` 与 **强调** 的正文，用于触发真实的行内解析与换行测量。序号 \(index)。"
            )
            parts.append("- 列表项一\n- 列表项二\n- 列表项三")
            parts.append("```swift\nlet value = compute(index: \(index))\nprint(value)\n```")
        }
        return parts.joined(separator: "\n\n")
    }

    private func medianRenderCost(_ text: String) -> (ms: Double, blocks: Int) {
        // 预热，与 Node 侧的 JIT 预热对应
        for _ in 0..<3 { _ = PuraPiMarkdownRenderer.render(text) }
        var samples: [(Double, Int)] = []
        for _ in 0..<5 {
            let start = Date()
            let result = PuraPiMarkdownRenderer.render(text)
            let blockCount = result.fallbackBlocks?.count ?? 0
            samples.append((Date().timeIntervalSince(start) * 1000, blockCount))
        }
        samples.sort { $0.0 < $1.0 }
        return (samples[2].0, samples[2].1)
    }

    func testMarkdownRenderCostAcrossSizes() {
        for paragraphs in [10, 40, 100, 250] {
            let text = makeDoc(paragraphs: paragraphs)
            let result = medianRenderCost(text)
            print(
                "PURAPI paragraphs=\(paragraphs) chars=\(text.count) "
                    + "median=\(String(format: "%.1f", result.ms))ms blocks=\(result.blocks)"
            )
        }
    }

    /// 成本必须随文档长度近似线性，不能出现平方级退化。
    func testRenderCostIsLinear() {
        let small = medianRenderCost(makeDoc(paragraphs: 40)).ms
        let large = medianRenderCost(makeDoc(paragraphs: 250)).ms
        let ratio = large / max(small, 0.001)
        print("PURAPI ratio(250/40)=\(String(format: "%.1f", ratio)) charRatio=6.4")
        XCTAssertLessThan(ratio, 15.0)
    }
}
