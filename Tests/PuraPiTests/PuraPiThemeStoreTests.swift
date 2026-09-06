import CryptoKit
import Foundation
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiThemeStoreTests: XCTestCase {
    func testLoadsPreviewAssetsAndChecksums() throws {
        let (root, packageURL) = try makePackage(id: "com.example.ocean", includeChecksum: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PuraPiThemeStore(directoryURL: root)
        let package = try store.loadPackage(at: packageURL)

        XCTAssertEqual(package.id, "com.example.ocean")
        XCTAssertNotNil(package.previewImageURL)
        XCTAssertEqual(package.assets.keys.sorted(), ["sample.txt"])
        XCTAssertTrue(package.checksumValidated)
        XCTAssertFalse(package.needsMigration)
        XCTAssertEqual(store.themes().last?.id, package.id)
    }

    func testMissingSchemaCanBeMigratedExplicitly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-theme-migrate-\(UUID().uuidString)")
        let packageURL = root.appendingPathComponent("com.example.migrate.purapitheme")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalTheme = try definitionData(id: "com.example.migrate", includeSchema: false)
        try originalTheme.write(to: packageURL.appendingPathComponent("theme.json"))
        let originalHash = SHA256.hash(data: originalTheme).map {
            String(format: "%02x", $0)
        }.joined()
        let manifest: [String: Any] = ["checksums": ["theme.json": originalHash]]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: packageURL.appendingPathComponent("manifest.json"))

        let store = PuraPiThemeStore(directoryURL: root)
        let before = try store.loadPackage(at: packageURL)
        XCTAssertTrue(before.needsMigration)

        let after = try store.migrate(packageAt: packageURL)
        XCTAssertFalse(after.needsMigration)
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageURL.appendingPathComponent("theme.json"))
        ) as? [String: Any]
        XCTAssertEqual((json?["schemaVersion"] as? NSNumber)?.intValue, 1)
    }

    func testChecksumMismatchAndExecutableAssetAreRejected() throws {
        let (root, packageURL) = try makePackage(id: "com.example.invalid", includeChecksum: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = packageURL.appendingPathComponent("assets/sample.txt")
        try "tampered".write(to: asset, atomically: true, encoding: .utf8)
        let store = PuraPiThemeStore(directoryURL: root)
        XCTAssertThrowsError(try store.loadPackage(at: packageURL)) { error in
            guard case .checksumMismatch = error as? PuraPiThemeStoreError else {
                return XCTFail("应报告 checksum mismatch，实际为 \(error)")
            }
        }

        let executablePackage = root.appendingPathComponent("com.example.script.purapitheme")
        try FileManager.default.createDirectory(
            at: executablePackage.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try definitionData(id: "com.example.script")
            .write(to: executablePackage.appendingPathComponent("theme.json"))
        try "#!/bin/sh".write(
            to: executablePackage.appendingPathComponent("assets/run.sh"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertThrowsError(try store.loadPackage(at: executablePackage))
    }

    func testAppearanceStateExposesValidatedUserThemes() throws {
        let (root, _) = try makePackage(id: "com.example.appearance", includeChecksum: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "PuraPi-theme-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let state = PuraPiAppearanceState(
            defaults: defaults,
            themeStore: PuraPiThemeStore(directoryURL: root)
        )
        XCTAssertTrue(state.availableThemes.contains(where: { $0.id == "com.example.appearance" }))
        state.setTheme(id: "com.example.appearance")
        XCTAssertEqual(state.theme.id, "com.example.appearance")
        XCTAssertEqual(
            defaults.string(forKey: PuraPiPreferences.Key.themeID),
            "com.example.appearance"
        )
    }

    func testLegacyThemeDirectoryAndExtensionRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-theme-new-\(UUID().uuidString)")
        let legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-theme-legacy-\(UUID().uuidString)")
        let (_, packageURL) = try makePackage(
            id: "com.example.legacy",
            parent: legacyRoot,
            includeChecksum: false,
            packageExtension: "workpitheme"
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: legacyRoot)
        }

        let store = PuraPiThemeStore(
            directoryURL: root,
            legacyDirectoryURL: legacyRoot
        )
        XCTAssertEqual(store.scan().map(\.id), ["com.example.legacy"])
        XCTAssertEqual(
            try store.loadPackage(id: "com.example.legacy").packageURL.path,
            packageURL.path
        )
        XCTAssertThrowsError(try store.delete(id: "com.example.legacy")) { error in
            XCTAssertEqual(
                error as? PuraPiThemeStoreError,
                .cannotDeleteLegacy("com.example.legacy")
            )
        }
        XCTAssertEqual(store.scan().map(\.id), ["com.example.legacy"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testLegacyBuiltInThemeIDResolvesToPuraPiTheme() {
        XCTAssertEqual(
            PuraPiThemeCatalog.theme(for: "workpi.midnight").id,
            "purapi.midnight"
        )
        XCTAssertEqual(
            PuraPiThemeCatalog.canonicalID(for: "workpi.default"),
            PuraPiThemeCatalog.defaultID
        )
    }

    func testMergeReplacesUserPackageAndDeleteProtectsBuiltIns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-theme-store-\(UUID().uuidString)")
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-theme-source-\(UUID().uuidString)")
        let (_, sourcePackage) = try makePackage(
            id: "com.example.merge",
            parent: sourceRoot,
            includeChecksum: false
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let store = PuraPiThemeStore(directoryURL: root)
        let merged = try store.merge(packageAt: sourcePackage)
        XCTAssertEqual(merged.id, "com.example.merge")
        XCTAssertTrue(FileManager.default.fileExists(atPath: merged.packageURL.path))
        XCTAssertEqual(store.scan().map(\.id), ["com.example.merge"])
        let replaced = try store.merge(packageAt: sourcePackage)
        XCTAssertEqual(replaced.id, "com.example.merge")
        XCTAssertEqual(store.scan().count, 1)

        XCTAssertThrowsError(try store.delete(id: PuraPiThemeCatalog.defaultID)) { error in
            guard case .cannotDeleteBuiltIn = error as? PuraPiThemeStoreError else {
                return XCTFail("内置主题必须不可删除")
            }
        }
        try store.delete(id: "com.example.merge")
        XCTAssertTrue(store.scan().isEmpty)
    }

    // MARK: - Helpers

    private func makePackage(
        id: String,
        parent: URL? = nil,
        includeChecksum: Bool,
        packageExtension: String = PuraPiThemeStore.packageExtension
    ) throws -> (URL, URL) {
        let root = parent ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-theme-package-\(UUID().uuidString)")
        let packageURL = root.appendingPathComponent("\(id).\(packageExtension)")
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try definitionData(id: id).write(to: packageURL.appendingPathComponent("theme.json"))
        try Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01,
        ]).write(to: packageURL.appendingPathComponent("preview.png"))
        try "asset".write(
            to: packageURL.appendingPathComponent("assets/sample.txt"),
            atomically: true,
            encoding: .utf8
        )
        if includeChecksum {
            let paths = ["theme.json", "preview.png", "assets/sample.txt"]
            var checksums: [String: String] = [:]
            for path in paths {
                let data = try Data(contentsOf: packageURL.appendingPathComponent(path))
                checksums[path] = SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
            }
            let manifest: [String: Any] = ["checksums": checksums]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try data.write(to: packageURL.appendingPathComponent("manifest.json"))
        }
        return (root, packageURL)
    }

    private func definitionData(id: String, includeSchema: Bool = true) throws -> Data {
        let original = try JSONEncoder().encode(PuraPiThemeCatalog.defaultDefinition)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        object["id"] = id
        object["names"] = ["zh": "测试主题", "en": "Test Theme"]
        object["summaries"] = ["zh": "用于测试", "en": "Theme for tests"]
        if includeSchema {
            object["schemaVersion"] = 1
        } else {
            object.removeValue(forKey: "schemaVersion")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
