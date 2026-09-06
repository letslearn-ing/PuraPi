import Darwin
import Foundation
import PiDomain

/// 把会话文件解析成按轮次组织的导航结构。
///
/// 会话是 append-only 的 entry 树（`id` / `parentId`）。`fork` 不会新建文件，而是
/// 在同一棵树上从某条用户消息长出新分支，因此文件里同时存在活动分支与废弃分支。
///
/// 活动分支 = 从最后一个 entry 沿 `parentId` 回溯到根的那条路径。用它标记轮次
/// 是否仍然有效，避免把已被 fork 抛弃的历史当作当前对话展示。
public enum PiSessionTurnParser {
    /// 解析出用户轮次列表，按时间顺序。
    public static func turns(in fileURL: URL) -> [PiSessionTurn] {
        guard let descriptor = openFixedDescriptor(fileURL) else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }

        var entries: [ParsedEntry] = []
        for line in LineReader(handle: handle) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = ParsedEntry(object: object)
            else { continue }
            entries.append(entry)
        }
        return turns(from: entries)
    }

    private static func openFixedDescriptor(_ url: URL) -> Int32? {
        guard url.pathExtension.lowercased() == "jsonl" else { return nil }
        // Resolve ancestor links (for example /tmp -> /private/tmp), but
        // reject a symlink at the final component before resolving the path.
        let lexicalURL = url.standardizedFileURL
        var lexicalStat = stat()
        guard lstat(lexicalURL.path, &lexicalStat) == 0,
              (lexicalStat.st_mode & S_IFMT) != S_IFLNK
        else { return nil }
        let parentPath = lexicalURL.deletingLastPathComponent().path
        guard let resolvedParent = parentPath.withCString({ realpath($0, nil) }) else {
            return nil
        }
        defer { free(resolvedParent) }
        let path = String(cString: resolvedParent) + "/" + lexicalURL.lastPathComponent
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
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

    static func turns(from entries: [ParsedEntry]) -> [PiSessionTurn] {
        guard !entries.isEmpty else { return [] }

        var byID: [String: ParsedEntry] = [:]
        for entry in entries {
            byID[entry.id] = entry
        }

        // 活动分支必须从最后一条消息 entry 回溯；文件末尾可能还有
        // session_info/model_change 等元数据，它们不代表当前分支位置。
        var activeIDs: Set<String> = []
        var cursor = entries.last(where: { $0.isMessageEntry })?.id
        var guardCounter = 0
        while let current = cursor, guardCounter <= entries.count {
            guard let entry = byID[current] else { break }
            activeIDs.insert(entry.id)
            cursor = entry.parentID
            guardCounter += 1
        }

        // 每个 response 沿 parentId 回溯到最近的 user entry。不能按文件
        // 线性顺序绑定 currentTurnID，否则 fork/交错分支会把响应算到错误轮次。
        // 对已经解析过的 parent 链做 memoization（记忆化），避免恶意的
        // 长链 response 让 100,000 行输入退化成 O(n²) 遍历。
        let userIDs = Set(entries.filter(\.isUserMessage).map(\.id))
        var responseCounts: [String: Int] = [:]
        for entry in entries where entry.isUserMessage {
            responseCounts[entry.id] = 0
        }
        var nearestUserByEntryID: [String: String] = [:]
        var entriesWithoutUserAncestor: Set<String> = []
        nearestUserByEntryID.reserveCapacity(entries.count)
        entriesWithoutUserAncestor.reserveCapacity(entries.count)

        for entry in entries where entry.isResponse {
            var ancestor = entry.parentID
            var path: [String] = []
            var visited: Set<String> = []
            var userID: String?
            while let ancestorID = ancestor {
                if let cached = nearestUserByEntryID[ancestorID] {
                    userID = cached
                    break
                }
                if entriesWithoutUserAncestor.contains(ancestorID) {
                    break
                }
                if userIDs.contains(ancestorID) {
                    userID = ancestorID
                    break
                }
                guard visited.insert(ancestorID).inserted else { break }
                path.append(ancestorID)
                ancestor = byID[ancestorID]?.parentID
            }

            if let userID {
                responseCounts[userID, default: 0] += 1
                for entryID in path {
                    nearestUserByEntryID[entryID] = userID
                }
            } else {
                entriesWithoutUserAncestor.formUnion(path)
            }
        }

        return entries.compactMap { entry in
            guard entry.isUserMessage, let text = entry.text, !text.isEmpty else { return nil }
            return PiSessionTurn(
                entryID: entry.id,
                text: text,
                timestamp: entry.timestamp,
                responseCount: responseCounts[entry.id] ?? 0,
                isOnActiveBranch: activeIDs.contains(entry.id)
            )
        }
    }
}

/// 会话文件里的一个 entry，只保留导航需要的字段。
struct ParsedEntry {
    let id: String
    let parentID: String?
    let timestamp: Date
    let role: String?
    let text: String?
    let type: String

    var isMessageEntry: Bool {
        type == "message"
    }

    var isUserMessage: Bool {
        isMessageEntry && role == "user"
    }

    /// 助手回复与工具结果都算这一轮的产出。
    var isResponse: Bool {
        guard type == "message" else { return false }
        return role == "assistant" || role == "toolResult"
    }

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String, type != "session" else { return nil }
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        self.type = type
        self.id = id
        self.parentID = object["parentId"] as? String
        if let raw = object["timestamp"] as? String {
            self.timestamp = PiSessionDateParser.date(from: raw)
        } else {
            self.timestamp = .distantPast
        }
        let message = object["message"] as? [String: Any]
        self.role = message?["role"] as? String
        self.text = PiSessionStore.plainText(from: message?["content"])
    }
}
