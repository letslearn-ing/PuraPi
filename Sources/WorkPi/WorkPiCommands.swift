import Foundation
import PiRPC

/// WorkPi 当前支持的内置命令动作。
enum WorkPiCommandAction: Equatable, Sendable {
    case newSession
    case continueRecent
    case compact
    case abort
    case trustProject
    /// 打开会话统计面板。
    case status
}

enum WorkPiCommandSelectionDirection: Sendable {
    case up
    case down
}

/// 命令选择器展示的一条命令。
struct WorkPiCommandItem: Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let source: String
    let action: WorkPiCommandAction?

    var id: String { name }
    var invocation: String { "/\(name)" }

    func sourceLabel(language: WorkPiInterfaceLanguage) -> String {
        if language == .english {
            switch source {
            case "workpi": return "Pura Pi"
            case "extension": return "Extension"
            case "skill": return "Skill"
            case "prompt": return "Prompt template"
            default: return source
            }
        }
        switch source {
        case "workpi": return "Pura Pi"
        case "extension": return "扩展"
        case "skill": return "技能"
        case "prompt": return "提示模板"
        default: return source
        }
    }
}

enum WorkPiCommandCatalog {
    static func items(
        piCommands: [PiRPCCommandInfo],
        language: WorkPiInterfaceLanguage
    ) -> [WorkPiCommandItem] {
        let builtIns = builtInItems(language: language)
        var result = builtIns
        var names = Set(builtIns.map { $0.name.lowercased() })

        for command in piCommands {
            let normalizedName = normalizedName(command.name)
            guard !normalizedName.isEmpty,
                  names.insert(normalizedName.lowercased()).inserted
            else { continue }

            result.append(
                WorkPiCommandItem(
                    name: normalizedName,
                    description: command.description ?? fallbackDescription(
                        source: command.source,
                        language: language
                    ),
                    source: command.source,
                    action: nil
                )
            )
        }
        return result
    }

    /// 统一 Composer 和候选面板的过滤规则，避免两处索引/匹配语义漂移。
    static func filtered(
        _ commands: [WorkPiCommandItem],
        query: String
    ) -> [WorkPiCommandItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return commands }
        return commands.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.description.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    /// 返回以 `/` 开头且尚未输入参数的命令查询词；非命令输入返回 nil。
    static func slashQuery(for text: String) -> String? {
        guard text.first == "/" else { return nil }
        let body = text.dropFirst()
        return body
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0.isNewline })
            .first
            .map(String.init) ?? ""
    }

    static func hasCommandArgument(_ text: String) -> Bool {
        guard text.first == "/" else { return false }
        return text.dropFirst().contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// 从 Pi 返回的命令目录中查找一个完整的斜杠命令。
    /// 参数不参与匹配，因此 `/command extra` 仍然对应同一条命令。
    static func discoveredCommand(
        for text: String,
        piCommands: [PiRPCCommandInfo]
    ) -> PiRPCCommandInfo? {
        guard let query = slashQuery(for: text), !query.isEmpty else { return nil }
        let normalizedQuery = normalizedName(query).lowercased()
        return piCommands.first {
            normalizedName($0.name).lowercased() == normalizedQuery
        }
    }

    /// `!` 前缀表示直接执行 shell 命令。
    ///
    /// 用 `!` 而不是新增斜杠命令：斜杠命名空间由 Pi 的 `get_commands` 动态提供，
    /// 我们自行占用名字有冲突风险；`!cmd` 是 shell/REPL 里通行的转义写法。
    ///
    /// 同时接受全角 `！`：中文输入法下打出的是全角，只认半角会让用户以为
    /// 功能失灵，而那条消息会被当成普通提问发给模型。
    static func shellCommand(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "!" || first == "！" else { return nil }
        let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// 输入是否已进入命令模式。
    ///
    /// 与 `shellCommand` 的区别：只输了前缀、还没打命令时也算，
    /// 这样界面能在用户敲下 `!` 的那一刻就给出反馈。
    static func isShellCommandMode(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return false
        }
        return first == "!" || first == "！"
    }

    static func action(for text: String) -> WorkPiCommandAction? {
        guard let query = slashQuery(for: text) else { return nil }

        switch normalizedName(query).lowercased() {
        case "new": return .newSession
        case "continue": return .continueRecent
        case "compact": return .compact
        case "abort": return .abort
        case "trust": return .trustProject
        case "status": return .status
        default: return nil
        }
    }

    static func customInstructions(from text: String) -> String? {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard parts.count == 2 else { return nil }
        let instructions = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return instructions.isEmpty ? nil : instructions
    }

    static func movedSelection(
        currentIndex: Int,
        direction: WorkPiCommandSelectionDirection,
        resultCount: Int
    ) -> Int {
        guard resultCount > 0 else { return 0 }
        let current = min(max(currentIndex, 0), resultCount - 1)
        switch direction {
        case .up:
            return max(0, current - 1)
        case .down:
            return min(resultCount - 1, current + 1)
        }
    }

    private static func builtInItems(language: WorkPiInterfaceLanguage) -> [WorkPiCommandItem] {
        let english = language == .english
        return [
            WorkPiCommandItem(
                name: "new",
                description: english ? "New session" : "新建会话",
                source: "workpi",
                action: .newSession
            ),
            WorkPiCommandItem(
                name: "status",
                description: english ? "Session statistics" : "会话统计",
                source: "workpi",
                action: .status
            ),
            WorkPiCommandItem(
                name: "continue",
                description: english ? "Continue recent session" : "继续最近会话",
                source: "workpi",
                action: .continueRecent
            ),
            WorkPiCommandItem(
                name: "compact",
                description: english ? "Compact current context" : "压缩当前上下文",
                source: "workpi",
                action: .compact
            ),
            WorkPiCommandItem(
                name: "abort",
                description: english ? "Stop the current Agent" : "停止当前 Agent",
                source: "workpi",
                action: .abort
            ),
            WorkPiCommandItem(
                name: "trust",
                description: english
                    ? "Authorize this project's local extensions"
                    : "授权当前项目的本地扩展",
                source: "workpi",
                action: .trustProject
            ),
        ]
    }

    private static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func fallbackDescription(
        source: String,
        language: WorkPiInterfaceLanguage
    ) -> String {
        if language == .english {
            switch source {
            case "skill": return "Run this skill"
            case "prompt": return "Run this prompt template"
            default: return "Extension command"
            }
        }
        switch source {
        case "skill": return "运行这个技能"
        case "prompt": return "运行这个提示模板"
        default: return "扩展命令"
        }
    }
}

/// 项目本地资源的安全授权状态。
enum WorkPiProjectAuthorizationState: Equatable, Sendable {
    case notRequired
    case needsDecision
    case approved
    case denied
}

enum WorkPiProjectAuthorization {
    static let rememberedProjectsKey = WorkPiPreferences.Key.rememberedAuthorizedProjects

    static func isRemembered(
        for rootURL: URL,
        defaults: UserDefaults = WorkPiPreferences.shared
    ) -> Bool {
        let path = canonicalProjectURL(rootURL).path
        let paths = defaults.stringArray(forKey: rememberedProjectsKey) ?? []
        return paths.contains(path)
    }

    static func remember(
        _ rootURL: URL,
        defaults: UserDefaults = WorkPiPreferences.shared
    ) {
        let path = canonicalProjectURL(rootURL).path
        var paths = defaults.stringArray(forKey: rememberedProjectsKey) ?? []
        if !paths.contains(path) {
            paths.append(path)
            defaults.set(paths.sorted(), forKey: rememberedProjectsKey)
        }
    }

    /// 撤销单个项目的持久授权；用于将来在 UI 中提供可见的撤销入口。
    static func forget(
        _ rootURL: URL,
        defaults: UserDefaults = WorkPiPreferences.shared
    ) {
        let path = canonicalProjectURL(rootURL).path
        let paths = defaults.stringArray(forKey: rememberedProjectsKey) ?? []
        guard paths.contains(path) else { return }
        defaults.set(paths.filter { $0 != path }.sorted(), forKey: rememberedProjectsKey)
    }

    static func rememberedProjectPaths(
        defaults: UserDefaults = WorkPiPreferences.shared
    ) -> [String] {
        defaults.stringArray(forKey: rememberedProjectsKey) ?? []
    }

    /// 与 Pi 的项目资源信任边界保持一致，只检查需要执行/读取的资源入口。
    static func requiresAuthorization(for rootURL: URL) -> Bool {
        let root = canonicalProjectURL(rootURL)
        let projectConfig = root.appendingPathComponent(".pi", isDirectory: true)
        let gatedEntries = [
            "settings.json",
            "extensions",
            "skills",
            "prompts",
            "themes",
            "SYSTEM.md",
            "APPEND_SYSTEM.md",
        ]
        if gatedEntries.contains(where: {
            FileManager.default.fileExists(
                atPath: projectConfig.appendingPathComponent($0).path
            )
        }) {
            return true
        }

        let homeAgentsSkills = canonicalProjectURL(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
        ).path
        var current = root
        while true {
            let agentsSkills = current
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
                .standardizedFileURL
            if agentsSkills.path != homeAgentsSkills,
               FileManager.default.fileExists(atPath: agentsSkills.path) {
                return true
            }

            // `deletingLastPathComponent()` 在根 URL 上可能产生空路径；若继续
            // 标准化会在 `/` 与空路径之间往返，因此必须显式终止。
            guard current.path != "/" else { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard !parent.path.isEmpty, parent.path != current.path else { break }
            current = parent
        }
        return false
    }

    private static func canonicalProjectURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
