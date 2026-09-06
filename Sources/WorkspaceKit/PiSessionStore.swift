import Darwin
import Foundation
import PiDomain

/// 从磁盘读取 Pi 会话文件的只读存储。
///
/// Pi 的 RPC 只暴露「当前会话」的能力，不提供同项目其他会话的列表，因此会话
/// 列表必须由 WorkPi 自己扫描。这一层只做解析，不发任何 RPC，也不改变运行状态：
/// 用户点开一个会话看看，不应该导致会话切换。
///
/// 目录布局（见上游 `docs/session-format.md`）：
/// `~/.pi/agent/sessions/--<cwd 把 / 换成 ->--/<时间戳>_<uuid>.jsonl`
public struct PiSessionStore: Sendable {
    /// 会话根目录。可注入以便测试。
    public let sessionsRoot: URL
    public let maximumSessionBytes: Int
    public let maximumSessionLines: Int

    public init(
        sessionsRoot: URL? = nil,
        maximumSessionBytes: Int = 16 * 1024 * 1024,
        maximumSessionLines: Int = 100_000
    ) {
        let root = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        self.sessionsRoot = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumSessionBytes = max(0, maximumSessionBytes)
        self.maximumSessionLines = max(0, maximumSessionLines)
    }

    /// 把工作目录映射为 Pi 的会话子目录名。
    ///
    /// 上游把 cwd 的 `/` 全部替换为 `-`，并在两端各加一个 `-`。
    /// cwd 以 `/` 开头，所以替换后已自带前导 `-`；不能再补两个，
    /// 否则会得到 `---Users-...` 而找不到目录。
    /// 实测真实目录：`/Users/limiao/work/PC/researchDSH`
    /// 对应 `--Users-limiao-work-PC-researchDSH--`。
    public static func directoryName(for workspacePath: String) -> String {
        "-\(workspacePath.replacingOccurrences(of: "/", with: "-"))--"
    }

    public func sessionsDirectory(for workspaceURL: URL) -> URL {
        let canonical = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        return sessionsRoot.appendingPathComponent(
            Self.directoryName(for: canonical.path),
            isDirectory: true
        )
    }

    /// 列出某个项目的全部会话，按最近修改时间倒序。
    ///
    /// 解析失败的文件会被跳过而不是让整个列表失败：会话文件可能正在被写入，
    /// 也可能来自更早的版本。
    public func listSessions(for workspaceURL: URL) -> [PiSessionSummary] {
        let canonicalWorkspacePath = Self.canonicalWorkspacePath(workspaceURL.path)
        let directory = sessionsDirectory(for: workspaceURL)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "jsonl" }
            // The upstream directory name is lossy (`/` becomes `-`), so two
            // different cwd values can share one directory.  The session
            // header is the authoritative workspace identity.
            .compactMap {
                summary(of: $0, expectedWorkspacePath: canonicalWorkspacePath)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 读取单个会话的摘要信息，不加载全部消息。
    public func summary(
        of fileURL: URL,
        expectedWorkspacePath: String? = nil
    ) -> PiSessionSummary? {
        guard let descriptor = openSessionDescriptor(fileURL) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }

        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else { return nil }
        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(fileStat.st_mtimespec.tv_sec))

        var header: PiSessionHeader?
        var name: String?
        var messageCount = 0
        var firstUserText: String?

        // 名字取最后一条 `session_info`；空字符串表示显式清除标题。
        for line in LineReader(
            handle: handle,
            maximumBytes: maximumSessionBytes,
            maximumLines: maximumSessionLines
        ) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "session":
                header = PiSessionHeader(object: object)
            case "session_info":
                let raw = (object["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                name = raw.isEmpty ? nil : raw
            case "message":
                messageCount += 1
                if firstUserText == nil,
                   let message = object["message"] as? [String: Any],
                   message["role"] as? String == "user" {
                    firstUserText = Self.plainText(from: message["content"])
                }
            default:
                break
            }
        }

        guard let header else { return nil }
        if let expectedWorkspacePath,
           Self.canonicalWorkspacePath(header.cwd) != expectedWorkspacePath {
            return nil
        }
        return PiSessionSummary(
            fileURL: fileURL,
            sessionID: header.id,
            createdAt: header.timestamp,
            modifiedAt: modifiedAt,
            cwd: header.cwd,
            parentSessionPath: header.parentSession,
            name: name,
            messageCount: messageCount,
            firstUserText: firstUserText
        )
    }

    /// 把 `message.content` 压成用于列表预览的一行纯文本。
    static func plainText(from content: Any?) -> String? {
        if let text = content as? String {
            return normalizedPreview(text)
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let joined = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: " ")
        return normalizedPreview(joined)
    }

    private static func canonicalWorkspacePath(_ path: String) -> String {
        let resolved: String? = path.withCString { pointer in
            guard let result = realpath(pointer, nil) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
        return resolved ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func normalizedPreview(_ text: String) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Opens a session relative to a fixed, resolved sessions root. Every path
    /// component is opened without following links, so a replacement between the
    /// directory scan and summary parsing cannot redirect the reader.
    private func openSessionDescriptor(_ fileURL: URL) -> Int32? {
        let target = fileURL.standardizedFileURL
        guard target.pathExtension.lowercased() == "jsonl",
              isInside(target, root: sessionsRoot) else { return nil }
        let suffix = String(target.path.dropFirst(sessionsRoot.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        let rootDescriptor = sessionsRoot.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard rootDescriptor >= 0 else { return nil }
        var current = rootDescriptor
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

    private func isInside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }
}

/// 会话时间戳解析器。每次调用创建独立 formatter，避免跨 detached 任务共享
/// `ISO8601DateFormatter`（它不是线程安全的 Sendable 值）。
enum PiSessionDateParser {
    static func date(from raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? .distantPast
    }
}

/// 会话文件头部。
struct PiSessionHeader {
    let id: String
    let timestamp: Date
    let cwd: String
    /// 由 `/fork`、`/clone` 或 `newSession({ parentSession })` 创建时指向来源会话。
    let parentSession: String?

    init?(object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.cwd = object["cwd"] as? String ?? ""
        self.parentSession = object["parentSession"] as? String
        if let raw = object["timestamp"] as? String {
            self.timestamp = PiSessionDateParser.date(from: raw)
        } else {
            self.timestamp = .distantPast
        }
    }
}

/// 逐行读取，避免把大会话文件整体载入内存。
///
/// 最大的真实会话已接近 2MB；列表要扫整个目录，不能每个文件都全量读进字符串。
struct LineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private var buffer = Data()
    private var isAtEnd = false
    private var bytesRead = 0
    private var linesRead = 0
    private let maximumBytes: Int
    private let maximumLines: Int
    private let maximumLineBytes = 1 * 1024 * 1024
    private let chunkSize = 64 * 1024

    init(handle: FileHandle, maximumBytes: Int = 16 * 1024 * 1024, maximumLines: Int = 100_000) {
        self.handle = handle
        self.maximumBytes = Swift.max(0, maximumBytes)
        self.maximumLines = Swift.max(0, maximumLines)
    }

    mutating func next() -> String? {
        guard linesRead < maximumLines else { return nil }
        while true {
            if let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                guard index <= maximumLineBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    isAtEnd = true
                    return nil
                }
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                linesRead += 1
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    return line
                }
                if linesRead >= maximumLines { return nil }
                continue
            }
            if buffer.count > maximumLineBytes {
                // Do not retain an unterminated attacker-controlled line.
                buffer.removeAll(keepingCapacity: false)
                isAtEnd = true
                return nil
            }
            guard !isAtEnd else {
                guard !buffer.isEmpty else { return nil }
                let line = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                linesRead += 1
                return line?.isEmpty == false ? line : nil
            }
            // 达到字节上限后仍要消费已经读入 buffer 的最后一行；只禁止
            // 继续向 fd 读取，否则恰好达到上限且无尾随换行的记录会丢失。
            guard bytesRead < maximumBytes else {
                isAtEnd = true
                continue
            }
            let remaining = maximumBytes - bytesRead
            let chunk = handle.readData(ofLength: Swift.min(chunkSize, remaining))
            if chunk.isEmpty {
                isAtEnd = true
            } else {
                bytesRead += chunk.count
                buffer.append(chunk)
            }
        }
    }
}
