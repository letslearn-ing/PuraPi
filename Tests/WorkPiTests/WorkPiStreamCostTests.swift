import XCTest
@testable import WorkPi

/// 逐行提交的实测成本；仅用于确认没有引入 O(n²) 回退。
final class WorkPiStreamCostTests: XCTestCase {
    func testStreamingCostStaysLinear() {
        func build(paragraphs: Int) -> String {
            var out = ""
            for p in 0..<paragraphs {
                out += "## 小节 \(p)\n\n"
                for l in 0..<4 { out += "这是第 \(p) 段第 \(l) 行的说明文字。\n" }
                out += "\n"
                if p % 3 == 0 { out += "- 甲\n- 乙\n\n```swift\nlet a = \(p)\n```\n\n" }
            }
            return out
        }

        var results: [(Int, Double, Int)] = []
        for paragraphs in [25, 50, 100] {
            let source = build(paragraphs: paragraphs)
            var state = WorkPiIncrementalMarkdownState()
            var accumulated = ""
            let start = DispatchTime.now()
            for character in source {
                accumulated.append(character)
                state.update(accumulated)
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            results.append((source.count, ms, state.stableBlocks.count))
            print(String(format: "COST chars=%6d ms=%8.1f blocks=%4d", source.count, ms, state.stableBlocks.count))
        }

        // 字符数增长时耗时应接近等比。阈值取字符比的 1.5 倍：
        // 既容纳常数开销与调度波动，又能在退化为二次复杂度时立即失败。
        let (c1, t1, _) = results[0]
        let (c2, t2, _) = results[2]
        let charRatio = Double(c2) / Double(c1)
        let timeRatio = t2 / max(t1, 0.001)
        print(String(format: "COST charRatio=%.2f timeRatio=%.2f", charRatio, timeRatio))
        XCTAssertLessThan(
            timeRatio,
            charRatio * 1.5,
            "流式增量解析应保持线性；charRatio=\(charRatio) timeRatio=\(timeRatio)"
        )
    }
}
