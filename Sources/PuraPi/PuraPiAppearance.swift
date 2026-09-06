import AppKit
import Combine
import SwiftUI

enum PuraPiInterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    static var systemDefault: Self {
        Locale.current.language.languageCode?.identifier == "zh" ? .chinese : .english
    }
}

enum PuraPiAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class PuraPiAppearanceState: ObservableObject {
    static let modeKey = PuraPiPreferences.Key.appearanceMode
    static let themeKey = PuraPiPreferences.Key.themeID
    static let languageKey = PuraPiPreferences.Key.interfaceLanguage

    @Published private(set) var mode: PuraPiAppearanceMode
    @Published private(set) var theme: PuraPiTheme
    @Published private(set) var availableThemes: [PuraPiTheme]
    @Published private(set) var language: PuraPiInterfaceLanguage
    /// 左侧 Sidebar 的表面主题色。
    @Published private(set) var sidebarTint: PuraPiPaneTint
    /// 右侧 Inspector 的表面主题色。
    @Published private(set) var inspectorTint: PuraPiPaneTint
    private let defaults: UserDefaults
    private let themeStore: PuraPiThemeStore

    init(
        defaults: UserDefaults = PuraPiPreferences.shared,
        themeStore: PuraPiThemeStore = PuraPiThemeStore()
    ) {
        self.defaults = defaults
        self.themeStore = themeStore
        let loadedThemes = themeStore.themes()
        availableThemes = loadedThemes
        let rawValue = defaults.string(forKey: Self.modeKey) ?? PuraPiAppearanceMode.system.rawValue
        mode = PuraPiAppearanceMode(rawValue: rawValue) ?? .system
        let storedThemeValue = defaults.string(forKey: Self.themeKey) ?? PuraPiThemeCatalog.defaultID
        let themeValue = PuraPiThemeCatalog.canonicalID(for: storedThemeValue)
        theme = loadedThemes.first(where: { $0.id == themeValue }) ?? .default
        if storedThemeValue != themeValue {
            defaults.set(themeValue, forKey: Self.themeKey)
        }
        let languageValue = defaults.string(forKey: Self.languageKey)
        language = languageValue.flatMap(PuraPiInterfaceLanguage.init(rawValue:))
            ?? PuraPiInterfaceLanguage.systemDefault

        // 默认保持现有观感：两栏都用紫色，与改动前一致。
        sidebarTint = defaults.string(forKey: Self.sidebarTintKey)
            .flatMap(PuraPiPaneTint.init(rawValue:)) ?? .purple
        inspectorTint = defaults.string(forKey: Self.inspectorTintKey)
            .flatMap(PuraPiPaneTint.init(rawValue:)) ?? .purple
    }

    func setMode(_ mode: PuraPiAppearanceMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    func setTheme(_ theme: PuraPiTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        defaults.set(theme.id, forKey: Self.themeKey)
    }

    func setTheme(id: String) {
        setTheme(themeStore.theme(for: PuraPiThemeCatalog.canonicalID(for: id)))
    }

    /// 设置页重新出现时刷新用户主题目录；当前主题若仍存在则保持不变。
    func reloadThemes() {
        let themes = themeStore.themes()
        availableThemes = themes
        guard let current = themes.first(where: { $0.id == theme.id }) else {
            setTheme(.default)
            return
        }
        if current != theme {
            theme = current
        }
    }

    @discardableResult
    func importThemePackage(from url: URL) -> Bool {
        do {
            _ = try themeStore.merge(packageAt: url)
            reloadThemes()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteTheme(id: String) -> Bool {
        do {
            try themeStore.delete(id: id)
            reloadThemes()
            return true
        } catch {
            return false
        }
    }

    func setLanguage(_ language: PuraPiInterfaceLanguage) {
        guard self.language != language else { return }
        self.language = language
        defaults.set(language.rawValue, forKey: Self.languageKey)
    }

    func setSidebarTint(_ tint: PuraPiPaneTint) {
        guard sidebarTint != tint else { return }
        sidebarTint = tint
        defaults.set(tint.rawValue, forKey: Self.sidebarTintKey)
    }

    func setInspectorTint(_ tint: PuraPiPaneTint) {
        guard inspectorTint != tint else { return }
        inspectorTint = tint
        defaults.set(tint.rawValue, forKey: Self.inspectorTintKey)
    }
}

/// 栏表面的主题色选项。
///
/// 用固定的一组预设而不是任意取色器：这层颜色是很淡的薄膜（不透明度 0.075），
/// 目的是给栏一点色调倾向，不是让用户涂色。开放任意 RGB 反而容易调出
/// 与正文抢注意力的结果。
enum PuraPiPaneTint: String, CaseIterable, Identifiable, Sendable {
    /// 不叠任何颜色。
    ///
    /// 左栏会露出系统玻璃/材质本身的颜色；右栏则连系统玻璃一起去掉，
    /// 变成完全中性的表面——这是用户明确要求的行为差异。
    case none
    case purple
    case blue
    case teal
    case green
    case orange
    case pink
    case graphite

    var id: String { rawValue }

    /// 叠加在表面上的默认颜色。`none` 返回 nil 表示不叠加。
    ///
    /// 这个无参数版本保留给设置页色板和旧调用；实际渲染时使用下面的
    /// `resolvedColor(using:)`，这样 `.purple` 才能跟随当前主题的强调色。
    var color: Color? {
        switch self {
        case .none: return nil
        case .purple: return PuraPiTheme.default.accent
        case .blue: return Color(red: 122 / 255, green: 162 / 255, blue: 247 / 255)
        case .teal: return Color(red: 108 / 255, green: 196 / 255, blue: 199 / 255)
        case .green: return Color(red: 140 / 255, green: 196 / 255, blue: 132 / 255)
        case .orange: return Color(red: 232 / 255, green: 163 / 255, blue: 106 / 255)
        case .pink: return Color(red: 226 / 255, green: 141 / 255, blue: 176 / 255)
        case .graphite: return Color(red: 150 / 255, green: 155 / 255, blue: 165 / 255)
        }
    }

    /// 在指定主题下解析栏色。紫色是主题的品牌强调色，其余色板保留为显式
    /// 用户覆盖；这样既兼容现有的独立 Sidebar/Inspector 色彩设置，也允许主题
    /// 改变全局品牌色。
    func resolvedColor(using theme: PuraPiTheme) -> Color? {
        guard self != .none else { return nil }
        if self == .purple { return theme.accent }
        return color
    }

    /// 色板上显示的方块颜色。`none` 用中性灰表示"无颜色"。
    var swatchColor: Color {
        color ?? Color(nsColor: .quaternaryLabelColor)
    }

    func title(language: PuraPiInterfaceLanguage) -> String {
        let english = language == .english
        switch self {
        case .none: return english ? "No color" : "无颜色"
        case .purple: return english ? "Purple" : "紫色"
        case .blue: return english ? "Blue" : "蓝色"
        case .teal: return english ? "Teal" : "青色"
        case .green: return english ? "Green" : "绿色"
        case .orange: return english ? "Orange" : "橙色"
        case .pink: return english ? "Pink" : "粉色"
        case .graphite: return english ? "Graphite" : "石墨"
        }
    }
}

extension PuraPiAppearanceState {
    static let sidebarTintKey = PuraPiPreferences.Key.sidebarTintID
    static let inspectorTintKey = PuraPiPreferences.Key.inspectorTintID
}
