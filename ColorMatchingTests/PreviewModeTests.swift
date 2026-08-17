import XCTest
@testable import ColorMatching
import ColorComposerCore

final class PreviewModeTests: XCTestCase {
    func testOrderedModesStayAlignedWithMenuNumbering() {
        XCTAssertEqual(
            PreviewMode.orderedModes,
            [
                .composite,
                .errorMap,
                .gamut,
                .lighting(.white),
                .lighting(.red),
                .lighting(.green),
                .lighting(.blue),
                .lighting(.lps)
            ]
        )
    }

    func testMenuTitlesMatchVisiblePreviewTabs() {
        XCTAssertEqual(
            PreviewMode.orderedModes.map(\.menuTitle),
            [
                "Composite",
                "Error Map",
                "Gamut",
                "White",
                "Red",
                "Green",
                "Blue",
                "LPS (Sodium)"
            ]
        )
    }
}
