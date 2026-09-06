import Foundation
import XCTest
@testable import PuraPi

/// 偏好域迁移与项目授权持久化。
///
/// 全部用例都在临时 suite 域中运行，不读写用户真实偏好，也不依赖 `PuraPiPreferences.shared`。
final class PuraPiPreferencesTests: XCTestCase {
    private var targetDomain = ""
    private var legacyDomain = ""
    private var target: UserDefaults!
    private var legacy: UserDefaults!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        targetDomain = "works.purapi.PuraPiTests.target.\(unique)"
        legacyDomain = "PuraPiTests.legacy.\(unique)"
        target = UserDefaults(suiteName: targetDomain)
        legacy = UserDefaults(suiteName: legacyDomain)
    }

    override func tearDown() {
        target.removePersistentDomain(forName: targetDomain)
        legacy.removePersistentDomain(forName: legacyDomain)
        target = nil
        legacy = nil
        super.tearDown()
    }

    func testMigrationCopiesKnownKeysFromLegacyDomain() {
        legacy.set("dark", forKey: PuraPiPreferences.Key.appearanceMode)
        legacy.set("purapi.midnight", forKey: PuraPiPreferences.Key.themeID)
        legacy.set("english", forKey: PuraPiPreferences.Key.interfaceLanguage)
        legacy.set(false, forKey: PuraPiPreferences.Key.sidebarVisible)
        legacy.set(324.5, forKey: PuraPiPreferences.Key.sidebarWidth)
        legacy.set(455.0, forKey: PuraPiPreferences.Key.inspectorWidth)
        legacy.set("teal", forKey: PuraPiPreferences.Key.sidebarTintID)
        legacy.set("orange", forKey: PuraPiPreferences.Key.inspectorTintID)
        legacy.set(
            ["/tmp/project-a", "/tmp/project-b"],
            forKey: PuraPiPreferences.Key.rememberedAuthorizedProjects
        )
        legacy.set(
            "/custom/pi",
            forKey: PuraPiPreferences.Key.runtimeExecutablePath
        )

        let migrated = PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertEqual(Set(migrated), Set(PuraPiPreferences.Key.migratable))
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.appearanceMode), "dark")
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.themeID), "purapi.midnight")
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.interfaceLanguage), "english")
        XCTAssertEqual(target.object(forKey: PuraPiPreferences.Key.sidebarVisible) as? Bool, false)
        XCTAssertEqual(target.double(forKey: PuraPiPreferences.Key.sidebarWidth), 324.5, accuracy: 0.001)
        XCTAssertEqual(target.double(forKey: PuraPiPreferences.Key.inspectorWidth), 455.0, accuracy: 0.001)
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.sidebarTintID), "teal")
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.inspectorTintID), "orange")
        XCTAssertEqual(
            target.stringArray(forKey: PuraPiPreferences.Key.rememberedAuthorizedProjects),
            ["/tmp/project-a", "/tmp/project-b"]
        )
        XCTAssertEqual(
            target.string(forKey: PuraPiPreferences.Key.runtimeExecutablePath),
            "/custom/pi"
        )
    }

    /// 授权记录属于安全语义，迁移不能丢。
    func testMigrationMapsLegacyWorkPiKeysIntoPuraPiKeys() {
        legacy.set("dark", forKey: "WorkPi.appearanceMode")
        legacy.set("workpi.midnight", forKey: "WorkPi.themeID")

        let migrated = PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertTrue(migrated.contains(PuraPiPreferences.Key.appearanceMode))
        XCTAssertTrue(migrated.contains(PuraPiPreferences.Key.themeID))
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.appearanceMode), "dark")
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.themeID), "workpi.midnight")
    }

    func testMigrationPreservesRememberedAuthorizationList() {
        legacy.set(
            ["/Users/example/work/researchDSH"],
            forKey: PuraPiPreferences.Key.rememberedAuthorizedProjects
        )

        PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertTrue(
            PuraPiProjectAuthorization.isRemembered(
                for: URL(fileURLWithPath: "/Users/example/work/researchDSH"),
                defaults: target
            )
        )
    }

    func testMigrationDoesNotOverwriteExistingTargetValues() {
        target.set("light", forKey: PuraPiPreferences.Key.appearanceMode)
        legacy.set("dark", forKey: PuraPiPreferences.Key.appearanceMode)
        legacy.set(true, forKey: PuraPiPreferences.Key.sidebarVisible)

        let migrated = PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertFalse(migrated.contains(PuraPiPreferences.Key.appearanceMode))
        XCTAssertEqual(target.string(forKey: PuraPiPreferences.Key.appearanceMode), "light")
        XCTAssertEqual(target.object(forKey: PuraPiPreferences.Key.sidebarVisible) as? Bool, true)
    }

    func testMigrationRunsOnlyOnce() {
        legacy.set("dark", forKey: PuraPiPreferences.Key.appearanceMode)
        let first = PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )
        XCTAssertEqual(first, [PuraPiPreferences.Key.appearanceMode])

        // 用户随后在新域清除了该键；再次启动不应把历史值重新搬回来。
        target.removeObject(forKey: PuraPiPreferences.Key.appearanceMode)
        let second = PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertTrue(second.isEmpty)
        XCTAssertNil(target.string(forKey: PuraPiPreferences.Key.appearanceMode))
        XCTAssertTrue(target.bool(forKey: PuraPiPreferences.migrationKey))
    }

    func testMigrationIsSkippedWhenLegacyDomainMatchesTarget() {
        let migrated = PuraPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: PuraPiPreferences.domain
        )

        XCTAssertTrue(migrated.isEmpty)
        XCTAssertTrue(target.bool(forKey: PuraPiPreferences.migrationKey))
    }

    func testLegacyDomainNameFallsBackToProcessNameWithoutBundleIdentifier() {
        XCTAssertEqual(
            PuraPiPreferences.legacyExecutableDomainName(
                bundle: Bundle(for: Self.self),
                processName: "PuraPi"
            ),
            Bundle(for: Self.self).bundleIdentifier ?? "PuraPi"
        )
    }

    func testRememberAndForgetProjectAuthorization() {
        let url = URL(fileURLWithPath: "/tmp/purapi-preferences-project")

        XCTAssertFalse(PuraPiProjectAuthorization.isRemembered(for: url, defaults: target))

        PuraPiProjectAuthorization.remember(url, defaults: target)
        XCTAssertTrue(PuraPiProjectAuthorization.isRemembered(for: url, defaults: target))
        XCTAssertEqual(
            PuraPiProjectAuthorization.rememberedProjectPaths(defaults: target),
            [url.resolvingSymlinksInPath().standardizedFileURL.path]
        )

        // 重复记住不应产生重复条目。
        PuraPiProjectAuthorization.remember(url, defaults: target)
        XCTAssertEqual(PuraPiProjectAuthorization.rememberedProjectPaths(defaults: target).count, 1)

        PuraPiProjectAuthorization.forget(url, defaults: target)
        XCTAssertFalse(PuraPiProjectAuthorization.isRemembered(for: url, defaults: target))
        XCTAssertTrue(PuraPiProjectAuthorization.rememberedProjectPaths(defaults: target).isEmpty)
    }
}
