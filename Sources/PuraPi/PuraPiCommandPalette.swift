import SwiftUI

/// Composer 输入 `/` 后显示的原生命令选择器。
enum PuraPiCommandPaletteScrollPolicy {
    static let visibleRowCount = 5
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 2
    static let contentPadding: CGFloat = 6

    static var viewportHeight: CGFloat {
        CGFloat(visibleRowCount) * rowHeight
            + CGFloat(visibleRowCount - 1) * rowSpacing
            + contentPadding * 2
    }

    /// 根据当前真实滚动窗口计算新的首行；选中项仍在 5 行窗口内时返回 nil。
    /// 首行由 View 持有，而不是从选中索引反推，避免向上移动时丢失滚动偏移。
    static func targetFirstVisibleIndex(
        selectedIndex: Int,
        currentFirstVisibleIndex: Int,
        resultCount: Int
    ) -> Int? {
        guard resultCount > 0,
              selectedIndex >= 0,
              selectedIndex < resultCount
        else { return nil }

        let maximumFirst = max(0, resultCount - visibleRowCount)
        let first = min(max(currentFirstVisibleIndex, 0), maximumFirst)
        let last = min(resultCount - 1, first + visibleRowCount - 1)
        if selectedIndex < first {
            return selectedIndex
        }
        if selectedIndex > last {
            return min(selectedIndex - visibleRowCount + 1, maximumFirst)
        }
        return nil
    }
}

/// Composer 输入 `/` 后显示的原生命令选择器。
struct PuraPiCommandPalette: View {
    @Environment(\.puraPiTheme) private var theme

    let commands: [PuraPiCommandItem]
    let query: String
    @Binding var selectedIndex: Int
    let language: PuraPiInterfaceLanguage
    let onSelect: (PuraPiCommandItem) -> Void

    @State private var firstVisibleIndex = 0

    private var filteredCommands: [PuraPiCommandItem] {
        PuraPiCommandCatalog.filtered(commands, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language == .english ? "Commands" : "命令")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(language == .english ? "↑↓  Select   Return  Confirm" : "↑↓ 选择 · Return 确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.45)

            if filteredCommands.isEmpty {
                Text(language == .english ? "No matching commands" : "没有匹配的命令")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 命令数量通常很小；使用普通 VStack 让 ScrollViewReader 在
                        // macOS 26 上能稳定测量所有目标行，避免 LazyVStack 对尚未创建的
                        // 第六项调用 scrollTo 时无效。
                        VStack(spacing: PuraPiCommandPaletteScrollPolicy.rowSpacing) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                Button {
                                    onSelect(command)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(command.invocation)
                                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .frame(width: 125, alignment: .leading)

                                        Text(command.description)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        if command.source != "purapi" {
                                            Text(command.sourceLabel(language: language))
                                                .font(.system(size: 9.5, design: .rounded))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(
                                        height: PuraPiCommandPaletteScrollPolicy.rowHeight,
                                        alignment: .center
                                    )
                                    .background(
                                        index == selectedIndex
                                            ? theme.accent.opacity(0.20)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(command.id)
                                .onHover { hovering in
                                    if hovering { selectedIndex = index }
                                }
                            }
                        }
                        .padding(PuraPiCommandPaletteScrollPolicy.contentPadding)
                    }
                    .frame(height: PuraPiCommandPaletteScrollPolicy.viewportHeight)
                    .onChange(of: selectedIndex) { _, newIndex in
                        scrollToSelection(newIndex, using: proxy)
                    }
                    .onChange(of: query) { _, _ in
                        selectedIndex = min(
                            selectedIndex,
                            max(filteredCommands.count - 1, 0)
                        )
                        firstVisibleIndex = 0
                        scrollToSelection(selectedIndex, using: proxy)
                    }
                    .onAppear {
                        // 初次展开从首行开始计算；只有当前选择超过第五项时才滚动。
                        firstVisibleIndex = 0
                        scrollToSelection(selectedIndex, using: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .puraPiGlassSurface(
            role: .glass,
            cornerRadius: 12,
            interactive: true,
            tint: theme.accent.opacity(0.045)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language == .english ? "Command suggestions" : "命令建议")
    }

    private func scrollToSelection(
        _ index: Int,
        using proxy: ScrollViewProxy
    ) {
        guard filteredCommands.indices.contains(index),
              let targetFirst = PuraPiCommandPaletteScrollPolicy.targetFirstVisibleIndex(
                  selectedIndex: index,
                  currentFirstVisibleIndex: firstVisibleIndex,
                  resultCount: filteredCommands.count
              )
        else { return }

        // 面板视口固定为 5 行。保持 0...4 直接可见；只有越过底部第五行
        // 或顶部第一行时才滚动，避免第三项开始因 `anchor: .center`
        // 被提前重定位。
        let previousFirstVisibleIndex = firstVisibleIndex
        firstVisibleIndex = targetFirst
        let targetIndex = index
        let id = filteredCommands[targetIndex].id
        let anchor: UnitPoint = targetFirst < previousFirstVisibleIndex ? .top : .bottom
        // 等一轮布局，确保刚进入可视范围的行已经注册到 ScrollViewReader。
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    func command(at index: Int) -> PuraPiCommandItem? {
        guard filteredCommands.indices.contains(index) else { return nil }
        return filteredCommands[index]
    }

    var count: Int { filteredCommands.count }
}
