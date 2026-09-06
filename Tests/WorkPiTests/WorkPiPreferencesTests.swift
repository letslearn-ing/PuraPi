import Foundation
import XCTest
@testable import WorkPi

/// 偏好域迁移与项目授权持久化。
///
/// 全部用例都在临时 suite 域中运行，不读写用户真实偏好，也不依赖 `WorkPiPreferences.shared`。
final class WorkPiPreferencesTests: XCTestCase {
    private var targetDomain = ""
    private var legacyDomain = ""
    private var target: UserDefaults!
    private var legacy: UserDefaults!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        targetDomain = "works.workpi.WorkPiTests.target.\(unique)"
        legacyDomain = "WorkPiTests.legacy.\(unique)"
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
        legacy.set("dark", forKey: WorkPiPreferences.Key.appearanceMode)
        legacy.set("workpi.midnight", forKey: WorkPiPreferences.Key.themeID)
        legacy.set("english", forKey: WorkPiPreferences.Key.interfaceLanguage)
        legacy.set(false, forKey: WorkPiPreferences.Key.sidebarVisible)
        legacy.set(324.5, forKey: WorkPiPreferences.Key.sidebarWidth)
        legacy.set(455.0, forKey: WorkPiPreferences.Key.inspectorWidth)
        legacy.set("teal", forKey: WorkPiPreferences.Key.sidebarTintID)
        legacy.set("orange", forKey: WorkPiPreferences.Key.inspectorTintID)
        legacy.set(
            ["/tmp/project-a", "/tmp/project-b"],
            forKey: WorkPiPreferences.Key.rememberedAuthorizedProjects
        )
        legacy.set(
            "/custom/pi",
            forKey: WorkPiPreferences.Key.runtimeExecutablePath
        )

        let migrated = WorkPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertEqual(Set(migrated), Set(WorkPiPreferences.Key.migratable))
        XCTAssertEqual(target.string(forKey: WorkPiPreferences.Key.appearanceMode), "dark")
        XCTAssertEqual(target.string(forKey: WorkPiPreferences.Key.themeID), "workpi.midnight")
        XCTAssertEqual(target.string(forKey: WorkPiPreferences.Key.interfaceLanguage), "english")
        XCTAssertEqual(target.object(forKey: WorkPiPreferences.Key.sidebarVisible) as? Bool, false)
        XCTAssertEqual(target.double(forKey: WorkPiPreferences.Key.sidebarWidth), 324.5, accuracy: 0.001)
        XCTAssertEqual(target.double(forKey: WorkPiPreferences.Key.inspectorWidth), 455.0, accuracy: 0.001)
        XCTAssertEqual(target.string(forKey: WorkPiPreferences.Key.sidebarTintID), "teal")
        XCTAssertEqual(target.string(forKey: WorkPiPreferences.Key.inspectorTintID), "orange")
        XCTAssertEqual(
            target.stringArray(forKey: WorkPiPreferences.Key.rememberedAuthorizedProjects),
            ["/tmp/project-a", "/tmp/project-b"]
        )
        XCTAssertEqual(
            target.string(forKey: WorkPiPreferences.Key.runtimeExecutablePath),
            "/custom/pi"
        )
    }

    /// 授权记录属于安全语义，迁移不能丢。
    func testMigrationPreservesRememberedAuthorizationList() {
        legacy.set(
            ["/Users/example/work/researchDSH"],
            forKey: WorkPiPreferences.Key.rememberedAuthorizedProjects
        )

        WorkPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertTrue(
            WorkPiProjectAuthorization.isRemembered(
                for: URL(fileURLWithPath: "/Users/example/work/researchDSH"),
                defaults: target
            )
        )
    }

    func testMigrationDoesNotOverwriteExistingTargetValues() {
        target.set("light", forKey: WorkPiPreferences.Key.appearanceMode)
        legacy.set("dark", forKey: WorkPiPreferences.Key.appearanceMode)
        legacy.set(true, forKey: WorkPiPreferences.Key.sidebarVisible)

        let migrated = WorkPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertFalse(migrated.contains(WorkPiPreferences.Key.appearanceMode))
        XCTAssertEqual(target.string(forKey: WorkPiPreferences.Key.appearanceMode), "light")
        XCTAssertEqual(target.object(forKey: WorkPiPreferences.Key.sidebarVisible) as? Bool, true)
    }

    func testMigrationRunsOnlyOnce() {
        legacy.set("dark", forKey: WorkPiPreferences.Key.appearanceMode)
        let first = WorkPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )
        XCTAssertEqual(first, [WorkPiPreferences.Key.appearanceMode])

        // 用户随后在新域清除了该键；再次启动不应把历史值重新搬回来。
        target.removeObject(forKey: WorkPiPreferences.Key.appearanceMode)
        let second = WorkPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: legacyDomain
        )

        XCTAssertTrue(second.isEmpty)
        XCTAssertNil(target.string(forKey: WorkPiPreferences.Key.appearanceMode))
        XCTAssertTrue(target.bool(forKey: WorkPiPreferences.migrationKey))
    }

    func testMigrationIsSkippedWhenLegacyDomainMatchesTarget() {
        let migrated = WorkPiPreferences.migrateFromLegacyDomainIfNeeded(
            into: target,
            legacyDomainName: WorkPiPreferences.domain
        )

        XCTAssertTrue(migrated.isEmpty)
        XCTAssertTrue(target.bool(forKey: WorkPiPreferences.migrationKey))
    }

    func testLegacyDomainNameFallsBackToProcessNameWithoutBundleIdentifier() {
        XCTAssertEqual(
            WorkPiPreferences.legacyExecutableDomainName(
                bundle: Bundle(for: Self.self),
                processName: "WorkPi"
            ),
            Bundle(for: Self.self).bundleIdentifier ?? "WorkPi"
        )
    }

    func testRememberAndForgetProjectAuthorization() {
        let url = URL(fileURLWithPath: "/tmp/workpi-preferences-project")

        XCTAssertFalse(WorkPiProjectAuthorization.isRemembered(for: url, defaults: target))

        WorkPiProjectAuthorization.remember(url, defaults: target)
        XCTAssertTrue(WorkPiProjectAuthorization.isRemembered(for: url, defaults: target))
        XCTAssertEqual(
            WorkPiProjectAuthorization.rememberedProjectPaths(defaults: target),
            [url.resolvingSymlinksInPath().standardizedFileURL.path]
        )

        // 重复记住不应产生重复条目。
        WorkPiProjectAuthorization.remember(url, defaults: target)
        XCTAssertEqual(WorkPiProjectAuthorization.rememberedProjectPaths(defaults: target).count, 1)

        WorkPiProjectAuthorization.forget(url, defaults: target)
        XCTAssertFalse(WorkPiProjectAuthorization.isRemembered(for: url, defaults: target))
        XCTAssertTrue(WorkPiProjectAuthorization.rememberedProjectPaths(defaults: target).isEmpty)
    }
}
