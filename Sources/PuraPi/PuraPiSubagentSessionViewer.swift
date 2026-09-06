import Darwin
import Foundation
import PiDomain
import PiRPC
import SwiftUI

/// 从持久化 Pi Session 中读取只读对话内容。
///
/// 读取在调用方的后台任务中执行；损坏或尚未写完的尾行会被跳过，避免一个正在
/// 写入的子会话让查看器崩溃。完整 Session 文件仍是唯一事实源。
enum PuraPiSubagentSessionReader {
    static let defaultSessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumLines = 100_000
    static let maximumLineBytes = 1 * 1024 * 1024

    static func conversation(
        from fileURL: URL,
        sessionsRoot: URL = defaultSessionsRoot
    ) -> [ConversationItem] {
        guard let descriptor = openFixedDescriptor(fileURL, sessionsRoot: sessionsRoot) else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }

        var buffer = Data()
        var messages: [JSONValue] = []
        var totalBytes = 0
        var lineCount = 0
        var stopped = false
        while !stopped, totalBytes < maximumBytes, lineCount < maximumLines {
            let chunk = try? handle.read(upToCount: min(64 * 1024, maximumBytes - totalBytes))
            guard let chunk, !chunk.isEmpty else { break }
            totalBytes += chunk.count
            buffer.append(chunk)
            stopped = consumeLines(from: &buffer, messages: &messages, lineCount: &lineCount)
        }
        if !stopped, !buffer.isEmpty, buffer.count <= maximumLineBytes, lineCount < maximumLines {
            appendMessage(from: buffer, to: &messages)
        }

        guard !messages.isEmpty else { return [] }
        let response = JSONValue.object([
            "messages": .array(messages),
        ])
        return PiSessionHistoryMapper.conversation(from: response)
    }

    private static func openFixedDescriptor(_ fileURL: URL, sessionsRoot: URL) -> Int32? {
        let root = sessionsRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = fileURL.standardizedFileURL
        guard target.pathExtension.lowercased() == "jsonl",
              target.path == root.path || target.path.hasPrefix(root.path + "/") else { return nil }
        let suffix = String(target.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        var current = root.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard current >= 0 else { return nil }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = component.withCString { name in openat(current, name, flags) }
            guard next >= 0 else { close(current); return nil }
            close(current)
            current = next
        }
        var fileStat = stat()
        guard fstat(current, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            close(current)
            return nil
        }
        return current
    }

    @discardableResult
    private static func consumeLines(
        from buffer: inout Data,
        messages: inout [JSONValue],
        lineCount: inout Int
    ) -> Bool {
        while let newline = buffer.firstIndex(of: 0x0A) {
            guard newline <= maximumLineBytes else {
                buffer.removeAll(keepingCapacity: false)
                return true
            }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            lineCount += 1
            appendMessage(from: line, to: &messages)
            if lineCount >= maximumLines { return true }
        }
        return buffer.count > maximumLineBytes
    }

    private static func appendMessage(from line: Data, to messages: inout [JSONValue]) {
        guard !line.isEmpty,
              let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              value["type"]?.stringValue == "message",
              let message = value["message"]
        else { return }
        messages.append(message)
    }
}

/// 子 Agent 的持久会话查看器。
///
/// 这是非破坏性的实时预览：它轮询目标 Session 的追加内容，主 Agent 和子 Agent
/// 可以继续运行；关闭查看器不会发送任何 RPC，也不会改变主 Runtime。
@MainActor
struct PuraPiSubagentSessionViewer: View {
    @Environment(\.puraPiTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let task: SubagentTaskSnapshot
    let language: PuraPiInterfaceLanguage

    @State private var items: [ConversationItem] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.2)

            if isLoading && items.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(language == .english ? "Loading session…" : "正在读取子会话…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    language == .english ? "No transcript yet" : "子会话尚无文本记录",
                    systemImage: "text.bubble",
                    description: Text(
                        language == .english
                            ? "The session may still be starting, or it ended before producing a message."
                            : "子 Agent 可能仍在启动，或在产生消息前就结束了。"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            ConversationItemView(item: item, language: language)
                                .frame(maxWidth: 780, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(PuraPiAdaptiveContentBackground(legacyColor: theme.contentBackground))
        .frame(minWidth: 620, idealWidth: 820, minHeight: 480, idealHeight: 680)
        .task(id: task.sessionFilePath) {
            await refreshLoop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(language == .english ? "SubAgent session" : "SubAgent 独立会话")
                    .font(.system(size: 16, weight: .semibold))
                Text(task.agentName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                statusBadge
                Spacer(minLength: 0)
                Button(language == .english ? "Close" : "关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Text(task.task)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                if let model = task.model {
                    Label(model, systemImage: "cpu")
                }
                Label(task.id, systemImage: "number")
                Text(task.sessionFilePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.sessionFilePath)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .puraPiGlassSurface(role: .hud, cornerRadius: 0)
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusText: String {
        switch task.status {
        case .queued: return language == .english ? "queued" : "等待中"
        case .running: return language == .english ? "running" : "运行中"
        case .retrying: return language == .english ? "retrying" : "重试中"
        case .completed: return language == .english ? "completed" : "已完成"
        case .failed: return language == .english ? "failed" : "失败"
        case .cancelled: return language == .english ? "cancelled" : "已取消"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .queued: return .secondary
        case .running: return theme.accent
        case .retrying: return theme.warning
        case .completed: return theme.success
        case .failed: return theme.error
        case .cancelled: return .secondary
        }
    }

    private func trustedSessionsRoot() -> URL {
        guard let configured = task.sessionRootPath,
              !configured.isEmpty
        else { return PuraPiSubagentSessionReader.defaultSessionsRoot }

        let candidate = URL(fileURLWithPath: configured)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let agentRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path == agentRoot.path || candidate.path.hasPrefix(agentRoot.path + "/") else {
            return PuraPiSubagentSessionReader.defaultSessionsRoot
        }
        return candidate
    }

    private func refreshLoop() async {
        let fileURL = URL(fileURLWithPath: task.sessionFilePath)
        let sessionsRoot = trustedSessionsRoot()
        while !Task.isCancelled {
            let loaded = await Task.detached(priority: .utility) {
                PuraPiSubagentSessionReader.conversation(
                    from: fileURL,
                    sessionsRoot: sessionsRoot
                )
            }.value
            guard !Task.isCancelled else { return }
            items = loaded
            isLoading = false
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }
}
