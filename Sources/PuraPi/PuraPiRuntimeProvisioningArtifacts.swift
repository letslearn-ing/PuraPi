import CryptoKit
import Foundation

enum PuraPiRuntimeBoundedFile {
    static func data(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? handle.close() }
        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        guard let data = try? handle.read(upToCount: readLimit),
              data.count <= maximumBytes
        else { return nil }
        return data
    }
}

extension PuraPiNodeArtifact {
    static func verify(
        archiveURL: URL,
        expectedSHA256: String
    ) throws {
        let normalizedExpected = expectedSHA256.lowercased()
        guard normalizedExpected.count == 64,
              normalizedExpected.allSatisfy({ $0.isHexDigit })
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("官方校验和格式无效。")
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: archiveURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: archiveURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0,
              size <= Int64(PuraPiRuntimePolicy.maxNodeArchiveBytes)
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("Node.js 下载文件大小无效。")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            throw PuraPiRuntimeProvisioningError.verificationFailed("无法读取 Node.js 下载文件。")
        }
        defer { try? handle.close() }

        var digest = SHA256()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 1024 * 1024) else { break }
                chunk = next
            } catch {
                throw PuraPiRuntimeProvisioningError.verificationFailed("读取 Node.js 下载文件失败。")
            }
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == normalizedExpected else {
            throw PuraPiRuntimeProvisioningError.verificationFailed(
                "Node.js 下载文件校验和不匹配。"
            )
        }
    }
}
