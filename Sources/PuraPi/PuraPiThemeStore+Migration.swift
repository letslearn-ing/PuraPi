import CryptoKit
import Foundation

extension PuraPiThemeStore {
    /// 迁移 schema 时同步更新包声明的 `theme.json` 校验和；未知格式会在
    /// 迁移后的重新加载阶段被拒绝，调用方可以回滚原文件。
    func updateDeclaredThemeChecksumIfNeeded(
        in root: URL,
        data: Data
    ) throws {
        let hash = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        let fileManager = FileManager.default

        for name in ["manifest.json", "checksums.json", "checksum.json"] {
            let url = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let manifestData = try readBoundedData(
                at: url,
                maximumBytes: maximumThemeJSONBytes,
                relativePath: name
            )
            guard var object = try JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
            else {
                throw PuraPiThemeStoreError.invalidPackage("\(name) 不是 JSON 对象")
            }
            var changed = false
            for key in ["checksums", "files"] {
                guard var checksums = object[key] as? [String: Any],
                      checksums["theme.json"] != nil
                else { continue }
                checksums["theme.json"] = hash
                object[key] = checksums
                changed = true
            }
            if !changed,
               (name == "checksums.json" || name == "checksum.json"),
               object["theme.json"] != nil {
                object["theme.json"] = hash
                changed = true
            }
            if changed {
                let updated = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
                try writeAtomically(updated, to: url)
            }
        }

        let checksumURL = root.appendingPathComponent("checksum.sha256")
        if fileManager.fileExists(atPath: checksumURL.path) {
            let checksumData = try readBoundedData(
                at: checksumURL,
                maximumBytes: maximumThemeJSONBytes,
                relativePath: "checksum.sha256"
            )
            guard let text = String(data: checksumData, encoding: .utf8) else {
                throw PuraPiThemeStoreError.invalidPackage("checksum.sha256 不是 UTF-8")
            }
            var lines = text.components(separatedBy: CharacterSet.newlines)
            var changed = false
            for index in lines.indices {
                let parts = lines[index].split(
                    maxSplits: 1,
                    whereSeparator: { $0.isWhitespace }
                )
                guard parts.count == 2 else { continue }
                let path = String(parts[1])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                guard path == "theme.json" else { continue }
                let suffix = String(lines[index].dropFirst(parts[0].count))
                lines[index] = hash + suffix
                changed = true
            }
            if changed {
                try writeAtomically(
                    Data(lines.joined(separator: "\n").utf8),
                    to: checksumURL
                )
            }
        }
    }

    func writeAtomically(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".purapi-theme-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PuraPiThemeStoreError.io(error.localizedDescription)
        }
    }
}
