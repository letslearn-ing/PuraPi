import PiDomain
import SwiftUI

/// Sidebar 的会话树：项目内的多个会话，展开后是该会话的多轮对话。
///
/// 会话列表来自磁盘扫描，因此这里也能看到其他会话；单击只预览，双击才切换，
/// 避免误触打断正在运行的任务。
struct SessionTreePane: View {
    let sessions: [PiSessionSummary]
    let turns: [String: [PiSessionTurn]]
    let activeSessionPath: String?
    let previewedSessionID: String?
    let language: PuraPiInterfaceLanguage
    let onPreview: (PiSessionSummary) -> Void
    /// 只补加载轮次，不改变预览高亮。切换会话清空缓存后由展开中的行自愈调用。
    let onRequestTurns: (PiSessionSummary) -> Void
    let onSwitch: (PiSessionSummary) -> Void
    let onFork: (PiSessionTurn) -> Void
    let onRename: (PiSessionSummary) -> Void
    let onClone: (PiSessionSummary) -> Void
    /// 双击某一轮：定位到它。会话未打开时先切换会话再定位。
    let onOpenTurn: (PiSessionSummary, PiSessionTurn) -> Void

    @State private var expandedSessionIDs: Set<String> = []

    private var isEnglish: Bool { language == .english }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 轮次时间：同一会话内多在同一天，只显示时分更省空间。
    private static let turnTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(isEnglish ? "Sessions" : "会话")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var list: some View {
        ScrollView {
            PuraPiLegacyScrollEdgeEffectMarker()

            LazyVStack(alignment: .leading, spacing: 1) {
                if sessions.isEmpty {
                    Text(isEnglish ? "No sessions yet" : "还没有会话")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }

                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isActive: session.fileURL.path == activeSessionPath,
                        isPreviewed: session.id == previewedSessionID,
                        isExpanded: expandedSessionIDs.contains(session.id),
                        title: session.displayTitle(dateFormatter: Self.dateFormatter),
                        subtitle: subtitle(for: session),
                        isEnglish: isEnglish,
                        onToggle: { toggle(session) },
                        onSwitch: { onSwitch(session) },
                        onRename: { onRename(session) },
                        onClone: { onClone(session) }
                    )

                    if expandedSessionIDs.contains(session.id) {
                        turnRows(for: session)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .puraPiTopScrollEdgeEffect()
    }

    @ViewBuilder
    private func turnRows(for session: PiSessionSummary) -> some View {
        let loaded = turns[session.id]
        if let loaded {
            if loaded.isEmpty {
                Text(isEnglish ? "No messages" : "没有对话")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 34)
                    .padding(.vertical, 3)
            } else {
                ForEach(loaded) { turn in
                    TurnRow(
                        turn: turn,
                        time: Self.turnTimeFormatter.string(from: turn.timestamp),
                        isEnglish: isEnglish,
                        canFork: session.fileURL.path == activeSessionPath,
                        onFork: { onFork(turn) },
                        onOpen: { onOpenTurn(session, turn) }
                    )
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                Text(isEnglish ? "Loading…" : "读取中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 34)
            .padding(.vertical, 3)
            // 切换会话会清空轮次缓存（活动分支可能已变），但展开状态会保留。
            // 此时必须重新请求一次，否则无人触发加载，转圈会永远停在这里。
            .task(id: session.id) {
                onRequestTurns(session)
            }
        }
    }

    /// 副标题显示创建时间：用户识别会话靠「什么时候开的」，消息条数帮助不大。
    private func subtitle(for session: PiSessionSummary) -> String {
        let created = Self.dateFormatter.string(from: session.createdAt)
        // 派生会话标注来源，帮助用户理解 fork/clone 产生的会话。
        if session.parentSessionPath != nil {
            return isEnglish ? "\(created) · forked" : "\(created) · 派生"
        }
        return created
    }

    private func toggle(_ session: PiSessionSummary) {
        // 单击既选中也切换展开状态；预览始终跟随最后一次点击。
        onPreview(session)
        if expandedSessionIDs.contains(session.id) {
            expandedSessionIDs.remove(session.id)
        } else {
            expandedSessionIDs.insert(session.id)
        }
    }
}

/// 会话行。
private struct SessionRow: View {
    @Environment(\.puraPiTheme) private var theme

    let session: PiSessionSummary
    let isActive: Bool
    let isPreviewed: Bool
    let isExpanded: Bool
    let title: String
    let subtitle: String
    let isEnglish: Bool
    let onToggle: () -> Void
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onClone: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            // 展开箭头只做视觉指示；命中区域是整行，不能要求用户
            // 精准点中倒三角。
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 22)

            Image(systemName: isActive ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(isActive ? theme.accent : .secondary)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isActive {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 5, height: 5)
                    .help(isEnglish ? "Current session" : "当前会话")
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(rowBackground)
        // 单击展开/收起并预览，双击切换：避免误触打断正在运行的任务。
        .onTapGesture(count: 2, perform: onSwitch)
        .onTapGesture(perform: onToggle)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "当前会话" : (isPreviewed ? "已预览" : ""))
        .accessibilityAction {
            onToggle()
        }
        .accessibilityAction(named: "切换会话") {
            onSwitch()
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isEnglish ? "Switch to This Session" : "切换到这个会话", action: onSwitch)
            Button(isEnglish ? "Duplicate Session" : "复制为新会话", action: onClone)
                // clone 复制的是 Pi 当前会话，因此只对当前会话可用。
                .disabled(!isActive)
            Divider()
            Button(isEnglish ? "Rename…" : "重命名…", action: onRename)
                .disabled(!isActive)
        }
        .help(session.fileURL.lastPathComponent)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isPreviewed {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.accent.opacity(0.23))
        } else if isHovering {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.accent.opacity(0.10))
        } else {
            Color.clear
        }
    }
}

/// 会话内的一轮对话。
private struct TurnRow: View {
    @Environment(\.puraPiTheme) private var theme

    let turn: PiSessionTurn
    let time: String
    let isEnglish: Bool
    let canFork: Bool
    let onFork: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(turn.text)
                    .font(.system(size: 11.5))
                    // 废弃分支用降级样式表达，不直接隐藏：用户需要知道它存在。
                    .foregroundStyle(turn.isOnActiveBranch ? .secondary : .tertiary)
                    .strikethrough(!turn.isOnActiveBranch, color: Color.secondary.opacity(0.6))
                    .lineLimit(1)
                Text(time)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if turn.responseCount > 0 {
                Text("\(turn.responseCount)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 37)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.accent.opacity(0.10))
            }
        }
        // 双击定位到这一轮；会话未打开时先切换再定位。
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(turn.text)
        .accessibilityValue(time)
        .accessibilityAction {
            onOpen()
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isEnglish ? "Open This Turn" : "打开这一轮", action: onOpen)
            // fork 只能作用于当前会话的活动分支。
            Button(isEnglish ? "Start Over From Here" : "从这里重新开始", action: onFork)
                .disabled(!canFork)
        }
        .help(turn.text)
    }
}
