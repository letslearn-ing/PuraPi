import AppKit
import Foundation
import PiDomain
import SwiftUI

/// 主题文件中的 RGBA 颜色。
///
/// 不把 SwiftUI `Color` 直接写进持久化模型：`Color` 是渲染类型，不是稳定的
/// 跨版本数据格式。未来的主题包只需要编码这个值，平台适配层再把它解析成
/// SwiftUI / AppKit 颜色。
struct PuraPiRGBAColor: Codable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    init?(hexString: String) {
        let normalized = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6 || normalized.count == 8,
              let value = UInt64(normalized, radix: 16)
        else { return nil }

        let hasAlpha = normalized.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha
            ? Double(value & 0xFF) / 255
            : 1
        self.init(
            hex: UInt32(rgb),
            alpha: alpha
        )
    }

    var hexString: String {
        let red = Int((red * 255).rounded())
        let green = Int((green * 255).rounded())
        let blue = Int((blue * 255).rounded())
        let alpha = Int((alpha * 255).rounded())
        if alpha >= 255 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    var color: Color {
        Color(
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }
}

/// 可编码的系统语义颜色。主题可以选择系统颜色，从而继续跟随浅色/深色模式；
/// 只有品牌色等确实需要固定值的地方才使用 RGBA。
enum PuraPiSystemColorRole: String, Codable, Hashable, Sendable {
    case primary
    case secondary
    case tertiary
    case separator
    case windowBackground
    case underPageBackground
    case textBackground
    case red
    case orange
    case green
    case blue
}

enum PuraPiThemeColorSource: Codable, Hashable, Sendable {
    case rgba(PuraPiRGBAColor)
    case system(PuraPiSystemColorRole)

    private enum CodingKeys: String, CodingKey {
        case source
        case value
        case rgba
        case system
    }

    init(from decoder: Decoder) throws {
        // 主题包使用可读的单字符串格式，例如 `#AB83E4` 或
        // `system.separator`。同时接受早期合成 Codable 产生的 keyed 形状，
        // 方便开发期间的主题文件平滑升级。
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            if string.hasPrefix("system."),
               let role = PuraPiSystemColorRole(
                   rawValue: String(string.dropFirst("system.".count))
               ) {
                self = .system(role)
                return
            }
            if let rgba = PuraPiRGBAColor(hexString: string) {
                self = .rgba(rgba)
                return
            }
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let source = try keyed.decodeIfPresent(String.self, forKey: .source) {
            if source == "rgba",
               let value = try keyed.decodeIfPresent(
                   PuraPiRGBAColor.self,
                   forKey: .value
               ) {
                self = .rgba(value)
                return
            }
            if source == "system",
               let value = try keyed.decodeIfPresent(
                   PuraPiSystemColorRole.self,
                   forKey: .value
               ) {
                self = .system(value)
                return
            }
        }
        // 兼容 Swift 自动合成 Codable 曾生成的 `{ "rgba": ... }` 形状。
        if let rgba = try keyed.decodeIfPresent(PuraPiRGBAColor.self, forKey: .rgba) {
            self = .rgba(rgba)
            return
        }
        if let role = try keyed.decodeIfPresent(PuraPiSystemColorRole.self, forKey: .system) {
            self = .system(role)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: single,
            debugDescription: "主题颜色必须是 #RRGGBB、#RRGGBBAA 或 system.<role>"
        )
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .rgba(let rgba):
            try single.encode(rgba.hexString)
        case .system(let role):
            try single.encode("system.\(role.rawValue)")
        }
    }

    var color: Color {
        switch self {
        case .rgba(let rgba):
            return rgba.color
        case .system(let role):
            switch role {
            case .primary:
                return Color(nsColor: .labelColor)
            case .secondary:
                return Color(nsColor: .secondaryLabelColor)
            case .tertiary:
                return Color(nsColor: .tertiaryLabelColor)
            case .separator:
                return Color(nsColor: .separatorColor)
            case .windowBackground:
                return Color(nsColor: .windowBackgroundColor)
            case .underPageBackground:
                return Color(nsColor: .underPageBackgroundColor)
            case .textBackground:
                return Color(nsColor: .textBackgroundColor)
            case .red:
                return .red
            case .orange:
                return .orange
            case .green:
                return .green
            case .blue:
                return .blue
            }
        }
    }
}

/// 带透明度的主题颜色 token（设计令牌）。
struct PuraPiThemeColorToken: Codable, Hashable, Sendable {
    let source: PuraPiThemeColorSource
    let opacity: Double

    init(source: PuraPiThemeColorSource, opacity: Double = 1) {
        self.source = source
        self.opacity = opacity
    }

    var color: Color {
        source.color.opacity(opacity)
    }
}

/// 当前 UI 使用的语义颜色集合。
struct PuraPiThemeColors: Codable, Hashable, Sendable {
    let accent: PuraPiThemeColorToken
    let hairline: PuraPiThemeColorToken
    let windowBackground: PuraPiThemeColorToken
    let workspaceBackground: PuraPiThemeColorToken
    let contentBackground: PuraPiThemeColorToken
    let panelBorder: PuraPiThemeColorToken
    let searchBarBackground: PuraPiThemeColorToken
    let success: PuraPiThemeColorToken
    let warning: PuraPiThemeColorToken
    let error: PuraPiThemeColorToken
    let info: PuraPiThemeColorToken
}

/// 会影响外观但不应改变分栏语义的视觉指标。
///
/// Sidebar/Inspector 的宽度范围和拖动几何仍属于产品布局策略，不能由主题任意
/// 改写；圆角、薄膜透明度等纯视觉指标才放在这里。
struct PuraPiThemeMetrics: Codable, Hashable, Sendable {
    let chromeCornerRadius: Double
    let paneTintOpacity: Double
    let panelBorderWidth: Double
    let smallControlCornerRadius: Double
}

/// 主题的稳定、可持久化定义。它不包含 View、闭包或可执行代码，适合作为未来
/// `.purapitheme` 声明式主题包的基础格式。
struct PuraPiThemeDefinition: Codable, Hashable, Sendable, Identifiable {
    let schemaVersion: Int
    let id: String
    let names: [String: String]
    let summaries: [String: String]
    let colors: PuraPiThemeColors
    let metrics: PuraPiThemeMetrics
}

/// 已解析的运行时主题。
///
/// 定义仍保持可编码；这个类型只负责给 SwiftUI/AppKit 提供解析后的值。
struct PuraPiTheme: Equatable, Identifiable {
    let definition: PuraPiThemeDefinition

    var id: String { definition.id }
    var colors: PuraPiThemeColors { definition.colors }
    var metrics: PuraPiThemeMetrics { definition.metrics }

    func title(language: PuraPiInterfaceLanguage) -> String {
        definition.names[language == .english ? "en" : "zh"]
            ?? definition.names["en"]
            ?? id
    }

    func summary(language: PuraPiInterfaceLanguage) -> String {
        definition.summaries[language == .english ? "en" : "zh"]
            ?? definition.summaries["en"]
            ?? ""
    }

    var accent: Color { colors.accent.color }
    var hairline: Color { colors.hairline.color }
    var windowBackground: Color { colors.windowBackground.color }
    var workspaceBackground: Color { colors.workspaceBackground.color }
    var contentBackground: Color { colors.contentBackground.color }
    var panelBorder: Color { colors.panelBorder.color }
    var searchBarBackground: Color { colors.searchBarBackground.color }
    var success: Color { colors.success.color }
    var warning: Color { colors.warning.color }
    var error: Color { colors.error.color }
    var info: Color { colors.info.color }

    static var `default`: PuraPiTheme {
        PuraPiTheme(definition: PuraPiThemeCatalog.defaultDefinition)
    }
}

/// 内置主题注册表。
///
/// 内置主题保持纯数据注册；用户主题由 `PuraPiThemeStore` 校验后在
/// `PuraPiAppearanceState` 中合并，UI 不需要知道主题来自内置资源还是外部主题包。
enum PuraPiThemeCatalog {
    static let defaultID = "purapi.default"

    /// 主题 ID 会写入用户偏好和外部 theme.json；旧 ID 只作为别名读取，
    /// 新设置和新主题包统一使用 PuraPi 前缀。
    private static let legacyIDAliases: [String: String] = [
        "\(PuraPiLegacyIdentifiers.themeIDPrefix)default": defaultID,
        "\(PuraPiLegacyIdentifiers.themeIDPrefix)midnight": "purapi.midnight",
        "\(PuraPiLegacyIdentifiers.themeIDPrefix)paper": "purapi.paper",
    ]

    static func canonicalID(for id: String) -> String {
        legacyIDAliases[id] ?? id
    }

    private static func system(
        _ role: PuraPiSystemColorRole,
        opacity: Double = 1
    ) -> PuraPiThemeColorToken {
        PuraPiThemeColorToken(source: .system(role), opacity: opacity)
    }

    private static func rgba(
        _ hex: UInt32,
        opacity: Double = 1
    ) -> PuraPiThemeColorToken {
        PuraPiThemeColorToken(
            source: .rgba(PuraPiRGBAColor(hex: hex)),
            opacity: opacity
        )
    }

    /// 当前产品视觉的原样定义。这里的数值必须与迁移前的静态颜色保持一致。
    static let defaultDefinition = PuraPiThemeDefinition(
        schemaVersion: 1,
        id: defaultID,
        names: ["zh": "PuraPi 默认", "en": "PuraPi Default"],
        summaries: [
            "zh": "当前 PuraPi 的紫色玻璃界面。",
            "en": "The current purple glass appearance of PuraPi.",
        ],
        colors: PuraPiThemeColors(
            // 171 / 255, 131 / 255, 228 / 255
            accent: rgba(0xAB83E4),
            hairline: system(.separator, opacity: 0.58),
            windowBackground: system(.windowBackground),
            workspaceBackground: system(.underPageBackground),
            contentBackground: system(.textBackground),
            panelBorder: system(.separator, opacity: 0.72),
            searchBarBackground: system(.windowBackground),
            success: system(.green),
            warning: system(.orange),
            error: system(.red),
            info: system(.blue)
        ),
        metrics: PuraPiThemeMetrics(
            chromeCornerRadius: 18,
            paneTintOpacity: 0.075,
            panelBorderWidth: 0.5,
            smallControlCornerRadius: 9
        )
    )

    /// 供主题页面展示的第二个内置主题。它只替换语义强调色和状态色，系统背景、
    /// 字体与布局保持不变，作为未来外部主题的最小示例。
    static let midnightDefinition = PuraPiThemeDefinition(
        schemaVersion: 1,
        id: "purapi.midnight",
        names: ["zh": "午夜蓝", "en": "Midnight Blue"],
        summaries: [
            "zh": "以冷蓝色为强调色的低干扰主题。",
            "en": "A low-distraction theme with a cool blue accent.",
        ],
        colors: PuraPiThemeColors(
            accent: rgba(0x7AA2F7),
            hairline: system(.separator, opacity: 0.58),
            windowBackground: system(.windowBackground),
            workspaceBackground: system(.underPageBackground),
            contentBackground: system(.textBackground),
            panelBorder: system(.separator, opacity: 0.72),
            searchBarBackground: system(.windowBackground),
            success: system(.green),
            warning: system(.orange),
            error: system(.red),
            info: rgba(0x7AA2F7)
        ),
        metrics: defaultDefinition.metrics
    )

    /// 暖色强调示例，帮助验证主题定义确实能被组件消费，而不是只有设置页换色。
    static let paperDefinition = PuraPiThemeDefinition(
        schemaVersion: 1,
        id: "purapi.paper",
        names: ["zh": "纸张暖灰", "en": "Warm Paper"],
        summaries: [
            "zh": "以暖紫色为强调色的柔和主题。",
            "en": "A softer theme with a warm violet accent.",
        ],
        colors: PuraPiThemeColors(
            accent: rgba(0x9A72C6),
            hairline: system(.separator, opacity: 0.58),
            windowBackground: system(.windowBackground),
            workspaceBackground: system(.underPageBackground),
            contentBackground: system(.textBackground),
            panelBorder: system(.separator, opacity: 0.72),
            searchBarBackground: system(.windowBackground),
            success: system(.green),
            warning: system(.orange),
            error: system(.red),
            info: system(.blue)
        ),
        metrics: defaultDefinition.metrics
    )

    static let builtInDefinitions: [PuraPiThemeDefinition] = [
        defaultDefinition,
        midnightDefinition,
        paperDefinition,
    ]

    static let builtInThemes: [PuraPiTheme] = builtInDefinitions.map(PuraPiTheme.init)

    static func theme(for id: String) -> PuraPiTheme {
        let canonicalID = canonicalID(for: id)
        return builtInThemes.first(where: { $0.id == canonicalID }) ?? .default
    }
}

private struct PuraPiThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = PuraPiTheme.default
}

extension EnvironmentValues {
    /// 当前视图树的主题运行时值。
    var puraPiTheme: PuraPiTheme {
        get { self[PuraPiThemeEnvironmentKey.self] }
        set { self[PuraPiThemeEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// 向 SwiftUI 子树注入主题。AppKit 独立托管的 hosting view 也必须显式调用它。
    func puraPiTheme(_ theme: PuraPiTheme) -> some View {
        environment(\.puraPiTheme, theme)
    }
}
