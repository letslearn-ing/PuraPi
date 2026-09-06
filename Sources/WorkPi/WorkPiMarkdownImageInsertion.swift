import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 将工作区内的图片文件转换为安全的 Markdown 图片引用。
enum WorkPiMarkdownImageInsertion {
    static let maximumImageBytes = 20 * 1024 * 1024
    /// 防止高压缩图片在解码时展开成不可控的大 bitmap。
    static let maximumImagePixels = 16_000_000
    static let maximumImageFrameCount = 256
    private static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic"
    ]

    static func markdown(for imageURL: URL, workspaceRoot: URL) -> String? {
        guard let image = validatedImageURL(imageURL, workspaceRoot: workspaceRoot),
              let data = readImageData(at: imageURL, workspaceRoot: workspaceRoot),
              hasSafeImageDimensions(data: data)
        else { return nil }

        let lexicalRoot = workspaceRoot.standardizedFileURL
        let lexicalImage = imageURL.standardizedFileURL
        let relativePath = String(
            lexicalImage.path.dropFirst(lexicalRoot.path.count)
        )
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let alt = escapeAltText(image.deletingPathExtension().lastPathComponent)
        // Keep spaces and URL-looking punctuation as a file path (rather than
        // percent-encoding it), but escape every delimiter that can terminate
        // an angle destination.  This round-trips names containing `\\`, `<`
        // and `>` and remains readable in the Markdown source.
        let escapedPath = escapeAngleDestination(relativePath)
        return "![\(alt)](<\(escapedPath)>)"
    }

    /// 校验一个工作区内的图片引用，并返回可安全读取的真实路径。
    static func validatedImageURL(
        _ imageURL: URL,
        workspaceRoot: URL
    ) -> URL? {
        let image = imageURL.resolvingSymlinksInPath().standardizedFileURL
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(image, root: root),
              allowedExtensions.contains(image.pathExtension.lowercased()),
              FileManager.default.isReadableFile(atPath: image.path),
              isRegularFile(image)
        else { return nil }
        guard let byteCount = try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              byteCount <= maximumImageBytes
        else { return nil }
        return image
    }

    /// 从一次打开的文件描述符读取图片，避免校验路径后再次跟随被替换的符号链接。
    static func readImageData(at imageURL: URL, workspaceRoot: URL) -> Data? {
        guard let image = validatedImageURL(imageURL, workspaceRoot: workspaceRoot),
              let descriptor = openWorkspaceDescriptor(
                  at: imageURL,
                  workspaceRoot: workspaceRoot
              )
        else { return nil }
        return readImageData(from: descriptor, expectedPath: image.path)
    }

    /// 没有工作区上下文时也拒绝最终符号链接，并在 descriptor 上执行尺寸限制；
    /// 调用方若有工作区，优先使用上面的带 root 校验重载。
    static func readImageData(at imageURL: URL) -> Data? {
        let image = imageURL.standardizedFileURL
        let descriptor = image.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        return readImageData(from: descriptor, expectedPath: image.path)
    }

    private static func openWorkspaceDescriptor(
        at imageURL: URL,
        workspaceRoot: URL
    ) -> Int32? {
        let target = imageURL.standardizedFileURL
        let lexicalRoot = workspaceRoot.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(target, root: lexicalRoot),
              isInside(resolvedTarget, root: resolvedRoot)
        else { return nil }
        let suffix = String(target.path.dropFirst(lexicalRoot.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        let rootDescriptor = resolvedRoot.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard rootDescriptor >= 0 else { return nil }
        var currentDescriptor = rootDescriptor
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let nextDescriptor = component.withCString { name in
                openat(currentDescriptor, name, flags)
            }
            guard nextDescriptor >= 0 else {
                close(currentDescriptor)
                return nil
            }
            close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func readImageData(
        from descriptor: Int32,
        expectedPath: String
    ) -> Data? {
        var expectedStat = stat()
        guard lstat(expectedPath, &expectedStat) == 0,
              (expectedStat.st_mode & S_IFMT) == S_IFREG
        else {
            close(descriptor)
            return nil
        }
        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              openedStat.st_dev == expectedStat.st_dev,
              openedStat.st_ino == expectedStat.st_ino,
              openedStat.st_size <= off_t(maximumImageBytes)
        else {
            close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.read(upToCount: maximumImageBytes + 1) ?? Data()
        } catch {
            try? handle.close()
            return nil
        }
        try? handle.close()
        guard data.count <= maximumImageBytes else { return nil }
        return data
    }

    private static func escapeAltText(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if character == "\\" || character == "[" || character == "]"
                || character == "\n" || character == "\r" {
                result.append("\\")
            }
            result.append(character)
        }
    }

    private static func escapeAngleDestination(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if character == "\\" || character == "<" || character == ">"
                || character == "\n" || character == "\r" {
                result.append("\\")
            }
            result.append(character)
        }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        if root.path == "/" { return url.path.hasPrefix("/") }
        return url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    /// 只读取图片元数据，不先解码像素；同时检查动画图片的每一帧和总像素预算。
    static func hasSafeImageDimensions(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return hasSafeImageDimensions(source)
    }

    /// 在后台把原图缩成有界预览数据；主线程只需解码小缩略图。
    static func safePreviewData(
        from data: Data,
        maximumPixelSize: Int = 1_600
    ) -> Data? {
        guard hasSafeImageDimensions(data: data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                  ] as CFDictionary
              )
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 嵌入预览在从 Data 解码前调用同一像素上限。
    static func hasSafeImageDimensions(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return hasSafeImageDimensions(source)
    }

    private static func hasSafeImageDimensions(_ source: CGImageSource) -> Bool {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumImageFrameCount else { return false }
        var totalPixels = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as NSDictionary?,
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0,
                  width <= maximumImagePixels / height,
                  totalPixels <= maximumImagePixels - width * height
            else { return false }
            totalPixels += width * height
        }
        return true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
