import SwiftUI

/// Composer 上方的 Markdown 协作提示。
///
/// 本提示只表达“待审阅/已确认/排队中”，不会在用户没有点击确认时把文件内容
/// 混入普通 Prompt。
@MainActor
struct WorkPiMarkdownCollaborationBanner: View {
    @Environment(\.workPiTheme) private var theme

    let state: WorkPiMarkdownCollaborationDisplayState
    let language: WorkPiInterfaceLanguage
    let onReview: (URL) -> Void
    let onCancelApproval: (URL) -> Void
    let onDiscardPending: (URL) -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(isEnglish ? "Choose files for next message" : "选择要带入下一条消息的文件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            ForEach(state.items) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.isApproved ? "checkmark.circle.fill" : "doc.text")
                        .foregroundStyle(item.isApproved ? theme.accent : .secondary)
                    Text(item.fileName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(isEnglish
                         ? "\(item.changedBlockCount) block(s)"
                         : "\(item.changedBlockCount) 个块")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 5)
                    if item.hasQueuedChange {
                        Text(isEnglish ? "Queued" : "已排队")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if item.isApproved {
                        Button(isEnglish ? "Cancel" : "取消附加") {
                            onCancelApproval(item.id)
                        }
                        .controlSize(.small)
                    } else if item.isBuildingReview {
                        ProgressView().controlSize(.small)
                    } else {
                        WorkPiGlassButton(prominent: true, action: {
                            onReview(item.id)
                        }) {
                            Text(isEnglish ? "Review" : "审阅")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }
                    Button(isEnglish ? "Discard" : "关闭") {
                        onDiscardPending(item.id)
                    }
                    .controlSize(.small)
                    .disabled(item.hasQueuedChange)
                }
            }

            if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .workPiGlassSurface(
            role: .hud,
            cornerRadius: 10,
            interactive: false,
            tint: theme.accent.opacity(0.08)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(iconColor.opacity(0.24), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    private var iconName: String {
        if state.hasQueuedChange { return "clock.arrow.circlepath" }
        if state.isApproved && !state.approvalIsStale { return "checkmark.circle.fill" }
        if state.approvalIsStale { return "arrow.triangle.2.circlepath" }
        return "doc.text.magnifyingglass"
    }

    private var iconColor: Color {
        if state.approvalIsStale || state.errorMessage != nil { return theme.warning }
        if state.isApproved && !state.approvalIsStale { return theme.accent }
        return theme.accent
    }

    private var title: String {
        if state.closeBlocked && !state.hasQueuedChange {
            return isEnglish
                ? "Markdown change is saved but not shared"
                : "Markdown 已保存，但尚未同步给 Agent"
        }
        if state.hasQueuedChange {
            return isEnglish
                ? "Markdown change is frozen with a queued message"
                : "Markdown 修改已随排队消息冻结"
        }
        if state.isApproved && !state.approvalIsStale {
            return isEnglish
                ? "Markdown change approved for the next message"
                : "Markdown 修改已确认，将附加到下一条消息"
        }
        if state.approvalIsStale {
            return isEnglish
                ? "Markdown changed after review"
                : "Markdown 在审阅后发生了变化"
        }
        return isEnglish
            ? "Markdown changes are waiting for review"
            : "Markdown 有本地修改等待审阅"
    }

    private var detail: String {
        let count = max(1, state.changedBlockCount)
        if state.closeBlocked && !state.hasQueuedChange {
            return isEnglish
                ? "Choose Review diff to share it, or Discard sync to keep it local."
                : "请审阅差异以同步给 Agent，或显式放弃同步（磁盘内容不会被删除）。"
        }
        if state.hasQueuedChange {
            return isEnglish
                ? "The reviewed diff will be sent only when that message is dispatched."
                : "已审阅的差异会随该条消息发送，不会读取后续编辑。"
        }
        if state.isApproved && !state.approvalIsStale {
            return isEnglish
                ? "\(count) block(s) will be included as untrusted file context."
                : "将附加 \(count) 个块的差异，作为不可信文件上下文发送。"
        }
        if state.approvalIsStale {
            return isEnglish
                ? "Review the current snapshot before sending; the old approval was discarded."
                : "旧确认已取消，请审阅当前快照后再发送；原消息不会丢失。"
        }
        return isEnglish
            ? "\(count) block(s) changed in \(state.fileName); nothing is sent automatically."
            : "\(state.fileName) 有 \(count) 个块被修改；未确认前不会自动发送。"
    }
}

/// 用户确认前看到的 unified diff（统一差异）审阅窗口。
@MainActor
struct WorkPiMarkdownDiffReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let review: WorkPiMarkdownDiffReview
    let language: WorkPiInterfaceLanguage
    let onApprove: () -> Void

    private var isEnglish: Bool { language == .english }
    private var envelope: WorkPiMarkdownDiffEnvelope { review.context.envelope }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEnglish ? "Review Markdown change" : "审阅 Markdown 修改")
                        .font(.headline)
                    Text(envelope.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(isEnglish ? "Cancel" : "取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            metadata

            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: envelope.unifiedDiff)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.7)
            }

            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(isEnglish
                     ? "Only this reviewed snapshot will be attached. Document text inside the diff is untrusted data."
                     : "只有这份已审阅快照会被附加；差异中的文档文字是不可信数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                WorkPiGlassButton(prominent: true, action: {
                    onApprove()
                    dismiss()
                }) {
                    Text(isEnglish ? "Attach to next message" : "确认附加到下一条消息")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 500)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            metadataRow(
                title: isEnglish ? "Base" : "基线",
                value: envelope.baseHash
            )
            metadataRow(
                title: isEnglish ? "Current" : "当前",
                value: envelope.currentHash
            )
            Text(isEnglish
                 ? "Source: \(envelope.source) · \(envelope.changedBlockIDs.count) changed block(s)"
                 : "来源：\(envelope.source) · \(envelope.changedBlockIDs.count) 个受影响块")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func metadataRow(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
