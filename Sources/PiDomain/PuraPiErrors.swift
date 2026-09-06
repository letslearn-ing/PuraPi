import Foundation

public enum PuraPiError: LocalizedError, Equatable, Sendable {
    case invalidWorkspace(URL)
    case fileNotFound(URL)
    case fileTooLarge(URL, Int)
    case binaryFile(URL)
    case invalidRPCLine(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkspace(let url):
            return "不是可用的工作区目录：\(url.path)"
        case .fileNotFound(let url):
            return "文件不存在：\(url.path)"
        case .fileTooLarge(let url, let bytes):
            return "文件过大，无法预览（\(bytes) bytes）：\(url.path)"
        case .binaryFile(let url):
            return "这是二进制文件，当前版本只提供文件路径：\(url.path)"
        case .invalidRPCLine(let line):
            return "Pi RPC 返回了无法解析的 JSONL：\(line.prefix(160))"
        }
    }
}
