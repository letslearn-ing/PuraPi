import Foundation

/// WorkPi 本地偏好的唯一读写入口。
///
/// 之所以需要这一层：SwiftPM 直接运行可执行文件时，`UserDefaults.standard`
/// 落在由可执行文件名推导出的域（`WorkPi`），一旦将来补上 `Info.plist` 和正式
/// bundle identifier，域会整体改变，已保存的外观、Sidebar 几何和项目授权记录
/// 会静默失效。授权记录属于安全语义，不允许在用户无感知的情况下丢失。
///
/// 因此这里固定使用显式命名的持久化域 `WorkPiPreferences.domain`，并在首次
/// 访问时把历史域中的已知键（包括主题选择）迁移过来。视图和状态类型只依赖
/// 这个入口，不再各自触碰 `UserDefaults`。
enum WorkPiPreferences {
    /// 最终 bundle identifier；打包后与 `.app` 的 bundle id 保持一致，
    /// 使无包运行和正式分发共享同一份偏好。
    static let domain = "works.workpi.WorkPi"

    /// 迁移标记本身也存在目标域中，保证迁移只执行一次。
    static let migrationKey = "WorkPi.preferencesMigratedFromExecutableDomain"

    enum Key {
        static let appearanceMode = "WorkPi.appearanceMode"
        static let themeID = "WorkPi.themeID"
        static let interfaceLanguage = "WorkPi.interfaceLanguage"
        static let sidebarVisible = "WorkPi.sidebarVisible"
        static let sidebarWidth = "WorkPi.sidebarWidth"
        static let inspectorWidth = "WorkPi.inspectorWidth"
        static let sidebarTintID = "WorkPi.sidebarTintID"
        static let inspectorTintID = "WorkPi.inspectorTintID"
        static let rememberedAuthorizedProjects = "WorkPi.rememberedAuthorizedProjects"
        static let runtimeExecutablePath = "WorkPi.runtimeExecutablePath"

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
    /// Foundation 的 UserDefaults 尚未声明 Sendable；WorkPi 的业务访问都在
    /// MainActor，`nonisolated(unsafe)` 只用于表达这一现有隔离边界。
    nonisolated(unsafe) static let shared: UserDefaults = {
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        migrateFromLegacyDomainIfNeeded(into: defaults)
        return defaults
    }()

    /// 把可执行文件名推导域中的已知键搬到目标域。
    ///
    /// 只在目标域尚未标记迁移时执行；只复制目标域中还不存在的键，避免覆盖
    /// 用户在新域中的更新。历史域保持不变，便于回滚核对。
    @discardableResult
    static func migrateFromLegacyDomainIfNeeded(
        into defaults: UserDefaults,
        legacyDomainName: String = legacyExecutableDomainName(),
        markCompletion: Bool = true
    ) -> [String] {
        guard defaults.bool(forKey: migrationKey) == false else { return [] }
        guard legacyDomainName != domain,
              let legacy = UserDefaults(suiteName: legacyDomainName)
        else {
            if markCompletion { defaults.set(true, forKey: migrationKey) }
            return []
        }

        var migratedKeys: [String] = []
        for key in Key.migratable {
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key)
            else { continue }
            defaults.set(value, forKey: key)
            migratedKeys.append(key)
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
