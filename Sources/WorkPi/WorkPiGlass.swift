import AppKit
import SwiftUI

/// WorkPi 的材质角色。
///
/// macOS 26 使用 SwiftUI 原生 Liquid Glass（液态玻璃）API；
/// macOS 14–25 使用语义化 NSVisualEffectView 降级，保持同一套几何层级。
enum WorkPiMaterialRole: Equatable {
    case titlebar
    case sidebar
    case inspector
    case glass
    case composer
    case hud

    /// 只有真正需要玻璃层的局部区域才启用原生玻璃；中间工作区背景保持透明，
    /// 让窗口与局部材质自然衔接。Inspector 在原生路径中使用独立的局部玻璃。
    var usesNativeGlassWhenAvailable: Bool {
        switch self {
        case .sidebar, .glass, .composer, .hud:
            return true
        case .titlebar:
            return false
        case .inspector:
            // Inspector 使用普通 NSSplitViewItem，不再嵌套在 AppKit 的 Sidebar
            // 外壳里；使用 clear glass 可保留系统合成，同时避免顶部高光形成
            // 与正文不同色的独立标题栏。
            return true
        }
    }

    var fallbackMaterial: NSVisualEffectView.Material {
        switch self {
        case .titlebar:
            return .titlebar
        case .sidebar:
            return .sidebar
        case .inspector:
            return .sidebar
        case .glass:
            return .popover
        case .composer:
            return .contentBackground
        case .hud:
            return .hudWindow
        }
    }

    var fallbackBlendingMode: NSVisualEffectView.BlendingMode {
        switch self {
        case .titlebar, .sidebar, .inspector:
            return .behindWindow
        case .glass, .composer, .hud:
            return .withinWindow
        }
    }
}

/// 将玻璃效果直接应用到真实内容容器。
///
/// 这与 Finder/Xcode 的层级更接近：玻璃是内容层的系统效果，
/// 而不是一个单独的灰色圆角背景视图。
struct WorkPiGlassSurfaceModifier: ViewModifier {
    @Environment(\.workPiTheme) private var theme

    let role: WorkPiMaterialRole
    let cornerRadius: CGFloat
    let interactive: Bool
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), role.usesNativeGlassWhenAvailable {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .glassEffect(nativeGlass, in: shape)
        } else {
            content
                .background {
                    ZStack {
                        WorkPiLegacyMaterialSurface(
                            material: role.fallbackMaterial,
                            blendingMode: role.fallbackBlendingMode,
                            emphasized: role == .glass,
                            cornerRadius: cornerRadius
                        )
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            theme.panelBorder,
                            lineWidth: theme.metrics.panelBorderWidth
                        )
                }
        }
    }

    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        var value: Glass = role == .inspector ? .clear : .regular
        if let tint {
            value = value.tint(tint)
        }
        return value.interactive(interactive)
    }
}

extension View {
    func workPiGlassSurface(
        role: WorkPiMaterialRole,
        cornerRadius: CGFloat,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(
            WorkPiGlassSurfaceModifier(
                role: role,
                cornerRadius: cornerRadius,
                interactive: interactive,
                tint: tint
            )
        )
    }
}

/// 将多个局部玻璃元素放进系统玻璃容器，避免每个元素各自渲染一套效果。
/// 这对应 Finder/Xcode 中工具栏和相邻玻璃控件的系统合成方式。
struct WorkPiGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: () -> Content

    init(
        spacing: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// macOS 14–25 的语义材质降级实现。
private struct WorkPiLegacyMaterialSurface: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let emphasized: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> WorkPiLegacyMaterialHostView {
        WorkPiLegacyMaterialHostView(
            material: material,
            blendingMode: blendingMode,
            emphasized: emphasized,
            cornerRadius: cornerRadius
        )
    }

    func updateNSView(_ nsView: WorkPiLegacyMaterialHostView, context: Context) {
        nsView.update(
            material: material,
            blendingMode: blendingMode,
            emphasized: emphasized,
            cornerRadius: cornerRadius
        )
    }
}

private final class WorkPiLegacyMaterialHostView: NSVisualEffectView {
    private var currentMaterial: NSVisualEffectView.Material
    private var currentBlendingMode: NSVisualEffectView.BlendingMode
    private var currentEmphasized: Bool
    private var currentCornerRadius: CGFloat

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        emphasized: Bool,
        cornerRadius: CGFloat
    ) {
        currentMaterial = material
        currentBlendingMode = blendingMode
        currentEmphasized = emphasized
        currentCornerRadius = cornerRadius
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        emphasized: Bool,
        cornerRadius: CGFloat
    ) {
        guard currentMaterial != material
            || currentBlendingMode != blendingMode
            || currentEmphasized != emphasized
            || currentCornerRadius != cornerRadius
        else { return }

        currentMaterial = material
        currentBlendingMode = blendingMode
        currentEmphasized = emphasized
        currentCornerRadius = cornerRadius
        configure()
    }

    private func configure() {
        material = currentMaterial
        blendingMode = currentBlendingMode
        state = .followsWindowActiveState
        isEmphasized = currentEmphasized
        wantsLayer = true
        layer?.cornerRadius = currentCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = currentCornerRadius > 0
    }
}

/// 使用 macOS 26 系统按钮样式，旧系统使用轻量语义化降级。
struct WorkPiGlassButton<Label: View>: View {
    @Environment(\.workPiTheme) private var theme

    private let action: () -> Void
    private let prominent: Bool
    private let label: () -> Label

    init(
        prominent: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.prominent = prominent
        self.label = label
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            if prominent {
                // 必须显式 tint：`.glassProminent` 默认用系统强调色（多为蓝），
                // 不加就会脱离项目紫主题。
                Button(action: action, label: label)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
            } else {
                Button(action: action, label: label)
                    .buttonStyle(.glass)
            }
        } else {
            Button(action: action, label: label)
                .buttonStyle(
                    WorkPiLegacyButtonStyle(
                        prominent: prominent,
                        accent: theme.accent,
                        cornerRadius: CGFloat(theme.metrics.smallControlCornerRadius)
                    )
                )
        }
    }
}

private struct WorkPiLegacyButtonStyle: ButtonStyle {
    let prominent: Bool
    let accent: Color
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        prominent
                            ? accent.opacity(configuration.isPressed ? 0.76 : 0.92)
                            : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.065)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 窗口内容底层：macOS 26 由 NSWindow/AppKit chrome 提供系统背景，内容保持透明；旧系统使用窗口背景色。
struct WorkPiWindowBackdrop: View {
    @Environment(\.workPiTheme) private var theme

    var body: some View {
        // macOS 26 的窗口背景由 NSWindow/AppKit chrome 管理；内容层必须
        // 保持透明，局部 glassEffect 才能采样真实窗口背景与相邻内容。
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            theme.windowBackground
        }
    }
}

/// 内容区在 macOS 26 上保持透明，以便 Sidebar/HUD 采样窗口底层；
/// 旧系统继续使用稳定的不透明颜色。
struct WorkPiAdaptiveContentBackground: View {
    @Environment(\.workPiTheme) private var theme
    let legacyColor: Color?

    init(legacyColor: Color? = nil) {
        self.legacyColor = legacyColor
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            legacyColor ?? theme.contentBackground
        }
    }
}

/// 两栏主题色的环境注入。
///
/// 用 Environment 而不是逐层传参：表面绘制发生在 `FileTreePane` /
/// `FileInspectorPane` 这类深层视图里，中间隔着好几层容器，逐层加参数会污染
/// 大量与颜色无关的签名，而且 AppKit 托管的宿主重建时容易漏传。
private struct WorkPiSidebarTintKey: EnvironmentKey {
    static let defaultValue: WorkPiPaneTint = .purple
}

private struct WorkPiInspectorTintKey: EnvironmentKey {
    static let defaultValue: WorkPiPaneTint = .purple
}

extension EnvironmentValues {
    var workPiSidebarTint: WorkPiPaneTint {
        get { self[WorkPiSidebarTintKey.self] }
        set { self[WorkPiSidebarTintKey.self] = newValue }
    }

    var workPiInspectorTint: WorkPiPaneTint {
        get { self[WorkPiInspectorTintKey.self] }
        set { self[WorkPiInspectorTintKey.self] = newValue }
    }
}

extension View {
    /// 把两栏主题色注入到子树。
    func workPiPaneTints(
        sidebar: WorkPiPaneTint,
        inspector: WorkPiPaneTint
    ) -> some View {
        environment(\.workPiSidebarTint, sidebar)
            .environment(\.workPiInspectorTint, inspector)
    }
}

// 所有主题颜色都通过 `WorkPiTheme` 提供；不再保留散落在 `Color` 命名空间里的
// 视觉常量，避免第三方主题只能覆盖部分组件。

extension View {
    /// Inspector 的悬浮圆角表面。
    ///
    /// 与 `workPiSidebarSurface` 共用同一套圆角与材质。颜色由设置状态决定；
    /// Inspector 选择“无颜色”时走中性底，不创建系统材质，避免出现蓝色底光。
    func workPiInspectorSurface(
        enabled: Bool = true,
        tint: WorkPiPaneTint = .purple
    ) -> some View {
        modifier(
            WorkPiInspectorSurfaceModifier(
                enabled: enabled,
                tint: tint
            )
        )
    }

    /// 只叠一层主题色薄膜，不重复绘制材质与圆角。
    ///
    /// 供由父容器提供玻璃外壳的嵌入场景补一层主题色薄膜。原生三栏 Inspector
    /// 现在直接使用自己的 `workPiInspectorSurface`，因此不会重复叠加这层材质。
    func workPiInspectorAccentWash(
        enabled: Bool = true,
        tint: WorkPiPaneTint = .purple
    ) -> some View {
        modifier(
            WorkPiInspectorAccentWashModifier(
                enabled: enabled,
                tint: tint
            )
        )
    }

    /// Sidebar 的主题色玻璃表面。
    ///
    /// 文件树与会话树共用它，且必须由容器绘制而不是各自绘制：只在树内容上画
    /// 会让顶部交通灯安全区露出窗口底色，与列表底色不一致。
    func workPiSidebarSurface(
        enabled: Bool = true,
        tint: WorkPiPaneTint = .purple
    ) -> some View {
        modifier(
            WorkPiSidebarSurfaceModifier(
                enabled: enabled,
                tint: tint
            )
        )
    }
}

private struct WorkPiInspectorSurfaceModifier: ViewModifier {
    @Environment(\.workPiTheme) private var theme

    let enabled: Bool
    let tint: WorkPiPaneTint

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if let color = tint.resolvedColor(using: theme) {
            content
                .workPiGlassSurface(
                    role: .inspector,
                    cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                    tint: color.opacity(theme.metrics.paneTintOpacity)
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                        style: .continuous
                    )
                )
        } else {
            // Inspector 选择“无颜色”时不能继续创建 NSVisualEffectView：
            // 那会把 macOS 默认的蓝色系统玻璃重新带回来。这里使用随系统
            // 浅深色变化的中性底，只保留圆角几何，不保留系统材质颜色。
            content
                .background {
                    RoundedRectangle(
                        cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                        style: .continuous
                    )
                    .fill(theme.workspaceBackground)
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                        style: .continuous
                    )
                    .strokeBorder(
                        theme.panelBorder,
                        lineWidth: theme.metrics.panelBorderWidth
                    )
                }
        }
    }
}

private struct WorkPiInspectorAccentWashModifier: ViewModifier {
    @Environment(\.workPiTheme) private var theme

    let enabled: Bool
    let tint: WorkPiPaneTint

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else {
            content.background {
                let shape = RoundedRectangle(
                    cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                    style: .continuous
                )
                if let color = tint.resolvedColor(using: theme) {
                    shape.fill(color.opacity(theme.metrics.paneTintOpacity))
                } else {
                    // “无颜色”时使用工作区同族的中性底，随浅色/深色外观切换。
                    shape.fill(theme.workspaceBackground)
                }
            }
        }
    }
}

private struct WorkPiSidebarSurfaceModifier: ViewModifier {
    @Environment(\.workPiTheme) private var theme

    let enabled: Bool
    let tint: WorkPiPaneTint

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else {
            content
                .workPiGlassSurface(
                    role: .sidebar,
                    cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                    // nil 表示“无颜色”：露出系统材质本身的色调。
                    tint: tint.resolvedColor(using: theme).map {
                        $0.opacity(theme.metrics.paneTintOpacity)
                    }
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: CGFloat(theme.metrics.chromeCornerRadius),
                        style: .continuous
                    )
                )
        }
    }
}

private struct WorkPiPresentationGlassChromeModifier: ViewModifier {
    @Environment(\.workPiTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .presentationBackground(.clear)
                .presentationCornerRadius(
                    CGFloat(theme.metrics.chromeCornerRadius)
                )
        } else {
            content
        }
    }
}

extension View {
    /// 让 sheet 背板本身透明，从而露出内容的玻璃层。
    ///
    /// macOS 14–25 没有 `presentationBackground`，保留系统默认背板即可，
    /// 内容侧的 NSVisualEffectView 降级仍然生效。
    func workPiPresentationGlassChrome() -> some View {
        modifier(WorkPiPresentationGlassChromeModifier())
    }
}
