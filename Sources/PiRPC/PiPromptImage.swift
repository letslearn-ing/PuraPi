import Darwin
import Foundation
import ImageIO

/// 随 `prompt` 一起发送的图片附件。
///
/// Pi 的协议要求 base64 数据加 MIME 类型：
/// `{"type": "image", "data": "base64...", "mimeType": "image/png"}`
public struct PiPromptImage: Equatable, Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// 从文件推断 MIME 类型；无法识别的扩展名返回 nil，不猜测。
    /// `maximumBytes` 在读取前检查文件大小，避免把任意大图片整体载入内存。
    public init?(fileURL: URL, maximumBytes: Int = 20 * 1024 * 1024) {
        guard maximumBytes > 0,
              let mimeType = Self.mimeType(forPathExtension: fileURL.pathExtension),
              let data = try? Self.readBoundedData(from: fileURL, maximumBytes: maximumBytes),
              data.count <= maximumBytes,
              Self.hasSafeImageDimensions(data)
        else { return nil }
        self.init(data: data, mimeType: mimeType)
    }

    private static func readBoundedData(
        from url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = try openRegularDescriptor(at: url)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size <= off_t(maximumBytes)
        else { throw CocoaError(.fileReadNoSuchFile) }
        let readCount = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        return try handle.read(upToCount: readCount) ?? Data()
    }

    /// Walk the path from a fixed root descriptor. O_NOFOLLOW on every component
    /// prevents both symlink attachments and parent-directory replacement from
    /// redirecting the image read outside the selected path.
    private static func openRegularDescriptor(at url: URL) throws -> Int32 {
        // Resolve ancestor links (for example /tmp -> /private/tmp), but
        // reject a symlink at the final component before resolving the path.
        let lexicalURL = url.standardizedFileURL
        var lexicalStat = stat()
        guard lstat(lexicalURL.path, &lexicalStat) == 0,
              (lexicalStat.st_mode & S_IFMT) != S_IFLNK
        else { throw CocoaError(.fileReadNoSuchFile) }
        let parentPath = lexicalURL.deletingLastPathComponent().path
        guard let resolvedParent = parentPath.withCString({ realpath($0, nil) }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { free(resolvedParent) }
        let path = String(cString: resolvedParent) + "/" + lexicalURL.lastPathComponent
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = component.withCString { name in openat(current, name, flags) }
            guard next >= 0 else {
                close(current)
                throw CocoaError(.fileReadNoSuchFile)
            }
            close(current)
            current = next
        }
        return current
    }

    /// Validate image structure and metadata without expanding pixels. This is
    /// shared by file attachments so a valid extension alone cannot authorize
    /// arbitrary bytes or a decompression-bomb-sized bitmap.
    private static func hasSafeImageDimensions(_ data: Data) -> Bool {
        let maximumPixels = 16_000_000
        let maximumFrames = 256
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrames else { return false }
        var totalPixels = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as NSDictionary?,
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0,
                  width <= maximumPixels / height,
                  totalPixels <= maximumPixels - width * height
            else { return false }
            totalPixels += width * height
        }
        return true
    }

    public static func mimeType(forPathExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    var jsonValue: JSONValue {
        .object([
            "type": .string("image"),
            "data": .string(data.base64EncodedString()),
            "mimeType": .string(mimeType),
        ])
    }
}
