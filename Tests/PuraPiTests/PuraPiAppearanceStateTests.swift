import XCTest
@testable import PuraPi

/// 栏颜色的默认值、持久化与非法值回退。
@MainActor
final class PuraPiAppearanceStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain = ""

    override func setUp() {
        super.setUp()
        domain = "works.purapi.PuraPiTests.appearance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        super.tearDown()
    }

    func testDefaultThemeAndTintPreserveExistingPurpleAppearance() {
        let state = PuraPiAppearanceState(defaults: defaults)

        XCTAssertEqual(state.theme.id, PuraPiThemeCatalog.defaultID)
        XCTAssertEqual(
            state.theme.colors.accent.source,
            .rgba(PuraPiRGBAColor(red: 171 / 255, green: 131 / 255, blue: 228 / 255))
        )
        XCTAssertEqual(state.theme.metrics.chromeCornerRadius, 18)
        XCTAssertEqual(state.theme.metrics.paneTintOpacity, 0.075, accuracy: 0.0001)
        XCTAssertEqual(state.sidebarTint, .purple)
        XCTAssertEqual(state.inspectorTint, .purple)
        XCTAssertNil(PuraPiPaneTint.none.color)
    }

    func testThemeAndTintSelectionsPersistIndependently() {
        let state = PuraPiAppearanceState(defaults: defaults)

        state.setTheme(id: "purapi.midnight")
        state.setSidebarTint(.teal)
        state.setInspectorTint(.none)

        XCTAssertEqual(
            defaults.string(forKey: PuraPiPreferences.Key.themeID),
            "purapi.midnight"
        )
        XCTAssertEqual(
            defaults.string(forKey: PuraPiPreferences.Key.sidebarTintID),
            PuraPiPaneTint.teal.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: PuraPiPreferences.Key.inspectorTintID),
            PuraPiPaneTint.none.rawValue
        )

        let reloaded = PuraPiAppearanceState(defaults: defaults)
        XCTAssertEqual(reloaded.theme.id, "purapi.midnight")
        XCTAssertEqual(reloaded.sidebarTint, .teal)
        XCTAssertEqual(reloaded.inspectorTint, .none)
    }

    func testInvalidThemeAndTintValuesFallBackToDefaults() {
        defaults.set("not-a-theme", forKey: PuraPiPreferences.Key.themeID)
        defaults.set("not-a-color", forKey: PuraPiPreferences.Key.sidebarTintID)
        defaults.set("also-not-a-color", forKey: PuraPiPreferences.Key.inspectorTintID)

        let state = PuraPiAppearanceState(defaults: defaults)

        XCTAssertEqual(state.theme.id, PuraPiThemeCatalog.defaultID)
        XCTAssertEqual(state.sidebarTint, .purple)
        XCTAssertEqual(state.inspectorTint, .purple)
    }

    func testThemeDefinitionRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(PuraPiThemeCatalog.midnightDefinition)
        let decoded = try JSONDecoder().decode(PuraPiThemeDefinition.self, from: data)

        XCTAssertEqual(decoded, PuraPiThemeCatalog.midnightDefinition)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.id, "purapi.midnight")
    }

    func testBuiltInThemeIDsAreUnique() {
        let ids = PuraPiThemeCatalog.builtInThemes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains(PuraPiThemeCatalog.defaultID))
    }

    func testThemeColorSourceUsesReadablePackageEncoding() throws {
        let encoded = try JSONEncoder().encode(
            PuraPiThemeColorSource.rgba(PuraPiRGBAColor(hex: 0x7AA2F7))
        )
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"#7AA2F7\"")

        let decoded = try JSONDecoder().decode(
            PuraPiThemeColorSource.self,
            from: Data("\"system.separator\"".utf8)
        )
        XCTAssertEqual(decoded, .system(.separator))
    }

    func testThemePackageShapeDecodes() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "com.example.test",
          "names": { "zh": "测试", "en": "Test" },
          "summaries": { "zh": "测试主题", "en": "Test theme" },
          "colors": {
            "accent": { "source": "#123456", "opacity": 1 },
            "hairline": { "source": "system.separator", "opacity": 0.58 },
            "windowBackground": { "source": "system.windowBackground", "opacity": 1 },
            "workspaceBackground": { "source": "system.underPageBackground", "opacity": 1 },
            "contentBackground": { "source": "system.textBackground", "opacity": 1 },
            "panelBorder": { "source": "system.separator", "opacity": 0.72 },
            "searchBarBackground": { "source": "system.windowBackground", "opacity": 1 },
            "success": { "source": "system.green", "opacity": 1 },
            "warning": { "source": "system.orange", "opacity": 1 },
            "error": { "source": "system.red", "opacity": 1 },
            "info": { "source": "system.blue", "opacity": 1 }
          },
          "metrics": {
            "chromeCornerRadius": 18,
            "paneTintOpacity": 0.075,
            "panelBorderWidth": 0.5,
            "smallControlCornerRadius": 9
          }
        }
        """

        let definition = try JSONDecoder().decode(
            PuraPiThemeDefinition.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(definition.id, "com.example.test")
        XCTAssertEqual(definition.colors.accent.source, .rgba(PuraPiRGBAColor(hex: 0x123456)))
    }

    func testEveryTintExceptNoneHasASwatchColor() {
        XCTAssertEqual(PuraPiPaneTint.allCases.count, 8)
        for tint in PuraPiPaneTint.allCases where tint != .none {
            XCTAssertNotNil(tint.color, "\(tint.rawValue) 应有可显示的颜色方格")
        }
    }
}
