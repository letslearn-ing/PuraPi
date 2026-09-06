import PiDomain
import SwiftUI

/// `/status` 中的 Runtime 状态区块。只有用户主动执行 `/status` 时才出现。
@MainActor
struct PuraPiRuntimeStatusPanel: View {
    @Environment(\.puraPiTheme) private var theme

    let snapshot: PuraPiRuntimeStatusSnapshot?
    let loading: Bool
    let error: String?
    let controlError: String?
    let autoRetryEnabled: Bool?
    let retryWait: PuraPiRetryWaitState?
    let turns: [PuraPiTurnRecord]
    let language: PuraPiInterfaceLanguage
    let canSetAutoRetry: Bool
    let isSettingAutoRetry: Bool
    let canAbortRetry: Bool
    let isAbortingRetry: Bool
    let onRefresh: () -> Void
    let onSetAutoRetry: (Bool) -> Void
    let onAbortRetry: () -> Void
    let onDismiss: () -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.error)
            }
            if let snapshot {
                stateGrid(snapshot)
            } else if loading {
                Text(isEnglish ? "Reading Runtime state…" : "正在读取 Runtime 状态…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text(isEnglish ? "No Runtime snapshot." : "暂无 Runtime 快照。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            retryControls
            if !turns.isEmpty {
                Divider().opacity(0.4)
                turnSection
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .puraPiGlassSurface(
            role: .glass,
            cornerRadius: 11,
            tint: theme.accent.opacity(0.06)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(isEnglish ? "Runtime status" : "Runtime 状态")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if loading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .help(isEnglish ? "Refresh Runtime state" : "刷新 Runtime 状态")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Close" : "关闭")
        }
    }

    private func stateGrid(_ snapshot: PuraPiRuntimeStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                valueRow(isEnglish ? "Model" : "模型", snapshot.modelName ?? "—")
                valueRow(isEnglish ? "Thinking" : "推理", snapshot.thinkingLevel ?? "—")
            }
            HStack(spacing: 12) {
                valueRow(isEnglish ? "Streaming" : "流式", boolean(snapshot.isStreaming))
                valueRow(isEnglish ? "Compacting" : "压缩", boolean(snapshot.isCompacting))
            }
            HStack(spacing: 12) {
                valueRow(isEnglish ? "Messages" : "消息", number(snapshot.messageCount))
                valueRow(isEnglish ? "Pending" : "排队", number(snapshot.pendingMessageCount))
            }
            HStack(spacing: 12) {
                valueRow(isEnglish ? "Steering" : "Steer 队列", snapshot.steeringMode ?? "—")
                valueRow(isEnglish ? "Follow-up" : "Follow-up 队列", snapshot.followUpMode ?? "—")
            }
            if let sessionName = snapshot.sessionName, !sessionName.isEmpty {
                valueRow(isEnglish ? "Session" : "会话", sessionName)
            }
            Text(
                isEnglish
                    ? "Sampled \(snapshot.sampledAt.formatted(date: .omitted, time: .standard))"
                    : "采样于 \(snapshot.sampledAt.formatted(date: .omitted, time: .standard))"
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private var retryControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Text(isEnglish ? "Auto retry" : "自动重试")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(autoRetryLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 0)
                Button(isEnglish ? "On" : "开启") { onSetAutoRetry(true) }
                    .buttonStyle(.borderless)
                    .disabled(!canSetAutoRetry || isSettingAutoRetry || autoRetryEnabled == true)
                Button(isEnglish ? "Off" : "关闭") { onSetAutoRetry(false) }
                    .buttonStyle(.borderless)
                    .disabled(!canSetAutoRetry || isSettingAutoRetry || autoRetryEnabled == false)
            }
            Text(
                isEnglish
                    ? "Pi 0.84.4 does not expose this setting through get_state."
                    : "Pi 0.84.4 不通过 get_state 回读此设置；这里只显示本连接最近一次成功设置。"
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            if let retryWait {
                HStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(theme.accent)
                    Text(retryLabel(retryWait))
                        .font(.system(size: 10))
                    Spacer(minLength: 0)
                    Button(isEnglish ? "Cancel retry" : "取消重试") { onAbortRetry() }
                        .buttonStyle(.borderless)
                        .disabled(!canAbortRetry || isAbortingRetry)
                }
            }
            if let controlError, !controlError.isEmpty {
                Text(controlError)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.error)
            }
        }
    }

    private var turnSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isEnglish ? "Recent turns" : "最近回合")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(turns.suffix(6))) { turn in
                HStack(spacing: 6) {
                    Text("#\(turn.index + 1)")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(turnOutcomeLabel(turn.outcome))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    if let duration = turn.duration {
                        Text(String(format: "%.2fs", duration))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    if let toolResultCount = turn.toolResultCount, toolResultCount > 0 {
                        Text(isEnglish ? "\(toolResultCount) tools" : "工具 \(toolResultCount)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var autoRetryLabel: String {
        if isSettingAutoRetry { return isEnglish ? "Applying…" : "设置中…" }
        guard let autoRetryEnabled else { return isEnglish ? "Unknown" : "未确认" }
        return autoRetryEnabled ? (isEnglish ? "On" : "开启") : (isEnglish ? "Off" : "关闭")
    }

    private func retryLabel(_ retry: PuraPiRetryWaitState) -> String {
        let attempt: String
        if let current = retry.attempt, let max = retry.maxAttempts {
            attempt = "\(current)/\(max)"
        } else {
            attempt = "—"
        }
        return isEnglish ? "Waiting to retry (\(attempt))" : "等待自动重试（\(attempt)）"
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boolean(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value
            ? (isEnglish ? "Yes" : "是")
            : (isEnglish ? "No" : "否")
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func turnOutcomeLabel(_ outcome: PuraPiTurnOutcome) -> String {
        switch outcome {
        case .running: return isEnglish ? "running" : "运行中"
        case .completed: return isEnglish ? "completed" : "已完成"
        case .failed: return isEnglish ? "failed" : "失败"
        case .cancelled: return isEnglish ? "cancelled" : "已取消"
        }
    }
}
