import Foundation

/// PuraPi 结构性更名后的兼容标识集中表。
///
/// 这些值只用于读取/迁移旧版本数据或兼容旧版扩展，不能作为新的用户可见名称、
/// 新的持久化键或新的协议生产值。集中管理可以让更名审计明确区分“新品牌”和
/// 必须保留的 legacy（旧版本兼容）边界。
public enum PuraPiLegacyIdentifiers {
    public static let bundleIdentifier = "works.workpi.WorkPi"
    public static let executableDomain = "WorkPi"
    public static let preferencesPrefix = "WorkPi."

    public static let runtimeDirectoryName = "WorkPi"
    public static let themesDirectoryName = "WorkPi"
    public static let runtimeManagedInstallationSource = "workPiManaged"
    public static let themePackageExtension = "workpitheme"
    public static let themeIDPrefix = "workpi."

    public static let subagentWidgetKey = "workpi.subagent.panel"
    public static let subagentLinePrefix = "WORKPI_SUBAGENT_PANEL_V1 "
    public static let markdownBlockUTI = "com.workpi.markdown-block"

    public static let windowAutosaveName = "WorkPi.mainWindow"
}
