import AppKit
import XCTest
@testable import WorkPi

final class WorkPiWindowTests: XCTestCase {
    private let windowBounds = NSRect(x: 0, y: 0, width: 1_200, height: 760)
    private let contentLayoutRect = NSRect(x: 0, y: 0, width: 1_200, height: 708)

    func testDoubleClickInBlankTitlebarTogglesZoom() {
        XCTAssertTrue(
            WorkPiWindowZoomPolicy.shouldToggleZoom(
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
            WorkPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 1,
                location: NSPoint(x: 600, y: 734),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [],
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            WorkPiWindowZoomPolicy.shouldToggleZoom(
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
            WorkPiWindowZoomPolicy.shouldToggleZoom(
                clickCount: 2,
                location: NSPoint(x: 500, y: 734),
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect,
                excludedRects: [tabRect],
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            WorkPiWindowZoomPolicy.shouldToggleZoom(
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
            WorkPiWindowZoomPolicy.titlebarRect(
                windowBounds: windowBounds,
                contentLayoutRect: contentLayoutRect
            ),
            NSRect(x: 0, y: 708, width: 1_200, height: 52)
        )
    }
}
