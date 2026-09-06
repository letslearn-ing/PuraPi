import AppKit
import PiDomain
import PiRPC
import SwiftUI

/// Composer 下方的 Runtime 状态条。
///
/// 模型与推理强度是可点击的下拉项，可选集合完全来自 Pi（`get_available_models`
/// 与 `get_available_thinking_levels`）；上下文与项目路径是只读展示。

struct RuntimeHUD: View {
    let metadata: AgentRuntimeMetadata
    let language: PuraPiInterfaceLanguage
    let workspacePath: String
    let availableModels: [PiRPCModelInfo]
    let availableThinkingLevels: [String]
    let isModelSwitching: Bool
    let isThinkingLevelSwitching: Bool
    let supportsThinkingLevelSelection: Bool
    let onSelectModel: (PiRPCModelInfo) -> Void
    let onSelectThinkingLevel: (String) -> Void
    /// 压缩当前上下文。Agent 运行中不可用。
    let onCompactContext: () -> Void
    let canCompactContext: Bool
    /// 自动压缩开关。nil 表示尚未从 Pi 读到状态。
    let autoCompactionEnabled: Bool?
    let onToggleAutoCompaction: (Bool) -> Void
    let canToggleAutoCompaction: Bool
    /// 导出当前会话为 HTML。
    let onExportSession: () -> Void
    let isExporting: Bool

    var body: some View {
        HStack(spacing: 0) {
            HUDMenuValue(
                label: language == .english ? "Model" : "模型",
                value: metadata.modelName ?? (language == .english ? "Loading…" : "读取中…"),
                icon: "cpu",
                language: language,
                isBusy: isModelSwitching,
                disabledHint: language == .english
                    ? "Pi has not reported available models"
                    : "Pi 尚未报告可用模型",
                options: modelOptions,
                onSelect: selectModel(withKey:)
            )

            HUDDivider()

            HUDMenuValue(
                label: language == .english ? "Reasoning" : "推理",
                value: metadata.thinkingLevel.map {
                    Self.displayThinkingLevel($0, language: language)
                } ?? (language == .english ? "Loading…" : "读取中…"),
                icon: "sparkles",
                language: language,
                isBusy: isThinkingLevelSwitching,
                disabledHint: metadata.modelSupportsReasoning == false
                    ? (language == .english
                        ? "This model does not support reasoning"
                        : "当前模型不支持推理")
                    : (language == .english
                        ? "Pi has not reported reasoning levels"
                        : "Pi 尚未报告可用推理强度"),
                options: thinkingLevelOptions,
                onSelect: onSelectThinkingLevel
            )

            HUDDivider()

            // 上下文只做展示；两个动作并排跟在它后面，作用对象一目了然。
            HUDValue(
                label: language == .english ? "Context" : "上下文",
                value: contextValue,
                icon: "text.alignleft"
            )

            HUDIconButton(
                icon: "arrow.down.right.and.arrow.up.left",
                help: canCompactContext
                    ? (language == .english
                        ? "Compact the current context now"
                        : "立即压缩当前上下文")
                    : (language == .english
                        ? "Agent is running; compaction is unavailable"
                        : "Agent 正在运行，暂时不能压缩上下文"),
                isActive: false,
                isEnabled: canCompactContext,
                action: onCompactContext
            )

            // 自动压缩是开关而非一次性动作，用图标的实心/描线区分状态。
            HUDIconButton(
                icon: isAutoCompactionEnabled
                    ? "arrow.triangle.2.circlepath.circle.fill"
                    : "arrow.triangle.2.circlepath.circle",
                help: autoCompactionHelp,
                isActive: isAutoCompactionEnabled,
                isEnabled: canToggleAutoCompaction,
                action: { onToggleAutoCompaction(!isAutoCompactionEnabled) }
            )

            HUDDivider()

            HUDValue(
                label: language == .english ? "Project" : "项目",
                value: abbreviatedWorkspacePath,
                icon: "folder"
            )

            HUDDivider()

            // 导出只作用于当前会话（协议无 session 参数），因此入口留在
            // 当前对话语境里，而不是文件菜单。
            HUDActionButton(
                label: language == .english ? "Export" : "导出",
                value: isExporting
                    ? (language == .english ? "Exporting…" : "导出中…")
                    : "HTML",
                icon: "square.and.arrow.up",
                help: language == .english
                    ? "Export the current session as offline HTML"
                    : "把当前会话导出为可离线阅读的 HTML",
                isEnabled: !isExporting,
                action: onExportSession
            )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .puraPiGlassSurface(
            role: .hud,
            cornerRadius: 10
        )
        .help(language == .english ? "Current Agent Runtime status" : "当前 Agent Runtime 状态")
    }

    /// Pi 尚未报告时按开启显示：Pi 的默认值是开启，这样不会误导用户以为关着。
    private var isAutoCompactionEnabled: Bool { autoCompactionEnabled ?? true }

    private var autoCompactionHelp: String {
        guard canToggleAutoCompaction else {
            return language == .english
                ? "Pi has not reported auto-compaction status"
                : "Pi 尚未报告自动压缩状态"
        }
        if language == .english {
            return isAutoCompactionEnabled
                ? "Auto-compaction is on; click to turn it off"
                : "Auto-compaction is off; click to turn it on"
        }
        return isAutoCompactionEnabled
            ? "自动压缩已开启：上下文接近上限时 Pi 会自动压缩。点击关闭"
            : "自动压缩已关闭：需要手动压缩。点击开启"
    }

    /// 模型候选项；空列表时 `HUDMenuValue` 自动退化为只读展示。
    private var modelOptions: [PuraPiHUDMenuOption] {
        availableModels.map { model in
            PuraPiHUDMenuOption(
                id: model.selectionKey,
                title: model.name,
                detail: model.provider,
                isSelected: model.selectionKey == metadata.modelSelectionKey
            )
        }
    }

    /// 推理强度候选项；模型不支持推理或只有单一级别时不提供选择。
    private var thinkingLevelOptions: [PuraPiHUDMenuOption] {
        guard supportsThinkingLevelSelection else { return [] }
        return availableThinkingLevels.map { level in
            PuraPiHUDMenuOption(
                id: level,
                title: Self.displayThinkingLevel(level, language: language),
                detail: level,
                isSelected: level == metadata.thinkingLevel
            )
        }
    }

    /// 菜单回传的是 `provider/id`，这里映回具体模型再交给控制器。
    private func selectModel(withKey key: String) {
        guard let model = availableModels.first(where: { $0.selectionKey == key }) else { return }
        onSelectModel(model)
    }

    private var abbreviatedWorkspacePath: String {
        guard !workspacePath.isEmpty else {
            return language == .english ? "Loading…" : "读取中…"
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if workspacePath == homePath {
            return "~"
        }
        if workspacePath.hasPrefix(homePath + "/") {
            return "~" + workspacePath.dropFirst(homePath.count)
        }
        return workspacePath
    }

    private var contextValue: String {
        if let tokens = metadata.contextTokens, let window = metadata.contextWindow {
            return "\(formatTokenCount(tokens)) / \(formatTokenCount(window))"
        }
        if let window = metadata.contextWindow {
            if let percent = metadata.contextPercent {
                return "\(Int(percent.rounded()))% / \(formatTokenCount(window))"
            }
            return "— / \(formatTokenCount(window))"
        }
        return language == .english ? "Loading…" : "读取中…"
    }

    static func displayThinkingLevel(
        _ level: String,
        language: PuraPiInterfaceLanguage = .chinese
    ) -> String {
        guard language != .english else {
            switch level.lowercased() {
            case "off": return "Off"
            case "minimal": return "Minimal"
            case "low": return "Low"
            case "medium": return "Medium"
            case "high": return "High"
            case "xhigh": return "X-high"
            case "max": return "Max"
            default: return level
            }
        }
        switch level.lowercased() {
        case "off": return "关闭"
        case "minimal": return "最低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "max": return "最大"
        default: return level
        }
    }

    private func formatTokenCount(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

/// HUD 中可点击展开的可选项（模型、推理强度）。
///
/// 视觉规格与 `HUDValue` 完全一致，只额外提供一个下拉指示箭头和悬停背景，
/// 避免把状态条变成一排明显的控件。不可用时保留文本展示并给出原因。
struct HUDMenuValue: View {
    let label: String
    let value: String
    let icon: String
    let language: PuraPiInterfaceLanguage
    let isBusy: Bool
    let disabledHint: String
    let options: [PuraPiHUDMenuOption]
    let onSelect: (String) -> Void

    @State private var isHovering = false

    private var isEnabled: Bool { !options.isEmpty }

    var body: some View {
        // 弹出由 AppKit `NSMenu` 接管；SwiftUI `Menu` 在自定义 label 下要么丢掉
        // 文本，要么丢掉点击，两边不可兼得。
        //
        // 用 ZStack 而不是 `.overlay`：命中层必须是真正的同级最上层视图，
        // 并且文本层要关掉命中，否则 SwiftUI 会先吃掉鼠标事件，
        // `NSView.mouseDown` 永远不会被调用。
        //
        // 命中层高度必须跟随文本层真实高度：HUD 整行会被其他列拉高，
        // 若让命中层跟着拉满，点击区会越出可见的 HUD 项。
        labelContent
            .allowsHitTesting(false)
            .background {
                GeometryReader { proxy in
                    if isEnabled {
                        PuraPiHUDMenu(options: options, onSelect: onSelect)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
            .onHover { isHovering = $0 && isEnabled }
            .help(isEnabled
                ? (language == .english ? "Change \(label.lowercased())" : "切换\(label)")
                : disabledHint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelContent: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    Text(value)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.62)
                            .frame(width: 8, height: 8)
                    } else if isEnabled {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 6.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering && isEnabled ? 0.07 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct HUDValue: View {
    let label: String
    let value: String
    let icon: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HUDDivider: View {
    @Environment(\.puraPiTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.hairline.opacity(0.72))
            .frame(width: 0.5, height: 25)
            .padding(.horizontal, 9)
    }
}

/// 既显示状态、又可点击触发动作的 HUD 项。
///
/// 用于「上下文」这类动作与数值直接相关的场景：压缩会改变这里显示的数值，
/// 因此把动作挂在数值本身上，比另开一个按钮更容易被理解。
struct HUDActionValue: View {
    @Environment(\.puraPiTheme) private var theme

    let label: String
    let value: String
    let icon: String
    let actionIcon: String
    let help: String
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(value)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isBusy {
                    ProgressView().controlSize(.mini).scaleEffect(0.5)
                } else if isHovering, isEnabled {
                    // 悬停才露出动作提示，静态时保持状态栏的克制观感。
                    Image(systemName: actionIcon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// 纯动作型 HUD 项。
struct HUDActionButton: View {
    @Environment(\.puraPiTheme) private var theme

    let label: String
    let value: String
    let icon: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(
                        isHovering && isEnabled ? theme.accent : .secondary
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(value)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(
                            isHovering && isEnabled ? theme.accent : .secondary
                        )
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// HUD 中的纯图标动作按钮。
///
/// 用于跟在某个状态值后面的操作，例如上下文的「立即压缩」与「自动压缩」。
/// 不带文字标签，避免把状态栏挤满；语义靠图标与 tooltip 表达。
struct HUDIconButton: View {
    @Environment(\.puraPiTheme) private var theme

    let icon: String
    let help: String
    /// 开关型按钮的开启态；一次性动作传 false。
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isHovering && isEnabled
                                ? theme.accent.opacity(0.12)
                                : Color.clear
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var foreground: Color {
        if !isEnabled { return Color.secondary.opacity(0.4) }
        if isActive { return theme.accent }
        return isHovering ? theme.accent : .secondary
    }
}
