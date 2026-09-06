import PiDomain
import SwiftUI

/// 对话内搜索的状态与匹配逻辑。
@MainActor
final class WorkPiConversationSearchState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published private(set) var matches: [UUID] = []
    @Published private(set) var currentIndex = 0

    /// 当前应滚动到的消息。
    var currentMatch: UUID? {
        guard matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var matchSummary: String {
        // 用去空白后的查询词判断：纯空格不算有效查询，
        // 否则会显示成「0 个匹配」，看着像搜索失败。
        guard !trimmedQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return "0" }
        return "\(currentIndex + 1)/\(matches.count)"
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 重新计算匹配。
    ///
    /// 只搜正文，不搜 detail：工具调用的原始参数往往包含大段 JSON，
    /// 匹配到那里对用户没有意义，还会把命中数量冲淡。
    func update(items: [ConversationItem]) {
        let needle = trimmedQuery
        guard !needle.isEmpty else {
            if !matches.isEmpty { matches = [] }
            if currentIndex != 0 { currentIndex = 0 }
            return
        }
        let previous = currentMatch
        let nextMatches = items
            .filter { $0.text.localizedCaseInsensitiveContains(needle) }
            .map(\.id)
        // 尽量保持当前位置：输入过程中命中集合会变，
        // 每次跳回第一条会让用户失去阅读位置。
        let nextIndex: Int
        if let previous, let index = nextMatches.firstIndex(of: previous) {
            nextIndex = index
        } else {
            nextIndex = 0
        }
        if matches != nextMatches { matches = nextMatches }
        if currentIndex != nextIndex { currentIndex = nextIndex }
    }

    func moveToNext() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    func moveToPrevious() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    func dismiss() {
        isPresented = false
        query = ""
        matches = []
        currentIndex = 0
    }
}

extension Notification.Name {
    /// Cmd+F：打开对话内搜索。
    static let workPiFindInConversation = Notification.Name("WorkPi.findInConversation")
}

/// 对话搜索条。
///
/// 位置在对话区顶部悬浮，与 Safari/Xcode 的查找栏一致——用户按 Cmd+F 时
/// 视线本来就在内容区，把输入框放到别处会打断这个动作。
@MainActor
struct WorkPiConversationSearchBar: View {
    @Environment(\.workPiTheme) private var theme
    @ObservedObject var state: WorkPiConversationSearchState
    let language: WorkPiInterfaceLanguage

    @FocusState private var isFocused: Bool

    private var isEnglish: Bool { language == .english }

    /// 有查询词但零命中：用橙色提示，避免用户以为搜索没生效。
    private var noMatches: Bool {
        state.matches.isEmpty && !state.matchSummary.isEmpty
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(
                isEnglish ? "Search conversation" : "搜索对话",
                text: $state.query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(width: 200)
            .focused($isFocused)
            .onSubmit { state.moveToNext() }
            // Esc 必须挂在输入框上：焦点在 TextField 时它自己会消费
            // Escape，外层的 `onExitCommand` 不会触发。
            .onKeyPress(.escape) {
                state.dismiss()
                return .handled
            }

            Text(state.matchSummary)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(noMatches ? theme.warning : Color.secondary.opacity(0.6))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)

            Button(action: state.moveToPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(state.matches.isEmpty)
            .help(isEnglish ? "Previous match" : "上一个匹配")

            Button(action: state.moveToNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(state.matches.isEmpty)
            .help(isEnglish ? "Next match" : "下一个匹配")

            Button(action: state.dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Close (Esc)" : "关闭（Esc）")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        // 搜索条悬浮在正文之上，必须自带不透明底：
        // 只用 .hud 玻璃时文字会与背后的对话内容叠在一起，几乎读不清。
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.searchBarBackground)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 0.5)
        )
        .onAppear {
            // `onAppear` 里直接置焦点在 overlay 中不生效：此时视图还没进入
            // 响应链。推到下一个主线程周期才能真正拿到键盘焦点，否则用户
            // 输入的字会落到下方的输入框里。
            DispatchQueue.main.async { isFocused = true }
        }
        // 焦点不在输入框时（例如点过按钮）仍然响应 Esc。
        .onExitCommand { state.dismiss() }
    }
}
