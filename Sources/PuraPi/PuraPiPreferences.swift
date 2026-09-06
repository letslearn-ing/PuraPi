import Foundation
import PiDomain

/// PuraPi 本地偏好的唯一读写入口。
///
/// 之所以需要这一层：SwiftPM 直接运行可执行文件时，`UserDefaults.standard`
/// 落在由可执行文件名推导出的域（`PuraPi`），一旦将来补上 `Info.plist` 和正式
/// bundle identifier，域会整体改变，已保存的外观、Sidebar 几何和项目授权记录
/// 会静默失效。授权记录属于安全语义，不允许在用户无感知的情况下丢失。
///
/// 因此这里固定使用显式命名的持久化域 `PuraPiPreferences.domain`，并在首次
/// 访问时把历史域中的已知键（包括主题选择）迁移过来。视图和状态类型只依赖
/// 这个入口，不再各自触碰 `UserDefaults`。
enum PuraPiPreferences {
    /// 最终 bundle identifier；打包后与 `.app` 的 bundle id 保持一致，
    /// 使无包运行和正式分发共享同一份偏好。
    static let domain = "works.purapi.PuraPi"

    /// 迁移标记本身也存在目标域中，保证迁移只执行一次。
    static let migrationKey = "PuraPi.preferencesMigratedFromLegacyDomain"

    enum Key {
        static let appearanceMode = "PuraPi.appearanceMode"
        static let themeID = "PuraPi.themeID"
        static let interfaceLanguage = "PuraPi.interfaceLanguage"
        static let sidebarVisible = "PuraPi.sidebarVisible"
        static let sidebarWidth = "PuraPi.sidebarWidth"
        static let inspectorWidth = "PuraPi.inspectorWidth"
        static let sidebarTintID = "PuraPi.sidebarTintID"
        static let inspectorTintID = "PuraPi.inspectorTintID"
        static let rememberedAuthorizedProjects = "PuraPi.rememberedAuthorizedProjects"
        static let runtimeExecutablePath = "PuraPi.runtimeExecutablePath"

        /// 迁移覆盖的全部业务键；新增偏好键时必须同时登记到这里。
        static let migratable = [
            appearanceMode,
            themeID,
            interfaceLanguage,
            sidebarVisible,
            sidebarWidth,
            inspectorWidth,
            sidebarTintID,
            inspectorTintID,
            rememberedAuthorizedProjects,
            runtimeExecutablePath,
        ]
    }

    /// 进程内共享的存储。首次访问时执行历史域迁移。
    /// Foundation 的 UserDefaults 尚未声明 Sendable；PuraPi 的业务访问都在
    /// MainActor，`nonisolated(unsafe)` 只用于表达这一现有隔离边界。
    nonisolated(unsafe) static let shared: UserDefaults = {
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        migrateFromLegacyDomainIfNeeded(into: defaults)
        return defaults
    }()

    /// 把旧可执行文件域、旧 bundle suite 域中的已知键搬到目标域。
    ///
    /// 只在目标域尚未标记迁移时执行；只复制目标域中还不存在的键，避免覆盖
    /// 用户在新域中的更新。历史域保持不变，便于回滚核对。旧版本的键名也会
    /// 被读取：例如 `WorkPi.appearanceMode` 会迁移到新的 `PuraPi.appearanceMode`。
    @discardableResult
    static func migrateFromLegacyDomainIfNeeded(
        into defaults: UserDefaults,
        legacyDomainName: String = legacyExecutableDomainName(),
        markCompletion: Bool = true
    ) -> [String] {
        guard defaults.bool(forKey: migrationKey) == false else { return [] }

        let knownLegacyDomains = legacyDomainName == legacyExecutableDomainName()
            ? [
                PuraPiLegacyIdentifiers.bundleIdentifier,
                PuraPiLegacyIdentifiers.executableDomain,
            ]
            : []
        let candidateDomains = ([legacyDomainName] + knownLegacyDomains)
            .reduce(into: [String]()) { result, candidate in
            guard candidate != domain, !candidate.isEmpty, !result.contains(candidate) else {
                return
            }
            result.append(candidate)
        }

        var migratedKeys: [String] = []
        for domainName in candidateDomains {
            guard let legacy = UserDefaults(suiteName: domainName) else { continue }
            for key in Key.migratable where !migratedKeys.contains(key) {
                guard defaults.object(forKey: key) == nil else { continue }
                let oldKey = key.replacingOccurrences(
                    of: "PuraPi.",
                    with: PuraPiLegacyIdentifiers.preferencesPrefix
                )
                guard let value = legacy.object(forKey: key) ?? legacy.object(forKey: oldKey) else {
                    continue
                }
                defaults.set(value, forKey: key)
                migratedKeys.append(key)
            }
        }

        if markCompletion { defaults.set(true, forKey: migrationKey) }
        return migratedKeys
    }

    /// SwiftPM 无包运行时，`UserDefaults.standard` 使用的历史域名。
    static func legacyExecutableDomainName(
        bundle: Bundle = .main,
        processName: String = ProcessInfo.processInfo.processName
    ) -> String {
        bundle.bundleIdentifier ?? processName
    }
}
