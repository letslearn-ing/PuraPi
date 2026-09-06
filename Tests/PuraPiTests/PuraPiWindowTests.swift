import AppKit
import XCTest
@testable import PuraPi

final class PuraPiWindowTests: XCTestCase {
    private let windowBounds = NSRect(x: 0, y: 0, width: 1_200, height: 760)
    private let contentLayoutRect = NSRect(x: 0, y: 0, width: 1_200, height: 708)

    func testDoubleClickInBlankTitlebarTogglesZoom() {
        XCTAssertTrue(
            PuraPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 2,
                location: NSPoint(x: 600, y: 734),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [],
                isFullScreen: false
            )
        )
    }

    func testSingleClickAndContentDoubleClickDoNotToggleZoom() {
        XCTAssertFalse(
            PuraPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 1,
                location: NSPoint(x: 600, y: 734),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [],
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            PuraPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 2,
                location: NSPoint(x: 600, y: 500),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [],
                isFullScreen: false
            )
        )
    }

    func testInteractiveTitlebarItemsAndFullScreenAreExcluded() {
        let tabRect = NSRect(x: 450, y: 712, width: 240, height: 40)
        XCTAssertFalse(
            PuraPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 2,
                location: NSPoint(x: 500, y: 734),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [tabRect],
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            PuraPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 2,
                location: NSPoint(x: 800, y: 734),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [],
                isFullScreen: true
            )
        )
    }

    func testTitlebarRectUsesAreaAboveContentLayout() {
        XCTAssertEqual(
            PuraPiWindowZoomPolicy.titlebarRect(
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect
            ),
            NSRect(x: 0, y: 708, width: 1_200, height: 52)
        )
    }

    func testLegacyWindowFrameMigratesWithoutOverwritingCurrentFrame() throws {
        let suiteName = "PuraPi-window-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let currentKey = "NSWindow Frame \(PuraPiWindowFrameMigration.currentAutosaveName)"
        let legacyKey = "NSWindow Frame \(PuraPiWindowFrameMigration.legacyAutosaveName)"
        defaults.set("legacy-frame", forKey: legacyKey)
        PuraPiWindowFrameMigration.migrateLegacyFrame(in: defaults)
        XCTAssertEqual(defaults.string(forKey: currentKey), "legacy-frame")

        defaults.set("current-frame", forKey: currentKey)
        defaults.set("new-legacy-frame", forKey: legacyKey)
        PuraPiWindowFrameMigration.migrateLegacyFrame(in: defaults)
        XCTAssertEqual(defaults.string(forKey: currentKey), "current-frame")
    }
}
