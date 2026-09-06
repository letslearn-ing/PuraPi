import Foundation

extension PuraPiRuntimeManagedStore {
    func isManagedExecutable(_ url: URL) -> Bool {
        currentInstallation()?.executableURL.standardizedFileURL == url.standardizedFileURL
    }

    func isValidPiRelease(
        at release: URL,
        version: PuraPiRuntimeVersion
    ) -> Bool {
        guard isDirectChild(release, of: locations.piReleasesURL),
              release.lastPathComponent == version.description,
              isSafeDirectory(release)
        else { return false }
        return isSafeExecutable(locations.piExecutableURL(for: version), inside: release)
    }

    func isValidNodeRelease(
        at release: URL,
        version: PuraPiRuntimeVersion
    ) -> Bool {
        guard isDirectChild(release, of: locations.nodeReleasesURL),
              release.lastPathComponent == version.description,
              isSafeDirectory(release)
        else { return false }
        let node = locations.nodeExecutableURL(for: version)
        let npm = locations.npmExecutableURL(for: version)
        return isSafeExecutable(node, inside: release)
            && isSafeExecutable(npm, inside: release)
    }

    private func isDirectChild(_ url: URL, of parent: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard !isSymbolicLink(url) else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return resolved == url.standardizedFileURL
    }

    private func isSafeExecutable(_ url: URL, inside directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: url.path) else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let root = directory.standardizedFileURL.path
        let path = resolved.path
        guard path.hasPrefix(root + "/") else { return false }
        return fileManager.isExecutableFile(atPath: resolved.path)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}
