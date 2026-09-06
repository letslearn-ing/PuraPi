import AppKit
import PiDomain
import XCTest
@testable import WorkPi

/// 长对话的布局成本基准。
///
/// 直接驱动真实 `WorkPiConversationViewportView`，不使用替身——要测的正是
/// 它为每条消息创建 `NSHostingView` 并逐行测量高度的真实开销。
@MainActor
final class WorkPiViewportPerfTests: XCTestCase {
    private func makeItems(_ count: Int) -> [ConversationItem] {
        var items: [ConversationItem] = []
        let userBody = String(repeating: "请解释一下这个问题。", count: 3)
        let assistantBody = String(repeating: "这是回答的一段内容，包含足够长度以触发换行测量。", count: 6)
        for index in 0..<count {
            let isUser = index % 2 == 0
            items.append(
                ConversationItem(
                    kind: isUser ? .user : .assistant,
                    text: isUser ? "\(userBody) #\(index)" : "\(assistantBody) #\(index)"
                )
            )
        }
        return items
    }

    /// 驱动一次完整的 update + 布局，返回耗时毫秒。
    private func measureLayout(itemCount: Int) -> Double {
        let viewport = WorkPiConversationViewportView()
        viewport.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: viewport.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(viewport)

        let items = makeItems(itemCount)
        let start = Date()
        viewport.update(items: items, language: .chinese)
        viewport.layoutSubtreeIfNeeded()
        let elapsed = Date().timeIntervalSince(start) * 1000
        viewport.detach()
        return elapsed
    }

    /// 真实会话规模下的首屏成本。
    ///
    /// 本机最大真实会话 168 条 entry，这是当前需要保证的量级；
    /// 上千条属于极端情况，用 `testLayoutCostScaling` 单独观察增长趋势。
    func testRealisticSessionLayoutCost() {
        let elapsed = measureLayout(itemCount: 200)
        print("VIEWPORT PERF realistic200=\(fmt(elapsed))ms")
        // 首屏一次性构建；超过 1.5 秒用户会明显感到卡顿。
        XCTAssertLessThan(elapsed, 1_500)
    }

    /// 记录不同规模的布局成本，并检查增长是否近似线性。
    ///
    /// 线性是这套实现的前提：document view 逐行摆放，没有行复用。
    /// 若出现超线性增长，说明某处引入了每行 O(n) 的操作。
    func testLayoutCostScaling() {
        let small = measureLayout(itemCount: 100)
        let medium = measureLayout(itemCount: 400)
        let large = measureLayout(itemCount: 1_000)

        print("VIEWPORT PERF 100=\(fmt(small))ms 400=\(fmt(medium))ms 1000=\(fmt(large))ms")
        let ratio = large / max(medium, 0.001)
        print("VIEWPORT PERF ratio(1000/400)=\(fmt(ratio)) itemRatio=2.5")

        // 允许常数因子波动，但不能出现平方级增长。
        XCTAssertLessThan(ratio, 6.0, "布局成本增长显著超过条目增长，疑似引入了每行 O(n) 操作")
    }

    /// 单次增量更新（新增一条消息）不应重排全部行的 SwiftUI 树。
    func testIncrementalAppendIsCheap() {
        let viewport = WorkPiConversationViewportView()
        viewport.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: viewport.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(viewport)

        var items = makeItems(600)
        viewport.update(items: items, language: .chinese)
        viewport.layoutSubtreeIfNeeded()

        items.append(ConversationItem(kind: .user, text: "追加的一条消息"))
        let start = Date()
        viewport.update(items: items, language: .chinese)
        viewport.layoutSubtreeIfNeeded()
        let elapsed = Date().timeIntervalSince(start) * 1000

        print("VIEWPORT PERF incrementalAppend=\(fmt(elapsed))ms base=600")
        viewport.detach()
        // 增量更新应远快于全量构建；给出宽裕上限只为捕捉数量级退化。
        XCTAssertLessThan(elapsed, 900)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
