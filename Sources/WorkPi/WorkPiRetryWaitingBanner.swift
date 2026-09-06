import PiDomain
import SwiftUI

/// 仅在 Pi 正等待自动重试退避时出现；它不是常驻状态面板。
@MainActor
struct WorkPiRetryWaitingBanner: View {
    @Environment(\.workPiTheme) private var theme

    let wait: WorkPiRetryWaitState
    let language: WorkPiInterfaceLanguage
    let isCancelling: Bool
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(isCancelling
                ? (language == .english ? "Cancelling…" : "取消中…")
                : (language == .english ? "Cancel retry" : "取消重试")) {
                onCancel()
            }
            .buttonStyle(.borderless)
            .disabled(!canCancel || isCancelling)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .workPiGlassSurface(
            role: .glass,
            cornerRadius: 10,
            tint: theme.accent.opacity(0.06)
        )
    }

    private var label: String {
        let attempt: String
        if let current = wait.attempt, let max = wait.maxAttempts {
            attempt = "\(current)/\(max)"
        } else {
            attempt = "—"
        }
        return language == .english
            ? "Pi is waiting to retry (\(attempt))"
            : "Pi 正在等待自动重试（\(attempt)）"
    }
}
