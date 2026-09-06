import AppKit
import PiDomain
import PiRPC
import SwiftUI

/// 输入区：文本、附件、命令模式与发送/停止按钮。
///
/// 从 `ConversationPane.swift` 拆出（该文件曾到 832 行触发 800 预警）。
struct Composer: View {
    @Environment(\.workPiTheme) private var theme

    @Binding var text: String
    let phase: AgentPhase
    let commands: [WorkPiCommandItem]
    let language: WorkPiInterfaceLanguage
    let metadata: AgentRuntimeMetadata
    let workspacePath: String
    let isFileSelected: Bool
    let availableModels: [PiRPCModelInfo]
    let availableThinkingLevels: [String]
    let isModelSwitching: Bool
    let isThinkingLevelSwitching: Bool
    let supportsThinkingLevelSelection: Bool
    let onSelectModel: (PiRPCModelInfo) -> Void
    let onSelectThinkingLevel: (String) -> Void
    let onCompactContext: () -> Void
    let canCompactContext: Bool
    let onToggleAutoCompaction: (Bool) -> Void
    let canToggleAutoCompaction: Bool
    let onExportSession: () -> Void
    let isExporting: Bool
    let attachments: [WorkPiAttachment]
    let onAttachFiles: ([URL]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onPasteImage: () -> Bool
    let onSubmit: () -> Void
    let onSubmitCommand: (String) -> Void
    let onAbort: () -> Void
    let subagentTasks: [SubagentTaskSnapshot]
    let onOpenSubagent: (SubagentTaskSnapshot) -> Void

    @State private var isCommandPaletteVisible = false
    @State private var commandQuery = ""
    @State private var selectedCommandIndex = 0

    static let maximumWidth: CGFloat = 980

    var body: some View {
        WorkPiGlassContainer(spacing: 7) {
            VStack(alignment: .leading, spacing: 7) {
                if isCommandPaletteVisible {
                    WorkPiCommandPalette(
                        commands: commands,
                        query: commandQuery,
                        selectedIndex: $selectedCommandIndex,
                        language: language,
                        onSelect: insertCommand
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                inputSurface

                RuntimeHUD(
                    metadata: metadata,
                    language: language,
                    workspacePath: workspacePath,
                    availableModels: availableModels,
                    availableThinkingLevels: availableThinkingLevels,
                    isModelSwitching: isModelSwitching,
                    isThinkingLevelSwitching: isThinkingLevelSwitching,
                    supportsThinkingLevelSelection: supportsThinkingLevelSelection,
                    onSelectModel: onSelectModel,
                    onSelectThinkingLevel: onSelectThinkingLevel,
                    onCompactContext: onCompactContext,
                    canCompactContext: canCompactContext,
                    autoCompactionEnabled: metadata.autoCompactionEnabled,
                    onToggleAutoCompaction: onToggleAutoCompaction,
                    canToggleAutoCompaction: canToggleAutoCompaction,
                    onExportSession: onExportSession,
                    isExporting: isExporting
                )

                if !subagentTasks.isEmpty {
                    WorkPiSubagentPanel(
                        tasks: subagentTasks,
                        language: language,
                        onOpen: onOpenSubagent
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: Self.maximumWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, isFileSelected ? 18 : 42)
        .padding(.bottom, isFileSelected ? 14 : 28)
    }

    /// 输入以 `!`（或全角 `！`）开头时进入命令模式。
    private var isShellCommandMode: Bool {
        WorkPiCommandCatalog.isShellCommandMode(text)
    }

    private var inputSurface: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.isEmpty {
                WorkPiAttachmentList(
                    attachments: attachments,
                    language: language,
                    onRemove: onRemoveAttachment
                )
            }
            inputRow
        }
        .padding(.horizontal, isFileSelected ? 12 : 16)
        .padding(.vertical, isFileSelected ? 9 : 14)
        .workPiGlassSurface(
            role: .hud,
            cornerRadius: isFileSelected ? 11 : 18,
            interactive: true,
            // 命令模式给整块输入面板着色：这是最难忽略的提示，
            // 用户不必先注意到图标或占位文案才知道模式已切换。
            tint: isShellCommandMode ? theme.accent.opacity(0.16) : nil
        )
        .overlay {
            if isShellCommandMode {
                RoundedRectangle(
                    cornerRadius: isFileSelected ? 11 : 18,
                    style: .continuous
                )
                .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1)
            }
        }
        // 模式标记用 overlay 而不是放进 HStack：放进布局流会占掉横向空间，
        // 把输入区和光标整体右推，用户每次敲 `!` 都会看到文字跳一下。
        .overlay(alignment: .bottomLeading) {
            if isShellCommandMode {
                HStack(spacing: 4) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(language == .english ? "shell" : "命令")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, isFileSelected ? 12 : 16)
                .padding(.bottom, isFileSelected ? 4 : 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isShellCommandMode)
        // 拖入文件即成为附件；图片走 prompt.images，文本拼进正文。
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    onAttachFiles([url])
                }
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                // 等宽字体让命令的空格与参数边界看得清。
                .fontDesign(isShellCommandMode ? .monospaced : .default)
                .onChange(of: text) { _, newValue in
                    updateCommandPalette(for: newValue)
                }
                .font(.system(size: isFileSelected ? 13.5 : 15))
                .lineLimit(isFileSelected ? 1...6 : 1...8)
                .frame(minHeight: isFileSelected ? 28 : 92, alignment: .topLeading)
                .padding(.leading, isFileSelected ? 3 : 5)
                .padding(.vertical, isFileSelected ? 7 : 10)
                .onSubmit {
                    guard !isCommandPaletteVisible,
                          !NSEvent.modifierFlags.contains(.shift)
                    else { return }
                    onSubmit()
                }
                .onKeyPress(phases: [.down]) { keyPress in
                    handleCommandKeyPress(keyPress)
                }

            Button(action: isWorking ? onAbort : onSubmit) {
                Image(systemName: sendButtonIcon)
                    .font(.system(size: 11.5, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(
                HUDSendButtonStyle(
                    isWorking: isWorking,
                    errorColor: theme.error
                )
            )
            .disabled(
                isStopping
                    || (!isWorking && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            )
            .help(isStopping ? "正在停止…" : (isWorking ? "停止 Agent" : "发送"))
        }
    }

    private var sendButtonIcon: String {
        if isWorking { return "stop.fill" }
        // 命令模式用 return 箭头，与 shell 的执行语义一致。
        return isShellCommandMode ? "return" : "arrow.up"
    }

    private var placeholder: String {
        let english = language == .english
        if isShellCommandMode {
            return english ? "Shell command · runs directly" : "Shell 命令 · 直接执行"
        }
        return english ? "Type a message…" : "输入指令…"
    }

    private func updateCommandPalette(for value: String) {
        guard let query = WorkPiCommandCatalog.slashQuery(for: value) else {
            isCommandPaletteVisible = false
            commandQuery = ""
            selectedCommandIndex = 0
            return
        }
        commandQuery = query
        guard !WorkPiCommandCatalog.hasCommandArgument(value) else {
            isCommandPaletteVisible = false
            selectedCommandIndex = 0
            return
        }

        isCommandPaletteVisible = true
        let filteredCount = WorkPiCommandCatalog.filtered(commands, query: query).count
        selectedCommandIndex = min(selectedCommandIndex, max(filteredCount - 1, 0))
    }

    private func selectedCommand() -> WorkPiCommandItem? {
        let filtered = WorkPiCommandCatalog.filtered(commands, query: commandQuery)
        guard filtered.indices.contains(selectedCommandIndex) else { return filtered.first }
        return filtered[selectedCommandIndex]
    }

    private func insertCommand(_ command: WorkPiCommandItem) {
        text = command.invocation + " "
        isCommandPaletteVisible = false
        commandQuery = ""
        selectedCommandIndex = 0
    }

    private func handleCommandKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // Cmd+V 优先尝试作为图片附件粘贴；剪贴板里没有图片时交还给文本输入。
        if keyPress.modifiers.contains(.command),
           keyPress.characters.lowercased() == "v" {
            return onPasteImage() ? .handled : .ignored
        }
        guard isCommandPaletteVisible else { return .ignored }
        switch keyPress.key {
        case .upArrow:
            let count = WorkPiCommandCatalog.filtered(commands, query: commandQuery).count
            selectedCommandIndex = WorkPiCommandCatalog.movedSelection(
                currentIndex: selectedCommandIndex,
                direction: .up,
                resultCount: count
            )
            return .handled
        case .downArrow:
            let count = WorkPiCommandCatalog.filtered(commands, query: commandQuery).count
            selectedCommandIndex = WorkPiCommandCatalog.movedSelection(
                currentIndex: selectedCommandIndex,
                direction: .down,
                resultCount: count
            )
            return .handled
        case .escape:
            isCommandPaletteVisible = false
            return .handled
        case .tab:
            if let command = selectedCommand() { insertCommand(command) }
            return .handled
        case .return:
            if let command = selectedCommand() {
                // 先消费按键，再清空输入框；即使系统随后派发 onSubmit，
                // `isCommandPaletteVisible == false` 也会阻止第二次发送。
                submitCommand(command)
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }

    private func submitCommand(_ command: WorkPiCommandItem) {
        guard isCommandPaletteVisible else { return }
        text = ""
        isCommandPaletteVisible = false
        commandQuery = ""
        selectedCommandIndex = 0
        onSubmitCommand(command.invocation)
    }

    private var isWorking: Bool {
        switch phase {
        case .preparing, .requesting, .streaming, .executingTool, .settling, .cancelled:
            return true
        default:
            return false
        }
    }

    private var isStopping: Bool {
        phase == .cancelled
    }
}


struct HUDSendButtonStyle: ButtonStyle {
    let isWorking: Bool
    let errorColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isWorking ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isWorking
                            ? errorColor.opacity(configuration.isPressed ? 0.72 : 0.86)
                            : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.1)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
